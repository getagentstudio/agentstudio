import AgentStudioCore
import AgentStudioInfrastructure
import AppKit
import Testing

@testable import AgentStudioRepoExplorer

@MainActor
@Suite(.serialized)
struct RepoExplorerPaneContextAnchorTests {
    @Test("pane status line growth, replacement and removal preserve the intersecting row anchor")
    func contextLineHeightChangesPreserveViewport() throws {
        let paneIDs = (0..<8).map { _ in UUIDv7.generate() }
        func paneSnapshot(status: AgentSessionStatus?) -> RepoExplorerMaterializationSnapshot {
            RepoExplorerMaterializationSnapshot(
                rows: paneIDs.map { paneID in
                    var pane = RepoExplorerProjectedPaneRow(
                        groupId: "panes",
                        destination: RepoExplorerUnassociatedPaneDestination(
                            paneId: paneID, tabId: paneIDs[0], tabIndex: 0, paneIndexInTab: 0, isActiveInTab: false),
                        rowId: paneID.uuidString, primaryText: "Pane")
                    pane.variants = RepoExplorerPaneRowVariants.make(
                        title: "Pane", branchContext: nil, note: nil, isDrawer: false,
                        branchStatus: nil, isActive: false, sessionStatus: status)
                    let presentation = RepoExplorerMaterializedRowPresentation.pane(pane)
                    return RepoExplorerMaterializedRow(
                        id: .tabPane(groupID: "panes", paneID: paneID),
                        contentRevision: RepoExplorerRowContentRevision(presentation: presentation),
                        layout: RepoExplorerRowLayout.make(for: presentation), representedRepoID: nil,
                        representedWorktreeID: nil)
                })
        }
        let materializer = RepoExplorerTableMaterializer(
            octiconLoader: makeRepoExplorerTestOcticonLoader(), onVisibleWorktreeSnapshotChange: { _ in })
        let window = makeMaterializerWindow(materializer, height: 90)
        defer {
            materializer.detach()
            window.close()
        }
        var previous = paneSnapshot(status: nil)
        materializer.apply(
            try tableCandidate(
                baseline: nativePlanRowlessBaseline(.noRepositories, revision: 0), snapshot: previous,
                requestGeneration: 1)
        ) { _ in }
        materializer.scroll(to: .tabPane(groupID: "panes", paneID: paneIDs[3]), offset: -7)
        let anchor = try #require(materializer.currentTopVisibleAnchor)
        #expect(anchor.offset < 0)
        for (offset, status) in [AgentSessionStatus?.some(.working(.active)), .idle(.ended), nil].enumerated() {
            let next = paneSnapshot(status: status)
            var disposition: RepoExplorerMaterializationChildDisposition?
            materializer.apply(
                try tableCandidate(
                    baseline: nativePlanBaseline(
                        snapshot: previous, revision: UInt64(offset + 1), visibleGeneration: UInt64(offset + 1)),
                    snapshot: next, requestGeneration: UInt64(offset + 2))
            ) { disposition = $0 }
            #expect(disposition == .accepted)
            #expect(materializer.currentTopVisibleAnchor?.identity == anchor.identity)
            #expect(materializer.currentTopVisibleAnchor?.offset == anchor.offset)
            previous = next
        }
        materializer.scroll(to: .tabPane(groupID: "panes", paneID: paneIDs[0]), offset: 0)
        let next = paneSnapshot(status: .needsYou(.approval))
        materializer.apply(
            try tableCandidate(
                baseline: nativePlanBaseline(snapshot: previous, revision: 4, visibleGeneration: 4),
                snapshot: next, requestGeneration: 5)
        ) { _ in }
        #expect(materializer.currentTopVisibleAnchor?.wasAtTop == true)
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

    private func makeMaterializerWindow(_ materializer: RepoExplorerTableMaterializer, height: CGFloat) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: height), styleMask: [.borderless], backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = materializer.view
        window.layoutIfNeeded()
        return window
    }
}
