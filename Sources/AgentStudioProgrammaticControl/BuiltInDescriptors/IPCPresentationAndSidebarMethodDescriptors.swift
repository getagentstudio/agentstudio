import Foundation

package struct IPCPresentationAndSidebarMethodDescriptors: Sendable {
    package let uiCommandBarOpen: IPCMethodDescriptor<IPCCommandBarOpenParams, IPCCommandBarOpenResult>
    package let uiArrangementsOpen: IPCMethodDescriptor<IPCArrangementsOpenParams, IPCArrangementsOpenResult>
    package let sidebarGroupingGet: IPCMethodDescriptor<IPCSidebarGroupingGetParams, IPCSidebarGroupingResult>
    package let sidebarSurfaceGet: IPCMethodDescriptor<IPCSidebarSurfaceGetParams, IPCSidebarSurfaceResult>

    init(examples: IPCBuiltInMethodExampleContext) throws {
        uiCommandBarOpen = try Self.uiCommandBarOpenEntry.makeDescriptor(
            inputs: IPCBuiltInMethodCatalogInputs(examples: examples))
        uiArrangementsOpen = try Self.uiArrangementsOpenEntry.makeDescriptor(
            inputs: IPCBuiltInMethodCatalogInputs(examples: examples))
        sidebarGroupingGet = try Self.sidebarGroupingGetEntry.makeDescriptor(
            inputs: IPCBuiltInMethodCatalogInputs(examples: examples))
        sidebarSurfaceGet = try Self.sidebarSurfaceGetEntry.makeDescriptor(
            inputs: IPCBuiltInMethodCatalogInputs(examples: examples))
    }

    init(representations: [String: any IPCMethodDescriptorRepresentation]) throws {
        uiCommandBarOpen = try Self.uiCommandBarOpenEntry.typedDescriptor(in: representations)
        uiArrangementsOpen = try Self.uiArrangementsOpenEntry.typedDescriptor(in: representations)
        sidebarGroupingGet = try Self.sidebarGroupingGetEntry.typedDescriptor(in: representations)
        sidebarSurfaceGet = try Self.sidebarSurfaceGetEntry.typedDescriptor(in: representations)
    }

    static let uiCommandBarOpenEntry = IPCBuiltInMethodEntry<IPCCommandBarOpenParams, IPCCommandBarOpenResult>(
        name: "ui.commandBar.open", summary: "Present one command-bar scope in an explicit workspace window.",
        modelCalls: [],
        correlationPolicy: .required,
        agentEligibility: .notYetAllowed,
        makeDescriptor: { entryName, entrySummary, _, entryEligibility, inputs in
            let examples = inputs.examples
            return try IPCBuiltInDescriptorSupport.mutation(
                name: entryName,
                description: entrySummary,
                parameters: IPCCommandBarOpenParams(
                    workspaceWindowId: examples.windowId,
                    scope: .everything,
                    correlationId: examples.correlationId
                ),
                result: IPCCommandBarOpenResult(
                    workspaceWindowId: examples.windowId,
                    scope: .everything,
                    correlationId: examples.correlationId
                ),
                metadata: .init(
                    privilege: .uiPresent,
                    dataScope: .uiSurface,
                    targetKinds: [.window],
                    owner: .uiPresentation,
                    semantics: .presented,
                    errors: Self.presentationErrors,
                    agentEligibility: entryEligibility)
            )
        })

    static let uiArrangementsOpenEntry = IPCBuiltInMethodEntry<IPCArrangementsOpenParams, IPCArrangementsOpenResult>(
        name: "ui.arrangements.open",
        summary: "Present arrangements in an explicit workspace window and optional pane context.",
        modelCalls: [],
        correlationPolicy: .required,
        agentEligibility: .notYetAllowed,
        makeDescriptor: { entryName, entrySummary, _, entryEligibility, inputs in
            let examples = inputs.examples
            return try IPCBuiltInDescriptorSupport.mutation(
                name: entryName,
                description: entrySummary,
                parameters: IPCArrangementsOpenParams(
                    workspaceWindowId: examples.windowId,
                    targetPaneHandle: "self",
                    correlationId: examples.correlationId
                ),
                result: IPCArrangementsOpenResult(
                    workspaceWindowId: examples.windowId,
                    tabId: examples.tabId,
                    contextPaneId: examples.paneId,
                    correlationId: examples.correlationId
                ),
                metadata: .init(
                    privilege: .uiPresent,
                    dataScope: .uiSurface,
                    targetKinds: [.window],
                    owner: .uiPresentation,
                    semantics: .presented,
                    errors: Self.presentationErrors,
                    agentEligibility: entryEligibility)
            )
        })

    static let sidebarGroupingGetEntry = IPCBuiltInMethodEntry<IPCSidebarGroupingGetParams, IPCSidebarGroupingResult>(
        name: "sidebar.grouping.get", summary: "Read the grouping mode for one sidebar surface.",
        modelCalls: [],
        correlationPolicy: .notAccepted,
        agentEligibility: .notYetAllowed,
        makeDescriptor: { entryName, entrySummary, _, entryEligibility, _ in
            try IPCBuiltInDescriptorSupport.read(
                name: entryName,
                description: entrySummary,
                parameters: IPCSidebarGroupingGetParams(surface: .repo),
                result: IPCSidebarGroupingResult(surface: .repo, mode: .repo),
                privilege: .workspaceRead,
                dataScope: .unspecified,
                errors: [IPCBuiltInDescriptorSupport.unavailable],
                agentEligibility: entryEligibility
            )
        })

    static let sidebarSurfaceGetEntry = IPCBuiltInMethodEntry<IPCSidebarSurfaceGetParams, IPCSidebarSurfaceResult>(
        name: "sidebar.surface.get", summary: "Read the visible sidebar surface.",
        modelCalls: [],
        correlationPolicy: .notAccepted,
        agentEligibility: .notYetAllowed,
        makeDescriptor: { entryName, entrySummary, _, entryEligibility, _ in
            try IPCBuiltInDescriptorSupport.read(
                name: entryName,
                description: entrySummary,
                parameters: IPCSidebarSurfaceGetParams(),
                result: IPCSidebarSurfaceResult(surface: .repo),
                privilege: .workspaceRead,
                dataScope: .unspecified,
                errors: [IPCBuiltInDescriptorSupport.unavailable],
                agentEligibility: entryEligibility
            )
        })

    private static let presentationErrors = [
        IPCBuiltInDescriptorSupport.invalidParams,
        IPCBuiltInDescriptorSupport.targetNotFound,
        IPCBuiltInDescriptorSupport.unavailable,
    ]

    var descriptorRepresentations: [any IPCMethodDescriptorRepresentation] {
        get throws {
            let representations: [any IPCMethodDescriptorRepresentation] = try [
                IPCMethodDescriptorRepresentations(typedDescriptor: uiCommandBarOpen),
                IPCMethodDescriptorRepresentations(typedDescriptor: uiArrangementsOpen),
                IPCMethodDescriptorRepresentations(typedDescriptor: sidebarGroupingGet),
                IPCMethodDescriptorRepresentations(typedDescriptor: sidebarSurfaceGet),
            ]
            return representations
        }
    }

    var erased: [IPCAnyMethodDescriptor] {
        get throws { try descriptorRepresentations.map(\.erasedDescriptor) }
    }
}
