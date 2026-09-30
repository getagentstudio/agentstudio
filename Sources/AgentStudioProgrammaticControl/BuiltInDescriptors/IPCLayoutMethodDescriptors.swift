import Foundation

package struct IPCLayoutMethodDescriptors: Sendable {
    package let paneFocus: IPCMethodDescriptor<IPCPaneControlParams, IPCPaneFocusResult>
    package let paneSplit: IPCMethodDescriptor<IPCPaneSplitParams, IPCPaneSplitResult>
    package let paneClose: IPCMethodDescriptor<IPCPaneCloseParams, IPCPaneCloseResult>
    package let drawerToggle: IPCMethodDescriptor<IPCDrawerToggleParams, IPCDrawerToggleResult>
    package let drawerAddPane: IPCMethodDescriptor<IPCDrawerAddPaneParams, IPCDrawerAddPaneResult>

    init(inputs: IPCBuiltInMethodCatalogInputs) throws {
        let example = inputs.examples
        let relationship = inputs.relationships
        paneFocus = try IPCBuiltInDescriptorSupport.mutation(
            name: "pane.focus",
            description: "Focus one explicit pane in an explicit workspace window context.",
            parameters: IPCPaneControlParams(handle: "self", correlationId: example.correlationId),
            result: IPCPaneFocusResult(paneId: example.paneId, focused: true),
            metadata: .init(
                privilege: .layoutMutate,
                dataScope: .paneContext,
                targetKinds: [.pane],
                relationship: relationship.paneFocus,
                owner: .workspaceAction,
                agentEligibility: .notYetAllowed)
        )
        paneSplit = try IPCBuiltInDescriptorSupport.mutation(
            name: "pane.split",
            description: "Split one explicit pane in the requested direction.",
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
                agentEligibility: .notYetAllowed)
        )
        paneClose = try IPCBuiltInDescriptorSupport.mutation(
            name: "pane.close",
            description: "Close one explicit pane.",
            parameters: IPCPaneCloseParams(handle: "self", correlationId: example.correlationId),
            result: IPCPaneCloseResult(paneId: example.paneId, correlationId: example.correlationId),
            metadata: .init(
                privilege: .layoutMutate,
                dataScope: .paneContext,
                targetKinds: [.pane],
                relationship: relationship.paneClose,
                owner: .workspaceAction,
                exposure: .allChannels,
                agentEligibility: .ownPane)
        )
        drawerToggle = try IPCBuiltInDescriptorSupport.mutation(
            name: "drawer.toggle",
            description: "Toggle the drawer belonging to one explicit parent pane.",
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
                agentEligibility: .notYetAllowed)
        )
        drawerAddPane = try IPCBuiltInDescriptorSupport.mutation(
            name: "drawer.addPane",
            description:
                "Add a terminal or browser to one explicit parent pane's drawer without expanding it or moving focus.",
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
                agentEligibility: .ownPane)
        )
    }

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
