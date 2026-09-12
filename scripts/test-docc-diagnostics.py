import json
from pathlib import Path
import tempfile
import unittest

from docc_diagnostics import MODULES, inspect_diagnostics


class DocCDiagnosticsTests(unittest.TestCase):
    def test_dependency_warning_cannot_hide_a_missing_or_warning_producing_sdk_module(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            def write(module, issues):
                file = root / (module + '.build') / 'Debug-iphonesimulator' / (module + '-t.build') / (module + '-diagnostics.json')
                file.parent.mkdir(parents=True, exist_ok=True)
                file.write_text(json.dumps(dict(diagnostics=issues)))
                return file
            upstream = dict(severity='warning', id='org.swift.docc.unresolvedTopicReference')
            write('GRDB', [upstream])
            self.assertFalse(inspect_diagnostics(root)[2])
            for module in MODULES:
                write(module, [])
            owned, dependencies, passed = inspect_diagnostics(root)
            self.assertTrue(passed)
            self.assertEqual(set(owned), MODULES)
            self.assertEqual(dependencies, [dict(module='GRDB', diagnostics=[upstream])])
            for module in MODULES:
                for severity in ('warning', 'error'):
                    write(module, [dict(severity=severity)])
                    self.assertFalse(inspect_diagnostics(root)[2])
                file = write(module, [])
                file.unlink()
                self.assertFalse(inspect_diagnostics(root)[2])
                write(module, [])


if __name__ == '__main__':
    unittest.main()
