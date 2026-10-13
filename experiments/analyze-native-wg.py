"""Pair private UDP echo packets using kernel timestamps, independent of reader lag."""
import argparse
from collections import defaultdict
import datetime
import json
import math
from pathlib import Path
import statistics


def stats(values):
    values = sorted(values)
    return dict(n=len(values), median_ms=round(statistics.median(values), 3) if values else None,
                p95_ms=round(values[math.ceil(len(values)*.95)-1], 3) if values else None,
                p99_ms=round(values[math.ceil(len(values)*.99)-1], 3) if values else None,
                max_ms=round(max(values), 3) if values else None)


def analyze(path, phases=None):
    pairs = defaultdict(lambda: {'out': [], 'in': []})
    read_lag = []
    malformed = 0
    for line in path.read_text().splitlines():
        try:
            row = json.loads(line)
        except ValueError:
            malformed += 1
            continue
        if (row['src'], row['dst'], row['dport']) == ('10.203.13.4', '10.203.13.1', 19516):
            direction, port = 'out', row['sport']
        elif (row['src'], row['dst'], row['sport']) == ('10.203.13.1', '10.203.13.4', 19516):
            direction, port = 'in', row['dport']
        else:
            continue
        pairs[(row['payload_hash'], port, row['length'])][direction].append(row['at'])
        read_lag.append((row['read_at']-row['at'])*1000)
    rtt = []
    phase_rtt = defaultdict(list)
    boundaries = sorted((datetime.datetime.fromisoformat(p['at']).timestamp(), p['phase']) for p in (phases or []))
    ambiguous = unmatched = reversed_time = 0
    for sides in pairs.values():
        if len(sides['out']) > 1 or len(sides['in']) > 1:
            ambiguous += 1
        elif not sides['out'] or not sides['in']:
            unmatched += 1
        elif sides['in'][0] < sides['out'][0]:
            reversed_time += 1
        else:
            elapsed = (sides['in'][0]-sides['out'][0])*1000
            rtt.append(elapsed)
            matches = [name for at, name in boundaries if at <= sides['out'][0]]
            if matches:
                phase_rtt[matches[-1]].append(elapsed)
    return dict(kernel_rtt=stats(rtt), capture_reader_lag=stats(read_lag),
                kernel_by_phase={name: stats(rows) for name, rows in phase_rtt.items()},
                ambiguous_keys=ambiguous, unmatched_keys=unmatched,
                reversed_time_keys=reversed_time, malformed_lines=malformed)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('capture', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--phases', type=Path)
    args = parser.parse_args()
    result = analyze(args.capture, json.loads(args.phases.read_text(encoding='utf-8-sig')) if args.phases else None)
    args.output.write_text(json.dumps(result, indent=2), encoding='utf-8')
    print(json.dumps(result, indent=2))
