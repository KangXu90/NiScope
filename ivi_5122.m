%% ============================================================
%  NI-SCOPE MATLAB Instrument Control Toolbox Example
%  Acquire waveform using the high-level IVI interface.
%  (Single-channel example, using existing connection code)
% ============================================================
clc; clear;

% --- Configuration Parameters ---
driverName   = 'niScope';
resourceName = 'DEV1';    % <<< 确保和 NI MAX 里的设备名一致, 如 'Dev1'
channelID    = '0';       % 采集通道 (字符串形式，如 '0' 或 '0,1')
maxRangeV    = 10.0;      % 垂直量程 (Volts)
verticalOffset = 0.0;     % 垂直偏移 (Volts)
sampleRate   = 1e6;     % 采样率 (Samples/second)
recordLength = 500;     % 采集点数
refPosition  = 50.0;      % 水平参考位置 (% of record length)
minRecordTime = recordLength / sampleRate;   % 最小记录时间 (秒)
numRecords   = 1;         % 记录数 (通常 1 即可)
timeout_s    = 5.0;       % 超时时间 (秒)

%% 1. Connect to the Instrument
try
    % 你这部分已经验证能连上，我保持不变
    niScopeDev = ividev(driverName, resourceName);  % 实机，不用 Simulate 参数
    fprintf('Successfully connected to NI Digitizer: %s\n', niScopeDev.Model);
catch ME
    error('Could not connect to instrument. Check resource name and driver installation. MATLAB Error: %s', ME.message);
end

%% 2. Basic Reset & Auto-Setup (可选，但推荐)
try
    reset(niScopeDev);      % 复位
    autoSetup(niScopeDev);  % 如果你希望先让设备自动找个合理配置，可以打开这一行
catch 
    warning('Reset/autoSetup failed or unsupported: %s');
end

%% 3. Configure Vertical (垂直设置)
% coupling: 'DC' / 'AC' / 'GND' 等，probe attenuation 通常 1
coupling          = 'DC';
probeAttenuation  = 1.0;
channelEnabled    = true;

configureVertical(niScopeDev, channelID, maxRangeV, verticalOffset, ...
                  coupling, probeAttenuation, channelEnabled);

%% 4. Configure Horizontal Timing (采样率 & 记录长度)
% samplerate = niScopeDev.sampleRate;
%  enforceRealtime = true;
% % % configureHorizontalTiming(obj, sampleRate, minRecordTime, refPosition, numRecords)
%  configureHorizontalTiming(niScopeDev, sampleRate, minRecordTime, ...
%                           refPosition, numRecords, enforceRealtime);

%% 5. Configure Trigger (这里用 Immediate Trigger，最简单)
% 你也可以改成 configureTriggerEdge 来用边沿触发
% try
%     % 立即触发（不等触发事件，直接开始采集）
%     configureTriggerImmediate(niScopeDev);
% catch
%     % 如果你的 driver 版本不支持这个函数，可以用简单 edge trigger 代替：
%     % configureTriggerEdge(niScopeDev, channelID, 0.0, 'Rising', 0.0, true);
%     warning('Immediate trigger configuration failed, check available trigger functions for your driver.');
% end

%% 6. Initiate Acquisition
initiateAcquisition(niScopeDev);

% samplerateafterConfig = niScopeDev.sampleRate;
%% 7. Fetch Waveform
% 注意：某些版本是 fetchWaveform，某些是 fetch，取决于 driver wrapper。
% 你可以先用 "methods(niScopeDev)" 查一下支持的函数名。
%
% 这里先用 fetch(niScopeDev, channelID, timeout_ms, numSamples)
% timeout 以毫秒计
timeout_ms = timeout_s * 1000;

try
    [waveformArray, waveformInfo] = niScopeDev.fetch(channelID, timeout_ms, recordLength);
catch ME
    % 如果上面这一句报 “Undefined function or method 'fetch' ...”
    % 试试下面的写法 (旧版本例子里叫 fetchWaveform)
    try
        [waveformArray, waveformInfo] = fetchWaveform(niScopeDev, channelID, timeout_ms, recordLength);
    catch ME2
        % 两个都不行就直接报错，把 message 打出来
        disp(ME.message);
        error('Neither fetch nor fetchWaveform is available. Check your NI-SCOPE driver/MATLAB example version. Error: %s', ME2.message);
    end
end
 % measFunction = NISCOPE_VAL_MEAS_MEAN;
   measurement =  niScopeDev.fetchWaveformMeasurement(channelID,4);
%% 8. Build Time Axis and Plot
% waveformInfo 里通常包含：
%   actualSamples   实际采集点数
%   xIncrement      相邻两点的时间间隔
%   xOrigin         起始时间
if isfield(waveformInfo, 'actualSamples')
    N = double(waveformInfo.actualSamples);
else
    N = numel(waveformArray);
end

if isfield(waveformInfo, 'xIncrement')
    dt = waveformInfo.xIncrement;
else
    dt = 1 / sampleRate;    % fallback
end

if isfield(waveformInfo, 'xOrigin')
    t0 = waveformInfo.xOrigin;
else
    t0 = 0;
end

t = t0 + (0:N-1) * dt;

figure;
plot(t, waveformArray);
grid on;
xlabel('Time (s)');
ylabel('Voltage (V)');
title(sprintf('NI-SCOPE Waveform (Channel %s)', channelID));

%% 9. Clean up
clear niScopeDev;
