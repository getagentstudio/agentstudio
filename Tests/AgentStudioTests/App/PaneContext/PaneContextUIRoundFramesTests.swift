import AgentStudioInfrastructure
import AgentStudioSharedComponents
import AgentStudioTestHarness
import AgentStudioTestSupport
import AppKit
import Darwin
import Dispatch
import Foundation
import SwiftUI
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioSessions

/// Permanent native capture fixture. Taste assertions are added only after owner approval.
@MainActor
@Suite("Pane context UI round native review frames", .serialized)
struct PaneContextUIRoundFramesTests {
    enum Scene: String, CaseIterable {
        case filename, postAngle, shortPicker, longRadio, checks, approval, environment, compiler, mixed
    }
    private var output: URL {
        URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "tmp/implementation-workflows/2026-10-28-pane-context-ui-round/frames")
    }

    @Test("Render realistic Messages originals before taste hardening", arguments: Scene.allCases, [true, false])
    func renderReviewFrames(scene: Scene, dark: Bool) async throws {
        installTestCoreAtomsIfNeeded()
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try await captureMessages(scene, dark: dark)
    }

    @Test(
        "Capture first-width and count-landed frames before F1 layout hardening",
        arguments: [Scene.filename, .compiler, .mixed], [true, false])
    func renderF1WidthTransition(scene: Scene, dark: Bool) async throws {
        installTestCoreAtomsIfNeeded()
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try await captureMessages(scene, dark: dark, holdFirstWidth: true)
    }

    @Test(
        "Compositor capture of held F1 width states",
        .enabled(if: ProcessInfo.processInfo.environment["AGENTSTUDIO_UI_ROUND_REVIEW"] == "1"),
        arguments: [Scene.compiler, .mixed])
    func interactiveF1WidthTransition(scene: Scene) async throws {
        installTestCoreAtomsIfNeeded()
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try await captureMessages(scene, dark: true, interactive: true, holdFirstWidth: true)
    }

    @Test(
        "Compositor capture of F2 input retention through filter unmount",
        .enabled(if: ProcessInfo.processInfo.environment["AGENTSTUDIO_UI_ROUND_REVIEW"] == "1"))
    func interactiveF2FilterRetention() async throws {
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let scene = try await PaneContextInteractionTestScene.make()
        do {
            var choice = AskFormDraft()
            choice.setChoice("blue", selected: true, allowsMultiple: false)
            var text = AskFormDraft()
            text.text = "The reply survives filtering"
            let input = try scene.bindings()
            input.draft(scene.key(scene.choice)).wrappedValue = choice
            input.draft(scene.key(scene.text)).wrappedValue = text
            try await scene.host.bodyLayoutsPrepared()
            for root in scene.host.native.roots { root.window?.appearance = NSAppearance(named: .darkAqua) }
            for phase in ["before-filter", "filtered-info", "returned-all"] {
                if phase == "filtered-info" { try await scene.filter(4) }
                if phase == "returned-all" { try await scene.filter(0) }
                let panel = try #require(scene.host.native.find("pane-context.popover-panel") as? NSView)
                try save(panel, name: "f2-" + phase)
                try await reviewWindow(scene.host, panel: panel, name: "f2-" + phase)
            }
            try await scene.close()
        } catch {
            try? await scene.close()
            throw error
        }
    }

    @Test("Render shared-shell Arrangements and Agent Line comparators", arguments: [true, false])
    func renderComparators(dark: Bool) throws {
        installTestCoreAtomsIfNeeded()
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try captureArrangements(dark: dark)
        try captureAgentLine(dark: dark)
    }

    @Test(
        "Interactive compositor capture for owner visual review",
        .enabled(if: ProcessInfo.processInfo.environment["AGENTSTUDIO_UI_ROUND_REVIEW"] == "1"),
        arguments: [Scene.filename, .mixed], [true, false])
    func interactiveReview(scene: Scene, dark: Bool) async throws {
        installTestCoreAtomsIfNeeded()
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try await captureMessages(scene, dark: dark, interactive: true)
    }

    private func captureMessages(
        _ scene: Scene, dark: Bool, interactive: Bool = false, holdFirstWidth: Bool = false
    ) async throws {
        let fixture = try await CompositionFactoryFixture.make()
        let widthDelivery = HeldStep<Void>("F1 actual width delivery before projection")
        defer { widthDelivery.retire() }
        var mounted: PaneContextPreparedNativeHost?
        do {
            let service = fixture.composition.paneContextService
            let sender = try fixture.sender(await fixture.bind(paneId: fixture.ownerId))
            let id = AgentMessageId.generateUUIDv7()
            let request = try request(scene, pane: fixture.ownerId, id: id, sender: sender)
            try #require(await service.send(request) == .created(id))
            if scene == .mixed {
                for (importance, body) in [
                    (MessageImportance.failure, "Swift build failed in the preview target."),
                    (.done, "Generated the release notes and checked the links."),
                    (.info, "Preview available at http://localhost:3000"),
                ] {
                    let notice = AgentMessageId.generateUUIDv7()
                    try #require(
                        await service.send(
                            .init(
                                paneId: fixture.ownerId, messageId: notice, sender: sender,
                                sourceOccurredAt: nil, importance: importance, body: body, why: nil, actions: [],
                                shape: .notice)) == .created(notice))
                }
            }
            await fixture.composition.presentationLane.publishPending()
            let bridge = PopoverOwnerFactBridge()
            let clock = TestPushClock(pendingSleepFactSink: bridge.observeClock)
            let time = PaneContextTestTime(clock: clock)
            let host = PaneContextPreparedNativeHost(
                fixture: fixture,
                entry: .messagesAction(PaneContextPopoverControlProjection.controls().messages, focusedMessage: nil),
                clock: clock, wallNow: { time.now }, bridge: bridge)
            mounted = host
            if holdFirstWidth {
                let owner = host.bindings.owner
                host.bindings.inputs.connectGeometry { key, opening, row, geometry, operation in
                    do { try await widthDelivery.arrive(()) } catch { return }
                    await owner.receiveBodyGeometry(
                        geometry, row: row, for: key, opening: opening, operation: operation)
                }
            }
            host.native.window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            try await host.open()
            for root in host.native.roots { root.window?.appearance = NSAppearance(named: dark ? .darkAqua : .aqua) }
            try await host.rendered()
            let panel = try #require(host.native.find("pane-context.popover-panel") as? NSView)
            let name = scene.rawValue + (dark ? "-dark" : "-light")
            if holdFirstWidth {
                let handle = try #require(host.handle)
                let deliveries = host.bindings.inputs.forwardingTasks(for: handle.key, opening: handle.opening.epoch)
                try #require(!deliveries.isEmpty, "The mounted text did not announce its actual width producer")
                try save(panel, name: "f1-" + name + "-first-open")
                try saveMeasurements(
                    host, panel: panel, name: "f1-" + name + "-first-open",
                    row: .init(sourcePaneId: fixture.ownerId.uuid, messageId: id.uuid))
                if interactive { try await reviewWindow(host, panel: panel, name: "f1-" + name + "-first-open") }
                widthDelivery.release()
                for delivery in deliveries { await delivery.value }
                try await host.rendered()
                try save(panel, name: "f1-" + name + "-count-landed")
                try saveMeasurements(
                    host, panel: panel, name: "f1-" + name + "-count-landed",
                    row: .init(sourcePaneId: fixture.ownerId.uuid, messageId: id.uuid))
                if interactive { try await reviewWindow(host, panel: panel, name: "f1-" + name + "-count-landed") }
            }
            try save(panel, name: name)
            if interactive && !holdFirstWidth { try await reviewWindow(host, panel: panel, name: name) }
            try saveMeasurements(
                host, panel: panel, name: name, row: .init(sourcePaneId: fixture.ownerId.uuid, messageId: id.uuid))
            if scene == .compiler {
                let identifier =
                    "pane-context.show-more-lines.pane-context.message-text." + fixture.ownerId.uuid.uuidString + "."
                    + id.uuid.uuidString
                let button = try #require(host.native.find(identifier) as? any NSAccessibilityProtocol)
                try #require(button.accessibilityPerformPress())
                print("UI_FRAME_PHASE disclosure-press-returned")
                try applyLocalView(panel)
                try save(panel, name: name + "-expanded")
                print("UI_FRAME_PHASE expanded-frame-saved")
            }
            print("UI_FRAME_PHASE native-close-start " + name)
            try await host.close()
            print("UI_FRAME_PHASE native-close-finished " + name)
            mounted = nil
            try await fixture.close()
            print("UI_FRAME_PHASE composition-close-finished " + name)
        } catch {
            widthDelivery.retire()
            try? await mounted?.close()
            try? await fixture.close()
            throw error
        }
    }

    private func reviewWindow(_ host: PaneContextPreparedNativeHost, panel: NSView, name: String) async throws {
        let review = HeldStep<Void>("owner compositor capture: " + name)
        let originalPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.regular)
        defer { NSApp.setActivationPolicy(originalPolicy) }
        let finish = NSButton(title: "Finish frame capture", target: nil, action: nil)
        let target = ReviewFinishTarget { review.release() }
        finish.target = target
        finish.action = #selector(ReviewFinishTarget.finish)
        finish.frame = .init(x: 20, y: 15, width: 220, height: 36)
        let controlWindow = NSWindow(
            contentRect: .init(x: 100, y: 120, width: 480, height: 75),
            styleMask: [.titled], backing: .buffered, defer: false)
        controlWindow.isReleasedWhenClosed = false
        controlWindow.title = "UI review controls — " + name
        controlWindow.contentView?.addSubview(finish)
        controlWindow.orderFront(nil)
        defer {
            controlWindow.contentView = nil
            controlWindow.close()
        }
        let observer = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: controlWindow, queue: .main
        ) { _ in review.retire() }
        defer { NotificationCenter.default.removeObserver(observer) }
        let popover = try #require(panel.window)
        let signalAdvance = ReviewSignalAdvance(review: review)
        popover.orderFront(nil)
        NSApp.activate()
        print(
            "UI_REVIEW_READY name=\(name) pid=\(ProcessInfo.processInfo.processIdentifier) popoverWindow=\(popover.windowNumber) controlsWindow=\(controlWindow.windowNumber)"
        )
        let receipt: [String: Any] = [
            "state": "held", "name": name, "pid": ProcessInfo.processInfo.processIdentifier,
            "popoverWindowId": popover.windowNumber, "controlsWindowId": controlWindow.windowNumber,
            "advance": "SIGUSR1 to \(ProcessInfo.processInfo.processIdentifier)",
        ]
        do {
            try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
                .write(to: output.appending(path: "interactive-review-current.json"), options: .atomic)
            // Finish, the owned SIGUSR1 source, cancellation or native retirement ends this hold.
            try await review.arrive(())
            try JSONSerialization.data(withJSONObject: ["state": "finished", "name": name], options: [.sortedKeys])
                .write(to: output.appending(path: "interactive-review-current.json"), options: .atomic)
            try await signalAdvance.close()
        } catch {
            try? JSONSerialization.data(withJSONObject: ["state": "retired", "name": name], options: [.sortedKeys])
                .write(to: output.appending(path: "interactive-review-current.json"), options: .atomic)
            try? await signalAdvance.close()
            throw error
        }
        withExtendedLifetime(target) {}
        print("UI_REVIEW_FINISHED name=\(name)")
    }

    private func request(_ scene: Scene, pane: PaneId, id: AgentMessageId, sender: AgentMessageSender) throws
        -> PaneMessageSendRequest
    {
        let question: String
        let form: PaneMessageSendShape
        switch scene {
        case .filename, .mixed:
            question = "What should the filename date represent?"
            form = try choice(["Collection date (Recommended)", "Post creation date"])
        case .postAngle:
            question = "What angle do you want to take with this post?"
            form = try choice([
                "Feature announcement/demo", "User benefit story", "Technical insight", "Broader AI interaction trend",
            ])
        case .shortPicker:
            question = "Which environment should receive the preview deployment?"
            form = try choice(["Local", "Development", "Staging", "QA", "Preview", "Production"])
        case .longRadio:
            question = "How should we investigate the failing release build?"
            form = try choice([
                "Inspect the failing Swift compiler diagnostics before changing the implementation",
                "Compare the current branch with the last passing main build",
                "Reproduce the isolated suite on the CI toolchain",
                "Check the generated resources and their target membership", "Review the dependency revision changes",
                "Capture the failing process and preserve its event stream",
            ])
        case .checks:
            question = "Which checks should run before merge?"
            form = try choice(["Swift tests", "BridgeWeb tests", "Lint", "Architecture lint"], multiple: true)
        case .approval:
            question = "Run mise run test in agentstudio.a1-frames?"
            form = .ask(reason: .approval, form: .approval, waiting: .nonBlocking)
        case .environment:
            question = "Configure the deployment verification."
            form = .ask(
                reason: .question,
                form: .elicitation(
                    .init(
                        properties: [
                            .init(
                                name: "environment", title: "Environment", description: nil,
                                type: .string(
                                    .init(
                                        choices: ["development", "staging", "production"], minLength: nil,
                                        maxLength: nil, format: nil))),
                            .init(name: "dry_run", title: "Dry run", description: nil, type: .boolean),
                        ], required: ["environment"])), waiting: .nonBlocking)
        case .compiler:
            question = Self.compilerOutput
            form = .notice
        }
        return .init(
            paneId: pane, messageId: id, sender: sender, sourceOccurredAt: nil,
            importance: scene == .compiler ? .failure : .attention, body: question, why: nil, actions: [], shape: form)
    }

    private func choice(_ labels: [String], multiple: Bool = false) throws -> PaneMessageSendShape {
        .ask(
            reason: .question,
            form: .choice(
                options: try labels.enumerated().map {
                    try AskChoice(id: .init("option-" + String($0.offset)), label: $0.element)
                }, allowsMultiple: multiple), waiting: .nonBlocking)
    }

    private func captureArrangements(dark: Bool) throws {
        let pane = UUIDv7.generate()
        let root = ArrangementPanel(
            tabId: UUIDv7.generate(), workspaceWindowId: nil,
            octiconLoader: makeTestOcticonLoader(),
            panes: [.init(id: pane, title: "agentstudio.a1-frames", isMinimized: false, supportsZoom: true)],
            zoomMode: nil,
            arrangements: [.init(id: UUIDv7.generate(), name: "Default", role: .defaultArrangement, isActive: true)],
            inlineRenameState: .init(),
            commandActionResolver: { command, _, _, _ in
                .init(commandSpec: command.definition, isEnabled: true, perform: {})
            }, onPaneAction: { _ in }, onDismiss: {})
        try captureStatic(root, width: 475, name: "arrangements", dark: dark)
    }

    private func captureAgentLine(dark: Bool) throws {
        let controls = PaneContextPopoverControlProjection.controls()
        let root = AgentLinePopover(
            model: .init(
                summary: "Reviewing deployment checks before merge", refs: [],
                writer: .session(provider: "codex", sessionRef: "release-review", bindingGeneration: UUIDv7.generate()),
                updatedAt: .distantPast, age: .init(text: "[2 min ago]")),
            octiconLoader: makeTestOcticonLoader(),
            goToPaneControl: controls.goToPane, onGoToPane: {})
        try captureStatic(root, width: 380, name: "agent-line", dark: dark)
    }

    private func captureStatic<Content: View>(_ content: Content, width: CGFloat, name: String, dark: Bool) throws {
        let host = NSHostingView(
            rootView:
                content
                .environment(\.colorScheme, dark ? .dark : .light)
                .background(Color(nsColor: .windowBackgroundColor)))
        host.frame = .init(x: 0, y: 0, width: width, height: 480)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        window.orderFront(nil)
        defer {
            window.contentView = nil
            window.close()
        }
        host.needsLayout = true
        host.layoutSubtreeIfNeeded()
        host.setFrameSize(.init(width: width, height: host.fittingSize.height))
        host.layoutSubtreeIfNeeded()
        try save(host, name: name + (dark ? "-dark" : "-light"))
    }

    private func applyLocalView(_ view: NSView) throws {
        let content = try #require(view.window?.contentView)
        content.needsLayout = true
        content.layoutSubtreeIfNeeded()
        content.displayIfNeeded()
    }

    private func save(_ view: NSView, name: String) throws {
        let root = try #require(view.window?.contentView)
        let region = root.convert(view.bounds, from: view)
        let bitmap = try #require(root.bitmapImageRepForCachingDisplay(in: region))
        root.effectiveAppearance.performAsCurrentDrawingAppearance {
            root.cacheDisplay(in: region, to: bitmap)
        }
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: output.appending(path: name + ".png"))
        Attachment.record(Array(png), named: name + ".png")
    }

    private func saveMeasurements(
        _ host: PaneContextPreparedNativeHost, panel: NSView, name: String, row: MessageRowModel.Key
    ) throws {
        let origin = panel.convert(panel.bounds, to: nil)
        var measured: [String: Any] = [
            "width": origin.width, "height": origin.height, "backingScale": panel.window?.backingScaleFactor ?? 0,
        ]
        for identifier in [
            "pane-context.messages-title", "pane-context.message-glyph." + row.controlScope,
            "pane-context.message-text." + row.controlScope, "pane-context.dismiss-all-notices",
            "pane-context.go-to-pane",
        ] {
            if let view = host.native.find(identifier) as? NSView {
                let rect = view.convert(view.bounds, to: nil)
                measured[identifier] = [
                    "left": rect.minX - origin.minX, "right": origin.maxX - rect.maxX,
                    "top": origin.maxY - rect.maxY, "bottom": rect.minY - origin.minY,
                ]
            }
        }
        try JSONSerialization.data(withJSONObject: measured, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appending(path: name + "-insets.json"))
    }

    // Exact captured Swift compiler diagnostic from the F15 setup failure, with only the checkout prefix removed.
    private static let compilerOutput = """
        error: SwiftCompile normal arm64 PaneContextPopoverRefreshOwnerTests+MixedPaging.swift failed with a nonzero exit code
            builtin-SwiftPerFileCompile PaneContextPopoverRefreshOwnerTests+MixedPaging.swift
        Tests/AgentStudioTests/App/PaneContext/PaneContextPopoverRefreshOwnerTests+MixedPaging.swift:80:19: error: cannot find 'withPaneContextService' in scope
         78 |         ) async throws -> Void
         79 |     ) async throws {
         80 |         try await withPaneContextService { fixture, service in
            |                   `- error: cannot find 'withPaneContextService' in scope
         81 |             // Live source metadata, not a native graph, forces real source discovery at the bounded-read seam.
         82 |             let drawers = (0..<160).map { _ in PaneId.generateUUIDv7() }
        """
}

@MainActor
private final class ReviewFinishTarget: NSObject {
    private let finishCapture: () -> Void
    init(finishCapture: @escaping () -> Void) { self.finishCapture = finishCapture }
    @objc func finish() { finishCapture() }
}

/// Owned only by the environment-gated interactive review, never by production code.
@MainActor
private final class ReviewSignalAdvance {
    private enum End: Sendable, Equatable { case cancelled }
    private let source: any DispatchSourceSignal
    private let previousDisposition: (@convention(c) (Int32) -> Void)?
    private let ended: FactRecorder<Int, End>
    private var closing: Task<Void, Error>?

    init(review: HeldStep<Void>) {
        previousDisposition = Darwin.signal(SIGUSR1, SIG_IGN)
        let ended = FactRecorder<Int, End>(
            vocabulary: .init(
                describeScope: { _ in "interactive review SIGUSR1 source" },
                describeFact: { String(describing: $0) }, isClosing: { _, _ in true }))
        self.ended = ended
        let source = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .global(qos: .userInitiated))
        self.source = source
        source.setEventHandler { @Sendable in review.release() }
        source.setCancelHandler { @Sendable in ended.append(scope: 0, fact: .cancelled) }
        source.activate()
    }

    func close() async throws {
        if let closing {
            try await closing.value
            return
        }
        // Cleanup must join the native cancellation callback even if the awaiting test was cancelled.
        let closing = Task { @MainActor in
            source.cancel()
            defer { _ = Darwin.signal(SIGUSR1, previousDisposition) }
            try await ended.expectNext(in: 0, .cancelled)
            ended.receive(.ended)
            try await ended.finish()
        }
        self.closing = closing
        try await closing.value
    }
}
