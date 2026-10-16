import Foundation

extension BridgePaneProductSchemeProvider {
    func fileSourceCurrentResponse(
        for request: BridgeProductControlRequest,
        source: any BridgePaneProductFileMetadataProducing
    ) async throws -> BridgeProductControlResponse {
        do {
            return try .callCompleted(
                correlating: request, result: .fileSourceCurrent(try await source.currentSource()))
        } catch let failure as BridgeWorktreeFileRootAccessError {
            return try .requestError(
                correlating: request, code: .internal,
                nextExpectedRequestSequence: request.requestSequence + 1,
                retryAfterMilliseconds: nil, retryable: failure.retryable, safeMessage: failure.safeMessage)
        }
    }
}
