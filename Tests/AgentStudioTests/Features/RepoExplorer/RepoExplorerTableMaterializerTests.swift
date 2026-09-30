import AgentStudioCore
import AgentStudioInfrastructure
import AppKit
import Testing

@testable import AgentStudioRepoExplorer

@MainActor
@Suite("Repo Explorer table materializer", .serialized)
struct RepoExplorerTableMaterializerTests {
    @Test("native proof fingerprint detects same-count stale bindings and restamps after scroll")
    func nativeVisibleProjectionFingerprintTracksBoundRows() async throws {
        let snapshot = nativePlanSnapshot(["A", "B", "C", "D", "E", "F", "G", "H"])
        let materializer = RepoExplorerTableMaterializer(
            octiconLoader: makeRepoExplorerTestOcticonLoader(),
            onVisibleWorktreeSnapshotChange: { _ in }
        )
        let window = makeMaterializerWindow(materializer, height: 40)
        defer {
            materializer.detach()
            window.close()
        }
        materializer.apply(
            try tableCandidate(
                baseline: nativePlanRowlessBaseline(.noRepositories, revision: 0),
                snapshot: snapshot,
                requestGeneration: 1
            )
        ) { _ in }
        let tableView = try #require((materializer.view as? NSScrollView)?.documentView as? NSTableView)
        materializeVisibleCells(in: tableView, visibleRect: tableView.visibleRect)
        await materializer.drainViewportPublication()
        let matching = try #require(RepoExplorerNativeVisibleProjectionReadback.capture(in: tableView))
        #expect(
            matching.matches(
                materializationGeneration: 1,
                materializationFingerprint: RepoExplorerMaterializationFingerprint.make(snapshot: snapshot).rawValue
            )
        )

        let firstVisibleRow = tableView.rows(in: tableView.visibleRect).location
        let firstCell = try #require(
            tableView.view(atColumn: 0, row: firstVisibleRow, makeIfNecessary: false)
                as? RepoExplorerTableRowCell
        )
        _ = firstCell.bind(row: snapshot.rows[firstVisibleRow + 1], visibleGeneration: 1)
        let staleBinding = try #require(RepoExplorerNativeVisibleProjectionReadback.capture(in: tableView))
        #expect(staleBinding.visibleRowCount == matching.visibleRowCount)
        #expect(staleBinding.actualVisibleFingerprint != staleBinding.expectedVisibleFingerprint)

        materializer.scroll(to: RepoExplorerRowID.group(groupID: "H"), offset: 0)
        materializeVisibleCells(in: tableView, visibleRect: tableView.visibleRect)
        await materializer.drainViewportPublication()
        let scrolled = try #require(RepoExplorerNativeVisibleProjectionReadback.capture(in: tableView))
        #expect(scrolled.expectedVisibleFingerprint != matching.expectedVisibleFingerprint)
        #expect(scrolled.actualVisibleFingerprint == scrolled.expectedVisibleFingerprint)
    }

    @Test("resume rebinds represented cells when layout returns after zero-size suspension")
    func resumeRebindsRepresentedCellsAfterZeroSizeLayout() async throws {
        try await verifyResumeRebindsAfterZeroSizeLayout()
    }

    @Test("resume at the existing size rebinds represented cells immediately")
    func resumeAtExistingSizeRebindsRepresentedCellsImmediately() async throws {
        try await verifyResumeRebindsAtExistingSize()
    }

    @Test("represented By Repo settlement publishes exact receipt without moving its anchor")
    func representedByRepoSettlementPublishesExactReceiptWithoutMovingAnchor() async throws {
        let repoID = UUIDv7.generate()
        let attemptID = UUIDv7.generate()
        let capturedProgress = RepositoryFactUpdateProgress.captured(
            repoId: repoID,
            attemptId: attemptID
        )
        let inactiveSnapshot = repositoryActivityMaterializerSnapshot(
            repoID: repoID,
            progress: nil
        )
        let capturedSnapshot = repositoryActivityMaterializerSnapshot(
            repoID: repoID,
            progress: capturedProgress
        )
        let settledSnapshot = repositoryActivityMaterializerSnapshot(
            repoID: repoID,
            progress: capturedProgress.settled([:])
        )
        let recorder = VisibleWorktreeSnapshotRecorder()
        let materializer = RepoExplorerTableMaterializer(
            octiconLoader: makeRepoExplorerTestOcticonLoader(),
            onVisibleWorktreeSnapshotChange: recorder.record
        )
        let window = makeMaterializerWindow(materializer, height: 20)
        defer {
            materializer.detach()
            window.close()
        }

        materializer.apply(
            try tableCandidate(
                baseline: nativePlanRowlessBaseline(.noRepositories, revision: 0),
                snapshot: inactiveSnapshot,
                requestGeneration: 1
            )
        ) { _ in }
        let tableView = try #require((materializer.view as? NSScrollView)?.documentView as? NSTableView)
        let inactiveRect = tableView.rect(ofRow: 0)

        materializer.apply(
            try tableCandidate(
                baseline: nativePlanBaseline(
                    snapshot: inactiveSnapshot,
                    revision: 1,
                    visibleGeneration: 1
                ),
                snapshot: capturedSnapshot,
                requestGeneration: 2
            )
        ) { _ in }
        materializer.scroll(to: .group(groupID: "repo-activity"), offset: -3)
        await materializer.drainViewportPublication()
        #expect(recorder.snapshots.last?.settledUpdateAttemptByRepositoryID.isEmpty == true)
        let capturedRect = tableView.rect(ofRow: 0)

        materializer.apply(
            try tableCandidate(
                baseline: nativePlanBaseline(
                    snapshot: capturedSnapshot,
                    revision: 2,
                    visibleGeneration: 2
                ),
                snapshot: settledSnapshot,
                requestGeneration: 3
            )
        ) { _ in }
        await materializer.drainViewportPublication()

        #expect(inactiveRect == capturedRect)
        #expect(capturedRect == tableView.rect(ofRow: 0))
        #expect(materializer.currentTopVisibleAnchor?.rowID == .group(groupID: "repo-activity"))
        #expect(materializer.currentTopVisibleAnchor?.offset == -3)
        #expect(recorder.snapshots.last?.repositoryIDs == [repoID])
        #expect(recorder.snapshots.last?.settledUpdateAttemptByRepositoryID == [repoID: attemptID])
    }

    @Test("nonrepresented and non-Repo headers publish no repository control or settlement receipt")
    func hiddenAndNonRepoHeadersPublishNoRepositoryControlOrSettlementReceipt() async throws {
        let repoID = UUIDv7.generate()
        let attemptID = UUIDv7.generate()
        let settledProgress = RepositoryFactUpdateProgress.captured(
            repoId: repoID,
            attemptId: attemptID
        ).settled([:])
        let hiddenHeader = repositoryActivityMaterializerSnapshot(
            repoID: repoID,
            progress: settledProgress
        ).rows[0]
        let representedRows = nativePlanSnapshot(["A", "B", "C", "D"]).rows
        let hiddenSnapshot = RepoExplorerMaterializationSnapshot(
            rows: representedRows + [hiddenHeader]
        )
        let nonRepoSnapshot = repositoryActivityMaterializerSnapshot(
            repoID: repoID,
            presentsRepositoryActivity: false,
            progress: settledProgress
        )
        let recorder = VisibleWorktreeSnapshotRecorder()
        let materializer = RepoExplorerTableMaterializer(
            octiconLoader: makeRepoExplorerTestOcticonLoader(),
            onVisibleWorktreeSnapshotChange: recorder.record
        )
        let window = makeMaterializerWindow(materializer)
        defer {
            materializer.detach()
            window.close()
        }

        materializer.apply(
            try tableCandidate(
                baseline: nativePlanRowlessBaseline(.noRepositories, revision: 0),
                snapshot: hiddenSnapshot,
                requestGeneration: 1
            )
        ) { _ in }
        await materializer.drainViewportPublication()
        #expect(recorder.snapshots.last?.repositoryIDs.isEmpty == true)
        #expect(recorder.snapshots.last?.settledUpdateAttemptByRepositoryID.isEmpty == true)

        materializer.apply(
            try tableCandidate(
                baseline: nativePlanBaseline(
                    snapshot: hiddenSnapshot,
                    revision: 1,
                    visibleGeneration: 1
                ),
                snapshot: nonRepoSnapshot,
                requestGeneration: 2
            )
        ) { _ in }
        await materializer.drainViewportPublication()
        #expect(recorder.snapshots.last?.repositoryIDs.isEmpty == true)
        #expect(recorder.snapshots.last?.settledUpdateAttemptByRepositoryID.isEmpty == true)
    }

    @Test("native table reveals the established sidebar chrome background")
    func nativeTableRevealsSidebarChromeBackground() throws {
        let materializer = RepoExplorerTableMaterializer(
            octiconLoader: makeRepoExplorerTestOcticonLoader(),
            onVisibleWorktreeSnapshotChange: { _ in }
        )
        defer { materializer.detach() }

        let scrollView = try #require(materializer.view as? NSScrollView)
        let tableView = try #require(scrollView.documentView as? NSTableView)

        #expect(!scrollView.drawsBackground)
        #expect(tableView.backgroundColor == .clear)
    }

    @Test("viewport coalesces the latest visible set and clears on detach")
    func viewportCoalescesAndClears() async throws {
        let firstWorktreeID = UUIDv7.generate()
        let secondWorktreeID = UUIDv7.generate()
        let snapshot = materializerSnapshot(
            ["A", "B", "C", "D"],
            worktreeIDs: [firstWorktreeID, secondWorktreeID, nil, nil]
        )
        let recorder = VisibleWorktreeSetRecorder()
        let materializer = RepoExplorerTableMaterializer(
            octiconLoader: makeRepoExplorerTestOcticonLoader(),
            onVisibleWorktreeSnapshotChange: recorder.record
        )
        let window = makeMaterializerWindow(materializer)
        defer {
            materializer.detach()
            window.close()
        }

        materializer.apply(
            try tableCandidate(
                baseline: nativePlanRowlessBaseline(.noRepositories, revision: 0),
                snapshot: snapshot,
                requestGeneration: 1
            )
        ) { _ in }
        materializer.scroll(to: .group(groupID: "A"), offset: 0)
        materializer.scroll(to: .group(groupID: "B"), offset: 0)
        await materializer.drainViewportPublication()

        #expect(recorder.values.last == [secondWorktreeID])
        let callCountAfterLatestViewport = recorder.values.count
        materializer.scroll(to: .group(groupID: "B"), offset: 0)
        await materializer.drainViewportPublication()
        #expect(recorder.values.count == callCountAfterLatestViewport)

        materializer.detach()
        #expect(recorder.values.last?.isEmpty == true)
    }

    @Test("demand suspension invalidates queued viewport work and reentry republishes current rows")
    func demandLifecycleInvalidatesAndRepublishesViewport() async throws {
        let worktreeID = UUIDv7.generate()
        let snapshot = materializerSnapshot(
            ["A", "B", "C", "D"],
            worktreeIDs: [worktreeID, nil, nil, nil]
        )
        let recorder = VisibleWorktreeSetRecorder()
        let materializer = RepoExplorerTableMaterializer(
            octiconLoader: makeRepoExplorerTestOcticonLoader(),
            onVisibleWorktreeSnapshotChange: recorder.record
        )
        let window = makeMaterializerWindow(materializer)
        defer {
            materializer.detach()
            window.close()
        }
        materializer.apply(
            try tableCandidate(
                baseline: nativePlanRowlessBaseline(.noRepositories, revision: 0),
                snapshot: snapshot,
                requestGeneration: 1
            )
        ) { _ in }
        materializer.scroll(to: .group(groupID: "A"), offset: 0)

        materializer.suspendDemand()
        await materializer.drainViewportPublication()
        let suspendedSnapshot = try #require(recorder.snapshots.last)
        #expect(suspendedSnapshot.worktreeIDs.isEmpty)

        materializer.resumeDemand(visibleGeneration: 1)
        await materializer.drainViewportPublication()
        let resumedSnapshot = try #require(recorder.snapshots.last)
        #expect(recorder.values.last == [worktreeID])
        #expect(resumedSnapshot.target != suspendedSnapshot.target)

        materializer.suspendDemand()
        let publicationCountAfterClear = recorder.values.count
        #expect(recorder.values.last?.isEmpty == true)
        materializer.suspendDemand()
        #expect(recorder.values.count == publicationCountAfterClear)

        materializer.resumeDemand(visibleGeneration: 999)
        await materializer.drainViewportPublication()
        #expect(recorder.values.count == publicationCountAfterClear)
        materializer.resumeDemand(visibleGeneration: 1)
        await materializer.drainViewportPublication()
        #expect(recorder.values.last == [worktreeID])
    }

    @Test("width measurement is limited to represented wrapping rows")
    func widthMeasurementIsVisibleOnly() throws {
        let snapshot = wrappingMaterializerSnapshot(["A", "B", "C", "D"])
        let measurementRecorder = VisibleHeightMeasurementRecorder()
        let materializer = RepoExplorerTableMaterializer(
            octiconLoader: makeRepoExplorerTestOcticonLoader(),
            onVisibleWorktreeSnapshotChange: { _ in },
            measureVisibleRowHeight: measurementRecorder.measure
        )
        let window = makeMaterializerWindow(materializer)
        defer {
            materializer.detach()
            window.close()
        }
        materializer.apply(
            try tableCandidate(
                baseline: nativePlanRowlessBaseline(.noRepositories, revision: 0),
                snapshot: snapshot,
                requestGeneration: 1
            )
        ) { _ in }

        let callCountBeforeOffscreenRead = measurementRecorder.callCount
        let offscreenHeight = materializer.resolvedHeight(forRowAt: 3)
        #expect(measurementRecorder.callCount == callCountBeforeOffscreenRead)
        materializer.scroll(to: .group(groupID: "B"), offset: 0)
        let visibleHeight = materializer.resolvedHeight(forRowAt: 1)

        #expect(
            (callCountBeforeOffscreenRead...(callCountBeforeOffscreenRead + 1))
                .contains(measurementRecorder.callCount)
        )
        #expect(visibleHeight > offscreenHeight)
    }

    @Test("hosted cell count stays represented-bounded when offscreen membership doubles")
    func hostedCellCountStaysBoundedWhenOffscreenRowsDouble() throws {
        let baselineSnapshot = nativePlanSnapshot((0..<180).map { "row-\($0)" })
        let doubledSnapshot = nativePlanSnapshot((0..<360).map { "row-\($0)" })
        let materializer = RepoExplorerTableMaterializer(
            octiconLoader: makeRepoExplorerTestOcticonLoader(),
            onVisibleWorktreeSnapshotChange: { _ in }
        )
        let window = makeMaterializerWindow(materializer)
        defer {
            materializer.detach()
            window.close()
        }
        materializer.apply(
            try tableCandidate(
                baseline: nativePlanRowlessBaseline(.noRepositories, revision: 0),
                snapshot: baselineSnapshot,
                requestGeneration: 1
            )
        ) { _ in }
        let scrollView = try #require(materializer.view as? NSScrollView)
        let tableView = try #require(scrollView.documentView as? NSTableView)
        materializeVisibleCells(in: tableView, visibleRect: scrollView.contentView.documentVisibleRect)
        let baselineHostCount = materializer.hostedCellCreationCount
        tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        #expect(tableView.selectedRowIndexes.isEmpty)

        materializer.apply(
            try tableCandidate(
                baseline: nativePlanBaseline(
                    snapshot: baselineSnapshot,
                    revision: 1,
                    visibleGeneration: 1
                ),
                snapshot: doubledSnapshot,
                requestGeneration: 2
            )
        ) { _ in }
        materializeVisibleCells(in: tableView, visibleRect: scrollView.contentView.documentVisibleRect)

        #expect(baselineHostCount > 0)
        #expect(baselineHostCount <= 8)
        #expect(materializer.hostedCellCreationCount <= baselineHostCount + 2)
    }
}

extension RepoExplorerTableMaterializerTests {
    @Test("command deltas reject stale lifetime and rebind represented occurrences only")
    func commandDeltaRejectsStaleLifetimeAndRebindsRepresentedOnly() async throws {
        let hostLifetimeID = RepoExplorerMaterializationHostLifetimeID(rawValue: UUIDv7.generate())
        let staleLifetimeID = RepoExplorerMaterializationHostLifetimeID(rawValue: UUIDv7.generate())
        let worktreeID = UUIDv7.generate()
        let source = nativePlanSnapshot((0..<8).map { "row-\($0)" })
        let snapshot = RepoExplorerMaterializationSnapshot(
            rows: source.rows.map { row in
                RepoExplorerMaterializedRow(
                    id: row.id,
                    contentRevision: row.contentRevision,
                    layout: row.layout,
                    representedRepoID: nil,
                    representedWorktreeID: worktreeID
                )
            }
        )
        let recorder = VisibleWorktreeSnapshotRecorder()
        let materializer = RepoExplorerTableMaterializer(
            materializationHostLifetimeID: hostLifetimeID,
            octiconLoader: makeRepoExplorerTestOcticonLoader(),
            onVisibleWorktreeSnapshotChange: recorder.record,
            observeCurrentVisibleTarget: recorder.recordStale
        )
        let window = makeMaterializerWindow(materializer)
        defer {
            materializer.detach()
            window.close()
        }
        materializer.apply(
            try tableCandidate(
                baseline: nativePlanRowlessBaseline(.noRepositories, revision: 0),
                snapshot: snapshot,
                requestGeneration: 1
            )
        ) { _ in }
        await materializer.drainViewportPublication()
        let currentVisibleSnapshot = try #require(recorder.snapshots.last)
        let scrollView = try #require(materializer.view as? NSScrollView)
        let tableView = try #require(scrollView.documentView as? NSTableView)
        materializeVisibleCells(in: tableView, visibleRect: scrollView.contentView.documentVisibleRect)
        let hostedCellCount = materializer.hostedCellCreationCount
        let commandSnapshot = RepoExplorerCommandPresentationSnapshot(generation: 5, results: [:])
        let staleTarget = RepoExplorerCommandPresentationTarget(
            materializationHostLifetimeID: staleLifetimeID,
            materializationGeneration: 1,
            visibleRevision: currentVisibleSnapshot.target.visibleRevision
        )
        let staleDelta = RepoExplorerCommandPresentationDelta(
            commandGeneration: 5,
            target: staleTarget,
            snapshot: commandSnapshot,
            affectedWorktreeIDs: [worktreeID],
            affectedRepositoryIDs: [],
            affectedRequestIdentities: [],
            toolbarChanged: false
        )

        #expect(
            materializer.applyCommandPresentationDelta(staleDelta)
                == .stale(currentVisibleSnapshot: currentVisibleSnapshot)
        )
        #expect(recorder.staleSnapshots == [currentVisibleSnapshot])
        let currentDelta = RepoExplorerCommandPresentationDelta(
            commandGeneration: 5,
            target: currentVisibleSnapshot.target,
            snapshot: commandSnapshot,
            affectedWorktreeIDs: [worktreeID],
            affectedRepositoryIDs: [],
            affectedRequestIdentities: [],
            toolbarChanged: false
        )
        let disposition = materializer.applyCommandPresentationDelta(currentDelta)

        guard case .accepted(let reboundRowCount) = disposition else {
            Issue.record("expected current command delta acceptance")
            return
        }
        #expect(reboundRowCount > 0)
        #expect(reboundRowCount < snapshot.rows.count)
        #expect(materializer.hostedCellCreationCount == hostedCellCount)
        #expect(
            materializer.applyCommandPresentationDelta(currentDelta)
                == .duplicateOrOlderCommandGeneration
        )
    }

    @Test("membership apply uses the sole applier and preserves a surviving row anchor")
    func membershipApplyPreservesSurvivingAnchor() throws {
        let initialSnapshot = nativePlanSnapshot(["A", "B", "C", "D", "E", "F"])
        let nextSnapshot = nativePlanSnapshot(["F", "A", "B", "C", "D", "E"])
        let materializer = RepoExplorerTableMaterializer(
            octiconLoader: makeRepoExplorerTestOcticonLoader(),
            onVisibleWorktreeSnapshotChange: { _ in }
        )
        let window = makeMaterializerWindow(materializer)
        defer {
            materializer.detach()
            window.close()
        }

        let initialCandidate = try tableCandidate(
            baseline: nativePlanRowlessBaseline(.noRepositories, revision: 0),
            snapshot: initialSnapshot,
            requestGeneration: 1
        )
        var disposition: RepoExplorerMaterializationChildDisposition?
        materializer.apply(initialCandidate) { disposition = $0 }
        #expect(disposition == .accepted)

        materializer.scroll(to: .group(groupID: "C"), offset: 3)
        let priorAnchor = try #require(materializer.currentTopVisibleAnchor)
        let nextCandidate = try tableCandidate(
            baseline: nativePlanBaseline(
                snapshot: initialSnapshot,
                revision: 1,
                visibleGeneration: 1
            ),
            snapshot: nextSnapshot,
            requestGeneration: 2
        )
        disposition = nil
        materializer.apply(nextCandidate) { disposition = $0 }

        #expect(disposition == .accepted)
        #expect(materializer.numberOfRows == nextSnapshot.rows.count)
        #expect(materializer.currentTopVisibleAnchor?.rowID == priorAnchor.rowID)
        #expect(materializer.currentTopVisibleAnchor?.offset == priorAnchor.offset)
        #expect(materializer.nativeTransactionApplyCount == 2)
    }

    @Test("membership apply accepts combined removals moves and insertions")
    func membershipApplyAcceptsCombinedStructuralChanges() throws {
        let initialSnapshot = nativePlanSnapshot(["A", "B", "C", "D"])
        let nextSnapshot = nativePlanSnapshot(["D", "A", "E"])
        let materializer = RepoExplorerTableMaterializer(
            octiconLoader: makeRepoExplorerTestOcticonLoader(),
            onVisibleWorktreeSnapshotChange: { _ in }
        )
        let window = makeMaterializerWindow(materializer)
        defer {
            materializer.detach()
            window.close()
        }

        materializer.apply(
            try tableCandidate(
                baseline: nativePlanRowlessBaseline(.noRepositories, revision: 0),
                snapshot: initialSnapshot,
                requestGeneration: 1
            )
        ) { _ in }
        var disposition: RepoExplorerMaterializationChildDisposition?
        materializer.apply(
            try tableCandidate(
                baseline: nativePlanBaseline(
                    snapshot: initialSnapshot,
                    revision: 1,
                    visibleGeneration: 1
                ),
                snapshot: nextSnapshot,
                requestGeneration: 2
            )
        ) { disposition = $0 }

        #expect(disposition == .accepted)
        #expect(materializer.numberOfRows == nextSnapshot.rows.count)
    }

    @Test("filtered membership restores heterogeneous row geometry")
    func filteredMembershipRestoresHeterogeneousRowGeometry() throws {
        let initialSnapshot = heterogeneousHeightSnapshot(
            identitiesAndHeights: [
                ("A", 34),
                ("B", 96),
                ("C", 42),
                ("D", 118),
                ("E", 50),
            ]
        )
        let retainedRowIDs: [RepoExplorerRowID] = [
            .group(groupID: "B"),
            .group(groupID: "D"),
        ]
        let filteredSnapshot = RepoExplorerMaterializationSnapshot(
            rows: retainedRowIDs.compactMap(initialSnapshot.row(id:))
        )
        let materializer = RepoExplorerTableMaterializer(
            octiconLoader: makeRepoExplorerTestOcticonLoader(),
            onVisibleWorktreeSnapshotChange: { _ in }
        )
        let window = makeMaterializerWindow(materializer)
        defer {
            materializer.detach()
            window.close()
        }

        materializer.apply(
            try tableCandidate(
                baseline: nativePlanRowlessBaseline(.noRepositories, revision: 0),
                snapshot: initialSnapshot,
                requestGeneration: 1
            )
        ) { _ in }
        materializer.apply(
            try tableCandidate(
                baseline: nativePlanBaseline(
                    snapshot: initialSnapshot,
                    revision: 1,
                    visibleGeneration: 1
                ),
                snapshot: filteredSnapshot,
                requestGeneration: 2
            )
        ) { _ in }

        let scrollView = try #require(materializer.view as? NSScrollView)
        let tableView = try #require(scrollView.documentView as? NSTableView)
        let firstRowRect = tableView.rect(ofRow: 0)
        let secondRowRect = tableView.rect(ofRow: 1)
        #expect(firstRowRect.minY == 0)
        #expect(firstRowRect.height == 96)
        #expect(secondRowRect.minY == firstRowRect.maxY)
        #expect(secondRowRect.height == 118)
        #expect(secondRowRect.maxY == filteredSnapshot.fallbackContentHeight)
    }

    @Test("removed row anchor restores its worker-derived successor")
    func removedAnchorUsesPlanFallback() throws {
        let initialSnapshot = nativePlanSnapshot(["A", "B", "C", "D", "E", "F"])
        let nextSnapshot = nativePlanSnapshot(["A", "B", "E", "F"])
        let materializer = RepoExplorerTableMaterializer(
            octiconLoader: makeRepoExplorerTestOcticonLoader(),
            onVisibleWorktreeSnapshotChange: { _ in }
        )
        let window = makeMaterializerWindow(materializer)
        defer {
            materializer.detach()
            window.close()
        }

        materializer.apply(
            try tableCandidate(
                baseline: nativePlanRowlessBaseline(.noRepositories, revision: 0),
                snapshot: initialSnapshot,
                requestGeneration: 1
            )
        ) { _ in }
        materializer.scroll(to: .group(groupID: "C"), offset: -2)
        var disposition: RepoExplorerMaterializationChildDisposition?
        materializer.apply(
            try tableCandidate(
                baseline: nativePlanBaseline(
                    snapshot: initialSnapshot,
                    revision: 1,
                    visibleGeneration: 1
                ),
                snapshot: nextSnapshot,
                requestGeneration: 2
            )
        ) { disposition = $0 }

        #expect(disposition == .accepted)
        #expect(materializer.currentTopVisibleAnchor?.rowID == .group(groupID: "E"))
        #expect(materializer.currentTopVisibleAnchor?.offset == -2)
    }

    func makeMaterializerWindow(
        _ materializer: RepoExplorerTableMaterializer,
        height: CGFloat = 36
    ) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: height),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = materializer.view
        window.layoutIfNeeded()
        return window
    }

    func tableCandidate(
        baseline: RepoExplorerMaterializationBaseline,
        snapshot: RepoExplorerMaterializationSnapshot,
        requestGeneration: UInt64,
        selectedRowID: RepoExplorerRowID? = nil
    ) throws -> RepoExplorerMaterializationContentCandidate {
        let presentation = nativePlanContent(snapshot)
        let plan = try RepoExplorerNativeUpdatePlan.validating(
            baseline: baseline,
            candidate: presentation,
            requestGeneration: requestGeneration
        ).get()
        let tablePlan = try #require(plan.tableUpdatePlan())
        return RepoExplorerMaterializationContentCandidate(
            candidateID: RepoExplorerMaterializationCandidateID(rawValue: requestGeneration),
            requestGeneration: requestGeneration,
            visibleGeneration: requestGeneration,
            snapshot: snapshot,
            tableUpdatePlan: tablePlan,
            selectedRowID: selectedRowID
        )
    }

    private func materializerSnapshot(
        _ identities: [String],
        worktreeIDs: [UUID?]
    ) -> RepoExplorerMaterializationSnapshot {
        let source = nativePlanSnapshot(identities)
        return RepoExplorerMaterializationSnapshot(
            rows: zip(source.rows, worktreeIDs).map { row, worktreeID in
                RepoExplorerMaterializedRow(
                    id: row.id,
                    contentRevision: row.contentRevision,
                    layout: row.layout,
                    representedRepoID: nil,
                    representedWorktreeID: worktreeID
                )
            }
        )
    }

    private func wrappingMaterializerSnapshot(
        _ identities: [String]
    ) -> RepoExplorerMaterializationSnapshot {
        let source = nativePlanSnapshot(identities)
        return RepoExplorerMaterializationSnapshot(
            rows: source.rows.map { row in
                RepoExplorerMaterializedRow(
                    id: row.id,
                    contentRevision: row.contentRevision,
                    layout: RepoExplorerRowLayout(
                        rowClass: row.layout.rowClass,
                        metrics: row.layout.metrics,
                        requiresVisibleWidthMeasurement: true
                    ),
                    representedRepoID: nil,
                    representedWorktreeID: nil
                )
            }
        )
    }

    private func repositoryActivityMaterializerSnapshot(
        repoID: UUID,
        presentsRepositoryActivity: Bool = true,
        progress: RepositoryFactUpdateProgress?
    ) -> RepoExplorerMaterializationSnapshot {
        let group = RepoExplorerMaterializedGroupHeaderPresentation(
            groupID: "repo-activity",
            icon: .repo,
            title: "Repository",
            organizationName: nil,
            colorHex: nil,
            isExpanded: true,
            repoIDs: [repoID],
            semanticRepoPath: URL(filePath: "/tmp/repository"),
            paneDestinations: [],
            presentsRepositoryActivity: presentsRepositoryActivity,
            repositoryActivityDisposition: .locallyInactive,
            repositoryFactUpdateProgress: progress
        )
        let presentation = RepoExplorerMaterializedRowPresentation.groupHeader(group)
        let activityRow = RepoExplorerMaterializedRow(
            id: .group(groupID: group.groupID),
            contentRevision: RepoExplorerRowContentRevision(presentation: presentation),
            layout: RepoExplorerRowLayout.make(for: presentation),
            representedRepoID: repoID,
            representedWorktreeID: nil
        )
        return RepoExplorerMaterializationSnapshot(
            rows: [activityRow] + nativePlanSnapshot(["trailing-row"]).rows
        )
    }

    private func heterogeneousHeightSnapshot(
        identitiesAndHeights: [(String, CGFloat)]
    ) -> RepoExplorerMaterializationSnapshot {
        let source = nativePlanSnapshot(identitiesAndHeights.map(\.0))
        return RepoExplorerMaterializationSnapshot(
            rows: zip(source.rows, identitiesAndHeights.map(\.1)).map { row, height in
                let metrics = row.layout.metrics
                return RepoExplorerMaterializedRow(
                    id: row.id,
                    contentRevision: row.contentRevision,
                    layout: RepoExplorerRowLayout(
                        rowClass: row.layout.rowClass,
                        metrics: RepoExplorerRowLayoutMetrics(
                            primaryLineHeight: metrics.primaryLineHeight,
                            metadataLineHeight: metrics.metadataLineHeight,
                            chipLineHeight: metrics.chipLineHeight,
                            contentSpacing: metrics.contentSpacing,
                            verticalInset: metrics.verticalInset,
                            leadingInset: metrics.leadingInset,
                            trailingInset: metrics.trailingInset,
                            minimumHeight: height,
                            fallbackHeight: height
                        ),
                        requiresVisibleWidthMeasurement: false
                    ),
                    representedRepoID: nil,
                    representedWorktreeID: nil
                )
            }
        )
    }
}

@MainActor
private func materializeVisibleCells(in tableView: NSTableView, visibleRect: NSRect) {
    let visibleRows = tableView.rows(in: visibleRect)
    guard visibleRows.location != NSNotFound else { return }
    for rowIndex in visibleRows.location..<NSMaxRange(visibleRows) {
        _ = tableView.view(atColumn: 0, row: rowIndex, makeIfNecessary: true)
    }
}

@MainActor
private final class VisibleWorktreeSetRecorder {
    private(set) var values: [Set<UUID>] = []
    private(set) var snapshots: [RepoExplorerVisibleWorktreeSnapshot] = []

    func record(_ snapshot: RepoExplorerVisibleWorktreeSnapshot) {
        snapshots.append(snapshot)
        values.append(snapshot.worktreeIDs)
    }
}

@MainActor
private final class VisibleWorktreeSnapshotRecorder {
    private(set) var snapshots: [RepoExplorerVisibleWorktreeSnapshot] = []
    private(set) var staleSnapshots: [RepoExplorerVisibleWorktreeSnapshot] = []

    func record(_ snapshot: RepoExplorerVisibleWorktreeSnapshot) {
        snapshots.append(snapshot)
    }

    func recordStale(_ snapshot: RepoExplorerVisibleWorktreeSnapshot) {
        staleSnapshots.append(snapshot)
    }
}

@MainActor
private final class VisibleHeightMeasurementRecorder {
    private(set) var callCount = 0

    func measure(_ row: RepoExplorerMaterializedRow, availableWidth: CGFloat) -> CGFloat {
        callCount += 1
        return row.layout.metrics.fallbackHeight + max(1, availableWidth / 100)
    }
}
