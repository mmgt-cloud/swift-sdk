#!/usr/bin/env python3
"""Regression tests for contract evidence integrity, without platform access."""
import importlib.util
import json
from pathlib import Path
import shutil
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('contract_evidence', ROOT / 'scripts/check-contracts.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class EvidenceTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        shutil.copytree(ROOT / 'Contracts', self.root / 'Contracts')
        shutil.copytree(ROOT / 'Tests', self.root / 'Tests')

    def edit_matrix(self, change):
        path = self.root / 'Contracts/platform.json'
        matrix = json.loads(path.read_text())
        change(matrix)
        path.write_text(json.dumps(matrix))

    def test_default_check_needs_no_private_checkout_and_keeps_pending_visible(self):
        self.edit_matrix(lambda matrix: matrix['operations'][0].update(serverVerified=False))
        result = module.verify(self.root)
        self.assertGreater(result['pendingServerReview'], 0)
        self.assertEqual(result['operations'], result['serverReviewed'] + result['pendingServerReview'])

    def test_changed_fixture_or_missing_test_cannot_keep_verified_status(self):
        path = self.root / 'Tests/MMGTTests/Fixtures/v1/billing-fullaccess.json'
        path.write_text(path.read_text().replace('"has_paid_access": true', '"has_paid_access": false'))
        with self.assertRaisesRegex(ValueError, 'checksum'):
            module.verify(self.root)
        shutil.copyfile(ROOT / 'Tests/MMGTTests/Fixtures/v1/billing-fullaccess.json', path)
        self.edit_matrix(lambda matrix: matrix['operations'].append({
            'service': 'billing', 'typescript': 'syntheticMissing', 'serverVerified': True,
            'serverReview': 'billing', 'tests': ['Tests/MMGTTests/BillingContractTests.swift#notAnExistingTest'],
        }))
        with self.assertRaisesRegex(ValueError, 'existing Swift test'):
            module.verify(self.root)

    def test_claiming_review_without_sources_or_tests_is_rejected(self):
        self.edit_matrix(lambda matrix: matrix['operations'][0].update(serverVerified=True, tests=[], serverReview='missing-review'))
        with self.assertRaisesRegex(ValueError, 'lacks server and test evidence'):
            module.verify(self.root)

    def test_repository_escape_is_rejected_before_reading(self):
        with self.assertRaisesRegex(ValueError, 'inside its repository'):
            module.local_file(self.root, '../outside')


if __name__ == '__main__':
    unittest.main()
