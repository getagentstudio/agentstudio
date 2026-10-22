import AgentStudioInfrastructure
import AgentStudioSharedComponents
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

    static func context(belowRoot: Bool = false, branch: String = "detached HEAD") -> PaneManagementContext {
        PaneManagementContext(
            paneId: UUID(uuidString: paneText)!,
            identityRows: [
                .init(id: "repo", icon: .octicon("octicon-repo"), text: "project", toolTip: nil),
                .init(id: "branch", icon: .octicon("octicon-git-branch"), text: branch, toolTip: nil),
                .init(id: "worktree", icon: .system("folder"), text: "project", toolTip: "/tmp/project"),
                .init(
                    id: "cwd", icon: .system("folder"), text: belowRoot ? "Sources/App" : "project",
                    toolTip: belowRoot ? "/tmp/project/Sources/App" : "/tmp/project"),
                .init(id: "pane", icon: .system("terminal"), text: paneText, toolTip: paneText),
            ],
            statusChips: .init(
                branchStatus: .init(
                    isDirty: true, syncState: .noUpstream, prCount: nil, pullRequestDataUnavailable: true,
                    linesAdded: 0, linesDeleted: 0, untrackedFileCount: 1)),
            targetPath: URL(filePath: belowRoot ? "/tmp/project/Sources/App" : "/tmp/project"), showsIdentityBlock: true
        )
    }

    static func strip(_ name: String) -> ManagementPaneIdentityStrip {
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
        let base = context(belowRoot: name == "session-where", branch: branch)
        var rows = base.identityRows
        if name == "session-where" {
            rows = rows.map { row in
                row.id == "worktree"
                    ? .init(id: row.id, icon: row.icon, text: "pane-card-one-row", toolTip: row.toolTip) : row
            }
            rows.append(
                .init(
                    id: "session", icon: .system("terminal"), text: "codex · 01A1631E-ABCD-7443-8AC3-75EEE79D3333",
                    toolTip: nil))
        }
        let cardContext = PaneManagementContext(
            paneId: base.paneId, identityRows: rows,
            statusChips: name == "card-3-like" ? nil : base.statusChips,
            targetPath: base.targetPath, showsIdentityBlock: true)
        return ManagementPaneIdentityStrip(
            context: cardContext, octiconLoader: makeTestOcticonLoader(), lines: lines,
            recencyText: "2d", recencyTier: .grey, isActive: false)
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
        NSHostingView(
            rootView: Text(row.text)
                .font(
                    .system(
                        size: AppStyles.Shell.Sidebar.branchFontSize, weight: .medium,
                        design: row.id == "pane" ? .monospaced : .default)
                )
                .lineLimit(1).fixedSize()
        ).fittingSize.width
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
