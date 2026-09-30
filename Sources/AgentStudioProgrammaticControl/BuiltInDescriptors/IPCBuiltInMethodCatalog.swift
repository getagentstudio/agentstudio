import Foundation

package struct IPCBuiltInMethodCatalog: Sendable {
    package let systemAndAuth: IPCSystemAndAuthMethodDescriptors
    package let workspaceQueries: IPCWorkspaceQueryMethodDescriptors
    package let layout: IPCLayoutMethodDescriptors
    package let terminal: IPCTerminalMethodDescriptors
    package let bridge: IPCBridgeMethodDescriptors
    package let presentationAndSidebar: IPCPresentationAndSidebarMethodDescriptors
    package let events: IPCEventMethodDescriptors
    package let sessions: IPCSessionMethodDescriptors
    package let descriptorRepresentations: [any IPCMethodDescriptorRepresentation]
    package let erasedDescriptors: [IPCAnyMethodDescriptor]

    package init(inputs: IPCBuiltInMethodCatalogInputs) throws {
        systemAndAuth = try IPCSystemAndAuthMethodDescriptors(examples: inputs.examples)
        workspaceQueries = try IPCWorkspaceQueryMethodDescriptors(examples: inputs.examples)
        layout = try IPCLayoutMethodDescriptors(inputs: inputs)
        terminal = try IPCTerminalMethodDescriptors(inputs: inputs)
        bridge = try IPCBridgeMethodDescriptors(inputs: inputs)
        presentationAndSidebar = try IPCPresentationAndSidebarMethodDescriptors(examples: inputs.examples)
        events = try IPCEventMethodDescriptors(examples: inputs.examples)
        sessions = try IPCSessionMethodDescriptors(examples: inputs.examples)
        let descriptorRepresentations = try
            (systemAndAuth.descriptorRepresentations
            + workspaceQueries.descriptorRepresentations
            + layout.descriptorRepresentations
            + terminal.descriptorRepresentations
            + bridge.descriptorRepresentations
            + presentationAndSidebar.descriptorRepresentations
            + events.descriptorRepresentations
            + sessions.descriptorRepresentations).sorted { $0.methodName < $1.methodName }
        self.descriptorRepresentations = descriptorRepresentations
        erasedDescriptors = descriptorRepresentations.map(\.erasedDescriptor)
    }

    package func descriptorRepresentations<Parameters, Result>(
        for descriptor: IPCMethodDescriptor<Parameters, Result>
    ) throws -> IPCMethodDescriptorRepresentations<Parameters, Result>
    where Parameters: Codable & Sendable, Result: Codable & Sendable {
        guard let representation = descriptorRepresentations.first(where: { $0.methodName == descriptor.name }) else {
            throw IPCMethodDescriptorRepresentationLookupError.missingMethod(descriptor.name)
        }
        guard let typedRepresentation = representation as? IPCMethodDescriptorRepresentations<Parameters, Result> else {
            throw IPCMethodDescriptorRepresentationLookupError.descriptorTypeMismatch(descriptor.name)
        }
        return typedRepresentation
    }
}
