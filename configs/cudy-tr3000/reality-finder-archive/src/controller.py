"""Continuous discovery and admission; health and failover have their own executor."""
from __future__ import annotations
import concurrent.futures as cf, copy, dataclasses, datetime, ipaddress, json, os, queue, random, statistics, threading, time
from collections import deque
from dataclasses import dataclass, field
from finder import Node, parse_nodes, unique_nodes
from storage import Settings, identity, subnet
from runtime import Core, udp_query
from cloud_subscription import SubscriptionPublisher
from policy import State, eligible, improvement, rank, reliability, percentile, retry_delay
from platform_runtime import network_fingerprint

ENDPOINTS=('https://www.gstatic.com/generate_204','https://www.cloudflare.com/cdn-cgi/trace','https://www.google.com/generate_204')

@dataclass
class Channel:
    node: Node
    port: int
    admitted: bool = False
    healthy: bool = True
    last: float = 0
    next_check: float = 0
    geo_at: float = 0
    udp_at: float = 0
    speed_at: float = 0
    observations: deque = field(default_factory=lambda: deque(maxlen=500))
    degraded_since: float | None = None
    failed_at: float | None = None
    state: str = State.CHECKING
    excluded: bool = False
    udp_ok: bool = False
    https_ok: bool = False
    last_error: str = ''
    failures: int = 0
    @property
    def key(self): return identity(self.node.uri)
    def rate(self,now):
        checks=[o for o in self.observations if o['at']>=now-300]
        return sum(o['ok'] for o in checks)/len(checks) if checks else 0
    def latency(self,now):
        good=[o['seconds'] for o in self.observations if o['ok'] and o['at']>=now-300]
        return statistics.median(good) if good else float('inf')
    def rank(self,now): return rank(self,now)

def choose_reserves(channels,active,count,now,freshness,countries=None,require_udp=False):
    healthy=sorted((c for c in channels if c.key!=active and c.state!=State.SUSPECT and eligible(c,now,freshness,countries,require_udp)),key=lambda c:c.rank(now))
    result=[]; ips=set(); networks=set(); providers=set()
    if active:
        current=next((c for c in channels if c.key==active),None)
        if current:
            ips.add(current.node.exit_ip); networks.add(subnet(current.node.exit_ip))
            if current.node.asn: providers.add(current.node.asn)
    # First spread subnets, then accept same-subnet independent IPs. Same IP is one backup.
    for diversify in (2,1,0):
        for c in healthy:
            ip=c.node.exit_ip; net=subnet(ip)
            if ip in ips or diversify and net in networks: continue
            if diversify==2 and c.node.asn and c.node.asn in providers:continue
            result.append(c); ips.add(ip); networks.add(net)
            if c.node.asn:providers.add(c.node.asn)
            if len(result)>=count: return result
    return result

class Controller:
    def __init__(self,store,emit=lambda *args:None,core=None):
        self.store=store; self.emit=emit; self.settings=store.settings(); self.core=core or Core(store,self.settings.interface,emit)
        self.publisher=SubscriptionPublisher(store,self.core,emit)
        self.cancel=threading.Event(); self.commands=queue.Queue(); self.thread=None
        self.channels={}; self.catalog={}; self.retry={}; self.manual_requests=set(); self.active=None; self.last_switch=0
        self.preferred_active=store.get('last_active')
        self.preferred=store.get('preferred_node')
        self.excluded=set(store.get('excluded_nodes',[]))
        self.retry_history=store.get('node_retry',{})
        self.source_stats=store.get('source_stats',{})
        self.explore_at=0; self.network_at=0; self.network_job=None; self.network_signature=None
        self.last_tick=time.monotonic(); self.network_enabled=core is None
        self.outage=False; self.reason='Ожидание проверенного узла'; self.search_at=0; self.next_search=0
        self.futures={}; self.health_jobs={}; self.speed_jobs={}; self.source_job=None
        self.speed_reserved=0; self.traffic_previous=None; self.traffic_at=0; self.user_busy_until=0
        self.source_times=self.store.get('source_times',{}); self.pass_candidates=deque(); self.generation=0
        self.incoming=queue.Queue(); self.last_snapshot=0
        self.health_pool=cf.ThreadPoolExecutor(3,thread_name_prefix='health')
        self.candidate_pool=cf.ThreadPoolExecutor(8,thread_name_prefix='candidate')
        self.source_pool=cf.ThreadPoolExecutor(1,thread_name_prefix='sources')
        self.speed_pool=cf.ThreadPoolExecutor(1,thread_name_prefix='speed')
        self.metadata_pool=cf.ThreadPoolExecutor(1,thread_name_prefix='reachability'); self.metadata_jobs={}; self.metadata_at={}
        self.asn_cache=store.get('asn_cache',{})
        self.network_pool=cf.ThreadPoolExecutor(1,thread_name_prefix='network')
        for value in store.nodes():
            try:
                n=Node(**{k:v for k,v in value.items() if k in Node.__dataclass_fields__})
                for check in n.checks:
                    if isinstance(check.get('at'),str):
                        try:check['at']=datetime.datetime.fromisoformat(check['at']).timestamp()
                        except ValueError:check['at']=0
                if parse_nodes(n.uri,'saved'): self.catalog[identity(n.uri)]=n
            except (ValueError,TypeError): continue
        for key,value in self.retry_history.items():
            self.retry[key]=time.monotonic()+max(0,value.get('next_at',0)-time.time())
        saved=sorted(self.catalog.values(),key=lambda n:(identity(n.uri)!=self.preferred,identity(n.uri)!=self.preferred_active))
        self.pass_candidates.extend(saved[:self.settings.candidates])

    def log(self,message,kind='log'):
        self.store.event(kind,message); self.emit('log',message)

    def start(self):
        self.publisher.start()
        self.thread=threading.Thread(target=self.run,name='scheduler',daemon=True); self.thread.start()

    def close(self):
        self.cancel.set()
        if self.thread: self.thread.join(15)
        self.publisher.close()
        for pool in (self.health_pool,self.candidate_pool,self.source_pool,self.speed_pool,self.metadata_pool,self.network_pool): pool.shutdown(wait=True,cancel_futures=True)
        self.core.stop()

    def configure(self,settings): settings.validate(); self.commands.put(('settings',settings))
    def search(self): self.commands.put(('search',None))
    def paste(self,text): self.commands.put(('paste',text))
    def action(self,kind,key):
        if kind not in ('recheck','prefer','exclude','include','switch'):raise ValueError('Неизвестное действие')
        self.commands.put((kind,key))

    def freshness(self):return self.settings.reserve_interval*2+self.settings.timeout

    def usable(self,c,now,provisional=False):
        return eligible(c,now,self.freshness(),self.settings.countries,self.settings.require_udp,provisional)

    def schedule_retry(self,node,now,error):
        key=identity(node.uri);previous=self.retry_history.get(key,{})
        failures=previous.get('failures',0)+1;delay=retry_delay(failures)
        self.retry[key]=now+delay
        self.retry_history[key]={'failures':failures,'next_at':time.time()+delay,'error':error}
        self.store.put('node_retry',self.retry_history)
        self.catalog[key]=node;self.store.save_node(node)

    def source_result(self,node,ok):
        stats=self.source_stats.setdefault(node.source,{})
        field='admitted' if ok else 'failed';stats[field]=stats.get(field,0)+1
        self.store.put('source_stats',self.source_stats)

    def probe(self,channel,endpoint=0,geo=False,udp=False,deadline=None):
        s=self.settings; now=time.monotonic()
        deadline=min(deadline or float('inf'),now+s.timeout)
        def remaining():
            value=deadline-time.monotonic()
            if value<=0:raise TimeoutError('Общий таймаут проверки')
            return value
        result={'at':now,'ok':False,'https_ok':False,'seconds':s.timeout,'geo':None,'udp':None,'endpoint':ENDPOINTS[endpoint%len(ENDPOINTS)]}
        try:
            url=ENDPOINTS[endpoint%len(ENDPOINTS)]
            r=self.core.request(channel.port,url,timeout=remaining())
            result.update(seconds=time.monotonic()-now,error=r['error'])
            if not r['ok'] or r['http'] not in (200,204): return result
            result['https_ok']=True
            if geo:
                trace=r if 'cdn-cgi/trace' in url else self.core.request(channel.port,ENDPOINTS[1],timeout=remaining())
                fields=dict(line.split('=',1) for line in trace['body'].splitlines() if '=' in line)
                if not trace['ok'] or trace['http']!=200: result['error']='Не удалось определить страну'; return result
                ip=str(ipaddress.ip_address(fields.get('ip',''))); cc=fields.get('loc','')
                result['geo']={'ip':ip,'country':cc}
                if cc not in s.countries: result['error']='Страна выхода: '+cc; result['ineligible']=True; return result
            if udp:
                try:
                    result['udp']=udp_query(channel.port,remaining(),address='8.8.8.8' if endpoint%2 else '1.1.1.1')
                    self.store.traffic(result['udp']['bytes'])
                except Exception as error:
                    result['udp']={'ok':False,'error':str(error)[:120]}
                    if s.require_udp:result['error']='UDP: '+str(error)[:120];return result
            result['ok']=True
        except Exception as e: result['error']=str(e)[:200]
        return result

    def qualify(self,node,generation):
        channel=None
        try:
            port=self.core.add(node,generation=generation); channel=Channel(copy.deepcopy(node),port)
            first=time.monotonic()
            for i in range(3):
                if i and self.cancel.wait(max(0,channel.observations[0]['at']+i*15-time.monotonic())): return None
                if generation!=self.core.generation or self.cancel.is_set(): return None
                result=self.probe(channel,i,geo=(i in (0,2)),udp=True)
                if not result['ok']:
                    self.observe(channel,result)
                    return {'failed':channel,'result':result,'generation':generation}
                self.observe(channel,result)
                if i==1:
                    # Emergency route only after two separate HTTPS AND UDP samples.
                    self.incoming.put(('provisional',copy.deepcopy(channel),generation))
            channel.admitted=True;channel.state=State.READY
            return {'channel':channel,'generation':generation}
        except Exception as e: return {'failed':channel,'node':node,'error':str(e),'generation':generation}

    def observe(self,c,result):
        c.observations.append(result); c.healthy=result['ok']; c.last=result['at']
        c.https_ok=result.get('https_ok',result['ok'])
        c.last_error=result.get('error','') if not result['ok'] else ''
        if result['ok']:
            c.failed_at=None;c.failures=0;c.state=State.READY if c.admitted else State.CHECKING
        else:
            c.failures+=1;c.state=State.QUARANTINE
            if c.failed_at is None:c.failed_at=result['at']
        if result.get('geo'):
            c.node.exit_ip=result['geo']['ip']; c.node.country=result['geo']['country']; c.geo_at=result['at']
        if result.get('udp') is not None:
            c.udp_ok=bool(result['udp'].get('ok'));c.udp_at=result['at']
        c.node.checks.append({'at':time.time(),'ok':result['ok'],'seconds':result['seconds'],'udp':result.get('udp'),'error':result.get('error','')})
        c.node.checks=c.node.checks[-500:]

    def health(self,c,is_active,generation):
        now=time.monotonic(); geo=not c.healthy or now-c.geo_at>=self.settings.geo_interval
        deadline=now+self.settings.timeout*2+2
        result=self.probe(c,len(c.observations),geo,is_active or now-c.udp_at>=self.settings.reserve_interval,deadline)
        if result['ok']: return {'result':result,'generation':generation}
        # Confirm on a different HTTPS origin and distinguish local outage from node failure.
        self.incoming.put(('suspect',c.key,generation))
        if not self.core.physical_online(): return {'offline':True,'generation':generation}
        confirmed=self.probe(c,len(c.observations)+1,geo,True,deadline)
        if confirmed['ok']: return {'result':confirmed,'first_failure':result,'generation':generation}
        return {'result':confirmed,'first_failure':result,'confirmed':True,'generation':generation}

    def discovery(self,sources,generation):
        nodes=[]
        for source in sources:
            if self.cancel.is_set() or generation!=self.core.generation: break
            try:
                batch=parse_nodes(self.core.fetch(source),source); nodes.extend(batch)
                self.log(f'GitHub: {len(batch)} VLESS + Reality — {source.split("/")[3]}')
            except Exception as e: self.log('Источник временно недоступен: '+str(e)[:160])
        return nodes,generation

    def speed(self,c,generation):
        size=self.settings.speed_sample_mib*1024*1024
        upload=min(size,512*1024); path=self.store.directory/('speed-'+c.key+'.bin')
        result={'generation':generation,'at':time.monotonic()}
        try:
            if self.cancel.is_set(): return result
            if c.key==self.active:
                before=self.core.client_bytes()
                if self.cancel.wait(1) or before is None or self.core.client_bytes()!=before: return result
            down=self.core.request(c.port,f'https://speed.cloudflare.com/__down?bytes={size}',timeout=10,output=os.devnull)
            result['down']=round(down['bytes']*8/max(down['seconds'],.001)/1e6,2) if down['ok'] and down['http']==200 and down['bytes']==size else None
            if self.cancel.is_set(): return result
            path.write_bytes(os.urandom(upload))
            up=self.core.request(c.port,'https://speed.cloudflare.com/__up',timeout=10,payload=path,output=os.devnull)
            result['up']=round(upload*8/max(up['seconds'],.001)/1e6,2) if up['ok'] and up['http']==200 else None
        except Exception as e: result['error']=str(e)
        finally: path.unlink(missing_ok=True)
        return result

    def reachability(self,c,generation):
        result={'generation':generation}
        for name,url in [('api','https://api.openai.com/v1/models'),('chatgpt','https://chatgpt.com/')]:
            try:
                r=self.core.request(c.port,url,timeout=self.settings.timeout)
                result[name]={'at':time.time(),'reachable':r['ok'],'http':r['http'],
                    'note':'Доступность HTTPS; наличие Dots в аккаунте не проверяется'}
            except Exception as e: result[name]={'reachable':False,'error':str(e)}
        # Optional metadata never affects admission. Resolve only a measured exit
        # IP, cache for a day, and keep RIPEstat off the health/failover executor.
        ip=c.node.exit_ip
        cached=self.asn_cache.get(ip,{})
        if cached.get('at',0)>time.time()-86400:
            result['network']=cached
        else:
            try:
                if ipaddress.ip_address(ip).is_global:
                    r=self.core.request(c.port,'https://stat.ripe.net/data/network-info/data.json?resource='+ip,timeout=self.settings.timeout)
                    data=json.loads(r['body'])['data'] if r['ok'] and r['http']==200 else {}
                    asns=data.get('asns',[])
                    if asns:
                        asn=str(int(asns[0]));provider=''
                        r=self.core.request(c.port,'https://stat.ripe.net/data/as-overview/data.json?resource=AS'+asn,timeout=self.settings.timeout)
                        if r['ok'] and r['http']==200:provider=str(json.loads(r['body']).get('data',{}).get('holder') or '')[:160]
                        result['network']={'ip':ip,'asn':asn,'provider':provider,'at':time.time()}
            except (ValueError,KeyError,OSError):pass
        return result

    def reserves(self,now):
        if self.outage:return []
        return choose_reserves(list(self.channels.values()),self.active,self.settings.reserves,now,self.freshness(),self.settings.countries,self.settings.require_udp)

    def switch(self,key,reason):
        old=self.active
        self.core.select(key); self.active=key; self.last_switch=time.monotonic(); self.reason=reason
        if key:self.preferred_active=key;self.store.put('last_active',key)
        self.log(f'Маршрут: {self.channels[key].node.exit_ip if key else "БЛОКИРОВКА"}. {reason}','switch')
        self.store.event('route',{'old':old,'new':key,'reason':reason})
        if key: self.channels[key].next_check=0

    def decide(self,now):
        if self.outage:return
        current=self.channels.get(self.active); backups=self.reserves(now)
        if current and not self.usable(current,now,provisional=True):
            self.switch(backups[0].key if backups else None,'Подтверждённый отказ основного канала'); return
        if not current:
            choices=[c for c in self.channels.values() if c.state!=State.SUSPECT and self.usable(c,now,provisional=True)]
            preferred=next((c for c in choices if c.key==self.preferred),None) or next((c for c in choices if c.key==self.preferred_active),None)
            if preferred:self.switch(preferred.key,'Прежний канал перепроверен и восстановлен')
            elif choices:self.switch(min(choices,key=lambda c:c.rank(now)).key,'Проверенный канал восстановлен')
            return
        if not backups or not current.admitted: return
        preferred=next((c for c in backups if c.key==self.preferred),None)
        best=preferred or min(backups,key=lambda c:c.rank(now))
        latency_bad=improvement(current,best,now)
        if latency_bad:
            if current.degraded_since is None: current.degraded_since=now
        else: current.degraded_since=None
        sustained=current.degraded_since is not None and now-current.degraded_since>=120
        history=[o for o in current.observations if now-o['at']<=300]
        poor_rate=bool(history) and now-history[0]['at']>=290 and current.rate(now)<.9 and best.rate(now)>current.rate(now)
        restore_preferred=preferred and len([o for o in preferred.observations if o['ok'] and now-o['at']<=120])>=3
        if now-self.last_switch>=300 and (restore_preferred or (current.key!=self.preferred and (sustained or poor_rate))):
            self.switch(best.key,'Предпочитаемый канал стабилен' if restore_preferred else 'Устойчивая высокая задержка' if sustained else 'Менее 90% успешных проверок за пять минут')

    def process_completed(self,now):
        while not self.incoming.empty():
            kind,c,generation=self.incoming.get_nowait()
            if generation!=self.core.generation:continue
            if kind=='suspect':
                if c in self.channels:self.channels[c].state=State.SUSPECT
                continue
            if c.key not in self.excluded and c.key not in self.channels and not self.active:
                self.channels[c.key]=c
        for key,future in list(self.futures.items()):
            if not future.done(): continue
            self.futures.pop(key)
            try: result=future.result()
            except Exception as e: result={'error':str(e)}
            if not result or result.get('generation')!=self.core.generation: continue
            c=result.get('channel')
            if c and key in self.excluded:
                c=None;result={'failed':result['channel'],'error':'Исключён вручную'}
            if c:
                provisional=self.channels.get(key)
                if provisional:
                    merged={o['at']:o for o in (*c.observations,*provisional.observations)}
                    c.observations=deque(sorted(merged.values(),key=lambda o:o['at']),maxlen=500)
                    checks={o['at']:o for o in (*c.node.checks,*provisional.node.checks)}
                    c.node.checks=sorted(checks.values(),key=lambda o:o['at'])[-500:]
                c.node.status='Готов';c.state=State.READY;self.channels[key]=c; self.catalog[key]=c.node; self.store.save_node(c.node)
                self.retry_history.pop(key,None);self.store.put('node_retry',self.retry_history)
                self.source_result(c.node,True)
                self.log(f'Допущен {c.node.country} {c.node.exit_ip}: HTTPS ×3, UDP {"✓" if c.udp_ok else "недоступен"}, ≥30 секунд.')
            else:
                node=result.get('node') or (result.get('failed').node if result.get('failed') else None)
                error=result.get('error') or result.get('result',{}).get('error') or 'Проверка не пройдена'
                if node:
                    self.schedule_retry(node,now,error);self.source_result(node,False)
                    self.log(f'Кандидат {node.host}: {error[:200]}')
                if key==self.active: self.switch(None,'Канал не прошёл полную проверку допуска')
                self.channels.pop(key,None)
                try: self.core.remove(key)
                except Exception as e: self.log(str(e))
        for key,future in list(self.health_jobs.items()):
            if not future.done(): continue
            self.health_jobs.pop(key)
            try: result=future.result()
            except Exception as e: self.log('Проверка: '+str(e)); continue
            if result.get('generation')!=self.core.generation or key not in self.channels: continue
            c=self.channels[key]
            if result.get('offline'):
                if not self.outage: self.log('Физическое подключение недоступно. Рейтинги узлов сохранены.')
                self.outage=True;c.state=State.SUSPECT; continue
            if self.outage: self.log('Физическое подключение восстановлено.'); self.outage=False
            if result.get('first_failure'): self.observe(c,result['first_failure'])
            self.observe(c,result['result']); c.node.status='Готов: основной' if key==self.active and c.healthy else 'Готов: резерв' if c.healthy else 'Ожидает перепроверки'
            if not c.healthy:
                self.schedule_retry(c.node,now,c.last_error)
                c.next_check=self.retry[c.key]
            else:
                self.retry_history.pop(key,None);self.store.put('node_retry',self.retry_history)
            self.catalog[key]=c.node
            self.store.save_node(c.node)
            if key==self.active and not c.healthy: self.decide(now)
        for key,future in list(self.speed_jobs.items()):
            if not future.done(): continue
            self.speed_jobs.pop(key); self.speed_reserved=0
            try: result=future.result()
            except Exception: continue
            if result.get('generation')!=self.core.generation or key not in self.channels: continue
            c=self.channels[key]
            c.speed_at=result['at'] if 'down' in result else now-self.settings.speed_interval+30
            if 'down' in result:
                c.node.download_mbps=result['down']; c.node.upload_mbps=result.get('up'); self.store.save_node(c.node)
        if self.source_job and self.source_job.done():
            try:
                nodes,generation=self.source_job.result()
                if generation==self.core.generation:
                    for n in nodes: self.catalog.setdefault(identity(n.uri),n)
                    candidates=unique_nodes(list(self.catalog.values()),set(self.settings.countries),len(self.catalog)+1)
                    random.shuffle(candidates)
                    def priority(n):
                        stats=self.source_stats.get(n.source,{})
                        yield_rate=(stats.get('admitted',0)+1)/(stats.get('admitted',0)+stats.get('failed',0)+2)
                        return (not bool(n.exit_ip), -yield_rate, not bool(set(n.label_countries)&set(self.settings.countries)))
                    candidates.sort(key=priority)
                    manual=[n for n in self.pass_candidates if identity(n.uri) in self.manual_requests]
                    queue_nodes=[n for n in candidates if identity(n.uri) not in self.channels and identity(n.uri) not in self.excluded and self.retry.get(identity(n.uri),0)<=now]
                    self.pass_candidates=deque(manual+queue_nodes[:self.settings.candidates])
            except Exception as e: self.log('Поиск: '+str(e))
            self.source_job=None
        for key,future in list(self.metadata_jobs.items()):
            if not future.done(): continue
            self.metadata_jobs.pop(key)
            try:
                result=future.result()
                if result['generation']==self.core.generation and key in self.channels:
                    c=self.channels[key]; c.node.api=result.get('api',{}); c.node.chatgpt=result.get('chatgpt',{})
                    network=result.get('network')
                    if network and network['ip']==c.node.exit_ip:
                        c.node.asn=network['asn'];c.node.provider=network['provider'];self.asn_cache[c.node.exit_ip]=network
                        self.asn_cache={ip:entry for ip,entry in self.asn_cache.items() if entry['at']>time.time()-86400}
                        self.store.put('asn_cache',self.asn_cache)
                    self.store.save_node(c.node)
            except Exception: pass

    def tick(self,now):
        while not self.commands.empty():
            kind,value=self.commands.get_nowait()
            if kind=='settings':
                changed_interface=value.interface!=self.settings.interface
                self.settings=value; self.store.put('settings',dataclasses.asdict(value)); self.next_search=0
                for c in self.channels.values():
                    if c.node.country not in value.countries: c.healthy=False
                if changed_interface:
                    self.network_signature=None;self.network_at=0
                    self.restart('Изменена физическая сетевая карта',now,value.interface)
                self.log('Настройки фоновой работы применены.')
            elif kind=='search':
                self.next_search=0;self.explore_at=0
                self.pass_candidates.extend(n for key,n in self.catalog.items() if key not in self.channels and key not in self.excluded)
            elif kind=='paste':
                nodes=parse_nodes(value,'manual')
                for n in nodes:
                    key=identity(n.uri); self.catalog[key]=n
                    if key not in self.channels or not self.channels[key].healthy:
                        self.manual_requests.add(key);self.retry[key]=0; self.pass_candidates.appendleft(n)
                self.log(f'Вставленный список: {len(nodes)} VLESS + Reality для проверки.')
            elif kind in ('recheck','prefer','exclude','include','switch'):
                if value not in self.catalog:continue
                channel=self.channels.get(value)
                if kind=='exclude':
                    self.excluded.add(value)
                    if channel:channel.excluded=True;channel.state=State.EXCLUDED
                    if self.preferred==value:self.preferred=None;self.store.put('preferred_node',None)
                elif kind=='include':
                    self.excluded.discard(value)
                    if channel:channel.excluded=False
                elif kind=='prefer':
                    self.preferred=None if self.preferred==value else value
                    self.store.put('preferred_node',self.preferred)
                elif kind=='switch':
                    if channel and self.usable(channel,now) and not self.outage:
                        self.switch(value,'Ручное переключение на проверенный сервер')
                    else:self.log('Сервер ещё не прошёл свежую проверку. Переключение отложено; нажмите «Перепроверить».')
                if kind in ('recheck','include','prefer') and value not in self.excluded:
                    self.retry[value]=0
                    if channel:channel.next_check=0
                    else:
                        self.manual_requests.add(value);self.pass_candidates.appendleft(self.catalog[value])
                self.store.put('excluded_nodes',sorted(self.excluded))
                self.log(f'{kind}: {self.catalog[value].host}','action')
        self.process_completed(now); self.decide(now)
        if self.network_enabled:
            if self.network_job and self.network_job.done():
                try:
                    signature=self.network_job.result()
                    if self.network_signature is not None and signature!=self.network_signature:
                        self.restart('Изменилось физическое подключение',now,signature[0] or self.settings.interface)
                    self.network_signature=signature
                except Exception as error:self.log('Сетевая карта: '+str(error)[:150])
                self.network_job=None
            if self.network_job is None and now>=self.network_at:
                self.network_at=now+15
                self.network_job=self.network_pool.submit(network_fingerprint,self.settings.interface)
            if now-self.last_tick>30:
                self.core.cache.clear()
                for c in self.channels.values():c.next_check=0;c.geo_at=0
                self.network_at=0
                self.log('Пауза в работе: повторная проверка сети и серверов')
        self.last_tick=now
        # The active check always gets an executor slot; only two backup checks run together.
        for key,c in sorted(self.channels.items(),key=lambda pair:pair[0]!=self.active):
            if c.excluded or key in self.health_jobs or now<c.next_check: continue
            is_active=key==self.active
            if key in self.futures and not is_active:continue
            if not is_active and sum(k!=self.active for k in self.health_jobs)>=2: continue
            c.next_check=now+(self.settings.active_interval if is_active else self.settings.reserve_interval)
            self.health_jobs[key]=self.health_pool.submit(self.health,c,is_active,self.core.generation)
        backups=self.reserves(now)
        if not self.outage and self.source_job is None and (now>=self.next_search or len(backups)<3 and now-self.search_at>=120):
            wall=time.time()
            def source_delay(source):
                stats=self.source_stats.get(source,{})
                multiplier=4 if len(backups)>=self.settings.reserves and stats.get('failed',0)>30 and not stats.get('admitted') else 1
                return self.settings.source_cooldown*multiplier
            sources=[s for s in self.settings.sources if wall-self.source_times.get(s,0)>=source_delay(s)]
            if sources:
                for source in sources: self.source_times[source]=wall
                self.store.put('source_times',self.source_times); self.search_at=now; self.next_search=now+self.settings.search_interval
                self.source_job=self.source_pool.submit(self.discovery,sources,self.core.generation)
        if not self.pass_candidates:
            self.pass_candidates.extend(n for key,n in self.catalog.items() if key not in self.channels
                and key not in self.excluded and self.retry.get(key,0)<=now)
        attempts=len(self.pass_candidates)
        while not self.outage and self.pass_candidates and len(self.futures)<self.settings.workers and attempts:
            attempts-=1
            n=self.pass_candidates.popleft();key=identity(n.uri)
            if key in self.excluded:continue
            if key in self.channels:
                if key in self.manual_requests:self.channels[key].next_check=0
                self.manual_requests.discard(key);continue
            if key in self.futures or self.retry.get(key,0)>now:continue
            manual=key in self.manual_requests
            if not manual and len(backups)>=self.settings.reserves and (now<self.explore_at or self.futures):
                self.pass_candidates.append(n);continue
            self.manual_requests.discard(key)
            self.futures[key]=self.candidate_pool.submit(self.qualify,copy.deepcopy(n),self.core.generation)
            if len(backups)>=self.settings.reserves:self.explore_at=now+self.settings.explore_interval
        # Retire excess handlers without closing established streams through their old outbound.
        keep={c.key for c in backups}|{self.active}
        # Keep a small warm bench for manual control and changes of ranking.
        parked=sorted((c for c in self.channels.values() if c.key not in keep and self.usable(c,now)),key=lambda c:c.rank(now))
        keep.update(c.key for c in parked[:2])
        for key,c in list(self.channels.items()):
            # Stale backups stay for revalidation, especially during a shared Internet outage.
            if c.healthy and not c.excluded and (self.outage or now-c.last>self.freshness()): keep.add(key)
            # Keep failed admitted nodes for lightweight recovery checks instead
            # of discarding the entire pool during a brief TUN restart. A failed
            # channel is never eligible for routing or the public subscription.
            if c.admitted and not c.excluded and (self.outage or c.failed_at is not None and now-c.failed_at<600): keep.add(key)
            if key not in keep and key not in self.futures and key not in self.health_jobs and key not in self.speed_jobs and key not in self.metadata_jobs:
                self.core.remove(key); self.channels.pop(key)
                self.retry[key]=max(self.retry.get(key,0),now+600)
        if now-self.traffic_at>=5:
            count=self.core.client_bytes()
            if count is None or self.traffic_previous is not None and count>self.traffic_previous: self.user_busy_until=now+15
            self.traffic_previous=count; self.traffic_at=now
        if not self.outage and not self.speed_jobs and self.settings.speed_budget_mib:
            budget=self.settings.speed_budget_mib*1024*1024; needed=(self.settings.speed_sample_mib*1024*1024)+512*1024+65536
            if self.store.used('speed')+needed<=budget:
                for c in sorted(self.channels.values(),key=lambda c:c.speed_at):
                    if not self.usable(c,now) or now-c.speed_at<self.settings.speed_interval: continue
                    if c.key==self.active and now<self.user_busy_until: continue
                    self.speed_reserved=needed; self.speed_jobs[c.key]=self.speed_pool.submit(self.speed,c,self.core.generation); break
        if not self.outage and not self.metadata_jobs:
            for c in self.channels.values():
                if self.usable(c,now) and now-self.metadata_at.get(c.key,0)>=self.settings.geo_interval:
                    self.metadata_at[c.key]=now; self.metadata_jobs[c.key]=self.metadata_pool.submit(self.reachability,c,self.core.generation); break
        if now-self.last_snapshot>=1:
            self.last_snapshot=now; self.snapshot(now)

    def snapshot(self,now=None):
        now=now or time.monotonic(); current=self.channels.get(self.active); backups=self.reserves(now)
        def node_view(node):
            # The details pane uses 20 recent samples. Avoid copying every saved
            # observation of every historical node once per second.
            return {f.name:copy.deepcopy(getattr(node,f.name)[-20:] if f.name=='checks' else getattr(node,f.name))
                    for f in dataclasses.fields(node)}
        backup_keys={c.key for c in backups};live=[]
        for c in self.channels.values():
            ready=self.usable(c,now,provisional=c.key==self.active) and not self.outage
            role='Основной' if c.key==self.active else 'Резерв' if c.key in backup_keys else 'Доступен' if ready else 'Перепроверка'
            state=State.EXCLUDED if c.excluded else State.SUSPECT if self.outage else c.state
            if c.admitted and c.healthy and state==State.CHECKING:state=State.READY
            live.append(node_view(c.node)|{'role':role,'state':state,
                'freshness':round(now-c.last,1),'healthy':ready,'https':c.https_ok,'udp':c.udp_ok and now-c.udp_at<=self.freshness(),
                'success':round(c.rate(now)*100,1),'confidence':round(reliability(c.observations,now)*100,1),
                'samples':len([o for o in c.observations if now-o['at']<=300]),
                'latency':round(c.latency(now)*1000) if c.latency(now)!=float('inf') else None,
                'p90':round(percentile(c.observations,now)*1000) if percentile(c.observations,now)!=float('inf') else None,
                'error':c.last_error,'next_check':round(max(0,c.next_check-now)),
                'preferred':c.key==self.preferred,'excluded':c.excluded})
        # The discovery history is independent of the live Xray handlers. Saved
        # results stay visible on restart/failure, but are never trusted as ready.
        history=[]
        for key,node in self.catalog.items():
            if key in self.channels: continue
            if not node.checks and key not in self.futures and key not in self.manual_requests and key not in self.excluded:continue
            checks=node.checks;last=checks[-1] if checks else None;retry=self.retry_history.get(key,{})
            state=State.EXCLUDED if key in self.excluded else State.CHECKING if key in self.futures else State.QUARANTINE if self.retry.get(key,0)>now else State.ARCHIVED
            history.append(node_view(node)|{'role':'История','state':state,'healthy':False,'udp':False,'https':False,
                'freshness':round(max(0,time.time()-last['at']),1) if last else None,
                'success':round(sum(bool(v['ok']) for v in checks)/len(checks)*100,1) if checks else None,'latency':None,
                'samples':len(checks),'confidence':None,'p90':None,'error':retry.get('error',''),
                'next_check':round(max(0,self.retry.get(key,0)-now)),'preferred':key==self.preferred,'excluded':key in self.excluded})
        value={'active':node_view(current.node) if current else None,
            'freshness':round(now-current.last,1) if current else None,'reserves':len(backups),'reserve_freshness':self.settings.reserve_interval*2+self.settings.timeout,
            'nodes':live+history,'sources':copy.deepcopy(self.source_stats),'require_udp':self.settings.require_udp,
            'reason':self.reason,'offline':self.outage,'traffic_mib':round(self.store.used()/1048576,2),
            'speed_mib':round(self.store.used('speed')/1048576,2),'budget_mib':self.settings.speed_budget_mib,
            'candidates':len(self.futures),'pending':len(self.pass_candidates),'core_pid':self.core.process.pid if self.core.process else None}
        self.emit('snapshot',value);self.publisher.update(value)

    def restart(self,reason,now,interface=None):
        self.log(reason+'; повторный допуск серверов','network')
        self.core.stop()
        if interface is not None:
            self.core.interface=interface
        self.channels.clear();self.active=None;self.outage=False
        self.core.start();self.generation=self.core.generation
        self.pass_candidates=deque(sorted(self.catalog.values(),key=lambda n:identity(n.uri)!=self.preferred_active)[:self.settings.candidates])
        self.next_search=0

    def run(self):
        try:
            while not self.cancel.is_set():
                try:
                    if self.core.process is None or self.core.process.poll() is not None:
                        if self.generation:self.log('Xray завершился. Восстановление с заблокированным маршрутом.','crash')
                        self.restart('Восстановление Xray',time.monotonic())
                    self.tick(time.monotonic())
                except Exception as e:
                    self.log('Планировщик: '+str(e)[:250]);self.emit('fatal',str(e));self.cancel.wait(3)
                self.cancel.wait(.25)
        except Exception as e: self.emit('fatal',str(e)); self.store.event('fatal',str(e))
        finally: self.core.stop()
