import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioCLIStore

@MainActor
@Suite("Real lifecycle writer processes", .serialized)
struct CLILifecycleReportProcessTests {
    @Test("SR13a keeps the warm main ended when its real start writer commits after the end read")
    func warmStartWriterHeldPastEndRead() async throws {
        try await withPaneCLIOutboxDrainHarness { harness in
            let pane = UUIDv7.generate()
            let session = UUIDv7.generate().uuidString
            try await harness.seedUnconfirmedLifecycleMain(pane: pane, session: session)
            let original = try await harness.lifecycleContext(pane: pane).currentBinding?.bindingGenerationId
            let end = try await harness.appendLifecycle(pane: pane, session: session, event: .sessionEnd, at: 2.0006)
            let startWriter = try CLILifecycleWriterProcess(
                executable: lifecycleWriterExecutable(),
                arguments: [
                    harness.storeURL.path, pane.uuidString, "--lifecycle", session, "sessionStart", "3.0006", "--hold",
                ],
                environment: [:])
            do {
                _ = try await startWriter.expectPrecommitHold()
                #expect(try await harness.rows().count == 1)
                #expect(await harness.drain().readOutcome == .complete(throughId: end.id))
                await harness.publishLifecycleStatus()
                #expect(harness.statusAtom.value(for: PaneId(existingUUID: pane))?.status == .idle(.ended))
                try await startWriter.releasePrecommitHold(payload: Data([1]))
                let output = try await startWriter.finish()
                #expect(output.status == 0)
                _ = try await harness.restartedDrain()
                await harness.publishLifecycleStatus()
                #expect(harness.statusAtom.value(for: PaneId(existingUUID: pane))?.status == .idle(.ended))
                try await assertReloadedLifecycleQuery(harness, pane: pane, health: .ended)
                try await harness.bindLifecycleMain(pane: pane, session: session, at: 4)
                let context = try await harness.lifecycleContext(pane: pane)
                #expect(context.currentBinding?.status == .active)
                #expect(context.currentBinding?.bindingGenerationId == original)
                #expect(context.bindings.count == 1)
            } catch {
                await startWriter.stop()
                throw error
            }
        }
    }

    @Test("an end held after real delivery failure cannot close a newer live start")
    func endHeldAcrossLiveResume() async throws {
        try await withPaneCLIOutboxDrainHarness { harness in
            let pane = UUIDv7.generate()
            let session = UUIDv7.generate().uuidString
            try await harness.bindLifecycleMain(pane: pane, session: session)
            let writer = try CLILifecycleWriterProcess(
                executable: lifecycleWriterExecutable(),
                arguments: [
                    harness.storeURL.path, pane.uuidString, "--lifecycle", session, "sessionEnd", "2.0006", "--hold",
                ],
                environment: [:])
            do {
                _ = try await writer.expectPrecommitHold()
                #expect(try await harness.rows().isEmpty)
                try await harness.bindLifecycleMain(pane: pane, session: session, at: 3.0008)
                try await writer.releasePrecommitHold(payload: Data([1]))
                let output = try await writer.finish()
                #expect(output.status == 0)
                let rows = try await harness.rows()
                guard case .sessionLifecycle(let end) = try #require(rows.first) else {
                    Issue.record("Missing held end")
                    return
                }
                #expect(end.reportedAt == Date(timeIntervalSince1970: 2))
                _ = await harness.drain()
                #expect(try await harness.lifecycleContext(pane: pane).currentBinding?.status == .active)
                _ = try await harness.restartedDrain()
                try await assertReloadedLifecycleQuery(harness, pane: pane, health: .live)
            } catch {
                await writer.stop()
                throw error
            }
        }
    }

    @Test("several real CLI writers commit one outbox in id order")
    func multipleWritersShareOutboxOrder() async throws {
        try await withPaneCLIOutboxDrainHarness { harness in
            let executable = try lifecycleWriterExecutable()
            let panes = (0..<3).map { _ in UUIDv7.generate() }
            var writers: [CLILifecycleWriterProcess] = []
            do {
                for pane in panes {
                    writers.append(
                        try CLILifecycleWriterProcess(
                            executable: executable,
                            arguments: [
                                harness.storeURL.path, pane.uuidString, "--lifecycle",
                                UUIDv7.generate().uuidString, "sessionEnd", "2.0006", "--hold",
                            ],
                            environment: [:]))
                }
                for writer in writers { _ = try await writer.expectPrecommitHold() }
                var ids: [Int64] = []
                for index in [2, 0, 1] {
                    let writer = writers[index]
                    try await writer.releasePrecommitHold(payload: Data([1]))
                    let output = try await writer.finish()
                    #expect(output.status == 0)
                    ids.append(try #require(Int64(output.text.trimmingCharacters(in: .whitespacesAndNewlines))))
                }
                let rows = try await harness.rows()
                try #require(ids.count == 3)
                #expect(ids[0] < ids[1] && ids[1] < ids[2])
                #expect(rows.map(\.id) == ids)
                #expect(rows.count == 3)
                var committedPanes: [UUID] = []
                for row in rows {
                    guard case .sessionLifecycle(let report) = row else {
                        Issue.record("Writer emitted another kind")
                        return
                    }
                    committedPanes.append(report.paneID)
                }
                #expect(committedPanes == [panes[2], panes[0], panes[1]])
            } catch {
                for writer in writers { await writer.stop() }
                throw error
            }
        }
    }

    @Test("a retryable notice holds a real process's later end")
    func retryablePrefixHoldsCommittedEnd() async throws {
        try await withPaneCLIOutboxDrainHarness { harness in
            let pane = UUIDv7.generate()
            let session = UUIDv7.generate().uuidString
            try await harness.bindLifecycleMain(pane: pane, session: session)
            _ = await harness.drain()
            _ = try await harness.append(paneID: pane, line: harness.messageLine(text: "retry first"))
            let writer = try CLILifecycleWriterProcess(
                executable: lifecycleWriterExecutable(),
                arguments: [
                    harness.storeURL.path, pane.uuidString, "--lifecycle", session, "sessionEnd", "2.0006", "--hold",
                ],
                environment: [:])
            do {
                _ = try await writer.expectPrecommitHold()
                await harness.sqliteAccess.setRejectsWrites(true)
                guard case .incomplete = await harness.drain().readOutcome else {
                    Issue.record("Notice did not hold the prefix")
                    await writer.stop()
                    return
                }
                try await writer.releasePrecommitHold(payload: Data([1]))
                let output = try await writer.finish()
                #expect(output.status == 0)
                let endId = try #require(Int64(output.text.trimmingCharacters(in: .whitespacesAndNewlines)))
                guard case .incomplete = await harness.drain().readOutcome else {
                    Issue.record("Skipped held notice")
                    return
                }
                #expect(try await harness.cursor() == 0)
                #expect(try await harness.lifecycleContext(pane: pane).currentBinding?.status == .active)
                await harness.sqliteAccess.setRejectsWrites(false)
                #expect(await harness.drain().readOutcome == .complete(throughId: endId))
                #expect(try await harness.cursor() == endId)
                #expect(try await harness.lifecycleContext(pane: pane).currentBinding?.status == .ended)
            } catch {
                await writer.stop()
                throw error
            }
        }
    }
}

func lifecycleWriterExecutable() throws -> URL {
    let buildDirectory = try #require(ProcessInfo.processInfo.environment["SWIFT_BUILD_DIR"])
    let projectRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let buildURL =
        buildDirectory.hasPrefix("/")
        ? URL(fileURLWithPath: buildDirectory) : projectRoot.appending(path: buildDirectory)
    return buildURL.appending(path: "debug/agentstudio-cli-store-process-fixture")
}
