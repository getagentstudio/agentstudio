import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioTestHarness
import Foundation
import GRDB
import Testing

@testable import AgentStudio
@testable import AgentStudioCLIStore
@testable import AgentStudioSessions
@testable import AgentStudioTerminal

@MainActor
@Suite("Closed-app read outcomes and history", .serialized)
struct CLILifecycleReadinessTests {
    @Test("readiness expiring before IPC is ready does not skip warm-pane import")
    func expiredReadinessStillImportsWarmEnd() async throws {
        try await withPaneCLIOutboxDrainHarness { harness in
            let pane = UUIDv7.generate()
            let session = UUIDv7.generate().uuidString
            try await harness.bindLifecycleMain(pane: pane, session: session)
            try await harness.appendLifecycle(pane: pane, session: session, event: .sessionEnd, at: 2)
            let readiness = RestoreResumeReadiness(clock: harness.clock, deadline: .zero)
            #expect(await readiness.wait(paneId: pane) == .unavailable)
            await harness.drainForLaunch(readiness: readiness, clock: harness.clock)
            #expect(try await harness.lifecycleContext(pane: pane).currentBinding?.status == .ended)
            #expect(await readiness.wait(paneId: pane) == .unavailable)
            await readiness.shutdown()
        }
    }

    @Test("only a genuinely missing first-use store is verified empty")
    func missingAndUnreadableAreDistinct() async throws {
        try await withPaneCLIOutboxDrainHarness { harness in
            let missing = harness.rootURL.appending(path: "never-created.sqlite")
            #expect(await harness.drain(at: missing).readOutcome == .verifiedEmpty)
            let corrupt = harness.rootURL.appending(path: "corrupt.sqlite")
            try Data("not sqlite".utf8).write(to: corrupt)
            guard case .unreadable = await harness.drain(at: corrupt).readOutcome else {
                Issue.record("Corruption was treated as empty history")
                return
            }
            let denied = harness.rootURL.appending(path: "denied.sqlite")
            let writer = try await valueFromDedicatedThread {
                try CLIStore.openWriter(url: denied, channel: .debug).get()
            }
            try await valueFromDedicatedThread { try writer.close() }
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: denied.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: denied.path) }
            guard case .unreadable = await harness.drain(at: denied).readOutcome else {
                Issue.record("A denied existing store was treated as empty")
                return
            }
        }
    }

    @Test("S to T is one loss; unchanged T is stable; T to S is a fresh loss")
    func historyTracksTransitions() async throws {
        try await withPaneCLIOutboxDrainHarness { harness in
            let pane = UUIDv7.generate()
            let session = UUIDv7.generate().uuidString
            try await harness.bindLifecycleMain(pane: pane, session: session)
            #expect(await harness.drain().readOutcome == .complete(throughId: 0))
            let replacementURL = harness.rootURL.appending(path: "replacement.sqlite")
            let replacement = try await valueFromDedicatedThread {
                try CLIStore.openWriter(url: replacementURL, channel: .debug).get()
            }
            try await valueFromDedicatedThread { try replacement.close() }
            #expect(await harness.drain(at: replacementURL).readOutcome == .historyLost(thenComplete: 0))
            let first = try #require(try await harness.evidenceRepository.loadEvidence(paneId: pane))
            #expect(first.value == .reportsUnreadable(.historyLost))
            #expect(await harness.drain(at: replacementURL).readOutcome == .complete(throughId: 0))
            #expect(try await harness.evidenceRepository.loadEvidence(paneId: pane) == first)
            #expect(await harness.drain().readOutcome == .historyLost(thenComplete: 0))
            _ = try await harness.ingestion.submitHook(
                .init(
                    paneId: pane, providerIdentifier: "codex", providerVersion: "1.0", sessionId: session,
                    eventName: .sessionEnd, turnId: nil, kind: .completed, signal: .sessionEnd,
                    recordId: UUIDv7.generate(), admittedAt: Date(timeIntervalSince1970: 4)))
            let newer = UUIDv7.generate().uuidString
            try await harness.bindLifecycleMain(pane: pane, session: newer, at: 5)
            #expect(try await harness.evidenceRepository.loadEvidence(paneId: pane) == nil)
        }
    }

    @Test("absence after adoption is history loss, then stable absence")
    func adoptedHistoryCannotBecomeVerifiedEmpty() async throws {
        try await withPaneCLIOutboxDrainHarness { harness in
            let pane = UUIDv7.generate()
            try await harness.bindLifecycleMain(pane: pane, session: UUIDv7.generate().uuidString)
            _ = await harness.drain()
            let missing = harness.rootURL.appending(path: "missing-after-adoption.sqlite")
            #expect(await harness.drain(at: missing).readOutcome == .historyLost(thenComplete: nil))
            #expect(
                try await harness.evidenceRepository.loadEvidence(paneId: pane)?.value
                    == .reportsUnreadable(.historyLost))
            #expect(await harness.drain(at: missing).readOutcome == .verifiedEmpty)
        }
    }

    @Test("all refused-store reasons veto adopted history", arguments: ["channel", "identity", "version"])
    func refusedStoresLoseHistory(reason: String) async throws {
        try await withPaneCLIOutboxDrainHarness { harness in
            let pane = UUIDv7.generate()
            try await harness.bindLifecycleMain(pane: pane, session: UUIDv7.generate().uuidString)
            _ = await harness.drain()
            let writer = harness.writer
            try await valueFromDedicatedThread {
                try writer.databaseQueue.write { database in
                    switch reason {
                    case "channel": try database.execute(sql: "UPDATE cli_store_identity SET channel = 'beta'")
                    case "identity": try database.execute(sql: "UPDATE cli_store_identity SET store_id = 'invalid'")
                    default:
                        try database.execute(sql: "INSERT INTO grdb_migrations(identifier) VALUES ('future-r3-schema')")
                    }
                }
            }
            let report = await harness.drain()
            #expect(report.readOutcome == .historyLost(thenComplete: nil))
            #expect(report.refusedStoreCount == 1)
            #expect(
                try await harness.evidenceRepository.loadEvidence(paneId: pane)?.value
                    == .reportsUnreadable(.historyLost))
        }
    }

    @Test("notice cursors on the first R3 launch do not constitute lost history")
    func upgradeWithNoticeCursorIsNotLoss() async throws {
        try await withPaneCLIOutboxDrainHarness { harness in
            let pane = UUIDv7.generate()
            try await harness.bindLifecycleMain(pane: pane, session: UUIDv7.generate().uuidString)
            try await harness.sqliteAccess.write {
                try CLIOutboxCursorCommitParticipant(storeID: UUIDv7.generate(), lastHandledID: 41).commit(in: $0)
            }
            #expect(await harness.drain().readOutcome == .complete(throughId: 0))
            #expect(try await harness.evidenceRepository.loadEvidence(paneId: pane) == nil)
        }
    }
}
