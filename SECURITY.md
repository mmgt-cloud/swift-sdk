# Security reporting

Report vulnerabilities through GitHub's
[private vulnerability reporting](https://github.com/mmgt-cloud/swift-sdk/security/advisories/new).
This repository has private reporting enabled. Do not open a public issue with
tokens, passwords, provider credentials, personal data or an exploitable live URL.

Include the SDK revision/version, affected product, iOS/Xcode versions, a minimal
synthetic reproduction and the expected security boundary. Use a test application
and accounts you control. Do not test another tenant or production user data.

The SDK is under development and has no supported stable version yet. Release
notes will identify the supported version and any required backend migration.
There is no published response-time or remediation SLA.

Keep administrative operations and provider secrets on your backend. A public app
ID is configuration, not authorization. Logout cancels client work and invalidates
local session activation; already-claimed server effects may require authoritative
reconciliation. Consult each service's documented retry and idempotency behavior.
