import AgentStudioCLIStore
import AgentStudioIPCTransport
import AgentStudioPrimitives
import AgentStudioProgrammaticControl
import AgentStudioTestHarness
import Foundation
import GRDB
import SQLite3
import Synchronization
import Testing

@testable import AgentStudioIPCClientCore

@Suite("Lifecycle writes share the hook deadline")
struct ProviderLifecycleBudgetTests {
    @Test("input and failure spending the deadline cannot append", arguments: [false, true])
    func exhaustedBudgetDoesNotWrite(exhaust: Bool) async throws {
        let observed = try await valueFromDedicatedThread {
            let fixture = try LifecycleHookFileFixture()
            defer { fixture.remove() }
            let timing = LifecycleDeadlineTiming()
            let deadline = CallDeadline(limit: .milliseconds(250), timing: timing)
            let diagnostics = Mutex<[String]>([])
            let code = ProviderHookInvocation.runCodexHook(
                .init(
                    eventName: "SessionEnd", environment: fixture.environment,
                    standardInput: { fixture.payload(eventName: "SessionEnd") }, correlationIdProvider: UUIDv7.generate,
                    delivery: .init(
                        deliver: { _, _, _ in
                            if exhaust { timing.advance(by: .milliseconds(250)) }
                            throw IPCDescriptorClientFailure(disposition: .notSubmitted, reason: .commandWrite)
                        }, recordRefusal: { _, _, _ in }, reportStatus: { _, _, _ in }),
                    standardErrorSink: { line in diagnostics.withLock { $0.append(line) } }, deadline: deadline))
            let exists = FileManager.default.fileExists(atPath: fixture.storeURL.path)
            let count: Int
            if exists {
                let reader = try CLIStore.openReader(url: fixture.storeURL, expectedChannel: .debug).get()
                defer { try? reader.close() }
                count = try reader.readOutbox(after: 0).get().entries.count
            } else {
                count = 0
            }
            return LifecycleBudgetObservation(
                exitCode: code, storeExists: exists, entryCount: count,
                diagnostics: diagnostics.withLock { $0 }, remainingBudget: deadline.remainingBudget,
                unexpectedWaitCount: timing.unexpectedWaitCount)
        }
        #expect(observed.exitCode == 0)
        #expect(observed.unexpectedWaitCount == 0)
        if exhaust {
            #expect(!observed.storeExists)
            #expect(observed.entryCount == 0)
            #expect(observed.diagnostics.contains("deadlineExceeded"))
        } else {
            #expect(observed.entryCount == 1)
        }

    }

    @Test("a real busy SQLite writer exhausts the controlled hook budget without a row")
    func busyWriterExhaustsBudget() async throws {
        let observed = try await valueFromDedicatedThread {
            let fixture = try LifecycleHookFileFixture()
            defer { fixture.remove() }
            let lockOwner = try CLIStore.openWriter(url: fixture.storeURL, channel: .debug).get()
            defer { try? lockOwner.close() }
            let timing = LifecycleDeadlineTiming()
            let deadline = CallDeadline(limit: .milliseconds(250), timing: timing)
            let writer = try CLIStore.openWriter(
                url: fixture.storeURL, channel: .debug, migrationLockWaitBudget: { deadline.remainingBudget },
                prepareConnection: { database in
                    let connection = database.sqliteConnection
                    database.trace { event in
                        guard case .statement(let statement) = event, statement.sql.hasPrefix("BEGIN IMMEDIATE") else {
                            return
                        }
                        sqlite3_busy_handler(
                            connection, lifecycleBudgetBusyCallback, Unmanaged.passUnretained(timing).toOpaque())
                    }
                }
            ).get()
            defer { try? writer.close() }
            let blocker = try DatabaseQueue(path: fixture.storeURL.path)
            defer { try? blocker.close() }
            let diagnostics = Mutex<[String]>([])
            let codes = Mutex<Int32?>(nil)
            try blocker.writeWithoutTransaction { database in
                try database.inTransaction(.immediate) {
                    let code = ProviderHookInvocation.runCodexHook(
                        .init(
                            eventName: "SessionEnd", environment: fixture.environment,
                            standardInput: { fixture.payload(eventName: "SessionEnd") },
                            correlationIdProvider: UUIDv7.generate,
                            delivery: .init(
                                deliver: { _, _, _ in
                                    throw IPCDescriptorClientFailure(disposition: .notSubmitted, reason: .commandWrite)
                                },
                                recordRefusal: { _, _, _ in }, reportStatus: { _, _, _ in }),
                            standardErrorSink: { label in diagnostics.withLock { $0.append(label) } },
                            deadline: deadline,
                            lifecycleWriter: .init { params, capturedAt, _ in
                                guard let payload = String(data: try JSONEncoder().encode(params), encoding: .utf8)
                                else { throw LifecycleFixtureFailure.invalidUTF8 }
                                _ = try writer.appendSessionLifecycle(
                                    paneID: fixture.paneID, messageID: UUIDv7.generate(),
                                    payloadJSON: payload, reportedAt: capturedAt
                                ).get()
                            }))
                    codes.withLock { $0 = code }
                    return .rollback
                }
            }
            guard let code = codes.withLock({ $0 }) else { throw LifecycleFixtureFailure.hookDidNotReturn }
            return LifecycleBudgetObservation(
                exitCode: code, storeExists: true,
                entryCount: try lockOwner.readOutbox(after: 0).get().entries.count,
                diagnostics: diagnostics.withLock { $0 }, remainingBudget: deadline.remainingBudget,
                unexpectedWaitCount: timing.unexpectedWaitCount)
        }
        #expect(observed.exitCode == 0)
        #expect(observed.unexpectedWaitCount == 0)
        #expect(observed.remainingBudget == .zero)
        #expect(observed.diagnostics.contains("deadlineExceeded"))
        #expect(observed.entryCount == 0)

    }
}

final class LifecycleDeadlineTiming: CallDeadlineTiming, Sendable {
    private let origin = ContinuousClock.now
    private let elapsed = Mutex<Duration>(.zero)
    private let unexpectedWaits = Mutex(0)
    var unexpectedWaitCount: Int { unexpectedWaits.withLock { $0 } }
    func now() -> ContinuousClock.Instant { origin.advanced(by: elapsed.withLock { $0 }) }
    func advance(by duration: Duration) { elapsed.withLock { $0 += duration } }
    func waitForReadiness(fileDescriptor: Int32, events: Int16, timeout: Duration) throws -> CallDeadlineReadiness {
        unexpectedWaits.withLock { $0 += 1 }
        throw LifecycleDeadlineFailure.unexpectedSocketWait
    }
}

private func lifecycleBudgetBusyCallback(context: UnsafeMutableRawPointer?, attempts: Int32) -> Int32 {
    guard let context else { return 0 }
    Unmanaged<LifecycleDeadlineTiming>.fromOpaque(context).takeUnretainedValue().advance(by: .milliseconds(250))
    return 0
}

private enum LifecycleDeadlineFailure: Error { case unexpectedSocketWait }

private struct LifecycleBudgetObservation: Sendable {
    let exitCode: Int32
    let storeExists: Bool
    let entryCount: Int
    let diagnostics: [String]
    let remainingBudget: Duration
    let unexpectedWaitCount: Int
}
