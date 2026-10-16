import AgentStudioCore
import Foundation

extension BridgePaneProductSchemeProvider {
    func enqueueSupersededContentTerminal(
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
                            code: .superseded,
                            retryable: true,
                            safeMessage: "Content descriptor was superseded"
                        ),
                        payload: Data()
                    )
                )
            }
        )
    }
}
