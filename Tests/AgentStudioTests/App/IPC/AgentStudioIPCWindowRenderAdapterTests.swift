import AgentStudioAppIPC
import AgentStudioIPCTransport
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import AppKit
import Testing

@testable import AgentStudio
@testable import AgentStudioTestSupport

@MainActor
@Suite("App window render adapter", .serialized)
struct AgentStudioIPCWindowRenderAdapterTests {
    init() { installTestCoreAtomsIfNeeded() }
    @Test("resize reports the actual window bounds and retains native resize notification")
    func windowResizeReadsAppliedContentSize() async throws {
        let fixture = try WindowRenderTestFixture()
        defer { fixture.tearDown() }
        let owner = WindowRenderTestOwner(window: fixture.window, windowId: fixture.windowId)
        let adapter = AgentStudioIPCWindowRenderAdapter(owner: owner, rendersDirectory: fixture.rendersDirectory)
        let contentView = try #require(fixture.window.contentView)
        let minimumView = NSView()
        minimumView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(minimumView)
        NSLayoutConstraint.activate([
            minimumView.widthAnchor.constraint(greaterThanOrEqualToConstant: 180),
            minimumView.heightAnchor.constraint(greaterThanOrEqualToConstant: 120),
            minimumView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            minimumView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            minimumView.topAnchor.constraint(equalTo: contentView.topAnchor),
            minimumView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
        let delegate = WindowRenderResizeDelegate()
        fixture.window.delegate = delegate
        for requestedSize in [NSSize(width: 520, height: 600), NSSize(width: 10, height: 10)] {
            let correlationId = UUIDv7.generate()
            let result = try await adapter.resize(
                .init(
                    workspaceWindowId: fixture.windowId, contentWidth: requestedSize.width,
                    contentHeight: requestedSize.height, correlationId: correlationId))
            #expect(result.workspaceWindowId == fixture.windowId)
            #expect(result.correlationId == correlationId)
            #expect(
                result.contentSize
                    == IPCWindowContentSize(width: contentView.bounds.width, height: contentView.bounds.height))
        }
        #expect(!delegate.frames.isEmpty)
        #expect(delegate.frames.last == fixture.window.frame)
        fixture.window.delegate = nil
    }

    @Test("invalid sizes and unknown windows leave layout and render storage unchanged")
    func windowAdapterRejectsInvalidTargetsAndSizes() async throws {
        let fixture = try WindowRenderTestFixture()
        defer { fixture.tearDown() }
        let owner = WindowRenderTestOwner(window: fixture.window, windowId: fixture.windowId)
        let adapter = AgentStudioIPCWindowRenderAdapter(owner: owner, rendersDirectory: fixture.rendersDirectory)
        let originalFrame = fixture.window.frame
        for invalid in [Double.nan, .infinity, -.infinity, 0, -1] {
            for size in [(invalid, 600.0), (520.0, invalid)] {
                await #expect(throws: AppIPCWindowRenderError.invalidSize) {
                    try await adapter.resize(
                        .init(
                            workspaceWindowId: fixture.windowId, contentWidth: size.0, contentHeight: size.1,
                            correlationId: UUIDv7.generate()))
                }
            }
        }
        let missingWindowId = UUIDv7.generate()
        await #expect(throws: AppIPCWindowRenderError.targetNotFound) {
            try await adapter.render(.init(workspaceWindowId: missingWindowId))
        }
        await #expect(throws: AppIPCWindowRenderError.targetNotFound) {
            try await adapter.resize(
                .init(
                    workspaceWindowId: missingWindowId, contentWidth: 520, contentHeight: 600,
                    correlationId: UUIDv7.generate()))
        }
        #expect(fixture.window.frame == originalFrame)
        #expect(!FileManager.default.fileExists(atPath: fixture.rendersDirectory.path))
    }

    @Test("the App owner refuses unknown and retiring main windows without active-window fallback")
    func windowOwnerRejectsRetiringWindow() throws {
        let fixture = try WindowRenderTestFixture()
        defer { fixture.tearDown() }
        let traceRuntime = AgentStudioTraceRuntime.fromEnvironment()
        let appDelegate = AppDelegate(
            traceRuntime: traceRuntime,
            startupTraceRecorder: AgentStudioStartupTraceRecorder(traceRuntime: traceRuntime))
        let controller = MainWindowController(
            window: fixture.window, commandDispatcher: appDelegate.commandDispatcherForBoot())
        appDelegate.mainWindowController = controller
        #expect(try appDelegate.renderingWindow(workspaceWindowId: controller.workspaceWindowId) === fixture.window)
        #expect(throws: AppIPCWindowRenderError.targetNotFound) {
            try appDelegate.renderingWindow(workspaceWindowId: UUIDv7.generate())
        }
        controller.shutdown()
        #expect(throws: AppIPCWindowRenderError.targetNotFound) {
            try appDelegate.renderingWindow(workspaceWindowId: controller.workspaceWindowId)
        }
        appDelegate.mainWindowController = nil
    }

    @Test("both methods cross the real prepared app socket and return finalized native outcomes")
    func windowMethodsCrossRealAppSocket() async throws {
        let fixture = try WindowRenderTestFixture()
        defer { fixture.tearDown() }
        let harness = try await SessionsVerticalHarness.make()
        do {
            let controller = try #require(harness.appDelegate.mainWindowController)
            controller.window = fixture.window
            let correlationId = UUIDv7.generate()
            let resize = try await harness.response(
                method: "window.resize",
                params: .object([
                    "workspaceWindowId": .string(harness.workspaceWindowId.uuidString),
                    "contentWidth": .number(96), "contentHeight": .number(64),
                    "correlationId": .string(correlationId.uuidString),
                ]))
            #expect(resize.error == nil)
            let resizeValue = try #require(resize.result)
            let applied = try JSONDecoder().decode(IPCWindowResizeResult.self, from: JSONEncoder().encode(resizeValue))
            #expect(applied.correlationId == correlationId)
            #expect(applied.contentSize == IPCWindowContentSize(width: 96, height: 64))
            let render = try await harness.response(
                method: "window.render",
                params: .object([
                    "workspaceWindowId": .string(harness.workspaceWindowId.uuidString)
                ]))
            #expect(render.error == nil)
            let renderValue = try #require(render.result)
            let result = try JSONDecoder().decode(IPCWindowRenderResult.self, from: JSONEncoder().encode(renderValue))
            #expect(
                URL(fileURLWithPath: result.image.path).deletingLastPathComponent()
                    == harness.rootDirectory.appendingPathComponent("renders", isDirectory: true))
            try expectWindowRenderInk(decodedWindowRenderBitmap(path: result.image.path), scale: result.image.scale)
            let refused = try await harness.response(
                method: "window.render",
                params: .object([
                    "workspaceWindowId": .string(harness.workspaceWindowId.uuidString)
                ]), authentication: .boundPane)
            #expect(refused.error?.code == -32_011)
            #expect(
                try FileManager.default.contentsOfDirectory(
                    atPath:
                        harness.rootDirectory.appendingPathComponent("renders").path
                ).count == 1)
        } catch {
            await harness.tearDown()
            throw error
        }
        await harness.tearDown()
    }
}

@MainActor
private final class WindowRenderTestOwner: AgentStudioIPCWindowOwning {
    let window: NSWindow
    let windowId: UUID
    init(window: NSWindow, windowId: UUID) {
        self.window = window
        self.windowId = windowId
    }
    func renderingWindow(workspaceWindowId: UUID) throws -> NSWindow {
        guard workspaceWindowId == windowId else { throw AppIPCWindowRenderError.targetNotFound }
        return window
    }
}

@MainActor
private final class WindowRenderResizeDelegate: NSObject, NSWindowDelegate {
    var frames: [NSRect] = []
    func windowDidResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        frames.append(window.frame)
    }
}
