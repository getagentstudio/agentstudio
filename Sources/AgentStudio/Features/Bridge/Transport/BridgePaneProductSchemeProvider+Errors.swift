private func makeProductRequestError(
    for request: BridgeProductControlRequest,
    code: BridgeProductRequestErrorCode,
    retryable: Bool,
    safeMessage: String
) throws -> BridgeProductControlResponse {
    try .requestError(
        correlating: request,
        code: code,
        nextExpectedRequestSequence: request.requestSequence + 1,
        retryAfterMilliseconds: nil,
        retryable: retryable,
        safeMessage: safeMessage
    )
}

func metadataStreamRequiredError(
    for request: BridgeProductControlRequest
) throws -> BridgeProductControlResponse {
    try makeProductRequestError(
        for: request,
        code: .resyncRequired,
        retryable: true,
        safeMessage: "Metadata stream is not installed"
    )
}

func viewControlRejectedError(
    for request: BridgeProductControlRequest,
    code: BridgeProductRequestErrorCode
) throws -> BridgeProductControlResponse {
    try makeProductRequestError(
        for: request,
        code: code,
        retryable: code == .staleWorker,
        safeMessage: "View control was not accepted"
    )
}

func annotationOutputUnavailableError(
    for request: BridgeProductControlRequest
) throws -> BridgeProductControlResponse {
    try makeProductRequestError(
        for: request,
        code: .internal,
        retryable: false,
        safeMessage: "Annotation output is unavailable"
    )
}
