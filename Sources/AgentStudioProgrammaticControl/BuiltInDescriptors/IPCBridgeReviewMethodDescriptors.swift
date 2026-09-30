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
        let example = inputs.examples
        bridgeDiffLoad = try IPCBuiltInDescriptorSupport.mutation(
            name: "bridge.diff.load",
            description: "Open a Bridge review for one explicit worktree.",
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
                agentEligibility: .notYetAllowed)
        )
        bridgeFileViewOpen = try IPCBuiltInDescriptorSupport.mutation(
            name: "bridge.fileView.open",
            description: "Open a Bridge file viewer for one explicit worktree.",
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
                agentEligibility: .notYetAllowed)
        )
        bridgeDiffRefresh = try IPCBuiltInDescriptorSupport.mutation(
            name: "bridge.diff.refresh",
            description: "Refresh the review package in one Bridge pane.",
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
                agentEligibility: .notYetAllowed)
        )
        bridgeDiffGetPackage = try IPCBuiltInDescriptorSupport.read(
            name: "bridge.diff.getPackage",
            description: "Read the current review package from one Bridge pane.",
            parameters: IPCBridgePaneParams(handle: "self"),
            result: Self.reviewPackage(example: example),
            privilege: .bridgeRead,
            dataScope: .bridgeReviewPackage,
            targetKinds: [.pane],
            owner: .bridgeCapability,
            errors: Self.bridgeErrors,
            agentEligibility: .notYetAllowed
        )
        bridgeDiffRenderState = try IPCBuiltInDescriptorSupport.read(
            name: "bridge.diff.renderState",
            description: "Read rendered Bridge state and diagnostics from one pane.",
            parameters: IPCBridgePaneParams(handle: "self"),
            result: Self.renderState(example: example),
            privilege: .bridgeRead,
            dataScope: .bridgeReviewPackage,
            targetKinds: [.pane],
            owner: .bridgeCapability,
            errors: Self.bridgeErrors,
            agentEligibility: .notYetAllowed
        )
        bridgeDiffSelectFile = try Self.makeSelectDescriptor(example: example)
    }

    private static func makeSelectDescriptor(
        example: IPCBuiltInMethodExampleContext
    ) throws -> IPCMethodDescriptor<IPCBridgeReviewSelectFileParams, IPCBridgeReviewSelectFileResult> {
        try IPCBuiltInDescriptorSupport.mutation(
            name: "bridge.diff.selectFile",
            description: "Select one review item in a Bridge pane.",
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
                agentEligibility: .notYetAllowed)
        )
    }

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
