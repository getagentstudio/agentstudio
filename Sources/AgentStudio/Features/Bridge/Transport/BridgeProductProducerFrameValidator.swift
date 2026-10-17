import Foundation

enum BridgeProductProducerFrameValidationError: Error, Equatable {
    case rejected(BridgeProductProducerEnqueueRejection)

    var rejection: BridgeProductProducerEnqueueRejection {
        switch self {
        case .rejected(let rejection): rejection
        }
    }
}

struct BridgeProductValidatedProducerFrame: Sendable {
    let data: Data
    let batchComplete: Bool
}

enum BridgeProductProducerFrameValidator {
    static func encode(
        for producerKey: BridgeProductProducerKey,
        sequence: Int,
        intent: BridgeProductProducerEnqueueIntent,
        build: @Sendable (Int) throws -> BridgeProductProducerFrame
    ) throws -> BridgeProductValidatedProducerFrame {
        let frame = try correlateContentFrame(
            try build(sequence),
            producerKey: producerKey
        )
        guard frame.sequence == sequence else {
            throw BridgeProductProducerFrameValidationError.rejected(.frameIdentityMismatch)
        }
        if let rejection = rejection(for: frame, producerKey: producerKey) {
            throw BridgeProductProducerFrameValidationError.rejected(rejection)
        }
        guard frameMatchesIntent(frame, intent: intent) else {
            throw BridgeProductProducerFrameValidationError.rejected(.frameLifecycleMismatch)
        }
        let batchComplete: Bool
        if case .metadata(.batch(.complete)) = frame {
            batchComplete = true
        } else {
            batchComplete = false
        }
        return try .init(data: frame.encode(), batchComplete: batchComplete)
    }

    private static func correlateContentFrame(
        _ frame: BridgeProductProducerFrame,
        producerKey: BridgeProductProducerKey
    ) throws -> BridgeProductProducerFrame {
        guard case .content(let contentFrame) = frame,
            case .content(let request) = producerKey
        else { return frame }
        return .content(try contentFrame.correlated(to: request.admission))
    }

    private static func rejection(
        for frame: BridgeProductProducerFrame,
        producerKey: BridgeProductProducerKey
    ) -> BridgeProductProducerEnqueueRejection? {
        switch (frame, producerKey) {
        case (.metadata(let metadataFrame), .metadata(let metadataKey)):
            if case .streamKeepalive = metadataFrame { return .frameKindMismatch }
            let identity = metadataFrame.producerFrameIdentity
            let correlation = metadataKey.request.correlation
            let matches =
                identity.metadataStreamId == correlation.metadataStreamId
                && identity.paneSessionId == correlation.paneSessionId
                && identity.wireVersion == correlation.wireVersion
                && identity.workerInstanceId == correlation.workerInstanceId
            guard matches else { return .frameIdentityMismatch }
            if case .metadataStreamAccepted(let acceptedFrame) = metadataFrame,
                acceptedFrame.resumeDisposition != metadataKey.expectedResumeDisposition
            {
                return .frameIdentityMismatch
            }
            return nil
        case (.content(let contentFrame), .content(let request)):
            guard case .accepted(let header) = contentFrame.header else { return nil }
            return header == BridgeProductContentAcceptedHeader(admission: request.admission)
                ? nil : .frameIdentityMismatch
        default:
            return .frameKindMismatch
        }
    }

    private static func frameMatchesIntent(
        _ frame: BridgeProductProducerFrame,
        intent: BridgeProductProducerEnqueueIntent
    ) -> Bool {
        switch intent {
        case .requiredOpening: frame.isRequiredOpening && !frame.isTerminal
        case .nonterminal: !frame.isRequiredOpening && !frame.isTerminal
        case .terminal: !frame.isRequiredOpening && frame.isTerminal
        }
    }
}
