"""Windows lifetime boundaries: singleton, child job and per-user installation."""
import ctypes, os, pathlib, shutil, sys
from ctypes import wintypes as w
from app_paths import paths

def packaged_process():
    if os.name!='nt':return False
    kernel=ctypes.WinDLL('kernel32')
    kernel.GetCurrentPackageFullName.argtypes=[ctypes.POINTER(w.UINT),w.LPWSTR]
    kernel.GetCurrentPackageFullName.restype=w.LONG
    length=w.UINT()
    result=kernel.GetCurrentPackageFullName(ctypes.byref(length),None)
    if result==15700:return False # APPMODEL_ERROR_NO_PACKAGE
    if result==122:return True # ERROR_INSUFFICIENT_BUFFER, package identity exists
    raise OSError(f'Package identity lookup failed: {result}')

def _native_task_script(script):
    import base64,subprocess
    encoded=base64.b64encode(script.encode('utf-16le')).decode('ascii')
    powershell=pathlib.Path(os.environ['WINDIR'])/'System32/WindowsPowerShell/v1.0/powershell.exe'
    result=subprocess.run([str(powershell),'-NoProfile','-NonInteractive','-WindowStyle','Hidden','-EncodedCommand',encoded],
        capture_output=True,timeout=20,creationflags=0x08000000)
    if result.returncode:raise RuntimeError('Не удалось запустить Reality Finder в обычной сессии Windows.')

def native_handoff(arguments):
    """MSIX file virtualization persists even with an unredirected Known Folder.

    A scheduler launch removes the inherited package identity; executable
    location alone must never split the state into the launcher's private VFS.
    """
    if not getattr(sys,'frozen',False) or not packaged_process():return False
    import subprocess,uuid
    token=uuid.uuid4().hex
    literal=lambda value:"'"+str(value).replace("'","''")+"'"
    executable=pathlib.Path(sys.executable).resolve()
    command=subprocess.list2cmdline([*arguments,'--native-launch',token])
    script="""$ErrorActionPreference='Stop'
$service=New-Object -ComObject Schedule.Service
$service.Connect()
$folder=$service.GetFolder('\\')
$sid=[System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$task=$service.NewTask(0)
$task.RegistrationInfo.Description='Reality Finder: native launch'
$task.Principal.UserId=$sid
$task.Principal.LogonType=3
$task.Principal.RunLevel=0
$task.Settings.DisallowStartIfOnBatteries=$false
$task.Settings.StopIfGoingOnBatteries=$false
$task.Settings.MultipleInstances=2
$task.Settings.ExecutionTimeLimit='PT0S'
$action=$task.Actions.Create(0)
"""
    script+=f'$action.Path={literal(executable)}\n$action.WorkingDirectory={literal(executable.parent)}\n$action.Arguments={literal(command)}\n'
    script+="$null=$folder.RegisterTaskDefinition('RealityFinder-Manual-'+$sid,$task,6,$null,$null,3).Run($null)\n"
    _native_task_script(script);return True

def cleanup_native_launch(token):
    import re
    if not token or not re.fullmatch('[0-9a-f]{32}',token):return
    script="""$ErrorActionPreference='Stop'
$service=New-Object -ComObject Schedule.Service
$service.Connect()
$folder=$service.GetFolder('\\')
$sid=[System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$name='RealityFinder-Manual-'+$sid
$existing=@($folder.GetTasks(0) | Where-Object Name -eq $name)
"""
    script+=f"if($existing.Count -and $existing[0].Definition.RegistrationInfo.Description -eq 'Reality Finder: native launch' -and $existing[0].Definition.Actions.Item(1).Arguments.EndsWith('--native-launch {token}')) {{$folder.DeleteTask($name,0)}}\n"
    _native_task_script(script)

class Singleton:
    def __init__(self,name):
        self.handle=None
        if os.name!='nt': return
        k=ctypes.WinDLL('kernel32',use_last_error=True)
        k.CreateMutexW.argtypes=[w.LPVOID,w.BOOL,w.LPCWSTR]; k.CreateMutexW.restype=w.HANDLE
        self.handle=k.CreateMutexW(None,False,'Local\\RealityFinder-'+name)
        if not self.handle: raise ctypes.WinError(ctypes.get_last_error())
        if ctypes.get_last_error()==183:
            self.close(); raise RuntimeError('Reality Finder уже работает. Откройте его через значок в трее.')
    def close(self):
        if self.handle:
            k=ctypes.WinDLL('kernel32',use_last_error=True); k.CloseHandle.argtypes=[w.HANDLE]
            k.CloseHandle(self.handle); self.handle=None

class Job:
    def __init__(self):
        self.handle=None
        if os.name!='nt': return
        class Basic(ctypes.Structure):
            _fields_=[('perprocess',ctypes.c_longlong),('perjob',ctypes.c_longlong),('flags',w.DWORD),
                ('min',ctypes.c_size_t),('max',ctypes.c_size_t),('active',w.DWORD),('affinity',ctypes.c_size_t),('priority',w.DWORD),('scheduling',w.DWORD)]
        class IO(ctypes.Structure): _fields_=[(n,ctypes.c_ulonglong) for n in ('ro','wo','oo','rb','wb','ob')]
        class Extended(ctypes.Structure):
            _fields_=[('basic',Basic),('io',IO),('processmemory',ctypes.c_size_t),('jobmemory',ctypes.c_size_t),('peakprocess',ctypes.c_size_t),('peakjob',ctypes.c_size_t)]
        self.k=ctypes.WinDLL('kernel32',use_last_error=True)
        self.k.CreateJobObjectW.argtypes=[w.LPVOID,w.LPCWSTR]; self.k.CreateJobObjectW.restype=w.HANDLE
        self.k.SetInformationJobObject.argtypes=[w.HANDLE,ctypes.c_int,w.LPVOID,w.DWORD]
        self.k.AssignProcessToJobObject.argtypes=[w.HANDLE,w.HANDLE]
        self.k.CloseHandle.argtypes=[w.HANDLE]
        self.handle=self.k.CreateJobObjectW(None,None)
        info=Extended(); info.basic.flags=0x2000 # JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
        if not self.handle or not self.k.SetInformationJobObject(self.handle,9,ctypes.byref(info),ctypes.sizeof(info)):
            self.close(); raise ctypes.WinError(ctypes.get_last_error())
    def assign(self,process):
        if self.handle and not self.k.AssignProcessToJobObject(self.handle,w.HANDLE(int(process._handle))):
            process.kill(); process.wait(); raise ctypes.WinError(ctypes.get_last_error())
    def close(self):
        if self.handle: self.k.CloseHandle(self.handle); self.handle=None

def install(source):
    target=paths().executable
    target.parent.mkdir(parents=True,exist_ok=True)
    if pathlib.Path(source).resolve()!=target.resolve(): shutil.copy2(source,target)
    return target

def autostart(enabled,executable=None):
    if os.name!='nt': return
    import base64, subprocess, winreg
    executable=pathlib.Path(executable or paths().executable).resolve()
    if enabled and not executable.is_file():
        raise RuntimeError('Для автозапуска установите Reality Finder командой Install.bat.')
    # Scheduler service registration bypasses the MSIX caller's virtual HKCU.
    # Interactive token keeps the tray and DPAPI in the signed-in user's session.
    literal=lambda value: "'"+str(value).replace("'","''")+"'"
    script="""$ErrorActionPreference='Stop'
$service=New-Object -ComObject Schedule.Service
$service.Connect()
$folder=$service.GetFolder('\\')
$sid=[System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$name='RealityFinder-'+$sid
"""
    if enabled:
        script+="""$task=$service.NewTask(0)
$task.RegistrationInfo.Description='Reality Finder: запуск при входе пользователя'
$task.Principal.UserId=$sid
$task.Principal.LogonType=3
$task.Principal.RunLevel=0
$task.Settings.StartWhenAvailable=$true
$task.Settings.DisallowStartIfOnBatteries=$false
$task.Settings.StopIfGoingOnBatteries=$false
$task.Settings.MultipleInstances=2
$task.Settings.ExecutionTimeLimit='PT0S'
$task.Settings.RestartCount=3
$task.Settings.RestartInterval='PT1M'
$trigger=$task.Triggers.Create(9)
$trigger.UserId=$sid
$trigger.Delay='PT15S'
$action=$task.Actions.Create(0)
"""
        script+=f"$action.Path={literal(executable)}\n$action.WorkingDirectory={literal(executable.parent)}\n"
        script+="$action.Arguments='--background'\n$null=$folder.RegisterTaskDefinition($name,$task,6,$null,$null,3)\n"
    else:
        script+="$existing=@($folder.GetTasks(0) | Where-Object Name -eq $name)\nif($existing.Count) {$folder.DeleteTask($name,0)}\n"
    encoded=base64.b64encode(script.encode('utf-16le')).decode('ascii')
    powershell=pathlib.Path(os.environ['WINDIR'])/'System32/WindowsPowerShell/v1.0/powershell.exe'
    result=subprocess.run([str(powershell),'-NoProfile','-NonInteractive','-WindowStyle','Hidden','-EncodedCommand',encoded],
        capture_output=True,timeout=20,creationflags=0x08000000)
    if result.returncode:
        raise RuntimeError('Не удалось настроить автозапуск в Планировщике Windows. Программа может работать вручную.')
    # Remove our previous Run entry only after successful scheduler registration.
    with winreg.CreateKey(winreg.HKEY_CURRENT_USER,r'Software\Microsoft\Windows\CurrentVersion\Run') as key:
        try: winreg.DeleteValue(key,'RealityFinder')
        except FileNotFoundError: pass

def startup_log(stage,error=None,directory=None):
    """Keep launch failures diagnosable even before SQLite/UI initialization."""
    import datetime, json
    try:
        directory=pathlib.Path(directory) if directory else paths().logs;directory.mkdir(parents=True,exist_ok=True)
        path=directory/'startup.jsonl'
        if path.exists() and path.stat().st_size>1048576: path.replace(directory/'startup.previous.jsonl')
        event={'at':datetime.datetime.now().astimezone().isoformat(),'pid':os.getpid(),'stage':stage}
        if error is not None:event['error']=str(error)
        with path.open('a',encoding='utf-8') as stream:stream.write(json.dumps(event,ensure_ascii=False)+'\n')
    except OSError: pass
