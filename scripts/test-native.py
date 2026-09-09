#!/usr/bin/env python3
"""Signed iPhone passkey and HTTPS OIDC acceptance; private fixtures, no retry."""
import argparse
import base64
import datetime
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import uuid
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parents[1]
BUNDLE = 'cloud.mmgt.sdkexample'


def now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def output(args, env=None):
    return subprocess.check_output(args, cwd=ROOT, env=env, text=True, stderr=subprocess.DEVNULL).strip()


def read_private(path):
    path = path.resolve(strict=True)
    if not path.is_relative_to(ROOT / '.artifacts') or path.stat().st_mode & 0o077:
        raise ValueError('Input must be a private file in this SDK artifact directory')
    return json.loads(path.read_text())


def fingerprint(path):
    if path.is_file():
        return hashlib.sha256(path.read_bytes()).hexdigest()
    digest = hashlib.sha256()
    for item in sorted(path.rglob('*')):
        if item.is_file():
            digest.update(str(item.relative_to(path)).encode() + b'\0')
            digest.update(hashlib.sha256(item.read_bytes()).digest())
    return digest.hexdigest()


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='action', required=True)
    build = commands.add_parser('build')
    build.add_argument('--environment', choices=['stage', 'prod'], required=True)
    build.add_argument('--device-id', required=True)
    build.add_argument('--team-id', required=True)
    build.add_argument('--developer-dir', type=Path)
    run = commands.add_parser('run')
    run.add_argument('--build-report', type=Path, required=True)
    run.add_argument('--configuration', type=Path, required=True)
    run.add_argument('--stage-report', type=Path)
    args = parser.parse_args()
    revision = output(['git', 'rev-parse', 'HEAD'])
    if output(['git', 'status', '--porcelain']):
        raise ValueError('Commit the exact reviewed SDK before native acceptance')
    env = os.environ.copy()
    for key in ('MMGT_NATIVE_CONFIGURATION', 'TEST_RUNNER_MMGT_NATIVE_CONFIGURATION'):
        env.pop(key, None)
    folder = ROOT / '.artifacts' / ('native-' + args.action + '-' + uuid.uuid4().hex)
    folder.mkdir(parents=True, mode=0o700)
    report = dict(schemaVersion=1, kind='swift-native-' + args.action, sourceCommit=revision,
                  startedAt=now(), status='failed',
                  scope='Physical iPhone: approved AASA, native passkey registration/sign-in/reauthentication, system-browser HTTPS OIDC callback, refresh/profile and server credential cleanup. MFA, account lifecycle, external OAuth providers and five services are separate gates.')
    if args.action == 'build':
        if not re.fullmatch(r'[A-Z0-9]{10}', args.team_id) or not re.fullmatch(r'[A-Za-z0-9-]+', args.device_id):
            raise ValueError('Explicit signing team and physical device ID required')
        if args.developer_dir:
            env['DEVELOPER_DIR'] = str(args.developer_dir.resolve(strict=True))
        domain = 'stage.mmgt.cloud' if args.environment == 'stage' else 'mmgt.cloud'
        entitlements = folder / 'native.entitlements'
        entitlements.write_bytes(plistlib.dumps({'com.apple.developer.associated-domains':
                                               ['applinks:' + domain, 'webcredentials:' + domain]}))
        derived = ROOT / '.artifacts' / ('NativeDeviceDerivedData-' + args.environment)
        destination = 'platform=iOS,id=' + args.device_id
        subprocess.run([sys.executable, 'scripts/example.py'], cwd=ROOT, check=True, stdout=subprocess.DEVNULL)
        # Example configuration is public only. Reject an accidentally embedded fixture.
        example = json.loads((ROOT / 'Examples/MMGTExample/Configuration.json').read_text())
        allowed = {'appID', 'authURL', 'billingURL', 'realtimeURL', 'syncURL', 'aiURL', 'oidcClientID',
                   'redirectURL', 'relyingPartyID', 'syncCollection', 'developmentScheme'}
        if set(example) != allowed:
            raise ValueError('The bundled example configuration must contain only public configuration fields')
        report.update(environment=args.environment, teamID=args.team_id, bundleID=BUNDLE,
                      relyingPartyID=domain, destination=destination,
                      developerDirectory=env.get('DEVELOPER_DIR') or output(['xcode-select', '-p']),
                      xcode=output(['xcodebuild', '-version'], env), entitlementsSHA256=fingerprint(entitlements))
        command = ['xcodebuild', 'build-for-testing', '-project', 'Examples/MMGTExample/MMGTExample.xcodeproj',
                   '-scheme', 'MMGTNative', '-destination', destination, '-derivedDataPath', str(derived),
                   '-allowProvisioningUpdates', 'DEVELOPMENT_TEAM=' + args.team_id, 'CODE_SIGN_STYLE=Automatic',
                   'MMGT_EXAMPLE_ENTITLEMENTS=' + str(entitlements)]
    else:
        prior = read_private(args.build_report)
        if prior.get('kind') != 'swift-native-build' or prior.get('status') != 'passed' or prior.get('sourceCommit') != revision:
            raise ValueError('A successful native build of this exact SDK is required')
        data = read_private(args.configuration)
        required = {'environment', 'appID', 'userID', 'email', 'password', 'runID', 'authURL',
                    'teamID', 'bundleID', 'relyingPartyID', 'clientID', 'redirectURL'}
        if set(data) != required or any(not isinstance(value, str) or not value for value in data.values()):
            raise ValueError('Native fixture fields are missing or unexpected')
        for field in ('appID', 'userID', 'runID'):
            uuid.UUID(data[field])
        for field in ('environment', 'teamID', 'bundleID', 'relyingPartyID'):
            if data[field] != prior[field]:
                raise ValueError('Native fixture differs from the signed build')
        auth, redirect = urlsplit(data['authURL']), urlsplit(data['redirectURL'])
        if (not data['email'].endswith('@example.invalid') or auth.hostname != 'api.' + data['relyingPartyID']
                or auth.path != '/auth' or redirect.hostname != data['relyingPartyID']
                or not redirect.path.startswith('/native/')
                or any(url.scheme != 'https' or url.port or url.username or url.password or url.query or url.fragment for url in (auth, redirect))):
            raise ValueError('Use owned test credentials and exact public URLs in one environment')
        if data['environment'] == 'prod':
            if not args.stage_report:
                raise ValueError('Production requires passing native stage acceptance')
            stage = read_private(args.stage_report)
            if any(stage.get(k) != v for k, v in dict(kind='swift-native-run', sourceCommit=revision,
                    status='passed', environment='stage').items()):
                raise ValueError('Native stage report does not match this SDK')
            report['stageReportSHA256'] = fingerprint(args.stage_report)
        for key in ('application', 'xctestrun', 'testBundle'):
            if fingerprint(Path(prior[key])) != prior[key + 'SHA256']:
                raise ValueError('Native build artifacts changed; build again before acceptance')
        report.update(environment=data['environment'], runID=data['runID'], destination=prior['destination'],
                      buildReport=str(args.build_report.resolve()), buildReportSHA256=fingerprint(args.build_report))
        env['DEVELOPER_DIR'] = prior['developerDirectory']
        env['TEST_RUNNER_MMGT_NATIVE_CONFIGURATION'] = base64.b64encode(json.dumps(data).encode()).decode()
        intent = ROOT / '.artifacts' / ('native-attempt-' + data['runID'] + '.json')
        with intent.open('x') as stream:
            json.dump(dict(sourceCommit=revision, environment=data['environment'], startedAt=now(),
                           report=str(folder / 'report.json'), status='started-no-automatic-retry'), stream)
        command = ['xcodebuild', 'test-without-building', '-xctestrun', prior['xctestrun'],
                   '-destination', prior['destination'], '-parallel-testing-enabled', 'NO',
                   '-resultBundlePath', str(folder / 'tests.xcresult')]
    with (folder / 'xcodebuild.log').open('w') as log:
        try:
            result = subprocess.run(command, cwd=ROOT, env=env, stdout=log, stderr=subprocess.STDOUT,
                                    timeout=900 if args.action == 'build' else 720)
            report['exitCode'] = result.returncode
        except subprocess.TimeoutExpired:
            report['exitCode'] = 124
            report['reason'] = 'timeout; reconcile fixture; no automatic retry'
    env.pop('TEST_RUNNER_MMGT_NATIVE_CONFIGURATION', None)
    try:
        if report['exitCode'] == 0:
            if args.action == 'build':
                app = derived / 'Build/Products/Debug-iphoneos/MMGTExample.app'
                test_bundle = app / 'PlugIns/MMGTNativeTests.xctest'
                runs = list((derived / 'Build/Products').glob('MMGTNative_*.xctestrun'))
                if len(runs) != 1 or not test_bundle.exists():
                    raise ValueError('Native test products are missing or ambiguous')
                signed = plistlib.loads(subprocess.check_output(['codesign', '-d', '--entitlements', ':-', str(app)], stderr=subprocess.DEVNULL))
                domains = signed.get('com.apple.developer.associated-domains')
                if domains != ['applinks:' + domain, 'webcredentials:' + domain] or signed.get('application-identifier') != args.team_id + '.' + BUNDLE:
                    raise ValueError('Signed app lacks exact Associated Domains or application identity')
                subprocess.run(['codesign', '--verify', '--strict', str(app)], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                report.update(signedDomains=domains)
                for key, path in dict(application=app, xctestrun=runs[0], testBundle=test_bundle).items():
                    report[key] = str(path)
                    report[key + 'SHA256'] = fingerprint(path)
            else:
                summary = json.loads(output(['xcrun', 'xcresulttool', 'get', 'test-results', 'summary',
                                             '--path', str(folder / 'tests.xcresult'), '--compact'], env))
                report['testCounts'] = {key: summary.get(key) for key in ('totalTestCount', 'passedTests', 'failedTests', 'skippedTests')}
                if summary.get('passedTests') != 1 or summary.get('failedTests') != 0 or summary.get('skippedTests') != 0:
                    raise ValueError('Native acceptance requires one executed test without failures or skips')
                devices = [row['device'] for row in summary.get('devicesAndConfigurations', [])]
                if not devices or any(device.get('platform') == 'iOS Simulator' for device in devices):
                    raise ValueError('Native acceptance requires a physical iPhone result')
                report['deviceOSVersions'] = sorted({device['osVersion'] for device in devices})
            report['status'] = 'passed'
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError):
        report['exitCode'] = 1
        report['reason'] = 'Signing, artifact integrity or physical test-result validation failed; private build evidence retained'
    report['finishedAt'] = now()
    (folder / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps({'status': report['status'], 'report': str(folder / 'report.json')}))
    return report['exitCode']


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError):
        sys.exit('Native runner could not validate configuration, signing or artifacts; inspect private evidence; no retry')
