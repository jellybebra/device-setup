"""Pair passive WinDivert observations; never infer Internet loss from missing copies."""
import argparse
import collections
import datetime
import json
import math
from pathlib import Path
import statistics


def stats(values):
    v = sorted(values)
    if not v:
        return {"n": 0}
    return dict(n=len(v), median_ms=round(statistics.median(v), 3),
                p95_ms=round(v[math.ceil(len(v) * .95) - 1], 3),
                p99_ms=round(v[math.ceil(len(v) * .99) - 1], 3),
                max_ms=round(v[-1], 3), over50=sum(x > 50 for x in v))


def focus_intervals(samples, before=None):
    """Conservative 1 Hz focus windows; exclude three seconds after focus changes."""
    samples = sorted((s for s in samples if s.get('kind') == 'sample'), key=lambda s: s['at'])
    windows = []
    for a, b in zip(samples, samples[1:]):
        start = datetime.datetime.fromisoformat(a['at']).timestamp()
        end = datetime.datetime.fromisoformat(b['at']).timestamp()
        if (a.get('game_foreground') is True and b.get('game_foreground') is True
                and a.get('focus_unchanged_seconds', 0) >= 3 and 0 < end-start <= 2.5):
            end = min(end, before) if before is not None else end
            if end > start:
                windows.append((start, end))
    return windows


def analyze(rows, tun, physical, game_ports, phases=(), focus_windows=None):
    groups = collections.defaultdict(list)
    for r in rows:
        if r['iface'] not in (tun, physical):
            continue
        outbound = r['outbound']
        remote = r['dst'] if outbound else r['src']
        port = r['dport'] if outbound else r['sport']
        groups[(outbound, remote, port, r['length'], r['payload_hash'])].append(r)
    pairs, ambiguous, unmatched, invalid_order = [], 0, 0, 0
    unmatched_by_interface_port = collections.Counter()
    start, end = min(r['at'] for r in rows), max(r['at'] for r in rows)
    if focus_windows is not None:
        focus_windows = [(max(a, start), min(b, end)) for a, b in focus_windows
                         if max(a, start) < min(b, end)]
    for (outbound, remote, port, length, digest), group in groups.items():
        ts = [r for r in group if r['iface'] == tun]
        ps = [r for r in group if r['iface'] == physical]
        # Repeated identical payloads are ambiguous; do not manufacture matches.
        if len(ts) > 1 or len(ps) > 1:
            ambiguous += 1
            continue
        if not ts or not ps:
            if any(start + 3 < r['at'] < end - 3 for r in group):
                unmatched += 1
                unmatched_by_interface_port[f"if{group[0]['iface']}:remote-port-{port}"] += 1
            continue
        t, p = ts[0], ps[0]
        local_port = t['sport'] if outbound else t['dport']
        kind = 'game' if local_port in game_ports else 'stun' if port == 3478 else 'other'
        before, after = (t, p) if outbound else (p, t)
        ms = (after['at'] - before['at']) * 1000
        if ms < 0 or ms > 3000:
            invalid_order += 1
            continue
        phase = next((name for at, name in reversed(phases) if before['at'] >= at), 'unlabelled')
        pairs.append(dict(at=before['at'], phase=phase, kind=kind, direction='out' if outbound else 'in',
                          remote=remote, port=port, ms=ms,
                          steady_foreground=any(a <= before['at'] <= after['at'] <= b
                                                for a, b in (focus_windows or ()))))
    summary = []
    for kind, direction in sorted({(p['kind'], p['direction']) for p in pairs}):
        summary.append(dict(kind=kind, direction=direction,
                            **stats([p['ms'] for p in pairs if (p['kind'], p['direction']) == (kind, direction)])))
    servers = collections.Counter(p['remote'] for p in pairs if p['kind'] == 'game')
    by_phase = []
    for phase, kind, direction in sorted({(p['phase'], p['kind'], p['direction']) for p in pairs}):
        by_phase.append(dict(phase=phase, kind=kind, direction=direction,
                             **stats([p['ms'] for p in pairs if (p['phase'], p['kind'], p['direction']) == (phase, kind, direction)])))
    return dict(duration_seconds=round(end-start, 3), packets=len(rows), pairs=len(pairs),
                ambiguous_keys=ambiguous, unmatched_keys_away_from_capture_edges=unmatched,
                unmatched_by_interface_remote_port=dict(unmatched_by_interface_port),
                invalid_order_keys=invalid_order, game_servers=dict(servers), summary=summary,
                steady_foreground_seconds=sum(b-a for a, b in focus_windows) if focus_windows is not None else None,
                steady_foreground_summary=[dict(kind=kind, direction=direction,
                    **stats([p['ms'] for p in pairs if p['steady_foreground']
                             and (p['kind'], p['direction']) == (kind, direction)]))
                    for kind, direction in sorted({(p['kind'], p['direction']) for p in pairs})]
                    if focus_windows is not None else [],
                by_phase=by_phase if phases else [],
                worst_game=sorted((p for p in pairs if p['kind'] == 'game'), key=lambda p: p['ms'], reverse=True)[:8])


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('capture', type=Path)
    ap.add_argument('--tun', type=int, required=True)
    ap.add_argument('--physical', type=int, required=True)
    ap.add_argument('--game-port', type=int, action='append', required=True)
    ap.add_argument('--output', type=Path, required=True)
    ap.add_argument('--phases', type=Path, help='JSONL records with ISO at and phase fields')
    ap.add_argument('--focus-samples', type=Path, help='monitor-tun-latency JSONL; also report stable foreground pairs')
    ap.add_argument('--focus-before', help='Optional ISO cutoff for foreground summary only; not an inferred match end')
    args = ap.parse_args()
    rows = [json.loads(line) for line in args.capture.read_text().splitlines() if line.strip()]
    if not rows:
        raise SystemExit('Capture is empty')
    phases = []
    if args.phases:
        for line in args.phases.read_text(encoding='utf-8-sig').splitlines():
            r = json.loads(line)
            phases.append((datetime.datetime.fromisoformat(r['at']).timestamp(), r['phase']))
        phases.sort()
    windows = None
    if args.focus_samples:
        samples = [json.loads(line) for line in args.focus_samples.read_text(encoding='utf-8-sig').splitlines() if line.strip()]
        cutoff = datetime.datetime.fromisoformat(args.focus_before).timestamp() if args.focus_before else None
        windows = focus_intervals(samples, cutoff)
    result = analyze(rows, args.tun, args.physical, set(args.game_port), phases, windows)
    args.output.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()
