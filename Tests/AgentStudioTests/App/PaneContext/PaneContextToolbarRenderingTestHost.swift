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
    func canonicalChangeCompleted(since checkpoint: Set<UUID>) async throws {
        let handle = try #require(handle)
        try await joinCanonicalForwarders()
        let current = try #require(await bindings.owner.latestExecution(for: handle.key), "Toolbar consumer retired")
        try #require(current.opening == handle.opening.epoch, "Toolbar opening was replaced")
        try await bridge.requireCanonicalInputCompleted(since: checkpoint)
        try await advance(by: .seconds(10), registeredAt: clock.now.advanced(by: .seconds(10)))
    }
    func joinCanonicalForwarders() async throws {
        let handle = try #require(handle)
        for forwarder in bindings.inputs.forwardingTasks(for: handle.key, opening: handle.opening.epoch) {
            await forwarder.value
        }
        try #require(bindings.inputs.forwardingTasks(for: handle.key, opening: handle.opening.epoch).isEmpty)
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
    func canonicalChangeCompleted(since checkpoint: Set<UUID>) async throws {
        let prepared = try #require(prepared)
        try await prepared.canonicalChangeCompleted(since: checkpoint)
        try prepared.rendered(host: host, window: window)
    }
    func stop() async throws {
        hide()
        try await prepared?.stop()
        window.contentView = nil
        window.close()
    }
}

@MainActor
func recordPaneLineDiagnosticFrame(_ view: NSView, name: String) throws {
    guard let directory = ProcessInfo.processInfo.environment["AGENTSTUDIO_PANE_LINE_FRAME_DIRECTORY"] else { return }
    let output = URL(filePath: directory, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    view.cacheDisplay(in: view.bounds, to: bitmap)
    let png = try #require(bitmap.representation(using: .png, properties: [:]))
    try png.write(to: output.appending(path: name + ".png"))
    let metadata: [String: Any] = [
        "width": view.bounds.width, "height": view.bounds.height,
        "backingScale": view.window?.backingScaleFactor ?? 0,
        "scope": "Diagnostic content-view export; not unlocked native acceptance",
    ]
    try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
        .write(to: output.appending(path: name + ".json"))
}
