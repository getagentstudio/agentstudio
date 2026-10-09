import AgentStudioCore
import AgentStudioInfrastructure
import AppKit
import Foundation

@MainActor
private final class WeakGhosttyRoutingLookup: GhosttyActionRoutingLookup {
    private weak var manager: SurfaceManager?

    init(manager: SurfaceManager) {
        self.manager = manager
    }

    func surfaceId(forViewObjectId viewObjectId: ObjectIdentifier) -> UUID? {
        manager?.surfaceId(forViewObjectId: viewObjectId)
    }

    func paneId(for surfaceId: UUID) -> UUID? {
        manager?.paneId(for: surfaceId)
    }
}

extension SurfaceManager {
    package func makeActionRoutingHost(
        runtimeRegistry: RuntimeRegistry,
        startupTraceRecorder: AgentStudioStartupTraceRecorder?,
        traceRuntime: AgentStudioTraceRuntime?,
        engineAccess: @escaping @MainActor @Sendable () -> GhosttyEngineAvailability,
        activityRouterAccess: @escaping @MainActor @Sendable () -> TerminalActivityRouter?
    ) -> GhosttyActionRoutingHost {
        GhosttyActionRoutingHost(
            dependencies: .init(
                runtimeRegistry: runtimeRegistry,
                routingLookup: WeakGhosttyRoutingLookup(manager: self),
                mountedHostResolver: .init(
                    surfaceForID: { [weak self] in self?.surface(for: $0) },
                    paneIDForSurfaceID: { [weak self] in self?.paneId(for: $0) }
                ),
                applyNativeView: { [weak self] surfaceID, viewID, update in
                    guard let view = self?.nativeLiveView(surfaceID: surfaceID, viewObjectID: viewID) else {
                        return .dropped(.staleSurface)
                    }
                    switch update {
                    case .closeRequested:
                        let completion = view.handleCloseRequested()
                        await completion.value
                    case .workingDirectory(let path):
                        view.pwdDidChange(path)
                    case .reportedInitialSize(let width, let height):
                        view.updateReportedInitialSize(NSSize(width: Double(width), height: Double(height)))
                    case .reportedCellSize(let width, let height):
                        let backingSize = NSSize(width: Double(width), height: Double(height))
                        view.updateReportedCellSize(view.convertFromBacking(backingSize))
                    case .cache(let rawTag, let payload):
                        guard let tag = GhosttyActionTag(rawValue: rawTag) else { return .unchanged }
                        switch tag {
                        case .configChange, .reloadConfig:
                            guard case .available(let engine) = engineAccess() else {
                                return .dropped(.engineUnavailable)
                            }
                            view.updateHostConfigSnapshot(engine.hostConfigSnapshot())
                        case .scrollbar:
                            guard case .scrollbar(let total, let offset, let length) = payload else {
                                return .unchanged
                            }
                            view.updateHostScrollbarState(
                                ScrollbarState(top: Int(offset), bottom: Int(offset + length), total: Int(total))
                            )
                        case .setTitle:
                            guard case .titleChanged(let title) = payload else { return .unchanged }
                            view.titleDidChange(title)
                        default:
                            return .unchanged
                        }
                    }
                    return .applied
                },
                activityContext: { paneID in activityRouterAccess()?.sourceInputContext(paneID: paneID) },
                submitActivityInput: { input in await activityRouterAccess()?.consumeSourceInputIfAccepting(input) },
                startupTraceRecorder: startupTraceRecorder,
                traceRuntime: traceRuntime
            )
        )
    }

    package func makeTerminalPaneSurfaceOperations() -> TerminalPaneMountView.SurfaceOperations {
        .init(
            registerHealthDelegate: { [weak self] in self?.addHealthDelegate($0) },
            destroySurface: { [weak self] in self?.destroy($0) },
            hasProcessExited: { [weak self] in self?.hasProcessExited($0) ?? true },
            setFocus: { [weak self] in self?.setFocus($0, focused: $1) }
        )
    }

    private func nativeLiveView(surfaceID: UUID, viewObjectID: ObjectIdentifier) -> Ghostty.SurfaceView? {
        let view =
            activeSurfaces[surfaceID]?.surface ?? hiddenSurfaces[surfaceID]?.surface
            ?? undoStack.first(where: { $0.surface.id == surfaceID })?.surface.surface
        guard let view, view.managedSurfaceID == surfaceID,
            ObjectIdentifier(view) == viewObjectID, view.surface != nil
        else { return nil }
        return view
    }
}
