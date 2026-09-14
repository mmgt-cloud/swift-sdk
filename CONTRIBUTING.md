# Contributing

Develop this package in its public repository. Do not copy SDK sources into the
private platform repository. Keep AppAuth and GRDB types out of public MMGT APIs.
New data types must preserve wire values and Swift 6 concurrency guarantees.

Use synthetic fixtures and deterministic response ordering for account changes,
retry, partial mutations, socket retirement and recovery. SDK tests run without
private-repository access or provider credentials. Live stage and production
acceptance uses dedicated test accounts and separate, ignored configuration.

Since 2026-09-14, targeted verification is the default for changes and fixes,
both locally and on stage and production. Select the relevant test, compiler,
example or DocC commands from the README and include regressions for affected
consumers. Run the full platform test matrix only when explicitly requested or
agreed; a new commit or fix does not automatically require it. Verify a deployed
fix on stage before promoting it and repeat the relevant smoke on production.
Record the tested commit, environment, scope and results; previous full-matrix
results remain dated evidence, not a fresh run for the new change.

For a physical device, generate the example project and use its application-hosted
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
