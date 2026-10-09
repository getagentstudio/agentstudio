import AgentStudioCore
import Foundation

@testable import AgentStudioBridge

struct ProductFileSourceStatusProvider: GitWorkingTreeStatusProvider {
    func statusResult(
        for _: URL,
        pathspecs _: [String]?
    ) async -> GitWorkingTreeStatusResult {
        .available(
            GitWorkingTreeStatus(
                summary: .init(changed: 1, staged: 2, untracked: 3),
                branch: "main",
                origin: nil
            )
        )
    }
}

enum ProductFileSourceFixtureError: Error {
    case invalidContentRequest
    case invalidControlRequest
    case invalidDemandedIndex
    case missingSubscription
}

struct ProductFileSourceFixture {
    let demandedFileURL: URL
    let demandedPath: String
    let paneId = UUID(uuidString: "00000000-0000-4000-8000-000000000003")!
    let productAdmission: BridgeProductAdmissionTestContext
    let repoId = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    let rootURL: URL
    let worktreeId = UUID(uuidString: "00000000-0000-4000-8000-000000000002")!

    init(
        fileCount: Int,
        demandedLineCount: Int = 2,
        demandedIndex: Int = 0,
        productAdmission suppliedProductAdmission: BridgeProductAdmissionTestContext? = nil
    ) throws {
        guard fileCount == 0 || (0..<fileCount).contains(demandedIndex) else {
            throw ProductFileSourceFixtureError.invalidDemandedIndex
        }
        productAdmission = try suppliedProductAdmission ?? BridgeProductAdmissionTestContext.make()
        rootURL = FileManager.default.temporaryDirectory
            .appending(path: "bridge-product-file-source-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        demandedPath = String(format: "File-%04d.swift", demandedIndex)
        demandedFileURL = rootURL.appending(path: demandedPath)
        for index in 0..<fileCount {
            let fileURL = rootURL.appending(path: String(format: "File-%04d.swift", index))
            let contents =
                index == demandedIndex
                ? String(repeating: "line\n", count: demandedLineCount)
                : "let value = \(index)\n"
            try Data(contents.utf8).write(to: fileURL)
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: rootURL)
    }

    func makeSource(
        paneId: UUID? = nil,
        constructionCoordinator: BridgeWorktreeProductConstructionCoordinator? = nil,
        revisionFloorCapture: @escaping @Sendable (BridgeWorktreeFileManifestIndex) async -> Int =
            BridgePaneProductFileMetadataSource.captureRevisionFloor,
        sourceAcceptedObserver: @escaping @Sendable (BridgeProductFileSourceIdentity) async -> Void = { _ in },
        snapshotPreparationLoader: BridgePaneProductFileSnapshotPreparationLoader? = nil,
        sharedSnapshotBuilder: @escaping BridgePaneProductFileSharedSnapshotBuilder =
            BridgeWorktreeFileMaterializer.buildSharedSnapshot,
        ignorePolicyLoader: @escaping BridgePaneProductFileIgnorePolicyLoader = loadTestBridgeFileIgnorePolicy,
        treeRowRefresher: BridgePaneProductFileTreeRowRefresher? = nil,
        descriptorMaterializer: @escaping BridgePaneProductFileDescriptorMaterializer =
            BridgePaneProductFileContentSource.materialize
    ) -> BridgePaneProductFileMetadataSource {
        BridgePaneProductFileMetadataSource(
            authority: .init(
                paneId: paneId ?? self.paneId,
                worktree: Worktree(
                    id: worktreeId,
                    repoId: repoId,
                    name: "fixture",
                    path: rootURL
                )
            ),
            gitReadContext: makeBridgeGitReadContext(rootURL: rootURL),
            constructionCoordinator: constructionCoordinator ?? BridgeWorktreeProductConstructionCoordinator(),
            sourceAcceptedObserver: sourceAcceptedObserver,
            statusProvider: ProductFileSourceStatusProvider(),
            revisionFloorCapture: revisionFloorCapture,
            snapshotPreparationLoader: snapshotPreparationLoader,
            sharedSnapshotBuilder: sharedSnapshotBuilder,
            ignorePolicyLoader: ignorePolicyLoader,
            treeRowRefresher: treeRowRefresher,
            descriptorMaterializer: descriptorMaterializer
        )
    }

    func openSnapshot(
        cwdScope: String? = nil,
        subscriptionId: String = "file-subscription-1"
    ) throws -> BridgeProductSubscriptionSnapshot {
        let cwdScopeValue: Any
        if let cwdScope {
            cwdScopeValue = cwdScope
        } else {
            cwdScopeValue = NSNull()
        }
        let request = try controlRequest(
            kind: "subscription.open",
            requestSequence: 2,
            values: [
                "subscription": [
                    "source": [
                        "cwdScope": cwdScopeValue,
                        "freshness": "live",
                        "includeStatuses": true,
                        "repoId": repoId.uuidString,
                        "rootPathToken": StableKey.fromPath(rootURL),
                        "worktreeId": worktreeId.uuidString,
                    ],
                    "subscriptionKind": "file.metadata",
                ],
                "subscriptionId": subscriptionId,
            ]
        )
        guard case .subscriptionOpen(let openRequest) = request else {
            throw ProductFileSourceFixtureError.invalidControlRequest
        }
        var state = BridgeProductSubscriptionState()
        _ = try state.open(openRequest)
        return try requiredSnapshot(from: state, subscriptionId: subscriptionId)
    }

    func viewDemand(
        foregroundPaths: [String]? = nil,
        visiblePaths: [String] = [],
        pathScope: [String] = [],
        scopeRevision: Int = 1,
        admissionSequence: Int? = nil,
        handle: String = "file-view-handle-1"
    ) throws -> BridgePaneProductFileViewDemand {
        let selectedPaths = foregroundPaths ?? [demandedPath]
        var interests: [BridgeProductFileMetadataInterestStateGroup] = []
        if !selectedPaths.isEmpty {
            interests.append(try .init(lane: .foreground, paths: selectedPaths))
        }
        if !visiblePaths.isEmpty {
            interests.append(try .init(lane: .visible, paths: visiblePaths))
        }
        return BridgePaneProductFileViewDemand(
            admissionSequence: admissionSequence ?? scopeRevision,
            handle: handle,
            scopeRevision: scopeRevision,
            state: .init(interests: interests, pathScope: pathScope)
        )
    }

    func contentRequest(
        descriptor: BridgeProductFileContentDescriptor
    ) throws -> BridgeProductFileContentRequest {
        let descriptorObject = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(descriptor)
        )
        let data = try JSONSerialization.data(
            withJSONObject: [
                "contentKind": "file.content",
                "contentRequestId": "file-content-request-1",
                "descriptor": descriptorObject,
                "kind": "content.open",
                "leaseId": "file-content-lease-1",
                "operationCorrelationId": NSNull(),
                "paneSessionId": "pane-session-1",
                "wireVersion": BridgeProductWireContract.version,
                "workerDerivationEpoch": 1,
                "workerInstanceId": "worker-instance-1",
            ],
            options: [.sortedKeys]
        )
        let request = try BridgeProductStrictJSON.decode(BridgeProductContentRequest.self, from: data)
        guard case .fileContent(let fileRequest) = request else {
            throw ProductFileSourceFixtureError.invalidContentRequest
        }
        return fileRequest
    }

    private func requiredSnapshot(
        from state: BridgeProductSubscriptionState,
        subscriptionId: String
    ) throws -> BridgeProductSubscriptionSnapshot {
        guard let snapshot = state.snapshot(subscriptionId: subscriptionId) else {
            throw ProductFileSourceFixtureError.missingSubscription
        }
        return snapshot
    }

    private func controlRequest(
        kind: String,
        requestSequence: Int,
        values: [String: Any]
    ) throws -> BridgeProductControlRequest {
        let object: [String: Any] = [
            "kind": kind,
            "paneSessionId": "pane-session-1",
            "requestId": "request-\(requestSequence)",
            "requestSequence": requestSequence,
            "wireVersion": BridgeProductWireContract.version,
            "workerDerivationEpoch": 1,
            "workerInstanceId": "worker-instance-1",
        ].merging(values) { _, new in new }
        return try BridgeProductStrictJSON.decode(
            BridgeProductControlRequest.self,
            from: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        )
    }
}

func sealProductFileSourceCapture(
    _ capture: BridgeWorktreeFileKeyedSnapshot,
    demand: BridgePaneProductFileViewDemand
) throws -> BridgeProductSealedViewBatch {
    let encodedDemand = try JSONEncoder().encode(demand.state)
    guard case .object(var scope) = try JSONDecoder().decode(BridgeProductJSONValue.self, from: encodedDemand)
    else { throw ProductFileSourceFixtureError.invalidControlRequest }
    scope["kind"] = .string("file")
    scope["changeFilter"] = .object(["kind": .string("none")])
    return try BridgeProductFileViewBatchFactory.sealSnapshot(
        .init(
            viewDomain: .init(viewId: "file-subscription-1", domain: .singleDomain, incarnation: "file-incarnation"),
            handle: demand.handle, scopeRevision: demand.scopeRevision, scope: .object(scope),
            firstDeliverySequence: 1, snapshot: capture))
}

func productFileBatchDescriptorCount(_ batch: BridgeProductSealedViewBatch) -> Int {
    batch.parts.filter { part in
        guard case .put(_, _, let value) = part,
            case .object(let fields) = value,
            let descriptor = fields["readDescriptor"]
        else { return false }
        return descriptor != .null
    }.count
}
