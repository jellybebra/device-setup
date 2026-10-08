from contextlib import closing
import importlib.util
import json
from pathlib import Path
import sqlite3
import tempfile
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location("updater", Path(__file__).parents[1] / "update-v2rayn.py")
updater = importlib.util.module_from_spec(spec)
spec.loader.exec_module(updater)


class UpdateTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.app = Path(self.temp.name) / "app"
        (self.app / "guiConfigs").mkdir(parents=True)
        self.config = self.app / "guiConfigs/guiNConfig.json"
        self.config.write_text('{"IndexId":"keep-server","TunModeItem":{"EnableTun":true}}')
        self.path = self.app / "guiConfigs/guiNDB.db"
        self.backups = Path(self.temp.name) / "backups"
        self.old_template = {"routing": {"rules": [{"outboundTag": "direct"}]}}
        self.template = {"routing": {"rules": [{"outboundTag": "proxy"}]}}
        self.old_rule = {"Id": "keep-rule", "Domain": ["domain:example.com"], "OutboundTag": "proxy", "Enabled": True}
        self.rules = [
            {"domain": ["domain:example.com"], "outboundTag": "proxy", "enabled": True},
            {"domain": ["domain:claude.com"], "outboundTag": "proxy", "enabled": True},
        ]
        with closing(sqlite3.connect(self.path)) as db, db:
            db.executescript('''
                CREATE TABLE FullConfigTemplateItem (Id TEXT PRIMARY KEY, Enabled INTEGER, CoreType INTEGER, Config TEXT, TunConfig TEXT, AddProxyOnly INTEGER);
                CREATE TABLE RoutingItem (Id TEXT PRIMARY KEY, Remarks TEXT, IsActive INTEGER, RuleSet TEXT, RuleNum INTEGER, Enabled INTEGER);
                CREATE TABLE ProfileItem (Id TEXT PRIMARY KEY, Secret TEXT);
                INSERT INTO ProfileItem VALUES ('server', 'untouched');
            ''')
            db.execute("INSERT INTO FullConfigTemplateItem VALUES ('xray',1,2,?,?,0)",
                       (json.dumps(self.old_template), json.dumps(self.old_template)))
            db.execute("INSERT INTO FullConfigTemplateItem VALUES ('sing',0,24,'{}','{}',1)")
            db.execute("INSERT INTO RoutingItem VALUES ('active','device-setup-windows',1,?,1,1)", (json.dumps([self.old_rule]),))
            db.execute("INSERT INTO RoutingItem VALUES ('other','Other',0,'[]',0,1)")
        self.validation = patch.object(updater, "validate_xray")
        self.mock_validation = self.validation.start()
        self.addCleanup(self.validation.stop)

    def snapshot(self, path=None):
        with closing(sqlite3.connect(path or self.path)) as db:
            return {table: db.execute(f"SELECT * FROM {table} ORDER BY Id").fetchall()
                    for table in ("FullConfigTemplateItem", "RoutingItem", "ProfileItem")}

    def run_update(self, **kwargs):
        return updater.update(self.app, self.template, self.rules, self.backups, **kwargs)

    def test_update_backup_preservation_and_idempotency(self):
        before = self.snapshot()
        config_before = self.config.read_bytes()
        backup = self.run_update()
        self.assertEqual(before, self.snapshot(backup / "guiNDB.db"))
        after = self.snapshot()
        self.assertEqual(before["ProfileItem"], after["ProfileItem"])
        self.assertEqual(before["RoutingItem"][1], after["RoutingItem"][1])
        self.assertEqual(before["FullConfigTemplateItem"][0], after["FullConfigTemplateItem"][0])
        self.assertEqual(config_before, self.config.read_bytes())
        self.assertEqual(config_before, (backup / "guiNConfig.json").read_bytes())
        self.assertEqual(json.loads(after["RoutingItem"][0][3])[0]["Id"], "keep-rule")
        self.assertEqual(after["RoutingItem"][0][4], 2)
        self.assertEqual(json.loads(after["FullConfigTemplateItem"][1][3]), self.template)
        self.assertEqual(after["FullConfigTemplateItem"][1][3], after["FullConfigTemplateItem"][1][4])
        self.assertIsNone(self.run_update())
        self.assertEqual(after, self.snapshot())
        self.assertEqual(len(list(self.backups.iterdir())), 1)

    def test_check_does_not_write_or_backup(self):
        before = self.snapshot()
        self.run_update(check=True)
        self.assertEqual(before, self.snapshot())
        self.assertFalse(self.backups.exists())
        self.mock_validation.assert_called_once()

    def test_validation_failure_does_not_write(self):
        before = self.snapshot()
        self.mock_validation.side_effect = ValueError("invalid Xray")
        with self.assertRaisesRegex(ValueError, "invalid Xray"):
            self.run_update()
        self.assertEqual(before, self.snapshot())
        self.assertFalse(self.backups.exists())

    def test_unrelated_active_profile_is_rejected(self):
        with closing(sqlite3.connect(self.path)) as db, db:
            db.execute("UPDATE RoutingItem SET Remarks='personal' WHERE IsActive=1")
        before = self.snapshot()
        with self.assertRaisesRegex(ValueError, "not device-setup-windows"):
            self.run_update()
        self.assertEqual(before, self.snapshot())

    def test_transaction_rolls_back_if_second_write_fails(self):
        with closing(sqlite3.connect(self.path)) as db, db:
            db.execute("CREATE TRIGGER fail_update BEFORE UPDATE ON RoutingItem BEGIN SELECT RAISE(ABORT,'test failure'); END")
        before = self.snapshot()
        with self.assertRaisesRegex(sqlite3.IntegrityError, "test failure"):
            self.run_update()
        self.assertEqual(before, self.snapshot())

    def test_concurrent_edit_is_not_overwritten(self):
        def edit(*args):
            with closing(sqlite3.connect(self.path)) as db, db:
                db.execute("UPDATE FullConfigTemplateItem SET AddProxyOnly=1 WHERE Id='xray'")
        self.mock_validation.side_effect = edit
        with self.assertRaisesRegex(ValueError, "changed during validation"):
            self.run_update()
        self.assertFalse(self.backups.exists())
        self.assertEqual(self.snapshot()["FullConfigTemplateItem"][1][5], 1)
        self.assertEqual(json.loads(self.snapshot()["FullConfigTemplateItem"][1][3]), self.old_template)

    def test_download_pins_both_files_to_same_commit(self):
        sha = "a" * 40
        with patch.object(updater, "fetch_json", side_effect=[{"sha": sha}, self.template, self.rules]) as fetch:
            template, rules, source = updater.load_rules(False)
        self.assertEqual(template, self.template)
        self.assertEqual(rules, self.rules)
        for call in fetch.call_args_list[1:]:
            self.assertIn(f"/{sha}/", call.args[0])
        self.assertIn(sha[:12], source)


if __name__ == "__main__":
    unittest.main()
