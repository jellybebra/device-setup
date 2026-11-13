"""Remove duplicate incident-ring copies from an existing diagnostic supervisor.

Only edits Lua source. Restart the owned supervisor separately after preserving
any existing incident evidence. Does not read profiles or stop production services.
"""
import argparse
import pathlib


def remove_snapshot_copies(source):
    marker = '  -- Keep metadata around target-specific failures'
    if marker not in source:
        if '-- Do not duplicate rings into incident directories' in source:
            return source
        raise ValueError('Unrecognized supervisor; refusing to edit')
    start = source.index(marker)
    end = source.index('  local remain=', start)
    block = source[start:end]
    if "cp '..dir..'/packets.jsonl*" not in block or "log('events'" not in block:
        raise ValueError('Unrecognized snapshot block; refusing to edit')
    source = source[:start] + (
        '  -- Packet metadata is buffered once and uploaded to the server archive.\n'
        "  -- Do not duplicate rings into incident directories on the router's tmpfs.\n"
    ) + source[end:]
    return source.replace(' local incident_at=0\n', '')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('supervisor', type=pathlib.Path)
    args = parser.parse_args()
    original = args.supervisor.read_text()
    result = remove_snapshot_copies(original)
    if result != original:
        backup = args.supervisor.with_suffix('.lua.before-snapshot-fix')
        if backup.exists():
            raise RuntimeError('Backup already exists; inspect before retrying')
        backup.write_text(original)
        staged = args.supervisor.with_suffix('.lua.new')
        staged.write_text(result)
        staged.chmod(args.supervisor.stat().st_mode & 0o777)
        staged.replace(args.supervisor)
