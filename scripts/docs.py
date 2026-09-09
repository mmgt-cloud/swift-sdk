#!/usr/bin/env python3
"""Build DocC archives locally for all public products."""
import datetime
import json
import pathlib
import shutil
import subprocess
import sys

root = pathlib.Path(__file__).resolve().parents[1]
subprocess.run([sys.executable, str(root / "scripts/check-snippets.py")], cwd=root, check=True)
stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
output = root / ".artifacts" / ("docs-" + stamp)
output.mkdir(parents=True, exist_ok=False)
cache = root / ".artifacts" / "DocumentationDerivedData"
command = ["xcodebuild", "docbuild", "-scheme", "MMGT-Package", "-destination", "generic/platform=iOS Simulator", "-derivedDataPath", str(cache), "CODE_SIGNING_ALLOWED=NO", "OTHER_DOCC_FLAGS=--warnings-as-errors --transform-for-static-hosting"]
with (output / "build.log").open("w") as log:
    result = subprocess.run(command, cwd=root, stdout=log, stderr=subprocess.STDOUT)
archives = []
if result.returncode == 0:
    for archive in sorted((cache / "Build/Products").glob("**/MMGT*.doccarchive")):
        destination = output / "Archives" / archive.name
        shutil.copytree(archive, destination)
        archives.append(str(destination.relative_to(output)))
report = {"schemaVersion": 1, "status": "passed" if result.returncode == 0 and len(archives) == 8 else "failed", "startedAt": stamp, "exitCode": result.returncode, "archives": archives, "scope": "Local DocC generation; public hosting not verified",
          "sourceCommit": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip(),
          "dirty": bool(subprocess.check_output(["git", "status", "--porcelain"], cwd=root, text=True).strip()),
          "xcode": subprocess.check_output(["xcodebuild", "-version"], text=True).strip()}
(output / "report.json").write_text(json.dumps(report, indent=2) + "\n")
print(json.dumps({"status": report["status"], "report": str(output / "report.json")}))
sys.exit(0 if report["status"] == "passed" else 1)
