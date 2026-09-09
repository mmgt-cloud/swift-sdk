#!/usr/bin/env python3
"""Compile all products with an explicit compiler and the selected Xcode SDK.

This checks source compatibility, separately from simulator/device tests. Xcode
still evaluates the package with its matching build-tools compiler; the override
applies to product sources, including their Swift dependencies.
"""
import argparse
import datetime
import json
import pathlib
import subprocess
import sys

parser = argparse.ArgumentParser()
parser.add_argument("--swiftc", required=True, type=pathlib.Path)
args = parser.parse_args()
compiler = args.swiftc.expanduser().absolute()
if not compiler.is_file():
    parser.error("The compiler path must name an existing swiftc executable")
root = pathlib.Path(__file__).resolve().parents[1]
stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
output = root / ".artifacts" / ("compiler-" + stamp)
output.mkdir(parents=True, exist_ok=False)

def capture(command):
    return subprocess.run(command, cwd=root, capture_output=True, text=True, check=True).stdout.strip()

report = {
    "schemaVersion": 1, "startedAt": stamp,
    "sourceCommit": capture(["git", "rev-parse", "HEAD"]),
    "dirty": bool(capture(["git", "status", "--porcelain"])),
    "compiler": capture([str(compiler), "--version"]),
    "xcode": capture(["xcodebuild", "-version"]),
    "sdk": capture(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-version"]),
    "scope": "Source compatibility for all products on both simulator architectures; not minimum-runtime, Swift Testing or device acceptance",
    "products": [], "status": "running",
}
products = ["MMGTCore", "MMGTAuth", "MMGTBilling", "MMGTRealtime", "MMGTSync", "MMGTSyncSQLite", "MMGTAI", "MMGTSwiftUI"]
for product in products:
    command = ["xcodebuild", "build", "-scheme", product,
               "-destination", "generic/platform=iOS Simulator",
               "-derivedDataPath", str(root / ".artifacts" / "CompilerDerivedData"),
               "SWIFT_EXEC=" + str(compiler), "CODE_SIGNING_ALLOWED=NO"]
    with (output / (product + ".log")).open("w") as log:
        result = subprocess.run(command, cwd=root, stdout=log, stderr=subprocess.STDOUT)
    report["products"].append({"product": product, "exitCode": result.returncode,
                               "status": "passed" if result.returncode == 0 else "failed"})
    (output / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(product + ": " + report["products"][-1]["status"], flush=True)
    if result.returncode:
        break
report["status"] = "passed" if len(report["products"]) == len(products) and all(x["exitCode"] == 0 for x in report["products"]) else "failed"
(output / "report.json").write_text(json.dumps(report, indent=2) + "\n")
print(json.dumps({"status": report["status"], "report": str(output / "report.json")}))
sys.exit(0 if report["status"] == "passed" else 1)
