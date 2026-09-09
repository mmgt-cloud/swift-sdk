# Local release procedure

All eight products share one SemVer version, independently from npm. Development
starts at 0.1.0; stable 1.0.0 requires the complete five-service/native Auth gates.
Never move or replace a published tag. A correction receives a new version.

1. Freeze a clean SDK commit, dependency lockfile and operation matrix. Record the
   compatible backend commit/contract and separate local, device, stage and
   production evidence. Platform deployments run locally, stage before production.
2. Run simulator tests, every product and minimal-consumer builds, minimum-compiler
   checks, the example and DocC. Check actual bundled privacy manifests. Verify the
   minimum runtime and physical iPhone separately; passkeys and Universal Links
   require signed application/domain acceptance, not just a successful build.
3. Reconcile the changelog and migration notes with the candidate. Do not advertise
   an SDK version in Panel ZIPs until that version is publicly installable.
4. Push the verified source commit to the public repository. Create an annotated
   SemVer tag at that exact commit and push that tag once. Use a GitHub Release
   naming the tested platforms, contract, limitations and migration steps. Preview
   releases must be clearly identified; they do not imply stable acceptance.
5. Submit the HTTPS repository URL with `.git` suffix through the
   [Swift Package Index submission page](https://swiftpackageindex.com/add-a-package).
   The public root manifest, compilable package and SemVer release are independently
   checked by the index. `.spi.yml` selects all eight DocC targets; follow the
   [SPI documentation configuration](https://swiftpackageindex.com/swiftpackageindex/spimanifest/documentation/spimanifest/commonusecases).
6. Install the exact tag anonymously from a clean SPM/Xcode consumer with no local
   path dependency, GitHub token or private checkout. Build the example against
   that public tag. Verify the actual hosted DocC URLs, not merely local archives.
7. Update the platform's Swift release record to the available version, regenerate
   and compile ZIP examples, then download and verify fresh Panel exports in both
   environments. Preserve dated evidence and source/digest identities.

SPM installation uses the public Git repository; it does not depend on indexing.
SPI submission, indexing and documentation hosting have distinct outcomes. An
external service delay remains visible and must not be described as completed.
Private vulnerability reporting is enabled; release notes must retain a working
security-reporting link. No additional registry or paid build service is required.
