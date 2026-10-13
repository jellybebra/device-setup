import argparse,ctypes,datetime,json,subprocess,time,sys
from pathlib import Path
parser=argparse.ArgumentParser(description='Bounded 40-second STUN capture with 12 normal-priority CPU workers for 20 seconds; Windows admin required.')
parser.add_argument('--output-directory',type=Path,required=True)
parser.add_argument('--physical-interface',type=int,required=True)
parser.add_argument('--source-ip',required=True)
parser.add_argument('--dll',type=Path,required=True)
args=parser.parse_args()
root=args.output_directory.resolve();root.mkdir(parents=True,exist_ok=False)
python=sys.executable
repo=Path(__file__).resolve().parent.parent
k=ctypes.windll.kernel32;k.GetCurrentProcess.restype=ctypes.c_void_p;k.SetPriorityClass.argtypes=[ctypes.c_void_p,ctypes.c_ulong]
if not ctypes.windll.shell32.IsUserAnAdmin():raise SystemExit('Run elevated for passive capture.')
if not k.SetPriorityClass(k.GetCurrentProcess(),0x8000):raise ctypes.WinError()
procs=[]
def phase(name):
 with (root/'phases.jsonl').open('a') as f:f.write(json.dumps({'at':datetime.datetime.now().astimezone().isoformat(),'phase':name})+'\n')
try:
 cap=subprocess.Popen([python,str(repo/'experiments/capture-tun-udp.py'),'--seconds','40','--game-port','1','--dll',str(args.dll.resolve()),'--output-directory',str(root)],creationflags=0x08000000);procs.append(cap)
 log=(root/'monitor.log').open('w')
 meter=subprocess.Popen([python,str(repo/'experiments/monitor-tun-latency.py'),'--seconds','40','--above-normal','--without-controller','--physical-interface',str(args.physical_interface),'--source-ip',args.source_ip,'--output-directory',str(root)],stdout=log,stderr=log,creationflags=0x08000000);procs.append(meter)
 phase('idle-before');time.sleep(8)
 worker="import ctypes,time; k=ctypes.windll.kernel32; k.GetCurrentProcess.restype=ctypes.c_void_p; k.SetPriorityClass.argtypes=[ctypes.c_void_p,ctypes.c_ulong]; k.SetPriorityClass(k.GetCurrentProcess(),0x20); end=time.monotonic()+20; n=0\nwhile time.monotonic()<end: n=(n+1)%1000000"
 phase('cpu-load-starting')
 loads=[]
 for _ in range(12):
  child=subprocess.Popen([python,'-c',worker],creationflags=0x08000000);loads.append(child);procs.append(child)
 for p in loads:p.wait(timeout=30)
 phase('idle-after')
 cap.wait(timeout=30);meter.wait(timeout=30)
finally:
 for p in procs:
  if p.poll() is None:p.terminate();p.wait(timeout=5)
 if 'log' in globals():log.close()
