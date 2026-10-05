import AgentStudioTestHarness
import Foundation

@testable import AgentStudioBridge
@testable import AgentStudioCore
@testable import AgentStudioInfrastructure

/// Captures existing owner state at the boundary where the packaged DOM wait opens.
@MainActor
func packagedProductNativeReadback(_ controller: BridgePaneController) async -> String {
    guard let installation = await controller.productSessionOwner.activeInstallation else {
        return "installation=absent"
    }
    let session = await installation.session.diagnosticSnapshot
    let subscriptions = await installation.session.subscriptionSnapshots()
    guard let provider = controller.productSchemeProvider else {
        return "provider=absent; session=\(session); subscriptions=\(subscriptions)"
    }
    let coordinator = await provider.metadataCoordinator
    let stream = await coordinator.activeStream
    let requested = await coordinator.subscriptionKindById
    let opened = await coordinator.openedSourceSubscriptionIds
    let deferred = await coordinator.deferredOpenSubscriptionIds
    return "installedStream=\(String(describing: stream?.lease)); "
        + "streamAdmissionLive=\(stream?.productAdmission.withValidAdmission({ true }) == true); "
        + "session=\(session); subscriptions=\(subscriptions); "
        + "requestedSubscriptions=\(requested); openedSubscriptions=\(opened); deferredSubscriptions=\(deferred); "
        + "nativeComparison=\(String(describing: controller.refreshAdmissionCoordinator.productPresentationSnapshot.reviewComparison)); "
        + "foreground=\(controller.refreshAdmissionCoordinator.diagnosticSnapshot)"
}

/// Records existing native and worker telemetry as it arrives, including events after the DOM wait starts.
actor BridgePackagedProductDiagnosticRecorder: BridgePerformanceTraceRecording {
    func record(sample: BridgeTelemetrySample, receivedAtUnixNano: UInt64) async {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        if let data = try? encoder.encode(sample), let description = String(data: data, encoding: .utf8) {
            TestEventLogWriter.append(
                "packaged_telemetry\treceivedAt=\(receivedAtUnixNano) sample=\(description)\n",
                path: HeldStepEventLog.environment.path)
        }
    }

    func recordDrop(
        reason: BridgeTelemetryDropReason,
        droppedCount: Int,
        firstRejectedEventName: String?,
        receivedAtUnixNano: UInt64
    ) async {
        TestEventLogWriter.append(
            "packaged_telemetry_drop\treason=\(reason) count=\(droppedCount) first=\(firstRejectedEventName ?? "none") receivedAt=\(receivedAtUnixNano)\n",
            path: HeldStepEventLog.environment.path)
    }

    func drain() async throws {}
}
