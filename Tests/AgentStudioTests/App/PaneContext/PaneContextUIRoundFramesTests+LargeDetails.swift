import AgentStudioInfrastructure
import AgentStudioSharedComponents
import AgentStudioTestSupport
import AppKit
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioSessions

extension PaneContextUIRoundFramesTests {
    private enum BodyProbe: String {
        case linesProportional, linesMonospaced, wrapProportional, wrapMonospaced, stress5000, stress20000
        case blankLinesProportional, blankLinesMonospaced

        var body: String {
            switch self {
            case .linesProportional: "L" + String(repeating: "\n", count: 4095)
            case .linesMonospaced: "```\nL" + String(repeating: "\n", count: 4088) + "```"
            case .blankLinesProportional: String(repeating: "\n", count: 4096)
            case .blankLinesMonospaced: "```\n" + String(repeating: "\n", count: 4089) + "```"
            case .wrapProportional: String(repeating: "W", count: 4096)
            case .wrapMonospaced: "```\n" + String(repeating: "W", count: 4088) + "\n```"
            case .stress5000, .stress20000:
                (1...(self == .stress5000 ? 5000 : 20_000)).map {
                    "Build record \($0): compiler diagnostic, preserved in full."
                }.joined(separator: "\n")
            }
        }
        var isStress: Bool { self == .stress5000 || self == .stress20000 }
    }

    @Test(
        "D85 opt-in native large-notice click-to-cache and scroll Performance Lane measurement",
        .enabled(if: ProcessInfo.processInfo.environment["AS_PANE_DETAIL_BODY_PROBE"] != nil))
    func measureLargeDetailReadSurface() async throws {
        let raw = try #require(ProcessInfo.processInfo.environment["AS_PANE_DETAIL_BODY_PROBE"])
        let probe = try #require(BodyProbe(rawValue: raw), "Unknown D85 body performance probe: \(raw)")
        try await withAsyncTestCoreAtoms { _ in try await measureLargeDetailReadSurface(probe: probe) }
    }

    private func measureLargeDetailReadSurface(probe: BodyProbe) async throws {
        let trace = PaneContextPopoverTraceFixture()
        let pane = PaneId.generateUUIDv7()
        let id = AgentMessageId.generateUUIDv7()
        let text = probe.body
        if !probe.isStress { #expect(text.utf8.count == AppPolicies.PaneContext.maximumBodyBytes) }
        // Stress input at the existing reader contract. Ordinary send admission caps bodies at4096bytes.
        let message = AgentMessageDetail(
            id: id, sourcePaneId: pane, sender: .pane(pane), sentAt: .distantPast, sourceOccurredAt: nil,
            importance: .failure, body: text, why: nil, actions: [], shape: .notice(.unread))
        let ports = PaneContextPopoverTestPorts(
            PaneContextPopoverShapingTests.detail(paneId: pane, messages: [message]))
        let adapter = PaneContextUIAdapter(reader: ports, person: ports)
        let owners = PaneContextTestSourceOwners(
            sessionStatus: SessionStatusAtom(), presentation: PaneContextPresentationAtom(), pane: { _ in nil },
            serviceProvider: { adapter }, performanceTraceRecorder: trace.recorder)
        let host = owners.makeNativeHost(
            paneId: pane,
            entry: .messagesAction(PaneContextPopoverControlProjection.controls().messages, target: .top),
            wallNow: .distantPast)
        do {
            try await host.open()
            try await host.bodyLayoutsPrepared()
            let beforeClick = try await trace.records().count
            let handle = try #require(host.handle)
            let key = PaneContextTextBodyKey.message(.init(sourcePaneId: pane.uuid, messageId: id.uuid))
            let trigger = try #require(
                host.native.find(
                    PaneContextPopoverControlProjection.controls().showDetails.identifier(in: key.textIdentifier))
                    as? any NSAccessibilityProtocol)
            let performance = PaneContextPopoverPerformance(recorder: trace.recorder)
            var clickAccepted = false
            var firstBitmap: NSBitmapImageRep?
            performance.mainActorHeld(.apply, key: handle.key) {
                clickAccepted = trigger.accessibilityPerformPress()
                host.native.layout()
                if let root = host.native.find("pane-context.details-panel.split") as? NSView {
                    firstBitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds)
                    if let firstBitmap { root.cacheDisplay(in: root.bounds, to: firstBitmap) }
                }
            }
            try #require(clickAccepted)
            let bitmap = try #require(firstBitmap, "The first native reading frame did not paint")
            let full = try #require(host.native.find("pane-context.details-text") as? NSView)
            let scroll = try #require(full.enclosingScrollView)
            let document = try #require(scroll.documentView)
            try #require(document.bounds.height > scroll.contentView.bounds.height)
            var scrollFrames: [NSBitmapImageRep] = []
            for fraction: CGFloat in [0.25, 0.5, 1] {
                performance.mainActorHeld(.complete, key: handle.key) {
                    scroll.contentView.scroll(
                        to: .init(
                            x: 0, y: fraction * (document.bounds.height - scroll.contentView.bounds.height)))
                    scroll.reflectScrolledClipView(scroll.contentView)
                    host.native.layout()
                    if let frame = scroll.bitmapImageRepForCachingDisplay(in: scroll.bounds) {
                        scroll.cacheDisplay(in: scroll.bounds, to: frame)
                        scrollFrames.append(frame)
                    }
                }
            }
            #expect(scroll.contentView.bounds.minY > 0)
            #expect(scrollFrames.count == 3)
            let records = try await trace.records()
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let measurements = records.dropFirst(beforeClick).filter {
                ($0["body"] as? String) == "performance.pane_context.popover.main_actor_held"
            }
            let report: [String: Any] = [
                "probe": probe.rawValue, "bodyBytes": text.utf8.count,
                "lineCount": text.split(separator: "\n", omittingEmptySubsequences: false).count,
                "input": probe.isStress
                    ? "synthetic typed reader beyond ordinary4096byte admission"
                    : "typed reader at actual4096byte admission bound; monospace uses explicit fences",
                "measurement":
                    "synchronous MainActor click through native cacheDisplay, then three direct native scroll/cache frames; compositor latency unmeasured",
                "mainActorHeld": measurements, "scrollOriginY": scroll.contentView.bounds.minY,
                "documentHeight": document.bounds.height, "viewportHeight": scroll.contentView.bounds.height,
            ]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: output.appending(path: "d85-\(probe.rawValue)-performance.json"))
            try paneContextOpaqueFramePNG(bitmap, background: AppStyles.Shell.TabBar.titlebarBackground)
                .write(to: output.appending(path: "d85-\(probe.rawValue)-first.png"))
            print("D85_LARGE_DETAIL", probe.rawValue, "mainActorHeld", measurements)
            try await host.close()
            try await ports.finish()
            try await trace.close()
        } catch {
            try? await host.close()
            try? await ports.finish()
            try? await trace.close()
            throw error
        }
    }
}
