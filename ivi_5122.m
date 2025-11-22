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
recordLength   = 1000;       % Points PER RECORD
refPosition    = 50.0;       % Reference position (% of record)
numRecords     = 3;          % <<< 3 segments
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
triggerSource = channelID;    % e.g. "0"
triggerLevel  = 0.0;          % Volts

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

try
    % Start from record 0, fetch 3 records at once
    %% Multi-record fetch setup
    NISCOPE_ATTR_FETCH_RECORD_NUMBER = 1150082;   % attribute ID from NI manual
    NISCOPE_ATTR_FETCH_NUM_RECORDS   = 1150083;

    % Start from record 0
    setAttributeViInt32(niScopeDev, "", NISCOPE_ATTR_FETCH_RECORD_NUMBER, 0);

    % Fetch 3 records
    setAttributeViInt32(niScopeDev, "", NISCOPE_ATTR_FETCH_NUM_RECORDS, 3);

    % Then fetch normally
    [wfm, info] = niScopeDev.fetch(channelID, timeout_ms, recordLength);

    % Reshape: each record is recordLength long
    wfmMat = reshape(wfm, recordLength, 3);


    [waveformArray, waveformInfo] = niScopeDev.fetch(channelID, timeout_ms, recordLength);

    % waveformArray is 1D: [Rec0(1..N), Rec1(1..N), Rec2(1..N)]
    if isfield(waveformInfo, 'actualSamples')
        N = double(waveformInfo(1).actualSamples);   % points per record
    else
        N = recordLength;
    end

    % Reshape into N x numRecords
    wfmMat = reshape(waveformArray, N, []);   % each column = one segment

    % Build time axis
    if isfield(waveformInfo(1), 'xIncrement')
        dt = waveformInfo(1).xIncrement;
    else
        dt = 1 / sampleRate;
    end

    if isfield(waveformInfo(1), 'xOrigin')
        t0 = waveformInfo(1).xOrigin;
    else
        t0 = 0;
    end

    t = t0 + (0:N-1) * dt;

    figure;
    plot(t, wfmMat);
    grid on;
    xlabel('Time (s)');
    ylabel('Voltage (V)');
    legend(arrayfun(@(k) sprintf('Record %d', k), 0:numRecords-1, 'UniformOutput', false));
    title(sprintf('Channel %s, %d records (edge-triggered)', channelID, numRecords));

catch ME
    warning("OPTION A fetch-all-records failed: %s\nTrying OPTION B (looped fetch)...", ME.message);

    %% ========= OPTION B: Fetch ONE record at a time in a loop =========
    % This does NOT rely on FetchNumRecords property; we only change FetchRecordNumber.
    % Some ividev wrappers expose attributes via set/ getAttribute methods instead.

    wfmMat = zeros(recordLength, numRecords);
    infoCell = cell(1, numRecords);

    for k = 0:numRecords-1
        % Set which record to fetch
        niScopeDev.FetchRecordNumber = k;   % zero-based
        niScopeDev.FetchNumRecords   = 1;   % only 1 record

        [wfm_k, info_k] = niScopeDev.fetch(channelID, timeout_ms, recordLength);

        if isfield(info_k, 'actualSamples')
            Nk = double(info_k.actualSamples);
        else
            Nk = numel(wfm_k);
        end

        wfmMat(1:Nk, k+1) = wfm_k(1:Nk);
        infoCell{k+1} = info_k;
    end

    % Use info from first record to build time axis
    info0 = infoCell{1};
    if isfield(info0, 'xIncrement')
        dt = info0.xIncrement;
    else
        dt = 1 / sampleRate;
    end

    if isfield(info0, 'xOrigin')
        t0 = info0.xOrigin;
    else
        t0 = 0;
    end

    N = recordLength;
    t = t0 + (0:N-1) * dt;

    figure;
    plot(t, wfmMat);
    grid on;
    xlabel('Time (s)');
    ylabel('Voltage (V)');
    legend(arrayfun(@(k) sprintf('Record %d', k), 0:numRecords-1, 'UniformOutput', false));
    title(sprintf('Channel %s, %d records (edge-triggered, looped fetch)', channelID, numRecords));
end

%% Scalar measurement (e.g., RMS = 4, or MEAN = 3)
% Measurement enum: 0 Vpp, 1 Max, 2 Min, 3 Mean, 4 RMS, ...
measRMS = niScopeDev.fetchWaveformMeasurement(channelID, 4);
fprintf('RMS (record 0) = %.6f V\n', measRMS);

%% 9. Clean up
clear niScopeDev;
