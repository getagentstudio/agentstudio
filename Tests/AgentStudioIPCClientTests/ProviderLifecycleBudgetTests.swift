import AgentStudioCLIStore
import AgentStudioIPCTransport
import AgentStudioPrimitives
import AgentStudioProgrammaticControl
import AgentStudioTestHarness
import Foundation
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

    @Test("a lifecycle writer exhausting the deadline fails open without a row or socket wait")
    func failedLifecycleWriterExhaustsBudget() async throws {
        let observed = try await valueFromDedicatedThread {
            let fixture = try LifecycleHookFileFixture()
            defer { fixture.remove() }
            let store = try CLIStore.openWriter(url: fixture.storeURL, channel: .debug).get()
            defer { try? store.close() }
            let timing = LifecycleDeadlineTiming()
            let deadline = CallDeadline(limit: .milliseconds(250), timing: timing)
            let diagnostics = Mutex<[String]>([])
            let writerCalls = Mutex(0)
            let code = ProviderHookInvocation.runCodexHook(
                .init(
                    eventName: "SessionEnd", environment: fixture.environment,
                    standardInput: { fixture.payload(eventName: "SessionEnd") },
                    correlationIdProvider: UUIDv7.generate,
                    delivery: .init(
                        deliver: { _, _, _ in
                            throw IPCDescriptorClientFailure(disposition: .notSubmitted, reason: .commandWrite)
                        }, recordRefusal: { _, _, _ in }, reportStatus: { _, _, _ in }),
                    standardErrorSink: { line in diagnostics.withLock { $0.append(line) } },
                    deadline: deadline,
                    lifecycleWriter: .init { _, _, _ in
                        writerCalls.withLock { $0 += 1 }
                        timing.advance(by: .milliseconds(250))
                        // SQLite busy (5), pinned by the real held-lock test in the store target.
                        throw CLIStoreFailure.busy(extendedResultCode: 5, stage: .append)
                    }))
            return (
                result: LifecycleBudgetObservation(
                    exitCode: code, storeExists: true,
                    entryCount: try store.readOutbox(after: 0).get().entries.count,
                    diagnostics: diagnostics.withLock { $0 }, remainingBudget: deadline.remainingBudget,
                    unexpectedWaitCount: timing.unexpectedWaitCount),
                writerCalls: writerCalls.withLock { $0 }
            )
        }
        #expect(observed.writerCalls == 1)
        #expect(observed.result.exitCode == 0)
        #expect(observed.result.unexpectedWaitCount == 0)
        #expect(observed.result.remainingBudget == .zero)
        #expect(observed.result.diagnostics.contains("deadlineExceeded"))
        #expect(observed.result.entryCount == 0)
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

private enum LifecycleDeadlineFailure: Error { case unexpectedSocketWait }

private struct LifecycleBudgetObservation: Sendable {
    let exitCode: Int32
    let storeExists: Bool
    let entryCount: Int
    let diagnostics: [String]
    let remainingBudget: Duration
    let unexpectedWaitCount: Int
}
