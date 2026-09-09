import Foundation
import MMGTCore

public struct BillingClient: Sendable {
  private let http: HTTPClient
  public let configuration: ServiceConfiguration
  public init(
    configuration: ServiceConfiguration, tokenProvider: @escaping AccessTokenProvider,
    transport: any HTTPTransport = URLSessionTransport()
  ) {
    self.configuration = configuration
    http = HTTPClient(
      configuration: configuration, tokenProvider: tokenProvider, transport: transport)
  }
  private func request<T: Decodable & Sendable>(
    _ path: [String], method: String = "GET", body: JSONValue? = nil, authenticated: Bool = true
  ) async throws -> T {
    try await http.request(
      path: ["app", configuration.appID] + path, method: method, body: body,
      authenticated: authenticated)
  }
  public func getCatalog() async throws -> BillingCatalogResponse {
    try await request(["catalog"], authenticated: false)
  }
  public func getAccess() async throws -> BillingAccessResponse { try await request(["access"]) }
  public func getPlan() async throws -> BillingPlanResponse { try await request(["plan"]) }
  public func startPersonalCheckout(_ input: CheckoutRequest) async throws -> CheckoutResponse {
    try await request(["checkout", "personal"], method: "POST", body: .encoding(input))
  }
  public func startWorkspaceCheckout(_ input: WorkspaceCheckoutRequest) async throws
    -> CheckoutResponse
  {
    try await request(["checkout", "workspace"], method: "POST", body: .encoding(input))
  }
  public func startOneTimeCheckout(_ input: OneTimeCheckoutRequest) async throws -> CheckoutResponse
  {
    try await request(["checkout", "addon"], method: "POST", body: .encoding(input))
  }
  public func changeSubscription(_ input: ChangeSubscriptionRequest) async throws
    -> ChangeSubscriptionResponse
  {
    try await request(["subscription", "change"], method: "POST", body: .encoding(input))
  }
  public func createPortalSession(_ input: PortalRequest = .init()) async throws -> PortalResponse {
    try await request(["portal"], method: "POST", body: .encoding(input))
  }
  public func listWorkspaces() async throws -> WorkspaceListResponse {
    try await request(["workspaces"])
  }
  public func getWorkspace(_ id: String) async throws -> WorkspaceResponse {
    try await request(["workspaces", id])
  }
  public func listMembers(workspaceID: String) async throws -> WorkspaceMembersResponse {
    try await request(["workspaces", workspaceID, "members"])
  }
  public func removeMember(workspaceID: String, userID: String) async throws -> StatusResponse {
    try await request(["workspaces", workspaceID, "members", userID], method: "DELETE")
  }
  public func addSeats(workspaceID: String, input: AddSeatsRequest) async throws -> AddSeatsResponse
  {
    try await request(["workspaces", workspaceID, "seats"], method: "POST", body: .encoding(input))
  }
  public func listInvites(workspaceID: String) async throws -> WorkspaceInvitesResponse {
    try await request(["workspaces", workspaceID, "invites"])
  }
  public func createInvites(workspaceID: String, input: CreateInvitesRequest) async throws
    -> CreateInvitesResponse
  {
    try await request(
      ["workspaces", workspaceID, "invites"], method: "POST", body: .encoding(input))
  }
  public func cancelInvite(workspaceID: String, inviteID: String) async throws -> StatusResponse {
    try await request(["workspaces", workspaceID, "invites", inviteID], method: "DELETE")
  }
  public func resendInvite(workspaceID: String, inviteID: String) async throws
    -> ResendInviteResponse
  {
    try await request(["workspaces", workspaceID, "invites", inviteID, "resend"], method: "POST")
  }
  public func acceptInvite(token: String) async throws -> AcceptInviteResponse {
    try await request(["invites", "accept"], method: "POST", body: ["token": .string(token)])
  }
}
