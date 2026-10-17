import Foundation

extension BridgeProductSchemeAdapter {
    /// Terminal status replies carry no product data and must settle even after
    /// the admission gate has been revoked. WebKit guards their dispatch after stop.
    func sendTerminalFailure(
        error: any Error,
        request: URLRequest,
        continuation: BridgeProductSchemeReplyContinuation
    ) {
        if case BridgeProductSchemeAdapterError.admissionInvalid = error,
            let control = try? BridgeProductStrictJSON.decode(
                BridgeProductControlRequest.self,
                from: request.httpBody ?? Data()
            ),
            let body = try? JSONEncoder().encode(
                BridgeProductControlResponse.requestError(
                    correlating: control,
                    code: .staleWorker,
                    nextExpectedRequestSequence: nil,
                    retryAfterMilliseconds: nil,
                    retryable: false,
                    safeMessage: nil
                )
            )
        {
            sendTerminalStatus(statusCode: 409, url: request.url, body: body, continuation: continuation)
            return
        }
        sendTerminalStatus(statusCode: 503, url: request.url, body: nil, continuation: continuation)
    }

    func sendTerminalStatus(
        statusCode: Int,
        url: URL?,
        body: Data?,
        continuation: BridgeProductSchemeReplyContinuation
    ) {
        guard let url else {
            // WebKit scheme tasks always carry a URL; without one there is no
            // legal HTTP response to emit.
            continuation.finish(throwing: CancellationError())
            return
        }
        let response = Self.response(
            statusCode: statusCode,
            url: url,
            contentType: "application/json",
            contentLength: body?.count ?? 0
        )
        guard case .enqueued = continuation.yield(.response(response)) else {
            continuation.finish()
            return
        }
        if let body { _ = continuation.yield(.data(body)) }
        continuation.finish()
    }
}
