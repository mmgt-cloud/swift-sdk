"""Offline acceptance must retain two launches and cannot accept simulator/partial proof."""
import importlib.util
from pathlib import Path
import unittest
import uuid

spec = importlib.util.spec_from_file_location("offline_runner", Path(__file__).with_name("test-offline.py"))
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class OfflineRunnerTests(unittest.TestCase):
    def test_configuration_contains_only_public_scoped_identity(self):
        c = dict(environment="stage", **{k: str(uuid.uuid4()) for k in ("appID", "foreignAppID", "runID")})
        self.assertEqual(runner.validate_configuration(c), "stage")
        for change in (dict(environment="local"), dict(foreignAppID=c["appID"]), dict(appID="bad"),
                       dict(password="synthetic-forbidden"), dict(phase="restart")):
            with self.subTest(change=change), self.assertRaises(ValueError):
                runner.validate_configuration({**c, **change})

    def test_prod_requires_both_physical_disconnected_stage_launches(self):
        stage = dict(kind="swift-guest-offline-run", sourceCommit="a" * 40, environment="stage", status="passed",
                     physicalDevice=True, networkPath="unsatisfied",
                     phases=[dict(phase=phase, exitCode=0, testCounts=dict(totalTestCount=1, passedTests=1, failedTests=0, skippedTests=0))
                             for phase in ("seed", "restart")])
        runner.validate_stage(stage, "a" * 40)
        for change in (dict(sourceCommit="b" * 40), dict(environment="prod"), dict(status="failed"),
                       dict(physicalDevice=False), dict(networkPath="satisfied"), dict(phases=stage["phases"][:1]),
                       dict(phases=[stage["phases"][0], {**stage["phases"][1], "exitCode": 1}])):
            with self.subTest(change=change), self.assertRaises(ValueError):
                runner.validate_stage({**stage, **change}, "a" * 40)


if __name__ == "__main__":
    unittest.main()
