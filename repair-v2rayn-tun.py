"""Repair saved custom sing-box DNS profiles that prevent TUN startup in 1.14+."""

import argparse
from contextlib import closing
from copy import deepcopy
from datetime import datetime
import json
import os
from pathlib import Path
import re
import sqlite3
import subprocess
import sys
import tempfile
import uuid


def migrate_dns(text):
    """Replace the legacy catch-all hosts lookup with explicit known hostnames."""
    if not text:
        return text
    dns = json.loads(text)
    changed = False
    servers = {s.get("tag"): s for s in dns.get("servers", [])}
    for rule in dns.get("rules", []):
        server = servers.get(rule.get("server"), {})
        if server.get("type") != "hosts" or rule.get("ip_accept_any") is not True:
            continue
        hosts = server.get("predefined", {})
        # Do not guess how to migrate system hosts, wildcard entries or a rule
        # with additional matching/action options. Leave the database untouched.
        if (set(rule) != {"server", "ip_accept_any"}
                or set(server) - {"type", "tag", "predefined"}
                or not hosts
                or any(not re.fullmatch(r"[A-Za-z0-9_-]+(?:\.[A-Za-z0-9_-]+)*\.?", h)
                       or not addresses for h, addresses in hosts.items())):
            raise ValueError("Unsupported legacy hosts rule; no settings changed.")
        del rule["ip_accept_any"]
        rule["domain"] = list(hosts)
        changed = True
    if not changed:
        return text
    dns.pop("independent_cache", None)
    return json.dumps(dns, ensure_ascii=False, indent=2)


def connect(path, mode="rw"):
    return sqlite3.connect(path.resolve().as_uri() + f"?mode={mode}", uri=True, timeout=15)


def rows(db):
    return db.execute(
        "SELECT Id,NormalDNS,TunDNS FROM DNSItem WHERE CoreType=24 AND Enabled=1 ORDER BY Id"
    ).fetchall()


def validate(data_dir, dns_text):
    runtime_path = data_dir / "binConfigs/configPre.json"
    runtime = json.loads(runtime_path.read_text(encoding="utf-8-sig"))
    if not any(i.get("type") == "tun" for i in runtime.get("inbounds", [])):
        raise ValueError("configPre.json is not a sing-box TUN configuration.")
    candidate = deepcopy(runtime)
    candidate["dns"] = json.loads(dns_text)
    # v2rayN adds bootstrap resolvers referenced by the generated outbounds.
    tags = {s.get("tag") for s in candidate["dns"].get("servers", [])}
    candidate["dns"].setdefault("servers", []).extend(
        s for s in runtime["dns"].get("servers", []) if s.get("tag") not in tags
    )
    core = data_dir / "bin/sing_box" / ("sing-box.exe" if os.name == "nt" else "sing-box")
    with tempfile.TemporaryDirectory(prefix="v2rayn-tun-check-") as directory:
        path = Path(directory) / "config.json"
        path.write_text(json.dumps(candidate), encoding="utf-8")
        result = subprocess.run(
            [str(core), "check", "-c", str(path)], cwd=runtime_path.parent,
            capture_output=True, text=True, timeout=30,
        )
        if result.returncode:
            raise ValueError("sing-box validation failed; no settings changed.\n" + result.stderr)


def repair(data_dir, check=False):
    data_dir = data_dir.resolve()
    db_path = data_dir / "guiConfigs/guiNDB.db"
    config_path = data_dir / "guiConfigs/guiNConfig.json"
    config_bytes = config_path.read_bytes()
    with closing(connect(db_path)) as db:
        before = rows(db)
        changes = []
        for identity, normal, tun in before:
            fixed = [migrate_dns(value) for value in (normal, tun)]
            if fixed != [normal, tun]:
                for old, new in zip((normal, tun), fixed):
                    if old != new:
                        validate(data_dir, new)
                changes.append((*fixed, identity))
        if not changes:
            print("No matching legacy custom DNS rules. No changes made.")
            return None
        if check:
            print(f"Repair available for {len(changes)} profile(s); sing-box validation passed. No changes made.")
            return None
        db.execute("BEGIN IMMEDIATE")
        try:
            if rows(db) != before or config_path.read_bytes() != config_bytes:
                raise ValueError("v2rayN settings changed during validation; retry the repair.")
            backup = data_dir / "backups" / (datetime.now().strftime("tun-dns-%Y%m%d-%H%M%S-") + uuid.uuid4().hex[:8])
            backup.mkdir(parents=True, mode=0o700)
            with closing(connect(db_path, "ro")) as source, closing(sqlite3.connect(backup / "guiNDB.db")) as dest:
                source.backup(dest)
            (backup / "guiNConfig.json").write_bytes(config_bytes)
            for path in backup.iterdir():
                path.chmod(0o600)
            db.executemany("UPDATE DNSItem SET NormalDNS=?,TunDNS=? WHERE Id=?", changes)
            actual = {r[0]: r[1:] for r in rows(db)}
            if (any(actual[identity] != (normal, tun) for normal, tun, identity in changes)
                    or db.execute("PRAGMA integrity_check").fetchone()[0] != "ok"):
                raise ValueError("Saved DNS verification failed.")
            db.commit()
        except BaseException:
            db.rollback()
            raise
    print(f"Repaired saved normal/TUN DNS profiles. Backup: {backup}")
    print("Press Reload in v2rayN, then verify sing-box stays running and reconnect voice if necessary.")
    return backup


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--data-dir", type=Path, help="folder containing guiConfigs, binConfigs and bin")
    parser.add_argument("--check", action="store_true", help="validate the repair without writing")
    args = parser.parse_args()
    data_dir = args.data_dir
    if data_dir is None:
        if sys.platform != "darwin":
            parser.error("Specify --data-dir for this platform.")
        data_dir = Path.home() / "Library/Application Support/v2rayN"
    try:
        repair(data_dir, check=args.check)
    except (OSError, ValueError, sqlite3.Error, subprocess.SubprocessError) as error:
        parser.exit(1, f"{error}\n")


if __name__ == "__main__":
    main()
