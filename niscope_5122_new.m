%% NI-SCOPE Acquisition & Analysis (Optimized for Binary Fetch)
% Hardware: PCI/PXI NI-SCOPE Device (e.g., PCI-5122)
% Workflow: Load -> Init -> Acquire -> FetchBinary -> Convert -> Plot -> Close

%% 1. Configuration Parameters
clear; clc; close all;

%% Clean up any previously loaded NI-SCOPE library
if libisloaded('niscope')
    unloadlibrary('niscope');
end 

%% 2. Load and Sanitize Driver
% Define paths (Adjust these if your paths differ)
dllPath       = 'C:\Program Files\IVI Foundation\IVI\Bin\niScope_64.dll';
sysHeaderPath = 'C:\Program Files\IVI Foundation\IVI\Include\niScope.h';
includeDir    = 'C:\Program Files\IVI Foundation\IVI\Include';
localHeader   = 'niScope_matlab.h';
protoFile     = 'niscope_proto.m';

% Check if library is loaded
if ~libisloaded('niscope')
    % Create sanitized header if missing
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

%% 1. Setup Parameters
devNameStr  = 'DEV1';      % Device Name in NI MAX
chanStr     = '0';         % Channel Name
vRange      = 1.0;         % 10 Vpk-pk
vOffset     = 0.0;         % 0V Offset
sampleRate  = 20e6;        % 20 MS/s
minRecord   = 100000;     % Request 1M points
timeout     = 5.0;         % 5 second timeout

%% 2. Initialize Session (niScope_init)
devNamePtr = libpointer('int8Ptr', [int8(devNameStr) 0]); 
viPtr      = libpointer('uint32Ptr', 0);                  

status = calllib('niscope', 'niScope_init', devNamePtr, 1, 1, viPtr);
if status < 0
    error('niScope_init failed with status: %d', status);
end
vi = viPtr.Value;
fprintf('Session Initialized. Handle: %d\n', vi);
cleanupObj = onCleanup(@() calllib('niscope', 'niScope_close', vi));

%% 3. Configure Channel
chanNamePtr = libpointer('int8Ptr', [int8(chanStr) 0]);
targetImpedance = 1000000.0; 
targetBandwidth = 0; 
status = calllib('niscope', 'niScope_ConfigureChanCharacteristics', ...
    vi, chanNamePtr, targetImpedance, targetBandwidth);
if status < 0
    warning('Retrying impedance setup...');
    calllib('niscope', 'niScope_ConfigureChanCharacteristics', ...
        vi, chanNamePtr, 1000000.0, targetBandwidth);
end

%% 4. Configure Vertical
couplingDC  = int32(0);   
probeAtten  = 1.0;
enabled     = uint16(1);  
status = calllib('niscope', 'niScope_ConfigureVertical', ...
    vi, chanNamePtr, vRange, vOffset, couplingDC, probeAtten, enabled);
if status < 0, error('Vertical config failed: %d', status); end

%% 5. Configure Horizontal
refPos      = 50.0;       
numRecords  = int32(1);
enforceRT   = uint16(1);  
status = calllib('niscope', 'niScope_ConfigureHorizontalTiming', ...
    vi, sampleRate, int32(minRecord), refPos, numRecords, enforceRT);
if status < 0, error('Horizontal config failed: %d', status); end

%% 6. Configure Trigger
triggerSourceStr = 'TRIG';     
trigSrcPtr = libpointer('int8Ptr', [int8(triggerSourceStr) 0]);
status = calllib('niscope', 'niScope_ConfigureTriggerEdge', ...
    vi, trigSrcPtr, 0.1, int32(1), int32(1), 0.0, 0.0);
if status < 0
     % Error handling omitted for brevity, but recommended
end
fprintf('Trigger Configured.\n');

%% 7. Initiate Acquisition
status = calllib('niscope', 'niScope_InitiateAcquisition', vi);
if status < 0, error('Initiate failed: %d', status); end
fprintf('Acquisition started...\n');

%% 8. Poll for Completion
acqStatusPtr = libpointer('int32Ptr', 0); 
tStart = tic;
while true
    calllib('niscope', 'niScope_AcquisitionStatus', vi, acqStatusPtr);
    if acqStatusPtr.Value == 1, break; end
    if toc(tStart) > timeout, error('Acquisition timed out.'); end
    pause(0.01);
end

%% 9. Determine Buffer Size
recLenPtr = libpointer('int32Ptr', 0);
calllib('niscope', 'niScope_ActualRecordLength', vi, recLenPtr);
actualPoints = recLenPtr.Value;
fprintf('Actual Record Length: %d points\n', actualPoints);

%% ==========================================================
%% ==========================================================
%% ==========================================================
%% 10. NEW: Fetch Binary (Raw Data Only)
%% ==========================================================
fprintf('Attempting Binary Fetch (Int16 - Raw)...\n');

% A. Prepare Int16 Buffer
% Allocate exactly what we need (plus small safety padding)
bufferSize = actualPoints + 16; 
rawArray   = zeros(1, bufferSize, 'int16'); 
rawPtr     = libpointer('int16Ptr', rawArray);

% B. Fetch Binary Data
% We pass [] (NULL) for the wfmInfo struct to keep it fast/safe.
status = calllib('niscope', 'niScope_FetchBinary16', ...
    vi, ...             
    chanNamePtr, ...    
    timeout, ...        
    actualPoints, ...   
    rawPtr, ...         
    []); % Pass NULL for struct

if status < 0
    errBuf = libpointer('int8Ptr', zeros(1, 1024, 'int8'));
    calllib('niscope', 'niScope_GetErrorMessage', vi, status, 1024, errBuf);
    error('FetchBinary16 failed: %s', char(errBuf.Value(errBuf.Value~=0)));
end
fprintf('Binary Fetch Successful!\n');

% C. Extract Raw Data
% We do NOT convert to Volts. We just take the raw integers.
rawCodes = rawPtr.Value(1:actualPoints); 

% D. Reconstruct Time Vector
dt = 1/sampleRate;
xData = (0:length(rawCodes)-1) * dt;

%% 11. Plot Raw Data
figure;
plot(xData, rawCodes);
title(['Channel ' chanStr ' Raw ADC Codes']);
xlabel('Time (s)');
ylabel('Raw ADC Value (Int16)');
grid on;

% Note: The Y-axis will now show integers (e.g., -8192 to +8191 for 14-bit)
% instead of Volts.

%% 12. Close Session
if exist('vi', 'var')
    calllib('niscope', 'niScope_close', vi);
    clear vi;
    fprintf('Session Closed.\n');
end