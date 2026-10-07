import Foundation

extension IPCBuiltInMethodExampleContext {
    package init(illustrativeIdentifier: UUID) {
        self.init(
            runtimeId: illustrativeIdentifier, windowId: illustrativeIdentifier, workspaceId: illustrativeIdentifier,
            repositoryId: illustrativeIdentifier, worktreeId: illustrativeIdentifier, tabId: illustrativeIdentifier,
            paneId: illustrativeIdentifier, commandId: illustrativeIdentifier, correlationId: illustrativeIdentifier,
            subscriptionId: illustrativeIdentifier
        )
    }
}

extension IPCBuiltInMethodCatalog {
    /// Offline classification cannot read the live catalog, so an unreachable
    /// app is answered from the compiled notification descriptors. Only these
    /// methods carry offline eligibility, so no other descriptor is needed.
    package static func offlineNotificationDescriptors(
        examples: IPCBuiltInMethodExampleContext
    ) throws -> [IPCAnyMethodDescriptor] {
        try IPCSessionMethodDescriptors(examples: examples).erased
    }
}
