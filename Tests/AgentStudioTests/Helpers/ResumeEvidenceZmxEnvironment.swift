import AgentStudioInfrastructure
import AgentStudioTestHarness
import Darwin
import Dispatch
import Foundation
import Synchronization
import Testing

@testable import AgentStudioCore
@testable import AgentStudioTerminal
@testable import AgentStudioTestSupport

/// S5 owns known session names and attach clients before starting them. Startup
/// is acknowledged by the child's protocol; teardown joins native exit events.
/// The older shared harness's settlement and cleanup polling are never called.
final class ResumeEvidenceZmxEnvironment: Sendable {
    private struct Ownership: Sendable {
        var sessions: Set<ZmxSessionID> = []
        var clients: [ResumeZmxProcessDriver] = []
        var jobControlChildren: [ZmxProcessIncarnation] = []
    }
    let harness: ZmxTestHarness
    let backend: ZmxBackend
    private let ownership = Mutex(Ownership())

    private init(harness: ZmxTestHarness, backend: ZmxBackend) {
        self.harness = harness
        self.backend = backend
    }

    static func make() async throws -> ResumeEvidenceZmxEnvironment {
        let harness = await ZmxTestHarness()
        let backend = try #require(harness.createBackend(), "S5 requires the real zmx executable")
        let available = await backend.isAvailable
        try #require(available)
        try FileManager.default.createDirectory(atPath: harness.zmxDir, withIntermediateDirectories: true)
        return Self(harness: harness, backend: backend)
    }

    func retainSession(_ sessionID: ZmxSessionID) {
        ownership.withLock { _ = $0.sessions.insert(sessionID) }
    }

    func launchSession(_ sessionID: ZmxSessionID, arguments: [String]) async throws -> ResumeZmxProcessDriver {
        retainSession(sessionID)
        print("R3_ZMX_OWNED root=\(harness.zmxDir) session=\(sessionID.rawValue) source=\(#filePath)")
        let zmxPath = try #require(harness.zmxPath)
        var environment = ZmxTestHarness.hermeticChildEnvironment(
            zmxDir: harness.zmxDir, scratchHomeDirectory: harness.scratchHomeDirectory)
        environment["ZMX_DIR"] = harness.zmxDir
        environment["ZMX_SESSION"] = ""
        environment["ZMX_SESSION_PREFIX"] = ""
        let words = [zmxPath, "attach", sessionID.rawValue] + arguments
        let command = words.map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }
            .joined(separator: " ")
        let client = try await ResumeZmxProcessDriver.launch(command: command, environment: environment)
        retainClient(client)
        return client
    }

    func retainClient(_ client: ResumeZmxProcessDriver) {
        ownership.withLock { $0.clients.append(client) }
    }

    func retainJobControlChild(_ child: ZmxProcessIncarnation) {
        ownership.withLock { $0.jobControlChildren.append(child) }
    }

    func killSession(_ sessionID: ZmxSessionID) async throws {
        try #require(
            ownership.withLock { $0.sessions.contains(sessionID) }, "only S5-owned session names may be killed")
        guard let encoded = try await backend.observeSessionIdentity(sessionID) else { return }
        let identity = try ZmxSessionIdentity.decode(encoded)
        let zmxPath = try #require(harness.zmxPath)
        var environment = ZmxTestHarness.hermeticChildEnvironment(
            zmxDir: harness.zmxDir, scratchHomeDirectory: harness.scratchHomeDirectory)
        environment["ZMX_DIR"] = harness.zmxDir
        environment["ZMX_SESSION"] = ""
        let killEnvironment = environment
        try await joinExit(of: identity.daemon) {
            let output = try await runProcessToExit(
                executableURL: URL(fileURLWithPath: zmxPath),
                arguments: ["kill", sessionID.rawValue], environment: killEnvironment)
            try #require(output.terminationStatus == 0, "the owned daemon must accept its kill command")
        }
    }

    private func joinExit(
        of process: ZmxProcessIncarnation, terminate: @Sendable () async throws -> Void
    ) async throws {
        // Reuse ColdStartObserver's native primitive; no foreground-following owner remains.
        let registered = HeldStep<Void>("owned zmx exit source registration")
        let exited = HeldStep<Void>("owned zmx daemon NOTE_EXIT")
        let cancelled = HeldStep<Void>("owned zmx exit source cancellation")
        let source = makeDefaultColdStartProcessWatchSource(
            identifier: process.pid, eventMask: .exit,
            queue: DispatchQueue(label: "resume-owned-daemon-exit"))
        source.setRegistrationHandler { try? registered.arriveBlocking(()) }
        source.setEventHandler { didExit in if didExit { try? exited.arriveBlocking(()) } }
        source.setCancelHandler { try? cancelled.arriveBlocking(()) }
        source.resume()
        do {
            _ = try await registered.firstArrival()
            registered.release()
            switch DarwinColdStartObserverSyscalls().leaderState(of: process) {
            case .exited: break
            case .unverifiable(let failure): throw failure
            case .sameIncarnationAlive:
                try await terminate()
                _ = try await exited.firstArrival()
            }
            exited.release()
            source.cancel()
            _ = try await cancelled.firstArrival()
            cancelled.release()
        } catch {
            registered.retire()
            exited.retire()
            source.cancel()
            _ = try? await cancelled.firstArrival()
            cancelled.release()
            throw error
        }
    }

    func close() async throws {
        let owned = ownership.withLock { $0 }
        var failure: (any Error)?
        for sessionID in owned.sessions.sorted(by: { $0.rawValue < $1.rawValue }) {
            do { try await killSession(sessionID) } catch { if failure == nil { failure = error } }
        }
        for child in owned.jobControlChildren {
            do {
                switch DarwinColdStartObserverSyscalls().leaderState(of: child) {
                case .exited: continue
                case .unverifiable(let failure): throw failure
                case .sameIncarnationAlive:
                    try await joinExit(of: child) {
                        guard Darwin.kill(child.pid, SIGKILL) == 0 || errno == ESRCH else {
                            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                        }
                    }
                }
            } catch { if failure == nil { failure = error } }
        }
        for client in owned.clients {
            do { try await client.stop() } catch { if failure == nil { failure = error } }
        }
        // Exactly one verification, after correlated process exits; never a retry.
        let inventory = await backend.discoverSessionInventory()
        if inventory != .complete([:]), failure == nil {
            failure = ResumeEvidenceCleanupFailure.remainingInventory(inventory)
        }
        if let failure { throw failure }  // Retain the scratch root for diagnosis.
        try FileManager.default.removeItem(atPath: harness.zmxDir)
        try FileManager.default.removeItem(atPath: harness.scratchHomeDirectory)
    }
}

private enum ResumeEvidenceCleanupFailure: Error {
    case remainingInventory(ZmxSessionInventory)
}

extension E2ESerializedTests.ZmxE2ETests {
    func withResumeEvidenceBackend(
        _ body: @escaping @Sendable (ResumeEvidenceZmxEnvironment) async throws -> Void
    ) async throws {
        let environment = try await ResumeEvidenceZmxEnvironment.make()
        var bodyError: (any Error)?
        do { try await body(environment) } catch { bodyError = error }
        do { try await environment.close() } catch {
            if bodyError == nil { throw error }
            Issue.record("S5 owned-process cleanup also failed: \(error)")
        }
        if let bodyError { throw bodyError }
    }
}
