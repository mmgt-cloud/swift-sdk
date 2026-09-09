// Derived from platform DTO declarations. Verification status and hashes: Contracts/platform.json.
import Foundation
import MMGTCore

public typealias BillingPlanType = String

public typealias BillingStatus = String

public typealias BillingInterval = String

public typealias BillingModel = String

public typealias WorkspaceRole = String

public struct BillingOffer: Codable, Sendable, Equatable {
  public var id: String
  public var key: String
  public var name: String
  public var `description`: String
  public var planType: String
  public var billingModel: BillingModel
  public var interval: BillingInterval
  public var currency: String
  public var unitAmountCents: Int
  public var baseSeatCount: Int
  public var extraSeatAmountCents: Int?
  public var contactUrl: String?
  public var metadata: [String: String]?
  public init(
    id: String, key: String, name: String, `description`: String, planType: String,
    billingModel: BillingModel, interval: BillingInterval, currency: String, unitAmountCents: Int,
    baseSeatCount: Int, extraSeatAmountCents: Int? = nil, contactUrl: String? = nil,
    metadata: [String: String]? = nil
  ) {
    self.id = id
    self.key = key
    self.name = name
    self.`description` = `description`
    self.planType = planType
    self.billingModel = billingModel
    self.interval = interval
    self.currency = currency
    self.unitAmountCents = unitAmountCents
    self.baseSeatCount = baseSeatCount
    self.extraSeatAmountCents = extraSeatAmountCents
    self.contactUrl = contactUrl
    self.metadata = metadata
  }
  enum CodingKeys: String, CodingKey {
    case id = "id"
    case key = "key"
    case name = "name"
    case `description` = "description"
    case planType = "plan_type"
    case billingModel = "billing_model"
    case interval = "interval"
    case currency = "currency"
    case unitAmountCents = "unit_amount_cents"
    case baseSeatCount = "base_seat_count"
    case extraSeatAmountCents = "extra_seat_amount_cents"
    case contactUrl = "contact_url"
    case metadata = "metadata"
  }
}

public struct BillingCatalogResponse: Codable, Sendable, Equatable {
  public var offers: [BillingOffer]
  public init(offers: [BillingOffer]) {
    self.offers = offers
  }
  enum CodingKeys: String, CodingKey {
    case offers = "offers"
  }
}

public struct BillingSubscriptionView: Codable, Sendable, Equatable {
  public var scope: String
  public var status: BillingStatus
  public var offerId: String
  public var offerKey: String
  public var offerName: String
  public var currentPeriodEnd: String?
  public var cancelAtPeriodEnd: Bool
  public init(
    scope: String, status: BillingStatus, offerId: String, offerKey: String, offerName: String,
    currentPeriodEnd: String? = nil, cancelAtPeriodEnd: Bool
  ) {
    self.scope = scope
    self.status = status
    self.offerId = offerId
    self.offerKey = offerKey
    self.offerName = offerName
    self.currentPeriodEnd = currentPeriodEnd
    self.cancelAtPeriodEnd = cancelAtPeriodEnd
  }
  enum CodingKeys: String, CodingKey {
    case scope = "scope"
    case status = "status"
    case offerId = "offer_id"
    case offerKey = "offer_key"
    case offerName = "offer_name"
    case currentPeriodEnd = "current_period_end"
    case cancelAtPeriodEnd = "cancel_at_period_end"
  }
}

public struct BillingEntitlement: Codable, Sendable, Equatable {
  public var id: String
  public var offerId: String
  public var key: String
  public var name: String
  public var status: BillingStatus
  public var stripeCheckoutSessionId: String
  public var createdAt: String
  public init(
    id: String, offerId: String, key: String, name: String, status: BillingStatus,
    stripeCheckoutSessionId: String, createdAt: String
  ) {
    self.id = id
    self.offerId = offerId
    self.key = key
    self.name = name
    self.status = status
    self.stripeCheckoutSessionId = stripeCheckoutSessionId
    self.createdAt = createdAt
  }
  enum CodingKeys: String, CodingKey {
    case id = "id"
    case offerId = "offer_id"
    case key = "key"
    case name = "name"
    case status = "status"
    case stripeCheckoutSessionId = "stripe_checkout_session_id"
    case createdAt = "created_at"
  }
}

public struct BillingWorkspaceSummary: Codable, Sendable, Equatable {
  public var id: String
  public var name: String
  public var role: WorkspaceRole
  public var status: BillingStatus
  public var seatLimit: Int
  public var memberCount: Int
  public var availableSeats: Int
  public var isOwner: Bool
  public init(
    id: String, name: String, role: WorkspaceRole, status: BillingStatus, seatLimit: Int,
    memberCount: Int, availableSeats: Int, isOwner: Bool
  ) {
    self.id = id
    self.name = name
    self.role = role
    self.status = status
    self.seatLimit = seatLimit
    self.memberCount = memberCount
    self.availableSeats = availableSeats
    self.isOwner = isOwner
  }
  enum CodingKeys: String, CodingKey {
    case id = "id"
    case name = "name"
    case role = "role"
    case status = "status"
    case seatLimit = "seat_limit"
    case memberCount = "member_count"
    case availableSeats = "available_seats"
    case isOwner = "is_owner"
  }
}

public struct BillingAccessResponse: Codable, Sendable, Equatable {
  public var appId: String
  public var userId: String
  public var hasPaidAccess: Bool
  public var plan: BillingPlanType
  public var status: BillingStatus
  public var subscription: BillingSubscriptionView?
  public var personalSubscription: BillingSubscriptionView?
  public var workspace: BillingWorkspaceSummary?
  public var workspaceMemberships: [BillingWorkspaceSummary]
  public var entitlements: [BillingEntitlement]
  public var freeLimitBannerKey: String?
  public init(
    appId: String, userId: String, hasPaidAccess: Bool, plan: BillingPlanType,
    status: BillingStatus, subscription: BillingSubscriptionView? = nil,
    personalSubscription: BillingSubscriptionView? = nil, workspace: BillingWorkspaceSummary? = nil,
    workspaceMemberships: [BillingWorkspaceSummary], entitlements: [BillingEntitlement],
    freeLimitBannerKey: String? = nil
  ) {
    self.appId = appId
    self.userId = userId
    self.hasPaidAccess = hasPaidAccess
    self.plan = plan
    self.status = status
    self.subscription = subscription
    self.personalSubscription = personalSubscription
    self.workspace = workspace
    self.workspaceMemberships = workspaceMemberships
    self.entitlements = entitlements
    self.freeLimitBannerKey = freeLimitBannerKey
  }
  enum CodingKeys: String, CodingKey {
    case appId = "app_id"
    case userId = "user_id"
    case hasPaidAccess = "has_paid_access"
    case plan = "plan"
    case status = "status"
    case subscription = "subscription"
    case personalSubscription = "personal_subscription"
    case workspace = "workspace"
    case workspaceMemberships = "workspace_memberships"
    case entitlements = "entitlements"
    case freeLimitBannerKey = "free_limit_banner_key"
  }
}

public typealias BillingPlanResponse = BillingAccessResponse

public struct CheckoutRequest: Codable, Sendable, Equatable {
  public var offerId: String
  public var successUrl: String?
  public var cancelUrl: String?
  public init(offerId: String, successUrl: String? = nil, cancelUrl: String? = nil) {
    self.offerId = offerId
    self.successUrl = successUrl
    self.cancelUrl = cancelUrl
  }
  enum CodingKeys: String, CodingKey {
    case offerId = "offer_id"
    case successUrl = "success_url"
    case cancelUrl = "cancel_url"
  }
}

public struct WorkspaceCheckoutRequest: Codable, Sendable, Equatable {
  public var offerId: String
  public var successUrl: String?
  public var cancelUrl: String?
  public var workspaceName: String
  public var extraSeats: Int?
  public init(
    offerId: String, successUrl: String? = nil, cancelUrl: String? = nil, workspaceName: String,
    extraSeats: Int? = nil
  ) {
    self.offerId = offerId
    self.successUrl = successUrl
    self.cancelUrl = cancelUrl
    self.workspaceName = workspaceName
    self.extraSeats = extraSeats
  }
  enum CodingKeys: String, CodingKey {
    case offerId = "offer_id"
    case successUrl = "success_url"
    case cancelUrl = "cancel_url"
    case workspaceName = "workspace_name"
    case extraSeats = "extra_seats"
  }
}

public typealias OneTimeCheckoutRequest = CheckoutRequest

public struct CheckoutApiRequest: Codable, Sendable, Equatable {
  public var offerId: String
  public var successUrl: String?
  public var cancelUrl: String?
  public var workspaceName: String?
  public var extraSeats: Int?
  public init(
    offerId: String, successUrl: String? = nil, cancelUrl: String? = nil,
    workspaceName: String? = nil, extraSeats: Int? = nil
  ) {
    self.offerId = offerId
    self.successUrl = successUrl
    self.cancelUrl = cancelUrl
    self.workspaceName = workspaceName
    self.extraSeats = extraSeats
  }
  enum CodingKeys: String, CodingKey {
    case offerId = "offer_id"
    case successUrl = "success_url"
    case cancelUrl = "cancel_url"
    case workspaceName = "workspace_name"
    case extraSeats = "extra_seats"
  }
}

public struct CheckoutResponse: Codable, Sendable, Equatable {
  public var checkoutSessionId: String
  public var url: String
  public var status: String
  public var workspaceId: String?
  public init(checkoutSessionId: String, url: String, status: String, workspaceId: String? = nil) {
    self.checkoutSessionId = checkoutSessionId
    self.url = url
    self.status = status
    self.workspaceId = workspaceId
  }
  enum CodingKeys: String, CodingKey {
    case checkoutSessionId = "checkout_session_id"
    case url = "url"
    case status = "status"
    case workspaceId = "workspace_id"
  }
}

public typealias SubscriptionProrationBehavior = String

public struct ChangeSubscriptionRequest: Codable, Sendable, Equatable {
  public var targetOfferId: String
  public var prorationBehavior: SubscriptionProrationBehavior?
  public init(targetOfferId: String, prorationBehavior: SubscriptionProrationBehavior? = nil) {
    self.targetOfferId = targetOfferId
    self.prorationBehavior = prorationBehavior
  }
  enum CodingKeys: String, CodingKey {
    case targetOfferId = "target_offer_id"
    case prorationBehavior = "proration_behavior"
  }
}

public struct ChangeSubscriptionApiRequest: Codable, Sendable, Equatable {
  public var targetOfferId: String
  public var prorationBehavior: SubscriptionProrationBehavior?
  public init(targetOfferId: String, prorationBehavior: SubscriptionProrationBehavior? = nil) {
    self.targetOfferId = targetOfferId
    self.prorationBehavior = prorationBehavior
  }
  enum CodingKeys: String, CodingKey {
    case targetOfferId = "target_offer_id"
    case prorationBehavior = "proration_behavior"
  }
}

public struct ChangeSubscriptionResponse: Codable, Sendable, Equatable {
  public var status: String
  public var access: BillingAccessResponse
  public var subscription: BillingSubscriptionView?
  public init(
    status: String, access: BillingAccessResponse, subscription: BillingSubscriptionView? = nil
  ) {
    self.status = status
    self.access = access
    self.subscription = subscription
  }
  enum CodingKeys: String, CodingKey {
    case status = "status"
    case access = "access"
    case subscription = "subscription"
  }
}

public struct PortalRequest: Codable, Sendable, Equatable {
  public var workspaceId: String?
  public var returnUrl: String?
  public init(workspaceId: String? = nil, returnUrl: String? = nil) {
    self.workspaceId = workspaceId
    self.returnUrl = returnUrl
  }
  enum CodingKeys: String, CodingKey {
    case workspaceId = "workspace_id"
    case returnUrl = "return_url"
  }
}

public struct PortalApiRequest: Codable, Sendable, Equatable {
  public var workspaceId: String?
  public var returnUrl: String?
  public init(workspaceId: String? = nil, returnUrl: String? = nil) {
    self.workspaceId = workspaceId
    self.returnUrl = returnUrl
  }
  enum CodingKeys: String, CodingKey {
    case workspaceId = "workspace_id"
    case returnUrl = "return_url"
  }
}

public struct PortalResponse: Codable, Sendable, Equatable {
  public var url: String
  public init(url: String) {
    self.url = url
  }
  enum CodingKeys: String, CodingKey {
    case url = "url"
  }
}

public struct BillingWorkspace: Codable, Sendable, Equatable {
  public var id: String
  public var appId: String
  public var name: String
  public var ownerUserId: String
  public var status: BillingStatus
  public var seatLimit: Int
  public var extraSeats: Int
  public var createdAt: String
  public var updatedAt: String
  public init(
    id: String, appId: String, name: String, ownerUserId: String, status: BillingStatus,
    seatLimit: Int, extraSeats: Int, createdAt: String, updatedAt: String
  ) {
    self.id = id
    self.appId = appId
    self.name = name
    self.ownerUserId = ownerUserId
    self.status = status
    self.seatLimit = seatLimit
    self.extraSeats = extraSeats
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
  enum CodingKeys: String, CodingKey {
    case id = "id"
    case appId = "app_id"
    case name = "name"
    case ownerUserId = "owner_user_id"
    case status = "status"
    case seatLimit = "seat_limit"
    case extraSeats = "extra_seats"
    case createdAt = "created_at"
    case updatedAt = "updated_at"
  }
}

public struct WorkspaceListResponse: Codable, Sendable, Equatable {
  public var workspaces: [BillingWorkspaceSummary]
  public init(workspaces: [BillingWorkspaceSummary]) {
    self.workspaces = workspaces
  }
  enum CodingKeys: String, CodingKey {
    case workspaces = "workspaces"
  }
}

public struct WorkspaceResponse: Codable, Sendable, Equatable {
  public var workspace: BillingWorkspace
  public var role: WorkspaceRole
  public init(workspace: BillingWorkspace, role: WorkspaceRole) {
    self.workspace = workspace
    self.role = role
  }
  enum CodingKeys: String, CodingKey {
    case workspace = "workspace"
    case role = "role"
  }
}

public struct WorkspaceMember: Codable, Sendable, Equatable {
  public var id: String
  public var workspaceId: String
  public var userId: String
  public var email: String
  public var role: WorkspaceRole
  public var status: BillingStatus
  public var createdAt: String
  public init(
    id: String, workspaceId: String, userId: String, email: String, role: WorkspaceRole,
    status: BillingStatus, createdAt: String
  ) {
    self.id = id
    self.workspaceId = workspaceId
    self.userId = userId
    self.email = email
    self.role = role
    self.status = status
    self.createdAt = createdAt
  }
  enum CodingKeys: String, CodingKey {
    case id = "id"
    case workspaceId = "workspace_id"
    case userId = "user_id"
    case email = "email"
    case role = "role"
    case status = "status"
    case createdAt = "created_at"
  }
}

public struct WorkspaceMembersResponse: Codable, Sendable, Equatable {
  public var members: [WorkspaceMember]
  public init(members: [WorkspaceMember]) {
    self.members = members
  }
  enum CodingKeys: String, CodingKey {
    case members = "members"
  }
}

public struct AddSeatsRequest: Codable, Sendable, Equatable {
  public var additionalSeats: Int
  public init(additionalSeats: Int) {
    self.additionalSeats = additionalSeats
  }
  enum CodingKeys: String, CodingKey {
    case additionalSeats = "additional_seats"
  }
}

public struct AddSeatsApiRequest: Codable, Sendable, Equatable {
  public var additionalSeats: Int
  public init(additionalSeats: Int) {
    self.additionalSeats = additionalSeats
  }
  enum CodingKeys: String, CodingKey {
    case additionalSeats = "additional_seats"
  }
}

public struct AddSeatsResponse: Codable, Sendable, Equatable {
  public var workspace: BillingWorkspace
  public init(workspace: BillingWorkspace) {
    self.workspace = workspace
  }
  enum CodingKeys: String, CodingKey {
    case workspace = "workspace"
  }
}

public struct WorkspaceInvite: Codable, Sendable, Equatable {
  public var id: String
  public var workspaceId: String
  public var email: String
  public var status: BillingStatus
  public var expiresAt: String
  public var invitedByUserId: String
  public var createdAt: String
  public var emailDeliveryStatus: String?
  public init(
    id: String, workspaceId: String, email: String, status: BillingStatus, expiresAt: String,
    invitedByUserId: String, createdAt: String, emailDeliveryStatus: String? = nil
  ) {
    self.id = id
    self.workspaceId = workspaceId
    self.email = email
    self.status = status
    self.expiresAt = expiresAt
    self.invitedByUserId = invitedByUserId
    self.createdAt = createdAt
    self.emailDeliveryStatus = emailDeliveryStatus
  }
  enum CodingKeys: String, CodingKey {
    case id = "id"
    case workspaceId = "workspace_id"
    case email = "email"
    case status = "status"
    case expiresAt = "expires_at"
    case invitedByUserId = "invited_by_user_id"
    case createdAt = "created_at"
    case emailDeliveryStatus = "email_delivery_status"
  }
}

public struct WorkspaceInviteWithLink: Codable, Sendable, Equatable {
  public var id: String
  public var workspaceId: String
  public var email: String
  public var status: BillingStatus
  public var expiresAt: String
  public var invitedByUserId: String
  public var createdAt: String
  public var emailDeliveryStatus: String?
  public var acceptUrl: String
  public init(
    id: String, workspaceId: String, email: String, status: BillingStatus, expiresAt: String,
    invitedByUserId: String, createdAt: String, emailDeliveryStatus: String? = nil,
    acceptUrl: String
  ) {
    self.id = id
    self.workspaceId = workspaceId
    self.email = email
    self.status = status
    self.expiresAt = expiresAt
    self.invitedByUserId = invitedByUserId
    self.createdAt = createdAt
    self.emailDeliveryStatus = emailDeliveryStatus
    self.acceptUrl = acceptUrl
  }
  enum CodingKeys: String, CodingKey {
    case id = "id"
    case workspaceId = "workspace_id"
    case email = "email"
    case status = "status"
    case expiresAt = "expires_at"
    case invitedByUserId = "invited_by_user_id"
    case createdAt = "created_at"
    case emailDeliveryStatus = "email_delivery_status"
    case acceptUrl = "accept_url"
  }
}

public struct WorkspaceInvitesResponse: Codable, Sendable, Equatable {
  public var invites: [WorkspaceInvite]
  public init(invites: [WorkspaceInvite]) {
    self.invites = invites
  }
  enum CodingKeys: String, CodingKey {
    case invites = "invites"
  }
}

public struct CreateInvitesRequest: Codable, Sendable, Equatable {
  public var emails: [String]
  public var expiresInDays: Int?
  public init(emails: [String], expiresInDays: Int? = nil) {
    self.emails = emails
    self.expiresInDays = expiresInDays
  }
  enum CodingKeys: String, CodingKey {
    case emails = "emails"
    case expiresInDays = "expires_in_days"
  }
}

public struct CreateInvitesApiRequest: Codable, Sendable, Equatable {
  public var emails: [String]
  public var expiresInDays: Int?
  public init(emails: [String], expiresInDays: Int? = nil) {
    self.emails = emails
    self.expiresInDays = expiresInDays
  }
  enum CodingKeys: String, CodingKey {
    case emails = "emails"
    case expiresInDays = "expires_in_days"
  }
}

public struct CreateInvitesResponse: Codable, Sendable, Equatable {
  public var invites: [WorkspaceInviteWithLink]
  public init(invites: [WorkspaceInviteWithLink]) {
    self.invites = invites
  }
  enum CodingKeys: String, CodingKey {
    case invites = "invites"
  }
}

public struct ResendInviteResponse: Codable, Sendable, Equatable {
  public var invite: WorkspaceInviteWithLink
  public init(invite: WorkspaceInviteWithLink) {
    self.invite = invite
  }
  enum CodingKeys: String, CodingKey {
    case invite = "invite"
  }
}

public struct AcceptInviteRequest: Codable, Sendable, Equatable {
  public var token: String
  public init(token: String) {
    self.token = token
  }
  enum CodingKeys: String, CodingKey {
    case token = "token"
  }
}

public struct AcceptInviteResponse: Codable, Sendable, Equatable {
  public var workspace: BillingWorkspaceSummary
  public init(workspace: BillingWorkspaceSummary) {
    self.workspace = workspace
  }
  enum CodingKeys: String, CodingKey {
    case workspace = "workspace"
  }
}

public struct StatusResponse: Codable, Sendable, Equatable {
  public var status: String
  public init(status: String) {
    self.status = status
  }
  enum CodingKeys: String, CodingKey {
    case status = "status"
  }
}
