#!/usr/bin/env python3
"""Verify that the built example actually contains the SDK/dependency privacy manifests."""
import argparse
import json
from pathlib import Path
import plistlib

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--application", required=True, type=Path)
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
if args.application.suffix != ".app" or not args.application.is_dir():
    parser.error("Pass a built application bundle")
matrix = json.loads((root / "Contracts/privacy.json").read_text())["modules"]
bundled = list(args.application.rglob("PrivacyInfo.xcprivacy"))
for module, kinds in matrix.items():
    source = root / "Sources" / module / "PrivacyInfo.xcprivacy"
    value = plistlib.loads(source.read_bytes())
    assert value["NSPrivacyTracking"] is False and value["NSPrivacyTrackingDomains"] == []
    assert {entry["NSPrivacyCollectedDataType"] for entry in value["NSPrivacyCollectedDataTypes"]} == {"NSPrivacyCollectedDataType" + kind for kind in kinds}
    candidates = [p for p in bundled if p.parent.name.endswith("_" + module + ".bundle")]
    assert len(candidates) == 1, f"Missing or duplicate built privacy bundle: {module}"
    assert plistlib.loads(candidates[0].read_bytes()) == value, f"Stale built manifest: {module}"
for dependency in ("AppAuth", "AppAuthCore", "GRDB"):
    assert any(dependency in p.parent.name for p in bundled), f"Missing dependency manifest: {dependency}"
print("PASS: eight SDK manifests and AppAuth/AppAuthCore/GRDB manifests in built application")
