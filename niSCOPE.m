%% ============================================================
%  NI-SCOPE MATLAB Acquisition Example Script
%  Hardware: PCI NI-SCOPE Device (e.g. PCI-5112)
%  Function: Initialize ? Configure ? Acquire ? Plot ? Close
% ============================================================

clc; clear;

%% Clean up any previously loaded NI-SCOPE library
if libisloaded('niscope')
    unloadlibrary('niscope');
end 
if libisloaded('niScope_32')
    unloadlibrary('niScope_32');
end


%% 1. Configure NI-SCOPE DLL and header file paths
dllfile = 'C:\Program Files\IVI Foundation\IVI\Bin\niScope_32.dll';
hfile   = 'C:\Program Files\IVI Foundation\IVI\Include\niScope.h';

% inc = 'C:\Program Files\IVI Foundation\VISA\WinNT\include';  % <- one char
inc = 'C:\Program Files\IVI Foundation\IVI\Include';  % <- one char

if ~exist(dllfile, 'file')
    error('NI-SCOPE DLL not found. Please check driver installation.');
end
if ~exist(hfile, 'file')
    error('niscope.h not found. Please check the Include path.');
end


%% 2. Load the NI-SCOPE library
if ~libisloaded('niscope')
    loadlibrary(dllfile, hfile, 'alias','niscope', ...
        'includepath', inc,...
        'mfilename','niscope_proto');


    disp('NI-SCOPE library loaded');
end


%% 3. Initialize the device session and selftest
devName ='1';                % device name as seen in NI MAX
resourcePtr = libpointer('int8Ptr',[int8(devName) 0]);  % C string (null-terminated)

vi = libpointer('uint32Ptr', 0); % for receiving session handle

status = calllib('niscope', 'niScope_init',resourcePtr, 1, 1, vi);
if status ~= 0
    error('niScope_init failed with status = %d', status);
else
    fprintf('niScope_init succeeded, session handle = %d\n', vi.Value);
end

if status ~= 0
    unloadlibrary('niscope');
    error('niScope_init failed, status = %d', status);
end

vi_value = vi.Value;
fprintf('Session initialized: %d\n', vi_value);

    
pCode = libpointer('int16Ptr',0);
msg   = libpointer('int8Ptr', zeros(1,1024,'int8'));
st = calllib('niscope','niScope_self_test', vi_value, pCode, msg);
fprintf('self_test: st=%d, code=%d, msg="%s"\n', ...
        st, pCode.Value, char(msg.Value(msg.Value~=0)));

    


%% 4. Configure vertical channel parameters  (uses: niScope_ConfigureVertical)
cstr = @(s) libpointer('int8Ptr', [int8(s) 0]);

channel         = '1';
channelPtr      = cstr(channel);

verticalRange   = 1;     % V
verticalOffset  = 0.0;     % V
coupling        = int32(1);% 0=DC  1=AC  (per niScope.h enum)
probeAtten      = 1.0;     % 1x probe (required by signature)
enabled         = uint16(1); % ViBoolean ? use uint16(0/1) in R2015b

status = calllib('niscope','niScope_ConfigureVertical', ...
    vi_value, channelPtr, verticalRange, verticalOffset, coupling, probeAtten, enabled);
if status<0, error('ConfigureVertical failed: %d', status); end



%% 5. Configure horizontal timing parameters  (uses: niScope_ConfigureHorizontalTiming)
sampleRate      = 1e6;     % S/s
minRecordLength = int32(1000);
refPosition     = 0;    % % of record pre-trigger
numRecords      = int32(1);
enforceRealtime = uint16(1);   % ViBoolean

status = calllib('niscope','niScope_ConfigureHorizontalTiming', ...
    vi_value, sampleRate, minRecordLength, refPosition, numRecords, enforceRealtime);
if status<0, error('ConfigureHorizontalTiming failed: %d', status); end

% To see if the parameter set to scope
rlPtr = libpointer('int32Ptr',0);
srPtr = libpointer('doublePtr',0);
calllib('niscope','niScope_ActualRecordLength', vi_value, rlPtr);
calllib('niscope','niScope_SampleRate',         vi_value, srPtr);
Texp = double(rlPtr.Value) / srPtr.Value;
fprintf('Expected acquisition time ~ %.6g s (RL=%d, SR=%.6g S/s)\n', Texp, rlPtr.Value, srPtr.Value);
%% 6. Configure trigger (immediate trigger)  (uses: niScope_ConfigureTriggerImmediate)
status = calllib('niscope','niScope_ConfigureTriggerImmediate', vi_value);
if status<0, error('ConfigureTriggerImmediate failed: %d', status); end


% 1) Initiate acquisition (good practice before any Fetch/Read)
st = calllib('niscope','niScope_InitiateAcquisition', vi_value);
if st < 0
    em = libpointer('int8Ptr', zeros(1,1024,'int8'));
    calllib('niscope','niScope_GetErrorMessage', vi_value, int32(st), int32(numel(em.Value)), em);
    error('InitiateAcquisition failed (%d): %s', st, char(em.Value(em.Value~=0)));
end

% 2) (Optional but recommended) poll until complete, or timeout yourself
statPtr = libpointer('int32Ptr',0);
t0 = tic;
while true
    calllib('niscope','niScope_AcquisitionStatus', vi_value, statPtr);
    if statPtr.Value == 0      % NISCOPE_VAL_ACQ_COMPLETE
        break
    end
    if toc(t0) > 6.0           % 2 s guard to avoid hanging forever
        warning('Acq not complete after 2 s; proceeding to Fetch with driver timeout.');
        break
    end
    pause(0.005);
end

% 3) Size the buffer from the actual record length (safer than guessing)
rlPtr = libpointer('int32Ptr',0);
st = calllib('niscope','niScope_ActualRecordLength', vi_value, rlPtr);
if st < 0
    em = libpointer('int8Ptr', zeros(1,1024,'int8'));
    calllib('niscope','niScope_GetErrorMessage', vi_value, int32(st), int32(numel(em.Value)), em);
    error('ActualRecordLength failed (%d): %s', st, char(em.Value(em.Value~=0)));
end
reqN = int32(max(1, rlPtr.Value));   % request exactly the record length

% 4) Prepare output pointers matching the niScope_Fetch prototype
timeout = 5.0;  % seconds (driver will wait up to this long if not ready)
wfmPtr  = libpointer('doublePtr', zeros(1, double(reqN)));   % double* buffer
info    = libstruct('niScope_wfmInfo');                      % struct for timing
infoPtr = libpointer('niScope_wfmInfoPtr', info);

% 5) Fetch the waveform (in volts). THIS CALL MUST MATCH TYPES EXACTLY.
st = calllib('niscope','niScope_Fetch', ...
             vi_value, channelPtr, timeout, reqN, wfmPtr, infoPtr);

if st < 0
    em = libpointer('int8Ptr', zeros(1,2048,'int8'));
    calllib('niscope','niScope_GetErrorMessage', vi_value, int32(st), int32(numel(em.Value)), em);
    error('niScope_Fetch failed (%d): %s', st, char(em.Value(em.Value~=0)));
end



numSamples = zero(1,16);
dblPtr = libpointer('unit32Ptr', zeros(1,numSamples));
infoOne = libstruct('niScope_wfmInfo');
infoPtr = libpointer('niScope_wfmInfoPtr', infoOne);
st = calllib('niscope','niScope_Read', vi_value, channelPtr, -1.0, numSamples, dblPtr, infoPtr);
assert(st>=0, 'Read failed: %d', st);
disp(infoPtr.Value);  % inspect fields are sane
plot(dblPtr.Value); title('Read (double) smoke test'); grid on;

%% 7. Fetch waveform data  (uses: niScope_Fetch)
numSamples = int32(100);
timeout    = 5.0;   % seconds

% waveform buffer must be double* for niScope_Fetch
waveformPtr = libpointer('doublePtr', zeros(1, double(numSamples)));

% wfm info struct (1 element, since 1 channel)
info      = libstruct('niScope_wfmInfo');           % fields: absoluteInitialX, xIncrement, actualSamples, ...
infoPtr   = libpointer('niScope_wfmInfoPtr', info);

status = calllib('niscope','niScope_Fetch', ...
    vi_value, channelPtr, timeout, numSamples, waveformPtr, infoPtr);

if status ~= 0
    % optional: turn status into human-readable text
    emsg = libpointer('int8Ptr', zeros(1,2048,'int8'));
    calllib('niscope','niScope_GetErrorMessage', vi_value, int32(status), int32(numel(emsg.Value)), emsg);
    calllib('niscope','niScope_close', vi_value);
    unloadlibrary('niscope');
    error('niScope_Fetch failed (%d): %s', status, char(emsg.Value(emsg.Value~=0)));
end

% unpack timing from wfmInfo
info = infoPtr.Value;
N    = double(info.actualSamples);
t    = info.absoluteInitialX + (0:N-1) * info.xIncrement;
y    = waveformPtr.Value(1:N);

%% 8. Plot waveform
plot(t, y);
xlabel('Time (s)'); ylabel('Voltage (V)');
title(['NI-SCOPE Waveform from Channel ' channel]);
grid on;

%% 9. Close session and unload library  (uses: niScope_close)
calllib('niscope','niScope_close', vi_value);
unloadlibrary('niscope');
disp('? Session closed and library unloaded');
