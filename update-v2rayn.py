"""Update an existing Windows v2rayN setup without reloading its services."""

import argparse
import csv
import ctypes
from ctypes import wintypes
from contextlib import closing
from datetime import datetime
import io
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import uuid


REPOSITORY = "jellybebra/device-setup"


def running_app_dir():
    result = subprocess.run(
        ["tasklist.exe", "/FI", "IMAGENAME eq v2rayN.exe", "/FO", "CSV", "/NH"],
        capture_output=True, check=True, timeout=15,
    )
    rows = csv.reader(io.StringIO(result.stdout.decode("utf-8", errors="replace")))
    pids = [int(row[1]) for row in rows if row and row[0].lower() == "v2rayn.exe"]
    if len(pids) != 1:
        raise ValueError("Expected one running v2rayN. Specify --app-dir explicitly.")

    # Limited query access also works when v2rayN runs elevated.
    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
    kernel.OpenProcess.restype = wintypes.HANDLE
    kernel.QueryFullProcessImageNameW.argtypes = [
        wintypes.HANDLE, wintypes.DWORD, wintypes.LPWSTR, ctypes.POINTER(wintypes.DWORD),
    ]
    kernel.CloseHandle.argtypes = [wintypes.HANDLE]
    handle = kernel.OpenProcess(0x1000, False, pids[0])
    if not handle:
        raise ctypes.WinError(ctypes.get_last_error())
    try:
        buffer = ctypes.create_unicode_buffer(32768)
        size = wintypes.DWORD(len(buffer))
        if not kernel.QueryFullProcessImageNameW(handle, 0, buffer, ctypes.byref(size)):
            raise ctypes.WinError(ctypes.get_last_error())
        return Path(buffer.value).parent
    finally:
        kernel.CloseHandle(handle)


def fetch_json(url):
    # Windows ships curl; it handles IPv4/IPv6 fallback more reliably here than
    # urllib on networks using TUN. Never use a shell to construct this command.
    with tempfile.TemporaryDirectory(prefix="device-setup-download-") as folder:
        path = Path(folder) / "response.json"
        result = subprocess.run(
            ["curl.exe", "--fail", "--silent", "--show-error", "--location",
             "--connect-timeout", "10", "--max-time", "20", "--retry", "2",
             "--retry-all-errors", "--output", str(path),
             "--user-agent", "device-setup-v2rayn", url],
            capture_output=True, timeout=75,
        )
        if result.returncode:
            raise OSError(f"Cannot download {url}: {result.stderr.decode('utf-8', errors='replace').strip()}")
        return json.loads(path.read_text(encoding="utf-8-sig"))


def load_rules(local):
    if local:
        folder = Path(__file__).resolve().parent / "configs/v2rayn/windows"
        template = json.loads((folder / "xray-template.json").read_text(encoding="utf-8-sig"))
        rules = json.loads((folder / "routes.json").read_text(encoding="utf-8-sig"))
        source = str(folder)
    else:
        # Pin both files to one commit, even if main changes during the download.
        sha = fetch_json(f"https://api.github.com/repos/{REPOSITORY}/commits/main")["sha"]
        base = f"https://raw.githubusercontent.com/{REPOSITORY}/{sha}/configs/v2rayn/windows"
        template = fetch_json(f"{base}/xray-template.json")
        rules = fetch_json(f"{base}/routes.json")
        source = f"{REPOSITORY}@{sha[:12]}"
    if not isinstance(template, dict) or not template.get("routing", {}).get("rules"):
        raise ValueError("Empty or invalid Xray template.")
    if not isinstance(rules, list) or not rules:
        raise ValueError("Empty or invalid routing profile.")
    for rule in rules:
        if not isinstance(rule, dict) or rule.get("outboundTag") not in {"direct", "proxy", "block"}:
            raise ValueError("Invalid routing rule.")
        if rule.get("enabled") is not True:
            raise ValueError("Source contains a disabled routing rule.")
    return template, rules, source


def normalize(rule):
    return {key.lower(): value for key, value in rule.items()
            if key.lower() != "id" and value is not None}


def connect(path, mode="rw"):
    return sqlite3.connect(path.resolve().as_uri() + f"?mode={mode}", uri=True, timeout=15)


def target_rows(db):
    templates = db.execute(
        "SELECT * FROM FullConfigTemplateItem WHERE Enabled=1 AND CoreType=2"
    ).fetchall()
    routes = db.execute("SELECT * FROM RoutingItem WHERE IsActive=1").fetchall()
    if len(templates) != 1 or len(routes) != 1:
        raise ValueError("Expected one enabled Xray template and one active routing profile.")
    if routes[0]["Remarks"] != "device-setup-windows":
        raise ValueError("Active profile is not device-setup-windows. Select it in v2rayN first.")
    return dict(templates[0]), dict(routes[0])


def validate_xray(app_dir, template):
    # v2rayN adds the selected server's outbounds to the full template on Reload.
    runtime = json.loads((app_dir / "binConfigs/config.json").read_text(encoding="utf-8-sig"))
    candidate = dict(template)
    candidate["outbounds"] = runtime["outbounds"]
    env = dict(os.environ, XRAY_LOCATION_ASSET=str(app_dir / "bin"))
    with tempfile.TemporaryDirectory(prefix="device-setup-xray-") as folder:
        path = Path(folder) / "config.json"
        path.write_text(json.dumps(candidate, ensure_ascii=False), encoding="utf-8")
        result = subprocess.run(
            [str(app_dir / "bin/xray/xray.exe"), "run", "-test", "-config", str(path)],
            cwd=app_dir / "bin", env=env, capture_output=True, timeout=30,
        )
        if result.returncode:
            output = (result.stdout + result.stderr).decode("utf-8", errors="replace")
            raise ValueError(f"Xray validation failed; no settings changed.\n{output}")


def update(app_dir, template, rules, backup_root, check=False):
    app_dir = app_dir.resolve()
    db_path = app_dir / "guiConfigs/guiNDB.db"
    config_path = app_dir / "guiConfigs/guiNConfig.json"
    config_bytes = config_path.read_bytes()
    db = connect(db_path)
    db.row_factory = sqlite3.Row
    try:
        before = target_rows(db)
        saved_template, saved_route = before
        old_rules = json.loads(saved_route["RuleSet"])
        current = (
            all(json.loads(saved_template[field]) == template for field in ("Config", "TunConfig"))
            and [normalize(r) for r in old_rules] == [normalize(r) for r in rules]
            and saved_route["RuleNum"] == len(rules)
        )
        if current and not check:
            print("Already up to date. No changes or reload performed.")
            return None
        validate_xray(app_dir, template)
        print("Xray validation: OK")
        if check:
            print(f"{'Already current' if current else 'Update available'}: {len(rules)} routing rules. No changes made.")
            return None

        new_rules = []
        for rule in rules:
            previous = next((r for r in old_rules if normalize(r) == normalize(rule)), None)
            new_rules.append(previous or {
                "Id": uuid.uuid4().hex,
                **{key[0].upper() + key[1:]: value for key, value in rule.items()},
            })
        text = json.dumps(template, ensure_ascii=False, indent=2)

        db.execute("BEGIN IMMEDIATE")
        try:
            if target_rows(db) != before or config_path.read_bytes() != config_bytes:
                raise ValueError("v2rayN settings changed during validation. Run the script again.")
            backup = backup_root / (datetime.now().strftime("routing-%Y%m%d-%H%M%S-") + uuid.uuid4().hex[:8])
            backup.mkdir(parents=True)
            # Use a second reader: backup on the connection holding the write
            # transaction would wait for that same transaction to finish.
            with closing(connect(db_path, "ro")) as source, closing(sqlite3.connect(backup / "guiNDB.db")) as dest:
                source.backup(dest)
            (backup / "guiNConfig.json").write_bytes(config_bytes)
            db.execute("UPDATE FullConfigTemplateItem SET Config=?,TunConfig=? WHERE Id=?",
                       (text, text, saved_template["Id"]))
            db.execute("UPDATE RoutingItem SET RuleSet=?,RuleNum=? WHERE Id=?",
                       (json.dumps(new_rules, ensure_ascii=False), len(new_rules), saved_route["Id"]))
            actual_template, actual_route = target_rows(db)
            if (any(json.loads(actual_template[field]) != template for field in ("Config", "TunConfig"))
                    or json.loads(actual_route["RuleSet"]) != new_rules
                    or actual_route["RuleNum"] != len(rules)
                    or db.execute("PRAGMA integrity_check").fetchone()[0] != "ok"):
                raise ValueError("Saved settings failed verification; transaction rolled back.")
            db.commit()
        except BaseException:
            db.rollback()
            raise
        print(f"Updated both Xray templates and device-setup-windows: {len(old_rules)} -> {len(rules)} rules.")
        print(f"Backup: {backup}")
        print("Services were not reloaded. Press Reload in v2rayN when ready.")
        print("If a site still redirects or fails, fully restart the browser after Reload.")
        return backup
    finally:
        db.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app-dir", type=Path, help="v2rayN folder (default: running process)")
    parser.add_argument("--local", action="store_true", help="use this checkout instead of GitHub main")
    parser.add_argument("--check", action="store_true", help="validate and compare without updating")
    args = parser.parse_args()
    if os.name != "nt":
        parser.error("This script updates the Windows profile only.")
    try:
        app_dir = args.app_dir or running_app_dir()
        print(f"v2rayN: {app_dir}")
        template, rules, source = load_rules(args.local)
        print(f"Rules: {source}")
        update(app_dir, template, rules, Path(os.environ["LOCALAPPDATA"]) / "v2rayN-backups", args.check)
        return 0
    except (OSError, ValueError, KeyError, TypeError, sqlite3.Error, subprocess.SubprocessError) as error:
        print(f"Error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
