import AgentStudioInfrastructure
import AgentStudioTestHarness
import AgentStudioTestSupport
import Foundation
import GRDB
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioTerminal

enum PreReadyRetirementWindow: CaseIterable, Sendable {
    case beforeSinkInstallation, afterSinkBeforeSchema
}

extension ScrollbackWorkspaceLifecycleTests {
    @Test(
        "an available recovered close expiring before foreground readiness is retained",
        arguments: PreReadyRetirementWindow.allCases)
    func recoveredAvailableCloseExpiryWaitsForForegroundReadiness(window: PreReadyRetirementWindow) async throws {
        let expiry = HeldStep<WorkspaceUndoJournalTime>("available recovered close reaches its controlled deadline")
        defer { expiry.retire() }
        let registrationScope = UUIDv7.generate()
        let registrations = FactRecorder<UUID, PreReadyDeadlineFact>(
            vocabulary: .init(
                describeScope: { $0.uuidString }, describeFact: { String(describing: $0) },
                isClosing: { _, fact in fact == .ownerEnded }))
        let clock = AgentStudioTestSupport.TestPushClock(pendingSleepFactSink: { fact in
            if case .registrationSettled(let deadline, _) = fact {
                registrations.append(scope: registrationScope, fact: .sleepRegistered(deadline))
            }
        })
        let deadline = clock.now.advanced(by: AppPolicies.WorkspacePersistence.undoGracePeriod)
        do {
            try await withWorkspace(expiryHold: expiry, clock: clock) { fixture in
                let pane = fixture.store.createPane(zmxSessionID: .generateUUIDv7())
                let tab = Tab(paneId: pane.id)
                fixture.store.appendTab(tab)
                #expect(await fixture.store.flushAsync() == .persisted)
                let paneID = PaneId(existingUUID: pane.id)
                _ = try await fixture.scrollback.store(paneId: paneID, capture: Data("available undo output".utf8))
                let repository = SQLitePaneForegroundEvidenceRepository(
                    access: WorkspaceForegroundEvidenceSQLiteAccess(datastore: fixture.datastore),
                    observerLaunchId: UUIDv7.generate())
                #expect(try await writeRetirementProbe(fixture, repository: repository, paneId: pane.id) == .admitted)
                try await fixture.coordinator.execute(.closeTab(tabId: tab.id))
                let time = try await fixture.coordinator.undoClock()
                let recovery = try await fixture.store.recoverUndoJournal(time: time)
                try #require(recovery.retiredCloses.isEmpty)
                try #require(recovery.availableCloses.count == 1)
                let delegate = AppDelegate()
                fixture.bootDelegate = delegate
                delegate.store = fixture.store
                delegate.viewRegistry = fixture.coordinator.viewRegistry
                delegate.workspaceSurfaceCoordinator = fixture.coordinator
                delegate.workspaceSQLiteDatastore = fixture.datastore
                delegate.restoreReportEvidenceRepository = repository
                delegate.workspaceSurfaceCoordinator.installUndoJournalRecovery(recovery)
                try #require(fixture.coordinator.undoStack.count == 1)
                if window == .afterSinkBeforeSchema {
                    try await installRetirementOwners(delegate, fixture: fixture)
                }
                let producer = try #require(fixture.coordinator.undoDeadlineTask)
                fixture.undoDeadlineLifetimeTask = Task {
                    await producer.value
                    registrations.append(scope: registrationScope, fact: .ownerEnded)
                    expiry.retire()
                    if !Task.isCancelled {
                        fixture.source.lose("undo deadline producer ended before the expected retirement")
                    }
                }
                try await registrations.expectNext(in: registrationScope, .sleepRegistered(deadline))
                fixture.clock.advance(to: deadline)
                _ = try await expiry.firstArrival()
                expiry.release()
                try await expectRetirement(fixture, paneIDs: [paneID])
                for task in fixture.coordinator.restoreRetirementTasksByID.values { await task.value }
                fixture.undoDeadlineLifetimeTask?.cancel()
                #expect(fixture.coordinator.undoStack.isEmpty)
                #expect(await fixture.scrollback.load(paneId: paneID) == .absent)
                let beforeReady = try await retirementEvidenceCount(fixture, paneId: pane.id)
                #expect(beforeReady == 1)
                let preReadyWrite = try await writeRetirementProbe(fixture, repository: repository, paneId: pane.id)
                #expect(preReadyWrite == .admitted, "an installed sink alone must not close foreground admission")
                if window == .beforeSinkInstallation {
                    try await installRetirementOwners(delegate, fixture: fixture)
                }
                #expect(await AppIPCDeferredInitialization.prepareOptionalSchema(using: fixture.datastore))
                delegate.replayBootRestoreRetirements()
                await fixture.coordinator.shutdown()
                let afterReady = try await retirementEvidenceCount(fixture, paneId: pane.id)
                #expect(afterReady == 0)
                let late = try await writeRetirementProbe(fixture, repository: repository, paneId: pane.id)
                #expect(late == .retiredPane)
            }
            try await registrations.finish()
        } catch {
            try? await registrations.finish()
            throw error
        }
    }

    private func installRetirementOwners(_ delegate: AppDelegate, fixture: ScrollbackWorkspaceFixture) async throws {
        await delegate.installRestoreEvidenceOwners(datastore: fixture.datastore)
        try #require(delegate.restoreReportEvidenceRepository != nil)
        delegate.acceptWorkspacePreparedContentMountCohort(
            .init(
                generation: .init(), terminalActivationInput: .init(entries: []),
                nonterminalContentMountInput: .init(entries: [])))
        delegate.bootInstallPreparedContentMountOwners(coordinator: fixture.coordinator)
    }

    private func retirementEvidenceCount(_ fixture: ScrollbackWorkspaceFixture, paneId: UUID) async throws -> Int? {
        try await fixture.datastore.performApplicationLocalRead {
            try Int.fetchOne(
                $0, sql: "SELECT COUNT(*) FROM terminal_pane_foreground_evidence WHERE pane_id = ?",
                arguments: [paneId.uuidString])
        }
    }

    private func writeRetirementProbe(
        _ fixture: ScrollbackWorkspaceFixture, repository: SQLitePaneForegroundEvidenceRepository, paneId: UUID
    ) async throws -> ForegroundEvidenceAdmission {
        try await fixture.datastore.performApplicationLocalWrite {
            try repository.write(
                in: $0, evidence: .reportsUnreadable(.rowRefused), paneId: paneId,
                bindingGenerationId: nil, sequence: 1, observedAt: Date(timeIntervalSince1970: 1))
        }
    }
}

private enum PreReadyDeadlineFact: Equatable, Sendable {
    case sleepRegistered(AgentStudioTestSupport.TestPushClock.Instant)
    case ownerEnded
}
