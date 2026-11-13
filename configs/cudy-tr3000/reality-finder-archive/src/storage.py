"""Persistent settings, identities and observations. No saved node is trusted on boot."""
from __future__ import annotations
import dataclasses, hashlib, ipaddress, json, pathlib, secrets, socket, sqlite3, threading, time, uuid, os
from dataclasses import dataclass, field
from finder import ELIGIBLE, SOURCES, query

@dataclass
class Settings:
    preset: str = 'Сбалансированный'
    interface: str = 'auto'
    countries: list[str] = field(default_factory=lambda: sorted(ELIGIBLE))
    sources: list[str] = field(default_factory=lambda: list(SOURCES))
    active_interval: float = 10
    reserve_interval: float = 30
    search_interval: float = 600
    source_cooldown: float = 120
    reserves: int = 5
    candidates: int = 450
    workers: int = 2
    timeout: float = 5
    speed_interval: float = 3600
    speed_budget_mib: int = 50
    speed_sample_mib: int = 2
    geo_interval: float = 300
    autostart: bool = True
    require_udp: bool = True
    explore_interval: float = 60

    def validate(self):
        for key, low, high in [('active_interval',2,120),('reserve_interval',5,600),
            ('search_interval',120,7200),('source_cooldown',120,7200),('reserves',1,30),
            ('candidates',1,5000),('workers',1,8),('timeout',1,8),
            ('speed_interval',300,86400),('speed_budget_mib',0,1000),('speed_sample_mib',1,10),('geo_interval',60,3600),('explore_interval',30,3600)]:
            value = getattr(self, key)
            if isinstance(value, bool) or not low <= value <= high: raise ValueError(f'{key}: допустимо {low}…{high}')
        if not self.countries or not set(self.countries) <= ELIGIBLE: raise ValueError('Недопустимые страны')
        if not self.interface.strip(): raise ValueError('Выберите физическую сетевую карту')
        from urllib.parse import urlsplit
        if not self.sources: raise ValueError('Нужен источник GitHub')
        for source in self.sources:
            u = urlsplit(source)
            if u.scheme != 'https' or u.hostname not in ('github.com','raw.githubusercontent.com') or u.username:
                raise ValueError('Источники должны быть HTTPS GitHub / raw.githubusercontent.com')
        return self

    @classmethod
    def mode(cls, name):
        s = cls(preset=name)
        if name == 'Экономный':
            s.active_interval=20; s.reserve_interval=60; s.search_interval=1200
            s.reserves=3; s.workers=1; s.candidates=150; s.speed_budget_mib=15; s.speed_interval=7200
        elif name == 'Агрессивный':
            s.active_interval=5; s.reserve_interval=15; s.search_interval=300
            s.reserves=8; s.workers=4; s.candidates=900; s.speed_budget_mib=150
        return s

def identity(uri):
    u,q=query(uri)
    # Labels, aliases and query parameter order never create separate candidates.
    q={k:v for k,v in q.items() if k not in ('remark','remarks')}
    q['type']={'tcp':'raw','splithttp':'xhttp'}.get(q.get('type','tcp'),q.get('type','tcp'))
    q.setdefault('encryption','none'); q.setdefault('fp','chrome'); q.setdefault('sid','')
    if q.get('flow') == 'xtls-rprx-vision-udp443': q['flow']='xtls-rprx-vision'
    value=[(u.hostname or '').lower(),u.port,u.username,sorted(q.items())]
    return hashlib.sha256(json.dumps(value).encode()).hexdigest()[:24]

_port_lock=threading.Lock()
_port_leases={}
def free_port(preferred=0):
    # Avoid the Windows dynamic client-port range: CLI API calls can otherwise
    # consume the just-released bind(0) port before Xray adds its listener.
    with _port_lock:
        for port in [preferred] if preferred else secrets.SystemRandom().sample(range(20000,40000),100):
            if not preferred and _port_leases.get(port,0)>time.monotonic():continue
            try:
                with socket.socket() as s, socket.socket(socket.AF_INET,socket.SOCK_DGRAM) as udp:
                    if hasattr(socket,'SO_EXCLUSIVEADDRUSE'):s.setsockopt(socket.SOL_SOCKET,socket.SO_EXCLUSIVEADDRUSE,1)
                    elif preferred:
                        # A stopped listener can leave accepted connections in
                        # TIME_WAIT. Match Xray's Unix listener reuse semantics;
                        # a genuinely live listener must still reject the bind.
                        s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
                    s.bind(('127.0.0.1',port))
                    if not preferred:udp.bind(('127.0.0.1',port))
                    _port_leases[port]=time.monotonic()+10
                    return port
            except OSError:
                if preferred:raise
        raise OSError('Нет свободного локального порта')

def subnet(ip):
    try:
        a=ipaddress.ip_address(ip)
        return str(ipaddress.ip_network(f'{a}/{24 if a.version==4 else 48}',strict=False))
    except ValueError: return ip

class Store:
    def __init__(self, directory):
        if os.environ.get('RF_TESTING') == '1':
            from app_paths import paths
            if pathlib.Path(directory).resolve() == paths().data.resolve():
                raise RuntimeError('Тестам запрещено открывать рабочую базу Reality Finder')
        self.directory=pathlib.Path(directory); self.directory.mkdir(parents=True,exist_ok=True)
        self.lock=threading.RLock()
        self.db=sqlite3.connect(self.directory/'reality.sqlite3',check_same_thread=False)
        self.db.execute('PRAGMA journal_mode=WAL')
        self.db.executescript('''CREATE TABLE IF NOT EXISTS kv(key TEXT PRIMARY KEY,value TEXT);
            CREATE TABLE IF NOT EXISTS nodes(id TEXT PRIMARY KEY,value TEXT,updated REAL);
            CREATE TABLE IF NOT EXISTS events(at REAL,kind TEXT,value TEXT);
            CREATE TABLE IF NOT EXISTS traffic(at REAL,bytes INTEGER,kind TEXT);
            CREATE INDEX IF NOT EXISTS traffic_at ON traffic(at);
            CREATE INDEX IF NOT EXISTS events_at ON events(at);''')
        # Telegram has been removed. Keep the independent subscription keys.
        self.db.execute("DELETE FROM kv WHERE key IN ('telegram','telegram_status')")
        self.db.commit()

    def get(self,key,default=None):
        with self.lock:
            row=self.db.execute('SELECT value FROM kv WHERE key=?',(key,)).fetchone()
            return json.loads(row[0]) if row else default

    def put(self,key,value):
        with self.lock, self.db:
            self.db.execute('INSERT OR REPLACE INTO kv VALUES(?,?)',(key,json.dumps(value,ensure_ascii=False)))

    def profile(self):
        profile=self.get('profile')
        if profile: return profile
        try: port=free_port(11080)
        except OSError: port=free_port()
        profile={'port':port,'uuid':str(uuid.uuid4())}; self.put('profile',profile); return profile

    def settings(self):
        value=self.get('settings') or {}
        return Settings(**{k:v for k,v in value.items() if k in Settings.__dataclass_fields__}).validate()

    def save_node(self,node):
        with self.lock,self.db:
            self.db.execute('INSERT OR REPLACE INTO nodes VALUES(?,?,?)',
                (identity(node.uri),json.dumps(dataclasses.asdict(node),ensure_ascii=False),time.time()))

    def nodes(self):
        with self.lock: return [json.loads(row[0]) for row in self.db.execute('SELECT value FROM nodes ORDER BY updated DESC LIMIT 5000')]

    def events(self, limit=100):
        with self.lock:
            return [{'at': row[0], 'kind': row[1], 'value': json.loads(row[2])}
                    for row in self.db.execute('SELECT at,kind,value FROM events ORDER BY at DESC LIMIT ?', (limit,))]

    def event(self,kind,value):
        with self.lock,self.db:
            self.db.execute('INSERT INTO events VALUES(?,?,?)',(time.time(),kind,json.dumps(value,ensure_ascii=False)))
            self.db.execute('DELETE FROM events WHERE at < ?',(time.time()-30*86400,))

    def traffic(self,count,kind='probe'):
        with self.lock,self.db:
            self.db.execute('INSERT INTO traffic VALUES(?,?,?)',(time.time(),max(0,int(count)),kind))
            self.db.execute('DELETE FROM traffic WHERE at < ?',(time.time()-7*86400,))

    def used(self,kind=None):
        with self.lock:
            sql='SELECT COALESCE(SUM(bytes),0) FROM traffic WHERE at>?'
            args=[time.time()-3600]
            if kind: sql+=' AND kind=?'; args.append(kind)
            return self.db.execute(sql,args).fetchone()[0]

    def migrate(self,paths):
        if self.get('migrated'): return
        from finder import Node
        s=Settings(); loaded=False
        for directory in map(pathlib.Path,paths):
            try:
                old=json.loads((directory/'settings.json').read_text(encoding='utf-8'))
                if not loaded:
                    countries=old.get('countries','').replace(' ','').split(',')
                    if set(countries)<=ELIGIBLE and countries: s.countries=countries
                    s.interface=old.get('interface') or 'Ethernet'; s.sources=old.get('sources') or SOURCES
                    self.put('settings',dataclasses.asdict(s)); loaded=True
                report=pathlib.Path(old.get('last_dir') or directory)/'report.json'
                for value in json.loads(report.read_text(encoding='utf-8')).get('nodes',[]):
                    self.save_node(Node(**{k:v for k,v in value.items() if k in Node.__dataclass_fields__}))
            except (OSError,ValueError,TypeError): continue
        self.put('migrated',True)

    def close(self):
        with self.lock: self.db.close()
