import AgentStudioCLIStore
import AgentStudioIPCTransport
import AgentStudioProgrammaticControl
import Foundation

extension IPCDescriptorClientFailure {
    package var permitsOfflineQueue: Bool { disposition == .endpointUnavailableBeforeSubmission }
}

package enum PaneNotificationOfflineOutcome: Equatable, Sendable {
    case queued(reply: String)
    case clearUnavailableWhileOffline
    case notQueued
}

private struct PaneNotificationOutboxLocation: Sendable {
    let storeURL: URL
    let channel: CLIStoreChannel
    let paneID: UUID

    init?(environment: [String: String]) {
        guard let path = environment["AGENTSTUDIO_CLI_STORE"], !path.isEmpty,
            let channelValue = environment["AGENTSTUDIO_CLI_STORE_CHANNEL"],
            let channel = CLIStoreChannel(rawValue: channelValue),
            let paneValue = environment["AGENTSTUDIO_PANE_ID"], let paneID = UUID(uuidString: paneValue)
        else { return nil }
        storeURL = URL(fileURLWithPath: path)
        self.channel = channel
        self.paneID = paneID
    }
}

/// Only a never-reached app permits this route. Eligibility and queued copy
/// still come from the descriptor; the durable acknowledgment now is SQLite.
package struct PaneNotificationOfflineHandler: Sendable {
    private let location: PaneNotificationOutboxLocation?
    private let maximumLineBytes: Int

    package init(environment: [String: String], maximumLineBytes: Int = IPCFramePolicy.maximumRequestFrameBytes) {
        location = PaneNotificationOutboxLocation(environment: environment)
        self.maximumLineBytes = maximumLineBytes
    }

    package func handleUnreachableApp(
        invocation: IPCDescriptorInvocation,
        requestLine: () throws -> String
    ) throws -> PaneNotificationOfflineOutcome {
        guard case .model(let presentation) = invocation.presentation else { return .notQueued }
        guard presentation.isOfflineEligible else {
            return presentation.variant == .needsYouClear ? .clearUnavailableWhileOffline : .notQueued
        }
        guard let reply = presentation.queuedReply, let location else { return .notQueued }
        let payload = try requestLine()
        guard payload.utf8.count <= maximumLineBytes,
            let request = try? JSONRPCCodec.decodeRequest(payload, maxBytes: maximumLineBytes),
            case .object(let parameters)? = request.params,
            case .string(let correlation)? = parameters["correlationId"],
            let messageID = UUID(uuidString: correlation)
        else { throw CLIStoreFailure.unavailable }
        let store = try CLIStore.openWriter(url: location.storeURL, channel: location.channel).get()
        _ = try store.appendNotice(
            paneID: location.paneID, messageID: messageID, payloadJSON: payload, createdAt: Date()
        ).get()
        return .queued(reply: reply)
    }
}
