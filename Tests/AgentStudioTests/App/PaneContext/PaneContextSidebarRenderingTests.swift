import AgentStudioInfrastructure
import AgentStudioSessions
import AgentStudioSharedComponents
import AgentStudioTestHarness
import AgentStudioTestSupport
import AppKit
import SwiftUI
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioRepoExplorer

@MainActor
@Suite("G21 production sidebar row consumption", .serialized)
struct PaneContextSidebarRenderingTests {
    @Test(
        "actual associated and unassociated rows draw ordered facts and route every entry to real detail",
        arguments: [true, false])
    func rowConsumesVariantAndOpensRealDetail(associated: Bool) async throws {
        try await withAsyncTestCoreAtoms { atoms in
            let statuses = SessionStatusAtom()
            let opens = FactRecorder<Int, SidebarOpenFact>(
                vocabulary: .init(
                    describeScope: { "sidebar press \($0)" }, describeFact: { String(describing: $0) },
                    isClosing: { _, _ in true }))
            var press = 0
            var controllers: [PaneContextPopoverController] = []
            let fixture = try await RepoExplorerMessageDeadlineHostFixture.make(
                atoms: atoms, statuses: statuses, associated: associated,
                onOpen: { _, controller in
                    if let controller { controllers.append(controller) }
                    opens.append(
                        scope: press,
                        fact: .opened(
                            pane: controller?.paneId?.uuid,
                            bodies: Set(controller?.state?.messages.messageRows.map(\.body) ?? []),
                            line: controller?.state?.agentLine?.summary))
                    press += 1
                })
            do {
                let pane = fixture.composition.ownerId
                statuses.apply([pane: .set(.init(status: .working(.active), evidence: .verifiedLive))])
                try await sendFourNotices(fixture)
                let row = try await capturedRow(fixture)
                let mounted = mount(row, controls: fixture.paneContextControl, width: 260)
                defer { mounted.window.close() }
                let identity = ObjectIdentifier(mounted.cell.hostingView)
                try assertOrderedPaint(in: mounted.cell.hostingView, associated: associated)
                try assertChipPalette(row, in: mounted.cell.hostingView)
                for (index, identifier)
                    in (["failure", "needsYou", "done", "info"].map({ "pane-context.messages." + $0 })
                    + ["pane-context.agent-line"]).enumerated()
                {
                    let button = try #require(pressBridge(in: mounted.cell.hostingView, identifier: identifier))
                    #expect(button.accessibilityPerformPress())
                    try await opens.expectNext(
                        in: index,
                        .opened(
                            pane: pane.uuid, bodies: ["failure body", "attention body", "done body", "info body"],
                            line: "Quiet stored message"))
                    controllers.last?.close()
                }
                fixture.store.paneAtom.updatePaneTitle(fixture.paneID, title: "✳ Changed title")
                let changed = try await capturedRow(fixture)
                mounted.cell.bind(row: changed, visibleGeneration: 2)
                mounted.cell.hostingView.layoutSubtreeIfNeeded()
                let title = try #require(label(in: mounted.cell.hostingView, identifier: "paneContext.title"))
                #expect(title.accessibilityLabel() == "Changed title")
                #expect(ObjectIdentifier(mounted.cell.hostingView) == identity)
                try expectText(
                    "Changed title", font: .system(size: 13, weight: .semibold), in: mounted.cell.hostingView)
                try await assertAbsentLines(fixture, statuses: statuses, fullHeight: mounted.cell.bounds.height)
                for controller in controllers { controller.close() }
                try await fixture.closeProducers()
                try await fixture.finishFacts()
                try await opens.finish()
            } catch {
                for controller in controllers { controller.close() }
                try? await fixture.closeProducers()
                try? await fixture.finishFacts()
                try? await opens.finish()
                throw error
            }
        }
    }

    private func sendFourNotices(_ fixture: RepoExplorerMessageDeadlineHostFixture) async throws {
        let service = fixture.composition.composition.paneContextService
        for (importance, body) in [
            (MessageImportance.failure, "failure body"), (.attention, "attention body"),
            (.done, "done body"), (.info, "info body"),
        ] {
            let id = AgentMessageId.generateUUIDv7()
            try #require(
                await service.send(
                    .init(
                        paneId: fixture.composition.ownerId, messageId: id, sender: .pane(fixture.composition.ownerId),
                        sourceOccurredAt: nil, importance: importance, body: body, why: nil, actions: [],
                        shape: .notice)) == .created(id))
        }
        await fixture.composition.composition.presentationLane.publishPending()
    }

    private func capturedRow(_ fixture: RepoExplorerMessageDeadlineHostFixture) async throws
        -> RepoExplorerMaterializedRow
    {
        let capture = try #require(fixture.adapter.inputCapture)
        let request = capture.captureRequest(query: "", referenceDate: fixture.clock.wallNow, trigger: .dataRefresh)
        let result = try await fixture.adapter.deadlineWorker.project(request)
        return try #require(
            result.materializationSnapshot.rows.first { row in
                switch row.presentation {
                case .pane(let pane): pane.destination.paneId == fixture.paneID
                case .unassociatedPane(let pane): pane.destination.paneId == fixture.paneID
                default: false
                }
            })
    }

    private func mount(
        _ row: RepoExplorerMaterializedRow, controls: @escaping RepoExplorerPaneContextControlFactory,
        width: CGFloat
    ) -> (cell: RepoExplorerTableRowCell, window: NSWindow) {
        let cell = RepoExplorerTableRowCell(
            octiconLoader: makeTestOcticonLoader(),
            interactions: .init(
                onCommandRequest: { _ in }, onToggleGroup: { _ in }, onFocusPane: { _ in }, paneContextControl: controls
            ))
        cell.bind(row: row, visibleGeneration: 1)
        cell.frame = .init(x: 0, y: 0, width: width, height: row.layout.metrics.fallbackHeight)
        let window = NSWindow(contentRect: cell.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = .black
        window.contentView = cell
        window.orderFront(nil)
        window.layoutIfNeeded()
        cell.layoutSubtreeIfNeeded()
        cell.hostingView.layoutSubtreeIfNeeded()
        cell.hostingView.displayIfNeeded()
        return (cell, window)
    }

    private func assertOrderedPaint(in host: NSView, associated: Bool) throws {
        let title = try #require(label(in: host, identifier: "paneContext.title"))
        let status = try #require(label(in: host, identifier: "paneContext.status.text"))
        let line = try #require(label(in: host, identifier: "paneContext.agentLine.text"))
        let age = try #require(label(in: host, identifier: "paneContext.agentLine.age"))
        #expect(title.accessibilityLabel() == "Stored message pane")
        #expect(status.accessibilityLabel() == "Working")
        #expect(line.accessibilityLabel() == "Quiet stored message")
        #expect(age.accessibilityLabel() == "[2 min ago]")
        let frames = [title, status, line].map { host.convert($0.bounds, from: $0) }
        #expect(frames[0].maxY <= frames[1].minY && frames[1].maxY <= frames[2].minY)
        let ageRect = host.convert(age.bounds, from: age)
        #expect(abs(ageRect.minX - frames[2].maxX) < 0.5)
        #expect(frames[2].width <= 220 && ageRect.maxX <= host.bounds.maxX)
        let chips = try ["failure", "needsYou", "done", "info"].map { kind in
            try #require(pressBridge(in: host, identifier: "pane-context.messages." + kind))
        }.map { host.convert($0.bounds, from: $0) }
        #expect(zip(chips, chips.dropFirst()).allSatisfy { $0.0.maxX <= $0.1.minX })
        #expect(chips.allSatisfy { $0.minY >= frames[2].maxY && $0.width > 0 && $0.maxX <= host.bounds.maxX })
        try expectText(
            "Working", font: .system(size: 12),
            colour: Color(.sRGB, red: 0x40 / 255.0, green: 0x9C / 255.0, blue: 1), in: host)
        try expectText("[2 min ago]", font: .system(size: 12), in: host)
        try assertWorkingColor(in: host, rect: frames[1], associated: associated)
    }

    private func assertChipPalette(_ row: RepoExplorerMaterializedRow, in host: NSView) throws {
        let render = PaneContextToolbarRenderingTests()
        let reference = mount(
            row,
            controls: { _, control in
                guard case .kind(let chip) = control else { return nil }
                return AnyView(
                    render.frozenKindChip(String(describing: chip.kind), background: .clear).background {
                        AccessibilityPressBridge(identifier: "reference.\(chip.kind)", label: "reference", action: {})
                    })
            }, width: host.bounds.width)
        defer { reference.window.close() }
        let referenceHost = reference.cell.hostingView
        for kind in ["failure", "needsYou", "done", "info"] {
            let actual = try #require(pressBridge(in: host, identifier: "pane-context.messages." + kind))
            let frozen = try #require(pressBridge(in: referenceHost, identifier: "reference." + kind))
            let actualRect = host.convert(actual.bounds, from: actual)
            let frozenRect = referenceHost.convert(frozen.bounds, from: frozen)
            #expect(actualRect == frozenRect)
            let actualPixels = try render.pixels(in: host, rect: actualRect)
            let referencePixels = try render.pixels(in: referenceHost, rect: frozenRect)
            #expect(
                actualPixels == referencePixels,
                "Sidebar \(kind) must paint the literal glyph and shared semantic colour; first pixels \(actualPixels.prefix(16))/\(referencePixels.prefix(16))"
            )
        }
    }

    private func assertAbsentLines(
        _ fixture: RepoExplorerMessageDeadlineHostFixture,
        statuses: SessionStatusAtom, fullHeight: CGFloat
    ) async throws {
        statuses.apply([fixture.composition.ownerId: .remove])
        let service = fixture.composition.composition.paneContextService
        guard
            case .claimed(let epoch) = await service.claimEpoch(
                .init(
                    paneId: fixture.composition.ownerId, writer: .pane(fixture.composition.ownerId), stream: .line,
                    claimId: UUIDv7.generate()))
        else { throw SidebarRenderingFailure.lineEpochUnavailable }
        try #require(
            await service.setLine(
                .init(
                    paneId: fixture.composition.ownerId, writer: .pane(fixture.composition.ownerId), line: nil,
                    writeNumber: .init(epoch: epoch, counter: 1))) == .applied)
        _ = await service.dismissAllNotices(paneId: fixture.composition.ownerId, includingDrawers: true)
        await fixture.composition.composition.presentationLane.publishPending()
        let absent = try await capturedRow(fixture)
        let mounted = mount(absent, controls: fixture.paneContextControl, width: 260)
        defer { mounted.window.close() }
        #expect(mounted.cell.bounds.height < fullHeight)
        #expect(label(in: mounted.cell.hostingView, identifier: "paneContext.status.text") == nil)
        #expect(label(in: mounted.cell.hostingView, identifier: "paneContext.agentLine.age") == nil)
        #expect(pressBridge(in: mounted.cell.hostingView, identifier: "pane-context.messages.info") == nil)
    }

    private func expectText(_ text: String, font: Font, colour: Color = .secondary, in host: NSView) throws {
        let render = PaneContextToolbarRenderingTests()
        let reference = render.mountCard(
            AnyView(Text(text).font(font).foregroundStyle(colour).fixedSize()), width: nil)
        defer { reference.window.close() }
        #expect(
            render.containsTextInk(
                try render.ink(in: reference.host, minimumBrightness: 60),
                in: try render.ink(in: host, minimumBrightness: 60)), "The literal \(text) must paint")
    }

    private func label(in view: NSView, identifier: String) -> AccessibilityLabelBridgeView? {
        if let value = view as? AccessibilityLabelBridgeView, value.accessibilityIdentifier() == identifier {
            return value
        }
        return view.subviews.lazy.compactMap { label(in: $0, identifier: identifier) }.first
    }

    private func pressBridge(in view: NSView, identifier: String) -> AccessibilityPressBridgeView? {
        if let value = view as? AccessibilityPressBridgeView, value.accessibilityIdentifier() == identifier {
            return value
        }
        return view.subviews.lazy.compactMap { pressBridge(in: $0, identifier: identifier) }.first
    }
}

private enum SidebarOpenFact: Equatable, Sendable {
    case opened(pane: UUID?, bodies: Set<String>, line: String?)
}
private enum SidebarRenderingFailure: Error { case lineEpochUnavailable }
