import AgentStudioInfrastructure
import AgentStudioTestSupport
import AppKit
import Foundation
import SwiftUI
import Testing

@testable import AgentStudio

/// Holds only the actual toolbar producer, demanded consumer and native receipts.
@MainActor
final class PreparedToolbarTestLifetime {
    let bindings: PaneContextPopoverHostBindings
    let clock: TestPushClock
    let bridge: PopoverOwnerFactBridge
    var task: Task<Void, Never>?
    var handle: PaneContextPopoverConsumerHandle?
    var applications: [UUID: PaneContextPopoverApplication] = [:]

    init(owners: PaneContextTestSourceOwners) {
        let bridge = PopoverOwnerFactBridge()
        let clock = TestPushClock(pendingSleepFactSink: bridge.observeClock)
        let time = PaneContextTestTime(clock: clock)
        time.shiftWallTime(by: Date(timeIntervalSince1970: 1_800_000_125).timeIntervalSince(time.now))
        self.bridge = bridge
        self.clock = clock
        bindings = owners.bindings(clock: clock, wallNow: { time.now }, observe: bridge.observe)
    }
    func observe(_ event: PaneContextPopoverApplicationEvent) {
        if case .applied(let value) = event { applications[value.publication.id] = value }
    }
    func opened() async throws {
        let task = try #require(task, "Toolbar mount did not announce its actual rendering producer")
        await task.value
        let handle = try #require(handle, "Toolbar producer ended without its actual consumer")
        try await completed(handle.opening.initialExecution, handle: handle)
    }
    func rendered(host: NSView, window: NSWindow) throws {
        let handle = try #require(handle)
        let accepted = try #require(handle.atom.latestAcceptedValue)
        try #require(handle.atom.isCurrent(accepted.publication.request), "Toolbar value was superseded or retired")
        let value = try #require(handle.atom.value)
        host.needsLayout = true
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        try #require(
            applications[value.publication.id] != nil,
            "Exact toolbar native application missing after one owning-host update: \(value.publication.request)")
    }
    func advance(by duration: Duration, registeredAt deadline: TestPushClock.Instant) async throws {
        let handle = try #require(handle)
        let previous = try #require(await bindings.owner.latestExecution(for: handle.key))
        let wake = try #require(await bindings.owner.scheduledWakeProducer(), "Toolbar had no useful deadline")
        let scope = PopoverOwnerProofScope(channel: .owner(.deadline(wake.sequence)))
        try await bridge.facts.expectNext(in: scope, .owner(.deadlineArmed))
        try await bridge.facts.expectNext(in: scope, .clockRegistered(deadline))
        clock.advance(by: duration)
        await wake.task.value
        let next = try #require(await bindings.owner.latestExecution(for: handle.key))
        try #require(next.id != previous.id, "Toolbar deadline ended without its next execution")
        try await completed(next, handle: handle)
    }
    func canonicalChangeCompleted() async throws {
        let handle = try #require(handle)
        let forwarders = bindings.inputs.forwardingTasks(for: handle.key, opening: handle.opening.epoch)
        try #require(!forwarders.isEmpty, "Canonical toolbar change announced no real capture forwarding task")
        for forwarder in forwarders { await forwarder.value }
        try await advance(by: .seconds(10), registeredAt: clock.now.advanced(by: .seconds(10)))
    }
    private func completed(_ execution: PaneContextPopoverExecution, handle: PaneContextPopoverConsumerHandle)
        async throws
    {
        await execution.task.value
        try #require(
            bridge.didFinish(.execution(handle.key, execution.id)), "Toolbar execution ended without its terminal fact")
        let scope = PopoverOwnerProofScope(channel: .owner(.execution(handle.key, execution.id)))
        while true {
            let fact = try await bridge.facts.expectNext(
                in: scope, where: { _ in true },
                "toolbar publication, failure, supersession, cancellation or retirement")
            if case .owner(.finished(let finish)) = fact {
                try #require(finish == .published || finish == .equal, "Toolbar execution ended: \(finish)")
                return
            }
        }
    }
    func stop() async throws {
        task?.cancel()
        await task?.value
        await bindings.stop()
        #expect(clock.pendingSleepCount == 0)
        bridge.facts.receive(.ended)
        try await bridge.facts.finish()
    }
}

@MainActor
struct PaneContextToolbarTestHost {
    let host: NSHostingView<AnyView>
    let window: NSWindow
    var prepared: PreparedToolbarTestLifetime?
    var clock: TestPushClock? { prepared?.clock }

    func hide() {
        host.rootView = AnyView(EmptyView())
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
    }
    func advance(by duration: Duration, registeredAt deadline: TestPushClock.Instant) async throws {
        let prepared = try #require(prepared)
        try await prepared.advance(by: duration, registeredAt: deadline)
        try prepared.rendered(host: host, window: window)
    }
    func canonicalChangeCompleted() async throws {
        let prepared = try #require(prepared)
        try await prepared.canonicalChangeCompleted()
        try prepared.rendered(host: host, window: window)
    }
    func stop() async throws {
        hide()
        try await prepared?.stop()
        window.contentView = nil
        window.close()
    }
}
