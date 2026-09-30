import Foundation

package struct IPCBridgeTelemetryMethodDescriptors: Sendable {
    package let bridgeTelemetrySnapshot: IPCMethodDescriptor<IPCBridgePaneParams, IPCBridgeTelemetrySnapshotResult>
    package let bridgeTelemetryFlush: IPCMethodDescriptor<IPCBridgeTelemetryFlushParams, IPCBridgeTelemetryFlushResult>

    init(examples: IPCBuiltInMethodExampleContext) throws {
        bridgeTelemetrySnapshot = try IPCBuiltInDescriptorSupport.read(
            name: "bridge.telemetry.snapshot",
            description: "Read the current telemetry report or its unavailable reason.",
            parameters: IPCBridgePaneParams(handle: "self"),
            result: IPCBridgeTelemetrySnapshotResult(
                paneId: examples.paneId,
                kind: .unavailable,
                unavailableReason: .disabled,
                report: nil
            ),
            privilege: .bridgeTelemetryRead,
            dataScope: .bridgeTelemetry,
            targetKinds: [.pane],
            owner: .bridgeCapability,
            errors: Self.telemetryErrors,
            agentEligibility: .notYetAllowed
        )
        bridgeTelemetryFlush = try IPCBuiltInDescriptorSupport.mutation(
            name: "bridge.telemetry.flush",
            description: "Flush buffered Bridge telemetry and return its settled report.",
            parameters: IPCBridgeTelemetryFlushParams(
                handle: "self",
                correlationId: examples.correlationId
            ),
            result: IPCBridgeTelemetryFlushResult(
                paneId: examples.paneId,
                kind: .unavailable,
                unavailableReason: .disabled,
                report: nil,
                drained: nil
            ),
            metadata: .init(
                privilege: .bridgeTelemetryFlush,
                dataScope: .bridgeTelemetry,
                targetKinds: [.pane],
                owner: .bridgeCapability,
                errors: Self.telemetryErrors,
                agentEligibility: .notYetAllowed)
        )
    }

    private static let telemetryErrors = [
        IPCBuiltInDescriptorSupport.invalidParams,
        IPCBuiltInDescriptorSupport.targetNotFound,
        IPCBuiltInDescriptorSupport.unavailable,
    ]

    var descriptorRepresentations: [any IPCMethodDescriptorRepresentation] {
        get throws {
            let representations: [any IPCMethodDescriptorRepresentation] = try [
                IPCMethodDescriptorRepresentations(typedDescriptor: bridgeTelemetrySnapshot),
                IPCMethodDescriptorRepresentations(typedDescriptor: bridgeTelemetryFlush),
            ]
            return representations
        }
    }

    var erased: [IPCAnyMethodDescriptor] {
        get throws { try descriptorRepresentations.map(\.erasedDescriptor) }
    }
}

package struct IPCBridgeMethodDescriptors: Sendable {
    package let review: IPCBridgeReviewMethodDescriptors
    package let control: IPCBridgeControlMethodDescriptors
    package let telemetry: IPCBridgeTelemetryMethodDescriptors

    init(inputs: IPCBuiltInMethodCatalogInputs) throws {
        review = try IPCBridgeReviewMethodDescriptors(inputs: inputs)
        control = try IPCBridgeControlMethodDescriptors(examples: inputs.examples)
        telemetry = try IPCBridgeTelemetryMethodDescriptors(examples: inputs.examples)
    }

    var descriptorRepresentations: [any IPCMethodDescriptorRepresentation] {
        get throws {
            try review.descriptorRepresentations
                + control.descriptorRepresentations
                + telemetry.descriptorRepresentations
        }
    }

    var erased: [IPCAnyMethodDescriptor] {
        get throws { try descriptorRepresentations.map(\.erasedDescriptor) }
    }
}
