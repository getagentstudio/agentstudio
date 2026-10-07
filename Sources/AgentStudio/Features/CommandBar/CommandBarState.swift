import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioSharedComponents
import AgentStudioWorktreeOperations
import Foundation
import SwiftUI
import os.log

private let stateLogger = Logger(subsystem: "com.agentstudio", category: "CommandBarState")

// MARK: - CommandBarState

/// Observable state for the command bar.
/// Manages visibility, search input with prefix parsing, navigation stack, and selection.
/// Always accessed on the main thread (SwiftUI views + AppKit panel controller).
@Observable
package final class CommandBarState {
    private let defaults: UserDefaults

    package init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    enum OpenMode: Equatable {
        case prefix(String)
        case defaultScope(CommandBarScope)
    }

    // MARK: - Visibility

    var isVisible: Bool = false

    // MARK: - Search Input

    /// Full raw text including any visible prefix characters (e.g., "> close", "$ main").
    package var rawInput: String = "" {
        didSet {
            if rawInput != oldValue {
                shouldSelectRestoredRootQuery = false
            }
            if let normalizedPrefix = Self.normalizedLeadingPrefix(for: rawInput, previousInput: oldValue),
                rawInput != normalizedPrefix
            {
                rawInput = normalizedPrefix
                return
            }
            if isNested {
                selectedIndex = 0
            }
        }
    }
    private(set) var lastRootQuery: String = ""
    private(set) var shouldSelectRestoredRootQuery = false

    // MARK: - Navigation

    /// Stack of nested levels. Empty = at root level.
    var navigationStack: [CommandBarLevel] = [] {
        didSet { levelVisitRevision += 1 }
    }

    /// Changes whenever the navigation stack does, so work deferred on one visit to a level
    /// can tell that the user has since left it, even for a revisit of the same level.
    private(set) var levelVisitRevision: Int = 0

    /// Root scope that remains stable while navigating nested levels.
    private(set) var pinnedScope: CommandBarScope = .everything
    private(set) var defaultRootScope: CommandBarScope = .everything
    private(set) var rootSessionGeneration: Int = 0

    // MARK: - Selection

    /// Currently highlighted row index within filtered results.
    var selectedIndex: Int = 0
    var appliedSearchResult: CommandBarAppliedSearchResult?

    // MARK: - Recents

    /// Persisted recent item IDs, ordered most-recent-first.
    var recentItemIds: [String] = []
    /// Persisted typed command history, ordered most-recent-first.
    private(set) var recentCommands: [AppCommand] = []

    // MARK: - Worktree Creation

    /// Fork eligibility answers for source worktrees chosen in this session; a missing
    /// entry means the query is still pending.
    private(set) var forkEligibilityBySourceWorktreeId: [UUID: WorktreeForkEligibility] = [:]
    private(set) var defaultStartPointByRepositoryId: [UUID: WorktreeDefaultStartPoint] = [:]
    private(set) var defaultStartPointQueryFailures: Set<UUID> = []
    private(set) var branchNamesByRepositoryId: [UUID: [String]] = [:]
    private(set) var branchListingQueryFailures: Set<UUID> = []

    // MARK: - Computed — Prefix Parsing

    /// Active prefix token: "> ", "$ ", "# ", or nil.
    var activePrefix: String? {
        guard navigationStack.isEmpty else { return nil }
        guard rawInput.count >= 2 else { return nil }
        let twoChars = String(rawInput.prefix(2))
        return ["> ", "$ ", "# "].contains(twoChars) ? twoChars : nil
    }

    /// Search query text after stripping the active prefix token.
    var searchQuery: String {
        guard let prefix = activePrefix else { return rawInput }
        return String(rawInput.dropFirst(prefix.count))
    }

    var normalizedRootQuery: String {
        searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var hasMeaningfulRootQuery: Bool {
        !normalizedRootQuery.isEmpty
    }

    /// Current scope derived from prefix.
    var activeScope: CommandBarScope {
        switch activePrefix {
        case "> ": return .commands
        case "$ ": return .panes
        case "# ": return .repos
        default: return defaultRootScope
        }
    }

    var currentScope: CommandBarScope {
        isNested ? pinnedScope : activeScope
    }

    var hasPrefixInText: Bool {
        activePrefix != nil && !rawInput.isEmpty
    }

    /// Whether we're in a nested navigation level.
    var isNested: Bool { !navigationStack.isEmpty }

    /// Current level for display (last in stack, or nil for root).
    var currentLevel: CommandBarLevel? { navigationStack.last }

    var rootScopeLabel: String {
        switch currentScope {
        case .everything: return "Home"
        case .quickOpen: return "Quick Open"
        case .commands: return "Commands"
        case .panes: return "Panes"
        case .repos: return "Repositories"
        case .inbox: return "Inbox"
        }
    }

    var breadcrumbLabels: [String] {
        breadcrumbItems.map(\.accessibilityLabel)
    }

    var breadcrumbItems: [CommandBarBreadcrumbItem] {
        [
            CommandBarBreadcrumbItem(
                label: currentScope == .everything ? "" : rootScopeLabel,
                accessibilityLabel: rootScopeLabel,
                icon: currentScope == .everything ? .home : nil
            )
        ]
            + navigationStack.map { level in
                let accessibilityLabel = typedBreadcrumbLabel(for: level)
                return CommandBarBreadcrumbItem(
                    label: level.breadcrumbIcon == nil ? accessibilityLabel : level.title,
                    accessibilityLabel: accessibilityLabel,
                    icon: level.breadcrumbIcon
                )
            }
    }

    var breadcrumbLabel: String {
        breadcrumbLabels.joined(separator: " › ")
    }

    private func typedBreadcrumbLabel(for level: CommandBarLevel) -> String {
        guard let scopeLabel = level.scopeLabel, scopeLabel != level.title else {
            return level.title
        }
        return "\(scopeLabel) \(level.title)"
    }

    // MARK: - Placeholder

    /// Placeholder text for the search field, varies by scope.
    var placeholder: String {
        if let textEntry = currentLevel?.textEntry {
            return textEntry.placeholder
        }
        if isNested {
            return "Filter..."
        }
        switch activeScope {
        case .everything: return "Search or jump to..."
        case .quickOpen: return "Open a terminal..."
        case .commands: return "Run a command..."
        case .panes: return "Search panes..."
        case .repos: return "Open repo or worktree..."
        case .inbox: return "Search inbox..."
        }
    }

    /// Icon name for the scope indicator left of the search field.
    var scopeIcon: String {
        if isNested { return "magnifyingglass" }
        switch activeScope {
        case .everything: return "magnifyingglass"
        case .quickOpen: return "terminal"
        case .commands: return "chevron.right.2"
        case .panes: return "terminal"
        case .repos: return "octicon-repo"
        case .inbox: return "bell"
        }
    }

    var scopeIconIsOcticon: Bool {
        scopeIcon.hasPrefix("octicon-")
    }

    // MARK: - Actions

    /// Show the command bar rooted at a specific scope.
    func show(defaultScope: CommandBarScope = .everything) {
        show(mode: .defaultScope(defaultScope))
    }

    /// Show the command bar with a prefix pre-filled.
    func show(prefix: String) {
        show(mode: .prefix(prefix))
    }

    private func show(mode: OpenMode) {
        rootSessionGeneration += 1

        let prefix: String?
        switch mode {
        case .prefix(let requestedPrefix):
            prefix = requestedPrefix
            defaultRootScope = .everything
        case .defaultScope(let scope):
            prefix = nil
            defaultRootScope = scope
        }

        if let prefix, !prefix.isEmpty, [">", "$", "#"].contains(prefix) {
            rawInput = prefix + " "
        } else {
            rawInput = prefix ?? lastRootQuery
        }
        shouldSelectRestoredRootQuery = prefix == nil && !lastRootQuery.isEmpty
        pinnedScope = activeScope
        navigationStack = []
        forkEligibilityBySourceWorktreeId = [:]
        defaultStartPointByRepositoryId = [:]
        defaultStartPointQueryFailures = []
        branchNamesByRepositoryId = [:]
        branchListingQueryFailures = []
        selectedIndex = 0
        isVisible = true
        stateLogger.debug("Command bar shown with prefix: \(prefix ?? "(none)")")
    }

    /// Dismiss the command bar entirely.
    func dismiss() {
        if !isNested && activePrefix == nil {
            lastRootQuery = rawInput
        }
        rootSessionGeneration += 1
        isVisible = false
        rawInput = ""
        pinnedScope = .everything
        defaultRootScope = .everything
        navigationStack = []
        forkEligibilityBySourceWorktreeId = [:]
        defaultStartPointByRepositoryId = [:]
        defaultStartPointQueryFailures = []
        branchNamesByRepositoryId = [:]
        branchListingQueryFailures = []
        selectedIndex = 0
        stateLogger.debug("Command bar dismissed")
    }

    /// Switch prefix in-place (when already open, pressing a different shortcut).
    func switchPrefix(_ prefix: String) {
        rootSessionGeneration += 1
        navigationStack = []
        forkEligibilityBySourceWorktreeId = [:]
        defaultStartPointByRepositoryId = [:]
        defaultStartPointQueryFailures = []
        branchNamesByRepositoryId = [:]
        branchListingQueryFailures = []
        defaultRootScope = .everything
        rawInput = prefix.isEmpty ? "" : prefix + " "
        shouldSelectRestoredRootQuery = false
        pinnedScope = activeScope
        selectedIndex = 0
    }

    @MainActor
    static func forOpen(
        windowLifecycle: WindowLifecycleAtom,
        managementLayer: ManagementLayerAtom,
        uiState: WorkspaceSidebarState
    ) -> CommandBarState {
        let state = CommandBarState()
        let owner = KeyboardOwner.current(
            windowLifecycle: windowLifecycle,
            managementLayer: managementLayer,
            uiState: uiState
        )
        state.show(defaultScope: defaultScope(for: owner))
        return state
    }

    /// Root-scope mapping is shared by the production AppDelegate open path and
    /// the test fixture entry point above so new owner→scope rows stay in sync.
    package static func defaultScope(for owner: KeyboardOwner) -> CommandBarScope {
        owner == .sidebar(.inbox) ? .inbox : .everything
    }

    func recordForkEligibility(_ eligibility: WorktreeForkEligibility, forSourceWorktreeId sourceWorktreeId: UUID) {
        forkEligibilityBySourceWorktreeId[sourceWorktreeId] = eligibility
    }

    func recordDefaultStartPoint(_ startPoint: WorktreeDefaultStartPoint, forRepositoryId repositoryId: UUID) {
        defaultStartPointByRepositoryId[repositoryId] = startPoint
        defaultStartPointQueryFailures.remove(repositoryId)
    }

    func recordDefaultStartPointQueryFailure(forRepositoryId repositoryId: UUID) {
        defaultStartPointQueryFailures.insert(repositoryId)
    }

    func recordBranchNames(_ names: [String], forRepositoryId repositoryId: UUID) {
        branchNamesByRepositoryId[repositoryId] = names
        branchListingQueryFailures.remove(repositoryId)
    }

    func recordBranchListingQueryFailure(forRepositoryId repositoryId: UUID) {
        branchListingQueryFailures.insert(repositoryId)
    }

    func invalidateBranchListing(forRepositoryId repositoryId: UUID) {
        branchNamesByRepositoryId.removeValue(forKey: repositoryId)
        branchListingQueryFailures.remove(repositoryId)
    }

    func replaceLevel(_ level: CommandBarLevel) {
        guard let index = navigationStack.lastIndex(where: { $0.id == level.id }) else { return }
        navigationStack[index] = level
    }

    /// Push a nested level onto the navigation stack.
    func pushLevel(_ level: CommandBarLevel) {
        navigationStack.append(level)
        rawInput = ""
        selectedIndex = 0
    }

    /// Pop the current nested level while preserving its parent.
    func popLevel() {
        guard !navigationStack.isEmpty else { return }
        navigationStack.removeLast()
        rawInput = ""
        selectedIndex = 0
    }

    /// Navigate directly to an ancestor represented by a breadcrumb index.
    func navigateToBreadcrumb(at index: Int) {
        guard index >= 0, index < breadcrumbLabels.count - 1 else { return }
        navigationStack = Array(navigationStack.prefix(index))
        rawInput = ""
        selectedIndex = 0
    }

    /// Pop back to root level.
    func popToRoot() {
        navigationStack = []
        rawInput = ""
        selectedIndex = 0
    }

    /// Move selection up by one row.
    func moveSelectionUp(totalItems: Int) {
        guard totalItems > 0 else { return }
        selectedIndex = selectedIndex > 0 ? selectedIndex - 1 : totalItems - 1
    }

    /// Move selection down by one row.
    func moveSelectionDown(totalItems: Int) {
        guard totalItems > 0 else { return }
        selectedIndex = selectedIndex < totalItems - 1 ? selectedIndex + 1 : 0
    }

    /// Record an item as recently used.
    func recordRecent(itemId: String) {
        recentItemIds.removeAll { $0 == itemId }
        recentItemIds.insert(itemId, at: 0)
        if recentItemIds.count > AppPolicies.CommandBar.maximumHistoryCount {
            recentItemIds = Array(recentItemIds.prefix(AppPolicies.CommandBar.maximumHistoryCount))
        }
        persistRecents()
    }

    func recordRecentCommand(_ command: AppCommand) {
        recentCommands.removeAll { $0 == command }
        recentCommands.insert(command, at: 0)
        if recentCommands.count > AppPolicies.CommandBar.maximumHistoryCount {
            recentCommands = Array(recentCommands.prefix(AppPolicies.CommandBar.maximumHistoryCount))
        }
        persistRecentCommands()
    }

    // MARK: - Persistence

    private static let recentsKey = "CommandBarRecentItemIds"
    private static let recentCommandsKey = "CommandBarRecentCommands"

    private static func normalizedLeadingPrefix(for input: String, previousInput: String) -> String? {
        guard previousInput.isEmpty else { return nil }
        guard [">", "$", "#"].contains(input) else { return nil }
        return input + " "
    }

    func loadRecents() {
        recentItemIds = defaults.stringArray(forKey: Self.recentsKey) ?? []
        let storedCommandValues = defaults.stringArray(forKey: Self.recentCommandsKey) ?? []
        var seenCommands: Set<AppCommand> = []
        recentCommands =
            storedCommandValues
            .compactMap(AppCommand.init(rawValue:))
            .filter { seenCommands.insert($0).inserted }
            .prefix(AppPolicies.CommandBar.maximumHistoryCount)
            .map(\.self)
    }

    private func persistRecents() {
        defaults.set(recentItemIds, forKey: Self.recentsKey)
    }

    private func persistRecentCommands() {
        defaults.set(recentCommands.map(\.rawValue), forKey: Self.recentCommandsKey)
    }
}
