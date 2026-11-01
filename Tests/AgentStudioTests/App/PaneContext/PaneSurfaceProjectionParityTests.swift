import AgentStudioInfrastructure
import AgentStudioSessions
import AgentStudioSharedComponents
import AgentStudioTestHarness
import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioRepoExplorer

@MainActor
@Suite("Sidebar and Arrangements source parity", .serialized)
struct PaneSurfaceProjectionParityTests {
    @Test("A retained open ask projects one Needs you chip on both real row paths")
    func openAskCountsReachBothSurfaces() async throws {
        try await withAsyncTestCoreAtoms { atoms in
            let fixture = PaneSurfaceProjectionFixture(atoms: atoms)
            fixture.status.apply([
                fixture.pane: .set(
                    .init(status: .idle(.ended), evidence: .verifiedEnded, provider: try .init("claude-code")))
            ])
            atoms.paneContextPresentation.apply([
                fixture.pane: .set(
                    .init(
                        revision: .init(25), agentTitle: nil, agentLine: nil,
                        own: .init(
                            kinds: .init(failure: 0, needsYou: 1, done: 0, info: 0), newestOpenBlockingAskId: nil),
                        includingDrawers: .init(
                            kinds: .init(failure: 0, needsYou: 1, done: 0, info: 0), newestOpenBlockingAskId: nil),
                        pullRequests: .notApplicable))
            ])

            let arrangement = try await ArrangementTableProjector.project(fixture.sources.capture(tabId: fixture.tab))
            let sidebar = try fixture.sidebarRow()

            #expect(sidebar.variants?.compact.chipModels == [.init(kind: .needsYou, count: 1)])
            #expect(arrangement.panes.first?.messageChips.map(\.model) == [.init(kind: .needsYou, count: 1)])
        }
    }

    @Test("An open Arrangements session follows the same keyed status changes as the sidebar")
    func openSessionTracksStatusChanges() async throws {
        try await withAsyncTestCoreAtoms { atoms in
            let fixture = PaneSurfaceProjectionFixture(atoms: atoms)
            let facts = FactRecorder<Int, PaneSurfaceProjectionFact>(
                vocabulary: .init(
                    describeScope: { "source parity opening \($0)" }, describeFact: { String(describing: $0) },
                    isClosing: { _, fact in fact == .finished }))
            fixture.status.apply([
                fixture.pane: .set(
                    .init(status: .idle(.ready), evidence: .verifiedLive, provider: try .init("claude-code")))
            ])
            let session = ArrangementPanelSession(
                sources: fixture.sources, project: { try await ArrangementTableProjector.project($0) },
                onCompletion: { facts.append(scope: 0, fact: .completed($0)) })
            let producer = session.beginArrangementProjection(tabId: fixture.tab)
            let ended = Task {
                await producer.value
                facts.append(scope: 0, fact: .finished)
                facts.receive(.ended)
            }
            do {
                try await facts.expectNext(in: 0, .completed(true))
                try expectStatus(session, fixture: fixture, kind: .idle, label: "Idle")
                for (status, kind, label) in [
                    (AgentSessionStatus.working(.active), StatusLine.Kind.working, "Working"),
                    (.idle(.done), .idle, "Idle"),
                    (.working(.active), .working, "Working"),
                ] {
                    fixture.status.apply([
                        fixture.pane: .set(
                            .init(status: status, evidence: .verifiedLive, provider: try .init("claude-code")))
                    ])
                    try await facts.expectNext(in: 0, .completed(true))
                    try expectStatus(session, fixture: fixture, kind: kind, label: label)
                }
                await session.retireArrangementProjection()?.value
                await ended.value
                try await facts.expectNext(in: 0, .finished)
                try await facts.finish()
            } catch {
                await session.retireArrangementProjection()?.value
                await ended.value
                try? await facts.finish()
                throw error
            }
        }
    }

    private func expectStatus(
        _ session: ArrangementPanelSession, fixture: PaneSurfaceProjectionFixture, kind: StatusLine.Kind, label: String
    ) throws {
        let row = try #require(session.presentation?.panes.first)
        guard case .agent(let status) = row.agentStatus else {
            Issue.record("Arrangements lost the verified status")
            return
        }
        #expect(status.kind == kind)
        #expect(status.label == label)
        #expect(try fixture.sidebarRow().variants?.compact.statusLine?.kind == kind)
    }
}

private enum PaneSurfaceProjectionFact: Equatable, Sendable {
    case completed(Bool)
    case finished
}

/// Real source composition and projectors; the caller supplies canonical atom values without production I/O.
@MainActor
private struct PaneSurfaceProjectionFixture {
    let store: WorkspaceStore
    let atoms: CoreAtoms
    let status = SessionStatusAtom()
    let pane: PaneId
    let tab: UUID
    let readers: PaneContextUIReaders
    let sources: ArrangementPanelSources

    init(atoms: CoreAtoms) {
        self.atoms = atoms
        let store = WorkspaceStore(
            catalogAtom: atoms.workspaceRepositoryTopology, graphAtom: atoms.workspacePane,
            interactionAtom: atoms.workspaceTabLayout)
        self.store = store
        let created = store.createPane(title: "Stored open ask owner")
        pane = .init(existingUUID: created.id)
        let arrangement = PaneArrangement(name: "Default", isDefault: true, layout: .autoTiled([created.id]))
        let tabModel = Tab(
            allPaneIds: [created.id], arrangements: [arrangement], activeArrangementId: arrangement.id)
        tab = tabModel.id
        store.appendTab(tabModel)
        let owners = PaneContextTestSourceOwners(
            sessionStatus: status, presentation: atoms.paneContextPresentation,
            pane: { store.paneAtom.pane($0.uuid) }, serviceProvider: { nil })
        readers = PaneContextUIReaders(
            sessionStatus: status, presentation: atoms.paneContextPresentation,
            pane: { store.paneAtom.pane($0.uuid) },
            popoverBindings: owners.bindings(clock: TestPushClock(), wallNow: { .distantPast }))
        sources = ArrangementPanelSources(store: store, repoCache: atoms.repoCache, readers: readers)
    }

    func sidebarRow() throws -> RepoExplorerProjectedPaneRow {
        let snapshot = RepoExplorerSnapshot(
            repos: [], repoEnrichmentByRepoId: [:], surface: .panes, query: "",
            unassociatedPaneLocations: [
                .init(paneId: pane.uuid, tabId: tab, tabIndex: 0, paneIndexInTab: 0, isActiveInTab: false)
            ])
        let facts = RepoExplorerPaneRowFacts(
            terminalTitle: "Stored open ask owner", sessionPresentation: readers.sessionStatusForPane(pane),
            contextDisplay: readers.contextDisplayForPane(pane), latestMessageText: nil,
            recencyReferenceDate: .distantPast, recencyText: "", isActive: false)
        let projection = RepoExplorerProjection.project(snapshot, paneRowFactsByPaneId: [pane.uuid: facts])
        return try #require(
            projection.resolvedGroups.flatMap { projection.paneRowsByGroupId[$0.id] ?? [] }.first)
    }
}
