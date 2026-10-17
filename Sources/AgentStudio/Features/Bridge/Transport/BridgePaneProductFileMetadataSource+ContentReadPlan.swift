extension BridgePaneProductFileMetadataSource {
    func authoritativePath(
        for request: BridgeProductFileContentRequest,
        productAdmission: BridgeProductAdmissionContext
    ) async -> String? {
        guard productAdmission.withValidAdmission({ true }) == true else { return nil }
        for subscriptionId in contextBySubscriptionId.keys.sorted() {
            guard let context = contextBySubscriptionId[subscriptionId],
                context.productSource == request.descriptor.source,
                context.productAdmission.matches(productAdmission)
            else { continue }
            if let issued = await context.manifestIndex.issuedDescriptorOutcome(
                matching: request.descriptor,
                productAdmission: productAdmission
            ) {
                return issued.path
            }
        }
        return nil
    }

    func contentReadPlan(
        for request: BridgeProductFileContentRequest,
        productAdmission: BridgeProductAdmissionContext
    ) async -> BridgePaneProductFileContentReadPlan? {
        guard productAdmission.withValidAdmission({ true }) == true else { return nil }
        for subscriptionId in contextBySubscriptionId.keys.sorted() {
            guard let context = contextBySubscriptionId[subscriptionId],
                context.productSource == request.descriptor.source,
                context.productAdmission.matches(productAdmission)
            else { continue }
            guard
                let issued = await context.manifestIndex.issuedDescriptorOutcome(
                    matching: request.descriptor,
                    productAdmission: productAdmission
                )
            else { continue }
            return BridgePaneProductFileContentReadPlan(
                descriptor: request.descriptor,
                relativePath: issued.path,
                rootURL: authority.worktree.path
            )
        }
        return nil
    }
}
