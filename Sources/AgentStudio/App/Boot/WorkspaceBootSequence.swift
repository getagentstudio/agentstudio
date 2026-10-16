import Foundation

enum WorkspaceBootStep: String, CaseIterable, Sendable {
    case prepareDatabases
    case loadCanonicalStore
    case loadSidebarMemory
    case loadCacheStore
    case loadWorkspaceSettings
    case establishRuntimeBus
    case startFilesystemActor
    case startGitProjector
    case startForgeActor
    case startCacheCoordinator
    case triggerInitialTopologySync
    case armPersistenceObservation
    case readyForReactiveSidebar

    var purpose: String {
        switch self {
        case .prepareDatabases:
            return "Prepare authoritative core and non-authoritative local storage before hydration."
        case .loadCanonicalStore:
            return "Strictly install durable composition before constructing its runtime hosts."
        case .loadSidebarMemory:
            return "Restore saved sidebar choices before constructing the split view and sidebar hosts."
        case .loadCacheStore:
            return "Hydrate rebuildable repo and sidebar cache after shell presentation."
        case .loadWorkspaceSettings:
            return "Hydrate independent workspace settings after shell presentation."
        case .establishRuntimeBus:
            return "Create the minimum runtime hosts required to present accepted composition."
        case .startFilesystemActor:
            return "Start filesystem discovery after the canonical workspace model exists."
        case .startGitProjector:
            return "Start git enrichment after filesystem discovery has a bus and scope."
        case .startForgeActor:
            return "Start forge enrichment after repo/worktree facts can be accumulated."
        case .startCacheCoordinator:
            return "Begin consuming runtime facts into canonical stores and rebuildable cache."
        case .triggerInitialTopologySync:
            return "Start the nonblocking repository/topology lane after shell presentation."
        case .armPersistenceObservation:
            return "Arm persistence observers after their independent stores finish hydration."
        case .readyForReactiveSidebar:
            return "Mark post-presentation secondary-state hydration as scheduled."
        }
    }
}

enum WorkspaceBootSequence {
    /// The minimum work allowed to delay workspace shell presentation.
    static let presentationPrerequisiteSteps: [WorkspaceBootStep] = [
        .prepareDatabases,
        .loadCanonicalStore,
        .loadSidebarMemory,
        .establishRuntimeBus,
    ]

    /// Independent work started only after the composition-backed shell is visible.
    static let postPresentationSteps: [WorkspaceBootStep] = [
        .loadCacheStore,
        .loadWorkspaceSettings,
        .startFilesystemActor,
        .startGitProjector,
        .startForgeActor,
        .startCacheCoordinator,
        .armPersistenceObservation,
        .triggerInitialTopologySync,
        .readyForReactiveSidebar,
    ]

    @MainActor
    static func runPresentationPrerequisites(_ perform: (WorkspaceBootStep) -> Void) {
        for step in presentationPrerequisiteSteps {
            perform(step)
        }
    }

    @MainActor
    static func runPresentationPrerequisitesAsync(
        _ perform: (WorkspaceBootStep) async -> Void
    ) async {
        for step in presentationPrerequisiteSteps {
            await perform(step)
        }
    }

    @MainActor
    static func runPostPresentationAsync(
        _ perform: (WorkspaceBootStep) async -> Void
    ) async {
        for step in postPresentationSteps {
            await perform(step)
        }
    }
}
