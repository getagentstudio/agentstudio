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
        bridgeDiffScrollToFile = try Self.bridgeDiffScrollToFileEntry.makeDescriptor(
            inputs: IPCBuiltInMethodCatalogInputs(examples: examples))
        bridgeDiffExpandFile = try Self.bridgeDiffExpandFileEntry.makeDescriptor(
            inputs: IPCBuiltInMethodCatalogInputs(examples: examples))
        bridgeDiffCollapseFile = try Self.bridgeDiffCollapseFileEntry.makeDescriptor(
            inputs: IPCBuiltInMethodCatalogInputs(examples: examples))
        bridgeFileTreeSearch = try Self.bridgeFileTreeSearchEntry.makeDescriptor(
            inputs: IPCBuiltInMethodCatalogInputs(examples: examples))
        bridgeFileTreeSetFilter = try Self.bridgeFileTreeSetFilterEntry.makeDescriptor(
            inputs: IPCBuiltInMethodCatalogInputs(examples: examples))
        bridgeFileTreeRevealPath = try Self.bridgeFileTreeRevealPathEntry.makeDescriptor(
            inputs: IPCBuiltInMethodCatalogInputs(examples: examples))
        bridgeFileViewGetContent = try Self.bridgeFileViewGetContentEntry.makeDescriptor(
            inputs: IPCBuiltInMethodCatalogInputs(examples: examples))
        bridgeFileViewShowMarkdownPreview = try Self.bridgeFileViewShowMarkdownPreviewEntry.makeDescriptor(
            inputs: IPCBuiltInMethodCatalogInputs(examples: examples))
    }

    init(representations: [String: any IPCMethodDescriptorRepresentation]) throws {
        bridgeDiffScrollToFile = try Self.bridgeDiffScrollToFileEntry.typedDescriptor(in: representations)
        bridgeDiffExpandFile = try Self.bridgeDiffExpandFileEntry.typedDescriptor(in: representations)
        bridgeDiffCollapseFile = try Self.bridgeDiffCollapseFileEntry.typedDescriptor(in: representations)
        bridgeFileTreeSearch = try Self.bridgeFileTreeSearchEntry.typedDescriptor(in: representations)
        bridgeFileTreeSetFilter = try Self.bridgeFileTreeSetFilterEntry.typedDescriptor(in: representations)
        bridgeFileTreeRevealPath = try Self.bridgeFileTreeRevealPathEntry.typedDescriptor(in: representations)
        bridgeFileViewGetContent = try Self.bridgeFileViewGetContentEntry.typedDescriptor(in: representations)
        bridgeFileViewShowMarkdownPreview = try Self.bridgeFileViewShowMarkdownPreviewEntry.typedDescriptor(
            in: representations)
    }

    static let bridgeDiffScrollToFileEntry = IPCBuiltInMethodEntry<
        IPCBridgeDiffScrollToFileParams, IPCBridgePageControlResult
    >(
        name: "bridge.diff.scrollToFile", summary: "Scroll one Bridge review item into view.",
        modelCalls: [],
        correlationPolicy: .required,
        agentEligibility: .notYetAllowed,
        makeDescriptor: { entryName, entrySummary, _, entryEligibility, inputs in
            let examples = inputs.examples
            let itemId = "Sources/App.swift"
            return try Self.pageControl(
                name: entryName,
                description: entrySummary,
                agentEligibility: entryEligibility,
                parameters: IPCBridgeDiffScrollToFileParams(
                    handle: "self", itemId: itemId, correlationId: examples.correlationId),
                example: examples,
                itemId: itemId
            )
        })

    static let bridgeDiffExpandFileEntry = IPCBuiltInMethodEntry<
        IPCBridgeDiffExpandFileParams, IPCBridgePageControlResult
    >(
        name: "bridge.diff.expandFile", summary: "Expand one Bridge review item.",
        modelCalls: [],
        correlationPolicy: .required,
        agentEligibility: .notYetAllowed,
        makeDescriptor: { entryName, entrySummary, _, entryEligibility, inputs in
            let examples = inputs.examples
            let itemId = "Sources/App.swift"
            return try Self.pageControl(
                name: entryName,
                description: entrySummary,
                agentEligibility: entryEligibility,
                parameters: IPCBridgeDiffExpandFileParams(
                    handle: "self", itemId: itemId, correlationId: examples.correlationId),
                example: examples,
                itemId: itemId
            )
        })

    static let bridgeDiffCollapseFileEntry = IPCBuiltInMethodEntry<
        IPCBridgeDiffCollapseFileParams, IPCBridgePageControlResult
    >(
        name: "bridge.diff.collapseFile", summary: "Collapse one Bridge review item.",
        modelCalls: [],
        correlationPolicy: .required,
        agentEligibility: .notYetAllowed,
        makeDescriptor: { entryName, entrySummary, _, entryEligibility, inputs in
            let examples = inputs.examples
            let itemId = "Sources/App.swift"
            return try Self.pageControl(
                name: entryName,
                description: entrySummary,
                agentEligibility: entryEligibility,
                parameters: IPCBridgeDiffCollapseFileParams(
                    handle: "self", itemId: itemId, correlationId: examples.correlationId),
                example: examples,
                itemId: itemId
            )
        })

    static let bridgeFileTreeSearchEntry = IPCBuiltInMethodEntry<
        IPCBridgeFileTreeSearchParams, IPCBridgePageControlResult
    >(
        name: "bridge.fileTree.search", summary: "Set exact text or regular-expression search on one Bridge file tree.",
        modelCalls: [],
        correlationPolicy: .required,
        agentEligibility: .notYetAllowed,
        makeDescriptor: { entryName, entrySummary, _, entryEligibility, inputs in
            let examples = inputs.examples
            return try Self.pageControl(
                name: entryName,
                description: entrySummary,
                agentEligibility: entryEligibility,
                parameters: IPCBridgeFileTreeSearchParams(
                    handle: "self",
                    searchText: "App",
                    correlationId: examples.correlationId
                ),
                example: examples
            )
        })

    static let bridgeFileTreeSetFilterEntry = IPCBuiltInMethodEntry<
        IPCBridgeFileTreeSetFilterParams, IPCBridgePageControlResult
    >(
        name: "bridge.fileTree.setFilter", summary: "Replace the complete filter for one Bridge file-tree surface.",
        modelCalls: [],
        correlationPolicy: .required,
        agentEligibility: .notYetAllowed,
        makeDescriptor: { entryName, entrySummary, _, entryEligibility, inputs in
            let examples = inputs.examples
            return try Self.pageControl(
                name: entryName,
                description: entrySummary,
                agentEligibility: entryEligibility,
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
        })

    static let bridgeFileTreeRevealPathEntry = IPCBuiltInMethodEntry<
        IPCBridgeFileTreeRevealPathParams, IPCBridgePageControlResult
    >(
        name: "bridge.fileTree.revealPath", summary: "Reveal one explicit path in a Bridge file tree.",
        modelCalls: [],
        correlationPolicy: .required,
        agentEligibility: .notYetAllowed,
        makeDescriptor: { entryName, entrySummary, _, entryEligibility, inputs in
            let examples = inputs.examples
            return try Self.pageControl(
                name: entryName,
                description: entrySummary,
                agentEligibility: entryEligibility,
                parameters: IPCBridgeFileTreeRevealPathParams(
                    handle: "self",
                    path: "Sources/App.swift",
                    correlationId: examples.correlationId
                ),
                example: examples,
                path: "Sources/App.swift"
            )
        })

    static let bridgeFileViewGetContentEntry = IPCBuiltInMethodEntry<
        IPCBridgeContentGetParams, IPCBridgeContentGetResult
    >(
        name: "bridge.fileView.getContent", summary: "Read content metadata for a handle in one Bridge pane.",
        modelCalls: [],
        correlationPolicy: .notAccepted,
        agentEligibility: .notYetAllowed,
        makeDescriptor: { entryName, entrySummary, _, entryEligibility, inputs in
            let examples = inputs.examples
            let itemId = "Sources/App.swift"
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
                name: entryName,
                description: entrySummary,
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
                agentEligibility: entryEligibility
            )
        })

    static let bridgeFileViewShowMarkdownPreviewEntry = IPCBuiltInMethodEntry<
        IPCBridgeFileViewShowMarkdownPreviewParams, IPCBridgePageControlResult
    >(
        name: "bridge.fileView.showMarkdownPreview", summary: "Show Markdown preview for an explicit or selected item.",
        modelCalls: [],
        correlationPolicy: .required,
        agentEligibility: .notYetAllowed,
        makeDescriptor: { entryName, entrySummary, _, entryEligibility, inputs in
            let examples = inputs.examples
            let itemId = "Sources/App.swift"
            return try Self.pageControl(
                name: entryName,
                description: entrySummary,
                agentEligibility: entryEligibility,
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
        })

    private static let bridgeErrors = [
        IPCBuiltInDescriptorSupport.invalidParams,
        IPCBuiltInDescriptorSupport.targetNotFound,
        IPCBuiltInDescriptorSupport.unavailable,
    ]

    private static func pageControl<Parameters: IPCSchemaProviding>(
        name: String,
        description: String,
        agentEligibility: IPCAgentEligibility?,
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
                agentEligibility: agentEligibility)
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
