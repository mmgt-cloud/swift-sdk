# Platform compatibility

`platform.json` maps the npm client surface to native Swift APIs. Its source-file
hashes identify the private platform declarations reviewed for this development
candidate. The private repository is never an installation or test dependency of
this package. A dirty platform revision is explicitly recorded.

Each operation records its native mapping, kind, implementation status and test
references. `serverVerified: false` and pending local, device or environment
acceptance remain open gates. A mapped method does not establish endpoint or
provider correctness. Native adaptations describe deliberate differences from
browser APIs; generic transport extensions are separated from service operations.
Internal TypeScript helper classes do not belong to the public service matrix.

The test target contains 17 synthetic shared JSON fixtures under
`Tests/MMGTTests/Fixtures/v1`. Their manifest, checksums and semantic tests run
without the platform checkout. The platform mirrors their exact bytes and tests
the actual Go and TypeScript DTOs/clients against them. A selected fixture is
evidence only for its scenario, not the entire service.

`privacy.json` is the reviewed per-module manifest inventory. It describes SDK
data transmission and source API use; integrating apps must assess their own
schemas, provider requests, entitlements and privacy disclosures.

The Billing server review now names the immutable platform source files and
checksums separately from the original npm snapshot. Its 18 HTTP operations have
explicit endpoint tests, including authenticated/public headers and request/response
bodies. Six added fixtures cover nonempty catalog, access, workspace and invitation
data. These checks do not represent actual Stripe payments or device acceptance.

Run `python3 scripts/check-contracts.py` to check evidence references and fixture
integrity using only this public checkout. Maintainers can optionally pass
`--platform-source <local-checkout>` to detect server declaration drift and compare
shared bytes. Missing reviews remain counted as pending; integrity validation does
not change their acceptance status. The ordinary simulator runner executes this
check and its regression tests before compiling the package.
