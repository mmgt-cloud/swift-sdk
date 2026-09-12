#!/usr/bin/env python3
"""Run the personal domain and profile/AI integration tests in the compiled SwiftUI example."""
import argparse
import datetime
import json
from pathlib import Path
import plistlib
import subprocess
import sys

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--destination', required=True)
args = parser.parse_args()
if not args.destination.startswith('platform=iOS Simulator,'):
    parser.error('This runner requires an explicit iOS Simulator; device tests use real signing separately')
root = Path(__file__).resolve().parents[1]
subprocess.run([sys.executable, str(root / 'scripts/example.py')], cwd=root, check=True)
stamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ')
folder = root / '.artifacts' / ('personal-' + stamp)
folder.mkdir(parents=True, exist_ok=False)
entitlements = folder / 'simulator.entitlements'
entitlements.write_bytes(plistlib.dumps({'application-identifier': 'MMGTTEST00.cloud.mmgt.sdkexample'}))
command = ['xcodebuild', 'test', '-project', 'Examples/MMGTExample/MMGTExample.xcodeproj',
           '-scheme', 'MMGTExample', '-destination', args.destination,
           '-derivedDataPath', str(root / '.artifacts/KeychainDerivedData'),
           '-resultBundlePath', str(folder / 'tests.xcresult'),
           '-only-testing:MMGTDeviceTests/PersonalExampleTests',
           'CODE_SIGN_IDENTITY=-', 'CODE_SIGNING_ALLOWED=YES', 'CODE_SIGNING_REQUIRED=YES',
           'MMGT_EXAMPLE_ENTITLEMENTS=' + str(entitlements)]
with (folder / 'xcodebuild.log').open('w') as log:
    result = subprocess.run(command, cwd=root, stdout=log, stderr=subprocess.STDOUT)
counts = {}
exit_code = result.returncode
if exit_code == 0:
    summary = json.loads(subprocess.check_output(['xcrun', 'xcresulttool', 'get', 'test-results', 'summary',
                                                 '--path', str(folder / 'tests.xcresult'), '--compact'], text=True))
    counts = {key: summary.get(key) for key in ('totalTestCount', 'passedTests', 'failedTests', 'skippedTests')}
    if counts != dict(totalTestCount=6, passedTests=6, failedTests=0, skippedTests=0):
        exit_code = 1
report = dict(schemaVersion=1, testCounts=counts, startedAt=stamp, destination=args.destination,
              sourceCommit=subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root, text=True).strip(),
              dirty=bool(subprocess.check_output(['git', 'status', '--porcelain'], cwd=root, text=True).strip()),
              status='passed' if exit_code == 0 else 'failed', exitCode=exit_code,
              scope='Personal domain, offline profile, consent import and cancelled AI in the compiled example; synthetic network only, physical device and environment acceptance remain separate')
(folder / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps(dict(status=report['status'], report=str(folder / 'report.json'))))
sys.exit(exit_code)
