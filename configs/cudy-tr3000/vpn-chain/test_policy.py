import pathlib
import sys
import unittest

HERE = pathlib.Path(__file__).resolve().parent
sys.path[:0] = [str(HERE), str(HERE.parent / 'reality-finder-archive' / 'src')]
from router_chain import Priority


class TwoProviderPolicy(unittest.TestCase):
    def healthy(self, policy, index, at):
        policy.states[index].observe(True, True, at)
        policy.states[index].observe(True, True, at + 1)

    def test_primary_then_secondary_then_fail_closed(self):
        p = Priority(2)
        self.healthy(p, 0, 100)
        self.healthy(p, 1, 100)
        self.assertEqual(p.choose(101), 0)
        p.active = 0
        for t in [102, 103]:
            p.states[0].observe(False, False, t)
        self.assertEqual(p.choose(103), 1)
        p.active = 1
        for t in [104, 105]:
            p.states[1].observe(False, False, t)
        self.assertIsNone(p.choose(105))

    def test_recovery_delay_and_stale_health(self):
        p = Priority(2, recovery=60, freshness=60)
        self.healthy(p, 1, 100)
        p.active = 1
        self.healthy(p, 0, 110)
        self.assertEqual(p.choose(111), 1)
        for t in [140, 170]:
            p.states[0].observe(True, True, t)
            p.states[1].observe(True, True, t)
        self.assertEqual(p.choose(170), 0)
        self.assertIsNone(p.choose(231))
