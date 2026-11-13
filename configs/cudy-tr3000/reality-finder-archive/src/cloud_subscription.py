"""Publish checked routes to a private Cloudflare Worker without client/TUN routing."""
from __future__ import annotations
import hashlib, http.client, json, re, socket, ssl, struct, threading, time
from urllib.parse import urlsplit
from runtime import recv_exact
from credentials import protect

KV_INTERVAL = 120
KV_DAILY_BUDGET = 900


class PublicationError(Exception):
    def __init__(self, message, retry_after=120):
        super().__init__(message)
        self.retry_after = retry_after


def save_subscription(store, base_url, read_token='', write_token='', enabled=True, backend=None):
    u=urlsplit(base_url.strip())
    if len(base_url)>256 or u.scheme!='https' or not u.hostname or u.username or u.password or u.path not in ('','/') or u.query or u.fragment:
        raise ValueError('Нужен HTTPS-адрес Worker без пути и токенов')
    if u.port not in (None,443):raise ValueError('Нужен стандартный HTTPS-порт 443')
    previous=store.get('subscription',{})
    backend=backend or previous.get('backend','kv')
    if backend not in ('r2','kv'):raise ValueError('Хранилище: r2 или kv')
    value={'base_url':base_url.strip().rstrip('/'),'enabled':bool(enabled),'backend':backend}
    for name,token in [('read_token',read_token),('write_token',write_token)]:
        if token:
            if not re.fullmatch(r'[A-Za-z0-9_-]{43}',token):raise ValueError('Токен должен содержать 43 символа URL-safe base64')
            value[name]=protect(token)
        elif previous.get(name):value[name]=previous[name]
        else:raise ValueError('Укажите ключи чтения и записи')
    if protect(value['read_token'],True)==protect(value['write_token'],True):raise ValueError('Ключи чтения и записи должны различаться')
    store.put('subscription',value)


def subscription_link(store):
    value=store.get('subscription',{})
    if not value.get('base_url') or not value.get('read_token'):return ''
    return value['base_url']+'/s/'+protect(value['read_token'],True)


def snapshot_payload(snapshot, now=None):
    now=time.time() if now is None else now
    nodes=snapshot.get('nodes',[]); active=snapshot.get('active') or {}
    maximum=min(120,snapshot.get('reserve_freshness',65))
    configs=[];seen=set()
    if snapshot.get('offline'):return {'version':1,'published_at':now,'configs':[]}
    ordered=sorted(nodes,key=lambda n:n.get('uri')!=active.get('uri'))
    for node in ordered:
        uri=node.get('uri','');age=node.get('freshness',99999)
        is_main=bool(active.get('uri')) and uri==active['uri']
        if not node.get('healthy') or snapshot.get('require_udp',True) and not node.get('udp') or age<0 or age>maximum or (not is_main and node.get('role')!='Резерв'):
            continue
        if uri in seen:continue
        seen.add(uri)
        configs.append({'uri':uri,'role':'main' if is_main else 'reserve','checked_at':now-age})
    return {'version':1,'published_at':now,'configs':configs[:31]}


class UploadTransport:
    def __init__(self,core,store,cancel,unprotect=None):
        self.core=core;self.store=store;self.cancel=cancel
        self.unprotect=unprotect or (lambda value: protect(value,True))
    def send(self,settings,payload,ports):
        host=urlsplit(settings['base_url']).hostname
        ip=self.core.resolve(host)
        token=self.unprotect(settings['write_token'])
        for port in ports[:3]:
            if self.cancel.is_set():raise ConnectionError('Отправка остановлена')
            try:return self._send(ip,host,port,token,payload,settings)
            except (OSError,http.client.HTTPException,ValueError):pass
        raise ConnectionError('Подписка: служебное подключение недоступно')
    def _send(self,ip,host,port,token,payload,settings):
        raw=socket.create_connection(('127.0.0.1',port),5);current=[raw];conn=None
        def expire():
            try:current[0].shutdown(socket.SHUT_RDWR)
            except OSError:pass
            current[0].close()
        timer=threading.Timer(10,expire);timer.daemon=True;timer.start()
        try:
            raw.settimeout(5);raw.sendall(b'\x05\x01\x00')
            if recv_exact(raw,2)!=b'\x05\x00':raise OSError('SOCKS недоступен')
            raw.sendall(b'\x05\x01\x00\x01'+socket.inet_aton(ip)+struct.pack('!H',443))
            head=recv_exact(raw,4)
            if head[1]:raise OSError('Подключение недоступно')
            size={1:4,4:16}.get(head[3])
            if head[3]==3:size=recv_exact(raw,1)[0]
            if size is None:raise OSError('Некорректный SOCKS')
            recv_exact(raw,size+2)
            secure=ssl.create_default_context().wrap_socket(raw,server_hostname=host,do_handshake_on_connect=False)
            current[0]=secure;secure.do_handshake()
            conn=http.client.HTTPConnection(host,timeout=5);conn.sock=secure
            body=json.dumps(payload,ensure_ascii=False).encode()
            if settings.get('backend')=='kv':reserve_kv_write(self.store,settings['base_url'])
            conn.request('PUT','/api/snapshot',body,{'Content-Type':'application/json','Authorization':'Bearer '+token,'Connection':'close'})
            response=conn.getresponse();data=response.read(4097)
            self.store.traffic(len(body)+len(data),'subscription')
            if response.status != 200:
                try: delay = max(KV_INTERVAL, min(86400, int(response.getheader('Retry-After', KV_INTERVAL))))
                except ValueError: delay = KV_INTERVAL
                raise PublicationError(f'Cloudflare: HTTP {response.status}', delay)
            if len(data)>4096:raise PublicationError('Подписка: слишком большой ответ')
            value=json.loads(data)
            if value.get('ok') is not True:raise ValueError('Подписка: загрузка отклонена')
            return value
        finally:
            timer.cancel()
            if conn:conn.close()
            current[0].close();raw.close()


def kv_write_allowed(store,base_url,now=None):
    now=time.time() if now is None else now
    guard=store.get('subscription_write_guard',{})
    # Changing URLs must not reset an account-wide daily allowance.
    if guard and now-guard.get('attempted_at',0)<KV_INTERVAL:return False
    return guard.get('day')!=int(now//86400) or guard.get('attempts',0)<KV_DAILY_BUDGET


def kv_usage(store, now=None):
    now=time.time() if now is None else now
    guard=store.get('subscription_write_guard',{})
    used=guard.get('attempts',0) if guard.get('day')==int(now//86400) else 0
    next_at=max(now,guard.get('attempted_at',0)+KV_INTERVAL) if guard else now
    if used>=KV_DAILY_BUDGET:next_at=max(next_at,(int(now//86400)+1)*86400)
    return {'used':used,'budget':KV_DAILY_BUDGET,'next_at':next_at,'reset_at':(int(now//86400)+1)*86400}


def reserve_kv_write(store,base_url,now=None):
    now=time.time() if now is None else now
    with store.lock:
        if not kv_write_allowed(store,base_url,now):raise ValueError('Достигнут лимит записи KV')
        old=store.get('subscription_write_guard',{});day=int(now//86400)
        count=old.get('attempts',0) if old.get('day')==day else 0
        store.put('subscription_write_guard',{'base_url':base_url,'day':day,'attempts':count+1,'attempted_at':now})


class SubscriptionPublisher:
    def __init__(self,store,core,emit=lambda *args:None,unprotect=None):
        self.store=store;self.core=core;self.emit=emit
        self.unprotect=unprotect
        self.stop=threading.Event();self.wake=threading.Event();self.lock=threading.Lock()
        self.latest=None;self.thread=None;self.signature=None;self.last_sent=0;self.next_try=0
    def start(self):
        self.thread=threading.Thread(target=self.run,name='subscription',daemon=True);self.thread.start()
    def update(self,snapshot):
        with self.lock:self.latest=snapshot
        self.wake.set()
    def close(self):
        self.stop.set();self.wake.set()
        if self.thread:self.thread.join(45)
    def publish(self,snapshot):
        settings=self.store.get('subscription',{})
        if not settings.get('enabled'):return
        kv=settings.get('backend')=='kv'
        if kv and not kv_write_allowed(self.store,settings['base_url']):return
        payload=snapshot_payload(snapshot);now=time.monotonic()
        signature=hashlib.sha256(json.dumps([settings,[(c['uri'],c['role']) for c in payload['configs']]],sort_keys=True).encode()).hexdigest()
        if now<self.next_try or signature==self.signature and now-self.last_sent<(KV_INTERVAL if kv else 30):return
        # An unchanged empty pool does not need periodic writes. The existing
        # remote snapshot expires on its own, even when this process stops.
        if not payload['configs'] and signature==self.signature:return
        from storage import identity
        with self.core.lock:
            ports=[self.core.maintenance_port]+[self.core.ports.get(identity(c['uri'])) for c in payload['configs']]
        ports=list(dict.fromkeys(p for p in ports if p))
        response=UploadTransport(self.core,self.store,self.stop,self.unprotect).send(settings,payload,ports)
        self.signature=signature;self.last_sent=now;self.next_try=now+3
        self.store.put('subscription_status',{'at':time.time(),'ok':True,'count':len(payload['configs']),
            'worker_upgrade_required':kv and response.get('policy_version',0)<2})
        self.emit('subscription','Закрытая подписка обновлена')
    def run(self):
        while not self.stop.is_set():
            self.wake.wait(2);self.wake.clear()
            with self.lock:value=self.latest
            if value is None:continue
            try:self.publish(value)
            except Exception as error:
                delay=error.retry_after if isinstance(error,PublicationError) else KV_INTERVAL
                self.next_try=time.monotonic()+delay
                message=(str(error) if isinstance(error,PublicationError) else 'Подписка: загрузка не выполнена')
                self.store.put('subscription_status',{'at':time.time(),'ok':False,'error':message,'retry_at':time.time()+delay})
                self.emit('subscription',message)
