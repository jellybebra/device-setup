"""Public VLESS + Reality discovery and real HTTPS checks, standard library only."""
from __future__ import annotations
import base64, concurrent.futures as futures, contextlib, datetime as dt
import hashlib, json, os, pathlib, re, socket, statistics, subprocess, sys, threading, time, uuid
from dataclasses import dataclass, asdict, field
from core_assets import binary, executable_hash, curl
from platform_runtime import spawn_options
from urllib.parse import parse_qs, quote, unquote, urlsplit, urlunsplit

RESOURCE_BASE = pathlib.Path(getattr(sys, '_MEIPASS', pathlib.Path(__file__).resolve().parent))
BASE = pathlib.Path(sys.executable).resolve().parent if getattr(sys, 'frozen', False) else RESOURCE_BASE
XRAY_SHA256 = '15c2d007954ac53ba69b80ec91242786b3c0b71d52649165b4ca1d5cc96ef8f1'
ELIGIBLE = set('US CA JP SG KR AU NZ IN TR AE AM GE KZ RS MD UA IL BR MX ZA TW MY ID TH VN AR CL AL BA MK PH'.split())
SOURCES = [
    'https://raw.githubusercontent.com/0xRadikal/Free-v2ray-Configs/main/verified/configs.txt',
    'https://raw.githubusercontent.com/VovaplusEXP/p-configs/main/Splitted-By-Protocol-Secure/vless.txt',
    'https://raw.githubusercontent.com/luxxuria/harvester/main/speed_tested.txt',
    'https://raw.githubusercontent.com/luxxuria/harvester/main/ping_tested.txt',
    'https://raw.githubusercontent.com/Danialsamadi/v2go/main/AllConfigsSub.txt',
    'https://raw.githubusercontent.com/MatinGhanbari/v2ray-configs/main/subscriptions/filtered/subs/vless.txt',
]
FLAGS = re.compile('[\U0001f1e6-\U0001f1ff]{2}')
HIDDEN = subprocess.CREATE_NO_WINDOW if os.name == 'nt' else 0

class Cancelled(Exception): pass

@dataclass
class Options:
    countries: set[str] = field(default_factory=lambda: set(ELIGIBLE))
    interface: str = 'Ethernet'
    workers: int = 4
    max_candidates: int = 450
    target: int = 5
    speed: bool = True
    stability_minutes: int = 0
    sources: list[str] = field(default_factory=lambda: list(SOURCES))

@dataclass
class Node:
    uri: str
    source: str
    host: str
    label_countries: list[str]
    index: int = 0
    country: str = ''
    exit_ip: str = ''
    checks: list[dict] = field(default_factory=list)
    download_mbps: float | None = None
    upload_mbps: float | None = None
    speed_samples: dict = field(default_factory=dict)
    api: dict = field(default_factory=dict)
    chatgpt: dict = field(default_factory=dict)
    status: str = 'Ожидает проверки'
    asn: str = ''
    provider: str = ''

def query(uri):
    u = urlsplit(uri)
    return u, {k: v[-1] for k, v in parse_qs(u.query, keep_blank_values=True).items()}

def make_config(uri: str, port: int, interface: str = '') -> dict:
    u, q = query(uri)
    if u.scheme != 'vless' or q.get('security') != 'reality':
        raise ValueError('Требуется VLESS + Reality')
    uuid.UUID(unquote(u.username or ''))
    if not u.hostname or not u.port or not 1 <= u.port <= 65535: raise ValueError('Некорректный адрес')
    pbk = q.get('pbk', '')
    if not re.fullmatch(r'[A-Za-z0-9_-]{43}=?', pbk) or len(base64.urlsafe_b64decode(pbk + '=' * (-len(pbk) % 4))) != 32:
        raise ValueError('Некорректный публичный ключ Reality')
    sid = q.get('sid', '')
    if len(sid) > 16 or len(sid) % 2 or (sid and not re.fullmatch('[a-fA-F0-9]+', sid)):
        raise ValueError('Некорректный shortId')
    if not q.get('sni'): raise ValueError('Нет SNI')
    network = {'tcp': 'raw', 'splithttp': 'xhttp'}.get(q.get('type', 'tcp'), q.get('type', 'tcp'))
    if network not in ('raw', 'grpc', 'xhttp'): raise ValueError('Транспорт не поддерживается')
    if q.get('headerType', 'none') not in ('', 'none'): raise ValueError('HTTP-заголовки TCP не поддерживаются')
    if q.get('encryption', 'none') not in ('', 'none'): raise ValueError('VLESS Encryption пока не поддерживается')
    if q.get('authority') and not re.fullmatch(r'[a-zA-Z0-9.:-]+', q['authority']): raise ValueError('Некорректная gRPC authority')
    stream = {'network': network, 'security': 'reality', 'realitySettings': {
        'serverName': q['sni'], 'fingerprint': q.get('fp') or 'chrome', 'publicKey': pbk,
        'password': pbk, 'shortId': sid, 'spiderX': q.get('spx', '/')}}
    if interface: stream['sockopt'] = {'interface': interface, 'domainStrategy': 'UseIPv4'}
    if network == 'grpc':
        stream['grpcSettings'] = {'serviceName': q.get('serviceName', ''), 'multiMode': q.get('mode') == 'multi'}
        if q.get('authority'): stream['grpcSettings']['authority'] = q['authority']
    if network == 'xhttp':
        stream['xhttpSettings'] = {'path': q.get('path', '/'), 'mode': q.get('mode') or 'auto'}
        if q.get('host'): stream['xhttpSettings']['host'] = q['host']
        if q.get('extra'): stream['xhttpSettings']['extra'] = json.loads(q['extra'])
    user = {'id': unquote(u.username), 'encryption': 'none'}
    if q.get('flow'): user['flow'] = q['flow']
    return {'log': {'loglevel': 'warning'}, 'inbounds': [{'listen': '127.0.0.1', 'port': port,
        'protocol': 'socks', 'settings': {'auth': 'noauth', 'udp': False}}],
        'outbounds': [{'protocol': 'vless', 'settings': {'vnext': [{'address': u.hostname,
            'port': u.port, 'users': [user]}]}, 'streamSettings': stream}]}

def parse_nodes(raw: str, source: str) -> list[Node]:
    if 'vless://' not in raw:
        raw = base64.b64decode(''.join(raw.split()) + '=' * (-len(''.join(raw.split())) % 4)).decode('utf-8-sig')
    result = []
    for line in raw.splitlines():
        line = line.strip()
        if not line.startswith('vless://'): continue
        try:
            make_config(line, 19001)
            u, _ = query(line); label = unquote(u.fragment)
            countries = {''.join(chr(ord(c) - 0x1f1e6 + 65) for c in flag) for flag in FLAGS.findall(label)}
            countries.update(re.findall(r'(?<![A-Z])[A-Z]{2}(?![A-Z])', label))
            # Ignore arbitrary uppercase fragments; only ISO country codes influence ranking.
            iso = ELIGIBLE | set('AT BE BG HR CY CZ DK EE FI FR DE GR HU IS IE IT LV LI LT LU MT NL NO PL PT RO SK SI ES SE GB CH RU CN HK IR'.split())
            countries &= iso
            for name, cc in {'United States': 'US', 'Canada': 'CA', 'Japan': 'JP', 'Singapore': 'SG', 'Moldova': 'MD', 'Turkey': 'TR'}.items():
                if name.lower() in label.lower(): countries.add(cc)
            result.append(Node(line, source, u.hostname, sorted(countries)))
        except (ValueError, KeyError, TypeError, json.JSONDecodeError): continue
    return result

def unique_nodes(nodes: list[Node], countries: set[str], limit: int) -> list[Node]:
    # Country labels are hints; actual exit is measured through the tunnel.
    nodes = sorted(nodes, key=lambda n: 0 if set(n.label_countries) & countries else 1)
    seen, hosts, out = set(), {}, []
    for n in nodes:
        u, q = query(n.uri)
        key = (u.hostname, u.port, u.username, *(q.get(k, '') for k in ('pbk','sni','sid','flow','type','serviceName','authority','path','host','mode','extra','fp')))
        if key in seen or hosts.get(n.host, 0) >= 3: continue
        # Labels are untrusted hints, not evidence of the actual exit country.
        seen.add(key); hosts[n.host] = hosts.get(n.host, 0) + 1
        n.index = len(out); out.append(n)
        if len(out) >= limit: break
    return out

def interfaces() -> list[str]:
    from platform_runtime import physical_interfaces
    return ['auto', *physical_interfaces()]

class Engine:
    def __init__(self, options: Options, emit=lambda *args: None, cancel=None, base=BASE):
        self.options = options; self.emit = emit; self.cancel = cancel or threading.Event()
        self.base = pathlib.Path(base); self.xray = (RESOURCE_BASE if self.base == BASE else self.base) / 'bin' / binary().name
        self.run_dir = self.base / 'data' / ('run-' + dt.datetime.now().strftime('%Y%m%d-%H%M%S') + '-' + uuid.uuid4().hex[:6])
        self.run_dir.mkdir(parents=True, exist_ok=True)
        self.results: list[Node] = []
        self.candidates: list[Node] = []

    def guard(self):
        if self.cancel.is_set(): raise Cancelled()

    def command(self, args, timeout):
        self.guard()
        proc = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, **spawn_options())
        began = time.monotonic()
        try:
            while True:
                self.guard()
                if time.monotonic() - began > timeout: raise TimeoutError('Таймаут процесса')
                try:
                    stdout, stderr = proc.communicate(timeout=.2)
                    return proc.returncode, stdout.decode('utf-8', 'replace'), stderr.decode('utf-8', 'replace')
                except subprocess.TimeoutExpired: pass
        finally:
            if proc.poll() is None:
                proc.terminate()
                try: proc.communicate(timeout=2)
                except subprocess.TimeoutExpired: proc.kill(); proc.communicate()

    @contextlib.contextmanager
    def tunnel(self, node=None):
        self.guard()
        with socket.socket() as sock: sock.bind(('127.0.0.1', 0)); port = sock.getsockname()[1]
        if node: cfg = make_config(node.uri, port, self.options.interface)
        else:
            cfg = {'log': {'loglevel': 'warning'}, 'inbounds': [{'listen': '127.0.0.1', 'port': port,
                'protocol': 'socks', 'settings': {'auth': 'noauth'}}], 'outbounds': [{'protocol': 'freedom'}]}
            if self.options.interface:
                cfg['outbounds'][0]['streamSettings'] = {'sockopt': {'interface': self.options.interface, 'domainStrategy': 'UseIPv4'}}
        token = uuid.uuid4().hex
        path = self.run_dir / (token + '.json'); path.write_text(json.dumps(cfg), encoding='utf-8')
        log_path = path.with_suffix('.log')
        with log_path.open('wb') as log:
            proc = subprocess.Popen([str(self.xray), 'run', '-c', str(path)], stdout=log, stderr=log, **spawn_options())
            try:
                for _ in range(60):
                    self.guard()
                    if proc.poll() is not None:
                        raise RuntimeError('Xray: ' + log_path.read_text(encoding='utf-8', errors='replace')[-600:])
                    try:
                        with socket.create_connection(('127.0.0.1', port), timeout=.1): break
                    except OSError: self.cancel.wait(.05)
                else: raise TimeoutError('Xray не открыл локальный порт')
                yield port
            finally:
                proc.terminate()
                try: proc.wait(timeout=2)
                except subprocess.TimeoutExpired: proc.kill(); proc.wait()
                path.unlink(missing_ok=True)

    def request(self, port, url, timeout=14, download=False, payload=None):
        args = [curl(), '-sS', '--noproxy', '', '--proxy', f'socks5h://127.0.0.1:{port}',
            '--connect-timeout', '9', '--max-time', str(timeout)]
        if download or payload:
            args += ['--output', os.devnull, '-H', 'Accept-Encoding: identity']
        if payload:
            args += ['-H', 'Expect:', '-H', 'Content-Type: application/octet-stream', '--data-binary', '@' + str(payload)]
        args += [url, '--write-out', '\n__META__%{json}']
        code, stdout, stderr = self.command(args, timeout + 4)
        body, _, meta = stdout.rpartition('\n__META__')
        try: values = json.loads(meta)
        except ValueError: values = {}
        return {'ok': code == 0, 'http': values.get('http_code', 0), 'seconds': values.get('time_total', 0),
            'body': body, 'error': stderr[:250], 'downloaded': values.get('size_download', 0), 'uploaded': values.get('size_upload', 0)}

    def fetch(self, port, url, index):
        self.guard()
        u = urlsplit(url)
        if u.scheme != 'https' or u.hostname not in ('raw.githubusercontent.com', 'github.com') or u.username:
            raise ValueError('Источники должны быть HTTPS-ссылками на GitHub / raw.githubusercontent.com')
        code, raw, err = self.command([curl(),'-fsSL','--max-time','40','--connect-timeout','10','--retry','1','--retry-delay','1',
            '--noproxy','','--proxy',f'socks5h://127.0.0.1:{port}', '-H','Cache-Control: no-cache',url], 85)
        if code: raise RuntimeError(err.strip()[:180])
        (self.run_dir / f'source-{index}.txt').write_text(raw, encoding='utf-8')
        nodes = parse_nodes(raw, url)
        self.emit('log', f'Источник {index + 1}: {len(nodes)} конфигураций VLESS + Reality')
        return nodes

    def check(self, node: Node, phase: int):
        self.guard(); observation = {'phase': phase, 'at': dt.datetime.now(dt.timezone.utc).isoformat(), 'ok': False}
        try:
            with self.tunnel(node) as port:
                trace = self.request(port, 'https://www.cloudflare.com/cdn-cgi/trace')
                observation['trace'] = trace
                fields = dict(s.split('=', 1) for s in trace['body'].splitlines() if '=' in s)
                if not trace['ok'] or trace['http'] != 200: raise ValueError('Нет HTTPS-соединения')
                cc, ip = fields.get('loc', ''), fields.get('ip', '')
                if cc not in self.options.countries or not ip: raise ValueError('Выход в другой стране: ' + cc)
                node.country, node.exit_ip = cc, ip
                if phase >= 2:
                    google = self.request(port, 'https://www.gstatic.com/generate_204')
                    observation['google'] = google
                    if not google['ok'] or google['http'] != 204: raise ValueError('Не прошёл второй HTTPS-запрос')
                if phase == 3:
                    node.api = self.request(port, 'https://api.openai.com/v1/models')
                    if 'unsupported_country' in node.api['body']: raise ValueError('OpenAI отклонил регион IP')
                    chat = self.request(port, 'https://chatgpt.com/')
                    node.chatgpt = {k: v for k,v in chat.items() if k != 'body'}
                    node.chatgpt['browser_challenge'] = 'cf-chl-' in chat['body'] or 'Just a moment' in chat['body']
                observation['ok'] = True
                node.status = f'HTTPS-проверок: {sum(c["ok"] for c in node.checks) + 1}'
        except Cancelled: raise
        except Exception as e: observation['error'] = str(e)[:300]; node.status = 'Отбракован: ' + str(e)[:100]
        node.checks.append(observation)
        if observation['ok'] or phase > 1: self.emit('node', asdict(node))
        return node, observation['ok']

    def speed_test(self, node):
        samples = {'download': [], 'upload': []}
        payload = self.run_dir / 'random-upload.bin'
        if not payload.exists(): payload.write_bytes(os.urandom(512 * 1024))
        with self.tunnel(node) as port:
            for direction, size in [('download', 2 * 1024 * 1024), ('upload', 512 * 1024)]:
                for _ in range(2):
                    url = 'https://speed.cloudflare.com/' + ('__down' if direction == 'download' else '__up') + f'?bytes={size}&r={uuid.uuid4().hex}'
                    r = self.request(port, url, timeout=20, download=True, payload=payload if direction == 'upload' else None)
                    complete = r['ok'] and r['http'] == 200 and r['downloaded' if direction == 'download' else 'uploaded'] == size
                    r.pop('body', None); r['complete'] = complete
                    r['mbps'] = round(size * 8 / r['seconds'] / 1e6, 2) if complete and r['seconds'] else None
                    samples[direction].append(r)
        for direction, attr in [('download', 'download_mbps'), ('upload', 'upload_mbps')]:
            rates = [r['mbps'] for r in samples[direction] if r['complete']]
            setattr(node, attr, round(statistics.median(rates), 2) if rates else None)
        node.speed_samples = samples
        self.emit('log', f'{node.host}: скачивание {node.download_mbps or "—"}, отдача {node.upload_mbps or "—"} Мбит/с')
        self.emit('node', asdict(node))

    def save(self, nodes):
        nodes = sorted(nodes, key=lambda n: -(n.download_mbps or 0))
        links = []
        for i, n in enumerate(nodes, 1):
            u, _ = query(n.uri)
            label = f'{i:02d}-{n.country}-Reality-{n.host}-{dt.date.today().isoformat()}'
            links.append(urlunsplit((u.scheme, u.netloc, u.path, u.query, quote(label))))
        (self.run_dir / 'vless-reality.txt').write_text('\n'.join(links) + ('\n' if links else ''), encoding='utf-8')
        report = {'checked_at': dt.datetime.now(dt.timezone.utc).isoformat(), 'interface': self.options.interface,
            'stability_minutes': self.options.stability_minutes,
            'sources': self.options.sources, 'method': 'Four independent Xray starts; HTTPS Cloudflare trace, plus Google 204 on checks 2-4. Speed: two single-stream 2 MiB downloads and two 512 KiB uploads; median successful complete transfers including setup. OpenAI 401 only confirms endpoint reachability; Dots/account eligibility not tested. No uptime guarantee.',
            'nodes': [asdict(n) for n in nodes]}
        (self.run_dir / 'report.json').write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding='utf-8')
        (self.run_dir / 'all-checks.json').write_text(json.dumps([asdict(n) for n in self.candidates if n.checks], ensure_ascii=False, indent=2), encoding='utf-8')
        self.results = nodes
        self.emit('saved', str(self.run_dir))

    def run(self, supplied_uris=None):
        final = []
        try:
            if not self.xray.exists(): raise RuntimeError('Нет bin/xray.exe. Распакуйте весь архив утилиты.')
            if hashlib.sha256(self.xray.read_bytes()).hexdigest() != executable_hash():
                raise RuntimeError('SHA256 Xray не совпадает с проверенным бинарным файлом версии 26.3.27')
            if not self.options.countries <= ELIGIBLE or not self.options.countries: raise ValueError('Некорректные страны')
            if not 1 <= self.options.workers <= 8 or not 1 <= self.options.target <= 30: raise ValueError('Некорректные лимиты')
            self.emit('log', 'Проверяю интернет и загружаю свежие списки GitHub…')
            with self.tunnel() as port:
                baseline = self.request(port, 'https://www.cloudflare.com/cdn-cgi/trace')
                if not baseline['ok'] or baseline['http'] != 200:
                    raise RuntimeError('Контрольный HTTPS-запрос не проходит. Выберите физическую сетевую карту вместо TUN.')
                self.emit('log', 'Контрольный HTTPS-запрос прошёл')
                all_nodes = []
                if supplied_uris is not None:
                    all_nodes = parse_nodes(supplied_uris, 'Вставленный список')
                else:
                    with futures.ThreadPoolExecutor(max_workers=4) as pool:
                        pending = {pool.submit(self.fetch, port, url, i): url for i, url in enumerate(self.options.sources)}
                        for f in futures.as_completed(pending):
                            self.guard()
                            try: all_nodes.extend(f.result())
                            except Cancelled: raise
                            except Exception as e: self.emit('log', 'Не удалось загрузить ' + pending[f] + ': ' + str(e))
            nodes = unique_nodes(all_nodes, self.options.countries, self.options.max_candidates)
            self.candidates = nodes
            if not nodes: raise RuntimeError('В загруженных источниках нет подходящих конфигураций')
            self.emit('log', f'Проверяю {len(nodes)} кандидатов; параллельных подключений: {self.options.workers}')
            iterator = iter(nodes); live = []; exits = set(); tested = 0
            with futures.ThreadPoolExecutor(max_workers=self.options.workers) as pool:
                pending = set()
                for _ in range(min(len(nodes), self.options.workers)): pending.add(pool.submit(self.check, next(iterator), 1))
                while pending:
                    self.guard()
                    done, pending = futures.wait(pending, timeout=.2, return_when=futures.FIRST_COMPLETED)
                    for f in done:
                        n, ok = f.result(); tested += 1
                        if ok and n.exit_ip not in exits: exits.add(n.exit_ip); live.append(n)
                        self.emit('progress', {'tested': tested, 'total': len(nodes), 'live': len(live), 'phase': 'Первый проход'})
                        if len(live) < max(self.options.target * 2, 8):
                            try: pending.add(pool.submit(self.check, next(iterator), 1))
                            except StopIteration: pass
            for phase in (2, 3):
                if not live: break
                self.emit('log', f'Повторное подключение {phase}/4: {len(live)} узлов. Пауза 15 секунд…')
                if self.cancel.wait(15): raise Cancelled()
                with futures.ThreadPoolExecutor(max_workers=2) as pool:
                    outcomes = list(pool.map(lambda n: self.check(n, phase), live))
                live = [n for n, ok in outcomes if ok]
            for n in live:
                self.guard()
                if self.options.speed:
                    self.emit('log', f'Короткий спидтест {n.host}…')
                    try: self.speed_test(n)
                    except Cancelled: raise
                    except Exception as e: self.emit('log', f'Спидтест {n.host}: {e}')
                n, ok = self.check(n, 4)
                if ok: n.status = 'Готов: 4/4 HTTPS'; final.append(n); self.emit('node', asdict(n))
            if self.options.stability_minutes and final:
                deadline = time.monotonic() + self.options.stability_minutes * 60
                phase = 5
                self.emit('log', f'Дополнительная проверка стабильности: {self.options.stability_minutes} мин, переподключение каждую минуту')
                while time.monotonic() < deadline and final:
                    if self.cancel.wait(min(60, max(0, deadline - time.monotonic()))): raise Cancelled()
                    with futures.ThreadPoolExecutor(max_workers=2) as pool:
                        outcomes = list(pool.map(lambda n: self.check(n, phase), final))
                    final = [n for n, ok in outcomes if ok]
                    phase += 1
                for n in final: n.status = f'Готов: {len(n.checks)}/{len(n.checks)} HTTPS'; self.emit('node', asdict(n))
            self.save(final)
            self.emit('done', {'count': len(final), 'cancelled': False})
        except Cancelled:
            self.save(final)
            self.emit('done', {'count': len(final), 'cancelled': True})
        except Exception as e:
            self.emit('error', str(e))
            self.save(final)
