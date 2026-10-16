import Foundation

package struct IPCBridgeTelemetryMethodDescriptors: Sendable {
    package let bridgeTelemetrySnapshot: IPCMethodDescriptor<IPCBridgePaneParams, IPCBridgeTelemetrySnapshotResult>
    package let bridgeTelemetryFlush: IPCMethodDescriptor<IPCBridgeTelemetryFlushParams, IPCBridgeTelemetryFlushResult>

    init(examples: IPCBuiltInMethodExampleContext) throws {
        bridgeTelemetrySnapshot = try Self.bridgeTelemetrySnapshotEntry.makeDescriptor(
            inputs: IPCBuiltInMethodCatalogInputs(examples: examples))
        bridgeTelemetryFlush = try Self.bridgeTelemetryFlushEntry.makeDescriptor(
            inputs: IPCBuiltInMethodCatalogInputs(examples: examples))
    }

    init(representations: [String: any IPCMethodDescriptorRepresentation]) throws {
        bridgeTelemetrySnapshot = try Self.bridgeTelemetrySnapshotEntry.typedDescriptor(in: representations)
        bridgeTelemetryFlush = try Self.bridgeTelemetryFlushEntry.typedDescriptor(in: representations)
    }

    static let bridgeTelemetrySnapshotEntry = IPCBuiltInMethodEntry<
        IPCBridgePaneParams, IPCBridgeTelemetrySnapshotResult
    >(
        name: "bridge.telemetry.snapshot", summary: "Read the current telemetry report or its unavailable reason.",
        modelCalls: [],
        correlationPolicy: .notAccepted,
        agentEligibility: .notYetAllowed,
        makeDescriptor: { entryName, entrySummary, _, entryEligibility, inputs in
            let examples = inputs.examples
            return try IPCBuiltInDescriptorSupport.read(
                name: entryName,
                description: entrySummary,
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
                agentEligibility: entryEligibility
            )
        })

    static let bridgeTelemetryFlushEntry = IPCBuiltInMethodEntry<
        IPCBridgeTelemetryFlushParams, IPCBridgeTelemetryFlushResult
    >(
        name: "bridge.telemetry.flush", summary: "Flush buffered Bridge telemetry and return its settled report.",
        modelCalls: [],
        correlationPolicy: .required,
        agentEligibility: .notYetAllowed,
        makeDescriptor: { entryName, entrySummary, _, entryEligibility, inputs in
            let examples = inputs.examples
            return try IPCBuiltInDescriptorSupport.mutation(
                name: entryName,
                description: entrySummary,
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
                    agentEligibility: entryEligibility)
            )
        })

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

    init(representations: [String: any IPCMethodDescriptorRepresentation]) throws {
        review = try IPCBridgeReviewMethodDescriptors(representations: representations)
        control = try IPCBridgeControlMethodDescriptors(representations: representations)
        telemetry = try IPCBridgeTelemetryMethodDescriptors(representations: representations)
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
