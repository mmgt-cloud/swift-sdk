# Privacy and application responsibilities

The SDK contains no advertising identifier, tracking domain, analytics uploader,
crash uploader or independent telemetry. Network requests go to the explicitly
configured MMGT application, its approved login provider, or its selected AI
connection. The SDK does not ask for access to contacts, location or the photo
library. Passkey user verification takes place in Apple's system interface;
biometric samples are never available to MMGT.

Each SPM target bundles `PrivacyInfo.xcprivacy`. The declarations include data
handled by optional operations in that target, for application functionality,
linked to the authenticated account, without tracking:

| Target | Data transmitted by supported operations |
| --- | --- |
| Auth | Account name, email, optional verified phone, account identifiers, authentication credentials and recovery proofs |
| Billing | Account identifiers, subscription/purchase state, workspace names and invitation email addresses |
| Realtime | Account identifiers and application-defined event content |
| Sync | Account identifiers and application-defined records/mutations |
| AI | Account identifiers, prompts, tool arguments/results, uploaded content and images supplied by the caller |
| Core, SyncSQLite, SwiftUI | No independent collection; the service targets own network behavior |

Billing does not collect card details inside the SDK; the current checkout opens
the provider's hosted page. Its result still requires server-side access checks.
Keychain credentials and the local SQLite outbox are device storage, separate
from data sent to the platform. Keychain entries do not use iCloud sync. The
Keychain activation fence is excluded from backup. SQLite backup policy is chosen
by the application through its database location and resource settings.

`OtherUserContent` describes the generic event, record and file interfaces. It is
not a substitute for the specific categories of a real application's content.
For example, an application sending health records, messages or audio must review
those categories explicitly. AI provider retention and use depend on the selected
connection/account; the SDK does not promise zero retention by a provider.
Additional domain payload must be covered by the integrating application's complete privacy disclosure.

The direct MMGT source review found no calls to UserDefaults, file timestamp
inspection, disk capacity, system boot time or other listed required-reason APIs.
The accessed-API arrays are consequently empty. Foundation file access is used
only for the app's stores. AppAuth and GRDB supply their own manifests, which SPM
must preserve. Re-run this review when changing persistence or dependencies.

The local example build checks that all eight manifests reach the app bundle.
An Xcode privacy report, provider configuration and the application's App Store
privacy details still need review for each shipped application. These files are
not a claim of App Store approval. See Apple's
[privacy manifest documentation](https://developer.apple.com/documentation/bundleresources/privacy-manifest-files),
[data declarations](https://developer.apple.com/documentation/bundleresources/describing-data-use-in-privacy-manifests)
and [required-reason APIs](https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api).
