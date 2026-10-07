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

@MainActor
@Suite(.serialized)
struct PaneContextPopoverHostNativeTests {
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
    func manualChipPressOpensOwnerDetailWithTitledDrawerAsk() async throws {
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
                    describeScope: { "drawer message open \($0)" }, describeFact: { String(describing: $0) },
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
                    onOpenCompleted: { value in
                        controller = value
                        completed.append(scope: 0, fact: .released)
                    }
                ))
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
            #expect(button.accessibilityPerformPress())
            try await completed.expectNext(in: 0, .released)
            #expect(await ports.requests == [.init(paneId: paneId, page: .first)])
            #expect(controller?.state?.messages.partitions.needsApproval.first?.sourceLabel == "Review drawer")
            #expect(controller?.state?.messages.partitions.needsApproval.first?.rows.first?.id == message.id.uuid)
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
