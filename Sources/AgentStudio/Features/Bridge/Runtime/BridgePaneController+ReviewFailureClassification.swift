import Foundation

@MainActor
extension BridgePaneController {
    static func reviewPackageLoadFailureSummary(for error: Error, stage: String) -> String {
        if error is BridgeReviewConstructionProgressFailure { return "reviewBuildProgressDeadline" }
        let prefix = "loadFailed:\(stage)"
        if let providerFailure = error as? BridgeProviderFailure {
            switch providerFailure {
            case .providerUnavailable:
                return "\(prefix):providerUnavailable"
            case .sourceCapacityDeferred:
                return "\(prefix):sourceCapacityDeferred"
            case .unavailableEndpoint:
                return "\(prefix):unavailableEndpoint"
            case .missingContent:
                return "\(prefix):missingContent"
            case .contentHashMismatch:
                return "\(prefix):contentHashMismatch"
            case .oversizedContent:
                return "\(prefix):oversizedContent"
            case .binaryContent:
                return "\(prefix):binaryContent"
            case .staleReviewGeneration:
                return "\(prefix):staleReviewGeneration"
            case .providerFailed(let message):
                return "\(prefix):providerFailed:\(providerFailureReason(from: message))"
            }
        }
        if error is CancellationError {
            return "\(prefix):cancelled"
        }
        return "\(prefix):\(String(describing: type(of: error)))"
    }

    static func providerFailureReason(from message: String) -> String {
        let normalizedMessage = message.lowercased()
        if normalizedMessage.hasPrefix("gitdataplane:") {
            let prefixLength = "gitDataPlane:".count
            let suffix = String(message.dropFirst(prefixLength))
            return "git.\(suffix)"
        }
        if normalizedMessage.contains("invalid bridge review content handle") {
            return "invalidContentHandle"
        }
        if normalizedMessage.contains("invalid bridge review content lease set") {
            return "invalidContentLeaseSet"
        }
        if normalizedMessage.contains("stale bridge review content lifetime") {
            return "staleContentLifetime"
        }
        if normalizedMessage.contains("head")
            && (normalizedMessage.contains("not found") || normalizedMessage.contains("revspec"))
        {
            return "unresolvedHEAD"
        }
        if normalizedMessage.contains("data plane read timed out")
            || normalizedMessage.contains("timed out")
            || normalizedMessage.contains("timeouterror")
        {
            return "gitDataPlaneTimeout"
        }
        if normalizedMessage.contains("content too large") || normalizedMessage.contains("too large") {
            return "contentTooLarge"
        }
        if normalizedMessage.contains("path escapes") {
            return "pathEscapesRepository"
        }
        if normalizedMessage.contains("tree reads") {
            return "unsupportedTreeRead"
        }
        if normalizedMessage.contains("checkpoint endpoint") {
            return "unsupportedCheckpointEndpoint"
        }
        if normalizedMessage.contains("invalid") {
            return "invalidProviderPayload"
        }
        if normalizedMessage.contains("not found") {
            return "notFound"
        }
        return "providerError"
    }
}
