import Foundation

package struct IPCBridgeControlMethodDescriptors: Sendable {
    package let bridgeDiffScrollToFile: IPCMethodDescriptor<IPCBridgeDiffScrollToFileParams, IPCBridgePageControlResult>
    package let bridgeDiffExpandFile: IPCMethodDescriptor<IPCBridgeDiffExpandFileParams, IPCBridgePageControlResult>
    package let bridgeDiffCollapseFile: IPCMethodDescriptor<IPCBridgeDiffCollapseFileParams, IPCBridgePageControlResult>
    package let bridgeFileTreeSearch: IPCMethodDescriptor<IPCBridgeFileTreeSearchParams, IPCBridgePageControlResult>
    package let bridgeFileTreeSetFilter:
        IPCMethodDescriptor<IPCBridgeFileTreeSetFilterParams, IPCBridgePageControlResult>
    package let bridgeFileTreeRevealPath:
        IPCMethodDescriptor<IPCBridgeFileTreeRevealPathParams, IPCBridgePageControlResult>
    package let bridgeFileViewGetContent: IPCMethodDescriptor<IPCBridgeContentGetParams, IPCBridgeContentGetResult>
    package let bridgeFileViewShowMarkdownPreview:
        IPCMethodDescriptor<IPCBridgeFileViewShowMarkdownPreviewParams, IPCBridgePageControlResult>

    init(examples: IPCBuiltInMethodExampleContext) throws {
        let itemId = "Sources/App.swift"
        bridgeDiffScrollToFile = try Self.pageControl(
            name: "bridge.diff.scrollToFile",
            description: "Scroll one Bridge review item into view.",
            parameters: IPCBridgeDiffScrollToFileParams(
                handle: "self", itemId: itemId, correlationId: examples.correlationId),
            example: examples,
            itemId: itemId
        )
        bridgeDiffExpandFile = try Self.pageControl(
            name: "bridge.diff.expandFile",
            description: "Expand one Bridge review item.",
            parameters: IPCBridgeDiffExpandFileParams(
                handle: "self", itemId: itemId, correlationId: examples.correlationId),
            example: examples,
            itemId: itemId
        )
        bridgeDiffCollapseFile = try Self.pageControl(
            name: "bridge.diff.collapseFile",
            description: "Collapse one Bridge review item.",
            parameters: IPCBridgeDiffCollapseFileParams(
                handle: "self", itemId: itemId, correlationId: examples.correlationId),
            example: examples,
            itemId: itemId
        )
        bridgeFileTreeSearch = try Self.pageControl(
            name: "bridge.fileTree.search",
            description: "Set exact text or regular-expression search on one Bridge file tree.",
            parameters: IPCBridgeFileTreeSearchParams(
                handle: "self",
                searchText: "App",
                correlationId: examples.correlationId
            ),
            example: examples
        )
        bridgeFileTreeSetFilter = try Self.pageControl(
            name: "bridge.fileTree.setFilter",
            description: "Replace the complete filter for one Bridge file-tree surface.",
            parameters: IPCBridgeFileTreeSetFilterParams(
                handle: "self",
                candidate: .review(
                    gitStatusFilter: .modified,
                    categoryFilter: .source,
                    showBinary: false,
                    showLarge: false
                ),
                correlationId: examples.correlationId
            ),
            example: examples
        )
        bridgeFileTreeRevealPath = try Self.pageControl(
            name: "bridge.fileTree.revealPath",
            description: "Reveal one explicit path in a Bridge file tree.",
            parameters: IPCBridgeFileTreeRevealPathParams(
                handle: "self",
                path: "Sources/App.swift",
                correlationId: examples.correlationId
            ),
            example: examples,
            path: "Sources/App.swift"
        )
        bridgeFileViewGetContent = try Self.makeContentDescriptor(
            itemId: itemId,
            examples: examples
        )
        bridgeFileViewShowMarkdownPreview = try Self.pageControl(
            name: "bridge.fileView.showMarkdownPreview",
            description: "Show Markdown preview for an explicit or selected item.",
            parameters: IPCBridgeFileViewShowMarkdownPreviewParams(
                handle: "self",
                itemId: itemId,
                correlationId: examples.correlationId
            ),
            example: examples,
            itemId: itemId,
            status: "rejected",
            reason: "unsupported_surface"
        )
    }

    private static func makeContentDescriptor(
        itemId: String,
        examples: IPCBuiltInMethodExampleContext
    ) throws -> IPCMethodDescriptor<IPCBridgeContentGetParams, IPCBridgeContentGetResult> {
        let contentHandle = IPCBridgeContentHandleSummary(
            identity: IPCBridgeContentHandleIdentity(
                handleId: "example-content",
                itemId: itemId,
                role: "workingTree",
                reviewGeneration: 1
            ),
            presentation: IPCBridgeContentHandlePresentation(
                mimeType: "text/plain",
                language: "swift"
            ),
            size: IPCBridgeContentHandleSize(sizeBytes: 12, isBinary: false)
        )
        return try IPCBuiltInDescriptorSupport.read(
            name: "bridge.fileView.getContent",
            description: "Read content metadata for a handle in one Bridge pane.",
            parameters: IPCBridgeContentGetParams(
                handle: "self",
                contentHandleId: contentHandle.handleId,
                reviewGeneration: contentHandle.reviewGeneration
            ),
            result: IPCBridgeContentGetResult(
                paneId: examples.paneId,
                handle: contentHandle,
                mimeType: contentHandle.mimeType
            ),
            privilege: .bridgeContentRead,
            dataScope: .bridgeContent,
            targetKinds: [.pane],
            owner: .bridgeCapability,
            errors: Self.bridgeErrors,
            agentEligibility: .notYetAllowed
        )
    }

    private static let bridgeErrors = [
        IPCBuiltInDescriptorSupport.invalidParams,
        IPCBuiltInDescriptorSupport.targetNotFound,
        IPCBuiltInDescriptorSupport.unavailable,
    ]

    private static func pageControl<Parameters: IPCSchemaProviding>(
        name: String,
        description: String,
        parameters: Parameters,
        example: IPCBuiltInMethodExampleContext,
        itemId: String? = nil,
        path: String? = nil,
        renderMode: String = "codeView",
        status: String = "accepted",
        reason: String? = nil
    ) throws -> IPCMethodDescriptor<Parameters, IPCBridgePageControlResult> {
        try IPCBuiltInDescriptorSupport.mutation(
            name: name,
            description: description,
            parameters: parameters,
            result: IPCBridgePageControlResult(
                paneId: example.paneId,
                method: name,
                status: status,
                itemId: itemId,
                path: path,
                treeSearchText: name == "bridge.fileTree.search" ? "App" : "",
                filterSurface: .review,
                gitStatusFilter: .modified,
                categoryFilter: .source,
                showBinary: false,
                showLarge: false,
                renderMode: renderMode,
                reason: reason,
                correlationId: example.correlationId
            ),
            metadata: .init(
                privilege: .bridgeControl,
                dataScope: .bridgeReviewPackage,
                targetKinds: [.pane],
                owner: .bridgeCapability,
                semantics: .accepted,
                errors: Self.bridgeErrors,
                agentEligibility: .notYetAllowed)
        )
    }

    var descriptorRepresentations: [any IPCMethodDescriptorRepresentation] {
        get throws {
            let representations: [any IPCMethodDescriptorRepresentation] = try [
                IPCMethodDescriptorRepresentations(typedDescriptor: bridgeDiffScrollToFile),
                IPCMethodDescriptorRepresentations(typedDescriptor: bridgeDiffExpandFile),
                IPCMethodDescriptorRepresentations(typedDescriptor: bridgeDiffCollapseFile),
                IPCMethodDescriptorRepresentations(typedDescriptor: bridgeFileTreeSearch),
                IPCMethodDescriptorRepresentations(typedDescriptor: bridgeFileTreeSetFilter),
                IPCMethodDescriptorRepresentations(typedDescriptor: bridgeFileTreeRevealPath),
                IPCMethodDescriptorRepresentations(typedDescriptor: bridgeFileViewGetContent),
                IPCMethodDescriptorRepresentations(typedDescriptor: bridgeFileViewShowMarkdownPreview),
            ]
            return representations
        }
    }

    var erased: [IPCAnyMethodDescriptor] {
        get throws { try descriptorRepresentations.map(\.erasedDescriptor) }
    }
}
