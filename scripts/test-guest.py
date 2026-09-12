#!/usr/bin/env python3
"""Build and run one explicit guest-AI/import interoperability attempt on iOS."""
import argparse
import base64
import datetime
import json
import os
import pathlib
import hashlib
import plistlib
import re
import stat
import subprocess
import sys
import uuid
from urllib.parse import urlsplit

ROOT = pathlib.Path(__file__).resolve().parents[1]


def output(*command, env=None):
    return subprocess.check_output(command, cwd=ROOT, env=env, text=True).strip()


def now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def read_json(path):
    return json.loads(path.read_text())


def validate_configuration(data):
    if not isinstance(data, dict):
        raise ValueError("Configuration must be an object")
    environment = data.get("environment")
    if environment not in ("stage", "prod"):
        raise ValueError("Configuration must explicitly select stage or prod")
    expected_host = "api.stage.mmgt.cloud" if environment == "stage" else "api.mmgt.cloud"
    for key in ("authURL", "syncURL", "aiURL"):
        url = urlsplit(data.get(key, ""))
        if url.scheme != "https" or url.hostname != expected_host or url.port not in (None, 443) or url.username or url.password or url.query or url.fragment or url.path != "/" + key.removesuffix("URL"):
            raise ValueError("Service URLs must belong to the selected platform environment")
    for key in ("appID", "userID", "runID", "webRecordID", "swiftRecordID", "aiConnectionID"):
        uuid.UUID(data[key])
    for key in ("email", "password", "aiModel"):
        if not isinstance(data.get(key), str) or not data[key]:
            raise ValueError("Required fixture configuration is missing")
    if data["webRecordID"] == data["swiftRecordID"]:
        raise ValueError("Web and Swift record identities must be distinct")
    return environment


def record_attempt(directory, environment, run_id, evidence):
    directory.mkdir(exist_ok=True, mode=0o700)
    marker = directory / (environment + "-" + str(uuid.UUID(run_id)) + ".json")
    try:
        with marker.open("x") as stream:
            json.dump(evidence, stream)
            stream.flush()
            os.fsync(stream.fileno())
    except FileExistsError:
        raise ValueError("This guest attempt already started; reconcile private evidence, do not retry generation") from None


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="action", required=True)
    build = commands.add_parser("build")
    build.add_argument("--destination", required=True)
    build.add_argument("--team-id")
    build.add_argument("--developer-dir", type=pathlib.Path)
    run = commands.add_parser("run")
    run.add_argument("--build-report", required=True, type=pathlib.Path)
    run.add_argument("--configuration", required=True, type=pathlib.Path)
    run.add_argument("--stage-report", type=pathlib.Path)
    args = parser.parse_args()
    revision = output("git", "rev-parse", "HEAD")
    if output("git", "status", "--porcelain"):
        parser.error("Live acceptance requires a clean source commit")
    env = os.environ.copy()
    env.pop("MMGT_GUEST_CONFIGURATION", None)
    env.pop("TEST_RUNNER_MMGT_GUEST_CONFIGURATION", None)
    started = now()
    directory = ROOT / ".artifacts" / ("guest-" + args.action + "-" + uuid.uuid4().hex)
    directory.mkdir(parents=True, mode=0o700)
    report = {"schemaVersion": 1, "kind": "swift-guest-" + args.action,
              "startedAt": started, "sourceCommit": revision, "status": "failed",
              "scope": "Guest product: offline SQLite, real guest Codex HTTP and upload/tool stream, full account authentication, consent import of original record IDs and web interoperability. Other scenario and cleanup receipts remain required."}
    command = ["xcodebuild"]
    if args.action == "build":
        if not re.fullmatch(r"platform=iOS( Simulator)?,id=[A-Za-z0-9-]+", args.destination):
            parser.error("Use an explicit iOS Simulator or iOS device ID")
        device = args.destination.startswith("platform=iOS,")
        if device and not re.fullmatch(r"[A-Z0-9]{10}", args.team_id or ""):
            parser.error("Physical devices require a ten-character --team-id")
        if args.developer_dir:
            env["DEVELOPER_DIR"] = str(args.developer_dir.expanduser().resolve(strict=True))
        developer = env.get("DEVELOPER_DIR") or output("xcode-select", "-p")
        report.update(destination=args.destination, developerDirectory=developer,
                      xcode=output("xcodebuild", "-version", env=env),
                      derivedData=str(ROOT / ".artifacts" / ("GuestDeviceDerivedData" if device else "GuestDerivedData")))
        subprocess.run([sys.executable, "scripts/example.py"], cwd=ROOT, env=env, check=True)
        command += ["build-for-testing", "-project", "Examples/MMGTExample/MMGTExample.xcodeproj",
                    "-scheme", "MMGTGuest", "-destination", args.destination,
                    "-derivedDataPath", report["derivedData"]]
        if device:
            command += ["-allowProvisioningUpdates", "DEVELOPMENT_TEAM=" + args.team_id, "CODE_SIGN_STYLE=Automatic"]
        else:
            entitlements = directory / "simulator.entitlements"
            entitlements.write_bytes(plistlib.dumps({"application-identifier": "MMGTTEST00.cloud.mmgt.sdkexample"}))
            command += ["CODE_SIGN_IDENTITY=-", "CODE_SIGNING_ALLOWED=YES", "CODE_SIGNING_REQUIRED=YES",
                        "MMGT_EXAMPLE_ENTITLEMENTS=" + str(entitlements)]
    else:
        prior = read_json(args.build_report)
        if prior.get("kind") != "swift-guest-build" or prior.get("status") != "passed" or prior.get("sourceCommit") != revision:
            parser.error("A successful build of this exact clean commit is required")
        configuration = args.configuration.expanduser().resolve(strict=True)
        if not configuration.is_relative_to(ROOT / ".artifacts"):
            parser.error("Copy private configuration into this repository's ignored .artifacts directory")
        if stat.S_IMODE(configuration.stat().st_mode) & 0o077:
            parser.error("Private configuration must not be group/world accessible (chmod 600)")
        raw = configuration.read_bytes()
        if len(raw) > 65_536:
            parser.error("Configuration is too large")
        data = json.loads(raw)
        environment = validate_configuration(data)
        if environment == "prod":
            if not args.stage_report:
                parser.error("Production requires --stage-report for this exact SDK commit")
            stage = read_json(args.stage_report)
            if stage.get("kind") != "swift-guest-run" or stage.get("environment") != "stage" or stage.get("status") != "passed" or stage.get("sourceCommit") != revision:
                parser.error("The supplied stage report does not satisfy the production gate")
            report["stageReport"] = str(args.stage_report.resolve())
        report.update(environment=environment, runID=data["runID"], buildReport=str(args.build_report.resolve()),
                      destination=prior["destination"], developerDirectory=prior["developerDirectory"],
                      configurationSHA256=hashlib.sha256(raw).hexdigest(),
                      buildReportSHA256=hashlib.sha256(args.build_report.read_bytes()).hexdigest())
        env["DEVELOPER_DIR"] = prior["developerDirectory"]
        # Apple passes TEST_RUNNER_ variables to the runner with the prefix
        # removed. Credentials are never shell arguments or part of our report.
        record_attempt(ROOT / ".artifacts/guest-attempts", environment, data["runID"],
                       dict(sourceCommit=revision, configurationSHA256=report["configurationSHA256"],
                            report=str(directory / "report.json"), status="attempted"))
        env["TEST_RUNNER_MMGT_GUEST_CONFIGURATION"] = base64.b64encode(raw).decode()
        command += ["test-without-building", "-project", "Examples/MMGTExample/MMGTExample.xcodeproj",
                    "-scheme", "MMGTGuest", "-destination", prior["destination"],
                    "-derivedDataPath", prior["derivedData"], "-resultBundlePath", str(directory / "tests.xcresult"),
                    "-parallel-testing-enabled", "NO"]
    with (directory / "xcodebuild.log").open("w") as log:
        try:
            result = subprocess.run(command, cwd=ROOT, env=env, stdout=log, stderr=subprocess.STDOUT,
                                    timeout=900 if args.action == "build" else 360)
            report["exitCode"] = result.returncode
        except subprocess.TimeoutExpired:
            report["exitCode"] = 124
            report["reason"] = "timeout; no retry; reconcile and clean up the fixture explicitly"
    env.pop("TEST_RUNNER_MMGT_GUEST_CONFIGURATION", None)
    if report["exitCode"] == 0 and args.action == "run":
        summary = json.loads(output("xcrun", "xcresulttool", "get", "test-results", "summary",
                                    "--path", str(directory / "tests.xcresult"), "--compact", env=env))
        report["testCounts"] = {key: summary.get(key) for key in ("totalTestCount", "passedTests", "failedTests", "skippedTests")}
        if summary.get("passedTests") != 1 or summary.get("failedTests") != 0 or summary.get("skippedTests") != 0:
            report["exitCode"] = 1
            report["reason"] = "Expected one executed guest product scenario, with no failures or skips"
    if report["exitCode"] == 0:
        report["status"] = "passed"
    report["finishedAt"] = now()
    (directory / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({"status": report["status"], "report": str(directory / "report.json")}))
    return report["exitCode"]


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError):
        # Configuration validation errors must not interpolate the supplied content.
        sys.exit("Guest runner failed to read configuration, build evidence or local tools; no retry")
