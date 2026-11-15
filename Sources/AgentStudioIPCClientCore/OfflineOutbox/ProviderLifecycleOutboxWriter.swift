import AgentStudioCLIStore
import AgentStudioIPCTransport
import AgentStudioPrimitives
import AgentStudioProgrammaticControl
import Foundation

/// The fake replaces persistence only in write-policy tests; integration uses this live writer.
package struct ProviderLifecycleOutboxWriter: Sendable {
    package let write: @Sendable (IPCSessionEventParams, Date, CallDeadline) throws -> Void

    package init(write: @escaping @Sendable (IPCSessionEventParams, Date, CallDeadline) throws -> Void) {
        self.write = write
    }

    static func live(environment: [String: String]) -> Self {
        .init { params, reportedAt, deadline in
            guard let paneText = environment["AGENTSTUDIO_PANE_ID"], let paneID = UUID(uuidString: paneText),
                let path = environment["AGENTSTUDIO_CLI_STORE"], !path.isEmpty,
                let channelText = environment["AGENTSTUDIO_CLI_STORE_CHANNEL"],
                let channel = CLIStoreChannel(rawValue: channelText)
            else { return }
            guard deadline.remainingBudget > .zero else {
                throw CLIStoreFailure.busy(extendedResultCode: nil, stage: .append)
            }
            let data = try JSONEncoder().encode(params)
            guard data.count <= IPCFramePolicy.maximumRequestFrameBytes,
                let payload = String(data: data, encoding: .utf8)
            else { throw CLIStoreFailure.unavailable }
            let writer = try CLIStore.openWriter(
                url: URL(fileURLWithPath: path), channel: channel,
                migrationLockWaitBudget: { deadline.remainingBudget }
            ).get()
            defer { try? writer.close() }
            _ = try writer.appendSessionLifecycle(
                paneID: paneID, messageID: UUIDv7.generate(), payloadJSON: payload, reportedAt: reportedAt
            ).get()
        }
    }

    static func permits(_ params: IPCSessionEventParams) -> Bool {
        guard params.provider.identifier == "claude-code" || params.provider.identifier == "codex" else { return false }
        return params.event.name == .sessionStart || params.event.name == .sessionEnd
    }
}
