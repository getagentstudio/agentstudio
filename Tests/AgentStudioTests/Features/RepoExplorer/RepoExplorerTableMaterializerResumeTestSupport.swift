import AgentStudioCore
import AgentStudioInfrastructure
import AppKit
import Testing

@testable import AgentStudioRepoExplorer

extension RepoExplorerTableMaterializerTests {
    func verifyResumeRebindsAfterZeroSizeLayout() async throws {
        let snapshot = nativePlanSnapshot(["A", "B", "C", "D", "E", "F"])
        let materializer = RepoExplorerTableMaterializer(
            octiconLoader: makeRepoExplorerTestOcticonLoader(),
            onVisibleWorktreeSnapshotChange: { _ in }
        )
        let window = makeMaterializerWindow(materializer, height: 80)
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
        let scrollView = materializer.scrollView
        let tableView = try #require(scrollView.documentView as? NSTableView)
        window.layoutIfNeeded()
        materializeVisibleCells(in: tableView, visibleRect: tableView.visibleRect)
        await materializer.drainViewportPublication()

        let initialRows = materializer.representedRowIndexes()
        #expect(!initialRows.isEmpty)
        let initialCells = try initialRows.map { rowIndex in
            try #require(
                tableView.view(atColumn: 0, row: rowIndex, makeIfNecessary: false)
                    as? RepoExplorerTableRowCell
            )
        }
        let initialBindingsByRow = try Dictionary(
            uniqueKeysWithValues: zip(initialRows, initialCells).map { rowIndex, cell in
                (rowIndex, try #require(cell.currentBindingIdentity))
            }
        )

        materializer.suspendDemand()
        #expect(initialCells.allSatisfy { $0.currentBindingIdentity == nil })

        let laidOutFrame = scrollView.frame
        scrollView.setFrameSize(.zero)
        scrollView.layoutSubtreeIfNeeded()
        tableView.layoutSubtreeIfNeeded()
        #expect(materializer.representedRowIndexes().isEmpty)

        materializer.resumeDemand(visibleGeneration: 1)
        await materializer.drainViewportPublication()
        #expect(initialCells.allSatisfy { $0.currentBindingIdentity == nil })

        scrollView.setFrameSize(laidOutFrame.size)
        window.layoutIfNeeded()
        scrollView.layoutSubtreeIfNeeded()
        tableView.layoutSubtreeIfNeeded()
        await materializer.drainViewportPublication()

        let reboundRows = materializer.representedRowIndexes()
        #expect(!reboundRows.isEmpty)
        let reboundBindingsByRow = try Dictionary(
            uniqueKeysWithValues: reboundRows.map { rowIndex in
                let cell = try #require(
                    tableView.view(atColumn: 0, row: rowIndex, makeIfNecessary: false)
                        as? RepoExplorerTableRowCell
                )
                return (rowIndex, try #require(cell.currentBindingIdentity))
            }
        )
        #expect(reboundBindingsByRow.mapValues(\.rowID) == initialBindingsByRow.mapValues(\.rowID))

        let firstReboundRow = try #require(reboundRows.first)
        let firstReboundCell = try #require(
            tableView.view(atColumn: 0, row: firstReboundRow, makeIfNecessary: false)
                as? RepoExplorerTableRowCell
        )
        firstReboundCell.clearBindingForReuse()

        scrollView.setFrameSize(
            NSSize(width: laidOutFrame.width + 12, height: laidOutFrame.height)
        )
        window.layoutIfNeeded()
        scrollView.layoutSubtreeIfNeeded()
        tableView.layoutSubtreeIfNeeded()
        await materializer.drainViewportPublication()
        #expect(firstReboundCell.currentBindingIdentity == nil)
    }

    func verifyResumeRebindsAtExistingSize() async throws {
        let snapshot = nativePlanSnapshot(["A", "B", "C", "D"])
        let materializer = RepoExplorerTableMaterializer(
            octiconLoader: makeRepoExplorerTestOcticonLoader(),
            onVisibleWorktreeSnapshotChange: { _ in }
        )
        let window = makeMaterializerWindow(materializer, height: 80)
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
        let tableView = try #require(materializer.scrollView.documentView as? NSTableView)
        window.layoutIfNeeded()
        materializeVisibleCells(in: tableView, visibleRect: tableView.visibleRect)
        await materializer.drainViewportPublication()

        let representedRows = materializer.representedRowIndexes()
        #expect(!representedRows.isEmpty)
        let representedCells = try representedRows.map { rowIndex in
            try #require(
                tableView.view(atColumn: 0, row: rowIndex, makeIfNecessary: false)
                    as? RepoExplorerTableRowCell
            )
        }
        let initialIdentities = try representedCells.map { cell in
            try #require(cell.currentBindingIdentity)
        }

        materializer.suspendDemand()
        #expect(representedCells.allSatisfy { $0.currentBindingIdentity == nil })
        materializer.resumeDemand(visibleGeneration: 1)
        await materializer.drainViewportPublication()

        let resumedIdentities = try representedCells.map { cell in
            try #require(cell.currentBindingIdentity)
        }
        #expect(resumedIdentities.map(\.rowID) == initialIdentities.map(\.rowID))
        #expect(resumedIdentities != initialIdentities)
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
