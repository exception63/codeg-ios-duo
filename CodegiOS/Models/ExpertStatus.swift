import Foundation

/// Per-agent link state of a built-in expert (`experts_get_install_status` /
/// `experts_link_to_agent`). `ExpertListItem` / `ExpertMetadata` already exist in
/// `ComposeInserts.swift` and are reused for the catalog list.
///
/// NOTE: the server already emits these fields in camelCase (`expertId`,
/// `agentType`, `linkPath`, …), and the `.convertFromSnakeCase` decoder leaves
/// already-camelCase keys untouched, so plain camelCase Swift fields match.

enum ExpertLinkState: String, Decodable, Hashable, Sendable {
    case notLinked = "not_linked"
    case linkedToCodeg = "linked_to_codeg"
    case linkedElsewhere = "linked_elsewhere"
    case blockedByRealDirectory = "blocked_by_real_directory"
    case broken

    /// Whether the expert is currently linked to this agent (toggle "on" state).
    var isLinked: Bool {
        switch self {
        case .linkedToCodeg: true
        case .notLinked, .linkedElsewhere, .blockedByRealDirectory, .broken: false
        }
    }
}

struct ExpertInstallStatus: Decodable, Hashable, Sendable {
    let expertId: String
    let agentType: AgentType
    let state: ExpertLinkState
    let linkPath: String
    let targetPath: String?
    let expectedTargetPath: String
    let copyMode: Bool
}

/// One op's outcome from `experts_apply_links` (Rust `LinkOpResult`). A failed op
/// doesn't stop the rest of the batch; `status` is present on a successful enable.
struct ExpertLinkOpResult: Decodable, Sendable {
    let expertId: String
    let agentType: AgentType
    let ok: Bool
    let status: ExpertInstallStatus?
    let error: String?
    let code: String?
}
