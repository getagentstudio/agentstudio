import AgentStudioCLIStore
import AgentStudioProgrammaticControl
import Foundation

/// Call completion may retire only the app's handled prefix of this CLI file.
package struct CLIStoreCleanupHandler: Sendable {
    private let location: CleanupStoreLocation?
    private let now: @Sendable () -> Date
    private let migrationLockWaitBudget: @Sendable () -> Duration?
    private let diagnosticSink: @Sendable (CLIStoreFailure) -> Void

    package init(
        environment: [String: String],
        now: @escaping @Sendable () -> Date = { Date() },
        migrationLockWaitBudget: @escaping @Sendable () -> Duration? = { nil },
        diagnosticSink: @escaping @Sendable (CLIStoreFailure) -> Void = {
            CLIDiagnostics.record(.init(cleanupFailure: $0))
        }
    ) {
        location = CleanupStoreLocation(environment: environment)
        self.now = now
        self.migrationLockWaitBudget = migrationLockWaitBudget
        self.diagnosticSink = diagnosticSink
    }

    package func handle(readThrough: IPCCLIStoreReadThrough?) {
        guard let location else { return }
        let opened = CLIStore.openWriter(
            url: location.url, channel: location.channel, migrationLockWaitBudget: migrationLockWaitBudget)
        switch opened {
        case .failure(let failure): record(failure)
        case .success(let writer):
            guard let readThrough, writer.identity.storeID == readThrough.storeId else { return }
            if case .failure(let failure) = writer.purgeHandledOutbox(
                expectedStoreID: readThrough.storeId, through: readThrough.outbox, now: now())
            {
                record(failure)
            }
        }
    }

    private func record(_ failure: CLIStoreFailure) {
        diagnosticSink(failure)
    }
}

private struct CleanupStoreLocation: Sendable {
    let url: URL
    let channel: CLIStoreChannel
    init?(environment: [String: String]) {
        guard let path = environment["AGENTSTUDIO_CLI_STORE"], !path.isEmpty,
            let rawChannel = environment["AGENTSTUDIO_CLI_STORE_CHANNEL"],
            let channel = CLIStoreChannel(rawValue: rawChannel)
        else { return nil }
        url = URL(fileURLWithPath: path)
        self.channel = channel
    }
}
