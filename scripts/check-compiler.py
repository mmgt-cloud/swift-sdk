#!/usr/bin/env python3
"""Compile all products with an explicit compiler and the selected Xcode SDK.

This checks source compatibility, separately from simulator/device tests. Xcode
still evaluates the package with its matching build-tools compiler; the override
applies to product sources, including their Swift dependencies.
"""
import argparse
import datetime
import hashlib
import json
import pathlib
import subprocess
import sys

parser = argparse.ArgumentParser()
parser.add_argument("--swiftc", required=True, type=pathlib.Path)
parser.add_argument("--build-system", choices=("xcode", "swiftpm"), default="xcode")
parser.add_argument("--sdk", type=pathlib.Path, help="Explicit installed iOS Simulator SDK for SwiftPM source checks")
args = parser.parse_args()
compiler = args.swiftc.expanduser().absolute()
if not compiler.is_file():
    parser.error("The compiler path must name an existing swiftc executable")
sdk = None
if args.build_system == "swiftpm":
    if args.sdk is None or not (compiler.parent / "swift").is_file():
        parser.error("SwiftPM mode requires --sdk and the compiler's adjacent swift driver")
    sdk = args.sdk.expanduser().resolve(strict=True)
    settings = json.loads((sdk / "SDKSettings.json").read_text())
    if not settings.get("CanonicalName", "").startswith("iphonesimulator") or "iphonesimulator" not in settings.get("SupportedTargets", {}):
        parser.error("Select an installed iOS Simulator SDK")
elif args.sdk:
    parser.error("--sdk is only supported by explicit SwiftPM mode")
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
    "buildSystem": args.build_system,
    "xcode": capture(["xcodebuild", "-version"]),
    "sdk": settings["Version"] if sdk else capture(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-version"]),
    "sdkPath": str(sdk) if sdk else capture(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-path"]),
    "lockfileSHA256": hashlib.sha256((root / "Package.resolved").read_bytes()).hexdigest(),
    "scope": "Source compatibility for all products on both simulator architectures; not minimum-runtime, Swift Testing or device acceptance",
    "products": [], "status": "running",
}
products = ["MMGTCore", "MMGTAuth", "MMGTBilling", "MMGTRealtime", "MMGTSync", "MMGTSyncSQLite", "MMGTAI", "MMGTSwiftUI"]
for product in products:
    results = []
    for arch in (("arm64", "x86_64") if sdk else ("both",)):
        if sdk:
            command = [str(compiler.parent / "swift"), "build", "--target", product,
                       "--triple", arch + "-apple-ios26.0-simulator", "--sdk", str(sdk),
                       "--scratch-path", str(root / ".artifacts" / ("CompilerSwiftPM-" + arch))]
        else:
            command = ["xcodebuild", "build", "-scheme", product,
                       "-destination", "generic/platform=iOS Simulator",
                       "-derivedDataPath", str(root / ".artifacts" / "CompilerDerivedData"),
                       "SWIFT_EXEC=" + str(compiler), "CODE_SIGNING_ALLOWED=NO"]
        with (output / (product + "-" + arch + ".log")).open("w") as log:
            result = subprocess.run(command, cwd=root, stdout=log, stderr=subprocess.STDOUT)
        results.append({"architecture": arch, "exitCode": result.returncode})
        if result.returncode:
            break
    code = next((x["exitCode"] for x in results if x["exitCode"]), 0)
    report["products"].append({"product": product, "exitCode": code, "builds": results,
                               "status": "passed" if code == 0 else "failed"})
    (output / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(product + ": " + report["products"][-1]["status"], flush=True)
    if code:
        break
report["status"] = "passed" if len(report["products"]) == len(products) and all(x["exitCode"] == 0 for x in report["products"]) else "failed"
if report["lockfileSHA256"] != hashlib.sha256((root / "Package.resolved").read_bytes()).hexdigest():
    report.update(status="failed", reason="Source compatibility verification changed the dependency lockfile")
(output / "report.json").write_text(json.dumps(report, indent=2) + "\n")
print(json.dumps({"status": report["status"], "report": str(output / "report.json")}))
sys.exit(0 if report["status"] == "passed" else 1)
