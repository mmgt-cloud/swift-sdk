#!/usr/bin/env python3
"""Build first, then run an explicit live fixture without exposing credentials."""
import argparse
import base64
import datetime
import json
import os
import pathlib
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


def validate_realtime_grant(data, timestamp):
    """Preflight an owned fixture, not signature verification or authorization.

    Realtime signs base64url(JSON) + "." + base64url(HMAC-SHA256); it is not
    a JWT. Only the server has the signing key and verifies the actual MAC.
    """
    def decode(part):
        if not isinstance(part, str) or not re.fullmatch(r"[A-Za-z0-9_-]+", part):
            raise ValueError("Expected canonical base64url Realtime grant parts")
        raw = base64.urlsafe_b64decode(part + "=" * (-len(part) % 4))
        if base64.urlsafe_b64encode(raw).decode().rstrip("=") != part:
            raise ValueError("Expected canonical base64url Realtime grant parts")
        return raw

    token = data.get("realtimeGrant")
    if not isinstance(token, str) or len(token) > 16_384 or len(token.split(".")) != 2:
        raise ValueError("Expected a two-part signed Realtime grant")
    payload, signature = token.split(".")
    if len(decode(signature)) != 32:
        raise ValueError("Expected a SHA-256 Realtime grant signature")
    try:
        claims = json.loads(decode(payload))
    except (ValueError, UnicodeError):
        raise ValueError("Invalid Realtime grant payload") from None
    if (not isinstance(claims, dict)
            or claims.get("app_id") != data.get("appID")
            or claims.get("user_id") != data.get("userID")
            or claims.get("channels") != ["sdk-live:" + data["runID"]]
            or claims.get("permissions") not in (["publish", "subscribe"], ["subscribe", "publish"])
            or type(claims.get("exp")) is not int):
        raise ValueError("Realtime grant does not describe the owned fixture scope")
    if claims["exp"] - timestamp < 180:
        raise ValueError("Prepare a fresh grant after build; at least 180 seconds must remain")


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
    env.pop("MMGT_LIVE_CONFIGURATION", None)
    env.pop("TEST_RUNNER_MMGT_LIVE_CONFIGURATION", None)
    started = now()
    directory = ROOT / ".artifacts" / ("live-" + args.action + "-" + uuid.uuid4().hex)
    directory.mkdir(parents=True, mode=0o700)
    report = {"schemaVersion": 1, "kind": "swift-live-" + args.action,
              "startedAt": started, "sourceCommit": revision, "status": "failed",
              "scope": "Five public services: password session, user Sync CAS/snapshot, Realtime publish/ACK, Billing reads, explicit AI HTTP/WebSocket. Native browser, MFA, passkeys, checkout and workspace authorization are separate gates."}
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
                      derivedData=str(ROOT / ".artifacts" / ("LiveDeviceDerivedData" if device else "ExampleDerivedData")))
        subprocess.run([sys.executable, "scripts/example.py"], cwd=ROOT, env=env, check=True)
        command += ["build-for-testing", "-project", "Examples/MMGTExample/MMGTExample.xcodeproj",
                    "-scheme", "MMGTLive", "-destination", args.destination,
                    "-derivedDataPath", report["derivedData"]]
        command += (["-allowProvisioningUpdates", "DEVELOPMENT_TEAM=" + args.team_id,
                     "CODE_SIGN_STYLE=Automatic"] if device else ["CODE_SIGNING_ALLOWED=NO"])
    else:
        prior = read_json(args.build_report)
        if prior.get("kind") != "swift-live-build" or prior.get("status") != "passed" or prior.get("sourceCommit") != revision:
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
        environment = data.get("environment")
        if environment not in ("stage", "prod"):
            parser.error("Configuration must explicitly select stage or prod")
        expected_host = "api.stage.mmgt.cloud" if environment == "stage" else "api.mmgt.cloud"
        for key in ("authURL", "billingURL", "realtimeURL", "syncURL", "aiURL"):
            url = urlsplit(data.get(key, ""))
            if url.scheme != "https" or url.hostname != expected_host or url.port not in (None, 443) or url.username or url.password or url.query or url.fragment:
                parser.error("Service URLs must belong to the selected platform environment")
        for key in ("appID", "userID", "runID"):
            uuid.UUID(data[key])
        for key in ("email", "password", "collection", "realtimeGrant", "aiConnectionID", "aiModel"):
            if not isinstance(data.get(key), str) or not data[key]:
                parser.error("Required fixture configuration is missing")
        try:
            validate_realtime_grant(data, datetime.datetime.now().timestamp())
        except ValueError as error:
            parser.error(str(error))
        if environment == "prod":
            if not args.stage_report:
                parser.error("Production requires --stage-report for this exact SDK commit")
            stage = read_json(args.stage_report)
            if stage.get("kind") != "swift-live-run" or stage.get("environment") != "stage" or stage.get("status") != "passed" or stage.get("sourceCommit") != revision:
                parser.error("The supplied stage report does not satisfy the production gate")
            report["stageReport"] = str(args.stage_report.resolve())
        report.update(environment=environment, runID=data["runID"], buildReport=str(args.build_report.resolve()),
                      destination=prior["destination"], developerDirectory=prior["developerDirectory"])
        env["DEVELOPER_DIR"] = prior["developerDirectory"]
        # Apple passes TEST_RUNNER_ variables to the runner with the prefix
        # removed. Credentials are never shell arguments or part of our report.
        env["TEST_RUNNER_MMGT_LIVE_CONFIGURATION"] = base64.b64encode(raw).decode()
        command += ["test-without-building", "-project", "Examples/MMGTExample/MMGTExample.xcodeproj",
                    "-scheme", "MMGTLive", "-destination", prior["destination"],
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
    env.pop("TEST_RUNNER_MMGT_LIVE_CONFIGURATION", None)
    if report["exitCode"] == 0 and args.action == "run":
        summary = json.loads(output("xcrun", "xcresulttool", "get", "test-results", "summary",
                                    "--path", str(directory / "tests.xcresult"), "--compact", env=env))
        report["testCounts"] = {key: summary.get(key) for key in ("totalTestCount", "passedTests", "failedTests", "skippedTests")}
        if summary.get("passedTests") != 1 or summary.get("failedTests") != 0 or summary.get("skippedTests") != 0:
            report["exitCode"] = 1
            report["reason"] = "Expected one executed live scenario, with no failures or skips"
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
        # JSON/grant validation errors must not interpolate the supplied content.
        sys.exit("Live runner failed to read configuration, build evidence or local tools; no retry")
