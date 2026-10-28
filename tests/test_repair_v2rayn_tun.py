from contextlib import closing
import importlib.util
import json
from pathlib import Path
import sqlite3
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("repair", Path(__file__).parents[1] / "repair-v2rayn-tun.py")
repair = importlib.util.module_from_spec(spec)
spec.loader.exec_module(repair)


class RepairTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "guiConfigs").mkdir()
        self.config = self.root / "guiConfigs/guiNConfig.json"
        self.config.write_text('{"TunModeItem":{"EnableTun":true}}')
        self.path = self.root / "guiConfigs/guiNDB.db"
        self.dns = {
            "servers": [{"type": "hosts", "tag": "hosts_dns", "predefined": {"dns.google": ["8.8.8.8"]}},
                        {"type": "https", "tag": "remote", "server": "1.1.1.1"}],
            "rules": [{"server": "hosts_dns", "ip_accept_any": True},
                      {"server": "remote", "domain_suffix": ["discord.com"]}],
            "final": "remote", "independent_cache": True,
        }
        with closing(sqlite3.connect(self.path)) as db, db:
            db.executescript("CREATE TABLE DNSItem(Id TEXT PRIMARY KEY, CoreType INT, Enabled INT, NormalDNS TEXT, TunDNS TEXT); CREATE TABLE ProfileItem(Id TEXT, Secret TEXT);")
            db.executemany("INSERT INTO DNSItem VALUES (?,?,?,?,?)", [
                ("active", 24, 1, json.dumps(self.dns), json.dumps(self.dns)),
                ("disabled", 24, 0, json.dumps(self.dns), json.dumps(self.dns)),
                ("xray", 2, 1, "{}", "{}"),
            ])
            db.execute("INSERT INTO ProfileItem VALUES ('server','unchanged')")
        self.validation = patch.object(repair, "validate").start()
        self.addCleanup(patch.stopall)

    def snapshot(self, path=None):
        with closing(sqlite3.connect(path or self.path)) as db:
            return (db.execute("SELECT * FROM DNSItem ORDER BY Id").fetchall(),
                    db.execute("SELECT * FROM ProfileItem").fetchall())

    def test_preserves_routes_servers_other_profiles_and_backup(self):
        before = self.snapshot()
        backup = repair.repair(self.root)
        self.assertEqual(self.snapshot(backup / "guiNDB.db"), before)
        after = self.snapshot()
        self.assertEqual(before[0][1:], after[0][1:])
        self.assertEqual(before[1], after[1])
        normal, tun = after[0][0][3:]
        self.assertEqual(normal, tun)
        dns = json.loads(tun)
        self.assertEqual(dns["servers"], self.dns["servers"])
        self.assertEqual(dns["rules"][0], {"server": "hosts_dns", "domain": ["dns.google"]})
        self.assertEqual(dns["rules"][1:], self.dns["rules"][1:])
        self.assertEqual(self.config.read_bytes(), (backup / "guiNConfig.json").read_bytes())
        self.assertIsNone(repair.repair(self.root))
        self.assertEqual(self.snapshot(), after)
        self.assertEqual(len(list((self.root / "backups").iterdir())), 1)

    def test_check_and_validation_failure_do_not_write(self):
        before = self.snapshot()
        repair.repair(self.root, check=True)
        self.assertEqual(self.snapshot(), before)
        self.assertFalse((self.root / "backups").exists())
        self.validation.side_effect = ValueError("invalid core config")
        with self.assertRaisesRegex(ValueError, "invalid core"):
            repair.repair(self.root)
        self.assertEqual(self.snapshot(), before)

    def test_unknown_hosts_semantics_are_rejected(self):
        for extra in [{"path": ["/etc/hosts"]}, {"predefined": {"*.example.com": ["1.1.1.1"]}}]:
            dns = json.loads(json.dumps(self.dns))
            dns["servers"][0].update(extra)
            with self.assertRaisesRegex(ValueError, "Unsupported"):
                repair.migrate_dns(json.dumps(dns))

    def test_empty_and_unrelated_dns_are_unchanged(self):
        self.assertEqual(repair.migrate_dns(""), "")
        value = '{"rules": [{"server":"other", "ip_accept_any":true}]}'
        self.assertEqual(repair.migrate_dns(value), value)

    def test_concurrent_edit_is_preserved(self):
        def edit(*args):
            with closing(sqlite3.connect(self.path)) as db, db:
                db.execute("UPDATE DNSItem SET TunDNS='{}' WHERE Id='active'")
        self.validation.side_effect = edit
        with self.assertRaisesRegex(ValueError, "changed during validation"):
            repair.repair(self.root)
        self.assertFalse((self.root / "backups").exists())

    def test_database_failure_rolls_back(self):
        before = self.snapshot()
        with closing(sqlite3.connect(self.path)) as db, db:
            db.execute("CREATE TRIGGER fail BEFORE UPDATE ON DNSItem BEGIN SELECT RAISE(ABORT,'test failure'); END")
        with self.assertRaises(sqlite3.IntegrityError):
            repair.repair(self.root)
        self.assertEqual(self.snapshot(), before)


if __name__ == "__main__":
    unittest.main()
