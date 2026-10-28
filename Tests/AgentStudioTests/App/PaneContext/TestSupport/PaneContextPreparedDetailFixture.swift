import AgentStudioInfrastructure
import AgentStudioSharedComponents
import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioCore

/// Keeps the real bindings, owner and family; raw canonical values are explicit test inputs.
@MainActor
final class PaneContextPreparedDetailFixture {
    private final class Inputs {
        var adapter: PaneContextUIAdapter?
        var sources: [PaneId: PopoverSourceCapture.Source] = [:]
        init(adapter: PaneContextUIAdapter?) { self.adapter = adapter }
    }
    private let inputs: Inputs
    let bridge: PopoverOwnerFactBridge
    let clock: TestPushClock
    let bindings: PaneContextPopoverHostBindings
    var adapter: PaneContextUIAdapter? {
        get { inputs.adapter }
        set { inputs.adapter = newValue }
    }

    init(
        adapter: PaneContextUIAdapter?, wallNow: Date = Date(timeIntervalSince1970: 2),
        observeOwner: @escaping PaneContextPopoverOwnerObserver = { _, _ in }
    ) {
        let inputs = Inputs(adapter: adapter)
        let bridge = PopoverOwnerFactBridge()
        let clock = TestPushClock(pendingSleepFactSink: bridge.observeClock)
        let time = PaneContextTestTime(clock: clock)
        time.shiftWallTime(by: wallNow.timeIntervalSince(time.now))
        self.inputs = inputs
        self.bridge = bridge
        self.clock = clock
        bindings = PaneContextPopoverHostBindings(
            clock: clock, wallNow: { time.now },
            readSource: { id in
                inputs.sources[id]
                    ?? .init(
                        structuralFacts: nil, title: "Source", note: nil,
                        session: nil, display: nil, activity: nil)
            },
            serviceProvider: { inputs.adapter },
            observe: { scope, fact in
                bridge.observe(scope, fact)
                observeOwner(scope, fact)
            })
    }

    func setSource(_ source: PopoverSourceCapture.Source, for pane: PaneId) { inputs.sources[pane] = source }

    static func source(
        _ pane: PaneId, title: String? = nil, children: [PaneId] = [],
        parent: PaneId? = nil, display: PaneContextDisplay? = nil
    ) -> PopoverSourceCapture.Source {
        var value = Pane(
            id: pane.uuid,
            content: .terminal(TerminalState(provider: .zmx, lifetime: .persistent, zmxSessionID: .generateUUIDv7())),
            metadata: PaneMetadata(launchDirectory: URL(filePath: "/tmp/popover-detail-input"), title: title ?? ""),
            kind: .layout(
                drawer: .init(
                    drawerId: UUIDv7.generate(),
                    parentPaneId: pane.uuid, paneIds: children.map(\.uuid))))
        if let parent { value.kind = .drawerChild(parentPaneId: parent.uuid) }
        return .init(
            structuralFacts: .init(state: .init(pane: value)), title: title, note: nil,
            session: nil, display: display, activity: nil)
    }

    static func cardSource(
        _ pane: PaneId, selected: PaneContextMessageKey,
        children: [PaneId] = [], parent: PaneId? = nil, revision: UInt64 = 1
    ) -> PopoverSourceCapture.Source {
        let counts = PaneMessageCounts(
            kinds: .init(failure: 0, needsYou: 1, done: 0, info: 0),
            newestOpenBlockingAskId: nil, oldestOpenAsk: selected)
        let display = PaneContextDisplay(
            revision: .init(revision), agentTitle: nil, agentLine: nil,
            own: selected.paneId == pane ? counts : .zero, includingDrawers: counts, pullRequests: .notApplicable)
        return source(pane, children: children, parent: parent, display: display)
    }

    func open(
        _ pane: PaneId, location: PaneContextPopoverLocation = .pane,
        content: PaneContextPopoverDemand.Content = .messages(.top), includingDrawers: Bool = true,
        screenVisibleWidth: Double = 1400, hostId: UUID = UUIDv7.generate()
    ) async throws -> PaneContextPopoverConsumerHandle {
        let surface: PaneContextPopoverConsumerKey.Surface =
            content == .card ? .managementCard : (location == .sidebar ? .sidebarMessages : .paneMessages)
        let key = PaneContextPopoverConsumerKey(hostId: hostId, surface: surface, paneId: pane)
        let task = bindings.beginOpen(
            key,
            demand: .init(
                content: content, location: location,
                includingDrawers: includingDrawers, screenVisibleWidth: screenVisibleWidth))
        let handle = try #require(await task.value, "Actual bindings setup ended without its consumer")
        let finish = try await completed(handle.opening.initialExecution, for: handle)
        #expect(finish == .published || finish == .equal)
        return handle
    }

    @discardableResult
    func refresh(_ handle: PaneContextPopoverConsumerHandle) async throws -> PaneContextPopoverOwnerFact.Finish {
        let previous = await bindings.owner.latestExecution(for: handle.key)
        await bindings.owner.refreshImmediately(handle.key, opening: handle.opening.epoch)
        await previous?.task.value
        let current = try #require(await bindings.owner.latestExecution(for: handle.key))
        try #require(current.id != previous?.id, "Immediate refresh ended without a new producer")
        return try await completed(current, for: handle)
    }

    func completed(_ execution: PaneContextPopoverExecution, for handle: PaneContextPopoverConsumerHandle)
        async throws -> PaneContextPopoverOwnerFact.Finish
    {
        await execution.task.value
        try #require(
            bridge.didFinish(.execution(handle.key, execution.id)), "Actual producer ended without its terminal fact")
        let scope = PopoverOwnerProofScope(channel: .owner(.execution(handle.key, execution.id)))
        while true {
            let fact = try await bridge.facts.expectNext(
                in: scope, where: { _ in true }, "exact execution terminal outcome")
            if case .owner(.finished(let finish)) = fact { return finish }
        }
    }

    static func withOpen(
        pane: PaneId, ports: PaneContextPopoverTestPorts,
        location: PaneContextPopoverLocation = .pane, content: PaneContextPopoverDemand.Content = .messages(.top),
        includingDrawers: Bool = true, screenVisibleWidth: Double = 1400,
        sources: [PaneId: PopoverSourceCapture.Source] = [:],
        observeOwner: @escaping PaneContextPopoverOwnerObserver = { _, _ in },
        body: @MainActor (PaneContextPreparedDetailFixture, PaneContextPopoverConsumerHandle) async throws -> Void
    ) async throws {
        let fixture = PaneContextPreparedDetailFixture(
            adapter: .init(reader: ports, person: ports), observeOwner: observeOwner)
        for (pane, source) in sources { fixture.setSource(source, for: pane) }
        do {
            let handle = try await fixture.open(
                pane, location: location, content: content,
                includingDrawers: includingDrawers, screenVisibleWidth: screenVisibleWidth)
            try await body(fixture, handle)
            try await fixture.finish()
            try await ports.finish()
        } catch {
            try? await fixture.finish()
            try? await ports.finish()
            throw error
        }
    }

    func finish() async throws {
        await bindings.stop()
        #expect(clock.pendingSleepCount == 0)
        bridge.facts.receive(.ended)
        try await bridge.facts.finish()
    }
}
