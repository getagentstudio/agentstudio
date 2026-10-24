import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioSessions
import AgentStudioTestSupport
import AppKit
import Testing

@testable import AgentStudio
@testable import AgentStudioTerminal

extension RestoreForegroundLifecycleTests {
    @Test("watcher shutdown remains off MainActor through the actual App owner")
    func foregroundWatcherShutdownRecordsOffMain() async throws {
        let fixture = RestoreCostTraceTestFixture()
        defer { fixture.cleanup() }
        do {
            let delegate = AppDelegate()
            delegate.restoreForegroundExitWatcher = DarwinProcessExitWatcher(performanceTraceRecorder: fixture.recorder)
            await delegate.shutdownRestoreEvidenceOwners()
            let records = try await fixture.finish()
            let shutdown = try #require(records.first { $0.body == "performance.restore.foreground.watch" })
            #expect(shutdown.attributes.executions == 1)
            #expect(shutdown.attributes.mainThreadExecutions == 0)
            #expect(shutdown.attributes.mainThreadMilliseconds == 0)
            #expect(delegate.restoreForegroundExitWatcher == nil)
        } catch {
            try? await fixture.recorder.drain()
            throw error
        }
    }

    @Test("quit and activation forwards retain distinct measured MainActor allowances")
    func quitAndActivationForwardHaveSeparateCostRecords() async throws {
        let fixture = RestoreCostTraceTestFixture()
        defer { fixture.cleanup() }
        do {
            let delegate = AppDelegate()
            delegate.performanceTraceRecorder = fixture.recorder
            delegate.restoreForegroundTriggerSink = { _ in }
            delegate.applicationDidBecomeActive(Notification(name: NSApplication.didBecomeActiveNotification))
            #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateNow)
            let records = try await fixture.finish()
            #expect(
                Set(records.map(\.body)) == [
                    "performance.restore.allowance.activation_forward", "performance.restore.allowance.quit_forward",
                ])
            #expect(records.count == 2)
            for record in records {
                #expect(record.attributes.executions == 1)
                #expect(record.attributes.mainThreadExecutions == 1)
                #expect(record.attributes.mainThreadMilliseconds == record.attributes.elapsedMilliseconds)
            }
            delegate.restoreForegroundTriggerSink = nil
        } catch {
            try? await fixture.recorder.drain()
            throw error
        }
    }
}

extension RestoreForegroundLifecycleTests {
    @Test("persisted graph gathering measures its SQL slice off MainActor")
    func persistedGraphGatherRecordsOffMain() async throws {
        let trace = RestoreCostTraceTestFixture()
        defer { trace.cleanup() }
        do {
            let workspace = UUIDv7.generate()
            let fixture = try makeWorkspaceSQLiteBridgeFixture(workspaceId: workspace)
            let datastore = try preparedWorkspaceSQLiteDatastore(from: fixture.backend)
            _ = try await datastore.liveZmxSessionsByPane(
                workspaceId: workspace, performanceTraceRecorder: trace.recorder)
            let records = try await trace.finish()
            #expect(records.count == 1)
            let record = try #require(records.first)
            #expect(record.body == "performance.restore.foreground.gather")
            #expect(record.attributes.mainThreadExecutions == 0)
            #expect(record.attributes.mainThreadMilliseconds == 0)
        } catch {
            try? await trace.recorder.drain()
            throw error
        }
    }
}

extension RestoreForegroundLifecycleTests {
    @Test("the real no-main verdict records its synchronous off-main decision")
    func resumeDecisionRecordsOffMainSlice() async throws {
        let trace = RestoreCostTraceTestFixture()
        defer { trace.cleanup() }
        do {
            let input = ResumeEvidenceInput(
                paneId: UUIDv7.generate(), zmxSessionId: .generateUUIDv7(), coldEndedMain: nil,
                evidence: nil, preRestoreLook: nil, launchBootId: "restore-cost-boot", inventory: .complete([:]))
            let result = await SessionsResumeResolver(performanceTraceRecorder: trace.recorder).resumeEvidence(
                for: input)
            #expect(result == .knownExited)
            let records = try await trace.finish()
            #expect(records.count == 1)
            let record = try #require(records.first)
            #expect(record.body == "performance.restore.resume.decide")
            #expect(record.attributes.mainThreadExecutions == 0)
            #expect(record.attributes.mainThreadMilliseconds == 0)
        } catch {
            try? await trace.recorder.drain()
            throw error
        }
    }
}
