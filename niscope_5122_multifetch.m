%% NI-SCOPE High-Speed Multi-Record Acquisition
%  Optimization: Hard Cleanup + Explicit Reset + Circular Buffer
%  Hardware: NI PXI-5122 (and compatible)

%% 0. Hard Cleanup (Crucial for Speed on Repeat Runs)
% This block forces MATLAB to release "zombie" driver handles and
% fragmented memory from previous runs.
try
    % Find any open sessions in the workspace and close them
    cleanVars = who;
    for i = 1:length(cleanVars)
        val = eval(cleanVars{i});
        if isa(val, 'uint32') && val > 0
            % Attempt to close if it looks like a session handle
            try calllib('niscope', 'niScope_close', val); catch, end
        end
    end
catch
end

% Clear workspace and force library unload
clear; clc; close all;
if libisloaded('niscope')
    unloadlibrary('niscope');
    fprintf('System cleaned. Ready for fresh acquisition.\n');
end

%% 1. Configuration Parameters
devNameStr   = 'DEV4';
chanStr      = '0';
vRange       = 1.0;        % Max 5V for 50 Ohm on 5122
sampleRate   = 100e6;      % 100 MS/s
minRecord    = 100;       % Points per record
numRecords   = 10000;       % Total records
timeout      = 5.0;        % Timeout per record

% Attribute IDs
NISCOPE_ATTR_FETCH_RECORD_NUMBER    = 1150079;
NISCOPE_ATTR_FETCH_NUM_RECORDS      = 1150080;
NISCOPE_ATTR_ALLOW_MORE_RECORDS_THAN_MEMORY = 1150068;

%% 2. Load and Sanitize Driver
dllPath     = 'C:\Program Files\IVI Foundation\IVI\Bin\niScope_64.dll';
sysHeadPath = 'C:\Program Files\IVI Foundation\IVI\Include\niScope.h';
incDir      = 'C:\Program Files\IVI Foundation\IVI\Include';
localHead   = 'niScope_matlab.h';
protoFile   = 'niscope_proto.m';

if ~exist(localHead, 'file')
    fprintf('Sanitizing NI-SCOPE header...\n');
    txt = fileread(sysHeadPath);
    txt = strrep(txt, '__fastcall', '');
    txt = strrep(txt, '_VI_FUNC', '');
    txt = strrep(txt, '_VI_FAR', '');
    fid = fopen(localHead, 'w'); fwrite(fid, txt); fclose(fid);
end

try
    loadlibrary(dllPath, localHead, 'alias', 'niscope', 'includepath', incDir, 'mfilename', protoFile);
catch ME
    error('Library Load Error: %s', ME.message);
end
% Or print them to the command window:
m = libfunctions('niscope', '-full');
disp(m);

%% 3. Initialize Session & Reset
viPtr = libpointer('uint32Ptr', 0);
devPtr = libpointer('int8Ptr', [int8(devNameStr) 0]);
chk(calllib('niscope', 'niScope_init', devPtr, 1, 1, viPtr));
vi = viPtr.Value;
fprintf('Session Initialized. Handle: %d\n', vi);

% --- EXPLICIT RESET ADDED HERE ---
% [cite_start]% Resets the device to default state (clears caches/buffers) [cite: 2376]
% chk(calllib('niscope', 'niScope_reset', vi));
% fprintf('Device Reset Successful.\n');

% Register cleanup (Safety net)
cleanupObj = onCleanup(@() calllib('niscope', 'niScope_close', vi));

%% 4. Configure Vertical & Horizontal
chanPtr = libpointer('int8Ptr', [int8(chanStr) 0]);
nullPtr = libpointer('int8Ptr', 0); % For Session Attributes
trigSrcPtr = libpointer('int8Ptr', [int8('TRIG') 0]);


% Vertical (50 Ohm, 5V Range)
chk(calllib('niscope', 'niScope_ConfigureVertical', vi, chanPtr, vRange, 0.0, int32(1), 1.0, uint16(1)));
chk(calllib('niscope', 'niScope_ConfigureChanCharacteristics', vi, chanPtr, 50.0, 0.0));

% Horizontal (Multi-Record)
chk(calllib('niscope', 'niScope_ConfigureHorizontalTiming', ...
    vi, sampleRate, int32(minRecord), 0.0, int32(numRecords), uint16(1)));

% Trigger (Edge - Channel 0)
chk(calllib('niscope', 'niScope_ConfigureTriggerEdge', ...
    vi, trigSrcPtr, 0.2, int32(1), int32(1), 0.0, 0.0));

%% 5. Advanced Memory Configuration (Set & Verify)
totalBytes = double(numRecords) * double(minRecord) * 2;
onboardMemory = 3.125 * 1024 * 1024; % Simulated 8MB limit

if totalBytes > onboardMemory
    fprintf('Large Acquisition. Enabling Circular Buffer.\n');
    enableMore = 1;
else
    enableMore = 0;
end

try
    % 1. SET the Attribute
    chk(calllib('niscope', 'niScope_SetAttributeViBoolean', ...
        vi, nullPtr, NISCOPE_ATTR_ALLOW_MORE_RECORDS_THAN_MEMORY, enableMore));

    % 2. READ it back to verify
    actualValPtr = libpointer('uint16Ptr', 0); % ViBoolean is uint16
    chk(calllib('niscope', 'niScope_GetAttributeViBoolean', ...
        vi, nullPtr, NISCOPE_ATTR_ALLOW_MORE_RECORDS_THAN_MEMORY, actualValPtr));

    % 3. Display Result
    fprintf('Attribute Verification: Requested=%d, Actual=%d\n', ...
        enableMore, actualValPtr.Value);

catch ME
    fprintf('Warning: Could not set/read memory attribute. Reason: %s\n', ME.message);
end

% Ensure we fetch ALL records (-1)
chk(calllib('niscope', 'niScope_SetAttributeViInt32', ...
    vi, nullPtr, NISCOPE_ATTR_FETCH_NUM_RECORDS, 1));

%% 6. Initiate Acquisition
% Starts hardware. Driver immediately begins capturing triggers to onboard RAM.
fprintf('Initiating acquisition of %d records...\n', numRecords);
chk(calllib('niscope', 'niScope_InitiateAcquisition', vi));

%% 7. Optimized 16-bit Binary Fetch Loop
% Ref: NI-SCOPE Manual Pg 199 "Retrieving Data... Fetching binary data saves time"

% 1. Get Record Length
recLenPtr = libpointer('int32Ptr', 0);
chk(calllib('niscope', 'niScope_ActualRecordLength', vi, recLenPtr));
recPts = recLenPtr.Value;

% 2. Allocate BINARY Buffers (int16)
% "Uses significantly less memory (2 bytes instead of 8 bytes per sample)"
wfmPtr = libpointer('int16Ptr', zeros(1, recPts, 'int16'));

% We MUST fetch the wfmInfo struct to get the Gain/Offset for scaling later [cite: 2466]
infoStruct = libstruct('niScope_wfmInfo');
infoPtr = libpointer('niScope_wfmInfoPtr', []);

% Pre-allocate storage matrix as INT16 (Saves 4x RAM in MATLAB too)
allData_Raw = zeros(numRecords, recPts, 'int16');
scalingFactors = zeros(numRecords, 2); % To store [Gain, Offset] for each record

fprintf('Entering 16-bit Fetch Loop (Buffer: %d pts)\n', recPts);
t0 = tic;

for i = 0 : (numRecords - 1)
    % A. Select Record
    chk(calllib('niscope', 'niScope_SetAttributeViInt32', ...
        vi, nullPtr, NISCOPE_ATTR_FETCH_RECORD_NUMBER, i));

    % B. Fetch Binary16 [cite: 2461]
    status = calllib('niscope', 'niScope_FetchBinary16', ...
        vi, chanPtr, timeout, recPts, wfmPtr, infoPtr);

    if status < 0
        errBuf = libpointer('int8Ptr', zeros(1, 1024, 'int8'));
        calllib('niscope', 'niScope_GetErrorMessage', vi, status, 1024, errBuf);
        error('Fetch Error (Rec %d): %s', i, char(errBuf.Value(errBuf.Value~=0)));
    end

    % C. Store Raw Integers
    allData_Raw(i+1, :) = wfmPtr.Value(1:recPts);

    % D. Store Scaling Factors (Gain/Offset) [cite: 2466]
    % infoPtr.Value is the struct containing .gain and .offset
    % info = infoPtr.Value;
    % scalingFactors(i+1, 1) = info.gain;
    % scalingFactors(i+1, 2) = info.offset;
    %
    if mod(i, 1000) == 0
        fprintf('Fetched %d / %d records...\n', i, numRecords);
    end
end
dt = toc(t0);
fprintf('Completed %d records in %.2f seconds (%.1f Recs/sec).\n', ...
    numRecords, dt, numRecords/dt);

%% 8. Visualization (Voltage vs Time)
% Extract scaling info from the LAST fetch (valid for all records in this config)
finalInfo = infoPtr.Value;

% Read parameters from the struct
gain       = finalInfo.gain;
offset     = finalInfo.offset;
xIncrement = finalInfo.xIncrement;

fprintf('Scaling Applied: Gain=%.4e, Offset=%.4e, dt=%.4e\n', gain, offset, xIncrement);

% 1. Create Time Vector
% Time = Index * xIncrement
timeVector = double(0 : recPts - 1) * xIncrement;

% 2. Convert Raw Data to Voltage
% Voltage = (Binary * Gain) + Offset
allData_Volts = (double(allData_Raw) .* gain) + offset;

% 3. Plot
figure('Color', 'w');
plot(timeVector, allData_Volts'); % Transpose so Time is X-axis
grid on;
title(sprintf('Voltage vs Time (%d Records)', numRecords));
xlabel('Time (s)');
ylabel('Voltage (V)');

% Optional: Plot Average
hold on;
plot(timeVector, mean(allData_Volts, 1), 'k', 'LineWidth', 2);
legend('Individual Records', 'Average');
%% 9. Helper Function
function chk(status)
if status < 0
    error('NI-SCOPE Error: %d', status);
end
end