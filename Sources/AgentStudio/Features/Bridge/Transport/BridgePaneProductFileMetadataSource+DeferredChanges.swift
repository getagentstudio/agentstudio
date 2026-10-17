import AgentStudioCore
import Foundation

extension BridgePaneProductFileMetadataSource {
    /// An admitted inventory remains unchanged until its certificate has been emitted.
    func deferFileChanges(
        subscriptionId: String,
        changedPaths: Set<String>,
        statusResult: GitWorkingTreeStatusResult?,
        productAdmission: BridgeProductAdmissionContext,
        foregroundWorkAdmission: BridgePaneRefreshWorkAdmission
    ) -> Bool {
        foregroundWorkAdmission.withValidAdmission {
            productAdmission.withValidAdmission {
                guard var context = contextBySubscriptionId[subscriptionId],
                    context.productAdmission.matches(productAdmission), context.initialEnumerationInFlight
                else { return false }
                context.deferredChangedPaths.formUnion(changedPaths)
                if let statusResult { context.deferredStatusResult = statusResult }
                contextBySubscriptionId[subscriptionId] = context
                return true
            } ?? false
        } ?? false
    }

    func drainDeferredFileChanges(_ request: InitialTreeEnumerationRequest) async throws -> Bool {
        let subscriptionId = request.subscription.subscriptionId
        let pending = request.foregroundWorkAdmission.withValidAdmission {
            request.productAdmission.withValidAdmission { () -> FileChangesPublicationRequest? in
                guard var context = contextBySubscriptionId[subscriptionId],
                    context.productSource == request.productSource,
                    context.productAdmission.matches(request.productAdmission)
                else { return nil }
                let pending = FileChangesPublicationRequest(
                    subscriptionId: subscriptionId, changedPaths: context.deferredChangedPaths,
                    statusResult: context.deferredStatusResult, productAdmission: request.productAdmission,
                    foregroundWorkAdmission: request.foregroundWorkAdmission)
                context.initialEnumerationInFlight = false
                context.deferredChangedPaths.removeAll()
                context.deferredStatusResult = nil
                contextBySubscriptionId[subscriptionId] = context
                return pending
            }.flatMap { $0 }
        }.flatMap { $0 }
        guard let pending else { return false }
        guard !pending.changedPaths.isEmpty || pending.statusResult != nil else { return true }
        let emissions = try await applyFileChanges(pending)
        for emission in emissions {
            guard
                isCurrent(
                    subscriptionId: subscriptionId, source: request.productSource,
                    productAdmission: request.productAdmission),
                request.foregroundWorkAdmission.withValidAdmission({ true }) == true,
                request.productAdmission.withValidAdmission({ true }) == true
            else { return false }
            try await request.emit(emission.fact)
        }
        return true
    }
}
