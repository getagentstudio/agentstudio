import AgentStudioBridge
import AgentStudioCodeViewer
import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioWebview
import AppKit
import Foundation

@MainActor
extension WorkspaceSurfaceCoordinator {
    /// Closing a browser pane's last tab closes the pane through the same
    /// validated close action the person's close control uses.
    private func submitBrowserPaneClose(_ paneId: UUID) {
        let owningPaneId = store.paneAtom.pane(paneId)?.parentPaneId ?? paneId
        guard let tabId = store.tabLayoutAtom.tabContaining(paneId: owningPaneId)?.id else {
            Self.logger.warning("Browser pane \(paneId) closed its last tab outside any tab")
            return
        }
        submitWorkspaceAction(.closePane(tabId: tabId, paneId: paneId))
    }

    /// Mount one nonterminal pane selected by a steady-state user action.
    @discardableResult
    func mountCurrentNonterminalContent(
        pane: Pane,
        bridgeViewerOpenTelemetryAnchor: BridgeViewerOpenTelemetryAnchor? = nil
    ) -> NSView? {
        guard
            let mountedView = mountNonterminalContent(
                pane: pane,
                bridgeViewerOpenTelemetryAnchor: bridgeViewerOpenTelemetryAnchor
            )
        else { return nil }
        registerPaneFilesystemContextIfNeeded(for: pane)
        return mountedView
    }

    /// Mount one nonterminal pane from the exact accepted composition value.
    ///
    /// The caller must claim the pane's prepared generation before entering
    /// this method. Mounting uses only values already carried by `pane` and
    /// never registers filesystem projection or reads repository topology.
    @discardableResult
    func mountPreparedNonterminalContent(pane: Pane) -> NSView? {
        mountNonterminalContent(pane: pane, bridgeViewerOpenTelemetryAnchor: nil)
    }

    @discardableResult
    private func mountNonterminalContent(
        pane: Pane,
        bridgeViewerOpenTelemetryAnchor: BridgeViewerOpenTelemetryAnchor?
    ) -> NSView? {
        viewRegistry.ensureSlot(for: pane.id)

        switch pane.content {
        case .terminal:
            preconditionFailure("terminal pane entered the nonterminal content owner")

        case .webview(let state):
            let view = WebviewPaneMountView(
                paneId: pane.id,
                state: state,
                tabSwitchProbe: performanceTraceRecorder.map { AgentStudioInteractionPerformanceProbe(recorder: $0) }
            )
            let paneID = pane.id
            view.controller.onTitleChange = { [weak self] title in
                self?.store.paneAtom.updatePaneTitle(paneID, title: title)
            }
            view.controller.onLastTabClosed = { [weak self] in
                self?.submitBrowserPaneClose(paneID)
            }
            registerHostedView(mountedView: view, for: pane.id)
            registerRuntimeIfNeeded(runtime: view.runtime, for: pane)
            Self.logger.info("Created webview pane \(pane.id)")
            return view

        case .codeViewer(let state):
            let initialText: String?
            if let codeViewerRuntime = registerCodeViewerRuntimeIfNeeded(for: pane) {
                if codeViewerRuntime.lifecycle == .created {
                    let transitioned = codeViewerRuntime.transitionToReady()
                    if !transitioned {
                        Self.logger.warning(
                            "Code viewer runtime for pane \(pane.id.uuidString, privacy: .public) failed ready transition"
                        )
                    }
                }
                initialText = codeViewerRuntime.displayedText.isEmpty ? nil : codeViewerRuntime.displayedText
            } else {
                initialText = nil
            }

            let view = CodeViewerPaneMountView(
                paneId: pane.id,
                state: state,
                initialText: initialText
            )
            registerHostedView(mountedView: view, for: pane.id)
            Self.logger.info("Created code viewer pane \(pane.id)")
            return view

        case .bridgePanel(let state):
            return createBridgePaneView(
                for: pane,
                state: state,
                viewerOpenTelemetryAnchor: bridgeViewerOpenTelemetryAnchor
            )

        case .unsupported:
            Self.logger.warning("Cannot create view for unsupported content type — pane \(pane.id)")
            return nil
        }
    }
}
