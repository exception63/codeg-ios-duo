import SwiftUI
import Observation

/// Top-level navigation + selection state shared by both shells. Owns the
/// server store, the per-tab navigation stacks, and the app-wide activity poller
/// that feeds the Activity tab and its badge.
///
/// Both shells read the **same** state: `selectedTab` + `paths[tab]`. Compact
/// renders each stack in its tab; regular shows the selected tab's list in the
/// content column and its stack in the detail column (root = first route). So
/// folding / unfolding an iPhone Duo (compact ⇄ regular) lands on the same
/// screen instead of each shell restoring its own, stale selection. The screen
/// models behind those routes (session detail, folder + terminal) are cached
/// here too, so a shell swap re-hosts them instead of rebuilding them.
@MainActor
@Observable
final class AppModel {
    let serverStore: ServerStore

    /// App-wide pulse of the selected server (running sessions, recents,
    /// folders) — the poll-based stand-in for the future persistent event hub.
    let activity = ActivityModel()

    // MARK: - Server selection

    private static let lastServerKey = "codeg.lastSelectedServerID"

    var selectedServerID: ServerProfile.ID? {
        didSet {
            guard oldValue != selectedServerID else { return }
            resetServerScopedState()
            UserDefaults.standard.set(selectedServerID?.uuidString, forKey: Self.lastServerKey)
        }
    }

    // MARK: - Navigation (both shells)

    // Typed route stacks (not opaque `NavigationPath`s) so navigation stays
    // inspectable — `open(_:)` can no-op when the destination is already on
    // top (e.g. tapping the running bar inside that very conversation).
    var selectedTab: AppTab = .chats
    var paths: [AppTab: [Route]] = [:] {
        didSet { pruneScreenCaches() }
    }

    /// Pushes within the regular content column. Nothing pushes here anymore
    /// (folders open in the detail column), but the column keeps a *bound*
    /// stack: swapping a bound `NavigationStack` for an unbound one in place
    /// trips a SwiftUI assertion.
    var contentPath: [Route] = []

    /// The Settings tab's stack is value-driven over `SettingsLeaf` (its own
    /// typed path, separate from the `Route` stacks above) so settings sub-screens
    /// stay out of the global deep-link routing while remaining programmatically
    /// pushable (e.g. `codeg://settings/<slug>`).
    var settingsPath: [SettingsLeaf] = []

    /// Width class mirrored in by RootView so `open(_:)` can decide between a
    /// push (compact) and a column selection (regular).
    var isCompact = false

    /// The conversation shown at the root of the Chats stack — the regular
    /// shell's list highlight. Setting it opens that conversation.
    var selectedConversationID: Int? {
        get {
            if case .conversation(let id) = paths[.chats]?.first { return id }
            return nil
        }
        set {
            if let newValue { open(.conversation(newValue)) }
        }
    }

    // MARK: - Presentation

    var serversSheetPresented = false
    var settingsSheetPresented = false

    init(serverStore: ServerStore? = nil) {
        let store = serverStore ?? ServerStore()
        self.serverStore = store
        // Restore the last-used server, falling back to the first. With servers
        // demoted out of the tab bar there is no "pick a server" landing screen
        // anymore — the app must come up already pointed at a server.
        let persisted = UserDefaults.standard.string(forKey: Self.lastServerKey).flatMap(UUID.init)
        self.selectedServerID = store.servers.first { $0.id == persisted }?.id ?? store.servers.first?.id
    }

    var selectedServer: ServerProfile? {
        guard let id = selectedServerID else { return nil }
        return serverStore.servers.first { $0.id == id }
    }

    /// HTTP client for the selected server, if its token resolves.
    func selectedClient() -> CodegClient? {
        guard let server = selectedServer else { return nil }
        return serverStore.client(for: server)
    }

    // MARK: - Routing

    /// Open a destination from any entry point. Compact pushes onto the current
    /// tab's stack; regular replaces the detail column's stack (a session opened
    /// from a folder's detail is pushed instead, so Back returns to the folder).
    func open(_ route: Route) {
        if isCompact {
            push(route, on: selectedTab)
            return
        }
        switch route {
        case .conversation, .newSession:
            if selectedTab == .settings { selectedTab = .chats }
            let stack = paths[selectedTab, default: []]
            if case .project = stack.first {
                push(route, on: selectedTab)
            } else if stack != [route] {
                paths[selectedTab] = [route]
            }
        case .project:
            selectedTab = .projects
            if paths[.projects] != [route] { paths[.projects] = [route] }
        }
    }

    private func push(_ route: Route, on tab: AppTab) {
        var path = paths[tab, default: []]
        // Already there (e.g. the running bar tapped inside that conversation).
        guard path.last != route else { return }
        path.append(route)
        paths[tab] = path
    }

    /// Called by RootView when the width class flips (iPhone Duo fold/unfold,
    /// iPad multitasking). Navigation itself is shared, so only Settings moves:
    /// a tab on compact, a sheet on regular.
    func adapt(toCompact compact: Bool) {
        isCompact = compact
        if compact {
            if settingsSheetPresented {
                settingsSheetPresented = false
                selectedTab = .settings
            }
        } else if selectedTab == .settings {
            selectedTab = .chats
            settingsSheetPresented = true
        }
    }

    /// Handle a `codeg://` URL. `codeg://tab/<name>` switches tabs;
    /// `codeg://conversation/<id>` / `codeg://project/<id>` land on the owning
    /// tab with a fresh, predictable stack (so Back always returns to that
    /// tab's root, not to wherever the user happened to be).
    func handle(url: URL) {
        guard Route.isAppURL(url) else { return }
        if url.host?.lowercased() == "tab",
           url.pathComponents.count > 1,
           let tab = AppTab(rawValue: url.pathComponents[1].lowercased()) {
            select(tab: tab)
            return
        }
        // `codeg://settings/<slug>` jumps straight to a Settings sub-screen (used
        // for screenshot verification, and harmless in production). The leaf is
        // honored on BOTH shells: compact pushes it onto the Settings tab; regular
        // presents the Settings sheet already pushed to it (the sheet binds the
        // same `settingsPath`).
        if url.host?.lowercased() == "settings",
           url.pathComponents.count > 1,
           let leaf = SettingsLeaf(slug: url.pathComponents[1]) {
            settingsPath = [leaf]
            if isCompact {
                selectedTab = .settings
            } else {
                settingsSheetPresented = true
            }
            return
        }
        guard let route = Route.from(url: url) else { return }
        let owner: AppTab = if case .project = route { .projects } else { .chats }
        selectedTab = owner
        paths[owner] = [route]
    }

    func select(tab: AppTab) {
        if !isCompact, tab == .settings {
            // Open Settings at its root (not whatever leaf a prior deep link left).
            settingsPath = []
            settingsSheetPresented = true
            return
        }
        selectedTab = tab
    }

    // MARK: - Screen caches

    // Session-detail and folder screen models, keyed per server endpoint. They
    // outlive their views so a fold/unfold (which swaps the whole shell) re-hosts
    // the same model — live stream, draft, scroll position, terminal and all —
    // and are dropped once their route leaves every stack.
    @ObservationIgnored private var sessionModels: [String: SessionDetailViewModel] = [:]
    @ObservationIgnored private var folderStates: [String: FolderScreenState] = [:]

    private func cacheKey(_ route: Route, client: CodegClient) -> String {
        let endpoint = "\(selectedServerID?.uuidString ?? "-")|\(client.token.hashValue)"
        switch route {
        case .conversation(let id): return "\(endpoint)|conversation-\(id)"
        case .newSession(let request): return "\(endpoint)|new-\(request.id)"
        case .project(let id): return "\(endpoint)|folder-\(id)"
        }
    }

    func sessionModel(for route: Route, client: CodegClient) -> SessionDetailViewModel {
        let key = cacheKey(route, client: client)
        if let model = sessionModels[key] { return model }
        let model: SessionDetailViewModel = switch route {
        case .newSession(let request): SessionDetailViewModel(client: client, newSession: request)
        case .conversation(let id): SessionDetailViewModel(client: client, conversationID: id)
        case .project(let id): SessionDetailViewModel(client: client, conversationID: id)  // unreachable
        }
        sessionModels[key] = model
        return model
    }

    func folderState(for folder: FolderDetail, client: CodegClient) -> FolderScreenState {
        let key = cacheKey(.project(folder.id), client: client)
        if let state = folderStates[key] { return state }
        let state = FolderScreenState(client: client, folder: folder)
        folderStates[key] = state
        return state
    }

    /// Drop cached screens whose route is no longer on any stack (the user went
    /// Back, or opened something else in the detail column). Dropping a folder
    /// state releases its terminal, which kills the PTY.
    private func pruneScreenCaches() {
        let live = Set(paths.values.joined().map { route -> String in
            switch route {
            case .conversation(let id): return "conversation-\(id)"
            case .newSession(let request): return "new-\(request.id)"
            case .project(let id): return "folder-\(id)"
            }
        })
        let keep: (String) -> Bool = { key in live.contains(String(key.split(separator: "|").last ?? "")) }
        sessionModels = sessionModels.filter { keep($0.key) }
        folderStates = folderStates.filter { keep($0.key) }
    }

    // MARK: - Server-scoped resets

    /// Conversation, folder, and route identities are all endpoint-local.
    /// Dropped when the selected server changes…
    private func resetServerScopedState() {
        paths = [:]
        settingsPath = []
        contentPath = []
        sessionModels = [:]
        folderStates = [:]
        activity.reset()
    }

    /// …and when the selected server is edited in place (same UUID, new
    /// URL/token) — the old endpoint's IDs may not exist on the new one.
    func selectedServerEndpointChanged() {
        resetServerScopedState()
    }
}
