#!/usr/bin/env python3
"""Local iOS test runner; failures retain logs and an xcresult bundle."""
import argparse
import datetime
import json
import pathlib
import subprocess
import sys

parser = argparse.ArgumentParser()
parser.add_argument("--destination", required=True, help="Explicit xcodebuild iOS Simulator destination")
args = parser.parse_args()
if not args.destination.startswith("platform=iOS Simulator,"):
    parser.error("Use an explicit iOS Simulator destination; device acceptance runs separately")
root = pathlib.Path(__file__).resolve().parents[1]
stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
output = root / ".artifacts" / ("tests-" + stamp)
output.mkdir(parents=True, exist_ok=False)
command = ["xcodebuild", "test", "-scheme", "MMGT-Package", "-destination", args.destination,
           "-derivedDataPath", str(root / ".artifacts" / "DerivedData"),
           "-resultBundlePath", str(output / "tests.xcresult"), "CODE_SIGNING_ALLOWED=NO"]
with (output / "xcodebuild.log").open("w") as log:
    result = subprocess.run(command, cwd=root, stdout=log, stderr=subprocess.STDOUT)
revision = subprocess.run(["git", "rev-parse", "HEAD"], cwd=root, capture_output=True, text=True)
status = subprocess.run(["git", "status", "--porcelain"], cwd=root, capture_output=True, text=True, check=True)
report = {"schemaVersion": 1, "startedAt": stamp, "destination": args.destination,
          "sourceCommit": revision.stdout.strip() if revision.returncode == 0 else None,
          "dirty": bool(status.stdout), "exitCode": result.returncode,
          "status": "passed" if result.returncode == 0 else "failed",
          "scope": "local simulator tests; not a release gate or device/environment acceptance"}
(output / "report.json").write_text(json.dumps(report, indent=2) + "\n")
print(json.dumps({"status": report["status"], "report": str(output / "report.json")}))
sys.exit(result.returncode)
