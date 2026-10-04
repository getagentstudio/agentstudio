import Foundation

package struct IPCLayoutMethodDescriptors: Sendable {
    package let paneFocus: IPCMethodDescriptor<IPCPaneControlParams, IPCPaneFocusResult>
    package let paneSplit: IPCMethodDescriptor<IPCPaneSplitParams, IPCPaneSplitResult>
    package let paneClose: IPCMethodDescriptor<IPCPaneCloseParams, IPCPaneCloseResult>
    package let drawerToggle: IPCMethodDescriptor<IPCDrawerToggleParams, IPCDrawerToggleResult>
    package let drawerAddPane: IPCMethodDescriptor<IPCDrawerAddPaneParams, IPCDrawerAddPaneResult>

    init(inputs: IPCBuiltInMethodCatalogInputs) throws {
        paneFocus = try Self.paneFocusEntry.makeDescriptor(inputs: inputs)
        paneSplit = try Self.paneSplitEntry.makeDescriptor(inputs: inputs)
        paneClose = try Self.paneCloseEntry.makeDescriptor(inputs: inputs)
        drawerToggle = try Self.drawerToggleEntry.makeDescriptor(inputs: inputs)
        drawerAddPane = try Self.drawerAddPaneEntry.makeDescriptor(inputs: inputs)
    }

    init(representations: [String: any IPCMethodDescriptorRepresentation]) throws {
        paneFocus = try Self.paneFocusEntry.typedDescriptor(in: representations)
        paneSplit = try Self.paneSplitEntry.typedDescriptor(in: representations)
        paneClose = try Self.paneCloseEntry.typedDescriptor(in: representations)
        drawerToggle = try Self.drawerToggleEntry.typedDescriptor(in: representations)
        drawerAddPane = try Self.drawerAddPaneEntry.typedDescriptor(in: representations)
    }

    static let paneFocusEntry = IPCBuiltInMethodEntry<IPCPaneControlParams, IPCPaneFocusResult>(
        name: "pane.focus", summary: "Focus one explicit pane in an explicit workspace window context.",
        modelCalls: [],
        correlationPolicy: .required,
        agentEligibility: .notYetAllowed,
        makeDescriptor: { entryName, entrySummary, _, entryEligibility, inputs in
            let example = inputs.examples
            let relationship = inputs.relationships
            return try IPCBuiltInDescriptorSupport.mutation(
                name: entryName,
                description: entrySummary,
                parameters: IPCPaneControlParams(handle: "self", correlationId: example.correlationId),
                result: IPCPaneFocusResult(paneId: example.paneId, focused: true),
                metadata: .init(
                    privilege: .layoutMutate,
                    dataScope: .paneContext,
                    targetKinds: [.pane],
                    relationship: relationship.paneFocus,
                    owner: .workspaceAction,
                    agentEligibility: entryEligibility)
            )
        })

    static let paneSplitEntry = IPCBuiltInMethodEntry<IPCPaneSplitParams, IPCPaneSplitResult>(
        name: "pane.split", summary: "Split one explicit pane in the requested direction.",
        modelCalls: [],
        correlationPolicy: .required,
        agentEligibility: .notYetAllowed,
        makeDescriptor: { entryName, entrySummary, _, entryEligibility, inputs in
            let example = inputs.examples
            return try IPCBuiltInDescriptorSupport.mutation(
                name: entryName,
                description: entrySummary,
                parameters: IPCPaneSplitParams(
                    handle: "self",
                    direction: .right,
                    correlationId: example.correlationId
                ),
                result: IPCPaneSplitResult(
                    targetPaneId: example.paneId,
                    direction: .right,
                    correlationId: example.correlationId
                ),
                metadata: .init(
                    privilege: .layoutMutate,
                    dataScope: .paneContext,
                    targetKinds: [.pane],
                    owner: .workspaceAction,
                    agentEligibility: entryEligibility)
            )
        })

    static let paneCloseEntry = IPCBuiltInMethodEntry<IPCPaneCloseParams, IPCPaneCloseResult>(
        name: "pane.close", summary: "Close one explicit pane.",
        modelCalls: [],
        correlationPolicy: .required,
        agentEligibility: .ownPane,
        makeDescriptor: { entryName, entrySummary, _, entryEligibility, inputs in
            let example = inputs.examples
            let relationship = inputs.relationships
            return try IPCBuiltInDescriptorSupport.mutation(
                name: entryName,
                description: entrySummary,
                parameters: IPCPaneCloseParams(handle: "self", correlationId: example.correlationId),
                result: IPCPaneCloseResult(paneId: example.paneId, correlationId: example.correlationId),
                metadata: .init(
                    privilege: .layoutMutate,
                    dataScope: .paneContext,
                    targetKinds: [.pane],
                    relationship: relationship.paneClose,
                    owner: .workspaceAction,
                    exposure: .allChannels,
                    agentEligibility: entryEligibility)
            )
        })

    static let drawerToggleEntry = IPCBuiltInMethodEntry<IPCDrawerToggleParams, IPCDrawerToggleResult>(
        name: "drawer.toggle", summary: "Toggle the drawer belonging to one explicit parent pane.",
        modelCalls: [],
        correlationPolicy: .required,
        agentEligibility: .notYetAllowed,
        makeDescriptor: { entryName, entrySummary, _, entryEligibility, inputs in
            let example = inputs.examples
            let relationship = inputs.relationships
            return try IPCBuiltInDescriptorSupport.mutation(
                name: entryName,
                description: entrySummary,
                parameters: IPCDrawerToggleParams(
                    parentPaneHandle: "self",
                    correlationId: example.correlationId
                ),
                result: IPCDrawerToggleResult(
                    parentPaneId: example.paneId,
                    correlationId: example.correlationId
                ),
                metadata: .init(
                    privilege: .layoutMutate,
                    dataScope: .paneContext,
                    targetKinds: [.pane],
                    relationship: relationship.drawerToggle,
                    owner: .workspaceAction,
                    agentEligibility: entryEligibility)
            )
        })

    static let drawerAddPaneEntry = IPCBuiltInMethodEntry<IPCDrawerAddPaneParams, IPCDrawerAddPaneResult>(
        name: "drawer.addPane",
        summary: "Add a terminal or browser to one explicit parent pane's drawer without expanding it or moving focus.",
        modelCalls: [],
        correlationPolicy: .required,
        agentEligibility: .ownPane,
        makeDescriptor: { entryName, entrySummary, _, entryEligibility, inputs in
            let example = inputs.examples
            let relationship = inputs.relationships
            return try IPCBuiltInDescriptorSupport.mutation(
                name: entryName,
                description:
                    entrySummary,
                parameters: IPCDrawerAddPaneParams(
                    parentPaneHandle: "self",
                    content: .browser(url: "https://example.com"),
                    correlationId: example.correlationId
                ),
                result: IPCDrawerAddPaneResult(
                    parentPaneId: example.paneId,
                    childPaneId: example.commandId,
                    correlationId: example.correlationId
                ),
                metadata: .init(
                    privilege: .layoutMutate,
                    dataScope: .paneContext,
                    targetKinds: [.pane],
                    relationship: relationship.drawerAddPane,
                    owner: .workspaceAction,
                    exposure: .allChannels,
                    agentEligibility: entryEligibility)
            )
        })

    var descriptorRepresentations: [any IPCMethodDescriptorRepresentation] {
        get throws {
            let representations: [any IPCMethodDescriptorRepresentation] = try [
                IPCMethodDescriptorRepresentations(typedDescriptor: paneFocus),
                IPCMethodDescriptorRepresentations(typedDescriptor: paneSplit),
                IPCMethodDescriptorRepresentations(typedDescriptor: paneClose),
                IPCMethodDescriptorRepresentations(typedDescriptor: drawerToggle),
                IPCMethodDescriptorRepresentations(typedDescriptor: drawerAddPane),
            ]
            return representations
        }
    }

    var erased: [IPCAnyMethodDescriptor] {
        get throws { try descriptorRepresentations.map(\.erasedDescriptor) }
    }
}
