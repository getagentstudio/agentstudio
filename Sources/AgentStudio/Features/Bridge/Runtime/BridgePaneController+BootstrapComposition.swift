import AgentStudioCore
import AgentStudioInfrastructure
import Foundation
import WebKit
import os.log

private let bridgeProductBootstrapLogger = Logger(
    subsystem: "com.agentstudio",
    category: "BridgeProductBootstrap"
)

extension BridgePaneController {
    static func registerAgentStudioSchemeHandler(
        in config: inout WebPage.Configuration,
        input: BridgeSchemeHandlerRegistrationInput
    ) {
        guard let scheme = URLScheme("agentstudio") else { return }
        config.urlSchemeHandlers[scheme] = BridgeSchemeHandler(
            paneId: input.paneId,
            appRootURL: input.appRootURL,
            telemetrySessionOwner: input.telemetrySessionOwner,
            productSessionRouter: input.productSessionRouter
        )
    }

    nonisolated static func makeTelemetrySessionDependencies(
        scopeGate: BridgeTelemetryScopeGate,
        recorder: (any BridgePerformanceTraceRecording)?
    ) -> BridgePaneTelemetrySessionDependencies? {
        guard scopeGate.isEnabled(.web), let recorder else { return nil }
        do {
            let projector = BridgeTelemetryNativeProjector(recorder: recorder)
            let installation = try BridgeTelemetrySessionInstallation.make(
                enabledScopes: [.web],
                endpointURL: "agentstudio://telemetry/batch",
                policy: .live,
                projector: projector.project
            )
            return BridgePaneTelemetrySessionDependencies(
                installation: installation,
                owner: BridgePaneTelemetrySessionOwner(initialInstallation: installation)
            )
        } catch {
            bridgeProductBootstrapLogger.error("Bridge telemetry session creation failed: \(error)")
            return nil
        }
    }

    nonisolated static func resolveTelemetryDependencies(
        traceRuntime: AgentStudioTraceRuntime?,
        telemetryRuntimePolicy: BridgeTelemetryRuntimePolicy,
        telemetryScopeGate: BridgeTelemetryScopeGate?,
        telemetryRecorder: (any BridgePerformanceTraceRecording)?,
        telemetrySessionDependencies: BridgePaneTelemetrySessionDependencies?
    ) -> (
        scopeGate: BridgeTelemetryScopeGate,
        recorder: (any BridgePerformanceTraceRecording)?,
        sessionDependencies: BridgePaneTelemetrySessionDependencies?
    ) {
        guard telemetryRuntimePolicy.allowsTelemetry else {
            return (BridgeTelemetryScopeGate(enabledScopes: []), nil, telemetrySessionDependencies)
        }

        let resolvedScopeGate = telemetryScopeGate ?? BridgeTelemetryScopeGate(traceRuntime: traceRuntime)
        let resolvedRecorder =
            telemetryRecorder
            ?? (resolvedScopeGate.isEnabled ? BridgePerformanceTraceRecorder(traceRuntime: traceRuntime) : nil)
        let resolvedSessionDependencies =
            telemetrySessionDependencies
            ?? makeTelemetrySessionDependencies(scopeGate: resolvedScopeGate, recorder: resolvedRecorder)
        return (resolvedScopeGate, resolvedRecorder, resolvedSessionDependencies)
    }

    static func makeBootstrapScript(_ input: BridgeBootstrapScriptInput) -> WKUserScript {
        WKUserScript(
            source: BridgeBootstrap.generateScript(
                appProtocol: Self.bridgeAppProtocol(for: input.panelKind),
                reviewPaneId: input.reviewPaneId,
                reviewStreamId: input.reviewStreamId,
                telemetryConfig: input.telemetryConfig
            ),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true,
            in: input.bridgeWorld
        )
    }

    static func makeBootstrapArtifacts(
        paneId: UUID,
        state: BridgePaneState,
        telemetryScopeGate: BridgeTelemetryScopeGate,
        viewerOpenTelemetryAnchor: BridgeViewerOpenTelemetryAnchor? = nil,
        bridgeWorld: WKContentWorld
    ) -> BridgeBootstrapArtifacts {
        let reviewPaneId = paneId.uuidString
        let reviewStreamId = "review:\(reviewPaneId)"
        let webTelemetryScopes = telemetryScopeGate.browserExposedScopes
        let telemetryConfig: BridgeTelemetryBootstrapConfig?
        if webTelemetryScopes.isEmpty {
            telemetryConfig = nil
        } else {
            telemetryConfig = BridgeTelemetryBootstrapConfig.enabled(
                scopes: webTelemetryScopes,
                scenario: BridgeTelemetryBootstrapConfig.packageApplyContentFetchScenario,
                viewerOpenEpochUnixMillis: viewerOpenTelemetryAnchor?.openEpochUnixMillis,
                viewerOpenTraceparent: viewerOpenTelemetryAnchor?.traceparent
            )
        }
        let script = makeBootstrapScript(
            BridgeBootstrapScriptInput(
                reviewPaneId: reviewPaneId,
                reviewStreamId: reviewStreamId,
                panelKind: state.panelKind,
                telemetryConfig: telemetryConfig,
                bridgeWorld: bridgeWorld
            )
        )
        return BridgeBootstrapArtifacts(script: script)
    }

    private static func bridgeAppProtocol(for panelKind: BridgePanelKind) -> String {
        switch panelKind {
        case .diffViewer:
            "review"
        case .fileViewer:
            "worktree-file"
        }
    }

    static func installInitialUserScripts(
        in userContentController: WKUserContentController,
        bootstrapScript: WKUserScript,
        managementScript: WKUserScript
    ) {
        userContentController.addUserScript(bootstrapScript)
        #if DEBUG
            userContentController.addUserScript(Self.makePageDiagnosticsProbeScript())
        #endif
        userContentController.addUserScript(managementScript)
    }

    static func worktreeFileBootstrapRootURL(
        metadata: PaneMetadata,
        source: BridgePaneSource?
    ) -> URL? {
        if case .workspace(let rootPath, _)? = source {
            return URL(fileURLWithPath: rootPath).standardizedFileURL.resolvingSymlinksInPath()
        }
        return metadata.cwd?.standardizedFileURL.resolvingSymlinksInPath()
    }
}
