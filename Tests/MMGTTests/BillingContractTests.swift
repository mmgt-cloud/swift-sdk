import Foundation
import MMGTBilling
import MMGTCore
import Testing

private enum BillingOperation: String, CaseIterable, Sendable {
  case catalog, access, plan, personalCheckout, workspaceCheckout, addonCheckout
  case changeSubscription, portal, workspaces, workspace, members, removeMember
  case addSeats, invites, createInvites, cancelInvite, resendInvite, acceptInvite
}

@Suite struct BillingContractTests {
  private let workspaceID = "33333333-3333-4333-8333-333333333333"
  private let userID = "22222222-2222-4222-8222-222222222222"
  private func fixture(_ name: String) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: SharedWireContractTests().data(name))
  }

  @Test(arguments: BillingOperation.allCases)
  private func actualEndpointContract(_ operation: BillingOperation) async throws {
    var path: [String]
    var method = "GET"
    var body: JSONValue?
    let wire: JSONValue
    switch operation {
    case .catalog:
      path = ["catalog"]
      wire = try fixture("billing-catalog")
    case .access, .plan:
      path = [operation.rawValue]
      wire = try fixture("billing-fullaccess")
    case .personalCheckout, .workspaceCheckout, .addonCheckout:
      let scope =
        operation == .personalCheckout
        ? "personal" : operation == .workspaceCheckout ? "workspace" : "addon"
      path = ["checkout", scope]
      method = "POST"
      var values: [String: JSONValue] = [
        "offer_id": "synthetic-offer", "success_url": "https://app.example.invalid/success",
        "cancel_url": "https://app.example.invalid/cancel",
      ]
      if operation == .workspaceCheckout {
        values["workspace_name"] = "Synthetic workspace"
        values["extra_seats"] = 3
      }
      body = .object(values)
      wire = try fixture("billing-checkout")
    case .changeSubscription:
      path = ["subscription", "change"]
      method = "POST"
      body = ["target_offer_id": "synthetic-offer", "proration_behavior": "none"]
      wire = ["status": "updated", "access": try fixture("billing-fullaccess")]
    case .portal:
      path = ["portal"]
      method = "POST"
      body = [
        "workspace_id": .string(workspaceID), "return_url": "https://app.example.invalid/return",
      ]
      wire = ["url": "https://billing.example.invalid/portal"]
    case .workspaces:
      path = ["workspaces"]
      wire = ["workspaces": try fixture("billing-fullaccess")["workspace_memberships"]!]
    case .workspace:
      path = ["workspaces", workspaceID]
      wire = try fixture("billing-workspace")
    case .members:
      path = ["workspaces", workspaceID, "members"]
      wire = try fixture("billing-members")
    case .removeMember:
      path = ["workspaces", workspaceID, "members", userID]
      method = "DELETE"
      wire = ["status": "removed"]
    case .addSeats:
      path = ["workspaces", workspaceID, "seats"]
      method = "POST"
      body = ["additional_seats": 3]
      wire = ["workspace": try fixture("billing-workspace")["workspace"]!]
    case .invites:
      path = ["workspaces", workspaceID, "invites"]
      wire = try fixture("billing-invites")
    case .createInvites:
      path = ["workspaces", workspaceID, "invites"]
      method = "POST"
      body = ["emails": ["invited@example.invalid"], "expires_in_days": 7]
      wire = try fixture("billing-createdinvites")
    case .cancelInvite:
      path = ["workspaces", workspaceID, "invites", "synthetic-invite"]
      method = "DELETE"
      wire = ["status": "canceled"]
    case .resendInvite:
      path = ["workspaces", workspaceID, "invites", "synthetic-invite", "resend"]
      method = "POST"
      guard case .array(let invites) = try fixture("billing-createdinvites")["invites"] else {
        throw MMGTError.invalidResponse("fixture")
      }
      wire = ["invite": invites[0]]
    case .acceptInvite:
      path = ["invites", "accept"]
      method = "POST"
      body = ["token": "synthetic-invite-token"]
      wire = ["workspace": try fixture("billing-fullaccess")["workspace"]!]
    }
    let transport = RecordingTransport([
      .init(data: try JSONEncoder().encode(wire), status: method == "POST" ? 201 : 200)
    ])
    let config = try ServiceConfiguration(
      baseURL: URL(string: "https://api.example.invalid/billing")!,
      appID: "11111111-1111-4111-8111-111111111111")
    let client = BillingClient(
      configuration: config, tokenProvider: { "synthetic-access" }, transport: transport)
    let result: JSONValue
    let checkout = CheckoutRequest(
      offerId: "synthetic-offer", successUrl: "https://app.example.invalid/success",
      cancelUrl: "https://app.example.invalid/cancel")
    switch operation {
    case .catalog: result = try .encoding(await client.getCatalog())
    case .access: result = try .encoding(await client.getAccess())
    case .plan: result = try .encoding(await client.getPlan())
    case .personalCheckout: result = try .encoding(await client.startPersonalCheckout(checkout))
    case .workspaceCheckout:
      result = try .encoding(
        await client.startWorkspaceCheckout(
          .init(
            offerId: checkout.offerId, successUrl: checkout.successUrl,
            cancelUrl: checkout.cancelUrl, workspaceName: "Synthetic workspace", extraSeats: 3)))
    case .addonCheckout: result = try .encoding(await client.startOneTimeCheckout(checkout))
    case .changeSubscription:
      result = try .encoding(
        await client.changeSubscription(
          .init(targetOfferId: "synthetic-offer", prorationBehavior: "none")))
    case .portal:
      result = try .encoding(
        await client.createPortalSession(
          .init(workspaceId: workspaceID, returnUrl: "https://app.example.invalid/return")))
    case .workspaces: result = try .encoding(await client.listWorkspaces())
    case .workspace: result = try .encoding(await client.getWorkspace(workspaceID))
    case .members: result = try .encoding(await client.listMembers(workspaceID: workspaceID))
    case .removeMember:
      result = try .encoding(await client.removeMember(workspaceID: workspaceID, userID: userID))
    case .addSeats:
      result = try .encoding(
        await client.addSeats(workspaceID: workspaceID, input: .init(additionalSeats: 3)))
    case .invites: result = try .encoding(await client.listInvites(workspaceID: workspaceID))
    case .createInvites:
      result = try .encoding(
        await client.createInvites(
          workspaceID: workspaceID,
          input: .init(emails: ["invited@example.invalid"], expiresInDays: 7)))
    case .cancelInvite:
      result = try .encoding(
        await client.cancelInvite(workspaceID: workspaceID, inviteID: "synthetic-invite"))
    case .resendInvite:
      result = try .encoding(
        await client.resendInvite(workspaceID: workspaceID, inviteID: "synthetic-invite"))
    case .acceptInvite:
      result = try .encoding(await client.acceptInvite(token: "synthetic-invite-token"))
    }
    #expect(result == wire)
    let requests = await transport.requests
    #expect(requests.count == 1)
    let request = try #require(requests.first)
    #expect(request.url == (try config.url(["app", config.appID] + path)))
    #expect(request.httpMethod == method)
    #expect(request.value(forHTTPHeaderField: "X-App-ID") == config.appID)
    #expect(
      request.value(forHTTPHeaderField: "Authorization")
        == (operation == .catalog ? nil : "Bearer synthetic-access"))
    #expect(try request.httpBody.map { try JSONDecoder().decode(JSONValue.self, from: $0) } == body)
  }

  @Test(arguments: [429, 500, 503])
  func checkoutFailureRetainsErrorAndDoesNotRepeatPayment(_ status: Int) async throws {
    let transport = RecordingTransport([
      .init(
        data: Data(#"{"error":"checkout_unavailable"}"#.utf8), status: status,
        headers: ["X-Request-ID": "synthetic-request", "Retry-After": "30"])
    ])
    let client = BillingClient(
      configuration: try .init(
        baseURL: URL(string: "https://api.example.invalid/billing")!, appID: "synthetic-app"),
      tokenProvider: { "synthetic-access" }, transport: transport)
    do {
      _ = try await client.startPersonalCheckout(.init(offerId: "synthetic-offer"))
      Issue.record("Expected server failure")
    } catch let error as APIError {
      #expect(error.status == status && error.code == "checkout_unavailable")
      #expect(error.requestID == "synthetic-request" && error.retryAfter == "30")
    }
    #expect(await transport.requests.count == 1)
  }
}
