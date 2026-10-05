enum ArchitectureAllowlists {
    static let broadObservationReadNames = Set([
        "paneSnapshot",
        "paneStateSnapshot",
        "snapshot",
        "values",
    ])
    static let observationCaptureAllowedPathSuffixes: [String] = []

    static let unboundedCollectionCallNames = Set([
        "grouped",
        "hash",
        "reduce",
        "sort",
        "sorted",
    ])
    static let mainActorCollectionWorkAllowedPathSuffixes: [String] = []

    static let performanceConstantNameFragments = [
        "cadence",
        "debounce",
        "interval",
        "threshold",
        "timeout",
    ]
    static let performanceConstantAllowedPathSuffixes: [String] = []
    static let performanceConstantPolicyHomes = [
        PolicyHomeAllowance(
            pathSuffix: "/Sources/AgentStudioCLIStore/CLIStorePolicy.swift",
            owner: "AgentStudioCLIStore policy home",
            reason:
                "CLI writer target links only GRDB and cannot import AgentStudioInfrastructure/AppPolicies; "
                + "this file is the target's single policy home"
        )
    ]
    static let concurrentIOAllowedPathSuffixes: [String] = []

    /// MainActor stream consumers the architecture prescribes as thin
    /// adapters: the stream is already contracted off MainActor, so each
    /// element is an admitted outcome, not a raw sample.
    static let mainActorPerElementAdapters = [
        NamedOwnerAllowance(
            pathSuffix: "/Sources/AgentStudio/App/Coordination/WorkspaceSurfaceCoordinator.swift",
            functionName: "startRuntimeReducerConsumers",
            owner: "WorkspaceSurfaceCoordinator runtime reducer consumers",
            reason:
                "Consume NotificationReducer's critical and batched outputs after off-main contraction; the "
                + "post-contraction MainActor adapter in pane_runtime_eventbus_design.md#admission-and-hop-shape"
        )
    ]

    /// Test files that own a blocking wait on purpose and document where the
    /// block lands: off the cooperative pool, or on a dispatch queue of their
    /// own such as the socket listener's handler queue. A full lint run fails
    /// when an owner's file is gone or no longer blocks at all.
    ///
    /// Blocking waits outside these owners are frozen per file by count in
    /// the debt ledger (`architecture-debt-ledger.tsv`), not listed here:
    /// this list is ownership, not debt.
    static let blockingTestWaitOwners = [
        BlockingWaitOwner(
            path: "Tests/AgentStudioTestHarness/HeldStep.swift",
            owner: "HeldStep.arriveBlocking",
            reason:
                "The harness-owned blocking arrival: parks only a dedicated thread, and refuses a blocking "
                + "arrival made from inside a task"
        ),
        BlockingWaitOwner(
            path: "Tests/AgentStudioAppIPCTests/AgentStudioAppIPCSocketTestSupport.swift",
            owner: "AppIPC synchronous client shims",
            reason:
                "AgentStudioIPCClient blocks in UnixSocketConnection.receive; the shims move that wait to a "
                + "libdispatch thread so the server's connection handler keeps its cooperative thread"
        ),
    ]

    /// Test files that own an elapsed-time budget on purpose, with who owns it
    /// and why. A full lint run fails when an owner's file is gone or no longer
    /// carries a budget. Budgets outside these owners are frozen per file by
    /// count in the debt ledger.
    static let elapsedTimeBudgetOwners = [
        ElapsedTimeBudgetOwner(
            path: "Tests/AgentStudioTests/Infrastructure/ProcessExecutorTests.swift",
            owner: "DefaultProcessExecutor",
            reason:
                "The executor's timeout is the behavior under test: these tests construct it with short "
                + "timeouts and assert the terminate-then-kill path"
        ),
        ElapsedTimeBudgetOwner(
            path: "Tests/AgentStudioTests/App/Panes/TabBarAdapterMaterializationTestSupport.swift",
            owner: "TabBar projection gate",
            reason: projectionGateOnPoolReason
        ),
        ElapsedTimeBudgetOwner(
            path: "Tests/AgentStudioTests/App/Windows/MainWindowControllerPresentationFactsTests.swift",
            owner: "presentation-facts TabBar projection gate",
            reason: projectionGateOnPoolReason
        ),
        ElapsedTimeBudgetOwner(
            path: "Tests/AgentStudioTests/Infrastructure/AtomLib/EagerDerivedAtomTestSupport.swift",
            owner: "EagerDerivedAtom projection gate",
            reason: projectionGateOnPoolReason
        ),
    ]

    /// Why the projection gates keep their deadlines for now. The fix is a
    /// production seam, not a test change, so it is recorded here rather than
    /// frozen as debt the tests could pay down.
    private static let projectionGateOnPoolReason =
        "The gate's hold runs on a cooperative-pool thread inside EagerDerivedAtom's detached projection task, "
        + "so removing the deadline turns latent pool starvation into deadlock on a three-core runner. The fix "
        + "is a production derivation-executor seam for EagerDerivedAtom; HeldStep does not fix it because "
        + "arriveBlocking must not run on the pool either"

    static let rawRepoCacheMembers = Set([
        "repoEnrichmentByRepoId",
        "worktreeEnrichmentByWorktreeId",
        "pullRequestFactsByBranch",
    ])

    static let repoCacheAllowedPathSuffixes = [
        "/Sources/AgentStudio/Core/State/MainActor/Atoms/RepoCacheAtom.swift",
        "/Sources/AgentStudio/Core/State/MainActor/Persistence/RepoCacheStore.swift",
        "/Sources/AgentStudio/Core/State/MainActor/Persistence/WorkspacePersistor+Payloads.swift",
        "/Sources/AgentStudio/Core/State/MainActor/Persistence/WorkspaceLocalRepository.swift",
        "/Sources/AgentStudio/Core/State/MainActor/Persistence/WorkspaceLocalRepository+Storage.swift",
        "/Sources/AgentStudio/Features/RepoExplorer/Models/RepoExplorerProjection.swift",
        "/Sources/AgentStudio/Features/InboxNotification/Views/InboxNotificationSidebarView.swift",
    ]

    static let stateActorGrandfatheredPathFragments = [
        "/Sources/AgentStudio/Features/Bridge/State/",
        "/Sources/AgentStudio/Features/InboxNotification/State/",
        "/Sources/AgentStudio/Features/EditorChooser/State/",
    ]

    static let concreteAppRuntimeOwnerNames = Set([
        "WorkspaceActionExecutor",
        "AppCommandDispatcher",
        "WorkspaceSurfaceCoordinator",
        "PaneRuntime",
        "RuntimeRegistry",
        "SurfaceManager",
        "TerminalRuntime",
        "WorkspaceCommandValidator",
    ])

    static let rawRuntimePayloadNames = Set([
        "PaneMetadata",
        "PaneRuntimeSnapshot",
        "RuntimeEnvelope",
        "TerminalRuntime",
        "ZmxBackend",
    ])

    static let atomAccessNames = Set([
        "AtomRegistry",
        "CoreAtoms",
        "CoreAtomScope",
    ])
}

/// A test file allowed to block, with who owns the blocking wait and why.
struct BlockingWaitOwner: Sendable {
    /// Repository-relative path.
    let path: String
    let owner: String
    let reason: String
}

/// A test file allowed to carry an elapsed-time budget, with who owns it and why.
struct ElapsedTimeBudgetOwner: Sendable {
    /// Repository-relative path.
    let path: String
    let owner: String
    let reason: String
}

/// One code site a rule allows on purpose, with who owns it and why. This is
/// ownership, reviewed with the lint tool's source; debt lives in the ledger.
struct NamedOwnerAllowance: Sendable {
    let pathSuffix: String
    let functionName: String
    let owner: String
    let reason: String
}

/// One target's designated policy home, with its owner and boundary rationale.
struct PolicyHomeAllowance: Sendable {
    let pathSuffix: String
    let owner: String
    let reason: String
}
