#!/usr/bin/env python3
"""Explicit disposable-account acceptance on Simulator or iPhone; no automatic retry."""
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

ROOT = Path(__file__).resolve().parents[1]
SCOPE = ('Password/profile, session revocation and refresh, TOTP enrollment/login, '
         'restricted MFA challenge, recovery replay rejection, password rotation, '
         'reauthentication and account deletion. Browser MFA and external providers are separate.')


def now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def output(command, env=None):
    return subprocess.check_output(command, cwd=ROOT, env=env, text=True,
                                   stderr=subprocess.DEVNULL).strip()


def fingerprint(path):
    if path.is_file():
        return hashlib.sha256(path.read_bytes()).hexdigest()
    if not path.is_dir():
        raise ValueError('Missing build artifact')
    digest = hashlib.sha256()
    for item in sorted(path.rglob('*')):
        if item.is_file():
            digest.update(str(item.relative_to(path)).encode() + b'\0')
            digest.update(hashlib.sha256(item.read_bytes()).digest())
    return digest.hexdigest()


def simulator_entitlements(executable, env):
    # Xcode embeds Simulator entitlements in Mach-O rather than the device
    # provisioning profile. Read the actual linked section, not its input file.
    layout = output(['xcrun', 'otool', '-l', str(executable)], env)
    matches = re.findall(r'sectname __entitlements\s+segname __TEXT\s+addr 0x[0-9a-fA-F]+\s+'
                         r'size (0x[0-9a-fA-F]+)\s+offset ([0-9]+)', layout)
    if len(matches) != 1:
        raise ValueError('Missing or ambiguous Simulator entitlement section')
    length, offset = int(matches[0][0], 16), int(matches[0][1])
    return plistlib.loads(executable.read_bytes()[offset:offset + length].rstrip(b'\0'))


def validate_configuration(data):
    expected = {'environment', 'appID', 'userID', 'runID', 'email', 'password',
                'replacementPassword', 'authURL'}
    if not isinstance(data, dict) or set(data) != expected:
        raise ValueError('Explicit account fixture fields required')
    if data['environment'] not in ('stage', 'prod'):
        raise ValueError('Explicit environment required')
    host = 'api.stage.mmgt.cloud' if data['environment'] == 'stage' else 'api.mmgt.cloud'
    if data['authURL'] != 'https://' + host + '/auth':
        raise ValueError('Account URL crosses the selected environment')
    for key in ('appID', 'userID', 'runID'):
        if not isinstance(data[key], str) or str(uuid.UUID(data[key])) != data[key]:
            raise ValueError('Canonical fixture UUID required')
    if not isinstance(data['email'], str) or not re.fullmatch(r'account-sdk-[a-f0-9]{32}@example\.invalid', data['email']):
        raise ValueError('Use only the explicitly disposable account identity')
    if any(not isinstance(data[key], str) or not 20 <= len(data[key]) <= 72
           for key in ('password', 'replacementPassword')) or data['password'] == data['replacementPassword']:
        raise ValueError('Distinct bounded fixture passwords required')


def read_private(path):
    path = path.resolve(strict=True)
    if not path.is_relative_to(ROOT / '.artifacts') or path.stat().st_mode & 0o077 or path.stat().st_size > 65_536:
        raise ValueError('Use a bounded private input in this SDK artifact directory')
    return json.loads(path.read_bytes())


def validate_stage(stage, revision, physical):
    expected = dict(kind='swift-accounts-run', sourceCommit=revision, environment='stage', status='passed')
    if any(stage.get(key) != value for key, value in expected.items()) or (physical and not stage.get('physicalDevice')):
        raise ValueError('Production requires matching stage account acceptance on the same device class')


def claim_attempt(directory, data, revision, report_path):
    intent = directory / ('account-attempt-' + data['runID'] + '.json')
    with intent.open('x') as stream:
        json.dump(dict(sourceCommit=revision, environment=data['environment'], startedAt=now(),
                       report=str(report_path), status='started-no-automatic-retry'), stream)
        stream.flush()
        os.fsync(stream.fileno())


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='action', required=True)
    build = commands.add_parser('build')
    build.add_argument('--destination', required=True)
    build.add_argument('--team-id')
    build.add_argument('--developer-dir', type=Path)
    run = commands.add_parser('run')
    run.add_argument('--build-report', type=Path, required=True)
    run.add_argument('--configuration', type=Path, required=True)
    run.add_argument('--stage-report', type=Path)
    args = parser.parse_args()
    revision = output(['git', 'rev-parse', 'HEAD'])
    if output(['git', 'status', '--porcelain']):
        raise ValueError('Commit the exact SDK source before account acceptance')
    env = os.environ.copy()
    for key in list(env):
        if key.startswith(('MMGT_', 'TEST_RUNNER_MMGT_')):
            env.pop(key)
    folder = ROOT / '.artifacts' / ('accounts-' + args.action + '-' + uuid.uuid4().hex)
    folder.mkdir(parents=True, mode=0o700)
    report = dict(schemaVersion=1, kind='swift-accounts-' + args.action, sourceCommit=revision,
                  startedAt=now(), status='failed', scope=SCOPE)
    report_path = folder / 'report.json'
    if args.action == 'build':
        if not re.fullmatch(r'platform=iOS( Simulator)?,id=[A-Za-z0-9-]+', args.destination):
            raise ValueError('Explicit iOS Simulator or physical device destination required')
        physical = args.destination.startswith('platform=iOS,')
        if physical and not re.fullmatch(r'[A-Z0-9]{10}', args.team_id or ''):
            raise ValueError('Physical device signing team required')
        if args.developer_dir:
            env['DEVELOPER_DIR'] = str(args.developer_dir.resolve(strict=True))
        # A separate product directory prevents another scheme from silently replacing the build.
        derived = ROOT / '.artifacts' / ('AccountsDeviceDerivedData' if physical else 'AccountsSimulatorDerivedData')
        report.update(destination=args.destination, physicalDevice=physical,
                      developerDirectory=env.get('DEVELOPER_DIR') or output(['xcode-select', '-p']),
                      xcode=output(['xcodebuild', '-version'], env), derivedData=str(derived))
        subprocess.run([sys.executable, 'scripts/example.py'], cwd=ROOT, check=True, stdout=subprocess.DEVNULL)
        # The host never needs private credentials embedded in its resource bundle.
        example = json.loads((ROOT / 'Examples/MMGTExample/Configuration.json').read_text())
        if set(example) != {'appID', 'authURL', 'billingURL', 'realtimeURL', 'syncURL', 'aiURL',
                            'oidcClientID', 'redirectURL', 'relyingPartyID', 'syncCollection', 'developmentScheme'}:
            raise ValueError('The example may contain only public configuration')
        command = ['xcodebuild', 'build-for-testing', '-project', 'Examples/MMGTExample/MMGTExample.xcodeproj',
                   '-scheme', 'MMGTAccounts', '-destination', 'generic/platform=iOS' if physical else args.destination,
                   '-derivedDataPath', str(derived)]
        if physical:
            command += ['-allowProvisioningUpdates', 'DEVELOPMENT_TEAM=' + args.team_id,
                        'CODE_SIGN_STYLE=Automatic']
        else:
            # This synthetic identity is confined to Simulator. The physical
            # build always uses the real signing team's provisioning profile.
            entitlement = folder / 'simulator.entitlements'
            entitlement.write_bytes(plistlib.dumps({'application-identifier': 'MMGTTEST00.cloud.mmgt.sdkexample'}))
            command += ['CODE_SIGNING_ALLOWED=YES', 'CODE_SIGN_IDENTITY=-',
                        'MMGT_EXAMPLE_ENTITLEMENTS=' + str(entitlement)]
    else:
        prior = read_private(args.build_report)
        if any(prior.get(key) != value for key, value in dict(kind='swift-accounts-build', status='passed', sourceCommit=revision).items()):
            raise ValueError('A passing build of the exact SDK commit is required')
        data = read_private(args.configuration)
        validate_configuration(data)
        physical = prior['physicalDevice']
        if data['environment'] == 'prod':
            if not args.stage_report:
                raise ValueError('Production requires a stage report')
            validate_stage(read_private(args.stage_report), revision, physical)
            report['stageReportSHA256'] = fingerprint(args.stage_report)
        for key in ('application', 'testBundle', 'xctestrun'):
            path = Path(prior[key]).resolve(strict=True)
            if not path.is_relative_to(ROOT / '.artifacts') or fingerprint(path) != prior[key + 'SHA256']:
                raise ValueError('Build artifacts changed; rebuild before acceptance')
        report.update(environment=data['environment'], runID=data['runID'], destination=prior['destination'],
                      physicalDevice=physical, buildReport=str(args.build_report.resolve()),
                      buildReportSHA256=fingerprint(args.build_report))
        env['DEVELOPER_DIR'] = prior['developerDirectory']
        env['TEST_RUNNER_MMGT_ACCOUNT_CONFIGURATION'] = base64.b64encode(json.dumps(data).encode()).decode()
        report_path.write_text(json.dumps(report, indent=2) + '\n')
        claim_attempt(ROOT / '.artifacts', data, revision, report_path)
        command = ['xcodebuild', 'test-without-building', '-xctestrun', prior['xctestrun'],
                   '-destination', prior['destination'], '-parallel-testing-enabled', 'NO',
                   '-collect-test-diagnostics', 'never',
                   '-resultBundlePath', str(folder / 'tests.xcresult')]
    with (folder / 'xcodebuild.log').open('w') as log:
        try:
            result = subprocess.run(command, cwd=ROOT, env=env, stdout=log, stderr=subprocess.STDOUT,
                                    timeout=1200 if args.action == 'build' else 420)
            report['exitCode'] = result.returncode
        except subprocess.TimeoutExpired:
            report['exitCode'] = 124
            report['reason'] = 'Timeout; reconcile the owned fixture; no retry'
    env.pop('TEST_RUNNER_MMGT_ACCOUNT_CONFIGURATION', None)
    try:
        if report['exitCode'] == 0:
            if args.action == 'build':
                app = derived / 'Build/Products' / ('Debug-iphoneos' if physical else 'Debug-iphonesimulator') / 'MMGTExample.app'
                bundle = app / 'PlugIns/MMGTAccountsTests.xctest'
                runs = list((derived / 'Build/Products').glob('MMGTAccounts_*.xctestrun'))
                if len(runs) != 1 or not bundle.is_dir():
                    raise ValueError('Missing or ambiguous test products')
                if physical:
                    subprocess.run(['codesign', '--verify', '--strict', str(app)], check=True,
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                    signed = plistlib.loads(subprocess.check_output(
                        ['codesign', '-d', '--entitlements', '-', '--xml', str(app)], stderr=subprocess.DEVNULL))
                    if signed.get('application-identifier') != args.team_id + '.cloud.mmgt.sdkexample':
                        raise ValueError('Physical application identity differs from the signing team')
                    report['applicationIdentifier'] = signed['application-identifier']
                else:
                    embedded = simulator_entitlements(app / 'MMGTExample', env)
                    if embedded.get('application-identifier') != 'MMGTTEST00.cloud.mmgt.sdkexample':
                        raise ValueError('Simulator host cannot access its own Keychain partition')
                    report['applicationIdentifier'] = embedded['application-identifier']
                for key, path in dict(application=app, testBundle=bundle, xctestrun=runs[0]).items():
                    report[key], report[key + 'SHA256'] = str(path), fingerprint(path)
            else:
                summary = json.loads(output(['xcrun', 'xcresulttool', 'get', 'test-results', 'summary',
                                             '--path', str(folder / 'tests.xcresult'), '--compact'], env))
                report['testCounts'] = {key: summary.get(key) for key in ('totalTestCount', 'passedTests', 'failedTests', 'skippedTests')}
                if summary.get('passedTests') != 2 or summary.get('failedTests') != 0 or summary.get('skippedTests') != 0:
                    raise ValueError('Expected the TOTP vector and one complete account scenario without failures or skips')
                devices = [row['device'] for row in summary.get('devicesAndConfigurations', [])]
                if not devices or any((device.get('platform') != 'iOS Simulator') != physical for device in devices):
                    raise ValueError('Result device class differs from the selected build')
                report['deviceOSVersions'] = sorted({device['osVersion'] for device in devices})
            report['status'] = 'passed'
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError):
        report['exitCode'] = 1
        report['reason'] = 'Artifact or executed test-result verification failed; inspect private evidence'
    report['finishedAt'] = now()
    report_path.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(dict(status=report['status'], report=str(report_path))))
    return report['exitCode']


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (ValueError, KeyError, TypeError, OSError, subprocess.CalledProcessError):
        sys.exit('Account runner could not verify configuration, build or attempt ownership; no automatic retry')
