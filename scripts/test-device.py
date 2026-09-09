#!/usr/bin/env python3
"""Run application-hosted tests on an explicitly selected, signed physical iPhone."""
import argparse
import datetime
import json
import os
import pathlib
import re
import subprocess
import sys

parser = argparse.ArgumentParser()
parser.add_argument("--device-id", required=True, help="xcodebuild destination identifier")
parser.add_argument("--team-id", required=True, help="Your Apple development team")
parser.add_argument("--developer-dir", type=pathlib.Path, help="Optional Xcode Contents/Developer directory; never changes global selection")
args = parser.parse_args()
if not re.fullmatch(r"[A-Za-z0-9-]+", args.device_id) or not re.fullmatch(r"[A-Z0-9]{10}", args.team_id):
    parser.error("Use an explicit device identifier and ten-character Apple Team ID")
root = pathlib.Path(__file__).resolve().parents[1]
env = os.environ.copy()
if args.developer_dir:
    env["DEVELOPER_DIR"] = str(args.developer_dir.expanduser().resolve(strict=True))
subprocess.run([sys.executable, str(root / "scripts/example.py")], cwd=root, env=env, check=True)
stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
output = root / ".artifacts" / ("device-" + stamp)
output.mkdir(parents=True, exist_ok=False)
command = ["xcodebuild", "test", "-project", "Examples/MMGTExample/MMGTExample.xcodeproj",
           "-scheme", "MMGTExample", "-destination", "platform=iOS,id=" + args.device_id,
           "-destination-timeout", "45", "-derivedDataPath", str(root / ".artifacts/DeviceDerivedData"),
           "-resultBundlePath", str(output / "tests.xcresult"), "-allowProvisioningUpdates",
           "DEVELOPMENT_TEAM=" + args.team_id, "CODE_SIGN_STYLE=Automatic"]
with (output / "xcodebuild.log").open("w") as log:
    result = subprocess.run(command, cwd=root, env=env, stdout=log, stderr=subprocess.STDOUT)
report = {
    "schemaVersion": 1, "startedAt": stamp,
    "sourceCommit": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip(),
    "dirty": bool(subprocess.check_output(["git", "status", "--porcelain"], cwd=root, text=True).strip()),
    "xcode": subprocess.check_output(["xcodebuild", "-version"], env=env, text=True).strip(),
    "status": "passed" if result.returncode == 0 else "failed", "exitCode": result.returncode,
    "scope": "Application-hosted synthetic device tests. Live provider, passkey and Associated Domain acceptance are separate gates; inspect the private xcresult for device identity.",
}
(output / "report.json").write_text(json.dumps(report, indent=2) + "\n")
print(json.dumps({"status": report["status"], "report": str(output / "report.json")}))
sys.exit(result.returncode)
