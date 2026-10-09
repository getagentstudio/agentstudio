import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudioBridge

@Suite("Bridge product bootstrap hard-cut contract")
struct BridgeProductBootstrapHardCutContractTests {
    @Test("content-world bootstrap cannot carry ordinary File or Review product frames")
    func contentWorldBootstrapCannotCarryProductFrames() {
        // Arrange
        let script = BridgeBootstrap.generateScript()
        let forbiddenProductCarrierMarkers = [
            "applyIntakeFrameJSON",
            "agentstudio.bridge.hostIntakeFrameJSON",
            "__bridge_intake_json",
            "__bridge_intake_replay_request",
        ]

        // Act
        let retainedProductCarrierMarkers = forbiddenProductCarrierMarkers.filter(script.contains)

        // Assert
        #expect(
            retainedProductCarrierMarkers.isEmpty,
            "Ordinary File and Review product data must arrive only through the pane comm-worker product streams"
        )
    }

    @Test("current worktree and File Review File events use the authenticated product session")
    func currentWorktreeAndViewerEventsUseProductSession() async throws {
        // Arrange
        let repoId = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
        let worktreeId = UUID(uuidString: "00000000-0000-4000-8000-000000000002")!
        let rootURL = FileManager.default.temporaryDirectory
            .appending(path: "bridge-product-startup-contract-\(UUIDv7.generate().uuidString)")
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let worktree = Worktree(
            id: worktreeId,
            repoId: repoId,
            name: "startup-contract",
            path: rootURL
        )
        let activeModeRecorder = BridgeProductStartupActiveModeRecorder()
        let refreshWorkAdmission = await BridgePaneRefreshWorkAdmissionTestContext.foreground()
        let provider = BridgePaneProductSchemeProvider(
            fileMetadataSource: BridgePaneProductFileMetadataSource(
                authority: .init(paneId: UUIDv7.generate(), worktree: worktree),
                gitReadContext: makeBridgeGitReadContext(rootURL: worktree.path),
                constructionCoordinator: BridgeWorktreeProductConstructionCoordinator(),
                statusProvider: ProductFileSourceStatusProvider()
            ),
            reviewMetadataSource: BridgeUnavailablePaneProductReviewMetadataSource(),
            reviewContentSource: BridgeUnavailablePaneProductReviewContentSource(),
            markReviewItemViewed: { _, _ in },
            applyActiveViewerModeUpdate: { call, _, productAdmission in
                await activeModeRecorder.record(
                    call.method,
                    productAdmission: productAdmission
                )
            },
            refreshWorkAdmissionSource: refreshWorkAdmission.source
        )
        let productAdmissionGate = BridgeProductAdmissionGate()
        let operationClock = TestPushClock()
        let installation = try BridgeProductSessionInstallation.make(
            paneSessionId: "pane-startup-contract",
            provider: provider,
            productAdmissionGate: productAdmissionGate,
            deadlineClock: operationClock
        )
        let capabilityHeader = try BridgeProductCapabilityHeaderEncoding.encode(
            installation.capabilityBytes
        )

        // Act
        let openResponse = try await bridgeProductStartupCommand(
            installation: installation,
            capabilityHeader: capabilityHeader,
            body: bridgeProductStartupWorkerOpenBody(installation: installation)
        )
        let currentSourceResponse = try await bridgeProductStartupCommand(
            installation: installation,
            capabilityHeader: capabilityHeader,
            body: bridgeProductStartupCurrentSourceBody(
                installation: installation,
                requestSequence: 2
            )
        )
        let modeMethods = [
            "file.activeViewerMode.update",
            "review.activeViewerMode.update",
            "file.activeViewerMode.update",
        ]
        var modeResponses: [BridgeProductControlResponse] = []
        for (index, method) in modeMethods.enumerated() {
            modeResponses.append(
                try await bridgeProductStartupCommand(
                    installation: installation,
                    capabilityHeader: capabilityHeader,
                    body: bridgeProductStartupActiveModeBody(
                        installation: installation,
                        method: method,
                        requestSequence: index + 3,
                        sequence: index + 1
                    )
                )
            )
        }
        let bootstrapScript = BridgeBootstrap.generateScript()

        // Assert
        guard case .workerSessionAccepted = openResponse,
            case .callCompleted(let currentSourceCall) = currentSourceResponse,
            case .fileSourceCurrent(.available(let currentSource)) = currentSourceCall.call
        else {
            Issue.record("Expected authenticated startup and current File source responses")
            return
        }
        #expect(currentSource.repoId == repoId.uuidString)
        #expect(currentSource.worktreeId == worktreeId.uuidString)
        #expect(currentSource.rootPathToken == worktree.stableKey)
        #expect(modeResponses.compactMap(bridgeProductStartupCompletedMethod) == modeMethods)
        #expect(await activeModeRecorder.methods == modeMethods)
        #expect(
            !bootstrapScript.contains("applyIntakeFrameJSON"),
            "The working product session must replace the legacy content-world product carrier"
        )
    }
}

private actor BridgeProductStartupActiveModeRecorder {
    private(set) var methods: [String] = []

    func record(
        _ method: String,
        productAdmission: BridgeProductAdmissionContext
    ) {
        _ = productAdmission.withValidAdmission {
            methods.append(method)
        }
    }
}

private func bridgeProductStartupCommand(
    installation: BridgeProductSessionInstallation,
    capabilityHeader: String,
    body: Data
) async throws -> BridgeProductControlResponse {
    let observation = try await collectBridgeProductSchemeReply(
        adapter: installation.productAdapter,
        request: bridgeProductSchemeRequest(
            route: BridgeProductWireContract.commandRoute,
            capability: capabilityHeader,
            body: body
        )
    )
    #expect(observation.response?.statusCode == 200)
    let admission = try BridgeProductStrictJSON.decode(
        BridgeProductOperationAdmittedResponse.self,
        from: observation.body
    )
    let resultRequestBody = try JSONSerialization.data(
        withJSONObject: [
            "kind": "operation.result",
            "operationId": admission.operationId,
            "paneSessionId": admission.correlation.paneSessionId,
            "wireVersion": BridgeProductWireContract.version,
            "workerInstanceId": admission.correlation.workerInstanceId,
        ]
    )
    let resultReply = try await collectBridgeProductSchemeReply(
        adapter: installation.productAdapter,
        request: bridgeProductSchemeRequest(
            route: BridgeProductWireContract.commandRoute,
            capability: capabilityHeader,
            body: resultRequestBody
        )
    )
    #expect(resultReply.response?.statusCode == 200)
    let result = try BridgeProductStrictJSON.decode(
        BridgeProductOperationResultResponse.self,
        from: resultReply.body
    )
    #expect(result.operationId == admission.operationId)
    #expect(result.outcome == .succeeded, Comment(rawValue: admission.correlation.requestId))
    return try BridgeProductStrictJSON.decode(
        BridgeProductControlResponse.self,
        from: JSONEncoder().encode(try #require(result.result))
    )
}

private func bridgeProductStartupWorkerOpenBody(
    installation: BridgeProductSessionInstallation
) throws -> Data {
    try bridgeProductStartupBody([
        "kind": "workerSession.open",
        "paneSessionId": installation.bootstrap.paneSessionId,
        "request": NSNull(),
        "requestId": "startup-open",
        "requestSequence": 1,
        "wireVersion": installation.bootstrap.wireVersion,
        "workerInstanceId": installation.bootstrap.workerInstanceId,
    ])
}

private func bridgeProductStartupCurrentSourceBody(
    installation: BridgeProductSessionInstallation,
    requestSequence: Int
) throws -> Data {
    try bridgeProductStartupBody([
        "call": [
            "method": "file.source.current",
            "request": [:],
        ],
        "kind": "product.call",
        "paneSessionId": installation.bootstrap.paneSessionId,
        "requestId": "startup-current-source",
        "requestSequence": requestSequence,
        "wireVersion": installation.bootstrap.wireVersion,
        "workerDerivationEpoch": 0,
        "workerInstanceId": installation.bootstrap.workerInstanceId,
    ])
}

private func bridgeProductStartupActiveModeBody(
    installation: BridgeProductSessionInstallation,
    method: String,
    requestSequence: Int,
    sequence: Int
) throws -> Data {
    let streamId = method.hasPrefix("file.") ? "file-stream" : "review-stream"
    return try bridgeProductStartupBody([
        "call": [
            "method": method,
            "request": [
                "activeSource": [
                    "generation": 1,
                    "streamId": streamId,
                ],
                "nativeSelectionRequestId": NSNull(),
                "sequence": sequence,
                "sessionId": "viewer-session",
            ],
        ],
        "kind": "product.call",
        "paneSessionId": installation.bootstrap.paneSessionId,
        "requestId": "startup-mode-\(requestSequence)",
        "requestSequence": requestSequence,
        "wireVersion": installation.bootstrap.wireVersion,
        "workerDerivationEpoch": 0,
        "workerInstanceId": installation.bootstrap.workerInstanceId,
    ])
}

private func bridgeProductStartupBody(_ object: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}

private func bridgeProductStartupCompletedMethod(
    _ response: BridgeProductControlResponse
) -> String? {
    guard case .callCompleted(let completed) = response else { return nil }
    return completed.call.method
}
