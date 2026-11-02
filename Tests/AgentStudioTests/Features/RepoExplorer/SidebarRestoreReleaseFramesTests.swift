import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioSharedComponents
import AppKit
import SwiftUI
import Testing

@testable import AgentStudioRepoExplorer

@MainActor
@Suite("Sidebar restore release frames", .serialized)
struct SidebarRestoreReleaseFramesTests {
    @Test(
        .enabled(if: ProcessInfo.processInfo.environment["AGENTSTUDIO_SIDEBAR_RESTORE_FRAMES"] != nil),
        arguments: ["active", "idle", "git", "drawer", "note", "rich"])
    func exportIdenticalFixture(state: String) throws {
        let directory = try #require(ProcessInfo.processInfo.environment["AGENTSTUDIO_SIDEBAR_RESTORE_FRAMES"])
        let output = URL(filePath: directory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let screen = try #require(NSScreen.screens.first { $0.backingScaleFactor == 2 })
        for expanded in [false, true] {
            let pane = UUIDv7.generate()
            let repo = UUIDv7.generate()
            let loader = makeRepoExplorerTestOcticonLoader()
            let status = GitBranchStatus(
                isDirty: true, syncState: .diverged(ahead: 5, behind: 3), prCount: 2,
                linesAdded: 19, linesDeleted: 7, untrackedFileCount: 1)
            let hasGit = state == "git" || state == "rich"
            let branch = hasGit ? "agent-studio · feature/restore" : nil
            let note = state == "note" || state == "rich" ? "Review the result" : nil
            let active = state == "active" || state == "rich"
            let drawer = state == "drawer" || state == "rich"
            let line: AgentLineDetail? =
                state == "rich"
                ? .init(
                    summary: "Running verification", refs: [], writer: .pane(.init(existingUUID: pane)),
                    updatedAt: Date(timeIntervalSince1970: 1000)) : nil
            var row = RepoExplorerProjectedPaneRow(
                groupId: "fixture", repoId: repo,
                destination: .init(
                    paneId: pane, repoId: repo, worktreeId: UUIDv7.generate(), worktreeLabel: "fixture",
                    tabId: UUIDv7.generate(), tabIndex: 0, paneIndexInTab: 0, isActiveInTab: active),
                rowId: "fixture-row", primaryText: "Verification pane",
                secondaryLine: note.map(RepoExplorerPaneSecondaryLine.note),
                branchContextText: branch, branchStatus: hasGit ? status : nil,
                recencyText: "Now", recencyTier: .strongBlue, isActive: active, isDrawerPane: drawer)
            row.variants = RepoExplorerPaneRowVariants.make(
                title: row.primaryText, branchContext: branch, note: note, isDrawer: drawer,
                branchStatus: hasGit ? status : nil, isActive: active, recencyText: "Now", recencyTier: .strongBlue,
                agentLine: line,
                sessionPresentation: state == "rich" ? .init(status: .working(.active), evidence: .verifiedLive) : nil,
                counts: .init(failure: 0, needsYou: state == "rich" ? 1 : 0, done: 0, info: 0),
                activityDate: Date(timeIntervalSince1970: 1120), now: Date(timeIntervalSince1970: 1120))
            row.displayVariant = expanded ? .expanded : .compact
            let controls: RepoExplorerPaneContextControlFactory = { _, presentation in
                if case .kind(let chip) = presentation {
                    return AnyView(
                        PaneMessageKindChip(
                            model: chip, control: PaneMessageKindChipProjection.control(chip),
                            octiconLoader: loader, onOpen: {}))
                }
                return nil
            }
            let view = RepoExplorerPaneRow(
                row: row, octiconLoader: loader,
                keyboardPresentation: .init(isSelected: expanded, shortcutDisplay: nil),
                paneContextControl: controls, onFocus: {}
            )
            .frame(width: 450).padding(8).background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, .dark)
            let host = NSHostingView(rootView: view)
            host.appearance = NSAppearance(named: .darkAqua)
            let window = NSWindow(
                contentRect: .init(x: screen.frame.minX + 30, y: screen.frame.minY + 30, width: 466, height: 300),
                styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.orderFront(nil)
            host.frame = .init(x: 0, y: 0, width: 466, height: 300)
            host.layoutSubtreeIfNeeded()
            host.frame.size = host.fittingSize
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.effectiveAppearance.performAsCurrentDrawingAppearance {
                host.cacheDisplay(in: host.bounds, to: bitmap)
            }
            try #require(bitmap.pixelsWide == Int(host.bounds.width * 2))
            try #require(bitmap.pixelsHigh == Int(host.bounds.height * 2))
            let name = state + (expanded ? "-expanded" : "-compact")
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: output.appending(path: name + ".png"))
            print("SIDEBAR_RESTORE_FRAME", name, host.bounds, bitmap.pixelsWide, bitmap.pixelsHigh)
            window.contentView = nil
            window.close()
        }
    }
}
