import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioRepoExplorer
import AgentStudioSessions
import AgentStudioSharedComponents
import AgentStudioTestHarness
import AgentStudioTestSupport
import AppKit
import Foundation
import SwiftUI
import Testing

@testable import AgentStudio

private enum AutoOpenOwnerFact: Sendable, Equatable {
    case ownerPresent(Bool)
}

private struct AutoOpenOwnerProbe: View {
    @Environment(\.paneContextPopoverAutoOpenState) private var owner
    let scope: Int
    let facts: FactRecorder<Int, AutoOpenOwnerFact>

    var body: some View {
        Color.clear
            .frame(width: 10, height: 10)
            .onAppear { facts.append(scope: scope, fact: .ownerPresent(owner != nil)) }
    }
}

@MainActor
@Suite(.serialized)
struct PaneContextPopoverHostNativeTests {
    @Test("Hosts without an injected owner do not share auto-open state")
    func hostsWithoutInjectedOwnerDoNotShareAutoOpenState() async throws {
        let facts = FactRecorder<Int, AutoOpenOwnerFact>(
            vocabulary: .init(
                describeScope: { "auto-open owner \($0)" }, describeFact: { String(describing: $0) },
                isClosing: { _, _ in true }))
        let host = NSHostingView(
            rootView: HStack {
                AutoOpenOwnerProbe(scope: 0, facts: facts)
                AutoOpenOwnerProbe(scope: 1, facts: facts)
            })
        host.frame = CGRect(x: 0, y: 0, width: 40, height: 20)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer {
            window.contentView = nil
            window.close()
        }
        host.layoutSubtreeIfNeeded()
        try await facts.expectNext(in: 0, .ownerPresent(false))
        try await facts.expectNext(in: 1, .ownerPresent(false))
        try await facts.finish()
    }

    @Test
    func nativeChipPressResolvesTheCurrentProviderAndReadsOwnerDetail() async throws {
        try await withAsyncTestCoreAtoms { atoms in
            let store = WorkspaceStore(
                catalogAtom: atoms.workspaceRepositoryTopology, graphAtom: atoms.workspacePane,
                interactionAtom: atoms.workspaceTabLayout)
            let pane = store.createPane(title: "Owner terminal")
            let paneId = PaneId(existingUUID: pane.id)
            let ports = PaneContextPopoverTestPorts(PaneContextPopoverShapingTests.detail(paneId: paneId))
            var adapter: PaneContextUIAdapter?
            var providerReadCount = 0
            let readers = PaneContextUIReaders(
                sessionStatus: SessionStatusAtom(), presentation: atoms.paneContextPresentation,
                pane: { store.paneAtom.pane($0.uuid) },
                serviceProvider: {
                    providerReadCount += 1
                    return adapter
                })
            let completed = FactRecorder<Int, PopoverReleaseFact>(
                vocabulary: .init(
                    describeScope: { "host open \($0)" }, describeFact: { String(describing: $0) },
                    isClosing: { _, _ in true }))
            var openNumber = 0
            var controller: PaneContextPopoverController?
            let host = NSHostingView(
                rootView: PaneContextPopoverHost(
                    paneId: paneId,
                    presentation: .messages(
                        .init(
                            count: 1, tone: .warning, countIncludingInformational: 2,
                            toneIncludingInformational: .warning)),
                    location: .pane, readers: readers, octiconLoader: makeTestOcticonLoader(),
                    onGoToPane: { _ in },
                    onOpenCompleted: { value in
                        controller = value
                        completed.append(scope: openNumber, fact: .released)
                        openNumber += 1
                    }))
            host.frame = CGRect(x: 0, y: 0, width: 200, height: 60)
            let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.makeKeyAndOrderFront(nil)
            defer {
                controller?.close()
                window.contentView = nil
                window.close()
            }
            host.layoutSubtreeIfNeeded()
            var visited = Set<ObjectIdentifier>()
            let button = try #require(
                Self.find(host, identifier: "pane-context.messages", visited: &visited) as? AccessibilityPressBridgeView
            )
            #expect(button.accessibilityLabel() == LocalActionSpec.showPaneMessages.actionSpec.label)
            #expect(providerReadCount == 0)
            #expect(button.accessibilityPerformPress())
            try await completed.expectNext(in: 0, .released)
            #expect(controller == nil)
            #expect(providerReadCount == 1)
            adapter = .init(reader: ports, person: ports)
            #expect(button.accessibilityPerformPress())
            try await completed.expectNext(in: 1, .released)
            #expect(controller?.paneId == paneId)
            #expect(await ports.requests == [.init(paneId: paneId, page: .first)])
            controller?.close()
            try await completed.finish()
            try await ports.finish()
        }
    }
    @Test
    func aNewBlockingAskOpensOwnerDetailWithTitledDrawerMessages() async throws {
        try await withAsyncTestCoreAtoms { atoms in
            let store = WorkspaceStore(
                catalogAtom: atoms.workspaceRepositoryTopology, graphAtom: atoms.workspacePane,
                interactionAtom: atoms.workspaceTabLayout)
            let owner = store.createPane(title: "Owner")
            let drawer = store.createPane(title: "Review drawer")
            let paneId = PaneId(existingUUID: owner.id)
            let drawerId = PaneId(existingUUID: drawer.id)
            let message = try PaneContextPopoverShapingTests.message(
                paneId: drawerId,
                shape: .ask(.approval, .freeText(placeholder: nil), .blocking(deadline: .distantFuture), .open),
                importance: .info)
            let ports = PaneContextPopoverTestPorts(
                PaneContextPopoverShapingTests.detail(
                    paneId: paneId,
                    drawers: [.init(sourcePaneId: drawerId, messages: [message])]))
            let adapter = PaneContextUIAdapter(reader: ports, person: ports)
            let readers = PaneContextUIReaders(
                sessionStatus: SessionStatusAtom(), presentation: atoms.paneContextPresentation,
                pane: { store.paneAtom.pane($0.uuid) }, serviceProvider: { adapter })
            let completed = FactRecorder<Int, PopoverReleaseFact>(
                vocabulary: .init(
                    describeScope: { "auto open \($0)" }, describeFact: { String(describing: $0) },
                    isClosing: { _, _ in true }))
            var controller: PaneContextPopoverController?
            let host = NSHostingView(
                rootView: PaneContextPopoverHost(
                    paneId: paneId,
                    presentation: .messages(
                        .init(
                            count: 1, tone: .danger, countIncludingInformational: 1, toneIncludingInformational: .danger
                        )),
                    location: .pane, readers: readers, octiconLoader: makeTestOcticonLoader(), onGoToPane: { _ in },
                    autoOpenAskId: message.id,
                    onOpenCompleted: { value in
                        controller = value
                        completed.append(scope: 0, fact: .released)
                    }
                )
                .environment(\.paneContextPopoverAutoOpenState, PaneContextPopoverAutoOpenState()))
            host.frame = CGRect(x: 0, y: 0, width: 200, height: 60)
            let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.makeKeyAndOrderFront(nil)
            defer {
                controller?.close()
                window.contentView = nil
                window.close()
            }
            host.layoutSubtreeIfNeeded()
            try await completed.expectNext(in: 0, .released)
            #expect(await ports.requests == [.init(paneId: paneId, page: .first)])
            #expect(controller?.state?.messages.partitions.needsApproval.first?.sourceLabel == "Review drawer")
            #expect(controller?.state?.messages.partitions.needsApproval.first?.rows.first?.id == message.id.uuid)
            controller?.close()
            try await completed.finish()
            try await ports.finish()
        }
    }
    @Test
    func nativeSummaryPressOpensTheSharedPopoverThroughTheLazyReader() async throws {
        try await withAsyncTestCoreAtoms { atoms in
            let store = WorkspaceStore(
                catalogAtom: atoms.workspaceRepositoryTopology, graphAtom: atoms.workspacePane,
                interactionAtom: atoms.workspaceTabLayout)
            let pane = store.createPane(title: "PR pane")
            let paneId = PaneId(existingUUID: pane.id)
            let firstWorktree = UUIDv7.generate()
            let secondWorktree = UUIDv7.generate()
            let summary = PullRequestSummaryDetail.summary(
                .init(
                    state: .needsAttention(count: 1),
                    members: [
                        .pullRequest(
                            worktreeId: firstWorktree, number: 7, checks: .failed, review: .changesRequested),
                        .noPullRequest(worktreeId: secondWorktree),
                    ]))
            let chip = try #require(RepoExplorerPanePullRequestProjection.make(summary))
            let ports = PaneContextPopoverTestPorts(
                PaneContextPopoverShapingTests.detail(paneId: paneId, pullRequests: summary))
            let adapter = PaneContextUIAdapter(reader: ports, person: ports)
            let readers = PaneContextUIReaders(
                sessionStatus: SessionStatusAtom(), presentation: atoms.paneContextPresentation,
                pane: { store.paneAtom.pane($0.uuid) }, serviceProvider: { adapter })
            let completed = FactRecorder<Int, PopoverReleaseFact>(
                vocabulary: .init(
                    describeScope: { "summary open \($0)" }, describeFact: { String(describing: $0) },
                    isClosing: { _, _ in true }))
            var controller: PaneContextPopoverController?
            let host = NSHostingView(
                rootView: PaneContextPopoverHost(
                    paneId: paneId, presentation: .pullRequests(chip),
                    location: .sidebar, readers: readers, octiconLoader: makeTestOcticonLoader(), onGoToPane: { _ in },
                    onOpenCompleted: { value in
                        controller = value
                        completed.append(scope: 0, fact: .released)
                    }))
            host.frame = CGRect(x: 0, y: 0, width: 200, height: 60)
            let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.makeKeyAndOrderFront(nil)
            defer {
                controller?.close()
                window.contentView = nil
                window.close()
            }
            host.layoutSubtreeIfNeeded()
            var visited = Set<ObjectIdentifier>()
            let button = try #require(
                Self.find(host, identifier: chip.control.identifier, visited: &visited) as? AccessibilityPressBridgeView
            )
            #expect(button.accessibilityLabel() == LocalActionSpec.showPanePullRequestSummary.actionSpec.label)
            #expect(button.accessibilityPerformPress())
            try await completed.expectNext(in: 0, .released)
            #expect(await ports.requests == [.init(paneId: paneId, page: .first)])
            #expect(controller?.state?.pullRequestSummaryChip?.presentation.header == "Needs attention (1)")
            #expect(controller?.state?.pullRequestSummaryChip?.presentation.chipText == "2 ✗")
            #expect(readers.membershipProvider() == nil)
            var goToPanePresent = false
            var removalPresent = false
            let controls = PaneContextPopoverControlProjection.controls()
            for candidate in NSApp.windows {
                guard let content = candidate.contentView else { continue }
                content.layoutSubtreeIfNeeded()
                var visited = Set<ObjectIdentifier>()
                if Self.find(content, identifier: controls.goToPane.identifier, visited: &visited) != nil {
                    goToPanePresent = true
                }
                for worktree in [firstWorktree, secondWorktree] {
                    visited.removeAll()
                    if Self.find(
                        content, identifier: controls.removeLink.identifier(in: worktree.uuidString), visited: &visited)
                        != nil
                    {
                        removalPresent = true
                    }
                }
            }
            #expect(goToPanePresent, "The shared popover must be rendered before asserting an absent removal control")
            #expect(!removalPresent)

            controller?.close()
            try await completed.finish()
            try await ports.finish()
        }
    }
    private static func find(_ element: AnyObject, identifier: String, visited: inout Set<ObjectIdentifier>)
        -> AnyObject?
    {
        guard visited.insert(ObjectIdentifier(element)).inserted else { return nil }
        if let accessible = element as? any NSAccessibilityProtocol {
            if accessible.accessibilityIdentifier() == identifier { return element }
            for child in accessible.accessibilityChildren() ?? [] {
                if let found = find(child as AnyObject, identifier: identifier, visited: &visited) { return found }
            }
        }
        for child in (element as? NSView)?.subviews ?? [] {
            if let found = find(child, identifier: identifier, visited: &visited) { return found }
        }
        return nil
    }
}
