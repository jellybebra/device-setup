import importlib.util
import pathlib
import unittest

p = pathlib.Path(__file__).with_name('disable-snapshot-copies.py')
spec = importlib.util.spec_from_file_location('snapshot_policy', p)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


class SnapshotPolicy(unittest.TestCase):
    def test_removes_copies_and_preserves_probe_loop(self):
        source = ("local setup=true\n local incident_at=0\n  log('probes',row)\n"
                  "  -- Keep metadata around target-specific failures\n"
                  "  os.execute('cp '..dir..'/packets.jsonl* '..dir..'/incident/')\n"
                  "  log('events',{event='incident_snapshot'})\n"
                  "  local remain=10\nend\n")
        result = m.remove_snapshot_copies(source)
        self.assertNotIn("os.execute('cp ", result)
        self.assertNotIn('incident_at', result)
        self.assertIn("log('probes',row)", result)
        self.assertTrue(result.endswith('  local remain=10\nend\n'))
        self.assertEqual(m.remove_snapshot_copies(result), result)

    def test_refuses_unknown_source(self):
        with self.assertRaises(ValueError):
            m.remove_snapshot_copies('local unknown=true')
