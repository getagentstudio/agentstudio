import Foundation

package struct IPCBridgeReviewMethodDescriptors: Sendable {
    package let bridgeDiffLoad: IPCMethodDescriptor<IPCBridgeReviewOpenParams, IPCBridgeReviewOpenResult>
    package let bridgeFileViewOpen: IPCMethodDescriptor<IPCBridgeFileViewOpenParams, IPCBridgeFileViewOpenResult>
    package let bridgeDiffRefresh: IPCMethodDescriptor<IPCBridgeReviewRefreshParams, IPCBridgeReviewRefreshResult>
    package let bridgeDiffGetPackage: IPCMethodDescriptor<IPCBridgePaneParams, IPCBridgeReviewPackageResult>
    package let bridgeDiffRenderState: IPCMethodDescriptor<IPCBridgePaneParams, IPCBridgeRenderStateResult>
    package let bridgeDiffSelectFile:
        IPCMethodDescriptor<IPCBridgeReviewSelectFileParams, IPCBridgeReviewSelectFileResult>

    init(inputs: IPCBuiltInMethodCatalogInputs) throws {
        bridgeDiffLoad = try Self.bridgeDiffLoadEntry.makeDescriptor(inputs: inputs)
        bridgeFileViewOpen = try Self.bridgeFileViewOpenEntry.makeDescriptor(inputs: inputs)
        bridgeDiffRefresh = try Self.bridgeDiffRefreshEntry.makeDescriptor(inputs: inputs)
        bridgeDiffGetPackage = try Self.bridgeDiffGetPackageEntry.makeDescriptor(inputs: inputs)
        bridgeDiffRenderState = try Self.bridgeDiffRenderStateEntry.makeDescriptor(inputs: inputs)
        bridgeDiffSelectFile = try Self.bridgeDiffSelectFileEntry.makeDescriptor(inputs: inputs)
    }

    init(representations: [String: any IPCMethodDescriptorRepresentation]) throws {
        bridgeDiffLoad = try Self.bridgeDiffLoadEntry.typedDescriptor(in: representations)
        bridgeFileViewOpen = try Self.bridgeFileViewOpenEntry.typedDescriptor(in: representations)
        bridgeDiffRefresh = try Self.bridgeDiffRefreshEntry.typedDescriptor(in: representations)
        bridgeDiffGetPackage = try Self.bridgeDiffGetPackageEntry.typedDescriptor(in: representations)
        bridgeDiffRenderState = try Self.bridgeDiffRenderStateEntry.typedDescriptor(in: representations)
        bridgeDiffSelectFile = try Self.bridgeDiffSelectFileEntry.typedDescriptor(in: representations)
    }

    static let bridgeDiffLoadEntry = IPCBuiltInMethodEntry<IPCBridgeReviewOpenParams, IPCBridgeReviewOpenResult>(
        name: "bridge.diff.load", summary: "Open a Bridge review for one explicit worktree.",
        modelCalls: [],
        correlationPolicy: .required,
        agentEligibility: .notYetAllowed,
        makeDescriptor: { entryName, entrySummary, _, entryEligibility, inputs in
            let example = inputs.examples
            return try IPCBuiltInDescriptorSupport.mutation(
                name: entryName,
                description: entrySummary,
                parameters: IPCBridgeReviewOpenParams(
                    correlationId: example.correlationId,
                    worktreeId: example.worktreeId
                ),
                result: IPCBridgeReviewOpenResult(
                    paneId: example.paneId,
                    handle: "pane:\(example.paneId.uuidString)",
                    correlationId: example.correlationId
                ),
                metadata: .init(
                    privilege: .layoutMutate,
                    dataScope: .paneContext,
                    targetKinds: [],
                    relationship: inputs.relationships.bridgeDiffLoad,
                    owner: .bridgeCapability,
                    errors: Self.bridgeErrors,
                    agentEligibility: entryEligibility)
            )
        })

    static let bridgeFileViewOpenEntry = IPCBuiltInMethodEntry<
        IPCBridgeFileViewOpenParams, IPCBridgeFileViewOpenResult
    >(
        name: "bridge.fileView.open", summary: "Open a Bridge file viewer for one explicit worktree.",
        modelCalls: [],
        correlationPolicy: .required,
        agentEligibility: .notYetAllowed,
        makeDescriptor: { entryName, entrySummary, _, entryEligibility, inputs in
            let example = inputs.examples
            return try IPCBuiltInDescriptorSupport.mutation(
                name: entryName,
                description: entrySummary,
                parameters: IPCBridgeFileViewOpenParams(
                    correlationId: example.correlationId,
                    worktreeId: example.worktreeId
                ),
                result: IPCBridgeFileViewOpenResult(
                    paneId: example.paneId,
                    handle: "pane:\(example.paneId.uuidString)",
                    correlationId: example.correlationId
                ),
                metadata: .init(
                    privilege: .layoutMutate,
                    dataScope: .paneContext,
                    targetKinds: [],
                    relationship: inputs.relationships.bridgeFileViewOpen,
                    owner: .bridgeCapability,
                    errors: Self.bridgeErrors,
                    agentEligibility: entryEligibility)
            )
        })

    static let bridgeDiffRefreshEntry = IPCBuiltInMethodEntry<
        IPCBridgeReviewRefreshParams, IPCBridgeReviewRefreshResult
    >(
        name: "bridge.diff.refresh", summary: "Refresh the review package in one Bridge pane.",
        modelCalls: [],
        correlationPolicy: .required,
        agentEligibility: .notYetAllowed,
        makeDescriptor: { entryName, entrySummary, _, entryEligibility, inputs in
            let example = inputs.examples
            return try IPCBuiltInDescriptorSupport.mutation(
                name: entryName,
                description: entrySummary,
                parameters: IPCBridgeReviewRefreshParams(
                    handle: "self",
                    correlationId: example.correlationId
                ),
                result: IPCBridgeReviewRefreshResult(
                    paneId: example.paneId,
                    refreshed: true,
                    status: "ready",
                    packageId: "example-package",
                    reviewGeneration: 1,
                    correlationId: example.correlationId
                ),
                metadata: .init(
                    privilege: .bridgeControl,
                    dataScope: .bridgeReviewPackage,
                    targetKinds: [.pane],
                    owner: .bridgeCapability,
                    errors: Self.bridgeErrors,
                    agentEligibility: entryEligibility)
            )
        })

    static let bridgeDiffGetPackageEntry = IPCBuiltInMethodEntry<IPCBridgePaneParams, IPCBridgeReviewPackageResult>(
        name: "bridge.diff.getPackage", summary: "Read the current review package from one Bridge pane.",
        modelCalls: [],
        correlationPolicy: .notAccepted,
        agentEligibility: .notYetAllowed,
        makeDescriptor: { entryName, entrySummary, _, entryEligibility, inputs in
            let example = inputs.examples
            return try IPCBuiltInDescriptorSupport.read(
                name: entryName,
                description: entrySummary,
                parameters: IPCBridgePaneParams(handle: "self"),
                result: Self.reviewPackage(example: example),
                privilege: .bridgeRead,
                dataScope: .bridgeReviewPackage,
                targetKinds: [.pane],
                owner: .bridgeCapability,
                errors: Self.bridgeErrors,
                agentEligibility: entryEligibility
            )
        })

    static let bridgeDiffRenderStateEntry = IPCBuiltInMethodEntry<IPCBridgePaneParams, IPCBridgeRenderStateResult>(
        name: "bridge.diff.renderState", summary: "Read rendered Bridge state and diagnostics from one pane.",
        modelCalls: [],
        correlationPolicy: .notAccepted,
        agentEligibility: .notYetAllowed,
        makeDescriptor: { entryName, entrySummary, _, entryEligibility, inputs in
            let example = inputs.examples
            return try IPCBuiltInDescriptorSupport.read(
                name: entryName,
                description: entrySummary,
                parameters: IPCBridgePaneParams(handle: "self"),
                result: Self.renderState(example: example),
                privilege: .bridgeRead,
                dataScope: .bridgeReviewPackage,
                targetKinds: [.pane],
                owner: .bridgeCapability,
                errors: Self.bridgeErrors,
                agentEligibility: entryEligibility
            )
        })

    static let bridgeDiffSelectFileEntry = IPCBuiltInMethodEntry<
        IPCBridgeReviewSelectFileParams, IPCBridgeReviewSelectFileResult
    >(
        name: "bridge.diff.selectFile", summary: "Select one review item in a Bridge pane.",
        modelCalls: [],
        correlationPolicy: .required,
        agentEligibility: .notYetAllowed,
        makeDescriptor: { entryName, entrySummary, _, entryEligibility, inputs in
            let example = inputs.examples
            return try IPCBuiltInDescriptorSupport.mutation(
                name: entryName,
                description: entrySummary,
                parameters: IPCBridgeReviewSelectFileParams(
                    handle: "self",
                    itemId: "Sources/App.swift",
                    correlationId: example.correlationId
                ),
                result: IPCBridgeReviewSelectFileResult(
                    paneId: example.paneId,
                    itemId: "Sources/App.swift",
                    selected: true,
                    correlationId: example.correlationId
                ),
                metadata: .init(
                    privilege: .bridgeControl,
                    dataScope: .bridgeReviewPackage,
                    targetKinds: [.pane],
                    owner: .bridgeCapability,
                    errors: Self.bridgeErrors,
                    agentEligibility: entryEligibility)
            )
        })

    private static let bridgeErrors = [
        IPCBuiltInDescriptorSupport.invalidParams,
        IPCBuiltInDescriptorSupport.targetNotFound,
        IPCBuiltInDescriptorSupport.unavailable,
    ]

    private static func reviewPackage(
        example: IPCBuiltInMethodExampleContext
    ) -> IPCBridgeReviewPackageResult {
        IPCBridgeReviewPackageResult(
            paneId: example.paneId,
            status: "ready",
            selectedItemId: "Sources/App.swift",
            packageId: "example-package",
            reviewGeneration: 1,
            revision: 1,
            summary: IPCBridgeReviewPackageSummary(
                filesChanged: 1,
                additions: 2,
                deletions: 1,
                visibleFileCount: 1,
                hiddenFileCount: 0
            ),
            reviewedSubjectLabel: "Example changes",
            items: [
                IPCBridgeReviewItemSummary(
                    itemId: "Sources/App.swift",
                    displayPath: "Sources/App.swift",
                    itemKind: "text",
                    changeKind: "modified",
                    collapsed: false
                )
            ]
        )
    }

    private static func renderState(
        example: IPCBuiltInMethodExampleContext
    ) -> IPCBridgeRenderStateResult {
        let productSession = IPCBridgeProductSessionDiagnostic(
            activeProducerCount: 0,
            activeProducerTaskCount: 0,
            activeContentLeaseCount: 0,
            queuedFrameCount: 0,
            queuedByteCount: 0,
            pendingFrameWaiterCount: 0,
            inFlightFrameReceiptCount: 0,
            pendingLifecycleAcknowledgementCount: 0,
            nextMetadataStreamSequence: 1
        )
        return IPCBridgeRenderStateResult(
            paneId: example.paneId,
            summary: IPCBridgeRenderSummary(
                pageTitle: "Review",
                hasAppRoot: true,
                hasEmptyShell: false,
                hasReviewShell: true,
                sidebarPosition: "left"
            ),
            diagnostics: IPCBridgeRenderDiagnostics(
                evaluateSucceeded: true,
                pageErrorCount: 0,
                pageErrorKinds: [],
                pageErrorMessages: [],
                nativeActivity: .foreground,
                foregroundWorkEpoch: 1,
                dirtyFactPresent: false,
                activeRefreshPassPresent: false,
                refreshPassCount: 1,
                productSession: productSession
            )
        )
    }

    var descriptorRepresentations: [any IPCMethodDescriptorRepresentation] {
        get throws {
            let representations: [any IPCMethodDescriptorRepresentation] = try [
                IPCMethodDescriptorRepresentations(typedDescriptor: bridgeDiffLoad),
                IPCMethodDescriptorRepresentations(typedDescriptor: bridgeFileViewOpen),
                IPCMethodDescriptorRepresentations(typedDescriptor: bridgeDiffRefresh),
                IPCMethodDescriptorRepresentations(typedDescriptor: bridgeDiffGetPackage),
                IPCMethodDescriptorRepresentations(typedDescriptor: bridgeDiffRenderState),
                IPCMethodDescriptorRepresentations(typedDescriptor: bridgeDiffSelectFile),
            ]
            return representations
        }
    }

    var erased: [IPCAnyMethodDescriptor] {
        get throws { try descriptorRepresentations.map(\.erasedDescriptor) }
    }
}
