#!/usr/bin/env python3
"""Synthetic wire/security regressions for the local live-fixture preflight."""
import base64
import hashlib
import hmac
import importlib.util
import json
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("live_runner", Path(__file__).with_name("test-live.py"))
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class RealtimeGrantTests(unittest.TestCase):
    def setUp(self):
        self.now = 2_000_000_000
        self.fixture = dict(appID="00000000-0000-4000-8000-000000000001",
                            userID="00000000-0000-4000-8000-000000000002",
                            runID="00000000-0000-4000-8000-000000000003")
        self.claims = dict(app_id=self.fixture["appID"], user_id=self.fixture["userID"],
                           channels=["sdk-live:" + self.fixture["runID"]],
                           permissions=["subscribe", "publish"], iat=self.now, exp=self.now + 300)

    @staticmethod
    def encode(value):
        return base64.urlsafe_b64encode(value).decode().rstrip("=")

    def token(self, claims=None):
        # Match Go signGrant: sign the encoded JSON, not decoded JSON or a JWT header.
        payload = self.encode(json.dumps(self.claims if claims is None else claims).encode())
        mac = hmac.new(b"synthetic-test-key-never-a-platform-secret", payload.encode(), hashlib.sha256)
        return payload + "." + self.encode(mac.digest())

    def check(self, token):
        runner.validate_realtime_grant({**self.fixture, "realtimeGrant": token}, self.now)

    def test_real_two_part_wire_contract(self):
        self.check(self.token())
        self.claims["permissions"].reverse()
        self.check(self.token())

    def test_jwt_and_unsigned_payload_are_rejected(self):
        for token in ["e30." + self.token(), self.token().split(".")[0], self.token() + "."]:
            with self.subTest(tokenShape=len(token.split("."))), self.assertRaises(ValueError):
                self.check(token)

    def test_foreign_or_expanded_scope_is_rejected(self):
        cases = dict(app_id="other-app", user_id="other-user", channels=["*"],
                     permissions=["subscribe", "publish", "presence"])
        for key, value in cases.items():
            with self.subTest(claim=key), self.assertRaises(ValueError):
                self.check(self.token({**self.claims, key: value}))
        with self.assertRaises(ValueError):
            self.check(self.token({**self.claims, "channels": self.claims["channels"] + ["other"]}))

    def test_expiry_requires_three_minutes_and_an_integer(self):
        self.check(self.token({**self.claims, "exp": self.now + 180}))
        for expiry in [self.now + 179, self.now, self.now - 1, None, True, str(self.now + 300), self.now + 300.0]:
            with self.subTest(expiryType=type(expiry).__name__), self.assertRaises(ValueError):
                self.check(self.token({**self.claims, "exp": expiry}))

    def test_malformed_claims_never_escape_with_private_input(self):
        for claims in [[], None, "private-input-marker", 2, {**self.claims, "permissions": None}]:
            with self.subTest(claimsType=type(claims).__name__):
                token = self.token(claims) if claims is not None else self.encode(b"null") + "." + self.token().split(".")[1]
                with self.assertRaises(ValueError) as raised:
                    self.check(token)
                self.assertNotIn("private-input-marker", str(raised.exception))

    def test_malformed_encoding_and_mac_size_are_rejected(self):
        payload, signature = self.token().split(".")
        for token in [payload + "." + signature + "=", payload + "=." + signature,
                      payload + ".AA", payload + ".!", "A." + signature,
                      self.encode(b"not json") + "." + signature,
                      self.encode(bytes([255])) + "." + signature, "x" * 16_385]:
            with self.subTest(length=len(token)), self.assertRaises(ValueError):
                self.check(token)

    def test_local_preflight_does_not_claim_to_verify_the_signature(self):
        payload, _ = self.token().split(".")
        self.check(payload + "." + self.encode(bytes(32)))
        # The live service must reject this MAC. The runner deliberately has no signing key.


if __name__ == "__main__":
    unittest.main()
