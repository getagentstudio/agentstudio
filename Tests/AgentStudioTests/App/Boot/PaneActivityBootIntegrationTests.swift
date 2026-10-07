import AgentStudioInfrastructure
import AgentStudioTestSupport
import Foundation
import GRDB
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioRepoExplorer

@MainActor
@Suite("Pane activity boot integration", .serialized)
struct PaneActivityBootIntegrationTests {
    init() { installTestCoreAtomsIfNeeded() }
    @Test("restored wall age gives the same ordering, bucket, chip and source", arguments: [30.0, 120.0, 14_400.0])
    func restoredAgePresentation(age: Double) {
        let delegate = AppDelegate()
        delegate.atomStore = makeTestAtomRegistry()
        let paneID = UUIDv7.generate()
        let referenceInstant = ContinuousClock.now
        let wallNow = Date(timeIntervalSince1970: 1_800_000_000)
        let record = PaneActivityRecord(paneId: paneID, wallTime: wallNow.addingTimeInterval(-age), source: .hook)
        delegate.applyRestoredPaneActivity([record], referenceInstant: referenceInstant, wallNow: wallNow)
        let restored = delegate.atomStore.core.paneActivityTime.value(for: paneID)
        let original = PaneActivityTime(
            orderingInstant: referenceInstant.advanced(by: .seconds(-age)), wallTime: record.wallTime, source: .hook)
        #expect(restored == original)
        let projected = RepoExplorerPaneActivityProjection.make(
            time: restored, referenceInstant: referenceInstant, wallNow: wallNow, calendar: .current)
        let expected = RepoExplorerPaneActivityProjection.make(
            time: original, referenceInstant: referenceInstant, wallNow: wallNow, calendar: .current)
        #expect(projected.age == .seconds(age))
        #expect(projected.clockText == expected.clockText)
        #expect(projected.unpinnedBucket == expected.unpinnedBucket)
        #expect(projected.pinnedBucket == expected.pinnedBucket)
    }

    @Test("future records clamp ordering to now and live activity wins")
    func futureClampAndLiveWins() {
        let delegate = AppDelegate()
        delegate.atomStore = makeTestAtomRegistry()
        let futureID = UUIDv7.generate()
        let liveID = UUIDv7.generate()
        let referenceInstant = ContinuousClock.now
        let wallNow = Date(timeIntervalSince1970: 1000)
        let live = PaneActivityTime(orderingInstant: referenceInstant, wallTime: wallNow, source: .terminal)
        delegate.atomStore.core.paneActivityTime.apply([.set(liveID, live)])
        delegate.applyRestoredPaneActivity(
            [
                .init(paneId: futureID, wallTime: wallNow.addingTimeInterval(60), source: .hook),
                .init(paneId: liveID, wallTime: wallNow.addingTimeInterval(-60), source: .hook),
            ], referenceInstant: referenceInstant, wallNow: wallNow)
        #expect(delegate.atomStore.core.paneActivityTime.value(for: futureID)?.orderingInstant == referenceInstant)
        #expect(delegate.atomStore.core.paneActivityTime.value(for: futureID)?.source == .hook)
        #expect(delegate.atomStore.core.paneActivityTime.value(for: liveID) == live)
    }

    @Test("the App boot restore entry loads the real datastore before returning")
    func bootRestoreLoadsDatastore() async throws {
        let delegate = AppDelegate()
        delegate.atomStore = makeTestAtomRegistry()
        let workspaceID = delegate.atomStore.core.workspaceIdentity.workspaceId
        let fixture = try makeWorkspaceSQLiteBridgeFixture(workspaceId: workspaceID)
        let datastore = try preparedWorkspaceSQLiteDatastore(from: fixture.backend)
        let pane = makePane(id: UUIDv7.generate())
        let tab = Tab(paneId: pane.id)
        try await datastore.saveWorkspaceSnapshotBundle(
            .emptyTopologyFixture(workspace: .init(id: workspaceID, panes: [pane], tabs: [tab], activeTabId: tab.id)))
        let time = PaneActivityTime(
            orderingInstant: ContinuousClock.now, wallTime: Date(timeIntervalSince1970: 100), source: .terminal)
        try await datastore.commitPaneActivity(.init(mutations: [.set(pane.id, time)]))
        delegate.store = WorkspaceStore(
            identityAtom: delegate.atomStore.core.workspaceIdentity, sqliteDatastore: datastore, startsObserving: false)
        delegate.workspaceSQLiteDatastore = datastore
        await delegate.bootRestorePaneActivity()
        #expect(delegate.atomStore.core.paneActivityTime.value(for: pane.id)?.wallTime == time.wallTime)
        #expect(delegate.atomStore.core.paneActivityTime.value(for: pane.id)?.source == .terminal)
    }
    @Test(
        "invalid retained SQLite activity is skipped and App boot restore continues",
        arguments: ["-1e300", "1e300", "-1e999", "1e999", "'NaN'", "'-Infinity'", "-9.223372036854776e18"]
    )
    func invalidSQLiteActivityDoesNotStopBoot(invalidTimestampSQL: String) async throws {
        let delegate = AppDelegate()
        delegate.atomStore = makeTestAtomRegistry()
        let workspaceID = delegate.atomStore.core.workspaceIdentity.workspaceId
        let fixture = try makeWorkspaceSQLiteBridgeFixture(workspaceId: workspaceID)
        let datastore = try preparedWorkspaceSQLiteDatastore(from: fixture.backend)
        let malformedPane = makePane(id: UUIDv7.generate())
        let validPane = makePane(id: UUIDv7.generate())
        let tab = Tab(paneId: malformedPane.id)
        let validTab = Tab(paneId: validPane.id)
        try await datastore.saveWorkspaceSnapshotBundle(
            .emptyTopologyFixture(
                workspace: .init(
                    id: workspaceID, panes: [malformedPane, validPane], tabs: [tab, validTab], activeTabId: validTab.id
                )))
        let validTime = PaneActivityTime(
            orderingInstant: ContinuousClock.now, wallTime: Date(timeIntervalSince1970: 100), source: .terminal
        )
        try await datastore.commitPaneActivity(.init(mutations: [.set(validPane.id, validTime)]))
        try await fixture.localQueue.write { database in
            try database.execute(
                sql:
                    "INSERT INTO local_pane_activity(pane_id, activity_at, source) VALUES (?, \(invalidTimestampSQL), 'hook')",
                arguments: [malformedPane.id.uuidString]
            )
        }
        let records = try fixture.localRepository.fetchPaneActivity()
        #expect(records.map(\.paneId) == [validPane.id])
        // The red proves decoder rejection without running the unsafe old conversion.
        guard !records.contains(where: { $0.paneId == malformedPane.id }) else { return }
        delegate.store = WorkspaceStore(
            identityAtom: delegate.atomStore.core.workspaceIdentity, sqliteDatastore: datastore, startsObserving: false
        )
        delegate.workspaceSQLiteDatastore = datastore
        await delegate.bootRestorePaneActivity()
        #expect(delegate.atomStore.core.paneActivityTime.value(for: malformedPane.id) == nil)
        #expect(delegate.atomStore.core.paneActivityTime.value(for: validPane.id)?.wallTime == validTime.wallTime)
        #expect(delegate.atomStore.core.paneActivityTime.value(for: validPane.id)?.source == .terminal)
    }

    @Test(
        "restore also rejects non-finite records before conversion",
        arguments: [Double.nan, .infinity, -.infinity, -1e300, 1e300])
    func invalidInMemoryTimeIsSkipped(timestamp: Double) {
        let delegate = AppDelegate()
        delegate.atomStore = makeTestAtomRegistry()
        let paneID = UUIDv7.generate()
        delegate.applyRestoredPaneActivity(
            [.init(paneId: paneID, wallTime: Date(timeIntervalSince1970: timestamp), source: .hook)],
            referenceInstant: ContinuousClock.now,
            wallNow: Date(timeIntervalSince1970: 1000)
        )
        #expect(delegate.atomStore.core.paneActivityTime.value(for: paneID) == nil)
    }

    @Test("restore uses the Duration component representation bound rather than an age horizon")
    func restoreRepresentationBoundary() throws {
        let paneID = UUIDv7.generate()
        let record = PaneActivityRecord(paneId: paneID, wallTime: Date(timeIntervalSince1970: 0), source: .hook)
        let referenceInstant = ContinuousClock.now
        let representableSeconds = Double(Int64.max).nextDown
        let restored = try #require(
            record.restoredActivityTime(
                referenceInstant: referenceInstant,
                wallNow: Date(timeIntervalSince1970: representableSeconds)
            ))
        #expect(
            restored.orderingInstant.duration(to: referenceInstant).components.seconds
                == Int64(exactly: representableSeconds))
        #expect(
            record.restoredActivityTime(
                referenceInstant: referenceInstant,
                wallNow: Date(timeIntervalSince1970: Double(Int64.max))
            ) == nil)
    }

}
