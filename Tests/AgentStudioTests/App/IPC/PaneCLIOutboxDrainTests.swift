import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import AgentStudioSessions
import AgentStudioTestHarness
import Foundation
import GRDB
import Testing

@testable import AgentStudio
@testable import AgentStudioCLIStore

@MainActor
@Suite("Pane CLI outbox drain", .serialized)
struct PaneCLIOutboxDrainTests {
    @Test("a real drain refusal emits only its controlled reason class through IPC telemetry")
    func drainRefusalIsRecordedAsTelemetry() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "outbox-telemetry-\(UUIDv7.generate())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let runtime = AgentStudioTraceRuntime(
            configuration: AgentStudioTraceConfiguration.from(environment: [
                "AGENTSTUDIO_TRACE_BACKEND": "jsonl", "AGENTSTUDIO_TRACE_DIR": directory.path,
                "AGENTSTUDIO_TRACE_NAME": "outbox-refusal", "AGENTSTUDIO_TRACE_TAGS": "performance",
            ]), processIdentifier: 909, timeUnixNano: { 117 })
        let recorder = AgentStudioPerformanceTraceRecorder(traceRuntime: runtime)
        let telemetry = AgentStudioIPCAgentAuthorizationTelemetry(performanceTraceRecorder: recorder)
        // Existing telemetry is a positive control for writer/configuration readiness.
        telemetry.recordAgentAuthorization(elapsed: .zero, outcome: .authorized)
        let marker = "PRIVATE-OFFLINE-PAYLOAD-MUST-NOT-RECORD"
        let recordRefusal: @Sendable (PaneCLIOutboxDrain.RefusalReason) -> Void = { reason in
            telemetry.recordOfflineNoticeRefusal(reason: reason)
        }
        do {
            try await withPaneCLIOutboxDrainHarness(refusalProbe: recordRefusal) { harness in
                let entry = try await harness.append(paneID: UUIDv7.generate(), line: marker)
                let report = await harness.drain()
                #expect(report.malformedEntryCount == 1)
                #expect(harness.refusalRecorder.reasons == [.malformedEnvelope])
                #expect(try await harness.cursor() == entry.id)
            }
        } catch {
            try? await recorder.drain()
            throw error
        }
        try await recorder.drain()
        let file = try #require(runtime.outputFileURL)
        let text = try await valueFromDedicatedThread { try String(contentsOf: file, encoding: .utf8) }
        #expect(text.contains("performance.ipc.agent_authorization"))
        #expect(text.contains("performance.ipc.outbox_refusal"))
        #expect(text.contains("agentstudio.performance.ipc.outbox_refusal.reason"))
        #expect(text.contains(PaneCLIOutboxDrain.RefusalReason.malformedEnvelope.rawValue))
        #expect(!text.contains(marker))
        #expect(!text.contains("pane_id"))
        #expect(!text.contains("store_id"))
    }

    @Test("a never-bound pane cannot wedge a later bound pane's notice")
    func unboundPaneDoesNotHoldAnotherPane() async throws {
        try await withPaneCLIOutboxDrainHarness { harness in
            let unboundPane = UUIDv7.generate()
            let boundPane = UUIDv7.generate()
            try await harness.bindPane(paneID: boundPane)
            let refused = try await harness.append(
                paneID: unboundPane, line: harness.reportLine(kind: "done", explanation: nil))
            let admitted = try await harness.append(
                paneID: boundPane, line: harness.messageLine(text: "other pane survives"))

            let report = await harness.drain()

            #expect(refused.id < admitted.id)
            #expect(report.malformedEntryCount == 1)
            #expect(report.admittedEntryCount == 1)
            #expect(report.retryableEntryCount == 0)
            #expect(harness.refusalRecorder.reasons == [.ineligibleMethod])
            #expect(try await harness.cursor() == admitted.id)
            #expect(try await harness.rows() == [refused, admitted])
            #expect(try await harness.snapshot(paneID: unboundPane).currentBinding == nil)
            #expect(try await harness.paneMessages(paneID: boundPane).map(\.body) == ["other pane survives"])
        }
    }

    @Test("one queued message becomes late evidence and advances the cursor without changing the outbox")
    func queuedMessageIsAdmittedLateAndReadThrough() async throws {
        try await withPaneCLIOutboxDrainHarness { harness in
            let paneID = UUIDv7.generate()
            let entry = try await harness.append(paneID: paneID, line: harness.messageLine(text: "deploy finished"))

            let report = await harness.drain()

            #expect(report.admittedEntryCount == 1)
            #expect(report.retryableEntryCount == 0)
            #expect(try await harness.cursor() == entry.id)
            #expect(try await harness.rows() == [entry])
            let messages = try await harness.paneMessages(paneID: paneID)
            #expect(messages.count == 1)
            #expect(messages.first?.body == "deploy finished")
            #expect(messages.first?.sender == .pane(PaneId(existingUUID: paneID)))
            #expect(messages.first?.sourcePaneId == PaneId(existingUUID: paneID))
        }
    }

    @Test("duplicate message id and a restarted drain produce one durable occurrence")
    func duplicateMessageIsAdmittedOnce() async throws {
        try await withPaneCLIOutboxDrainHarness { harness in
            let paneID = UUIDv7.generate()
            let line = try harness.messageLine(text: "duplicate", correlationID: UUIDv7.generate())
            let first = try await harness.append(paneID: paneID, line: line)
            let duplicate = try await harness.append(paneID: paneID, line: line)

            let report = await harness.drain()
            let restarted = try await harness.restartedDrain()

            #expect(first == duplicate)
            #expect(report.admittedEntryCount == 1)
            #expect(restarted.admittedEntryCount == 0)
            #expect(try await harness.cursor() == first.id)
            #expect(try await harness.paneMessages(paneID: paneID).count == 1)
        }
    }

    @Test("malformed envelopes are refused while later valid notices advance the prefix")
    func malformedEnvelopeIsSkipped() async throws {
        try await withPaneCLIOutboxDrainHarness { harness in
            let paneID = UUIDv7.generate()
            _ = try await harness.append(paneID: paneID, line: #"{"not":"a json-rpc request"}"#)
            let survivor = try await harness.append(paneID: paneID, line: harness.messageLine(text: "survivor"))

            let report = await harness.drain()

            #expect(report.malformedEntryCount == 1)
            #expect(report.admittedEntryCount == 1)
            #expect(try await harness.cursor() == survivor.id)
            #expect(try await harness.rows().count == 2)
            #expect(try await harness.paneMessages(paneID: paneID).map(\.body) == ["survivor"])
        }
    }

    @Test("provider events in the outbox never reach Sessions admission")
    func providerEventIsNeverAdmitted() async throws {
        try await withPaneCLIOutboxDrainHarness { harness in
            let paneID = UUIDv7.generate()
            let entry = try await harness.append(paneID: paneID, line: harness.providerEventLine())

            let report = await harness.drain()

            #expect(report.malformedEntryCount == 1)
            #expect(report.admittedEntryCount == 0)
            #expect(harness.refusalRecorder.reasons == [.ineligibleMethod])
            #expect(try await harness.cursor() == entry.id)
            #expect(try await harness.snapshot(paneID: paneID).currentBinding == nil)
        }
    }

    @Test("a wire handle naming another pane is refused for the row's pane")
    func foreignHandleIsRefused() async throws {
        try await withPaneCLIOutboxDrainHarness { harness in
            let paneID = UUIDv7.generate()
            let entry = try await harness.append(
                paneID: paneID,
                line: harness.messageLine(text: "wrong pane", handle: UUIDv7.generate().uuidString))

            let report = await harness.drain()

            #expect(report.malformedEntryCount == 1)
            #expect(harness.refusalRecorder.reasons == [.foreignPane])
            #expect(try await harness.cursor() == entry.id)
            #expect(try await harness.paneMessages(paneID: paneID).isEmpty)
        }
    }

    @Test("datastore failure leaves the cursor and row intact for the next readiness")
    func datastoreFailureRetainsUnreadEntry() async throws {
        try await withPaneCLIOutboxDrainHarness { harness in
            let paneID = UUIDv7.generate()
            let entry = try await harness.append(paneID: paneID, line: harness.messageLine(text: "retry me"))
            await harness.sqliteAccess.setRejectsWrites(true)

            let failed = await harness.drain()

            #expect(failed.admittedEntryCount == 0)
            #expect(failed.retryableEntryCount == 1)
            #expect(try await harness.cursor() == 0)
            #expect(try await harness.rows() == [entry])
            await harness.sqliteAccess.setRejectsWrites(false)
            let retried = try await harness.restartedDrain()
            #expect(retried.admittedEntryCount == 1)
            #expect(try await harness.cursor() == entry.id)
            #expect(try await harness.paneMessages(paneID: paneID).count == 1)
        }
    }

    @Test("a claimed writer's binding read failure keeps the notice queued until the next drain")
    func bindingReadFailureRetainsClaimedNotice() async throws {
        try await withPaneCLIOutboxDrainHarness { harness in
            let paneID = UUIDv7.generate()
            try await harness.bindPane(paneID: paneID)
            let snapshot = try await harness.snapshot(paneID: paneID)
            let binding = try #require(snapshot.currentBinding)
            let writer = IPCPaneWriterClaim(
                provider: binding.providerIdentifier, conversationId: binding.providerConversationId)
            let line = try harness.messageLine(text: "retry the binding read", writer: writer)
            let entry = try await harness.append(paneID: paneID, line: line)
            // Cursor reads remain available; only the actual binding query loses its table.
            try await harness.sqliteAccess.write { database in
                try database.execute(
                    sql: "ALTER TABLE sessions_pane_binding RENAME TO test_unavailable_sessions_binding")
            }

            let failed = await harness.drain()
            let cursorAfterFailure = try await harness.cursor()
            let queuedAfterFailure = try await harness.rows()
            let messagesAfterFailure = try await harness.paneMessages(paneID: paneID)
            #expect(failed.admittedEntryCount == 0)
            #expect(failed.retryableEntryCount == 1)
            #expect(failed.malformedEntryCount == 0)
            #expect(failed.refusedEntryCount == 0)
            #expect(cursorAfterFailure == 0)
            #expect(queuedAfterFailure == [entry])
            #expect(messagesAfterFailure.isEmpty)
            #expect(harness.refusalRecorder.reasons.isEmpty)

            try await harness.sqliteAccess.write { database in
                try database.execute(
                    sql: "ALTER TABLE test_unavailable_sessions_binding RENAME TO sessions_pane_binding")
            }
            let retried = try await harness.restartedDrain()
            let cursorAfterRetry = try await harness.cursor()
            let admitted = try await harness.paneMessages(paneID: paneID)
            let expectedSender = AgentMessageSender.session(
                provider: try BridgeAgentProviderName(binding.providerIdentifier),
                sessionRef: try BridgeAgentSessionRef(binding.providerConversationId),
                bindingGeneration: binding.bindingGenerationId)
            #expect(retried.admittedEntryCount == 1)
            #expect(retried.retryableEntryCount == 0)
            #expect(cursorAfterRetry == entry.id)
            #expect(admitted.count == 1)
            #expect(admitted.first?.body == "retry the binding read")
            #expect(admitted.first?.sender == expectedSender)
        }
    }

    @Test("an unbound pane's deliberate report is refused and never replayed after binding")
    func unboundDeliberateReportIsRefused() async throws {
        try await withPaneCLIOutboxDrainHarness { harness in
            let paneID = UUIDv7.generate()
            let entry = try await harness.append(
                paneID: paneID,
                line: harness.reportLine(kind: "needsYou", explanation: "approve the plan"))

            let beforeBinding = await harness.drain()

            #expect(beforeBinding.retryableEntryCount == 0)
            #expect(beforeBinding.malformedEntryCount == 1)
            #expect(harness.refusalRecorder.reasons == [.ineligibleMethod])
            #expect(try await harness.cursor() == entry.id)
            #expect(try await harness.rows() == [entry])
            try await harness.bindPane(paneID: paneID)
            let afterBinding = await harness.drain()
            #expect(afterBinding.admittedEntryCount == 0)
            #expect(afterBinding.retryableEntryCount == 0)
            #expect(try await harness.cursor() == entry.id)
            #expect(try await harness.attention(paneID: paneID).isEmpty)
        }
    }

    @Test("an over-limit payload is refused without holding its valid neighbour")
    func overLimitEnvelopeIsSkipped() async throws {
        try await withPaneCLIOutboxDrainHarness { harness in
            let paneID = UUIDv7.generate()
            _ = try await harness.append(
                paneID: paneID,
                line: harness.messageLine(
                    text: String(repeating: "x", count: AppPolicies.IPC.offlineNoticeMaximumPayloadBytes)))
            let survivor = try await harness.append(paneID: paneID, line: harness.messageLine(text: "survivor"))

            let report = await harness.drain()

            #expect(report.malformedEntryCount == 1)
            #expect(report.admittedEntryCount == 1)
            #expect(try await harness.cursor() == survivor.id)
            #expect(try await harness.rows().count == 2)
            #expect(try await harness.paneMessages(paneID: paneID).map(\.body) == ["survivor"])
        }
    }

    @Test("a CLI write lock does not hold the app's readonly drain")
    func heldCLIWriterDoesNotBlockTheReader() async throws {
        try await withPaneCLIOutboxDrainHarness { harness in
            let paneID = UUIDv7.generate()
            let entry = try await harness.append(
                paneID: paneID, line: harness.messageLine(text: "committed before lock"))
            let held = HeldStep<Void>("CLI writer transaction holds the write lock")
            let writer = harness.writer
            let lockOwner = Task {
                try await valueFromDedicatedThread {
                    try writer.databaseQueue.write { _ in try held.arriveBlocking(()) }
                }
            }
            do {
                try await held.firstArrival()
                let report = await harness.drain()
                #expect(report.admittedEntryCount == 1)
                #expect(try await harness.cursor() == entry.id)
                held.release()
                try await lockOwner.value
            } catch {
                held.release()
                _ = try? await lockOwner.value
                throw error
            }
        }
    }

    @Test("legacy status reports after relaunch are refused without creating history")
    func deliberateReportsSurviveRelaunch() async throws {
        try await withPaneCLIOutboxDrainHarness { harness in
            let paneID = UUIDv7.generate()
            try await harness.bindPane(paneID: paneID)
            try await harness.simulateRelaunch()
            let stateAfterRelaunch = try await harness.sessionSummary(paneID: paneID)
            _ = try await harness.append(
                paneID: paneID, line: harness.reportLine(kind: "needsYou", explanation: "approve the plan"))
            let last = try await harness.append(
                paneID: paneID, line: harness.reportLine(kind: "done", explanation: nil))

            let report = await harness.drain()

            #expect(report.admittedEntryCount == 0)
            #expect(report.malformedEntryCount == 2)
            #expect(try await harness.cursor() == last.id)
            let snapshot = try await harness.snapshot(paneID: paneID)
            #expect(try await harness.sessionSummary(paneID: paneID) == stateAfterRelaunch)
            #expect(try await harness.attention(paneID: paneID).isEmpty)
            #expect(snapshot.results.isEmpty)
            #expect(snapshot.historicalOccurrenceIds.isEmpty)
            #expect(harness.refusalRecorder.reasons == [.ineligibleMethod, .ineligibleMethod])
        }
    }

    @Test("a permanent refusal advances the handled prefix without holding later notices")
    func permanentRefusalDoesNotHoldLaterNotices() async throws {
        try await withPaneCLIOutboxDrainHarness { harness in
            let paneID = UUIDv7.generate()
            let handled = try await harness.append(paneID: paneID, line: harness.messageLine(text: "first"))
            let refused = try await harness.append(
                paneID: paneID, line: harness.reportLine(kind: "needsYou", explanation: "bind first"))
            let later = try await harness.append(
                paneID: paneID, line: harness.messageLine(text: "survives permanent refusal"))

            let report = await harness.drain()

            #expect(report.admittedEntryCount == 2)
            #expect(report.malformedEntryCount == 1)
            #expect(report.retryableEntryCount == 0)
            #expect(try await harness.cursor() == later.id)
            #expect(try await harness.rows() == [handled, refused, later])
            let messages = try await harness.paneMessages(paneID: paneID).map(\.body)
            #expect(Set(messages) == Set(["first", "survives permanent refusal"]))
            #expect(messages.count == 2)
        }
    }

    @Test("a concurrent CLI append during drain is never lost")
    func concurrentAppendDuringDrainSurvives() async throws {
        try await withPaneCLIOutboxDrainHarness { harness in
            let paneID = UUIDv7.generate()
            let handled = try await harness.append(paneID: paneID, line: harness.messageLine(text: "first"))
            let refused = try await harness.append(
                paneID: paneID, line: harness.reportLine(kind: "needsYou", explanation: "bind first"))
            let appendedLine = try harness.reportLine(kind: "needsYou", explanation: "second approval")

            async let drained = harness.drain()
            async let appended = harness.append(paneID: paneID, line: appendedLine)
            let (report, last) = try await (drained, appended)

            #expect(report.admittedEntryCount == 1)
            #expect(report.retryableEntryCount == 0)
            #expect(report.malformedEntryCount >= 1)
            #expect(try await harness.cursor() >= refused.id)
            let completed = try await harness.restartedDrain()
            #expect(completed.retryableEntryCount == 0)
            #expect(report.malformedEntryCount + completed.malformedEntryCount == 2)
            #expect(try await harness.cursor() == last.id)
            #expect(try await harness.rows() == [handled, refused, last])
        }
    }

    @Test("cursor commit failure rolls back the notice effect too")
    func cursorAndNoticeCommitAtomically() async throws {
        try await withPaneCLIOutboxDrainHarness { harness in
            let paneID = UUIDv7.generate()
            let entry = try await harness.append(paneID: paneID, line: harness.messageLine(text: "atomic message"))
            await harness.sqliteAccess.failCursorCommit()

            let report = await harness.drain()

            #expect(report.admittedEntryCount == 0)
            #expect(report.retryableEntryCount == 1)
            #expect(try await harness.cursor() == 0)
            #expect(try await harness.paneMessages(paneID: paneID).isEmpty)
            #expect(try await harness.rows() == [entry])
        }
    }

    @Test("a store from a foreign release channel is refused without cursor progress")
    func foreignStoreIsRefused() async throws {
        try await withPaneCLIOutboxDrainHarness { harness in
            let paneID = UUIDv7.generate()
            let entry = try await harness.append(paneID: paneID, line: harness.messageLine(text: "foreign channel"))
            let writer = harness.writer
            try await valueFromDedicatedThread {
                try writer.databaseQueue.write { database in
                    try database.execute(sql: "UPDATE cli_store_identity SET channel = 'beta'")
                }
            }

            let report = await harness.drain()

            #expect(report.refusedStoreCount == 1)
            #expect(harness.refusalRecorder.reasons == [.foreignStore])
            #expect(report.admittedEntryCount == 0)
            #expect(try await harness.cursor() == 0)
            #expect(try await harness.rows() == [entry])
        }
    }

    @Test("old NDJSON files are admitted once and removed; no new spool path remains")
    func legacyFilesAreImportedOnceAndRemoved() async throws {
        try await withPaneCLIOutboxDrainHarness { harness in
            let paneID = UUIDv7.generate()
            try harness.writeLegacyFile(paneID: paneID, lines: [harness.messageLine(text: "legacy notice")])

            let first = await harness.drain()
            let restarted = try await harness.restartedDrain()

            #expect(first.importedLegacyLineCount == 1)
            #expect(restarted.importedLegacyLineCount == 0)
            #expect(!FileManager.default.fileExists(atPath: harness.legacyFileURL(paneID: paneID).path))
            #expect(try await harness.paneMessages(paneID: paneID).map(\.body) == ["legacy notice"])
            // The app must not insert the imported envelope into the CLI file.
            #expect(try await harness.rows().isEmpty)
        }
    }

    @Test("an unknown stored kind is dispositioned with telemetry and cursor progress")
    func unknownStoredKindAdvancesTheRefusedPrefix() async throws {
        try await withPaneCLIOutboxDrainHarness { harness in
            let paneID = UUIDv7.generate()
            let entry = try await harness.append(paneID: paneID, line: harness.messageLine(text: "future kind"))
            let writer = harness.writer
            try await valueFromDedicatedThread {
                try writer.databaseQueue.write { database in
                    try database.execute(
                        sql: "UPDATE cli_outbox SET kind = 'future-kind' WHERE id = ?", arguments: [entry.id])
                }
            }

            let report = await harness.drain()

            #expect(report.malformedEntryCount == 1)
            #expect(harness.refusalRecorder.reasons == [.unknownKind])
            #expect(try await harness.cursor() == entry.id)
            #expect(try await harness.paneMessages(paneID: paneID).isEmpty)
            let storedCount = try await valueFromDedicatedThread {
                try writer.databaseQueue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM cli_outbox") }
            }
            #expect(storedCount == 1)
        }
    }

    @Test("a forged offline clear never reaches the live deliberate-report mutation")
    func offlineClearCannotClearAttention() async throws {
        try await withPaneCLIOutboxDrainHarness { harness in
            let paneID = UUIDv7.generate()
            try await harness.bindPane(paneID: paneID)
            let messageID = UUIDv7.generate()
            let snapshot = try await harness.snapshot(paneID: paneID)
            let generation = try #require(snapshot.currentBinding?.bindingGenerationId)
            let request = PaneMessageSendRequest(
                paneId: PaneId(existingUUID: paneID), messageId: AgentMessageId(existingUUID: messageID),
                sender: .session(
                    provider: try BridgeAgentProviderName(PaneCLIOutboxDrainHarness.qualifiedProvider.identifier),
                    sessionRef: try BridgeAgentSessionRef("conversation-\(paneID)"),
                    bindingGeneration: generation),
                sourceOccurredAt: nil, importance: .attention, body: "keep attention", why: nil, actions: [],
                shape: .ask(reason: .blocked, form: .freeText(placeholder: nil), waiting: .nonBlocking))
            let opened = await harness.paneService.send(request)
            #expect(opened == .created(AgentMessageId(existingUUID: messageID)))
            let attention = try await harness.paneMessages(paneID: paneID)
            #expect(attention.count == 1)
            let entry = try await harness.append(
                paneID: paneID, line: harness.reportLine(kind: "clearNeedsYou", explanation: nil))

            let report = await harness.drain()

            #expect(report.malformedEntryCount == 1)
            #expect(harness.refusalRecorder.reasons == [.ineligibleMethod])
            #expect(try await harness.cursor() == entry.id)
            #expect(try await harness.paneMessages(paneID: paneID) == attention)
        }
    }

    @Test("an unbound legacy report is refused and removed rather than replayed after binding")
    func legacyUnboundReportIsRefused() async throws {
        try await withPaneCLIOutboxDrainHarness { harness in
            let paneID = UUIDv7.generate()
            try harness.writeLegacyFile(
                paneID: paneID, lines: [harness.reportLine(kind: "needsYou", explanation: "legacy approval")])

            let refused = await harness.drain()

            #expect(refused.malformedEntryCount == 1)
            #expect(refused.retryableEntryCount == 0)
            #expect(!FileManager.default.fileExists(atPath: harness.legacyFileURL(paneID: paneID).path))
            try await harness.bindPane(paneID: paneID)
            let retried = try await harness.restartedDrain()
            #expect(retried.importedLegacyLineCount == 0)
            #expect(!FileManager.default.fileExists(atPath: harness.legacyFileURL(paneID: paneID).path))
            #expect(try await harness.attention(paneID: paneID).isEmpty)
        }
    }
}
