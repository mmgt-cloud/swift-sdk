"""Guest live preflight and durable provider-attempt safety, with synthetic inputs."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
import uuid

spec = importlib.util.spec_from_file_location("guest_runner", Path(__file__).with_name("test-guest.py"))
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class GuestRunnerTests(unittest.TestCase):
    def fixture(self):
        result = dict(environment="stage", email="guest@example.invalid", password="synthetic-not-secret", aiModel="explicit-model")
        result.update({key: str(uuid.uuid4()) for key in ("appID", "userID", "runID", "webRecordID", "swiftRecordID", "aiConnectionID")})
        result.update({name + "URL": "https://api.stage.mmgt.cloud/" + name for name in ("auth", "sync", "ai")})
        return result

    def test_exact_environment_and_distinct_record_identity(self):
        original = self.fixture()
        self.assertEqual(runner.validate_configuration(original), "stage")
        for field, value in (("aiURL", "https://api.mmgt.cloud/ai"), ("syncURL", "https://api.stage.mmgt.cloud/auth"),
                             ("authURL", "https://user:private@api.stage.mmgt.cloud/auth"),
                             ("aiURL", "http://api.stage.mmgt.cloud/ai"), ("aiURL", "https://api.stage.mmgt.cloud/ai?secret=private"),
                             ("swiftRecordID", original["webRecordID"]), ("aiModel", ""), ("appID", "bad")):
            with self.subTest(field=field), self.assertRaises(ValueError):
                runner.validate_configuration({**original, field: value})
        prod = {**original, "environment": "prod", **{name + "URL": "https://api.mmgt.cloud/" + name for name in ("auth", "sync", "ai")}}
        self.assertEqual(runner.validate_configuration(prod), "prod")

    def test_restart_cannot_repeat_an_uncertain_provider_attempt(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary) / "attempts"
            run_id = str(uuid.uuid4())
            evidence = dict(status="attempted", report="private-report-path")
            runner.record_attempt(directory, "stage", run_id, evidence)
            path = directory / ("stage-" + run_id + ".json")
            self.assertEqual(json.loads(path.read_text()), evidence)
            for later in (dict(status="attempted"), dict(status="passed"), dict(status="failed")):
                with self.assertRaises(ValueError):
                    runner.record_attempt(directory, "stage", run_id, later)
                self.assertEqual(json.loads(path.read_text()), evidence)
            runner.record_attempt(directory, "prod", run_id, evidence)


if __name__ == "__main__":
    unittest.main()
