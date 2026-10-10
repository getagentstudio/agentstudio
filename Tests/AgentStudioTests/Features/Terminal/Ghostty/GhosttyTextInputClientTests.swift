import AgentStudioCore
import AgentStudioInfrastructure
import AppKit
import Testing

@testable import AgentStudioTerminal

@MainActor
@Suite("Ghostty text input client", .serialized)
struct GhosttyTextInputClientTests {
    @Test("empty selection and marked ranges use AppKit's zero range")
    func emptyRangesUseZeroRange() {
        let surface = makeBareSurface()

        #expect(surface.selectedRange() == NSRange())
        #expect(surface.markedRange() == NSRange())
    }

    @Test("marked range spans the current marked text")
    func markedRangeSpansMarkedText() {
        let surface = makeBareSurface()
        surface.setMarkedText("かな", selectedRange: NSRange(), replacementRange: NSRange())

        #expect(surface.markedRange() == NSRange(location: 0, length: 2))
    }

    @Test("missing native surface returns its zero-sized frame-origin rect")
    func missingSurfaceFirstRectUsesFrameOrigin() {
        let surface = makeBareSurface()
        surface.frame = NSRect(x: 12, y: 34, width: 56, height: 78)

        #expect(
            surface.firstRect(forCharacterRange: NSRange(), actualRange: nil)
                == NSRect(x: 12, y: 34, width: 0, height: 0)
        )
    }

    @Test("selection offsets map to an AppKit range")
    func selectionOffsetsMapToAppKitRange() {
        #expect(ghosttyTextInputSelectionRange(offsetStart: 12, offsetLength: 4) == NSRange(location: 12, length: 4))
    }

    @Test("marked range uses an empty zero range and covers all marked text")
    func markedRangeUsesAppKitLengthSemantics() {
        #expect(ghosttyTextInputMarkedRange(length: 0) == NSRange())
        #expect(ghosttyTextInputMarkedRange(length: 3) == NSRange(location: 0, length: 3))
    }

    @Test("dictation rect collapses width, advances by cell width, and clamps height")
    func dictationRectUsesInjectedPointAndCellSize() {
        let rect = ghosttyTextInputViewRect(
            pointAndSize: GhosttyIMEPointAndSize(x: 20, y: 30, width: 8, height: 4),
            characterRange: NSRange(location: 3, length: 0),
            cellSize: NSSize(width: 10, height: 18),
            viewHeight: 120
        )

        #expect(rect == NSRect(x: 50, y: 90, width: 0, height: 18))
    }

    @Test("marked text rect keeps its width and converts from top-left coordinates")
    func markedTextRectConvertsInjectedPoint() {
        let rect = ghosttyTextInputViewRect(
            pointAndSize: GhosttyIMEPointAndSize(x: 20, y: 30, width: 8, height: 20),
            characterRange: NSRange(location: 1, length: 2),
            cellSize: NSSize(width: 10, height: 18),
            viewHeight: 120
        )

        #expect(rect == NSRect(x: 20, y: 90, width: 8, height: 20))
    }

    private func makeBareSurface() -> Ghostty.SurfaceView {
        Ghostty.SurfaceView(
            managedSurfaceID: UUIDv7.generate(),
            appCommandDispatcher: TextInputNoOpAppCommandDispatcher()
        )
    }
}

@MainActor
private final class TextInputNoOpAppCommandDispatcher: AppCommandDispatching {
    func dispatchKeyboardShortcut(_: AppShortcut) {}
    func dispatchExtractPaneToTab(tabId _: UUID, paneId _: UUID, targetTabInsertionIndex _: Int?) {}

    func dispatch(_: AppCommand) -> Bool { false }
    func dispatch(_: AppCommand, target _: UUID, targetType _: SearchItemType) {}
    func canDispatch(_: AppCommand) -> Bool { false }
    func canDispatch(_: AppCommand, target _: UUID, targetType _: SearchItemType) -> Bool { false }
    func bridgePaneCommandTarget(worktreeId _: UUID) -> BridgePaneCommandTarget? { nil }
    func dispatchMovePaneToTab(sourcePaneId _: UUID, sourceTabId _: UUID?, targetTabId _: UUID) {}
}
