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
    package let paneContext: IPCPaneContextMethodDescriptors
    package let descriptorRepresentations: [any IPCMethodDescriptorRepresentation]
    package let erasedDescriptors: [IPCAnyMethodDescriptor]

    package init(inputs: IPCBuiltInMethodCatalogInputs) throws {
        let descriptorRepresentations = try IPCBuiltInMethodIndex().makeRepresentations(inputs: inputs)
        let byName = Dictionary(uniqueKeysWithValues: descriptorRepresentations.map { ($0.methodName, $0) })
        systemAndAuth = try IPCSystemAndAuthMethodDescriptors(representations: byName)
        workspaceQueries = try IPCWorkspaceQueryMethodDescriptors(representations: byName)
        layout = try IPCLayoutMethodDescriptors(representations: byName)
        terminal = try IPCTerminalMethodDescriptors(representations: byName)
        bridge = try IPCBridgeMethodDescriptors(representations: byName)
        presentationAndSidebar = try IPCPresentationAndSidebarMethodDescriptors(representations: byName)
        events = try IPCEventMethodDescriptors(representations: byName)
        sessions = try IPCSessionMethodDescriptors(representations: byName)
        paneContext = try IPCPaneContextMethodDescriptors(representations: byName)
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
