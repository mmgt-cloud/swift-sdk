import CryptoKit
import Foundation
import MMGTAI
import MMGTAuth
import MMGTBilling
import MMGTCore
import MMGTRealtime
import MMGTSync
import Testing

/// These exact bytes are also decoded by the platform's Go DTOs and npm clients.
@Suite struct SharedWireContractTests {
  struct Manifest: Decodable {
    struct Entry: Decodable { let file, service, sha256: String }
    let schemaVersion: Int
    let synthetic: Bool
    let fixtures: [Entry]
  }
  func data(_ name: String) throws -> Data {
    let url = try #require(
      Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/v1"))
    return try Data(contentsOf: url)
  }
  func decode<T: Decodable>(_ name: String, as type: T.Type = T.self) throws -> T {
    try JSONDecoder().decode(type, from: data(name))
  }
  func roundTrip<T: Codable & Equatable>(_ name: String, as type: T.Type) throws -> T {
    let value = try decode(name, as: type)
    let wire = try decode(name, as: JSONValue.self)
    #expect(try JSONValue.encoding(value) == wire)
    return value
  }
  @Test func manifestCoversEveryFixtureAndMatchesItsBytes() throws {
    let manifest = try decode("manifest", as: Manifest.self)
    #expect(manifest.schemaVersion == 1 && manifest.synthetic)
    #expect(Set(manifest.fixtures.map(\.service)) == ["auth", "billing", "sync", "ai", "realtime"])
    #expect(Set(manifest.fixtures.map(\.file)).count == manifest.fixtures.count)
    let directory = try #require(
      Bundle.module.url(forResource: "manifest", withExtension: "json", subdirectory: "Fixtures/v1")
    ).deletingLastPathComponent()
    let actual = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter {
      $0.hasSuffix(".json") && $0 != "manifest.json"
    }
    #expect(Set(actual) == Set(manifest.fixtures.map(\.file)))
    for entry in manifest.fixtures {
      #expect(!entry.file.contains("/") && entry.file.hasSuffix(".json"))
      let bytes = try data(String(entry.file.dropLast(5)))
      #expect(SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() == entry.sha256)
    }
  }
  @Test func authNeverTurnsEnrollmentOrMFAIntoAFullSession() async throws {
    let transport = RecordingTransport(
      try ["auth-enrollment", "auth-mfa"].map {
        HTTPResponse(data: try data($0), status: 202, headers: [:])
      })
    let client = AuthClient(
      configuration: try .init(
        baseURL: URL(string: "https://api.example.invalid/auth")!,
        appID: "11111111-1111-4111-8111-111111111111"), transport: transport)
    guard
      case .requiresTwoFactorSetup(let tokens, _) = try await client.login(
        input: .init(email: "synthetic@example.invalid", password: "synthetic"))
    else {
      Issue.record("Enrollment credentials must not authenticate a user")
      return
    }
    #expect(tokens.accessToken == "synthetic-enrollment-access")
    guard
      case .requiresTwoFactor(let temporary, let method, _) = try await client.login(
        input: .init(email: "synthetic@example.invalid", password: "synthetic"))
    else {
      Issue.record("Second factor must remain required")
      return
    }
    #expect(temporary == "synthetic-temp" && method == "passkey")
  }
  @Test func syncPreservesBigintVersionsFalseNullAndNanosecondDates() throws {
    let pull = try roundTrip("sync-pull", as: SyncPullResponse.self)
    let record = try #require(pull.changes.first)
    #expect(record.sequence == "9007199254740993")
    #expect(record.version == "9223372036854775807")
    #expect(record.data?["enabled"] == .bool(false))
    #expect(record.data?["cleared"] == .null)
    #expect(record.createdAt == "2026-09-09T12:00:00.123456789Z")
    _ = try WireDate.parse(record.createdAt)
    let push = try roundTrip("sync-push", as: SyncPushResponse.self)
    #expect(push.results.map(\.status) == ["applied", "conflict", "rejected"])
    #expect(push.results[1].conflictId == "synthetic-conflict")
    #expect(push.results[2].error == "schema_validation_failed")
    let snapshot = try roundTrip("sync-snapshot", as: SyncSnapshotResponse.self)
    #expect(snapshot.watermark == record.version)
    #expect(snapshot.records == pull.changes)
    #expect(!snapshot.hasMore && snapshot.cursor == "synthetic-snapshot-cursor")
  }
  @Test func checkoutCallbackDoesNotImplyAccess() throws {
    let checkout = try roundTrip("billing-checkout", as: CheckoutResponse.self)
    let access = try roundTrip("billing-access", as: BillingAccessResponse.self)
    #expect(checkout.status == "pending" && access.status == "pending")
    #expect(!access.hasPaidAccess && access.entitlements.isEmpty)
    #expect(access.subscription == nil && access.workspaceMemberships.isEmpty)
  }
  @Test func billingRetainsNestedAccessWorkspaceAndInviteFields() throws {
    let catalog = try roundTrip("billing-catalog", as: BillingCatalogResponse.self)
    #expect(catalog.offers.first?.unitAmountCents == 999)
    #expect(catalog.offers.first?.extraSeatAmountCents == 125)
    let access = try roundTrip("billing-fullaccess", as: BillingAccessResponse.self)
    #expect(access.hasPaidAccess && access.subscription?.cancelAtPeriodEnd == false)
    #expect(access.personalSubscription?.scope == "personal")
    #expect(access.workspace == access.workspaceMemberships.first)
    #expect(access.workspace?.availableSeats == 6)
    #expect(access.entitlements.first?.createdAt == "2026-09-09T12:00:00.123456789Z")
    let workspace = try roundTrip("billing-workspace", as: WorkspaceResponse.self)
    #expect(workspace.workspace.id == access.workspace?.id && workspace.role == "owner")
    #expect(workspace.workspace.extraSeats == 3)
    let members = try roundTrip("billing-members", as: WorkspaceMembersResponse.self)
    #expect(members.members.first?.userId == access.userId)
    let invites = try roundTrip("billing-invites", as: WorkspaceInvitesResponse.self)
    #expect(invites.invites.first?.emailDeliveryStatus == nil)
    let created = try roundTrip("billing-createdinvites", as: CreateInvitesResponse.self)
    #expect(created.invites.first?.emailDeliveryStatus == "queued")
    #expect(created.invites.first?.id == invites.invites.first?.id)
    #expect(
      created.invites.first?.acceptUrl == "https://app.example.invalid/invite?token=synthetic-only")
  }
  @Test func aiResponseAndErrorKeepTheirActualSemantics() throws {
    let response = try roundTrip("ai-response", as: AIResponse.self)
    #expect(response.status == "requires_action")
    let call = try #require(response.toolCalls?.first)
    #expect(call.arguments["enabled"] == .bool(false))
    #expect(call.arguments["clear"] == .null)
    guard case .failed(let error) = try AIStreamEvent(wire: decode("ai-error")) else {
      Issue.record("An AI error must not silently become an unknown frame")
      return
    }
    #expect(error.code == "provider_unavailable" && error.retryable == true)
  }
  @Test func realtimeEventAndAcknowledgementRemainDistinct() throws {
    guard case .event(let event) = try RealtimeMessage(wire: decode("realtime-event")) else {
      Issue.record("Expected an event")
      return
    }
    guard
      case .acknowledged(let channel, let id, let date) = try RealtimeMessage(
        wire: decode("realtime-ack"))
    else {
      Issue.record("Expected a transport acknowledgement")
      return
    }
    #expect(id == event.id && channel == event.channel)
    #expect(date == "2026-09-09T12:00:00.123456789Z")
    _ = try WireDate.parse(date)
  }
}
