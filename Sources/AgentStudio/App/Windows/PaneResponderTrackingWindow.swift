import AppKit

@MainActor
final class PaneResponderTrackingWindow: NSWindow {
    private(set) var responderChangeGeneration: UInt64 = 0

    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        responderChangeGeneration &+= 1
        return super.makeFirstResponder(responder)
    }
}
