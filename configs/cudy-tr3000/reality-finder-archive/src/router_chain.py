"""Independent fixed-priority VPN relay: private primary, secondary, Finder.

Only this process changes its own Xray balancer. No UCI edits or service reloads
occur during failover. Probes cover TLS and SOCKS UDP; no direct fallback.
"""
from __future__ import annotations
import argparse
import concurrent.futures
import copy
import dataclasses
import ipaddress
import json
import os
import pathlib
import signal
import threading
import time

from router import DataLock, RouterCore
from router_subscription import load_private
from runtime import udp_query
from storage import Store, free_port


@dataclasses.dataclass
class Health:
    successes: int = 0
    failures: int = 0
    healthy: bool = False
    good_since: float | None = None
    checked_at: float = 0
    https: bool = False
    udp: bool = False

    def observe(self, https, udp, now):
        self.checked_at = now
        self.https, self.udp = https, udp
        if https and udp:
            self.failures = 0
            self.successes += 1
            if self.good_since is None:
                self.good_since = now
            if self.successes >= 2:
                self.healthy = True
        else:
            self.successes = 0
            self.good_since = None
            self.failures += 1
            if self.failures >= 2:
                self.healthy = False


class Priority:
    def __init__(self, count, recovery=60, freshness=40):
        self.states = [Health() for _ in range(count)]
        self.active = None
        self.recovery = recovery
        self.freshness = freshness

    def choose(self, now):
        eligible = [i for i, state in enumerate(self.states)
                    if state.healthy and now - state.checked_at <= self.freshness]
        if self.active not in eligible:
            return eligible[0] if eligible else None
        for i in eligible:
            state = self.states[i]
            if i < self.active and state.good_since is not None and now - state.good_since >= self.recovery:
                return i
        return self.active


def endpoint(outbound):
    settings = outbound['settings']
    return settings['vnext'][0] if 'vnext' in settings else settings


class ChainCore(RouterCore):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.routes = {}

    def prepare(self, index, definition):
        """Pin server DNS through independent DoH, avoiding VPN-DNS recursion."""
        original = definition['outbound']
        host = endpoint(original)['address']
        address = self.resolve(host)
        old = self.routes.get(index)
        if old and old['address'] == address:
            return old['port']
        out = copy.deepcopy(original)
        endpoint(out)['address'] = address
        # Match Core.add: transparent relay traffic must retain QUIC support.
        # Plain Vision rejects UDP/443 even when the server supports it.
        settings = out['settings']
        users = [user for server in settings.get('vnext', [])
                 for user in server.get('users', [])] if 'vnext' in settings else [settings]
        for user in users:
            if user.get('flow') == 'xtls-rprx-vision':
                user['flow'] = 'xtls-rprx-vision-udp443'
        out['tag'] = 'n-' + str(index)
        opts = out.setdefault('streamSettings', {}).setdefault('sockopt', {})
        opts['mark'] = self.mark
        # Loopback Finder must not be bound to the physical WAN interface.
        if ipaddress.ip_address(address).is_loopback:
            opts.pop('interface', None)
        else:
            opts['interface'] = self.interface
        opts['domainStrategy'] = 'UseIPv4'
        out.pop('proxySettings', None)
        opts.pop('dialerProxy', None)
        out['mux'] = {'enabled': False}
        port = old['port'] if old else free_port()
        tag = 'chain-probe-' + str(index)
        if old:
            import contextlib
            with contextlib.suppress(RuntimeError):
                self.api('rmo', out['tag'])
            old['address'] = None
        self.api('ado', config={'outbounds': [out]})
        if not old:
            try:
                self.api('adi', config={'inbounds': [{'tag': tag, 'listen': '127.0.0.1',
                    'port': port, 'protocol': 'socks', 'settings': {'auth': 'noauth', 'udp': True}}]})
                self.api('adrules', '-append', config={'routing': {'rules': [
                    {'ruleTag': tag, 'type': 'field', 'inboundTag': [tag], 'outboundTag': out['tag']}]}})
            except BaseException:
                import contextlib
                with contextlib.suppress(Exception): self.api('rmi', tag)
                with contextlib.suppress(Exception): self.api('rmo', out['tag'])
                raise
        self.routes[index] = {'port': port, 'address': address}
        return port


def probe(core, port, timeout):
    https = False
    # Different providers: an outage at one test target must not eject all VPNs.
    for url in ('https://www.gstatic.com/generate_204', 'https://www.cloudflare.com/cdn-cgi/trace'):
        try:
            reply = core.request(port, url, timeout=timeout)
            if reply['ok'] and reply['http'] in (200, 204):
                https = True
                break
        except Exception:
            pass
    udp = False
    for address in ('1.1.1.1', '8.8.8.8'):
        try:
            udp = udp_query(port, timeout=timeout, address=address)['ok']
            if udp: break
        except Exception:
            pass
    return https, udp


def write_status(path, value):
    temporary = path.with_suffix('.new')
    temporary.write_text(json.dumps(value, ensure_ascii=False))
    temporary.chmod(0o600)
    temporary.replace(path)


def serve(config_path, data):
    config = load_private(config_path)
    nodes = config['nodes']
    if len(nodes) != 3 or [n['name'] for n in nodes] != ['test', 'quiet', 'finder']:
        raise ValueError('Expected ordered test, quiet, finder nodes')
    if any(n['outbound']['protocol'] != 'vless' for n in nodes):
        raise ValueError('Only VLESS relay outbounds are supported')
    data.mkdir(parents=True, exist_ok=True, mode=0o700)
    data.chmod(0o700)
    lock = DataLock(data)
    stop = threading.Event()
    for signum in (signal.SIGINT, signal.SIGTERM):
        signal.signal(signum, lambda *_: stop.set())
    store = Store(data)
    store.put('profile', config['profile'])
    core = ChainCore(store, config.get('interface', 'auto'), xray=config['xray'],
                     expected_sha256=config['sha256'], quiet=True, mark=config.get('mark', 131327))
    interval, timeout = 10, 4
    # Worst failed probe: two HTTPS and two UDP destinations (16 s), plus DNS.
    policy = Priority(3, recovery=60, freshness=60)
    status_path = data / 'status.json'
    generation = 0
    refresh_at = 0
    changes = []
    try:
        with concurrent.futures.ThreadPoolExecutor(3, thread_name_prefix='chain-probe') as pool:
            while not stop.is_set():
                started = time.monotonic()
                core.start()
                if generation != core.generation:
                    generation = core.generation
                    core.routes.clear()
                    policy = Priority(3, recovery=60, freshness=60)
                    refresh_at = 0
                errors = {}
                if (started >= refresh_at or len(core.routes) < 3
                        or any(route['address'] is None for route in core.routes.values())):
                    for i, node in enumerate(nodes):
                        if stop.is_set(): break
                        try: core.prepare(i, node)
                        except Exception as error:
                            errors[node['name']] = type(error).__name__
                    refresh_at = time.monotonic() + 300
                futures = {i: pool.submit(probe, core, route['port'], timeout)
                           for i, route in core.routes.items()}
                for i, state in enumerate(policy.states):
                    if i in futures:
                        try: https, udp = futures[i].result()
                        except Exception: https, udp = False, False
                    else:
                        https, udp = False, False
                    state.observe(https, udp, time.monotonic())
                now = time.monotonic()
                selected = policy.choose(now)
                if selected != policy.active:
                    core.select(str(selected) if selected is not None else None)
                    change = {'at': time.time(), 'from': nodes[policy.active]['name'] if policy.active is not None else None,
                              'to': nodes[selected]['name'] if selected is not None else None}
                    changes.append(change)
                    changes = changes[-20:]
                    print(json.dumps({'switch': change}), flush=True)
                    policy.active = selected
                write_status(status_path, {'updated_at': time.time(), 'pid': os.getpid(),
                    'core_pid': core.process.pid, 'active': nodes[policy.active]['name'] if policy.active is not None else None,
                    'port': core.profile['port'], 'mark': core.mark,
                    'nodes': [{'name': node['name'], 'healthy': state.healthy,
                               'https': state.https, 'udp': state.udp,
                               'successes': state.successes, 'failures': state.failures,
                               'stable_seconds': round(now-state.good_since, 1) if state.good_since is not None else 0,
                               'probe_port': core.routes.get(i, {}).get('port')}
                              for i, (node, state) in enumerate(zip(nodes, policy.states))],
                    'changes': changes, 'errors': errors})
                stop.wait(max(0.2, interval - (time.monotonic()-started)))
    finally:
        core.stop()
        status_path.unlink(missing_ok=True)
        store.close()
        lock.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=('serve', 'status'))
    parser.add_argument('--config', type=pathlib.Path, default=pathlib.Path('/etc/reality-finder/chain.json'))
    parser.add_argument('--data', type=pathlib.Path, default=pathlib.Path('/tmp/reality-chain'))
    args = parser.parse_args()
    os.umask(0o077)
    if args.command == 'status':
        value = json.loads((args.data / 'status.json').read_text())
        value['stale'] = time.time() - value['updated_at'] > 60
        print(json.dumps(value, ensure_ascii=False, indent=2))
    else:
        serve(args.config, args.data)


if __name__ == '__main__':
    main()
