"""Small OS boundary shared by the desktop, relay and acceptance harness."""
from __future__ import annotations

import contextlib
import hashlib
import json
import os
import pathlib
import plistlib
import signal
import subprocess
import sys
import tempfile
import threading

from app_paths import paths
from windows_runtime import startup_log, native_handoff, cleanup_native_launch


def spawn_options():
    return {'creationflags': 0x08000000} if os.name == 'nt' else {'start_new_session': True}


def physical_interfaces():
    if sys.platform.startswith('linux'):
        # BusyBox ip supports text output but not necessarily `ip -j`.
        try:
            result=subprocess.run(['ip','-4','route','show','default'],capture_output=True,text=True,timeout=3,check=True)
            names=[]
            for line in result.stdout.splitlines():
                fields=line.split()
                if 'dev' in fields:
                    name=fields[fields.index('dev')+1]
                    if name not in names:names.append(name)
            return names
        except (OSError,ValueError,IndexError,subprocess.SubprocessError):
            return []
    if os.name == 'nt':
        script = ('[Console]::OutputEncoding=[System.Text.UTF8Encoding]::new(); '
                  'Get-NetAdapter -Physical | Where-Object Status -eq "Up" | '
                  'Sort-Object InterfaceMetric | Select-Object -ExpandProperty Name | ConvertTo-Json -Compress')
        try:
            value = json.loads(subprocess.run(['powershell.exe', '-NoProfile', '-Command', script],
                capture_output=True, timeout=8, encoding='utf-8', **spawn_options()).stdout)
            return [value] if isinstance(value, str) else (value or [])
        except (OSError, ValueError, subprocess.SubprocessError):
            return []
    if sys.platform == 'darwin':
        try:
            text = subprocess.run(['/usr/sbin/networksetup', '-listallhardwareports'],
                                  capture_output=True, text=True, timeout=5).stdout
            names = [line.split(':', 1)[1].strip() for line in text.splitlines() if line.startswith('Device:')]
            result = []
            for name in names:
                info = subprocess.run(['/sbin/ifconfig', name], capture_output=True, text=True, timeout=3).stdout
                if 'status: active' in info and 'inet ' in info:
                    result.append(name)
            return result
        except (OSError, subprocess.SubprocessError):
            return []
    return []


def network_fingerprint(interface):
    """Bounded, local-only observation; ignores virtual/TUN adapters."""
    names = physical_interfaces()
    selected = (names[0] if names else None) if interface == 'auto' else interface if interface in names else None
    if not selected:
        return None, ()
    try:
        if os.name == 'nt':
            # The adapter name is data in an environment variable, never shell code.
            env = os.environ.copy(); env['RF_INTERFACE'] = selected
            script = ('Get-NetIPAddress -InterfaceAlias $env:RF_INTERFACE -AddressFamily IPv4 '
                      '-ErrorAction SilentlyContinue | Select-Object -ExpandProperty IPAddress | ConvertTo-Json -Compress')
            value = json.loads(subprocess.run(['powershell.exe', '-NoProfile', '-Command', script], env=env,
                capture_output=True, text=True, timeout=5, **spawn_options()).stdout)
            addresses = [value] if isinstance(value, str) else value or []
        elif sys.platform.startswith('linux'):
            text=subprocess.run(['ip','-4','addr','show','dev',selected],capture_output=True,text=True,timeout=3,check=True).stdout
            addresses=[line.split()[1].split('/')[0] for line in text.splitlines() if line.strip().startswith('inet ')]
        else:
            text = subprocess.run(['/sbin/ifconfig', selected], capture_output=True, text=True, timeout=3).stdout
            addresses = [line.split()[1] for line in text.splitlines() if line.strip().startswith('inet ')]
        return selected, tuple(sorted(addresses))
    except (OSError, ValueError, subprocess.SubprocessError):
        return selected, ()


if os.name == 'nt':
    from windows_runtime import Singleton, Job, install, autostart
else:
    class Singleton:
        def __init__(self, name):
            import fcntl
            digest = hashlib.sha256(name.encode()).hexdigest()[:24]
            folder = pathlib.Path.home() / 'Library' / 'Caches' / 'RealityFinder'
            folder.mkdir(parents=True, exist_ok=True)
            self.stream = (folder / (digest + '.lock')).open('a')
            try:
                fcntl.flock(self.stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except OSError:
                self.stream.close(); self.stream = None
                raise RuntimeError('Reality Finder уже работает. Откройте его через значок в меню.')

        def close(self):
            if self.stream:
                self.stream.close(); self.stream = None

    class Job:
        """Watchdog kills only registered process groups when the owner disappears."""
        def __init__(self):
            command = ([sys.executable, '--watch-processes'] if getattr(sys, 'frozen', False)
                       else [sys.executable, str(pathlib.Path(__file__).resolve()), '--watch-processes'])
            self.lock = threading.Lock()
            self.process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.DEVNULL,
                                            stderr=subprocess.DEVNULL, start_new_session=True, text=True)

        def assign(self, process):
            self._send('add', process.pid)

        def release(self, process):
            self._send('remove', process.pid)

        def _send(self, operation, pid):
            with self.lock:
                if self.process:
                    self.process.stdin.write(f'{operation} {pid}\n'); self.process.stdin.flush()

        def close(self):
            with self.lock:
                if self.process:
                    self.process.stdin.close()
                    try:
                        self.process.wait(5)
                    except subprocess.TimeoutExpired:
                        self.process.terminate(); self.process.wait(3)
                    self.process = None

    def install(source):
        raise RuntimeError('На macOS перенесите RealityFinder.app в Applications.')

    def autostart(enabled, executable=None):
        if sys.platform != 'darwin':
            raise RuntimeError('Автозапуск поддерживается на Windows и macOS')
        target = pathlib.Path.home() / 'Library' / 'LaunchAgents' / 'com.realityfinder.desktop.plist'
        if not enabled:
            target.unlink(missing_ok=True); return
        executable = pathlib.Path(executable or sys.executable).resolve()
        arguments=[str(executable),'--background']
        if not getattr(sys,'frozen',False):arguments.insert(1,str(pathlib.Path(__file__).resolve().with_name('app.py')))
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(plistlib.dumps({'Label': 'com.realityfinder.desktop',
            'ProgramArguments': arguments, 'RunAtLoad': True,
            'ProcessType': 'Interactive', 'ThrottleInterval': 30}))
        target.chmod(0o600)
        # launchd loads this file at the next login. bootout would terminate this
        # very application if it was originally started by the LaunchAgent.


def release_process(job, process):
    if job and hasattr(job, 'release'):
        with contextlib.suppress(OSError):
            job.release(process)


def watch_processes():
    groups = {}
    def birth(pid):
        # Guard against PID reuse if the owner dies before unregistering a child.
        if sys.platform.startswith('linux'):
            try:
                return pathlib.Path(f'/proc/{pid}/stat').read_text().rsplit(')',1)[1].split()[19]
            except (OSError,IndexError):
                return ''
        return subprocess.run(['/bin/ps', '-p', str(pid), '-o', 'lstart='],
                              capture_output=True, text=True, timeout=2).stdout.strip()
    try:
        for line in sys.stdin:
            action, value = line.split(); pid = int(value)
            if action == 'add':
                stamp = birth(pid)
                if stamp: groups[pid] = stamp
            elif action == 'remove':
                groups.pop(pid, None)
    finally:
        for pid, stamp in groups.items():
            with contextlib.suppress(OSError, subprocess.SubprocessError):
                if birth(pid) == stamp and os.getpgid(pid) == pid:
                    os.killpg(pid, signal.SIGKILL)


if __name__ == '__main__' and '--watch-processes' in sys.argv:
    watch_processes()
