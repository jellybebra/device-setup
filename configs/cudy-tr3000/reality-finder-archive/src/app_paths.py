"""One per-user installation and state location, independent of the launcher."""
from __future__ import annotations
import ctypes, os, pathlib, uuid, sys
from dataclasses import dataclass

def local_appdata():
    if os.name == 'nt':
        # FOLDERID_LocalAppData, KF_FLAG_NO_PACKAGE_REDIRECTION: a launch from a
        # packaged terminal must not select that terminal's private app folder.
        folder = (ctypes.c_ubyte * 16).from_buffer_copy(uuid.UUID('f1b32785-6fba-4fcf-9d55-7b8e7f157091').bytes_le)
        shell = ctypes.WinDLL('shell32'); ole = ctypes.WinDLL('ole32')
        shell.SHGetKnownFolderPath.argtypes = [ctypes.c_void_p, ctypes.c_uint32, ctypes.c_void_p, ctypes.POINTER(ctypes.c_void_p)]
        shell.SHGetKnownFolderPath.restype = ctypes.c_long
        ole.CoTaskMemFree.argtypes = [ctypes.c_void_p]
        pointer = ctypes.c_void_p()
        result = shell.SHGetKnownFolderPath(ctypes.byref(folder), 0x00010000, None, ctypes.byref(pointer))
        if result != 0: raise OSError(f'LocalAppData lookup failed: {result:#x}')
        try: return pathlib.Path(ctypes.wstring_at(pointer))
        finally: ole.CoTaskMemFree(pointer)
    if sys.platform == 'darwin': return pathlib.Path.home() / 'Library' / 'Application Support'
    return pathlib.Path(os.environ.get('LOCALAPPDATA', pathlib.Path.home() / '.local' / 'share'))

@dataclass(frozen=True)
class AppPaths:
    root: pathlib.Path
    @property
    def executable(self):
        return (self.root / 'RealityFinder.exe') if os.name == 'nt' else pathlib.Path(sys.executable)
    @property
    def data(self): return self.root / 'data'
    @property
    def logs(self): return self.root / 'logs'
    @property
    def backups(self): return self.root / 'backups'

def paths(): return AppPaths(local_appdata() / 'RealityFinder')

def logs_for(data):
    data = pathlib.Path(data)
    return paths().logs if data.resolve() == paths().data.resolve() else data / 'logs'
