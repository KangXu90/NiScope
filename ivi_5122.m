%% ============================================================
%  NI-SCOPE MATLAB Instrument Control Toolbox Example
%  Multi-record (3 segments) acquisition with edge trigger
%  and multi-fetch using ividev.niScope
% ============================================================
clc; clear;

% --- Configuration Parameters ---
driverName     = 'niScope';
resourceName   = 'DEV1';     % Must match NI MAX, e.g. 'Dev1'
channelID      = '0';        % Channel to acquire (string, e.g., '0' or '0,1')
maxRangeV      = 10.0;       % Vertical range (Volts)
verticalOffset = 0.0;        % Vertical offset (Volts)
sampleRate     = 100e6;      % Sample rate (Samples/second)
recordLength   = 100;       % Points PER RECORD
refPosition    = 50.0;       % Reference position (% of record)
numRecords     = 10;          % <<< 3 segments
timeout_s      = 5.0;        % Timeout in seconds

%% 1. Connect to the Instrument
try
    niScopeDev = ividev(driverName, resourceName);  % Real device
    fprintf('Successfully connected to NI Digitizer: %s\n', niScopeDev.Model);
catch ME
    error('Could not connect to instrument. Check resource name and driver installation. MATLAB Error: %s', ME.message);
end

%% 2. Basic Reset & Auto-Setup (optional)
try
       reset(niScopeDev);
catch ME
    warning('Reset/autoSetup failed or unsupported: %s', ME.message);
end
%% 3. Configure channel Characteristics
inputImpedance = 50; % 50 ohm input impedance
maxInputFrequency = 0; % filter bandwidth at input 0 means default

configureChanCharacteristics(niScopeDev,channelID,inputImpedance,maxInputFrequency);

%% 3. Configure Vertical (垂直设置)
coupling         = 'DC';
probeAttenuation = 1.0;
channelEnabled   = true;

configureVertical(niScopeDev, channelID, maxRangeV, verticalOffset, ...
                  coupling, probeAttenuation, channelEnabled);

%% 4. Configure Horizontal Timing (采样率 & 多记录)
% NOTE: second arg is minNumPts (recordLength), not time.
enforceRealtime = true;
configureHorizontalTiming(niScopeDev, ...
                          sampleRate, ...   % minSampleRate
                          recordLength, ... % minNumPts per record
                          refPosition, ...
                          numRecords, ...   % <<< multi-record
                          enforceRealtime);

configuredsampleRate  = niScopeDev.sampleRate;
fprintf("Actual sample rate = %.3f MS/s\n", configuredsampleRate/1e6);
fprintf("Num records configured = %d\n", numRecords);

%% 5. Configure Edge Trigger
triggerSource = 'TRIG';    % e.g. "0",'1'.'TRIG'
triggerLevel  = 1;          % Volts

% Enums from ividev (check with 'enumeration' if needed)
triggerSlope    = 1;   % rising edge
triggerCoupling = 1;  % AC = 0; DC =1

holdoff = 0.0;   % seconds
delay   = 0.0;   % seconds

configureTriggerEdge(niScopeDev, triggerSource, triggerLevel, ...
                     triggerSlope, triggerCoupling, holdoff, delay);


%% 6. Initiate Acquisition (wait for 3 triggers, one per record)
initiateAcquisition(niScopeDev);

timeout_ms = timeout_s * 1000;

%% ========= OPTION A: Fetch ALL 3 records in ONE call =========
% Use FetchRecordNumber / FetchNumRecords properties if they exist.
% (If they don't, you can skip to OPTION B below.)
%% ------ Attribute IDs from niScope.h ------
NISCOPE_ATTR_FETCH_RECORD_NUMBER = 1150079;
NISCOPE_ATTR_FETCH_NUM_RECORDS   = 1150080;
% NISCOPE_ATTR_ALLOW_MORE_RECORDS_THAN_MEMORY = 1150068;
% 
% setAttributeViBoolean(niScopeDev, "", ...
%     NISCOPE_ATTR_ALLOW_MORE_RECORDS_THAN_MEMORY, true);


%% ------ Loop through each record WANT: record = 0,1,2,... ------
wfmMat = zeros(recordLength, numRecords);
tCell  = cell(1, numRecords);

for k = 0:(numRecords-1)

    % -----------------------------------------
    % 1. Tell the digitizer which record to fetch
    % -----------------------------------------
    setAttributeViInt32(niScopeDev, "", ...
        NISCOPE_ATTR_FETCH_RECORD_NUMBER, k);

    % -----------------------------------------
    % 2. Tell the digitizer to fetch ONLY ONE record
    % -----------------------------------------
    setAttributeViInt32(niScopeDev, "", ...
        NISCOPE_ATTR_FETCH_NUM_RECORDS, 1);

    % Optional debug print
    currRec  = getAttributeViInt32(niScopeDev, "", NISCOPE_ATTR_FETCH_RECORD_NUMBER);
    currNRec = getAttributeViInt32(niScopeDev, "", NISCOPE_ATTR_FETCH_NUM_RECORDS);
    fprintf("Loop %d → FetchRecordNumber=%d  FetchNumRecords=%d\n", ...
        k, currRec, currNRec);

    % -----------------------------------------
    % 3. Actually fetch this record
    % -----------------------------------------
    [wfm_k, pts_k, t0_k, dt_k] = fetchWaveform(niScopeDev, channelID, recordLength);

    % -----------------------------------------
    % 4. Store waveform
    % -----------------------------------------
    wfmMat(1:pts_k, k+1) = wfm_k;

    % -----------------------------------------
    % 5. Build time axis for this record
    % -----------------------------------------
    tCell{k+1} = t0_k + (0:pts_k-1) * dt_k;
end

%% ------ Plot results ------
figure; hold on;
for k = 1:numRecords
    plot(tCell{k}, wfmMat(:,k), "DisplayName", sprintf("Record %d", k-1));
end
xlabel("Time (s)");
ylabel("Voltage (V)");
title("Multi-record acquisition using setAttributeViInt32 + fetchWaveform");
% legend;
grid on;


%% Scalar measurement (e.g., RMS = 4, or MEAN = 3)
% Measurement enum: 0 Vpp, 1 Max, 2 Min, 3 Mean, 4 RMS, ...
measRMS = niScopeDev.fetchWaveformMeasurement(channelID, 0);
fprintf('RMS (record 0) = %.6f V\n', measRMS);

%% 9. Clean up
clear niScopeDev;
