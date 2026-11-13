"""One Xray, hot API updates, independent maintenance transport, SOCKS UDP probes."""
from __future__ import annotations
import contextlib, hashlib, ipaddress, json, pathlib, socket, struct, subprocess, threading, time, uuid
from urllib.parse import urlencode, urlsplit
from finder import RESOURCE_BASE, XRAY_SHA256, HIDDEN, make_config
from storage import free_port, identity
from platform_runtime import Job, spawn_options, release_process, physical_interfaces
from core_assets import binary, executable_hash, curl
from app_paths import logs_for

def recv_exact(sock,size,deadline=None):
    data=b''
    while len(data)<size:
        if deadline is not None:
            remaining=deadline-time.monotonic()
            if remaining<=0:raise TimeoutError('Общий таймаут UDP')
            sock.settimeout(remaining)
        piece=sock.recv(size-len(data))
        if not piece: raise ConnectionError('Соединение закрыто')
        data+=piece
    return data

def udp_query(port,timeout=5,address='1.1.1.1',destination_port=53):
    """SOCKS5 UDP ASSOCIATE + DNS, validate transaction, source and DNS response."""
    started=time.monotonic();deadline=started+timeout
    def receive(sock,size):return recv_exact(sock,size,deadline)
    def limit(sock):
        remaining=deadline-time.monotonic()
        if remaining<=0:raise TimeoutError('Общий таймаут UDP')
        sock.settimeout(remaining)
    with socket.create_connection(('127.0.0.1',port),timeout=timeout) as control, socket.socket(socket.AF_INET,socket.SOCK_DGRAM) as udp:
        control.settimeout(timeout); udp.settimeout(timeout); udp.bind(('127.0.0.1',0))
        control.sendall(b'\x05\x01\x00')
        if receive(control,2)!=b'\x05\x00': raise ValueError('SOCKS authentication')
        limit(control)
        control.sendall(b'\x05\x03\x00\x01\x7f\x00\x00\x01'+struct.pack('!H',udp.getsockname()[1]))
        head=receive(control,4)
        if head[:3]!=b'\x05\x00\x00': raise ValueError('UDP associate refused')
        if head[3]==1: relay=socket.inet_ntoa(receive(control,4))
        elif head[3]==3: relay=receive(control,receive(control,1)[0]).decode()
        elif head[3]==4: relay=socket.inet_ntop(socket.AF_INET6,receive(control,16))
        else: raise ValueError('SOCKS address')
        relay_port=struct.unpack('!H',receive(control,2))[0]
        token=uuid.uuid4().int&65535
        dns=struct.pack('!6H',token,0x100,1,0,0,0)+b'\x07example\x03com\x00\x00\x01\x00\x01'
        packet=b'\x00\x00\x00\x01'+socket.inet_aton(address)+struct.pack('!H',destination_port)+dns
        relay=relay if relay!='0.0.0.0' else '127.0.0.1'
        limit(udp);udp.sendto(packet,(relay,relay_port));limit(udp)
        response,peer=udp.recvfrom(65535)
        if peer[1]!=relay_port:raise ValueError('Unexpected UDP relay')
        if len(response)<4:raise ValueError('Short UDP response')
        if response[:3]!=b'\0\0\0': raise ValueError('Fragmented UDP')
        offset={1:10,4:22}.get(response[3])
        if response[3]==3: offset=7+response[4]
        if not offset or len(response)<offset+12: raise ValueError('Short UDP response')
        tid,flags,questions,answers,_,_=struct.unpack('!6H',response[offset:offset+12])
        if tid!=token or not flags&0x8000 or flags&15 or not answers: raise ValueError('Invalid DNS response')
        return {'ok':True,'seconds':time.monotonic()-started,'bytes':len(packet)+len(response)}

class Core:
    def __init__(self,store,interface,emit=lambda *args:None,xray=None,expected_sha256=None,quiet=False):
        self.store=store; self.interface=interface; self.emit=emit
        self.xray=pathlib.Path(xray or binary())
        self.expected_sha256=expected_sha256; self.quiet=quiet
        self.profile=store.profile(); self.directory=store.directory/'core'; self.directory.mkdir(exist_ok=True)
        self.log_directory=logs_for(store.directory); self.log_directory.mkdir(parents=True,exist_ok=True)
        self.lock=threading.RLock(); self.process=None; self.job=None; self.log=None
        self.ports={}; self.generation=0; self.selected=None; self.cache={}
        self.api_port=free_port(); self.maintenance_port=free_port(); self.validation_port=free_port()

    @property
    def uri(self):
        return f"vless://{self.profile['uuid']}@127.0.0.1:{self.profile['port']}?encryption=none&security=none&type=tcp#RealityFinder"

    def configuration(self):
        client={'tag':'client','listen':'127.0.0.1','port':self.profile['port'],'protocol':'vless',
            'settings':{'clients':[{'id':self.profile['uuid']}],'decryption':'none'},'streamSettings':{'network':'raw','security':'none'}}
        def socks(tag,port):
            return {'tag':tag,'listen':'127.0.0.1','port':port,'protocol':'socks','settings':{'auth':'noauth','udp':True}}
        return {'log':{'loglevel':'warning'},'api':{'tag':'api','listen':f'127.0.0.1:{self.api_port}',
                'services':['HandlerService','RoutingService','StatsService']},
            'stats':{},'policy':{'system':{'statsInboundUplink':True,'statsInboundDownlink':True}},
            'inbounds':[client,socks('maintenance',self.maintenance_port),socks('validation',self.validation_port)],
            'outbounds':[{'tag':'blocked','protocol':'blackhole'},
                {'tag':'maintenance-direct','protocol':'freedom','streamSettings':{'sockopt':{'interface':self.interface,'domainStrategy':'UseIPv4'}}}],
            'routing':{'domainStrategy':'AsIs','rules':[
                {'ruleTag':'client','type':'field','inboundTag':['client','validation'],'network':'tcp,udp','balancerTag':'managed'},
                {'ruleTag':'maintenance','type':'field','inboundTag':['maintenance'],'outboundTag':'maintenance-direct'}],
                'balancers':[{'tag':'managed','selector':['blocked'],'strategy':{'type':'random'}}]}}

    def start(self):
        with self.lock:
            if self.process and self.process.poll() is None: return
            with self.xray.open('rb') as stream:
                digest=hashlib.file_digest(stream,'sha256').hexdigest()
            if digest!=(self.expected_sha256 or executable_hash()): raise ValueError('Контрольная сумма Xray не совпадает')
            try: free_port(self.profile['port'])
            except OSError: raise RuntimeError(f"Порт {self.profile['port']} занят. Постоянный профиль сохранён; освободите порт.")
            self.stop(); self.ports.clear(); self.selected=None; self.cache.clear()
            if self.interface=='auto':
                names=physical_interfaces()
                if not names:raise ConnectionError('Нет активной физической сетевой карты; ожидание подключения')
                self.interface=names[0]
            self.api_port=free_port(); self.maintenance_port=free_port(); self.validation_port=free_port()
            path=self.directory/'core.json'; path.write_text(json.dumps(self.configuration()),encoding='utf-8')
            self.log=(pathlib.Path('/dev/null') if self.quiet else self.log_directory/'xray.log').open('ab'); self.job=Job()
            try:
                self.process=subprocess.Popen([str(self.xray),'run','-c',str(path)],stdout=self.log,stderr=self.log,**spawn_options())
                self.job.assign(self.process)
                deadline=time.monotonic()+5
                while time.monotonic()<deadline:
                    if self.process.poll() is not None:
                        detail='' if self.quiet else (self.log_directory/'xray.log').read_text(errors='replace')[-600:]
                        raise RuntimeError('Xray не запустился: '+detail)
                    try:
                        with socket.create_connection(('127.0.0.1',self.api_port),timeout=.1): break
                    except OSError: time.sleep(.05)
                else: raise TimeoutError('Xray API не готов')
                self.generation+=1; self.emit('log','Xray запущен: клиентский маршрут заблокирован до проверки узла.')
            except BaseException: self.stop(); raise

    def stop(self):
        with self.lock:
            if self.process and self.process.poll() is None:
                self.process.terminate()
                try: self.process.wait(3)
                except subprocess.TimeoutExpired: self.process.kill(); self.process.wait()
            if self.process:release_process(self.job,self.process)
            self.process=None
            if self.job: self.job.close(); self.job=None
            if self.log: self.log.close(); self.log=None

    def api(self,command,*args,config=None):
        with self.lock:
            path=None
            try:
                if config is not None:
                    path=self.directory/(uuid.uuid4().hex+'.json'); path.write_text(json.dumps(config),encoding='utf-8'); args=(*args,str(path))
                p=subprocess.run([str(self.xray),'api',command,f'--server=127.0.0.1:{self.api_port}',*args],
                    capture_output=True,timeout=3,**spawn_options(),encoding='utf-8',errors='replace')
                if p.returncode: raise RuntimeError(f'Xray {command}: '+(p.stderr or p.stdout)[-400:])
                return p.stdout
            finally:
                if path: path.unlink(missing_ok=True)

    def select(self,node_id=None):
        self.api('bo','-b','managed',('n-'+node_id) if node_id else 'blocked'); self.selected=node_id

    def resolve(self,hostname,timeout=5):
        try: return str(ipaddress.ip_address(hostname))
        except ValueError: pass
        cached=self.cache.get(hostname)
        if cached and cached[1]>time.monotonic(): return cached[0]
        error=None; deadline=time.monotonic()+timeout
        for name,ip in [('cloudflare-dns.com','1.1.1.1'),('cloudflare-dns.com','1.0.0.1'),('dns.google','8.8.8.8')]:
            remaining=deadline-time.monotonic()
            if remaining<=0: break
            try:
                r=self.request(self.maintenance_port,'https://'+name+'/dns-query?'+urlencode({'name':hostname,'type':'A'}),
                    timeout=min(2,remaining),extra=['--connect-to',f'{name}:443:{ip}:443','-H','Accept: application/dns-json'])
                d=json.loads(r['body'])
                answer=next(a for a in d.get('Answer',[]) if a['type']==1)
                address=str(ipaddress.IPv4Address(answer['data']))
                self.cache[hostname]=(address,time.monotonic()+max(30,min(answer.get('TTL',60),600)))
                return address
            except (ValueError,StopIteration,KeyError,OSError) as e: error=e
        raise ConnectionError(f'DoH: {hostname}: {error}')

    def outbound(self,node):
        return make_config(node.uri,0,self.interface)['outbounds'][0]

    def add(self,node,generation=None):
        key=identity(node.uri)
        with self.lock:
            if generation is not None and generation!=self.generation:raise ConnectionError('Поколение ядра изменилось')
            if key in self.ports: return self.ports[key]
        address=self.resolve(node.host)
        out=self.outbound(node)
        out['tag']='n-'+key; out['settings']['vnext'][0]['address']=address
        user=out['settings']['vnext'][0]['users'][0]
        if user.get('flow')=='xtls-rprx-vision': user['flow']='xtls-rprx-vision-udp443'
        out['mux']={'enabled':False}
        port=free_port(); tag='p-'+key
        with self.lock:
            if generation is not None and generation!=self.generation:raise ConnectionError('Поколение ядра изменилось')
            if key in self.ports: return self.ports[key]
            self.api('ado',config={'outbounds':[out]})
            try:
                self.api('adi',config={'inbounds':[{'tag':tag,'listen':'127.0.0.1','port':port,'protocol':'socks','settings':{'auth':'noauth','udp':True}}]})
                self.api('adrules','-append',config={'routing':{'rules':[{'ruleTag':tag,'type':'field','inboundTag':[tag],'outboundTag':out['tag']}]}})
            except BaseException:
                with contextlib.suppress(Exception): self.api('rmi',tag)
                with contextlib.suppress(Exception): self.api('rmo',out['tag'])
                raise
            self.ports[key]=port; return port

    def remove(self,key):
        with self.lock:
            if self.selected==key: raise ValueError('Нельзя удалять текущий маршрут')
            if key not in self.ports: return
            self.api('rmi','p-'+key); self.api('rmrules','p-'+key); self.api('rmo','n-'+key); self.ports.pop(key,None)

    def request(self,port,url,timeout=5,extra=None,output=None,payload=None,local_dns=False):
        extra=list(extra or [])
        target=urlsplit(url)
        # Probe destinations must not use Xray's Windows resolver: changing the
        # v2rayN profile tears down its TUN/DNS path. Keep TLS hostname verification
        # and SNI, but send the independently resolved IP through the tested node.
        pinned=any(arg in ('--connect-to','--resolve') for arg in extra)
        if target.scheme=='https' and target.hostname and port!=self.maintenance_port and not local_dns and not pinned:
            started=time.monotonic(); address=self.resolve(target.hostname,timeout=timeout)
            timeout=max(.1,timeout-(time.monotonic()-started))
            destination_port=target.port or 443
            extra+=['--connect-to',f'{target.hostname}:{destination_port}:{address}:{destination_port}']
            pinned=True
        local_dns=local_dns or pinned
        args=[curl(),'-sS','--noproxy','','--proxy',f"{'socks5' if local_dns else 'socks5h'}://127.0.0.1:{port}",
            '--connect-timeout',str(timeout),'--max-time',str(timeout),'--max-filesize','16777216']
        if extra: args+=extra
        if output: args+=['--output',str(output)]
        if payload: args+=['-H','Expect:','--data-binary','@'+str(payload)]
        args+=[url,'--write-out','\n__META__%{json}']
        with self.lock:
            if not self.job: raise ConnectionError('Ядро остановлено')
            job=self.job
            p=subprocess.Popen(args,stdout=subprocess.PIPE,stderr=subprocess.PIPE,**spawn_options())
            job.assign(p)
        try:
            stdout,stderr=p.communicate(timeout=timeout+1)
        except BaseException:
            p.kill();p.communicate();raise
        finally:release_process(job,p)
        body,_,meta=stdout.decode('utf-8','replace').rpartition('\n__META__')
        try: d=json.loads(meta)
        except ValueError: d={}
        count=d.get('size_download',0)+d.get('size_upload',0)
        self.store.traffic(count,'speed' if output or payload else 'probe')
        return {'ok':p.returncode==0,'http':d.get('http_code',0),'seconds':d.get('time_total',timeout),
            'body':body,'bytes':count,'error':stderr.decode('utf-8','replace')[-300:]}

    def fetch(self,url):
        u=urlsplit(url)
        if u.scheme!='https' or u.hostname not in ('github.com','raw.githubusercontent.com') or u.username: raise ValueError('Недопустимый источник')
        ip=self.resolve(u.hostname)
        r=self.request(self.maintenance_port,url,timeout=40,extra=['--resolve',f'{u.hostname}:443:{ip}'],local_dns=True)
        if not r['ok'] or r['http']!=200: raise ConnectionError(r['error'] or f"HTTP {r['http']}")
        return r['body']

    def physical_online(self):
        # Literal addresses and original SNI: no Windows DNS or TUN dependency.
        import concurrent.futures as cf
        def check(target):
            host,ip,path=target
            try:
                r=self.request(self.maintenance_port,f'https://{host}{path}',timeout=2,extra=['--connect-to',f'{host}:443:{ip}:443'])
                return r['ok'] and r['http'] in (200,301,302,404)
            except Exception: return False
        with cf.ThreadPoolExecutor(2) as pool:
            return any(list(pool.map(check,[('one.one.one.one','1.1.1.1','/'),('dns.google','8.8.8.8','/')])))

    def client_bytes(self):
        try:
            d=json.loads(self.api('statsquery','-pattern','inbound>>>client>>>traffic'))
            return sum(int(s.get('value',0)) for s in d.get('stat',[]))
        # Statistics are optional. An unavailable API means user activity is
        # unknown; the scheduler already avoids active-channel speed tests then.
        except (ValueError,RuntimeError,OSError,subprocess.TimeoutExpired): return None
