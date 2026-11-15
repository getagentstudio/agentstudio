import Foundation

extension BridgePaneProductSchemeProvider {
    func runReviewContentProducer(
        request: BridgeProductReviewContentRequest,
        lease: BridgeProductProducerLease,
        productAdmission: BridgeProductAdmissionContext,
        foregroundWorkAdmission: BridgePaneRefreshWorkAdmission,
        session: BridgeProductSession
    ) async throws {
        guard foregroundWorkAdmission.withValidAdmission({ true }) == true else { return }
        let body: BridgePaneProductReviewContentBody
        do {
            body = try await reviewContentSource.contentBody(
                for: request,
                productAdmission: productAdmission
            )
        } catch BridgeProviderFailure.sourceCapacityDeferred {
            guard foregroundWorkAdmission.withValidAdmission({ true }) == true else { return }
            try await enqueueContentCapacityDeferredTerminal(
                for: lease,
                productAdmission: productAdmission,
                foregroundWorkAdmission: foregroundWorkAdmission,
                session: session
            )
            return
        } catch {
            guard foregroundWorkAdmission.withValidAdmission({ true }) == true else { return }
            try await enqueueUnavailableContentTerminal(
                for: lease,
                productAdmission: productAdmission,
                foregroundWorkAdmission: foregroundWorkAdmission,
                session: session
            )
            return
        }
        guard foregroundWorkAdmission.withValidAdmission({ true }) == true else { return }
        _ = try await runBufferedContentProducer(
            BufferedContentBody(
                data: body.data,
                endOfSource: body.isFinalRange,
                sha256: body.sha256
            ),
            lease: lease,
            productAdmission: productAdmission,
            foregroundWorkAdmission: foregroundWorkAdmission,
            session: session
        )
    }

    private func enqueueContentCapacityDeferredTerminal(
        for lease: BridgeProductProducerLease,
        productAdmission: BridgeProductAdmissionContext,
        foregroundWorkAdmission: BridgePaneRefreshWorkAdmission,
        session: BridgeProductSession
    ) async throws {
        _ = try await session.enqueueTerminalContentFrame(
            for: lease,
            productAdmission: productAdmission,
            foregroundWorkAdmission: foregroundWorkAdmission,
            build: { sequence in
                .content(
                    .init(
                        header: try .error(
                            contentSequence: sequence,
                            code: .internal,
                            retryable: true,
                            safeMessage: "Git content read capacity is temporarily unavailable"
                        ),
                        payload: Data()
                    )
                )
            }
        )
    }
}
