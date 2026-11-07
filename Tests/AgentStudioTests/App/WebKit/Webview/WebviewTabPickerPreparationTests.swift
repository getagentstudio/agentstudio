import AgentStudioInfrastructure
import AgentStudioTestHarness
import AgentStudioTestSupport
import AppKit
import Foundation
import SwiftUI
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioWebview

/// How one held preparation ended, reported in the main-actor turn it ended in.
private enum PickerPreparationOutcome: Equatable, Sendable {
    case returned(query: String)
    case cancelled(query: String)
}

/// Picker preparations a test can hold, one held step per query; other queries
/// prepare at once. Each preparation runs on the main actor, so when it returns
/// the view applies or drops its result in that same turn, before the test
/// reads the outcome.
@MainActor
private final class HeldPickerPreparations {
    let outcomes: AsyncStream<PickerPreparationOutcome>
    private let continuation: AsyncStream<PickerPreparationOutcome>.Continuation
    private let steps: [String: HeldStep<String>]

    init(steps: [String: HeldStep<String>]) {
        (outcomes, continuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        self.steps = steps
    }

    func prepare(_ request: WebviewTabPickerRequest) async -> WebviewTabPickerContents {
        if let step = steps[request.query] {
            do {
                try await step.arrive(request.query)
            } catch {
                continuation.yield(.cancelled(query: request.query))
                return WebviewTabPickerContents(request: request)
            }
        }
        continuation.yield(.returned(query: request.query))
        return WebviewTabPickerContents(request: request)
    }

    /// Ends every outcome wait once the test is done with the view.
    func finish() { continuation.finish() }
}

/// Mounts the real picker in a key window, shown while the controller presents it.
@MainActor
private struct MountedPicker {
    let window: NSWindow
    let host: NSView
    let controller: WebviewPaneController
    let tabIds: [String: WebviewTabId]

    static func make(preparations: HeldPickerPreparations) -> Self {
        _ = NSApplication.shared
        let tabs = [
            ("Alpha page", "about:tab-alpha"), ("Beta page", "about:tab-beta"), ("Gamma page", "about:tab-gamma"),
        ]
        .map { title, url in WebviewTab(id: .generate(), url: URL(string: url)!, title: title) }
        let controller = WebviewPaneController(
            paneId: UUIDv7.generate(),
            tabList: WebviewTabList(restoring: tabs, activeTabId: tabs[2].id)!,
            showNavigation: true)
        controller.isTabPickerPresented = true
        let loader = OcticonLoader(resourceBundle: testSourceCatalogOcticonBundle())
        let host = NSHostingView(
            rootView: PresentedPicker(controller: controller, octiconLoader: loader, preparations: preparations))
        host.frame = NSRect(x: 0, y: 0, width: 440, height: 520)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        host.layoutSubtreeIfNeeded()
        return Self(
            window: window, host: host, controller: controller,
            tabIds: Dictionary(uniqueKeysWithValues: tabs.map { ($0.title, $0.id) }))
    }

    /// Applies pending SwiftUI updates so the keyboard bridge holds the shown rows.
    func flush() {
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
    }

    func searchEditor() throws -> NSText {
        let field = try #require(Self.editableFields(host).first, "the search field is mounted")
        if field.currentEditor() == nil { field.selectText(nil) }
        return try #require(field.currentEditor(), "the search field took focus")
    }

    /// Replaces the search text in one edit, so the picker sees one new request.
    func search(_ query: String) throws {
        let editor = try searchEditor()
        editor.selectAll(nil)
        editor.insertText(query)
        flush()
    }

    func pressReturn() throws {
        NSApp.sendEvent(
            try #require(
                makeKeyEvent(
                    characters: "\r", charactersIgnoringModifiers: "\r", keyCode: 36,
                    windowNumber: window.windowNumber)))
    }

    func tearDown(_ preparations: HeldPickerPreparations) {
        preparations.finish()
        window.contentView = nil
        window.close()
    }

    private static func editableFields(_ root: NSView) -> [NSTextField] {
        let own = (root as? NSTextField).map { $0.isEditable ? [$0] : [] } ?? []
        return own + root.subviews.flatMap { editableFields($0) }
    }
}

/// The picker as its popover shows it: present while the controller presents it.
private struct PresentedPicker: View {
    @Bindable var controller: WebviewPaneController
    let octiconLoader: OcticonLoader
    let preparations: HeldPickerPreparations

    var body: some View {
        if controller.isTabPickerPresented {
            WebviewTabPickerView(
                controller: controller, octiconLoader: octiconLoader,
                prepareContents: { @MainActor request in await preparations.prepare(request) })
        }
    }
}

extension WebKitSerializedTests.WebviewPaneControllerTests {
    /// Waits for the outcome of `query`'s preparation. Ends when it arrives, or
    /// when the outcomes stream finishes because the test retired the view.
    @MainActor
    private func outcome(
        of query: String, in preparations: HeldPickerPreparations
    ) async -> PickerPreparationOutcome? {
        for await outcome in preparations.outcomes {
            switch outcome {
            case .returned(let returned) where returned == query: return outcome
            case .cancelled(let cancelled) where cancelled == query: return outcome
            default: continue
            }
        }
        return nil
    }

    @Test("a late result for an older search is dropped, so Return chooses a row still shown")
    func tabPickerDropsLateResultForOlderSearch() async throws {
        // Arrange: the "alpha" preparation finishes only after "beta" is shown.
        let alpha = HeldStep<String>("alpha preparation", cancellation: .holdThroughCancellation)
        let preparations = HeldPickerPreparations(steps: ["alpha": alpha])
        let picker = MountedPicker.make(preparations: preparations)
        defer { picker.tearDown(preparations) }
        #expect(await outcome(of: "", in: preparations) == .returned(query: ""))

        // Act
        try picker.search("alpha")
        _ = try await alpha.firstArrival()
        try picker.search("beta")
        #expect(await outcome(of: "beta", in: preparations) == .returned(query: "beta"))
        alpha.release()
        #expect(await outcome(of: "alpha", in: preparations) == .returned(query: "alpha"))
        picker.flush()
        try picker.pressReturn()

        // Assert: Beta, the only row shown for "beta"; not Alpha from the late result.
        #expect(picker.controller.activeTabId == picker.tabIds["Beta page"])
    }

    @Test("dismissing the picker while a preparation is held cancels it and applies nothing")
    func tabPickerDismissalCancelsHeldPreparation() async throws {
        // Arrange: the first preparation is held.
        let opening = HeldStep<String>("opening preparation")
        let preparations = HeldPickerPreparations(steps: ["": opening])
        let picker = MountedPicker.make(preparations: preparations)
        defer { picker.tearDown(preparations) }
        _ = try await opening.firstArrival()
        let activeBefore = picker.controller.activeTabId

        // Act: the picker is dismissed while its preparation is held.
        picker.controller.isTabPickerPresented = false
        picker.flush()

        // Assert: the held preparation ended as cancelled, and nothing changed.
        try await opening.cancellationObserved()
        #expect(await outcome(of: "", in: preparations) == .cancelled(query: ""))
        #expect(picker.controller.activeTabId == activeBefore)
    }

    @Test("the picker opens at its rows' height after a delayed first preparation and keeps it while searching")
    func tabPickerHeightLatchesOnFirstResultAndHolds() async throws {
        // Arrange: the first preparation is held.
        let opening = HeldStep<String>("opening preparation")
        let preparations = HeldPickerPreparations(steps: ["": opening])
        let picker = MountedPicker.make(preparations: preparations)
        defer { picker.tearDown(preparations) }
        _ = try await opening.firstArrival()
        picker.flush()
        let heightBeforeRows = picker.host.fittingSize.height

        // Act: the first result arrives, then a search matches nothing.
        opening.release()
        #expect(await outcome(of: "", in: preparations) == .returned(query: ""))
        picker.flush()
        let openedHeight = picker.host.fittingSize.height
        try picker.search("nothing like this")
        #expect(await outcome(of: "nothing like this", in: preparations) == .returned(query: "nothing like this"))
        picker.flush()
        let noMatchHeight = picker.host.fittingSize.height

        // Assert: the panel grew to its rows once they existed, then held that height.
        #expect(openedHeight > heightBeforeRows, "the panel must not latch before its first rows")
        #expect(openedHeight <= AppStyles.WorkspaceFocus.Webview.tabPickerMaximumHeight)
        #expect(noMatchHeight == openedHeight, "a search must not change the panel's height")
    }
}
