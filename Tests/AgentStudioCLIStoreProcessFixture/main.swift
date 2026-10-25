import AgentStudioCLIStore
import AgentStudioIPCClientCore
import AgentStudioIPCTransport
import AgentStudioPrimitives
import AgentStudioProgrammaticControl
import Darwin
import Foundation
import Synchronization

/// A real second CLI writer process, without linking the app or its runtime.
@main
struct CLIStoreProcessFixture {
    static func main() throws {
        let arguments = CommandLine.arguments
        let lifecycle = arguments.count >= 7 && arguments[3] == "--lifecycle"
        guard arguments.count == 3 || (lifecycle && (arguments.count == 7 || arguments.count == 8)),
            let paneID = UUID(uuidString: arguments[2])
        else {
            Darwin.exit(64)
        }
        let opened = CLIStore.openWriter(
            url: URL(fileURLWithPath: CommandLine.arguments[1]), channel: .debug
        )
        if case .failure(.busy(let extendedResultCode, let stage)) = opened {
            let codeText = extendedResultCode.map { String($0) } ?? "none"
            let diagnostic = "CLI store busy: stage=\(stage.rawValue); extendedResultCode=\(codeText)\n"
            FileHandle.standardError.write(Data(diagnostic.utf8))
        }
        let store = try opened.get()
        defer { try? store.close() }
        if lifecycle {
            try writeLifecycle(arguments: arguments, paneID: paneID, store: store)
            return
        }
        // A busy writer may fail open. Report every successful id and every
        // busy disposition; the parent proves precisely the committed effects.
        for _ in 0..<16 {
            let outcome = store.appendNotice(
                paneID: paneID, messageID: UUIDv7.generate(), payloadJSON: #"{"method":"session.message"}"#,
                createdAt: Date(timeIntervalSince1970: 1_700_000_000))
            switch outcome {
            case .success(let entry):
                print(entry.id)
            case .failure(.busy):
                print("busy")
            case .failure(let failure):
                throw failure
            }
        }
    }
    private static func writeLifecycle(arguments: [String], paneID: UUID, store: CLIStore) throws {
        guard let event = IPCSessionEventName(rawValue: arguments[5]),
            let seconds = Double(arguments[6]), event == .sessionStart || event == .sessionEnd
        else { Darwin.exit(64) }
        let capturedAt = Date(timeIntervalSince1970: seconds)
        let eventName = event == .sessionStart ? "SessionStart" : "SessionEnd"
        let input = try JSONSerialization.data(withJSONObject: [
            "session_id": arguments[4], "hook_event_name": eventName,
        ])
        let committedId = Mutex<Int64?>(nil)
        let socket = URL(fileURLWithPath: "/tmp").appending(path: "r3-hook-missing-\(UUIDv7.generate()).sock")
        guard !FileManager.default.fileExists(atPath: socket.path) else { throw CLIStoreFailure.unavailable }
        let code = ProviderHookInvocation.runCodexHook(
            .init(
                eventName: eventName,
                environment: [
                    "AGENTSTUDIO_PANE_ID": paneID.uuidString, "AGENTSTUDIO_PANE_TOKEN": "fixture-token",
                    "AGENTSTUDIO_IPC_SOCKET": socket.path,
                ],
                standardInput: { input }, correlationIdProvider: UUIDv7.generate,
                delivery: .liveIPC(exampleIdentifierProvider: UUIDv7.generate),
                standardErrorSink: { _ in },
                deadline: CallDeadline(limit: .seconds(2), timing: FrozenLifecycleDeadline()),
                wallNow: { capturedAt },
                lifecycleWriter: .init { params, reportedAt, _ in
                    if arguments.count == 8 {
                        guard arguments[7] == "--hold" else { Darwin.exit(64) }
                        FileHandle.standardOutput.write(Data("ready\n".utf8))
                        guard try FileHandle.standardInput.read(upToCount: 1) == Data([1]) else { Darwin.exit(65) }
                    }
                    guard let payload = String(data: try JSONEncoder().encode(params), encoding: .utf8) else {
                        throw CLIStoreFailure.unavailable
                    }
                    let entry = try store.appendSessionLifecycle(
                        paneID: paneID, messageID: UUIDv7.generate(), payloadJSON: payload, reportedAt: reportedAt
                    ).get()
                    committedId.withLock { $0 = entry.id }
                }))
        guard code == 0, let id = committedId.withLock({ $0 }) else { Darwin.exit(66) }
        print(id)
    }

}

/// Freezes the hook's budget while the parent controls a causal pre-append hold.
private struct FrozenLifecycleDeadline: CallDeadlineTiming {
    private let instant = ContinuousClock.now
    func now() -> ContinuousClock.Instant { instant }
    func waitForReadiness(fileDescriptor: Int32, events: Int16, timeout: Duration) throws -> CallDeadlineReadiness {
        throw CLIStoreFailure.unavailable
    }
}
