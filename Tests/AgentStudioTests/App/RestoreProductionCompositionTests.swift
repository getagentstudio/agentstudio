import AgentStudioCLIStore
import AgentStudioIPCTransport
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import AgentStudioSessions
import AgentStudioTerminal
import AgentStudioTestHarness
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioTestSupport

@MainActor
@Suite("Report-only production restore composition", .serialized)
struct RestoreProductionCompositionTests {
    @Test("the actual App cold-resume factory reaches the resolver with no observer")
    func productionFactoryResumesElectedBinding() async throws {
        try await withCompositionFactory { fixture in
            let binding = try await fixture.bind(paneId: fixture.ownerId)
            let delegate = await MainActor.run { AppDelegate() }
            let datastore = WorkspaceSQLiteDatastoreActor(
                preparedCoreRepository: WorkspaceCoreRepository(databaseWriter: fixture.corePool),
                preparationReceipt: .init(core: .uninitialized, local: .available(recovery: nil)),
                preparedApplicationLocalRepository: WorkspaceLocalRepository(
                    workspaceId: fixture.workspaceId, databaseWriter: fixture.localPool))
            let reportRepository = SQLitePaneForegroundEvidenceRepository(
                access: WorkspaceForegroundEvidenceSQLiteAccess(datastore: datastore),
                observerLaunchId: UUIDv7.generate())
            let resolution = await MainActor.run {
                delegate.appIPCSessionsPaneContextComposition = fixture.composition
                delegate.restoreReportEvidenceRepository = reportRepository
                delegate.restoreLaunchBoot = .init(previousBootId: "before", currentBootId: "after")
                return delegate.makeColdResumePlanResolution()
            }
            await delegate.restoreResumeReadiness.record(.verifiedEmpty)
            let plan = await resolution(fixture.ownerId, coldResumeBasePlan(session: .generateUUIDv7()), .complete([:]))
            let expected = ResumeInvocation(
                provider: .claudeCode,
                sessionId: try ProviderSessionId(rawValue: binding.providerConversationId))
            #expect(plan.resume == expected)
            #expect(plan.notice.linesByCandidateIndex[0].contains("Resumed Claude Code"))
            await delegate.shutdownRestoreEvidenceOwners()
            await MainActor.run { delegate.appIPCSessionsPaneContextComposition = nil }
        }
    }

    @Test("ready intake still fails closed when the actual App factory lacks its required report reader")
    func missingRequiredReportReaderFailsClosedAfterReadiness() async throws {
        try await withCompositionFactory { fixture in
            _ = try await fixture.bind(paneId: fixture.ownerId)
            let delegate = await MainActor.run { AppDelegate() }
            let resolution = await MainActor.run {
                delegate.appIPCSessionsPaneContextComposition = fixture.composition
                delegate.restoreLaunchBoot = .init(previousBootId: "before", currentBootId: "after")
                return delegate.makeColdResumePlanResolution()
            }
            let readerMissing = await MainActor.run { delegate.restoreReportEvidenceRepository == nil }
            #expect(readerMissing)
            await delegate.restoreResumeReadiness.record(.verifiedEmpty)
            #expect(await delegate.restoreResumeReadiness.wait(paneId: fixture.ownerId.uuid) == .ready)
            let plan = await resolution(fixture.ownerId, coldResumeBasePlan(session: .generateUUIDv7()), .complete([:]))
            #expect(plan.resume == nil)
            #expect(plan.notice.linesByCandidateIndex[0].contains("Agent state couldn't be checked"))
            #expect(plan.notice.linesByCandidateIndex[0].contains("resume it manually"))
            await delegate.shutdownRestoreEvidenceOwners()
            await MainActor.run { delegate.appIPCSessionsPaneContextComposition = nil }
        }
    }

    @Test("a valid historical look reads as no report and gives the no-row resume verdict")
    func oldLookRowReadsAsNoReport() async throws {
        try await withPaneCLIOutboxDrainHarness { harness in
            let pane = try await ColdResumeTestPane.make(harness: harness)
            try await harness.sqliteAccess.write { database in
                try database.execute(
                    sql: """
                        INSERT INTO terminal_pane_foreground_evidence (
                            pane_id,evidence_kind,binding_generation_id,observer_launch_id,sequence,observed_at,
                            zmx_session_id,program,identity_version,boot_id,daemon_pid,daemon_start_seconds,
                            daemon_start_microseconds,leader_pid,leader_start_seconds,leader_start_microseconds,
                            process_group_id,session_created_at
                        ) VALUES (?,'look',?,?,1,'1970-01-01T00:00:11.000Z',?,'codex',1,'old-boot',2111,1,1,2112,1,2,2112,1)
                        """,
                    arguments: [
                        pane.paneId.uuidString, pane.bindingGenerationId.uuidString,
                        UUIDv7.generate().uuidString, pane.zmxSessionId.rawValue,
                    ])
            }
            let report = try await pane.repository.loadEvidence(paneId: pane.paneId)
            #expect(report == nil)
            let ended = try await harness.ingestion.endLiveMainForColdRestore(paneId: pane.paneId)
            let fromRow = await SessionsResumeResolver().resumeEvidence(
                for: .init(
                    zmxSessionId: pane.zmxSessionId, coldEndedMain: ended, evidence: report,
                    isSameBoot: false, inventory: .complete([:])))
            let noRow = await SessionsResumeResolver().resumeEvidence(
                for: .init(
                    zmxSessionId: pane.zmxSessionId, coldEndedMain: ended, evidence: nil,
                    isSameBoot: false, inventory: .complete([:])))
            #expect(fromRow == noRow)
            #expect(
                fromRow
                    == .interruptedCandidate(
                        .init(
                            provider: .codex,
                            sessionId: try ProviderSessionId(rawValue: pane.sessionId))))
        }
    }

    @Test("the real App starts outbox intake without a preinstalled report repository")
    func outboxStartsWithoutPreinstalledReportOwner() async throws {
        let harness = try await SessionsVerticalHarness.make()
        do {
            let reportRepository = harness.appDelegate.restoreReportEvidenceRepository
            #expect(reportRepository != nil)
            let installedDrainTask = harness.appDelegate.paneCLIOutboxDrainTask
            let task = try #require(installedDrainTask)
            let drain = try #require(await task.value)
            #expect(await harness.commandHarness.store.flushAsync() == .persisted)
            let paths = try #require(harness.appDelegate.appIPCPaths)
            let message = UUIDv7.generate()
            let params = IPCPaneMessageSendParams(
                handle: "self", messageId: message, writer: nil,
                importance: .info, body: "Offline intake survives removal of foreground observation",
                actions: [], shape: .notice, correlationId: message)
            let value = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(params))
            let payload = try JSONRPCCodec.encodeRequest(
                .init(id: .number(1), method: "pane.message.send", params: value))
            try await valueFromDedicatedThread {
                let writer = try CLIStore.openWriter(url: paths.cliStoreURL, channel: .debug).get()
                defer { try? writer.close() }
                _ = try writer.appendNotice(
                    paneID: harness.boundPaneId, messageID: message,
                    payloadJSON: payload, createdAt: Date(timeIntervalSince1970: 20)
                ).get()
            }
            let result = await drain.drain(storeURL: paths.cliStoreURL)
            #expect(result.admittedEntryCount == 1)
            let composition = try #require(harness.appDelegate.appIPCSessionsPaneContextComposition)
            let detail = await composition.paneContextService.readDetail(
                .init(paneId: .init(existingUUID: harness.boundPaneId), page: .first))
            guard case .detail(let snapshot) = detail else {
                Issue.record("imported notice unavailable")
                await harness.tearDown()
                return
            }
            #expect(snapshot.messages.contains { $0.id.uuid == message && $0.body == params.body })
            await harness.tearDown()
        } catch {
            await harness.tearDown()
            throw error
        }
    }
}
