import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioSharedComponents
import SwiftUI
import Testing

@testable import AgentStudioRepoExplorer

@MainActor
@Suite("Repo Explorer drawer rail geometry", .serialized)
struct RepoExplorerDrawerRailRenderTests {
    @Test("owner, middle drawer, and last drawer join across their allocated row heights")
    func twoDrawersHaveContinuousRail() throws {
        let rows: [RepoExplorerProjectedPaneRow] = [
            makePaneRow(rail: .ownerWithDrawers, isDrawer: false, note: "Owner context"),
            makePaneRow(rail: .drawer(isLast: false), isDrawer: true),
            makePaneRow(rail: .drawer(isLast: true), isDrawer: true),
        ]
        let allocatedHeights = rows.map { row in
            let layout = RepoExplorerRowLayout.make(for: .pane(row))
            return max(layout.metrics.minimumHeight, layout.metrics.fallbackHeight)
        }
        let rowInset = AppStyles.Shell.Sidebar.nativeRowVerticalInset
        let railX = AppStyles.Shell.Sidebar.rowIdentityIconSize / 2
        let childIconLeadingX = RepoExplorerPaneRowContent.leadingContentInset(for: .drawer(isLast: false))
        let elbowEndX = childIconLeadingX - AppStyles.Shell.Sidebar.drawerRailIconGap
        let titleMidpoint = rowInset + AppStyles.Shell.Sidebar.nativePrimaryTextLineHeight / 2
        let ownerLineCount = try #require(rows[0].variants?.compact.lines.count)
        let ownerLastGlyphBottom =
            rowInset
            + CGFloat(ownerLineCount) * AppStyles.Shell.Sidebar.nativePrimaryTextLineHeight
            + CGFloat(ownerLineCount - 1) * AppStyles.Shell.Sidebar.rowContentSpacing
        let railPoints = rows.enumerated().map { index, row in
            points(
                in: DrawerRail.path(
                    segment: row.drawerRail,
                    ownerLineCount: row.variants?.compact.lines.count ?? 1,
                    rowVerticalInset: rowInset,
                    size: CGSize(
                        width: AppStyles.Shell.Sidebar.rowLeadingIconColumnWidth,
                        height: allocatedHeights[index]
                    )
                ))
        }
        let owner = railPoints[0]
        let middleDrawer = railPoints[1]
        let lastDrawer = railPoints[2]

        #expect(allocatedHeights[0] > allocatedHeights[1])
        #expect(ownerLastGlyphBottom < allocatedHeights[0])
        #expect(
            owner == [
                CGPoint(x: railX, y: ownerLastGlyphBottom),
                CGPoint(x: railX, y: allocatedHeights[0]),
            ])
        #expect(
            middleDrawer == [
                CGPoint(x: railX, y: 0),
                CGPoint(x: railX, y: allocatedHeights[1]),
                CGPoint(x: railX, y: titleMidpoint),
                CGPoint(x: elbowEndX, y: titleMidpoint),
            ])
        #expect(
            lastDrawer == [
                CGPoint(x: railX, y: 0),
                CGPoint(x: railX, y: titleMidpoint),
                CGPoint(x: railX, y: titleMidpoint),
                CGPoint(x: elbowEndX, y: titleMidpoint),
            ])
        #expect(middleDrawer[3].x == childIconLeadingX - AppStyles.Shell.Sidebar.drawerRailIconGap)
        #expect(lastDrawer[3].x == childIconLeadingX - AppStyles.Shell.Sidebar.drawerRailIconGap)
        #expect(owner[1].y == allocatedHeights[0] + middleDrawer[0].y)
        #expect(
            allocatedHeights[0] + middleDrawer[1].y
                == allocatedHeights[0] + allocatedHeights[1] + lastDrawer[0].y
        )
    }

    private func points(in path: Path) -> [CGPoint] {
        var points: [CGPoint] = []
        // Path exposes its elements through forEach; it is not a Sequence.
        // swift-format-ignore: ReplaceForEachWithForLoop
        path.forEach { element in
            switch element {
            case .move(to: let point), .line(to: let point):
                points.append(point)
            default:
                break
            }
        }
        return points
    }

    private func makePaneRow(
        rail: RepoExplorerDrawerRail,
        isDrawer: Bool,
        note: String? = nil
    ) -> RepoExplorerProjectedPaneRow {
        let title = isDrawer ? "Drawer" : "Owner"
        var row = RepoExplorerProjectedPaneRow(
            groupId: "drawer-rail",
            destination: navigationUnassociatedDestination(
                paneID: UUIDv7.generate(),
                tabID: UUIDv7.generate()
            ),
            rowId: "rail-\(UUIDv7.generate())",
            primaryText: title,
            secondaryLine: note.map(RepoExplorerPaneSecondaryLine.note),
            isDrawerPane: isDrawer
        )
        row.variants = RepoExplorerPaneRowVariants.make(
            title: title,
            agentLine: note.map {
                .init(
                    summary: $0, refs: [], writer: .pane(.init(existingUUID: row.destination.paneId)),
                    updatedAt: .distantPast)
            },
            sessionPresentation: note.map { _ in .init(status: .idle(.ready), evidence: .verifiedLive) },
            now: .distantPast)
        row.drawerRail = rail
        return row
    }
}
