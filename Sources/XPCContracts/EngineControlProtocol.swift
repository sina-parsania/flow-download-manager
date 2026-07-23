// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Versioned, authenticated control interface exported by the engine agent over
/// XPC (`02-architecture.md` §10, `04-domain-and-data-contracts.md` §9).
///
/// Every method takes an explicit request identifier and replies with a typed
/// DTO or an `NSError` carrying a stable ``XPCErrorCode``. Reply blocks are
/// `@Sendable`: they may be invoked on an arbitrary XPC delivery queue, so
/// callers must not capture non-`Sendable` state.
///
/// The handshake MUST precede any other command; the service rejects commands
/// received before a successful handshake (`fail closed on unknown major version
/// or role`, `06-licensing-security-privacy.md` §4).
@objc(DMEngineControlProtocol)
public protocol EngineControlProtocol {
    /// Negotiate protocol version and exchange build/database metadata.
    /// Rejected with ``XPCErrorCode/unsupportedProtocolVersion`` when the client
    /// major version is unknown.
    func handshake(
        _ hello: ClientHello,
        reply: @escaping @Sendable (ServerHello?, NSError?) -> Void
    )

    /// Harmless health/status probe. Requires a prior successful handshake on the
    /// same connection. `requestID` is a UUID string used for idempotency and
    /// duplicate-detection (`04-domain-and-data-contracts.md` §9).
    func healthStatus(
        requestID: String,
        reply: @escaping @Sendable (EngineHealthSnapshot?, NSError?) -> Void
    )

    /// Persist a reviewed batch and acknowledge before the UI dismisses (FR-ING).
    func enqueueBatch(
        _ request: EnqueueBatchRequest,
        reply: @escaping @Sendable (EnqueueBatchResponse?, NSError?) -> Void
    )

    /// Library read model. Idempotent for a given requestID on one connection.
    func listJobs(
        requestID: String,
        reply: @escaping @Sendable (JobListSnapshot?, NSError?) -> Void
    )

    /// Pause / resume / cancel / retry with expected revision.
    func controlJob(
        _ request: JobCommandRequest,
        reply: @escaping @Sendable (JobCommandResponse?, NSError?) -> Void
    )

    /// Set absolute queue priority for a job (`priority DESC` ordering).
    func setJobPriority(
        _ request: SetJobPriorityRequest,
        reply: @escaping @Sendable (SetJobPriorityResponse?, NSError?) -> Void
    )

    /// Remove a terminal job from the library (DB row only; completed files kept).
    func deleteJob(
        _ request: DeleteJobRequest,
        reply: @escaping @Sendable (DeleteJobResponse?, NSError?) -> Void
    )

    /// Create or replace a credential profile (password → Keychain only).
    func upsertCredentialProfile(
        _ request: UpsertCredentialProfileRequest,
        reply: @escaping @Sendable (UpsertCredentialProfileResponse?, NSError?) -> Void
    )

    /// Create or replace a proxy profile (non-secret metadata in SQLite).
    func upsertProxyProfile(
        _ request: UpsertProxyProfileRequest,
        reply: @escaping @Sendable (UpsertProxyProfileResponse?, NSError?) -> Void
    )

    /// Create or replace a cookie jar profile (path only).
    func upsertCookieProfile(
        _ request: UpsertCookieProfileRequest,
        reply: @escaping @Sendable (UpsertCookieProfileResponse?, NSError?) -> Void
    )

    /// List credential, proxy, and cookie profiles for Settings.
    func listProfiles(
        requestID: String,
        reply: @escaping @Sendable (ListProfilesResponse?, NSError?) -> Void
    )

    /// Read the default download folder (path display only — never logs full URLs with query).
    func getDefaultDestination(
        requestID: String,
        reply: @escaping @Sendable (GetDefaultDestinationResponse?, NSError?) -> Void
    )

    /// Set or reset the default download folder (bookmark from the app, or nil to reset).
    func setDefaultDestination(
        _ request: SetDefaultDestinationRequest,
        reply: @escaping @Sendable (SetDefaultDestinationResponse?, NSError?) -> Void
    )

    /// Create or replace the global bandwidth calendar policy (FR-QUE).
    func upsertBandwidthPolicy(
        _ request: UpsertBandwidthPolicyRequest,
        reply: @escaping @Sendable (UpsertBandwidthPolicyResponse?, NSError?) -> Void
    )

    /// Fetch the global bandwidth policy, if configured.
    func getBandwidthPolicy(
        requestID: String,
        reply: @escaping @Sendable (GetBandwidthPolicyResponse?, NSError?) -> Void
    )

    /// List projects and tags (FR-ORG minimal).
    func listOrganization(
        requestID: String,
        reply: @escaping @Sendable (ListOrganizationResponse?, NSError?) -> Void
    )

    /// Create or replace a project.
    func upsertProject(
        _ request: UpsertProjectRequest,
        reply: @escaping @Sendable (UpsertProjectResponse?, NSError?) -> Void
    )

    /// Create or replace a tag.
    func upsertTag(
        _ request: UpsertTagRequest,
        reply: @escaping @Sendable (UpsertTagResponse?, NSError?) -> Void
    )

    /// Replace the tag set attached to a job.
    func setJobTags(
        _ request: SetJobTagsRequest,
        reply: @escaping @Sendable (SetJobTagsResponse?, NSError?) -> Void
    )

    /// Assign or clear the project for a job.
    func setJobProject(
        _ request: SetJobProjectRequest,
        reply: @escaping @Sendable (SetJobProjectResponse?, NSError?) -> Void
    )

    /// Change the category for a job (built-in stable key).
    func setJobCategory(
        _ request: SetJobCategoryRequest,
        reply: @escaping @Sendable (SetJobCategoryResponse?, NSError?) -> Void
    )

    /// Rename the job’s display / destination filename.
    func setJobFilename(
        _ request: SetJobFilenameRequest,
        reply: @escaping @Sendable (SetJobFilenameResponse?, NSError?) -> Void
    )

    /// Read an allowlisted agent boolean preference (e.g. `zipAutoExtractEnabled`).
    func getBoolSetting(
        _ request: GetBoolSettingRequest,
        reply: @escaping @Sendable (GetBoolSettingResponse?, NSError?) -> Void
    )

    /// Write an allowlisted agent boolean preference.
    func setBoolSetting(
        _ request: SetBoolSettingRequest,
        reply: @escaping @Sendable (SetBoolSettingResponse?, NSError?) -> Void
    )

    /// List user category classification rules (FR-CAT).
    func listCategoryRules(
        requestID: String,
        reply: @escaping @Sendable (ListCategoryRulesResponse?, NSError?) -> Void
    )

    /// Create or replace a category rule.
    func upsertCategoryRule(
        _ request: UpsertCategoryRuleRequest,
        reply: @escaping @Sendable (UpsertCategoryRuleResponse?, NSError?) -> Void
    )

    /// Recent event-journal rows (optional job filter, newest first).
    func listEvents(
        _ request: ListEventsRequest,
        reply: @escaping @Sendable (ListEventsResponse?, NSError?) -> Void
    )

    /// Delete event-journal rows for one job (inspector “Clean all”).
    func clearEvents(
        _ request: ClearEventsRequest,
        reply: @escaping @Sendable (ClearEventsResponse?, NSError?) -> Void
    )
}

/// Mach service name the agent's `NSXPCListener` binds and the app connects to.
/// Kept equal to the LaunchAgent label so launchd on-demand launch and XPC
/// addressing use one identity. This is an owner-supplied local development value
/// (see `Configuration/BundleIdentifiers.xcconfig`); the constant and the
/// `Contents/Library/LaunchAgents/*.plist` `Label`/`MachServices` keys must stay
/// in sync.
public enum EngineXPC {
    public static let machServiceName = "org.downloadmanager.local.DownloadEngineAgent"

    /// Bundle name (without `.xpc`) of the app-scoped XPC service used when
    /// launchd refuses the ad-hoc LaunchAgent (`Launch Constraint Violation` /
    /// `EX_CONFIG`). Must match `PRODUCT_NAME` of `DownloadEngineAgentXPC`.
    public static let bundledXPCServiceName = "DownloadEngineAgent"

    /// Hard cap on any single decoded XPC payload string/collection to bound
    /// interprocess DoS (`06-licensing-security-privacy.md` §4). Larger transfers
    /// use dedicated chunked/file-handle methods, never one giant message.
    public static let maxPayloadStringLength = 4096
    public static let maxCollectionCount = 4096
}
