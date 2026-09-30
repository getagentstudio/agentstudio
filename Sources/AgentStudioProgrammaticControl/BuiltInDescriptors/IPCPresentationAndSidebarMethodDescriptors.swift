import Foundation

package struct IPCPresentationAndSidebarMethodDescriptors: Sendable {
    package let uiCommandBarOpen: IPCMethodDescriptor<IPCCommandBarOpenParams, IPCCommandBarOpenResult>
    package let uiArrangementsOpen: IPCMethodDescriptor<IPCArrangementsOpenParams, IPCArrangementsOpenResult>
    package let sidebarGroupingGet: IPCMethodDescriptor<IPCSidebarGroupingGetParams, IPCSidebarGroupingResult>
    package let sidebarSurfaceGet: IPCMethodDescriptor<IPCSidebarSurfaceGetParams, IPCSidebarSurfaceResult>

    init(examples: IPCBuiltInMethodExampleContext) throws {
        uiCommandBarOpen = try IPCBuiltInDescriptorSupport.mutation(
            name: "ui.commandBar.open",
            description: "Present one command-bar scope in an explicit workspace window.",
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
                agentEligibility: .notYetAllowed)
        )
        uiArrangementsOpen = try IPCBuiltInDescriptorSupport.mutation(
            name: "ui.arrangements.open",
            description: "Present arrangements in an explicit workspace window and optional pane context.",
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
                agentEligibility: .notYetAllowed)
        )
        sidebarGroupingGet = try IPCBuiltInDescriptorSupport.read(
            name: "sidebar.grouping.get",
            description: "Read the grouping mode for one sidebar surface.",
            parameters: IPCSidebarGroupingGetParams(surface: .repo),
            result: IPCSidebarGroupingResult(surface: .repo, mode: .repo),
            privilege: .workspaceRead,
            dataScope: .unspecified,
            errors: [IPCBuiltInDescriptorSupport.unavailable],
            agentEligibility: .notYetAllowed
        )
        sidebarSurfaceGet = try IPCBuiltInDescriptorSupport.read(
            name: "sidebar.surface.get",
            description: "Read the visible sidebar surface.",
            parameters: IPCSidebarSurfaceGetParams(),
            result: IPCSidebarSurfaceResult(surface: .repo),
            privilege: .workspaceRead,
            dataScope: .unspecified,
            errors: [IPCBuiltInDescriptorSupport.unavailable],
            agentEligibility: .notYetAllowed
        )
    }

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
