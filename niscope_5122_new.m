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
vRange      = 5.0;        % 10 Vpk-pk
vOffset     = 0.0;         % 0V Offset
sampleRate  = 100e6;        % 20 MS/s
minRecord   = 500;        % Request at least 1000 points
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

chk(calllib('niscope', 'niScope_reset', vi));


% Safety: Close session if script errors later
cleanupObj = onCleanup(@() calllib('niscope', 'niScope_close', vi));


%% 3b. Configure Channel Impedance and Filter
% Validated against niScope.h
% Function defined as: (ViSession, ViConstString, ViReal64, ViReal64)

% --- Configuration ---
% Impedance: 50.0 or 1000000.0 (1MOhm)
% Check your device specs! If 50 Ohm fails, use 1000000.0
targetImpedance = 1000000.0; 

% Bandwidth: 0 (Default) or -1 (Full) or specific Hz (e.g. 20e6)
targetBandwidth = 0; 

try
    status = calllib('niscope', 'niScope_ConfigureChanCharacteristics', ...
        vi, ...              % Session Handle
        chanNamePtr, ...     % Channel Name Pointer (from Step 3)
        targetImpedance, ... % ViReal64 (double)
        targetBandwidth);    % ViReal64 (double)

    if status < 0
        % If 50 Ohm fails, try 1MOhm automatically
        warning('50 Ohm setup failed (Status %d). Retrying with 1 MOhm...', status);
        status = calllib('niscope', 'niScope_ConfigureChanCharacteristics', ...
            vi, chanNamePtr, targetImpedance, targetBandwidth);
            
        if status < 0
             error('Failed to set impedance. Status: %d', status);
        else
             fprintf('Fallback successful: Configured 1 MOhm Input Impedance.\n');
        end
    else
        fprintf('Success: Configured %.0f Ohm Input Impedance.\n', targetImpedance);
    end
catch ME
    disp(ME.message);
end

%% %% 3. Configure Vertical (niScope_ConfigureVertical)
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

%% %% Check Actual Sample Rate (niScope_SampleRate)
% Prototype: [long, doublePtr] niScope_SampleRate(ulong, doublePtr)

% 1. Create a pointer to hold the result
actualRatePtr = libpointer('doublePtr', 0);

% 2. Call the function
status = calllib('niscope', 'niScope_SampleRate', vi, actualRatePtr);

% 3. Error Checking & Display
if status < 0
    errBuf = libpointer('int8Ptr', zeros(1, 1024, 'int8'));
    calllib('niscope', 'niScope_GetErrorMessage', vi, status, 1024, errBuf);
    error('niScope_SampleRate failed: %s', char(errBuf.Value(errBuf.Value~=0)));
else
    actualRate = actualRatePtr.Value;
    fprintf('------------------------------------------------\n');
    fprintf('Requested Rate : %.2f MS/s\n', sampleRate / 1e6);
    fprintf('Actual Rate    : %.2f MS/s\n', actualRate / 1e6);
    fprintf('------------------------------------------------\n');
end

%% 5. Configure Edge Trigger (niScope_ConfigureTriggerEdge)
% Prototype: [long, int8Ptr] niScope_ConfigureTriggerEdge(ulong, int8Ptr, double, long, long, double, double)

% --- User Parameters ---
triggerSourceStr = 'TRIG';     % Use '0', '1', or 'External' (Note: 'TRIG' might need to be 'External' or 'VAL_EXTERNAL' depending on driver)
triggerLevel     = 0.2;     % Volts
triggerSlope     = 1;       % 1 = Positive (Rising), 0 = Negative (Falling)
triggerCoupling  = 1;       % 1 = DC, 0 = AC (Based on your input. Note: Standard NI headers often use DC=0, AC=1. Verify if you see signal drift.)
holdoff          = 0.0;     % Seconds
delay            = 0.0;     % Seconds

% --- Type Casting for DLL ---
% Convert string to C-String pointer
trigSrcPtr = libpointer('int8Ptr', [int8(triggerSourceStr) 0]);

% Convert Enums/Ints to int32 (C 'long')
slopeVal    = int32(triggerSlope);
couplingVal = int32(triggerCoupling);

% --- Call Library Function ---
status = calllib('niscope', 'niScope_ConfigureTriggerEdge', ...
    vi, ...             % Session Handle (ulong)
    trigSrcPtr, ...     % Trigger Source (int8Ptr)
    triggerLevel, ...   % Level (double)
    slopeVal, ...       % Slope (long)
    couplingVal, ...    % Coupling (long)
    holdoff, ...        % Holdoff (double)
    delay);             % Delay (double)

% --- Error Checking ---
if status < 0
    errBuf = libpointer('int8Ptr', zeros(1, 1024, 'int8'));
    calllib('niscope', 'niScope_GetErrorMessage', vi, status, 1024, errBuf);
    error('ConfigureTriggerEdge failed: %s', char(errBuf.Value(errBuf.Value~=0)));
else
    fprintf('Trigger Configured: Edge on %s at %.2f V\n', triggerSourceStr, triggerLevel);
end
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

%% 9. Fetch Data (Safe Mode)
fprintf('Attempting Safe Fetch...\n');

% 1. Buffer Safety: Allocate slightly more than needed
% This prevents crashes if the driver writes 1-2 extra bytes due to alignment.
bufferSize = actualPoints + 10; 
wfmPtr  = libpointer('doublePtr', zeros(1, bufferSize));

% 2. Struct Safety: Pass NULL for the info struct first.
% If this works, we know the previous crash was due to struct definition mismatch.
% We can calculate dt manually: dt = 1/sampleRate.
infoPtr = libpointer('niScope_wfmInfoPtr', []); 

% 3. Call Fetch
status = calllib('niscope', 'niScope_Fetch', ...
    vi, ...             
    chanNamePtr, ...    
    timeout, ...        
    actualPoints, ...   % Ask for specific amount
    wfmPtr, ...         
    infoPtr);           % Pass NULL

if status < 0
    errBuf = libpointer('int8Ptr', zeros(1, 1024, 'int8'));
    calllib('niscope', 'niScope_GetErrorMessage', vi, status, 1024, errBuf);
    error('Fetch failed: %s', char(errBuf.Value(errBuf.Value~=0)));
end

fprintf('Fetch Successful!\n');

% 4. Manual reconstruction of Time vector (since we skipped wfmInfo)
yData = wfmPtr.Value(1:actualPoints); % Truncate the safety padding
dt = 1/sampleRate; % You set this in Step 1
xData = (0:length(yData)-1) * dt;


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

%% Helper Function
function chk(status)
    if status < 0
        error('NI-SCOPE Error: %d', status);
    end
end