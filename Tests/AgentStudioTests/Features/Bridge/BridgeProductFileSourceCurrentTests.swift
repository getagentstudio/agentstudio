import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudioBridge

@Suite("Bridge product current File source")
struct BridgeProductFileSourceCurrentTests {
    @Test("call contract requires an empty request and closed result variants")
    func callContractRequiresEmptyRequestAndClosedResultVariants() throws {
        // Arrange
        let cases = try productFileSourceCurrentCorpusCases()
        let availableCase = try #require(
            cases.first { $0["name"] as? String == "available" }
        )
        let unavailableCase = try #require(
            cases.first { $0["name"] as? String == "unavailable" }
        )
        let requestObject = try #require(availableCase["request"] as? [String: Any])
        let availableResultObject = try #require(availableCase["result"] as? [String: Any])
        let unavailableResultObject = try #require(unavailableCase["result"] as? [String: Any])

        // Act
        let request = try decodeProductFileSourceCurrent(
            BridgeProductCallRequest.self,
            object: requestObject
        )
        let availableResult = try decodeProductFileSourceCurrent(
            BridgeProductCallResult.self,
            object: availableResultObject
        )
        let unavailableResult = try decodeProductFileSourceCurrent(
            BridgeProductCallResult.self,
            object: unavailableResultObject
        )

        // Assert
        guard case .fileSourceCurrent = request,
            case .fileSourceCurrent(.available(let source)) = availableResult,
            case .fileSourceCurrent(.unavailable(let reason)) = unavailableResult
        else {
            Issue.record("Expected the closed file.source.current request and result variants")
            return
        }
        #expect(source.repoId == productFileSourceCurrentRepoId.uuidString)
        #expect(source.worktreeId == productFileSourceCurrentWorktreeId.uuidString)
        #expect(source.rootPathToken == "0123456789abcdef")
        #expect(reason == .noFileSourceAuthority)
        #expect(try productFileSourceCurrentCorpusMirrorsMatch())

        var requestWithUnknownMember = requestObject
        requestWithUnknownMember["request"] = ["source": productFileSourceCurrentSourceObject]
        #expect(
            decodeProductFileSourceCurrentIfPresent(
                BridgeProductCallRequest.self,
                object: requestWithUnknownMember
            ) == nil
        )
        var availableWithReason = availableResultObject
        var availablePayload = try #require(availableWithReason["result"] as? [String: Any])
        availablePayload["reason"] = "no-file-source-authority"
        availableWithReason["result"] = availablePayload
        #expect(
            decodeProductFileSourceCurrentIfPresent(
                BridgeProductCallResult.self,
                object: availableWithReason
            ) == nil
        )
        var unavailableWithSource = unavailableResultObject
        var unavailablePayload = try #require(unavailableWithSource["result"] as? [String: Any])
        unavailablePayload["source"] = productFileSourceCurrentSourceObject
        unavailableWithSource["result"] = unavailablePayload
        #expect(
            decodeProductFileSourceCurrentIfPresent(
                BridgeProductCallResult.self,
                object: unavailableWithSource
            ) == nil
        )
        var unavailableWithUnknownReason = unavailableResultObject
        var unknownReasonPayload = try #require(
            unavailableWithUnknownReason["result"] as? [String: Any]
        )
        unknownReasonPayload["reason"] = "authority-missing"
        unavailableWithUnknownReason["result"] = unknownReasonPayload
        #expect(
            decodeProductFileSourceCurrentIfPresent(
                BridgeProductCallResult.self,
                object: unavailableWithUnknownReason
            ) == nil
        )
    }

    @Test("provider derives available source from immutable authority without opening")
    func providerDerivesAvailableSourceFromAuthorityWithoutOpening() async throws {
        // Arrange
        let rootURL = FileManager.default.temporaryDirectory
            .appending(path: "bridge-product-current-source-\(UUIDv7.generate().uuidString)")
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let worktree = Worktree(
            id: productFileSourceCurrentWorktreeId,
            repoId: productFileSourceCurrentRepoId,
            name: "current-source",
            path: rootURL
        )
        let fileMetadataSource = BridgePaneProductFileMetadataSource(
            authority: .init(paneId: UUIDv7.generate(), worktree: worktree),
            gitReadContext: makeBridgeGitReadContext(rootURL: rootURL),
            constructionCoordinator: BridgeWorktreeProductConstructionCoordinator(),
            statusProvider: ProductFileSourceStatusProvider()
        )
        let refreshWorkAdmission = await BridgePaneRefreshWorkAdmissionTestContext.foreground()
        let provider = BridgePaneProductSchemeProvider(
            fileMetadataSource: fileMetadataSource,
            reviewMetadataSource: BridgeUnavailablePaneProductReviewMetadataSource(),
            reviewContentSource: BridgeUnavailablePaneProductReviewContentSource(),
            markReviewItemViewed: { _, _ in },
            refreshWorkAdmissionSource: refreshWorkAdmission.source
        )
        let request = try productFileSourceCurrentControlRequest()
        let productAdmission = try BridgeProductAdmissionTestContext.make()

        // Act
        let response = await provider.response(
            for: request,
            productAdmission: productAdmission.context
        )
        let emissionsAfterQuery = try await fileMetadataSource.publish(
            changeset: FileChangeset(
                worktreeId: worktree.id,
                repoId: worktree.repoId,
                rootPath: rootURL,
                paths: ["File.swift"],
                timestamp: .now,
                batchSeq: 1
            ),
            productAdmission: productAdmission.context,
            foregroundWorkAdmission: refreshWorkAdmission.admission
        )

        // Assert
        guard case .callCompleted(let completed) = response,
            case .fileSourceCurrent(.available(let source)) = completed.call
        else {
            Issue.record("Expected an available current File source")
            return
        }
        #expect(source.cwdScope == nil)
        #expect(source.includeStatuses)
        #expect(source.repoId == worktree.repoId.uuidString)
        #expect(source.worktreeId == worktree.id.uuidString)
        #expect(source.rootPathToken == StableKey.fromPath(rootURL))
        #expect(emissionsAfterQuery.isEmpty)
    }

    @Test("provider returns typed unavailable when File authority is absent")
    func providerReturnsTypedUnavailableWithoutAuthority() async throws {
        // Arrange
        let refreshWorkAdmission = await BridgePaneRefreshWorkAdmissionTestContext.foreground()
        let provider = BridgePaneProductSchemeProvider(
            fileMetadataSource: BridgeUnavailablePaneProductFileMetadataSource(),
            reviewMetadataSource: BridgeUnavailablePaneProductReviewMetadataSource(),
            reviewContentSource: BridgeUnavailablePaneProductReviewContentSource(),
            markReviewItemViewed: { _, _ in },
            refreshWorkAdmissionSource: refreshWorkAdmission.source
        )
        let productAdmission = try BridgeProductAdmissionTestContext.make()

        // Act
        let response = await provider.response(
            for: try productFileSourceCurrentControlRequest(),
            productAdmission: productAdmission.context
        )

        // Assert
        guard case .callCompleted(let completed) = response,
            case .fileSourceCurrent(.unavailable(let reason)) = completed.call
        else {
            Issue.record("Expected a typed unavailable current File source")
            return
        }
        #expect(reason == .noFileSourceAuthority)
    }
}

private let productFileSourceCurrentRepoId = UUID(
    uuidString: "00000000-0000-4000-8000-000000000001"
)!
private let productFileSourceCurrentWorktreeId = UUID(
    uuidString: "00000000-0000-4000-8000-000000000002"
)!

private var productFileSourceCurrentSourceObject: [String: Any] {
    [
        "cwdScope": NSNull(),
        "freshness": "live",
        "includeStatuses": true,
        "repoId": productFileSourceCurrentRepoId.uuidString,
        "rootPathToken": "0123456789abcdef",
        "worktreeId": productFileSourceCurrentWorktreeId.uuidString,
    ]
}

private func productFileSourceCurrentCorpusCases() throws -> [[String: Any]] {
    let projectRoot = URL(fileURLWithPath: TestPathResolver.projectRoot(from: #filePath))
    let data = try Data(
        contentsOf: projectRoot.appending(
            path: "Tests/BridgeContractFixtures/valid/bridge-product-session-corpus.json"
        )
    )
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    return try #require(object["fileSourceCurrentCases"] as? [[String: Any]])
}

private func productFileSourceCurrentCorpusMirrorsMatch() throws -> Bool {
    let projectRoot = URL(fileURLWithPath: TestPathResolver.projectRoot(from: #filePath))
    let swiftCorpus = try Data(
        contentsOf: projectRoot.appending(
            path: "Tests/BridgeContractFixtures/valid/bridge-product-session-corpus.json"
        )
    )
    let bridgeWebCorpus = try Data(
        contentsOf: projectRoot.appending(
            path:
                "BridgeWeb/src/test-fixtures/bridge-contract-fixtures/valid/bridge-product-session-corpus.json"
        )
    )
    return swiftCorpus == bridgeWebCorpus
}

private func productFileSourceCurrentControlRequest() throws -> BridgeProductControlRequest {
    try decodeProductFileSourceCurrent(
        BridgeProductControlRequest.self,
        object: [
            "call": [
                "method": "file.source.current",
                "request": [:],
            ],
            "kind": "product.call",
            "paneSessionId": "pane-session-1",
            "requestId": "file-source-current-1",
            "requestSequence": 2,
            "wireVersion": BridgeProductWireContract.version,
            "workerDerivationEpoch": 1,
            "workerInstanceId": "worker-instance-1",
        ]
    )
}

private func decodeProductFileSourceCurrent<DecodedValue: Decodable>(
    _: DecodedValue.Type,
    object: [String: Any]
) throws -> DecodedValue {
    try BridgeProductStrictJSON.decode(
        DecodedValue.self,
        from: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    )
}

private func decodeProductFileSourceCurrentIfPresent<DecodedValue: Decodable>(
    _: DecodedValue.Type,
    object: [String: Any]
) -> DecodedValue? {
    try? decodeProductFileSourceCurrent(DecodedValue.self, object: object)
}
