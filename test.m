% 0) Clean load
if libisloaded('niscope'); unloadlibrary('niscope'); end
loadlibrary('C:\Program Files\IVI Foundation\IVI\Bin\niScope_32.dll', ...
            'C:\Program Files\IVI Foundation\IVI\Include\niScope.h', ...
            'alias','niscope', ...
            'includepath','C:\Program Files\IVI Foundation\VISA\WinNT\Include');

% 1) Legacy NI-SCOPE uses the device NUMBER from MAX (Device 1 ? "1")
resourceStr = '1';                                % NOT 'Dev1' for 5112
resourcePtr = libpointer('int8Ptr',[int8(resourceStr) 0]);  % C string (null-terminated)

% 2) Exact types for the booleans
idQuery     = uint16(1);
resetDevice = uint16(0);   % or 1 for a full reset

% 3) ViSession* out (ulongPtr ? uint32Ptr for 32-bit DLL)
vi = libpointer('uint32Ptr',0);

% 4) Call
status = calllib('niscope','niScope_init',resourcePtr,idQuery,resetDevice,vi);

if status ~= 0
    error('niScope_init failed, status=%d',status);
else
    fprintf('OK. Session=0x%08X\n', vi.Value);
end
