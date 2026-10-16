"""Export ru-blocked to independent Mihomo rule providers.

Clash Verge may replace geoip.dat/geosite.dat with bundled databases at startup.
Keep this custom category in separate files instead. Input DAT files must come
from a trusted source. Output is a frozen snapshot; rerun explicitly to update.
The protobuf field numbers follow Mihomo component/geodata/router/config.proto.
"""
import argparse
import hashlib
import ipaddress
import json
from pathlib import Path


def varint(data, pos):
    value = 0
    for shift in range(0, 70, 7):
        if pos >= len(data):
            raise ValueError('Truncated protobuf varint')
        byte = data[pos]
        pos += 1
        value |= (byte & 127) << shift
        if byte < 128:
            return value, pos
    raise ValueError('Oversized protobuf varint')


def fields(data):
    pos = 0
    while pos < len(data):
        tag, pos = varint(data, pos)
        number, wire = tag >> 3, tag & 7
        if not number:
            raise ValueError('Invalid protobuf field')
        if wire == 0:
            value, pos = varint(data, pos)
        elif wire in (1, 2, 5):
            if wire == 2:
                length, pos = varint(data, pos)
            else:
                length = 8 if wire == 1 else 4
            if pos + length > len(data):
                raise ValueError('Truncated protobuf field')
            value = data[pos:pos + length]
            pos += length
        else:
            raise ValueError(f'Unsupported protobuf wire type: {wire}')
        yield number, value


def category(data):
    for number, entry in fields(data):
        if number != 1:
            continue
        values = list(fields(entry))
        if any(n == 1 and v.decode().lower() == 'ru-blocked' for n, v in values):
            if any(n == 3 and v for n, v in values):
                raise ValueError('Reverse matching is unsupported')
            records = [v for n, v in values if n == 2]
            if not records:
                raise ValueError('Empty ru-blocked category')
            return records
    raise ValueError('ru-blocked category missing')


def export(geodata, output):
    """Validate both sets before writing. No silent dropping of domain types."""
    sources = {kind: (geodata / f'{kind}.dat').read_bytes()
               for kind in ('geoip', 'geosite')}
    networks = []
    for record in category(sources['geoip']):
        value = dict(fields(record))
        address = ipaddress.ip_address(value[1])
        networks.append(str(ipaddress.ip_network(f'{address}/{value.get(2, 0)}', strict=False)))
    domains = []
    for record in category(sources['geosite']):
        value = dict(fields(record))
        kind, domain = value.get(1, 0), value[2].decode()
        if kind not in (2, 3) or not domain or any(c in domain for c in '\r\n,*+'):
            raise ValueError('Only literal full/suffix domain entries are supported')
        domains.append(('+.' if kind == 2 else '') + domain)
    output.mkdir(parents=True, exist_ok=True)
    summary = {}
    for name, payload in [('ip', networks), ('domain', domains)]:
        # Mihomo's fast provider parser reads one YAML entry per line; a JSON
        # flow-style mapping is valid YAML but silently produces zero rules.
        encoded = ('payload:\n' + ''.join('  - ' + json.dumps(item) + '\n' for item in payload)).encode()
        path = output / f'ru-blocked-{name}.yaml'
        temporary = path.with_suffix('.tmp')
        temporary.write_bytes(encoded)
        temporary.replace(path)
        summary[name] = {'count': len(payload), 'sha256': hashlib.sha256(encoded).hexdigest()}
    summary['source_sha256'] = {k: hashlib.sha256(v).hexdigest() for k, v in sources.items()}
    (output / 'manifest.json').write_text(json.dumps(summary, indent=2) + '\n', encoding='utf-8')
    return summary


def isolate(profile, prefix='./rule-providers/device-setup'):
    """Keep rule ordering, targets and no-resolve; preserve unrelated providers."""
    providers = profile.setdefault('rule-providers', {})
    rewritten = []
    for rule in profile['rules']:
        parts = rule.split(',')
        if parts[0] in ('GEOIP', 'GEOSITE') and parts[1].lower() == 'ru-blocked':
            kind = 'ip' if parts[0] == 'GEOIP' else 'domain'
            name = f'device-setup-ru-blocked-{kind}'
            provider = {'type': 'file', 'behavior': 'ipcidr' if kind == 'ip' else 'domain',
                        'format': 'yaml', 'path': f'{prefix}/ru-blocked-{kind}.yaml'}
            if name in providers and providers[name] != provider:
                raise ValueError(f'Provider name collision: {name}')
            providers[name] = provider
            parts[:2] = ['RULE-SET', name]
        rewritten.append(','.join(parts))
    profile['rules'] = rewritten
    return profile


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--geodata', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--profile', type=Path, help='Optional JSON profile from build_profile.py')
    parser.add_argument('--profile-output', type=Path, help='New JSON/YAML profile; never overwritten')
    args = parser.parse_args()
    if bool(args.profile) != bool(args.profile_output):
        parser.error('--profile and --profile-output must be supplied together')
    if args.profile_output and args.profile_output.exists():
        parser.error('Refusing to overwrite a profile')
    profile = isolate(json.loads(args.profile.read_text(encoding='utf-8-sig'))) if args.profile else None
    print(json.dumps(export(args.geodata, args.output), indent=2))
    if profile is not None:
        with args.profile_output.open('x', encoding='utf-8') as stream:
            json.dump(profile, stream, indent=2, ensure_ascii=False)
