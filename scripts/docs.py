#!/usr/bin/env python3
"""Build DocC archives locally for all public products."""
import datetime
import json
import pathlib
import subprocess
import sys

root = pathlib.Path(__file__).resolve().parents[1]
subprocess.run([sys.executable, str(root / "scripts/check-snippets.py")], cwd=root, check=True)
stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
output = root / ".artifacts" / ("docs-" + stamp)
output.mkdir(parents=True)
command = ["xcodebuild", "docbuild", "-scheme", "MMGT-Package", "-destination", "generic/platform=iOS Simulator", "-derivedDataPath", str(output / "DerivedData"), "CODE_SIGNING_ALLOWED=NO", "OTHER_DOCC_FLAGS=--warnings-as-errors --transform-for-static-hosting"]
with (output / "build.log").open("w") as log:
    result = subprocess.run(command, cwd=root, stdout=log, stderr=subprocess.STDOUT)
archives = sorted(str(path.relative_to(output)) for path in output.rglob("MMGT*.doccarchive"))
report = {"status": "passed" if result.returncode == 0 and len(archives) == 8 else "failed", "startedAt": stamp, "exitCode": result.returncode, "archives": archives, "scope": "Local DocC generation; public hosting not verified"}
(output / "report.json").write_text(json.dumps(report, indent=2) + "\n")
print(json.dumps({"status": report["status"], "report": str(output / "report.json")}))
sys.exit(0 if report["status"] == "passed" else 1)
