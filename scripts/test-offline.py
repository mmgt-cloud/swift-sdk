#!/usr/bin/env python3
"""Two separate native launches with the real iOS network path disconnected.

Build first, then connect the iPhone by USB and disable cellular data and Wi-Fi
on the phone only. The Mac must stay online for Xcode. No mock response, simulator
offline switch or injected transport failure can satisfy this receipt.
"""
import argparse
import base64
import datetime
import hashlib
import json
import os
import pathlib
import re
import stat
import subprocess
import sys
import uuid

ROOT = pathlib.Path(__file__).resolve().parents[1]


def output(*command, env=None):
    return subprocess.check_output(command, cwd=ROOT, env=env, text=True).strip()


def now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def validate_configuration(data):
    if not isinstance(data, dict) or set(data) != {"environment", "appID", "foreignAppID", "runID"}:
        raise ValueError("Only the four public offline configuration fields are accepted")
    if data["environment"] not in ("stage", "prod"):
        raise ValueError("Explicit stage or prod required")
    for name in ("appID", "foreignAppID", "runID"):
        uuid.UUID(data[name])
    if data["appID"] == data["foreignAppID"]:
        raise ValueError("Two distinct owned applications are required")
    return data["environment"]


def validate_stage(stage, revision):
    expected = dict(kind="swift-guest-offline-run", sourceCommit=revision,
                    environment="stage", status="passed", physicalDevice=True,
                    networkPath="unsatisfied")
    if any(stage.get(k) != v for k, v in expected.items()):
        raise ValueError("Production requires the exact SDK's completed physical offline stage test")
    if [x.get("phase") for x in stage.get("phases", [])] != ["seed", "restart"]:
        raise ValueError("Both distinct stage launches are required")
    for phase in stage["phases"]:
        if phase.get("exitCode") != 0 or phase.get("testCounts") != dict(totalTestCount=1, passedTests=1, failedTests=0, skippedTests=0):
            raise ValueError("Stage phase did not execute its required test")


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="action", required=True)
    build = commands.add_parser("build")
    build.add_argument("--device-id", required=True)
    build.add_argument("--team-id", required=True)
    build.add_argument("--developer-dir", type=pathlib.Path)
    run = commands.add_parser("run")
    run.add_argument("--build-report", required=True, type=pathlib.Path)
    run.add_argument("--configuration", required=True, type=pathlib.Path)
    run.add_argument("--stage-report", type=pathlib.Path)
    args = parser.parse_args()
    revision = output("git", "rev-parse", "HEAD")
    if output("git", "status", "--porcelain"):
        parser.error("A clean source commit is required")
    env = os.environ.copy()
    env.pop("MMGT_OFFLINE_CONFIGURATION", None)
    env.pop("TEST_RUNNER_MMGT_OFFLINE_CONFIGURATION", None)
    directory = ROOT / ".artifacts" / ("offline-" + args.action + "-" + uuid.uuid4().hex)
    directory.mkdir(parents=True, mode=0o700)
    report = dict(schemaVersion=1, kind="swift-guest-offline-" + args.action,
                  startedAt=now(), sourceCommit=revision, status="failed", physicalDevice=True,
                  scope="Native SDK consumer with no account restoration: actual disconnected iOS path, first fresh profile, two test-host processes, SQLite CRUD and sixteen local partitions. No cloud acceptance or provider generation is implied.")
    code = 1
    if args.action == "build":
        if not re.fullmatch(r"[A-Fa-f0-9]{8}-[A-Fa-f0-9]{16}", args.device_id) or not re.fullmatch(r"[A-Z0-9]{10}", args.team_id):
            parser.error("An explicit physical iPhone identifier and signing team are required")
        if args.developer_dir:
            env["DEVELOPER_DIR"] = str(args.developer_dir.expanduser().resolve(strict=True))
        developer = env.get("DEVELOPER_DIR") or output("xcode-select", "-p")
        derived = directory / "DerivedData"
        report.update(destination="platform=iOS,id=" + args.device_id,
                      buildDestination="generic/platform=iOS", developerDirectory=developer,
                      derivedData=str(derived), xcode=output("xcodebuild", "-version", env=env))
        subprocess.run([sys.executable, "scripts/example.py"], cwd=ROOT, env=env, check=True)
        command = ["xcodebuild", "build-for-testing", "-project", "Examples/MMGTExample/MMGTExample.xcodeproj",
                   "-scheme", "MMGTOffline", "-destination", report["buildDestination"], "-derivedDataPath", str(derived),
                   "-allowProvisioningUpdates", "DEVELOPMENT_TEAM=" + args.team_id, "CODE_SIGN_STYLE=Automatic"]
        # Generic device compilation can finish before the iPhone is attached.
        # Only run/test-without-building below counts as physical execution.
        with (directory / "xcodebuild.log").open("w") as log:
            try:
                code = subprocess.run(command, cwd=ROOT, env=env, stdout=log, stderr=subprocess.STDOUT, timeout=900).returncode
            except subprocess.TimeoutExpired:
                code = 124
        report["exitCode"] = code
    else:
        prior = json.loads(args.build_report.read_text())
        if any(prior.get(k) != v for k, v in dict(kind="swift-guest-offline-build", status="passed", sourceCommit=revision, physicalDevice=True).items()):
            parser.error("An exact clean successful physical-target build is required")
        file = args.configuration.expanduser().resolve(strict=True)
        if not file.is_relative_to(ROOT / ".artifacts") or stat.S_IMODE(file.stat().st_mode) & 0o077:
            parser.error("Store the configuration with mode 600 inside ignored .artifacts")
        raw = file.read_bytes()
        if len(raw) >= 8_192:
            parser.error("Configuration is too large")
        data = json.loads(raw)
        environment = validate_configuration(data)
        if environment == "prod":
            if not args.stage_report:
                parser.error("Production requires --stage-report")
            validate_stage(json.loads(args.stage_report.read_text()), revision)
            report["stageReport"] = str(args.stage_report.resolve())
            report["stageReportSHA256"] = hashlib.sha256(args.stage_report.read_bytes()).hexdigest()
        report.update(environment=environment, runID=data["runID"], configurationSHA256=hashlib.sha256(raw).hexdigest(),
                      buildReport=str(args.build_report.resolve()), buildReportSHA256=hashlib.sha256(args.build_report.read_bytes()).hexdigest(),
                      destination=prior["destination"], developerDirectory=prior["developerDirectory"], phases=[])
        env["DEVELOPER_DIR"] = prior["developerDirectory"]
        attempts = ROOT / ".artifacts/offline-attempts"
        attempts.mkdir(exist_ok=True, mode=0o700)
        with (attempts / (environment + "-" + str(uuid.UUID(data["runID"])) + ".json")).open("x") as marker:
            json.dump(dict(sourceCommit=revision, report=str(directory / "report.json"), configurationSHA256=report["configurationSHA256"]), marker)
            marker.flush()
            os.fsync(marker.fileno())
        for phase in ("seed", "restart"):
            current = dict(phase=phase, startedAt=now())
            report["phases"].append(current)
            payload = dict(data, phase=phase)
            env["TEST_RUNNER_MMGT_OFFLINE_CONFIGURATION"] = base64.b64encode(json.dumps(payload).encode()).decode()
            bundle = directory / (phase + ".xcresult")
            command = ["xcodebuild", "test-without-building", "-project", "Examples/MMGTExample/MMGTExample.xcodeproj",
                       "-scheme", "MMGTOffline", "-destination", prior["destination"], "-derivedDataPath", prior["derivedData"],
                       "-resultBundlePath", str(bundle), "-parallel-testing-enabled", "NO"]
            with (directory / (phase + ".log")).open("w") as log:
                try:
                    code = subprocess.run(command, cwd=ROOT, env=env, stdout=log, stderr=subprocess.STDOUT, timeout=180).returncode
                except subprocess.TimeoutExpired:
                    code = 124
            if code == 0:
                summary = json.loads(output("xcrun", "xcresulttool", "get", "test-results", "summary", "--path", str(bundle), "--compact", env=env))
                counts = {k: summary.get(k) for k in ("totalTestCount", "passedTests", "failedTests", "skippedTests")}
                current["testCounts"] = counts
                if counts != dict(totalTestCount=1, passedTests=1, failedTests=0, skippedTests=0):
                    code = 1
            current.update(exitCode=code, finishedAt=now(), resultBundle=str(bundle))
            if code != 0:
                break
        if code == 0:
            report.update(networkPath="unsatisfied", partitions=16, sdkNetworkRequests=0, processLaunches=2)
        report["exitCode"] = code
    if code == 0:
        report["status"] = "passed"
    report["finishedAt"] = now()
    (directory / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(dict(status=report["status"], report=str(directory / "report.json"))))
    return code


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError):
        sys.exit("Offline acceptance preparation failed; preserve the attempt and use a fresh explicit run after diagnosis")
