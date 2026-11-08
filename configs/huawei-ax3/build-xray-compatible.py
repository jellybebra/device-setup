#!/usr/bin/env python3
"""Build Xray ARM soft-float with a Go wakeup-pipe fallback for Huawei kernels.

The firmware omits CONFIG_EVENTFD. Stock Go 1.27 aborts before Xray starts.
Use a build overlay so neither the shared Go installation nor Xray is modified.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess

p = argparse.ArgumentParser(description=__doc__)
p.add_argument("--source", type=Path, required=True)
p.add_argument("--work", type=Path, required=True)
p.add_argument("--output", type=Path, required=True)
a = p.parse_args()
env = dict(os.environ, GOTOOLCHAIN="go1.27.3", CGO_ENABLED="0", GOOS="linux", GOARCH="arm", GOARM="5")
downloaded = Path(subprocess.check_output(["go", "env", "GOROOT"], env=env, text=True).strip())
# Go forbids overlays within GOMODCACHE, including downloaded toolchains.
root = a.work.resolve() / "go1.27.3"
if not root.exists():
    shutil.copytree(downloaded, root)
env.update(GOROOT=str(root), GOTOOLCHAIN="local")
original = root / "src/runtime/netpoll_epoll.go"
source = original.read_text()

def replace_once(old, new):
    global source
    if source.count(old) != 1:
        raise RuntimeError("Go runtime differs from the reviewed version: " + old)
    source = source.replace(old, new, 1)

replace_once("var (\n", "var (\n\tnetpollWakeWriteFd uintptr // eventfd or the write end of the fallback pipe\n")
replace_once(
    "\tefd, errno := linux.Eventfd(0, linux.EFD_CLOEXEC|linux.EFD_NONBLOCK)\n",
    "\tefd, errno := linux.Eventfd(0, linux.EFD_CLOEXEC|linux.EFD_NONBLOCK)\n"
    "\twfd := efd\n"
    "\tif errno == _ENOSYS {\n"
    "\t\t// Huawei's kernel has epoll and pipe2 but no eventfd.\n"
    "\t\t// netpollWakeSig permits one pending, atomic 8-byte wakeup.\n"
    "\t\tvar pipeErr int32\n"
    "\t\tefd, wfd, pipeErr = pipe2(_O_CLOEXEC | _O_NONBLOCK)\n"
    "\t\tif pipeErr != 0 {\n"
    "\t\t\tprintln(\"runtime: wakeup pipe failed with\", pipeErr)\n"
    "\t\t\tthrow(\"runtime: wakeup pipe failed\")\n"
    "\t\t}\n"
    "\t\terrno = 0\n"
    "\t}\n",
)
replace_once("\tnetpollEventFd = uintptr(efd)\n", "\tnetpollEventFd = uintptr(efd)\n\tnetpollWakeWriteFd = uintptr(wfd)\n")
replace_once("fd == netpollEventFd\n", "fd == netpollEventFd || fd == netpollWakeWriteFd\n")
replace_once("write(netpollEventFd,", "write(netpollWakeWriteFd,")
a.work.mkdir(parents=True, exist_ok=True)
patched = a.work.resolve() / "netpoll_epoll.go"
patched.write_text(source)
overlay = a.work.resolve() / "overlay.json"
overlay.write_text(json.dumps({"Replace": {str(original): str(patched)}}))
subprocess.run([str(root / "bin/go"), "build", "-p", "4", "-overlay", str(overlay), "-trimpath", "-ldflags=-s -w", "-o", str(a.output.resolve()), "./main"], cwd=a.source.resolve(), env=env, check=True)
