import AgentStudioTestHarness
import AppKit
import SwiftUI
import Testing

@testable import AgentStudio

enum ToolbarHostFailure: Error {
    case unexpectedClockFact(String)
}

@MainActor
struct PaneContextToolbarTestHost {
    let host: NSHostingView<AnyView>
    let window: NSWindow
    var clock: NativeCardTestClock?
    var paneId: UUID?
    var hasLine = false

    func hide() {
        host.rootView = AnyView(EmptyView())
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
    }

    func stop() async throws {
        hide()
        if let clock, let paneId {
            let hidden = try await clock.nextHideResult()
            try #require(hidden == (hasLine ? .cancelled(requested: true) : .notRunning))
            if hasLine { try await clock.cancelledWorker(pane: paneId, input: nil) }
            #expect(clock.pendingSleepCount == 0)
            try await clock.finish()
        }
        window.contentView = nil
        window.close()
    }
}
