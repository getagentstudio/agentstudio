import AgentStudioInfrastructure
import AgentStudioRepoExplorer
import AgentStudioSharedComponents
import AgentStudioTestSupport
import AppKit
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioCore

extension PaneContextAgentLinePopoverNativeTests {
    @Test("The shared shell keeps Agent Line's opening height while a longer line scrolls")
    func changedAgentLineKeepsOpeningHeight() async throws {
        let fixture = try await CompositionFactoryFixture.make()
        var mounted: PaneContextPreparedNativeHost?
        do {
            let service = fixture.composition.paneContextService
            let writer = try fixture.sender(await fixture.bind(paneId: fixture.ownerId))
            guard
                case .claimed(let epoch) = await service.claimEpoch(
                    .init(
                        paneId: fixture.ownerId, writer: writer, stream: .line, claimId: UUIDv7.generate()))
            else { throw AgentLineShellHeightFailure.missingLine }
            let short = "Checking the preview"
            try #require(
                await service.setLine(
                    .init(
                        paneId: fixture.ownerId, writer: writer, line: .init(summary: short, refs: []),
                        writeNumber: .init(epoch: epoch, counter: 1))) == .applied)
            guard case .detail(let initial) = await service.readDetail(.init(paneId: fixture.ownerId, page: .first))
            else { throw AgentLineShellHeightFailure.missingLine }
            let line = try #require(initial.agentLine)
            await fixture.composition.presentationLane.publishPending()
            let owners = PaneContextTestSourceOwners(
                sessionStatus: .init(), presentation: fixture.presentationAtom,
                pane: { _ in nil }, serviceProvider: { PaneContextUIAdapter(service: service) })
            let now = fixture.now.addingTimeInterval(120)
            let bridge = PopoverOwnerFactBridge()
            let clock = TestPushClock(pendingSleepFactSink: bridge.observeClock)
            let host = PaneContextPreparedNativeHost(
                paneId: fixture.ownerId, sourceOwners: owners, entry: .agentLine(.agent(line, now: now)),
                clock: clock, wallNow: { now }, bridge: bridge, location: .sidebar)
            mounted = host
            try await host.open()
            try host.appliedAgentLine(summary: short, age: "2 min ago")
            host.native.layout()
            let opened = try #require(host.native.find("pane-context.popover-panel") as? NSView)
            let openingHeight = opened.bounds.height
            try #require(openingHeight > 0)
            #expect(openingHeight < 280, "Agent Line stays content-sized without the Messages minimum")
            #expect(opened.bounds.width == 380)
            try captureAgentLineShell(opened, name: "shell-agentLine-open-380")
            let long = Array(
                repeating: "Reviewing every verification result and preserving the complete source evidence.", count: 2
            )
            .joined(separator: " ")
            try #require(
                await service.setLine(
                    .init(
                        paneId: fixture.ownerId, writer: writer, line: .init(summary: long, refs: []),
                        writeNumber: .init(epoch: epoch, counter: 2))) == .applied)
            await fixture.composition.presentationLane.publishPending()
            try await host.refresh()
            try host.appliedAgentLine(summary: long, age: "2 min ago")
            host.native.layout()
            let changed = try #require(host.native.find("pane-context.popover-panel") as? NSView)
            #expect(changed.bounds.height == openingHeight)
            let text = try #require(host.native.find(AgentLinePopover.datedLabelIdentifier) as? NSView)
            let scroll = text.enclosingScrollView
            #expect(scroll != nil, "Growing Agent Line text must belong to the shared scroll content")
            #expect((scroll?.documentView?.bounds.height ?? 0) > (scroll?.contentView.bounds.height ?? 0))
            try captureAgentLineShell(changed, name: "shell-agentLine-changed-380")
            try await host.close()
            mounted = nil
            try await fixture.close()
        } catch {
            try? await mounted?.close()
            try? await fixture.close()
            throw error
        }
    }

    private func captureAgentLineShell(_ view: NSView, name: String) throws {
        guard ProcessInfo.processInfo.environment["AGENTSTUDIO_UI_ROUND_REVIEW"] == "1" else { return }
        let frames = PaneContextUIRoundFramesTests()
        try FileManager.default.createDirectory(at: frames.output, withIntermediateDirectories: true)
        if let window = view.window { try frames.setReviewAppearance(window) }
        try frames.applyLocalView(view)
        try frames.save(view, name: name, opaqueBackground: .windowBackgroundColor)
        print("SHELL_AGENT_LINE_FRAME", name, "width", view.bounds.width, "height", view.bounds.height)
    }
}

private enum AgentLineShellHeightFailure: Error { case missingLine }
