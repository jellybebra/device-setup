import socket,select,time,re,sys,json,secrets
class Console:
 def __init__(self):
  self.s=socket.create_connection(('192.168.3.1',23),timeout=4,source_address=('192.168.3.2',0));self.pending=b''
 def read(self,timeout=4):
  output=bytearray();end=time.monotonic()+timeout;last=None
  while time.monotonic()<end:
   r,_,_=select.select([self.s],[],[],.1)
   if not r:
    if last and time.monotonic()-last>.35:break
    continue
   b=self.s.recv(65536)
   if not b:break
   last=time.monotonic();b=self.pending+b;self.pending=b'';i=0
   while i<len(b):
    if b[i]!=255:output.append(b[i]);i+=1;continue
    if i+1>=len(b):self.pending=b[i:];break
    verb=b[i+1]
    if verb==255:output.append(255);i+=2;continue
    if verb in (251,252,253,254):
     if i+2>=len(b):self.pending=b[i:];break
     if verb==251:self.s.sendall(bytes([255,254,b[i+2]]))
     elif verb==253:self.s.sendall(bytes([255,252,b[i+2]]))
     i+=3;continue
    if verb==250:
     j=b.find(b'\xff\xf0',i+2)
     if j<0:self.pending=b[i:];break
     i=j+2;continue
    i+=2
  return output.decode('utf-8',errors='replace').replace('\r','')
 def command(self,cmd,timeout=5):
  self.s.sendall(cmd.encode()+b'\r\n');return self.read(timeout)
 def root(self):
  banner=self.command('')
  if 'ATP>' not in banner:raise RuntimeError('Unexpected console: '+banner)
  shell=self.command('shell')
  if re.search(r'password\s*:',shell,re.I):raise RuntimeError('Shell requires authentication')
  result=self.command('su')
  if re.search(r'password\s*:',result,re.I):raise RuntimeError('Root requires authentication')
  identity=self.command('cat /proc/self/status')
  if not re.search(r'Uid:\s+0\s+0\s+0\s+0',identity):raise RuntimeError('Root not confirmed: '+identity)
  return banner+shell+result+identity
 def run(self,cmd,timeout=30):
  marker='MVP_DONE_'+secrets.token_hex(6)
  self.s.sendall((cmd+"\necho "+marker+"\r\n").encode())
  output='';end=time.monotonic()+timeout
  while time.monotonic()<end:
   output+=self.read(min(2,end-time.monotonic()))
   if re.search(r'(?:^|\n)'+marker+r'\s*(?:\n|$)',output):return output
  raise TimeoutError('Command output: '+output)
 def close(self):self.s.close()
if __name__=='__main__':
 c=Console()
 try:
  c.root(); print('Root UID 0 confirmed',flush=True)
  for cmd in json.load(sys.stdin):
   print(c.run(cmd,60).encode('ascii','backslashreplace').decode(),flush=True)
 finally:c.close()
