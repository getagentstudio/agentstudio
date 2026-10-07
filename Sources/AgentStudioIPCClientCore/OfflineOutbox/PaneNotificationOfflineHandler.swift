import AgentStudioCLIStore
import AgentStudioIPCTransport
import AgentStudioProgrammaticControl
import Foundation

extension IPCDescriptorClientFailure {
    package var permitsOfflineQueue: Bool {
        if disposition == .endpointUnavailableBeforeSubmission { return true }
        guard disposition == .notSubmitted else { return false }
        switch reason {
        case .authenticationTransport, .commandWrite, .endpointConnectFailed, .socketNotFound: return true
        default: return false
        }
    }
}

package enum PaneNotificationOfflineOutcome: Equatable, Sendable {
    case queued(reply: String)
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
    private let now: @Sendable () -> Date
    private let migrationLockWaitBudget: @Sendable () -> Duration?

    package init(
        environment: [String: String], maximumLineBytes: Int = IPCFramePolicy.maximumRequestFrameBytes,
        now: @escaping @Sendable () -> Date = { Date() },
        migrationLockWaitBudget: @escaping @Sendable () -> Duration? = { nil }
    ) {
        location = PaneNotificationOutboxLocation(environment: environment)
        self.maximumLineBytes = maximumLineBytes
        self.now = now
        self.migrationLockWaitBudget = migrationLockWaitBudget
    }

    package func handleUnreachableApp(
        invocation: IPCDescriptorInvocation,
        requestLine: () throws -> String
    ) throws -> PaneNotificationOfflineOutcome {
        guard invocation.descriptor.metadata.name == "pane.message.send",
            invocation.descriptor.metadata.offlineEligibility == .noticeOnly, let location
        else { return .notQueued }
        let payload = try requestLine()
        guard payload.utf8.count <= maximumLineBytes,
            let request = try? JSONRPCCodec.decodeRequest(payload, maxBytes: maximumLineBytes),
            request.method == "pane.message.send", let parameters = request.params,
            let encoded = try? JSONEncoder().encode(parameters),
            let notice = try? JSONDecoder().decode(IPCPaneMessageSendParams.self, from: encoded),
            case .notice = notice.shape,
            notice.handle == "self" || notice.handle == location.paneID.uuidString
        else { return .notQueued }
        let store = try CLIStore.openWriter(
            url: location.storeURL, channel: location.channel, migrationLockWaitBudget: migrationLockWaitBudget
        ).get()
        defer { try? store.close() }
        _ = try store.appendNotice(
            paneID: location.paneID, messageID: notice.messageId, payloadJSON: payload, createdAt: now()
        ).get()
        return .queued(reply: "notify queued")
    }
}
