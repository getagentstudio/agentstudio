import AgentStudioCLIStore
import AgentStudioProgrammaticControl
import Foundation
import os

/// Controlled reason classes are persisted without provider-visible output or payloads.
enum CLIDiagnostics {
    enum Reason: String, Sendable {
        case providerCommandFailed = "provider_command_failed"
        case storeUnavailable = "store_unavailable"
        case storeBusy = "store_busy"
        case storeSuperseded = "store_superseded"
        case storeChannelMismatch = "store_channel_mismatch"
        case storeInvalidIdentity = "store_invalid_identity"
        case storeReadOnly = "store_read_only"

        init(cleanupFailure: CLIStoreFailure) {
            switch cleanupFailure {
            case .unavailable: self = .storeUnavailable
            case .busy: self = .storeBusy
            case .superseded: self = .storeSuperseded
            case .channelMismatch: self = .storeChannelMismatch
            case .invalidIdentity: self = .storeInvalidIdentity
            case .readOnly: self = .storeReadOnly
            }
        }
    }

    private static let logger = Logger(subsystem: "com.agentstudio.cli", category: "diagnostics")

    static func recordHook(_ label: String, environment: [String: String]) {
        let reason = IPCAgentConnectionRefusalReason(rawValue: label) ?? .undecodablePayload
        let pane = environment["AGENTSTUDIO_PANE_ID"].flatMap(UUID.init(uuidString:))?.uuidString ?? "unknown"
        logger.error("pane=\(pane, privacy: .public) reason=\(reason.rawValue, privacy: .public)")
    }

    static func record(_ reason: Reason) {
        logger.error("\(reason.rawValue, privacy: .public)")
    }
}
