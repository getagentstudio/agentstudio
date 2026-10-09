import AgentStudioCore
import AgentStudioInfrastructure
import AppKit
import Testing

@testable import AgentStudioTerminal

@MainActor
@Suite("Surface manager production callback guard", .serialized)
struct SurfaceManagerCallbackGuardTests {
    enum NativeFreeLifetime: String, CaseIterable, Sendable {
        case unregistered, activeWithoutNativeSurface, hiddenWithoutNativeSurface
        case undoWithoutNativeSurface, retired, replaced
    }

    nonisolated static let copiedUpdates: [GhosttyDirectHostUpdate] = [
        .closeRequested, .workingDirectory("/guard-must-not-apply"), .workingDirectory(nil),
        .reportedInitialSize(width: 640, height: 480), .reportedCellSize(width: 8, height: 16),
        .cache(tag: GhosttyActionTag.scrollbar.rawValue, payload: .scrollbar(total: 200, offset: 80, length: 40)),
        .cache(tag: GhosttyActionTag.configChange.rawValue, payload: .noPayload),
    ]

    @Test(
        "production host drops copied updates for invalid native lifetimes", arguments: NativeFreeLifetime.allCases,
        copiedUpdates)
    func nativeFreeLifetimeRejectsViewEffects(lifetime: NativeFreeLifetime, update: GhosttyDirectHostUpdate)
        async throws
    {
        let surfaceID = UUIDv7.generate()
        let paneID = UUIDv7.generate()
        var engineReads = 0
        let manager = SurfaceManager(
            appCommandDispatcher: TerminalFixtureCommandDispatcher(), engineAccess: { .unavailable },
            callbackHandlingAccess: { nil }, maxCreationRetries: 0, healthCheckInterval: 3600,
            processExitedCheck: { _ in false }
        )
        let view = Ghostty.SurfaceView(
            managedSurfaceID: surfaceID, appCommandDispatcher: TerminalFixtureCommandDispatcher())
        defer { manager.destroy(surfaceID) }
        if lifetime != .unregistered {
            let managed = try manager.acceptCreatedSurface(view, metadata: SurfaceMetadata(paneId: paneID)).get()
            switch lifetime {
            case .activeWithoutNativeSurface:
                manager.attach(managed.id, to: paneID)
                #expect(manager.activeSurfaces[surfaceID]?.surface === view)
            case .undoWithoutNativeSurface:
                manager.attach(managed.id, to: paneID)
                manager.retainSurfacesForUndo(forPaneIDs: [paneID])
                #expect(manager.undoStack.first?.surface.surface === view)
                #expect(manager.paneId(for: surfaceID) == nil)
            case .retired:
                manager.destroy(surfaceID)
                #expect(manager.surface(for: surfaceID) == nil)
            case .replaced:
                manager.destroy(surfaceID)
                let replacement = Ghostty.SurfaceView(
                    managedSurfaceID: surfaceID, appCommandDispatcher: TerminalFixtureCommandDispatcher())
                _ = try manager.acceptCreatedSurface(replacement, metadata: SurfaceMetadata(paneId: paneID)).get()
                #expect(manager.hiddenSurfaces[surfaceID]?.surface === replacement)
                #expect(ObjectIdentifier(replacement) != ObjectIdentifier(view))
            case .hiddenWithoutNativeSurface:
                #expect(manager.hiddenSurfaces[surfaceID]?.surface === view)
            case .unregistered:
                break
            }
        }
        var closeRequests = 0
        view.onCloseRequested = { _ in
            closeRequests += 1
            return nil
        }
        #expect(view.surface == nil)
        let host = manager.makeActionRoutingHost(
            runtimeRegistry: RuntimeRegistry(), startupTraceRecorder: nil, traceRuntime: nil,
            engineAccess: {
                engineReads += 1
                return .unavailable
            }, activityRouterAccess: { nil }
        )

        let result = await host.applyDirectHost(
            surfaceID: surfaceID, viewObjectID: ObjectIdentifier(view), update: update)

        #expect(result == .dropped(.staleSurface))
        #expect(view.pwd == nil)
        #expect(view.reportedInitialSize == nil)
        #expect(view.reportedCellSize == nil)
        #expect(view.hostScrollbarState == nil)
        #expect(closeRequests == 0)
        #expect(engineReads == 0)
    }
}
