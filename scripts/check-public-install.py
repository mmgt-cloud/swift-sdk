#!/usr/bin/env python3
"""Build independent consumers of an exact public tag or development revision."""
import argparse
import datetime
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
import uuid

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--reference", required=True, help="An immutable SemVer tag or a full commit SHA")
args = parser.parse_args()
if not re.fullmatch(r"(?:v?\d+\.\d+\.\d+(?:-[A-Za-z0-9.-]+)?|[a-f0-9]{40})", args.reference):
    parser.error("Use a SemVer tag or full commit SHA, not a moving branch")
root = pathlib.Path(__file__).resolve().parents[1]
directory = root / ".artifacts" / ("public-install-" + uuid.uuid4().hex)
directory.mkdir(parents=True, exist_ok=False)
repository = "https://github.com/mmgt-cloud/swift-sdk.git"
env = {key: value for key, value in os.environ.items()
       if not key.startswith("GIT_") and key not in ("GH_TOKEN", "GITHUB_TOKEN", "SSH_AUTH_SOCK", "SSH_ASKPASS")}
env.update(GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL="/dev/null", GIT_TERMINAL_PROMPT="0",
           GIT_CONFIG_COUNT="2", GIT_CONFIG_KEY_0="credential.helper", GIT_CONFIG_VALUE_0="",
           GIT_CONFIG_KEY_1="http.extraHeader", GIT_CONFIG_VALUE_1="Authorization:")
report = {"schemaVersion": 1, "reference": args.reference, "status": "running",
          "repository": repository, "startedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
          "scope": "Anonymous public SPM consumers on both simulator architectures. Device, live services and hosted DocC are separate gates.",
          "variants": []}


def record():
    (directory / "report.json").write_text(json.dumps(report, indent=2) + "\n")


def call(command, name, cwd=directory):
    with (directory / (name + ".log")).open("w") as log:
        return subprocess.run(command, cwd=cwd, env=env, stdout=log, stderr=subprocess.STDOUT).returncode


try:
    source = directory / "public-sdk"
    if call(["git", "clone", "--no-checkout", repository, str(source)], "clone"):
        raise RuntimeError("Anonymous clone failed")
    revision = subprocess.check_output(["git", "rev-parse", args.reference + "^{commit}"],
                                       cwd=source, env=env, text=True).strip()
    if not re.fullmatch(r"[a-f0-9]{40}", revision):
        raise RuntimeError("Reference did not resolve to a commit")
    if call(["git", "checkout", "--detach", revision], "checkout", source):
        raise RuntimeError("Public checkout failed")
    report.update(revision=revision, versioned=bool(re.fullmatch(r"v?\d+\.\d+\.\d+(?:-[A-Za-z0-9.-]+)?", args.reference)),
                  xcode=subprocess.check_output(["xcodebuild", "-version"], env=env, text=True).strip())
    products = ["MMGTCore", "MMGTAuth", "MMGTBilling", "MMGTRealtime", "MMGTSync", "MMGTSyncSQLite", "MMGTAI", "MMGTSwiftUI"]
    cache = root / ".artifacts" / "PublicInstallDerivedData"
    for name, modules in [("AllProducts", products), ("AuthOnly", ["MMGTAuth"])]:
        consumer = directory / name
        (consumer / "Sources").mkdir(parents=True)
        (consumer / "Sources/App.swift").write_text('''import Foundation
import SwiftUI
import MMGTAuth
@main struct ConsumerApp: App {
  private let session = AuthSession(configuration: try! .init(
    baseURL: URL(string: "https://example.invalid/auth")!, appID: "synthetic-app"))
  var body: some Scene { WindowGroup { Text("MMGT public package consumer") } }
}
''')
        if name == "AllProducts":
            shutil.copyfile(source / "Tests/MMGTTests/CompiledQuickstarts.swift", consumer / "Sources/Quickstarts.swift")
        dependency = {"url": repository, "revision": revision}
        if report["versioned"]:
            dependency = {"url": repository, "exactVersion": args.reference.removeprefix("v")}
        spec = {"name": name, "options": {"deploymentTarget": {"iOS": "26.0"}}, "packages": {"MMGT": dependency},
                "targets": {name: {"type": "application", "platform": "iOS", "sources": ["Sources"],
                    "settings": {"base": {"PRODUCT_BUNDLE_IDENTIFIER": "invalid.example.mmgt." + name.lower(),
                        "SWIFT_VERSION": "6.0", "SWIFT_STRICT_CONCURRENCY": "complete", "GENERATE_INFOPLIST_FILE": True,
                        "CODE_SIGNING_ALLOWED": "NO"}}, "dependencies": [{"package": "MMGT", "products": modules}]}}}
        spec_path = consumer / "project.json"
        spec_path.write_text(json.dumps(spec, indent=2) + "\n")
        if call(["xcodegen", "generate", "--spec", str(spec_path)], name + "-generate"):
            raise RuntimeError("Consumer project generation failed")
        project = consumer / (name + ".xcodeproj")
        code = call(["xcodebuild", "build", "-project", str(project), "-scheme", name,
                     "-destination", "generic/platform=iOS Simulator", "-scmProvider", "system",
                     "-derivedDataPath", str(cache), "CODE_SIGNING_ALLOWED=NO"], name + "-build")
        row = {"variant": name, "exitCode": code, "products": modules, "status": "failed"}
        report["variants"].append(row)
        record()
        if code:
            raise RuntimeError("Public consumer build failed")
        resolved = json.loads((project / "project.xcworkspace/xcshareddata/swiftpm/Package.resolved").read_text())
        pin = next(pin for pin in resolved["pins"] if pin["identity"] == "swift-sdk")
        if pin["state"]["revision"] != revision:
            raise RuntimeError("SPM used another package revision")
        row["resolvedRevision"] = pin["state"]["revision"]
        row["resolvedVersion"] = pin["state"].get("version")
        if report["versioned"] and row["resolvedVersion"] != args.reference.removeprefix("v"):
            raise RuntimeError("SPM did not install the requested version")
        if name == "AuthOnly":
            app = cache / "Build/Products/Debug-iphonesimulator/AuthOnly.app"
            links = []
            for binary in (app / "AuthOnly", app / "AuthOnly.debug.dylib"):
                if binary.exists():
                    links.append(subprocess.check_output(["otool", "-L", str(binary)], text=True))
            row["sqliteAbsentFromLinkage"] = bool(links) and not any("GRDB" in item or "MMGTSyncSQLite" in item for item in links)
            row["sqliteAbsentFromLinkage"] &= not any("GRDB" in item.name or "MMGTSyncSQLite" in item.name for item in app.rglob("*.framework"))
            if not row["sqliteAbsentFromLinkage"]:
                raise RuntimeError("Auth-only consumer unexpectedly links SQLite")
        row["status"] = "passed"
        record()
        print(name + ": passed", flush=True)
    report["status"] = "passed"
except (RuntimeError, OSError, ValueError, KeyError, StopIteration, subprocess.CalledProcessError) as error:
    report["status"] = "failed"
    report["error"] = str(error)
finally:
    report["finishedAt"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
    record()
    print(json.dumps({"status": report["status"], "report": str(directory / "report.json")}), flush=True)
sys.exit(0 if report["status"] == "passed" else 1)
