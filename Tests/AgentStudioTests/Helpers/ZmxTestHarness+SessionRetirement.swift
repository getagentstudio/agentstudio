import AgentStudioTestHarness
import Darwin
import Foundation

@testable import AgentStudioCore

enum ZmxSessionRetirementFailure: Error, Equatable {
    case daemonExitedWithSocket(sessionID: String, daemonPID: Int32)
}

private enum SessionRetirementEvent: Sendable {
    case registered
    case socketChanged
    case daemonExited
}

extension ZmxTestHarness {
    /// Arm both watches before requesting retirement. A dead daemon cannot
    /// remove a remaining socket; report that outcome instead of waiting forever.
    func observeSessionRetirement(
        sessionID: String, daemon: ZmxProcessIncarnation,
        retire: @Sendable () async throws -> Void
    ) async throws {
        let socketPath = sessionSocketPath(for: sessionID)
        let directoryDescriptor = open(zmxDir, O_EVTONLY)
        guard directoryDescriptor >= 0 else {
            throw SessionSettlementError.sessionDirectoryUnwatchable(path: zmxDir, errno: errno)
        }
        let (events, continuation) = AsyncStream.makeStream(
            of: SessionRetirementEvent.self, bufferingPolicy: .unbounded)
        let directoryStopped = DedicatedThreadCompletion()
        let processStopped = DedicatedThreadCompletion()
        let queue = DispatchQueue(label: "zmx-session-retirement")
        let directorySource = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: directoryDescriptor, eventMask: [.write, .rename, .delete], queue: queue)
        let processSource = DispatchSource.makeProcessSource(identifier: daemon.pid, eventMask: .exit, queue: queue)
        directorySource.setRegistrationHandler { continuation.yield(.registered) }
        processSource.setRegistrationHandler { continuation.yield(.registered) }
        directorySource.setEventHandler { continuation.yield(.socketChanged) }
        processSource.setEventHandler {
            if processSource.data.contains(.exit) { continuation.yield(.daemonExited) }
        }
        directorySource.setCancelHandler {
            close(directoryDescriptor)
            directoryStopped.finish()
        }
        processSource.setCancelHandler { processStopped.finish() }
        directorySource.resume()
        processSource.resume()

        var failure: (any Error)?
        do {
            var registrations = 0
            var daemonExited = false
            var retirementRequested = false
            for await event in events {
                switch event {
                case .registered: registrations += 1
                case .daemonExited: daemonExited = true
                case .socketChanged: break
                }
                guard registrations == 2 else { continue }
                // Register-then-check also covers unlink/exit before registration.
                if !FileManager.default.fileExists(atPath: socketPath) { break }
                if !daemonExited {
                    switch DarwinColdStartObserverSyscalls().leaderState(of: daemon) {
                    case .exited: daemonExited = true
                    case .unverifiable(let failure): throw failure
                    case .sameIncarnationAlive: break
                    }
                }
                if daemonExited {
                    // Unlink may have happened between the earlier check and
                    // confirming exit. Absence on exit is ordinary success.
                    if !FileManager.default.fileExists(atPath: socketPath) { break }
                    throw ZmxSessionRetirementFailure.daemonExitedWithSocket(
                        sessionID: sessionID, daemonPID: daemon.pid)
                }
                if !retirementRequested {
                    retirementRequested = true
                    try await retire()
                }
            }
            try Task.checkCancellation()
        } catch {
            failure = error
        }
        directorySource.cancel()
        processSource.cancel()
        continuation.finish()
        // Cancellation handlers own descriptor closure; join them even if the
        // observing task was cancelled or the retirement request threw.
        await directoryStopped.wait()
        await processStopped.wait()
        if let failure { throw failure }
    }
}
