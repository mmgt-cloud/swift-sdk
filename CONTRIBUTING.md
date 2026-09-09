# Contributing

Develop this package in its public repository. Do not copy SDK sources into the
private platform repository. Keep AppAuth and GRDB types out of public MMGT APIs.
New data types must preserve wire values and Swift 6 concurrency guarantees.

Use synthetic fixtures and deterministic response ordering for account changes,
retry, partial mutations, socket retirement and recovery. SDK tests run without
private-repository access or provider credentials. Live stage and production
acceptance uses dedicated test accounts and separate, ignored configuration.

Run the local test, compiler, example and DocC commands in the README. For a
physical device, generate the example project and use its application-hosted
`MMGTDeviceTests` target. Plain SPM tool-hosted tests cannot run on an iPhone.
Select your own signing team, registered Bundle ID and explicit device destination.
The separate [live-service suite](Examples/MMGTExample/LiveTests/README.md) uses
dedicated stage/prod fixtures and a build-then-run procedure for fresh grants.

Update the operation matrix, DocC, privacy inventory and changelog when behavior
changes. Generated declarations are not proof of endpoint correctness. A required
test that cannot run remains pending with its cause; it must not silently skip.

Do not add credentials, real provider payloads, private configuration or test
results with user data to commits. Report vulnerabilities using SECURITY.md.
All build and release steps run locally; GitHub Actions is not a dependency.
