import AgentStudioInfrastructure
import AgentStudioSharedComponents
import AgentStudioTestSupport
import AppKit
import SwiftUI
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioRepoExplorer

@MainActor
enum PaneIdentityCardFixture {
    static let widths: [CGFloat] = [420, 520, 640, 780, 1000]
    nonisolated static let names = [
        "card-1-like", "card-2-like", "card-3-like", "secondary-lines", "long-title", "long-branch", "session-where",
    ]
    static let paneText = "01A1631E-62EE-7443-8AC3-75EEE79D1F58"
    static let message = RepoExplorerPaneContextLine(
        text: "Checking the pane layout before the next build", icon: .system(.terminal),
        tooltip: .init(text: "Message", shortcutDisplayText: nil), tone: .neutral, glyphMotion: .still,
        ageText: "2 min ago")
    static let warning = RepoExplorerPaneContextLine(
        text: "Agent connection needs attention", icon: .system(.terminal),
        tooltip: .init(text: "Connection", shortcutDisplayText: nil), tone: .warning, glyphMotion: .still, ageText: nil)

    static func context(
        belowRoot: Bool = false, branch: String = "detached HEAD", worktreeName: String? = nil,
        hasGitChanges: Bool = true
    ) throws -> PaneManagementContext {
        try withTestCoreAtoms { atoms in
            let store = WorkspaceStore(
                catalogAtom: atoms.workspaceRepositoryTopology, graphAtom: atoms.workspacePane,
                interactionAtom: atoms.workspaceTabLayout)
            let repo = store.addRepo(at: URL(filePath: "/tmp/project"))
            var worktree = try #require(repo.worktrees.first)
            if let worktreeName {
                worktree = Worktree(
                    id: UUIDv7.generate(), repoId: repo.id, name: worktreeName,
                    path: repo.repoPath.appending(path: worktreeName))
                store.reconcileDiscoveredWorktrees(repo.id, worktrees: repo.worktrees + [worktree])
            }
            let cwd = belowRoot ? worktree.path.appending(path: "Sources/App") : worktree.path
            let pane = Pane(
                id: UUID(uuidString: paneText)!,
                content: .terminal(
                    TerminalState(provider: .zmx, lifetime: .persistent, zmxSessionID: .generateUUIDv7())),
                metadata: PaneMetadata(
                    launchDirectory: worktree.path, title: "Agent | project",
                    facets: PaneContextFacets(repoId: repo.id, worktreeId: worktree.id, cwd: cwd)))
            try #require(store.paneAtom.insertRestoredPane(pane))
            let branchName = branch == "detached HEAD" ? "" : branch
            atoms.repoCache.setWorktreeEnrichment(
                WorktreeEnrichment(
                    worktreeId: worktree.id, repoId: repo.id, branch: branchName,
                    snapshot: GitWorkingTreeSnapshot(
                        worktreeId: worktree.id, repoId: repo.id, rootPath: worktree.path,
                        summary: GitWorkingTreeSummary(
                            changed: 0, staged: 0, untracked: hasGitChanges ? 1 : 0,
                            linesAdded: 0, linesDeleted: 0, aheadCount: 0, behindCount: 0, hasUpstream: true),
                        branch: branchName)))
            if let key = RepoBranchKey(repoId: repo.id, branch: branchName) {
                atoms.repoCache.applyPullRequestFacts([key: .init(openCount: 0, exactOpenURL: nil)])
            }
            return PaneManagementContext.project(paneId: pane.id, store: store)
        }
    }

    static func verifiedSession(reference: String = "01A1631E-ABCD-7443-8AC3-75EEE79D3333") throws -> SessionSummary {
        SessionSummary(
            id: UUIDv7.generate(), provider: try .init("codex"), sessionRef: try .init(reference),
            bindingGeneration: UUIDv7.generate(), status: .working(.active), providerPrompts: [])
    }

    static func strip(_ name: String) throws -> ManagementPaneIdentityStrip {
        let title = name == "long-title" ? String(repeating: "A long agent title ", count: 8) : "Agent | project"
        var lines: [RepoExplorerPaneRowLine] = [.title(title)]
        if name == "secondary-lines" {
            lines += [.agentLine(message), .connectionIssue(warning), .note("Keep this pane for the release")]
        }
        if name == "card-3-like" { lines += [.note("Release notes")] }
        if name == "secondary-lines", let status = RepoExplorerPaneContextLine.session(.working(.active)) {
            lines += [.sessionStatus(status)]
        }
        let branch =
            name == "long-branch"
            ? String(repeating: "feature/one-row-", count: 8) : (name == "card-3-like" ? "main" : "detached HEAD")
        let base = try context(
            belowRoot: name == "session-where", branch: branch,
            worktreeName: name == "session-where" ? "pane-card-one-row" : nil,
            hasGitChanges: name != "card-3-like")
        let cardContext = base.includingVerifiedLiveSession(name == "session-where" ? try verifiedSession() : nil)
        return ManagementPaneIdentityStrip(
            context: cardContext, octiconLoader: makeTestOcticonLoader(), lines: lines,
            activityText: "2 days ago")
    }

    static func mount(_ strip: ManagementPaneIdentityStrip, width: CGFloat) -> (
        host: NSHostingView<AnyView>, window: NSWindow
    ) {
        mountView(AnyView(strip), width: width)
    }

    static func mountView(_ view: AnyView, width: CGFloat) -> (host: NSHostingView<AnyView>, window: NSWindow) {
        let host = NSHostingView(
            rootView: AnyView(
                view.frame(width: width).background(Color.black).environment(\.colorScheme, .dark)
            ))
        host.frame = CGRect(x: 0, y: 0, width: width, height: host.fittingSize.height)
        let window = NSWindow(contentRect: host.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.setFrameOrigin(CGPoint(x: -10_000, y: -10_000))
        window.contentView = host
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        return (host, window)
    }

    static func frame(of identifier: String, in host: NSView) -> CGRect? {
        func findFrame(in view: NSView) -> CGRect? {
            if view.identifier?.rawValue == identifier { return view.convert(view.bounds, to: host) }
            for child in view.subviews {
                if let frame = findFrame(in: child) { return frame }
            }
            return nil
        }
        return findFrame(in: host)
    }

    static func frames(in host: NSView) -> [String: CGRect] {
        var result: [String: CGRect] = [:]
        func visit(_ view: NSView) {
            if view.identifier?.rawValue == "paneManagement.identityStrip" {
                result["container"] = view.convert(view.bounds, to: host)
            }
            if let identifier = view.identifier?.rawValue, identifier.hasPrefix("paneManagement.card.") {
                result[String(identifier.dropFirst("paneManagement.card.".count))] = view.convert(view.bounds, to: host)
            }
            view.subviews.forEach(visit)
        }
        visit(host)
        return result
    }

    static func expectContained(in host: NSView) throws {
        host.layoutSubtreeIfNeeded()
        let frames = frames(in: host)
        let container = try #require(frames["container"])
        let inner = container.insetBy(dx: 18, dy: 12)
        for (identifier, frame) in frames where identifier != "container" {
            #expect(frame.minX >= inner.minX, "\(identifier): \(frame) outside \(inner)")
            #expect(frame.maxX <= inner.maxX, "\(identifier): \(frame) outside \(inner)")
            #expect(frame.minY >= inner.minY, "\(identifier): \(frame) outside \(inner)")
            #expect(frame.maxY <= inner.maxY, "\(identifier): \(frame) outside \(inner)")
        }
    }

    static func naturalValueWidth(_ row: PaneManagementIdentityRow) -> CGFloat {
        let mounted = mountView(
            AnyView(
                Text(row.text)
                    .font(
                        .system(
                            size: AppStyles.Shell.Sidebar.branchFontSize, weight: .medium,
                            design: row.id == "pane" ? .monospaced : .default)
                    )
                    .lineLimit(1).fixedSize()
                    .background {
                        AccessibilityLabelBridge(identifier: "paneManagement.card.reference", label: "")
                    }), width: 2000)
        defer {
            mounted.window.contentView = nil
            mounted.window.close()
        }
        // Native bounds preserve fractional points; fittingSize rounds them to whole points.
        return frames(in: mounted.host)["reference"]!.width
    }

    static func elements(in host: NSView) -> [(label: String, frame: CGRect)] {
        var result: [(String, CGRect)] = []
        var visited = Set<ObjectIdentifier>()
        func visit(_ object: NSObject) {
            guard visited.insert(ObjectIdentifier(object)).inserted else { return }
            let labelSelector = NSSelectorFromString("accessibilityLabel")
            let frameSelector = NSSelectorFromString("accessibilityFrame")
            if object.responds(to: labelSelector), object.responds(to: frameSelector),
                let label = object.perform(labelSelector)?.takeUnretainedValue() as? String,
                let frame = object.value(forKey: "accessibilityFrame") as? NSValue,
                let window = host.window
            {
                result.append((label, host.convert(window.convertFromScreen(frame.rectValue), from: nil)))
            }
            let childrenSelector = NSSelectorFromString("accessibilityChildren")
            if object.responds(to: childrenSelector),
                let children = object.perform(childrenSelector)?.takeUnretainedValue() as? [NSObject]
            {
                children.forEach(visit)
            }
            if let view = object as? NSView { view.subviews.forEach(visit) }
        }
        visit(host)
        return result
    }
}
