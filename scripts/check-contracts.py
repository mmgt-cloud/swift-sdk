#!/usr/bin/env python3
"""Validate public contract evidence; optionally compare a local platform checkout.

The default check needs only this public repository. Pending operations remain
visible and are never inferred to have passed from a mapped Swift method.
"""
import argparse
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def local_file(root, value):
    path = Path(value)
    if path.is_absolute() or '..' in path.parts:
        raise ValueError('Contract reference must stay inside its repository')
    result = (root / path).resolve(strict=True)
    if not result.is_relative_to(root.resolve()):
        raise ValueError('Contract reference resolved outside its repository')
    return result


def verify(root, platform=None):
    matrix = json.loads((root / 'Contracts/platform.json').read_text())
    reviews = matrix.get('serverReviews', {})
    identities = set()
    verified = 0
    for operation in matrix['operations']:
        identity = (operation['service'], operation['typescript'])
        if identity in identities:
            raise ValueError('Duplicate public operation mapping')
        identities.add(identity)
        for reference in operation['tests']:
            file, separator, symbol = reference.partition('#')
            source = local_file(root, file).read_text()
            if separator and (not symbol or ('func ' + symbol + '(') not in source):
                raise ValueError('Test reference does not identify an existing Swift test: ' + reference)
        if operation['serverVerified']:
            review = reviews.get(operation.get('serverReview'))
            if not review or not operation['tests'] or not review.get('files'):
                raise ValueError('Verified operation lacks server and test evidence')
            verified += 1
    if platform is not None:
        for entry in matrix['files'] + [file for review in reviews.values() for file in review['files']]:
            actual = hashlib.sha256(local_file(platform, entry['path']).read_bytes()).hexdigest()
            if actual != entry['sha256']:
                raise ValueError('Platform contract changed: ' + entry['path'])
    fixtures = root / 'Tests/MMGTTests/Fixtures/v1'
    manifest = json.loads((fixtures / 'manifest.json').read_text())
    expected = {entry['file'] for entry in manifest['fixtures']}
    actual = {path.name for path in fixtures.glob('*.json') if path.name != 'manifest.json'}
    if not manifest['synthetic'] or len(expected) != len(manifest['fixtures']) or expected != actual:
        raise ValueError('Synthetic fixture inventory differs from the actual files')
    for entry in manifest['fixtures']:
        raw = local_file(fixtures, entry['file']).read_bytes()
        if hashlib.sha256(raw).hexdigest() != entry['sha256']:
            raise ValueError('Fixture checksum mismatch: ' + entry['file'])
        if platform is not None and raw != local_file(platform, 'contracts/swift/v1/' + entry['file']).read_bytes():
            raise ValueError('Platform and Swift fixture bytes differ: ' + entry['file'])
    return dict(operations=len(identities), serverReviewed=verified,
                pendingServerReview=len(identities) - verified, fixtures=len(expected))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--platform-source', type=Path, help='Optional local checkout; never downloaded or required by SPM')
    args = parser.parse_args()
    try:
        result = verify(ROOT, args.platform_source)
    except (ValueError, OSError, KeyError) as error:
        parser.exit(1, 'Contract evidence check failed: ' + str(error) + '\n')
    print(json.dumps(dict(status='passed', scope='evidence integrity, not environment acceptance', **result)))


if __name__ == '__main__':
    main()
