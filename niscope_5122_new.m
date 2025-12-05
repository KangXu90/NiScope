%% NI-SCOPE Acquisition & Analysis
% Hardware: PCI/PXI NI-SCOPE Device (e.g., PCI-5112, PXI-5122)
% Workflow: Load -> Init -> Acquire -> Plot -> Close

%% 1. Configuration Parameters
clear; clc; close all;
%% Clean up any previously loaded NI-SCOPE library
if libisloaded('niscope')
    unloadlibrary('niscope');
end 
if libisloaded('niScope_32')
    unloadlibrary('niScope_32');
end


% %% 
% % Hardware Settings
% devName      = 'DEV1';      % Resource name in NI MAX
% channelName  = '0';         % Channel '0' or '1'
% vRange       = 10.0;        % Vertical Range (Vpk-pk)
% vOffset      = 0.0;         % Vertical Offset (V)
% targetRate   = 10e6;        % Sampling Rate (10 MS/s)
% minRecordLen = 100;        % Minimum record length
% timeoutSec   = 5.0;         % Acquisition timeout

%% 2. Load and Sanitize Driver
% Define paths
dllPath       = 'C:\Program Files\IVI Foundation\IVI\Bin\niScope_64.dll';
sysHeaderPath = 'C:\Program Files\IVI Foundation\IVI\Include\niScope.h';
includeDir    = 'C:\Program Files\IVI Foundation\IVI\Include';
localHeader   = 'niScope_matlab.h';
protoFile     = 'niscope_proto.m';

% Check if library is loaded
if ~libisloaded('niscope')
    % Create sanitized header if missing (Fixes __fastcall issue)
    if ~exist(localHeader, 'file')
        if ~exist(sysHeaderPath, 'file')
            error('System header not found at: %s', sysHeaderPath);
        end
        fprintf('Sanitizing NI-SCOPE header...\n');
        fileText = fileread(sysHeaderPath);
        cleanText = strrep(fileText, '__fastcall', '');
        cleanText = strrep(cleanText, '_VI_FUNC', '');
        cleanText = strrep(cleanText, '_VI_FAR', '');
        fid = fopen(localHeader, 'w');
        fwrite(fid, cleanText);
        fclose(fid);
    end
    
    % Load Library
    try
        fprintf('Loading NI-SCOPE library...\n');
        loadlibrary(dllPath, localHeader, ...
            'alias', 'niscope', ...
            'includepath', includeDir, ...
            'mfilename', protoFile);
        fprintf('Library loaded successfully.\n');
    catch ME
        error('Failed to load library: %s', ME.message);
    end
end

functions = libfunctions('niscope', '-full');

%% 1. Setup Parameters
devNameStr  = 'DEV1';      % Device Name in NI MAX
chanStr     = '0';         % Channel Name
vRange      = 10.0;        % 10 Vpk-pk
vOffset     = 0.0;         % 0V Offset
sampleRate  = 100e6;        % 20 MS/s
minRecord   = 100;        % Request at least 1000 points
timeout     = 5.0;         % 5 second timeout

%% 2. Initialize Session (niScope_init)
% Prototype: [long, int8Ptr, ulongPtr] niScope_init(int8Ptr, uint16, uint16, ulongPtr)

% Prepare pointers
devNamePtr = libpointer('int8Ptr', [int8(devNameStr) 0]); % Null-terminated string
viPtr      = libpointer('uint32Ptr', 0);                  % Storage for Session Handle

% Call init (ID Query=1, Reset=1)
status = calllib('niscope', 'niScope_init', devNamePtr, 1, 1, viPtr);

if status < 0
    error('niScope_init failed with status: %d', status);
end

vi = viPtr.Value; % This is your 'ulong' session handle for all future calls
fprintf('Session Initialized. Handle: %d\n', vi);

% Safety: Close session if script errors later
cleanupObj = onCleanup(@() calllib('niscope', 'niScope_close', vi));

%% 3. Configure Vertical (niScope_ConfigureVertical)
% Prototype: niScope_ConfigureVertical(ulong, int8Ptr, double, double, long, double, uint16)

chanNamePtr = libpointer('int8Ptr', [int8(chanStr) 0]);
couplingDC  = int32(0);   % 0 = DC, 1 = AC
probeAtten  = 1.0;
enabled     = uint16(1);  % True

status = calllib('niscope', 'niScope_ConfigureVertical', ...
    vi, chanNamePtr, vRange, vOffset, couplingDC, probeAtten, enabled);

if status < 0, error('Vertical config failed: %d', status); end

%% 4. Configure Horizontal (niScope_ConfigureHorizontalTiming)
% Prototype: niScope_ConfigureHorizontalTiming(ulong, double, long, double, long, uint16)

refPos      = 50.0;       % Trigger at 50% of record
numRecords  = int32(1);
enforceRT   = uint16(1);  % Enforce Realtime

status = calllib('niscope', 'niScope_ConfigureHorizontalTiming', ...
    vi, sampleRate, int32(minRecord), refPos, numRecords, enforceRT);

if status < 0, error('Horizontal config failed: %d', status); end

%% 5. Configure Trigger (niScope_ConfigureTriggerImmediate)
% Prototype: niScope_ConfigureTriggerImmediate(ulong)

status = calllib('niscope', 'niScope_ConfigureTriggerImmediate', vi);
if status < 0, error('Trigger config failed: %d', status); end

%% 6. Initiate Acquisition (niScope_InitiateAcquisition)
% Prototype: long niScope_InitiateAcquisition(ulong)

status = calllib('niscope', 'niScope_InitiateAcquisition', vi);
if status < 0, error('Initiate failed: %d', status); end
fprintf('Acquisition started...\n');

%% 7. Poll for Completion (niScope_AcquisitionStatus)
% Prototype: [long, longPtr] niScope_AcquisitionStatus(ulong, longPtr)

acqStatusPtr = libpointer('int32Ptr', 0); % 'longPtr' in C is usually int32 in MATLAB/Win
tStart = tic;

while true
    calllib('niscope', 'niScope_AcquisitionStatus', vi, acqStatusPtr);
    
    if acqStatusPtr.Value == 1 % NISCOPE_VAL_ACQ_COMPLETE (usually 1 or 0 depending on driver version, check if it's Done)
        % Note: Sometimes 0 is "In Progress" and 1 is "Complete". 
        % However, standard IVI often defines NISCOPE_VAL_ACQ_COMPLETE as 1. 
        % If loop finishes instantly, check if Logic should be reversed.
        break;
    end
    
    % If the driver uses 0 for complete (Success), swap logic:
    if status == 0 && acqStatusPtr.Value == 0 
        % Some versions return status 0 (Success) implies done if checking IsDone
        break; 
    end
    
    if toc(tStart) > timeout
        error('Acquisition timed out.');
    end
    pause(0.01);
end

%% 8. Determine Buffer Size (niScope_ActualRecordLength)
% Prototype: [long, longPtr] niScope_ActualRecordLength(ulong, longPtr)

recLenPtr = libpointer('int32Ptr', 0);
calllib('niscope', 'niScope_ActualRecordLength', vi, recLenPtr);
actualPoints = recLenPtr.Value;
fprintf('Actual Record Length: %d points\n', actualPoints);

%% 9. Fetch Data (niScope_Fetch)
% Prototype: [long, int8Ptr, doublePtr, niScope_wfmInfoPtr] niScope_Fetch(...)

% Allocate buffers
wfmPtr  = libpointer('doublePtr', zeros(1, actualPoints));
infoStruct = libstruct('niScope_wfmInfo');
infoPtr = libpointer('niScope_wfmInfoPtr', infoStruct);

% Call Fetch
status = calllib('niscope', 'niScope_Fetch', ...
    vi, ...             % Session
    chanNamePtr, ...    % Channel String
    timeout, ...        % Timeout
    actualPoints, ...   % Num Samples
    wfmPtr, ...         % Waveform Array (Output)
    infoPtr);           % Info Struct (Output)

if status < 0
    % Retrieve Error Message if failed
    % Prototype: [long, int8Ptr] niScope_GetErrorMessage(ulong, long, long, int8Ptr)
    errBuf = libpointer('int8Ptr', zeros(1, 1024, 'int8'));
    calllib('niscope', 'niScope_GetErrorMessage', vi, status, 1024, errBuf);
    error('Fetch failed: %s', char(errBuf.Value(errBuf.Value~=0)));
end

% Extract Data
yData = wfmPtr.Value;
wfmInfo = infoPtr.Value;
dt = wfmInfo.xIncrement;
t0 = wfmInfo.absoluteInitialX;
xData = (0:actualPoints-1) * dt;

%% 10. Plot
figure;
plot(xData, yData);
title(['Channel ' chanStr ' Data']);
xlabel('Time (s)');
ylabel('Voltage (V)');
grid on;

%% 11. Close Session (niScope_close)
% Prototype: long niScope_close(ulong)

% The onCleanup object above handles this, but here is the explicit call:
if exist('vi', 'var')
    calllib('niscope', 'niScope_close', vi);
    clear vi;
    fprintf('Session Closed.\n');
end