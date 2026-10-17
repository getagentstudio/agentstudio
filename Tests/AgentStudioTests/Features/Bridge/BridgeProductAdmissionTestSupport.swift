import Foundation
import Testing

@testable import AgentStudioBridge

struct BridgeProductAdmissionTestContext: Sendable {
    let gate: BridgeProductAdmissionGate
    let context: BridgeProductAdmissionContext

    static func make() throws -> Self {
        let gate = BridgeProductAdmissionGate()
        return try Self(
            gate: gate,
            context: #require(gate.acquire())
        )
    }

    func close() {
        gate.close()
    }

    func beginControl(
        in session: BridgeProductSession,
        exactRequestBytes: Data,
        presentedCapability: String
    ) async -> BridgeProductSessionControlAdmission {
        await session.beginControl(
            exactRequestBytes: exactRequestBytes,
            presentedCapability: presentedCapability,
            productAdmission: context
        )
    }
}

struct BridgePaneRefreshWorkAdmissionTestContext: Sendable {
    let admission: BridgePaneRefreshWorkAdmission
    let source: BridgePaneRefreshWorkAdmissionSource

    @MainActor
    static func foregroundOnMainActor() -> Self {
        let coordinator = BridgePaneRefreshAdmissionCoordinator(initialActivity: .foreground)
        guard let admission = coordinator.acquireForegroundWork() else {
            preconditionFailure("Foreground Bridge pane activity must admit test work")
        }
        return Self(
            admission: admission,
            source: coordinator.workAdmissionSource
        )
    }

    static func foreground() async -> Self {
        await foregroundOnMainActor()
    }
}

extension BridgePaneProductFileMetadataSource {
    func open(
        subscription: BridgeProductSubscriptionSnapshot,
        productAdmission: BridgeProductAdmissionContext,
        emit: @escaping BridgePaneProductFileSourceFactSink
    ) async throws {
        let foregroundWorkAdmission = await BridgePaneRefreshWorkAdmissionTestContext.foreground()
            .admission
        try await open(
            subscription: subscription,
            productAdmission: productAdmission,
            foregroundWorkAdmission: foregroundWorkAdmission,
            emit: emit
        )
    }

    func applyViewDemand(
        subscriptionId: String,
        demand: BridgePaneProductFileViewDemand,
        productAdmission: BridgeProductAdmissionContext,
        forceRecapture: Bool,
        emit: @escaping BridgePaneProductFileSourceFactSink
    ) async throws {
        let foregroundWorkAdmission = await BridgePaneRefreshWorkAdmissionTestContext.foreground()
            .admission
        try await applyViewDemand(
            subscriptionId: subscriptionId,
            demand: demand,
            productAdmission: productAdmission,
            foregroundWorkAdmission: foregroundWorkAdmission,
            forceRecapture: forceRecapture,
            emit: emit
        )
    }
}
