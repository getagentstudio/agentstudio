import Foundation

package struct IPCWorkspaceQueryMethodDescriptors: Sendable {
    package let windowList: IPCMethodDescriptor<IPCEmptyParams, IPCWindowListResult>
    package let windowCurrent: IPCMethodDescriptor<IPCEmptyParams, IPCCurrentWindowResult>
    package let workspaceList: IPCMethodDescriptor<IPCEmptyParams, IPCWorkspaceListResult>
    package let workspaceCurrent: IPCMethodDescriptor<IPCEmptyParams, IPCCurrentWorkspaceResult>
    package let paneList: IPCMethodDescriptor<IPCEmptyParams, IPCPaneListResult>
    package let paneCurrent: IPCMethodDescriptor<IPCEmptyParams, IPCPaneSnapshotResult>
    package let paneSnapshot: IPCMethodDescriptor<IPCPaneSelectorParams, IPCPaneSnapshotResult>

    init(examples: IPCBuiltInMethodExampleContext) throws {
        windowList = try Self.windowListEntry.makeDescriptor(inputs: IPCBuiltInMethodCatalogInputs(examples: examples))
        windowCurrent = try Self.windowCurrentEntry.makeDescriptor(
            inputs: IPCBuiltInMethodCatalogInputs(examples: examples))
        workspaceList = try Self.workspaceListEntry.makeDescriptor(
            inputs: IPCBuiltInMethodCatalogInputs(examples: examples))
        workspaceCurrent = try Self.workspaceCurrentEntry.makeDescriptor(
            inputs: IPCBuiltInMethodCatalogInputs(examples: examples))
        paneList = try Self.paneListEntry.makeDescriptor(inputs: IPCBuiltInMethodCatalogInputs(examples: examples))
        paneCurrent = try Self.paneCurrentEntry.makeDescriptor(
            inputs: IPCBuiltInMethodCatalogInputs(examples: examples))
        paneSnapshot = try Self.paneSnapshotEntry.makeDescriptor(
            inputs: IPCBuiltInMethodCatalogInputs(examples: examples))
    }

    init(representations: [String: any IPCMethodDescriptorRepresentation]) throws {
        windowList = try Self.windowListEntry.typedDescriptor(in: representations)
        windowCurrent = try Self.windowCurrentEntry.typedDescriptor(in: representations)
        workspaceList = try Self.workspaceListEntry.typedDescriptor(in: representations)
        workspaceCurrent = try Self.workspaceCurrentEntry.typedDescriptor(in: representations)
        paneList = try Self.paneListEntry.typedDescriptor(in: representations)
        paneCurrent = try Self.paneCurrentEntry.typedDescriptor(in: representations)
        paneSnapshot = try Self.paneSnapshotEntry.typedDescriptor(in: representations)
    }

    static let windowListEntry = IPCBuiltInMethodEntry<IPCEmptyParams, IPCWindowListResult>(
        name: "window.list", summary: "List workspace windows.",
        modelCalls: [],
        correlationPolicy: .notAccepted,
        agentEligibility: .anyTarget,
        makeDescriptor: { entryName, entrySummary, _, entryEligibility, inputs in
            let examples = inputs.examples
            let window = IPCWindowSummary(
                id: examples.windowId,
                ordinal: 1,
                isKey: true,
                isFocused: true,
                isCurrent: true,
                workspaceId: examples.workspaceId
            )
            return try Self.query(
                entryName, entrySummary, IPCWindowListResult(windows: [window]), .workspaceRead,
                .unspecified, agentEligibility: entryEligibility)
        })

    static let windowCurrentEntry = IPCBuiltInMethodEntry<IPCEmptyParams, IPCCurrentWindowResult>(
        name: "window.current", summary: "Read the current workspace window.",
        modelCalls: [],
        correlationPolicy: .notAccepted,
        agentEligibility: .anyTarget,
        makeDescriptor: { entryName, entrySummary, _, entryEligibility, inputs in
            let examples = inputs.examples
            let window = IPCWindowSummary(
                id: examples.windowId,
                ordinal: 1,
                isKey: true,
                isFocused: true,
                isCurrent: true,
                workspaceId: examples.workspaceId
            )
            return try Self.query(
                entryName, entrySummary, IPCCurrentWindowResult(window: window),
                .workspaceRead, .unspecified, agentEligibility: entryEligibility)
        })

    static let workspaceListEntry = IPCBuiltInMethodEntry<IPCEmptyParams, IPCWorkspaceListResult>(
        name: "workspace.list", summary: "List available workspaces.",
        modelCalls: [],
        correlationPolicy: .notAccepted,
        agentEligibility: .anyTarget,
        makeDescriptor: { entryName, entrySummary, _, entryEligibility, inputs in
            let examples = inputs.examples
            let worktree = IPCWorkspaceWorktreeSummary(
                id: examples.worktreeId,
                repoId: examples.repositoryId,
                name: "main",
                path: "/example/repository",
                isMainWorktree: true
            )
            let repository = IPCWorkspaceRepositorySummary(
                id: examples.repositoryId,
                name: "example-repository",
                path: "/example/repository",
                worktrees: [worktree]
            )
            let workspace = IPCWorkspaceSummary(
                id: examples.workspaceId,
                ordinal: 1,
                name: "Example Workspace",
                tabCount: 1,
                paneCount: 1,
                repositories: [repository],
                isCurrent: true
            )
            return try Self.query(
                entryName, entrySummary, IPCWorkspaceListResult(workspaces: [workspace]),
                .workspaceRead, .unspecified, agentEligibility: entryEligibility)
        })

    static let workspaceCurrentEntry = IPCBuiltInMethodEntry<IPCEmptyParams, IPCCurrentWorkspaceResult>(
        name: "workspace.current", summary: "Read the current workspace.",
        modelCalls: [],
        correlationPolicy: .notAccepted,
        agentEligibility: .anyTarget,
        makeDescriptor: { entryName, entrySummary, _, entryEligibility, inputs in
            let examples = inputs.examples
            let worktree = IPCWorkspaceWorktreeSummary(
                id: examples.worktreeId,
                repoId: examples.repositoryId,
                name: "main",
                path: "/example/repository",
                isMainWorktree: true
            )
            let repository = IPCWorkspaceRepositorySummary(
                id: examples.repositoryId,
                name: "example-repository",
                path: "/example/repository",
                worktrees: [worktree]
            )
            let workspace = IPCWorkspaceSummary(
                id: examples.workspaceId,
                ordinal: 1,
                name: "Example Workspace",
                tabCount: 1,
                paneCount: 1,
                repositories: [repository],
                isCurrent: true
            )
            return try Self.query(
                entryName, entrySummary, IPCCurrentWorkspaceResult(workspace: workspace),
                .workspaceRead, .unspecified, agentEligibility: entryEligibility)
        })

    static let paneListEntry = IPCBuiltInMethodEntry<IPCEmptyParams, IPCPaneListResult>(
        name: "pane.list", summary: "List panes in the selected runtime.",
        modelCalls: [],
        correlationPolicy: .notAccepted,
        agentEligibility: .anyTarget,
        makeDescriptor: { entryName, entrySummary, _, entryEligibility, inputs in
            let examples = inputs.examples
            let pane = IPCPaneSummary(
                id: examples.paneId,
                ordinal: 1,
                contentKind: .terminal,
                residency: .active,
                tabId: examples.tabId,
                repoId: examples.repositoryId,
                worktreeId: examples.worktreeId,
                isActive: true,
                isDrawerChild: false
            )
            return try Self.query(
                entryName, entrySummary, IPCPaneListResult(panes: [pane]),
                .paneContextRead, .paneContext, agentEligibility: entryEligibility)
        })

    static let paneCurrentEntry = IPCBuiltInMethodEntry<IPCEmptyParams, IPCPaneSnapshotResult>(
        name: "pane.current", summary: "Read the current pane and its workspace context.",
        modelCalls: [],
        correlationPolicy: .notAccepted,
        agentEligibility: .anyTarget,
        makeDescriptor: { entryName, entrySummary, _, entryEligibility, inputs in
            let examples = inputs.examples
            let worktree = IPCWorkspaceWorktreeSummary(
                id: examples.worktreeId,
                repoId: examples.repositoryId,
                name: "main",
                path: "/example/repository",
                isMainWorktree: true
            )
            let repository = IPCWorkspaceRepositorySummary(
                id: examples.repositoryId,
                name: "example-repository",
                path: "/example/repository",
                worktrees: [worktree]
            )
            let workspace = IPCWorkspaceSummary(
                id: examples.workspaceId,
                ordinal: 1,
                name: "Example Workspace",
                tabCount: 1,
                paneCount: 1,
                repositories: [repository],
                isCurrent: true
            )
            let tab = IPCTabSummary(
                id: examples.tabId,
                ordinal: 1,
                name: "Main",
                paneIds: [examples.paneId],
                activePaneId: examples.paneId,
                isActive: true
            )
            let pane = IPCPaneSummary(
                id: examples.paneId,
                ordinal: 1,
                contentKind: .terminal,
                residency: .active,
                tabId: examples.tabId,
                repoId: examples.repositoryId,
                worktreeId: examples.worktreeId,
                isActive: true,
                isDrawerChild: false
            )
            let paneResult = IPCPaneSnapshotResult(pane: pane, tab: tab, workspace: workspace)
            return try Self.query(
                entryName, entrySummary, paneResult,
                .paneContextRead, .paneContext, agentEligibility: entryEligibility)
        })

    static let paneSnapshotEntry = IPCBuiltInMethodEntry<IPCPaneSelectorParams, IPCPaneSnapshotResult>(
        name: "pane.snapshot", summary: "Read one explicit pane and its workspace context.",
        modelCalls: [],
        correlationPolicy: .notAccepted,
        agentEligibility: .ownPane,
        makeDescriptor: { entryName, entrySummary, _, entryEligibility, inputs in
            let examples = inputs.examples
            let worktree = IPCWorkspaceWorktreeSummary(
                id: examples.worktreeId,
                repoId: examples.repositoryId,
                name: "main",
                path: "/example/repository",
                isMainWorktree: true
            )
            let repository = IPCWorkspaceRepositorySummary(
                id: examples.repositoryId,
                name: "example-repository",
                path: "/example/repository",
                worktrees: [worktree]
            )
            let workspace = IPCWorkspaceSummary(
                id: examples.workspaceId,
                ordinal: 1,
                name: "Example Workspace",
                tabCount: 1,
                paneCount: 1,
                repositories: [repository],
                isCurrent: true
            )
            let tab = IPCTabSummary(
                id: examples.tabId,
                ordinal: 1,
                name: "Main",
                paneIds: [examples.paneId],
                activePaneId: examples.paneId,
                isActive: true
            )
            let pane = IPCPaneSummary(
                id: examples.paneId,
                ordinal: 1,
                contentKind: .terminal,
                residency: .active,
                tabId: examples.tabId,
                repoId: examples.repositoryId,
                worktreeId: examples.worktreeId,
                isActive: true,
                isDrawerChild: false
            )
            let paneResult = IPCPaneSnapshotResult(pane: pane, tab: tab, workspace: workspace)
            return try IPCBuiltInDescriptorSupport.read(
                name: entryName,
                description: entrySummary,
                parameters: IPCPaneSelectorParams(handle: "self"),
                result: paneResult,
                privilege: .paneContextRead,
                dataScope: .paneContext,
                targetKinds: [.pane],
                exposure: .allChannels,
                errors: [IPCBuiltInDescriptorSupport.invalidParams, IPCBuiltInDescriptorSupport.targetNotFound],
                agentEligibility: entryEligibility
            )
        })

    private static func query<Result: IPCSchemaProviding>(
        _ name: String,
        _ description: String,
        _ result: Result,
        _ privilege: IPCPrivilegeClass,
        _ dataScope: IPCDataScope,
        agentEligibility: IPCAgentEligibility?
    ) throws -> IPCMethodDescriptor<IPCEmptyParams, Result> {
        try IPCBuiltInDescriptorSupport.read(
            name: name,
            description: description,
            parameters: IPCEmptyParams(),
            result: result,
            privilege: privilege,
            dataScope: dataScope,
            exposure: .allChannels,
            errors: [IPCBuiltInDescriptorSupport.unavailable],
            agentEligibility: agentEligibility
        )
    }

    var descriptorRepresentations: [any IPCMethodDescriptorRepresentation] {
        get throws {
            let representations: [any IPCMethodDescriptorRepresentation] = try [
                IPCMethodDescriptorRepresentations(typedDescriptor: windowList),
                IPCMethodDescriptorRepresentations(typedDescriptor: windowCurrent),
                IPCMethodDescriptorRepresentations(typedDescriptor: workspaceList),
                IPCMethodDescriptorRepresentations(typedDescriptor: workspaceCurrent),
                IPCMethodDescriptorRepresentations(typedDescriptor: paneList),
                IPCMethodDescriptorRepresentations(typedDescriptor: paneCurrent),
                IPCMethodDescriptorRepresentations(typedDescriptor: paneSnapshot),
            ]
            return representations
        }
    }

    var erased: [IPCAnyMethodDescriptor] {
        get throws { try descriptorRepresentations.map(\.erasedDescriptor) }
    }
}
