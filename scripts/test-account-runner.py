#!/usr/bin/env python3
"""Account acceptance preflight and interruption regressions; no live accounts."""
import importlib.util
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('accounts', Path(__file__).with_name('test-accounts.py'))
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class AccountRunnerTests(unittest.TestCase):
    def setUp(self):
        self.fixture = dict(environment='stage', authURL='https://api.stage.mmgt.cloud/auth',
                            appID='00000000-0000-4000-8000-000000000001',
                            userID='00000000-0000-4000-8000-000000000002',
                            runID='00000000-0000-4000-8000-000000000003',
                            email='account-sdk-' + 'a' * 32 + '@example.invalid',
                            password='synthetic-original-password', replacementPassword='synthetic-replacement-password')

    def test_exact_owned_configuration(self):
        runner.validate_configuration(self.fixture)
        runner.validate_configuration({**self.fixture, 'environment': 'prod', 'authURL': 'https://api.mmgt.cloud/auth'})

    def test_cross_environment_and_ambiguous_urls(self):
        for url in ['https://api.mmgt.cloud/auth', 'http://api.stage.mmgt.cloud/auth',
                    'https://api.stage.mmgt.cloud/auth?secret=x', 'https://api.stage.mmgt.cloud:443/auth',
                    'https://user@api.stage.mmgt.cloud/auth', 'https://api.stage.mmgt.cloud/auth/']:
            with self.subTest(url=url), self.assertRaises(ValueError):
                runner.validate_configuration({**self.fixture, 'authURL': url})

    def test_no_real_identity_or_extra_secret_fields(self):
        for changed in [dict(email='customer@example.com'), dict(userID='not-a-uuid'),
                        dict(accessToken='private-marker'), dict(password='short'),
                        dict(replacementPassword=self.fixture['password']), dict(password=None)]:
            with self.subTest(fields=list(changed)), self.assertRaises((ValueError, TypeError)) as raised:
                runner.validate_configuration({**self.fixture, **changed})
            self.assertNotIn('private-marker', str(raised.exception))

    def test_production_needs_matching_stage_and_physical_evidence(self):
        stage = dict(kind='swift-accounts-run', sourceCommit='a' * 40, environment='stage', status='passed', physicalDevice=True)
        runner.validate_stage(stage, 'a' * 40, True)
        for changed in [dict(sourceCommit='b' * 40), dict(environment='prod'), dict(status='failed'),
                        dict(physicalDevice=False), dict(kind='swift-accounts-build')]:
            with self.subTest(fields=list(changed)), self.assertRaises(ValueError):
                runner.validate_stage({**stage, **changed}, 'a' * 40, True)

    def test_interrupted_attempt_cannot_be_started_again(self):
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            runner.claim_attempt(directory, self.fixture, 'a' * 40, directory / 'report.json')
            with self.assertRaises(FileExistsError):
                runner.claim_attempt(directory, self.fixture, 'a' * 40, directory / 'second.json')
            evidence = next(directory.glob('account-attempt-*')).read_text()
            self.assertNotIn(self.fixture['password'], evidence)
            self.assertNotIn(self.fixture['email'], evidence)

    def test_artifact_hash_detects_replacement_and_missing_bundle(self):
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            artifact = directory / 'binary'
            artifact.write_bytes(b'first build')
            first = runner.fingerprint(directory)
            artifact.write_bytes(b'changed build')
            self.assertNotEqual(first, runner.fingerprint(directory))
            with self.assertRaises(ValueError):
                runner.fingerprint(directory / 'missing')


if __name__ == '__main__':
    unittest.main()
