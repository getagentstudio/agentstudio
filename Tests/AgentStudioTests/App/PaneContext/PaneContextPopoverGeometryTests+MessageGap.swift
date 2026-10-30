import AgentStudioInfrastructure
import AgentStudioSessions
import AgentStudioSharedComponents
import AgentStudioTestSupport
import AppKit
import Foundation
import Observation
import SwiftUI
import Testing

@testable import AgentStudio
@testable import AgentStudioCore

extension PaneContextPopoverGeometryTests {
    @Test("One-line ask and notice ages follow the title at the shared spacing token", arguments: [false, true])
    func singleLineAgeUsesTitleSpacing(ask: Bool) async throws {
        let fixture = try await CompositionFactoryFixture.make()
        let service = fixture.composition.paneContextService
        let body = ask ? "Type a short reply to verify the pane card" : "A one-line information notice"
        let id = AgentMessageId.generateUUIDv7()
        var mounted: PaneContextPreparedNativeHost?
        do {
            let binding = try await fixture.bind(paneId: fixture.ownerId)
            try #require(
                await service.send(
                    .init(
                        paneId: fixture.ownerId, messageId: id, sender: try fixture.sender(binding),
                        sourceOccurredAt: nil, importance: ask ? .attention : .info, body: body, why: nil, actions: [],
                        shape: ask
                            ? .ask(reason: .question, form: .freeText(placeholder: "Your reply"), waiting: .nonBlocking)
                            : .notice
                    )) == .created(id))
            await fixture.composition.presentationLane.publishPending()
            let adapter = PaneContextUIAdapter(service: service)
            let owners = PaneContextTestSourceOwners(
                sessionStatus: .init(), presentation: fixture.presentationAtom,
                pane: { _ in nil }, serviceProvider: { adapter })
            let host = owners.makeNativeHost(
                paneId: fixture.ownerId,
                entry: .messagesAction(
                    PaneContextPopoverControlProjection.controls().messages, target: .top),
                wallNow: fixture.now, viewportWidth: 480)
            mounted = host
            try await host.open()
            try await host.bodyLayoutsPrepared()
            let handle = try #require(host.handle)
            for producer in host.bindings.inputs.forwardingTasks(for: handle.key, opening: handle.opening.epoch) {
                await producer.value
            }
            try await host.rendered()
            let value = try #require(host.value)
            let key = MessageRowModel.Key(sourcePaneId: fixture.ownerId.uuid, messageId: id.uuid)
            let measurement = try #require(value.bodyMeasurements[.message(key)])
            let row = try #require(value.shape?.messages.messageRows.first { $0.key == key })
            #expect(row.why == nil)
            #expect(measurement.visualLines == 1)
            let leaves = gapTextLeaves(host.native.roots)
            let title = try #require(leaves.first { $0.label == body })
            let age = try #require(leaves.first { $0.label == "Now" })
            let text = try #require(host.native.find("pane-context.message-text." + key.controlScope) as? NSView)
            let gap = title.frame.minY - age.frame.maxY
            let reference = try literalTitleAgeGeometry(body: body, width: text.bounds.width)
            let layoutGap = gap + (AppStyles.General.Spacing.tight - reference.gap)
            print(
                "GAP_GEOMETRY", "ask", ask, "preparedWidth", measurement.key.effectiveWidth,
                "visualLines", measurement.visualLines, "renderedColumnWidth", text.bounds.width,
                "titleHeight", title.frame.height, "ageHeight", age.frame.height,
                "nativeTitleToAge", gap, "literalNativeTitleToAge", reference.gap,
                "layoutTitleToAge", layoutGap, "token", AppStyles.General.Spacing.tight,
                "rowHeight", text.bounds.height, "literalRowHeight", reference.height)
            #expect(
                layoutGap == AppStyles.General.Spacing.tight,
                "Title and age must match a literal VStack using the spacing token; native AX focus outsets cancel")
            #expect(
                text.bounds.height == reference.height,
                "A prepared one-line row must not retain empty disclosure height")
            try await host.close()
            mounted = nil
            try await fixture.close()
        } catch {
            try? await mounted?.close()
            try? await fixture.close()
            throw error
        }
    }

    @Test("D84a count arrival keeps short text stable and grows capped long text once", arguments: [false, true])
    func countArrivalHasOnlyItsDeclaredGrowth(long: Bool) async throws {
        let pane = PaneId.generateUUIDv7()
        let lines = ["Build output"] + (1...18).map { "Compiling module \($0)" }
        let body = long ? lines.joined(separator: "\n") : "A short information notice"
        let message = AgentMessageDetail(
            id: .generateUUIDv7(), sourcePaneId: pane, sender: .pane(pane),
            sentAt: Date(timeIntervalSince1970: 100), sourceOccurredAt: nil,
            importance: .info, body: body, why: nil, actions: [], shape: .notice(.unread))
        let initial = try await PaneContextPopoverShapingTests.onlyRow(message).replacingAge(.init(text: "Now"))
        let model = PaneContextGapRowModel(row: initial)
        let controls = PaneContextPopoverControlProjection.controls()
        // The observable wrapper applies the actual worker's result to the same mounted row.
        let host = NSHostingView(rootView: PaneContextGapRowSubject(model: model, controls: controls))
        host.frame.size = host.fittingSize
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer {
            window.contentView = nil
            window.close()
        }
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        let firstHeight = try #require(model.heights.last)
        let reference = try literalTitleAgeGeometry(
            body: long ? lines.prefix(6).joined(separator: "\n") : body, width: 400, font: initial.bodyFont)
        #expect(
            firstHeight == reference.height, "First paint is capped at six lines and has no provisional button slot")
        let opening = model.heights.count
        let geometry = try #require(model.geometry)
        model.row = try await prepareGapRow(message, geometry: geometry)
        host.needsLayout = true
        host.frame.size = host.fittingSize
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        let changes = Array(model.heights.dropFirst(opening))
        let finalHeight = try #require(model.heights.last)
        if long {
            #expect(changes.count == 1, "Long text grows exactly once when its prepared disclosure appears")
            #expect(changes.allSatisfy { $0 > firstHeight }, "The capped long body never shrinks")
            #expect(finalHeight - firstHeight == AppStyles.General.Button.compact + AppStyles.General.Spacing.standard)
        } else {
            #expect(changes.isEmpty, "A known-short row never changes geometry when its count arrives")
            #expect(finalHeight == firstHeight)
        }
        print(
            "GAP_COUNT_TRANSITION", "long", long, "firstHeight", firstHeight,
            "finalHeight", finalHeight, "changes", changes)
    }

    @concurrent nonisolated private func prepareGapRow(
        _ message: AgentMessageDetail, geometry: PaneContextMessageBodyGeometry
    ) async throws -> MessageRowModel {
        let key = PaneContextPopoverConsumerKey(
            hostId: UUIDv7.generate(), surface: .paneMessages, paneId: message.sourcePaneId)
        let epoch = UUIDv7.generate()
        let snapshot = PaneContextPopoverSnapshot(
            identity: .init(
                key: key, openingEpoch: 1, serviceEpoch: epoch, requestGeneration: 1,
                inputGeneration: 0, ageGeneration: 0, pageGeneration: 0, producer: .input(UUIDv7.generate())),
            demand: .init(content: .messages(.top), location: .pane, includingDrawers: true, screenVisibleWidth: 480),
            capture: .init(observationGeneration: 1, serviceEpoch: epoch, sources: [:]),
            state: .ready(
                .detail(
                    PaneContextPopoverShapingTests.detail(paneId: message.sourcePaneId, messages: [message]),
                    selectedAsk: .none)),
            wallNow: message.sentAt, frozenWidth: 480,
            bodyGeometry: [
                .message(.init(sourcePaneId: message.sourcePaneId.uuid, messageId: message.id.uuid)): geometry
            ])
        guard case .messages(let model, _) = PaneContextPopoverDetailProjection.project(snapshot).content.body else {
            throw GapGeometryFailure.missingPreparedMessages
        }
        return try #require(model.messageRows.first)
    }

    private func literalTitleAgeGeometry(
        body: String, width: CGFloat, font: PaneContextMessageBodyFont = .proportional(pointSize: 12)
    ) throws -> (gap: CGFloat, height: CGFloat) {
        let content = VStack(alignment: .leading, spacing: AppStyles.General.Spacing.tight) {
            Text(body)
                .font(font.paintFont)
                .lineSpacing(font.lineSpacing)
                .lineLimit(6)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Now").font(.system(size: AppStyles.General.Typography.textSm))
        }
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: width, alignment: .leading)
        let host = NSHostingView(rootView: content)
        host.frame.size = host.fittingSize
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer {
            window.contentView = nil
            window.close()
        }
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        let leaves = gapTextLeaves([host])
        let title = try #require(leaves.first { $0.label == body })
        let age = try #require(leaves.first { $0.label == "Now" })
        return (title.frame.minY - age.frame.maxY, host.bounds.height)
    }

    private func gapTextLeaves(_ roots: [NSView]) -> [(label: String, frame: CGRect)] {
        var visited = Set<ObjectIdentifier>()
        var result: [(label: String, frame: CGRect)] = []
        func visit(_ element: AnyObject) {
            guard visited.insert(ObjectIdentifier(element)).inserted else { return }
            if let accessible = element as? any NSAccessibilityProtocol {
                let label = accessible.accessibilityLabel() ?? (accessible.accessibilityValue() as? String ?? "")
                if !label.isEmpty { result.append((label, accessible.accessibilityFrame())) }
                for child in accessible.accessibilityChildren() ?? [] { visit(child as AnyObject) }
            }
            for child in (element as? NSView)?.subviews ?? [] { visit(child) }
        }
        for root in roots { visit(root) }
        return result
    }
}

@MainActor @Observable
private final class PaneContextGapRowModel {
    var row: MessageRowModel
    @ObservationIgnored var geometry: PaneContextMessageBodyGeometry?
    @ObservationIgnored var heights: [CGFloat] = []
    init(row: MessageRowModel) { self.row = row }
}

private struct PaneContextGapRowSubject: View {
    let model: PaneContextGapRowModel
    let controls: PaneContextPopoverControls
    var body: some View {
        PaneContextMessageText(
            value: .init(row: model.row),
            octiconLoader: makeTestOcticonLoader(), onDetails: {},
            onBodyGeometry: { _, geometry in model.geometry = geometry }
        )
        .onGeometryChange(for: CGFloat.self) {
            $0.size.height
        } action: {
            model.heights.append($0)
        }
        .frame(width: 400)
    }
}

private enum GapGeometryFailure: Error { case missingPreparedMessages }
