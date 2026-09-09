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

The test target contains 11 synthetic shared JSON fixtures under
`Tests/MMGTTests/Fixtures/v1`. Their manifest, checksums and semantic tests run
without the platform checkout. The platform mirrors their exact bytes and tests
the actual Go and TypeScript DTOs/clients against them. A selected fixture is
evidence only for its scenario, not the entire service.

`privacy.json` is the reviewed per-module manifest inventory. It describes SDK
data transmission and source API use; integrating apps must assess their own
schemas, provider requests, entitlements and privacy disclosures.
