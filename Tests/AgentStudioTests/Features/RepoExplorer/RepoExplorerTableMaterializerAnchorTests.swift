import AgentStudioCore
import AgentStudioInfrastructure
import AppKit
import Testing

@testable import AgentStudioRepoExplorer

extension RepoExplorerTableMaterializerTests {
    @Test("selected pane alone uses its expanded row height")
    func selectionChangesOnlyTwoPaneHeights() throws {
        let firstPaneID = UUIDv7.generate()
        let secondPaneID = UUIDv7.generate()
        let snapshot = paneVariantMaterializerSnapshot([firstPaneID, secondPaneID])
        let materializer = RepoExplorerTableMaterializer(
            octiconLoader: makeRepoExplorerTestOcticonLoader(),
            onVisibleWorktreeSnapshotChange: { _ in }
        )
        let window = makeMaterializerWindow(materializer, height: 90)
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

        let compactFirstHeight = materializer.resolvedHeight(forRowAt: 0)
        let compactSecondHeight = materializer.resolvedHeight(forRowAt: 1)
        #expect(materializer.applySelection(rowID: snapshot.rows[0].id, scrollIntoView: false))
        #expect(materializer.resolvedHeight(forRowAt: 0) > compactFirstHeight)
        #expect(materializer.resolvedHeight(forRowAt: 1) == compactSecondHeight)
        #expect(materializer.applySelection(rowID: snapshot.rows[1].id, scrollIntoView: false))
        #expect(materializer.resolvedHeight(forRowAt: 0) == compactFirstHeight)
        #expect(materializer.resolvedHeight(forRowAt: 1) > compactSecondHeight)
    }

    @Test("candidate selection change remeasures both the prior and new pane rows")
    func candidateSelectionRemeasuresBothRows() throws {
        let paneIDs = [UUIDv7.generate(), UUIDv7.generate()]
        let snapshot = paneVariantMaterializerSnapshot(paneIDs)
        let materializer = RepoExplorerTableMaterializer(
            octiconLoader: makeRepoExplorerTestOcticonLoader(),
            onVisibleWorktreeSnapshotChange: { _ in }
        )
        let window = makeMaterializerWindow(materializer, height: 180)
        defer {
            materializer.detach()
            window.close()
        }
        let firstID = snapshot.rows[0].id
        let secondID = snapshot.rows[1].id
        materializer.apply(
            try tableCandidate(
                baseline: nativePlanRowlessBaseline(.noRepositories, revision: 0),
                snapshot: snapshot,
                requestGeneration: 1,
                selectedRowID: firstID
            )
        ) { _ in }
        let tableView = try #require((materializer.view as? NSScrollView)?.documentView as? NSTableView)
        let compactFirstHeight = snapshot.rows[0].layout.metrics.fallbackHeight
        let expandedFirstHeight = try #require(snapshot.rows[0].expandedPaneLayout?.metrics.fallbackHeight)
        #expect(tableView.rect(ofRow: 0).height == expandedFirstHeight)

        materializer.apply(
            RepoExplorerMaterializationContentCandidate(
                candidateID: RepoExplorerMaterializationCandidateID(rawValue: 2),
                requestGeneration: 2,
                visibleGeneration: 1,
                snapshot: snapshot,
                tableUpdatePlan: .content(
                    RepoExplorerNativeContentUpdatePlan(
                        rowCount: snapshot.rows.count,
                        membershipFingerprint: RepoExplorerMaterializationFingerprint.make(snapshot: snapshot),
                        reloadRowsInNewSpace: [],
                        heightReloadRowsInNewSpace: []
                    )
                ),
                selectedRowID: secondID
            )
        ) { _ in }

        #expect(tableView.rect(ofRow: 0).height == compactFirstHeight)
        #expect(tableView.rect(ofRow: 1).height == expandedFirstHeight)
    }

    @Test("a partly visible pane remains anchored when its bucket row id changes")
    func paneBucketMovePreservesSemanticAnchor() throws {
        let paneIDs = (0..<8).map { _ in UUIDv7.generate() }
        let first = paneVariantMaterializerSnapshot(paneIDs, groupID: "recent")
        let secondOrder = [paneIDs[7]] + Array(paneIDs.dropLast())
        let second = paneVariantMaterializerSnapshot(secondOrder, groupID: "older")
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
                snapshot: first,
                requestGeneration: 1
            )
        ) { _ in }
        materializer.scroll(to: first.rows[3].id, offset: -4)
        #expect(materializer.currentTopVisibleAnchor?.rowID == first.rows[3].id)

        materializer.apply(
            try tableCandidate(
                baseline: nativePlanBaseline(snapshot: first, revision: 1, visibleGeneration: 1),
                snapshot: second,
                requestGeneration: 2
            )
        ) { _ in }

        #expect(materializer.currentTopVisibleAnchor?.rowID == second.rows[4].id)
        #expect(materializer.currentTopVisibleAnchor?.offset == -4)
    }

    @Test("selection expansion above a partly visible pane keeps the pane in place")
    func selectedExpansionPreservesAnchor() throws {
        let paneIDs = (0..<8).map { _ in UUIDv7.generate() }
        let snapshot = paneVariantMaterializerSnapshot(paneIDs)
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
        materializer.scroll(to: snapshot.rows[4].id, offset: -3)
        let priorAnchor = try #require(materializer.currentTopVisibleAnchor)
        #expect(materializer.applySelection(rowID: snapshot.rows[0].id, scrollIntoView: false))
        #expect(materializer.currentTopVisibleAnchor?.rowID == priorAnchor.rowID)
        #expect(materializer.currentTopVisibleAnchor?.offset == priorAnchor.offset)
    }

    @Test("inserting a new section while at the top stays at the top")
    func newSectionAtTopDoesNotScroll() throws {
        let initial = nativePlanSnapshot(["A", "B", "C", "D", "E"])
        let withNewSection = nativePlanSnapshot(["new", "A", "B", "C", "D", "E"])
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
                snapshot: initial,
                requestGeneration: 1
            )
        ) { _ in }
        materializer.apply(
            try tableCandidate(
                baseline: nativePlanBaseline(snapshot: initial, revision: 1, visibleGeneration: 1),
                snapshot: withNewSection,
                requestGeneration: 2
            )
        ) { _ in }
        #expect(materializer.currentTopVisibleAnchor?.rowID == .group(groupID: "new"))
        #expect(materializer.scrollView.contentView.documentVisibleRect.minY == 0)
    }

    private func paneVariantMaterializerSnapshot(
        _ paneIDs: [UUID],
        groupID: String = "recent"
    ) -> RepoExplorerMaterializationSnapshot {
        let rows = paneIDs.map { paneID in
            let destination = RepoExplorerUnassociatedPaneDestination(
                paneId: paneID,
                tabId: UUIDv7.generate(),
                tabIndex: 0,
                paneIndexInTab: 0,
                isActiveInTab: false
            )
            var pane = RepoExplorerProjectedPaneRow(
                groupId: groupID,
                destination: destination,
                rowId: paneID.uuidString,
                primaryText: "Pane"
            )
            pane.variants = RepoExplorerPaneRowVariants(
                compact: RepoExplorerPaneRowVariant(
                    lines: [.title("Pane")]
                ),
                expanded: RepoExplorerPaneRowVariant(
                    lines: [.title("Pane"), .worktreeBranch("repo · main"), .note("Note")]
                )
            )
            pane.displayVariant = .expanded
            let expandedLayout = RepoExplorerRowLayout.make(for: .pane(pane))
            pane.displayVariant = .compact
            let presentation = RepoExplorerMaterializedRowPresentation.pane(pane)
            return RepoExplorerMaterializedRow(
                id: .tabPane(groupID: groupID, paneID: paneID),
                contentRevision: RepoExplorerRowContentRevision(presentation: presentation),
                layout: RepoExplorerRowLayout.make(for: presentation),
                representedRepoID: nil,
                representedWorktreeID: nil,
                expandedPaneLayout: expandedLayout
            )
        }
        return RepoExplorerMaterializationSnapshot(rows: rows)
    }

}
