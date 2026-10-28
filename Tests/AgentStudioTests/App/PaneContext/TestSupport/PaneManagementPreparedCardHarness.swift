import AgentStudioCore
import AgentStudioTestSupport
import AppKit
import Foundation
import SwiftUI
import Testing

@testable import AgentStudio

/// A themed management-card viewport over the actual prepared host and its owned producers.
@MainActor
final class PaneManagementPreparedCardHarness {
    let prepared: PaneContextPreparedNativeHost
    let host: NSHostingView<AnyView>
    let time: PaneContextTestTime
    var clock: TestPushClock { prepared.clock }
    var window: NSWindow { prepared.native.window }

    init(context: PaneManagementContext, owners: PaneContextTestSourceOwners, wallNow: Date, height: CGFloat)
        async throws
    {
        let bridge = PopoverOwnerFactBridge()
        let clock = TestPushClock(pendingSleepFactSink: bridge.observeClock)
        let time = PaneContextTestTime(clock: clock)
        time.shiftWallTime(by: wallNow.timeIntervalSince(time.now))
        self.time = time
        let prepared = PaneContextPreparedNativeHost(
            context: context, sourceOwners: owners, clock: clock,
            wallNow: { time.now }, bridge: bridge, viewportWidth: 1000, viewportHeight: height,
            decorateRoot: { content in
                AnyView(
                    content.frame(width: 1000, height: height, alignment: .topLeading)
                        .background(Color.black).environment(\.colorScheme, .dark))
            })
        do {
            host = try #require(prepared.native.window.contentView as? NSHostingView<AnyView>)
            self.prepared = prepared
            prepared.native.window.appearance = NSAppearance(named: .darkAqua)
        } catch {
            try? await prepared.close()
            throw error
        }
    }

    func open() async throws {
        try await prepared.open()
        try await prepared.renderedCard()
    }
    func advance(by duration: Duration, registeredAt deadline: TestPushClock.Instant) async throws {
        try await prepared.advance(by: duration, registeredAt: deadline)
        try await prepared.renderedCard()
    }
    func canonicalChangeCompleted(since checkpoint: Set<UUID>) async throws {
        let handle = try #require(prepared.cardHandle)
        let forwarding = prepared.bindings.inputs.forwardingTasks(for: handle.key, opening: handle.opening.epoch)
        for producer in forwarding { await producer.value }
        let current = try #require(
            await prepared.bindings.owner.latestExecution(for: handle.key), "Management card consumer retired")
        try #require(current.opening == handle.opening.epoch, "Management card opening was replaced")
        try await prepared.bridge.requireCanonicalInputCompleted(since: checkpoint)
        try await prepared.advance(by: .seconds(10), registeredAt: clock.now.advanced(by: .seconds(10)))
        try await prepared.renderedCard()
    }
    func hide() async throws {
        let handle = try #require(prepared.cardHandle)
        host.rootView = AnyView(Color.black.frame(width: 1000, height: host.bounds.height))
        host.needsLayout = true
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        if let closing = prepared.bindings.lifecycleProducer(for: handle.key) {
            try #require(await closing.value == nil, "Hiding the real root did not announce its actual close barrier")
        }
        #expect(await prepared.bindings.owner.latestExecution(for: handle.key) == nil)
        #expect(clock.pendingSleepCount == 0)
    }
    func close() async throws { try await prepared.close() }
}
