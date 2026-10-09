import AgentStudioTestSupport
import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import Synchronization
import Testing
import WebKit

@testable import AgentStudioBridge
@testable import AgentStudioBridgeDevelopmentServer
@testable import AgentStudioCore

@Suite("Bridge development HTTP routing")
struct BridgeDevelopmentHTTPRoutingTests {
    @MainActor
    @Test("core composition seeds an absent exact pane once and restores its symbolic target")
    func coreCompositionRestoresExactPaneWithoutReseeding() async throws {
        // Arrange
        let paneID = PaneId.generateUUIDv7().uuid
        let fixtureRoot = FileManager.default.temporaryDirectory.appending(
            path: "bridge-development-core-composition-\(paneID.uuidString)",
            directoryHint: .isDirectory
        )
        let dataRoot = fixtureRoot.appending(path: "data", directoryHint: .isDirectory)
        let worktreeRoot = fixtureRoot.appending(path: "repository", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }
        try FileManager.default.createDirectory(at: worktreeRoot, withIntermediateDirectories: true)
        let firstConfiguration = try BridgeDevelopmentServerConfiguration(
            dataRoot: dataRoot,
            paneID: paneID,
            port: 43_871,
            seedContributionTarget: .ref(name: "refs/heads/original-base"),
            seedWorktreeRoot: worktreeRoot
        )

        // Act
        let firstComposition = try await BridgeDevelopmentServerCoreComposition.prepare(
            configuration: firstConfiguration
        )
        let firstSource = firstComposition.productSource
        try await firstComposition.shutdown()
        let secondConfiguration = try BridgeDevelopmentServerConfiguration(
            dataRoot: dataRoot,
            paneID: paneID,
            port: 43_872,
            seedContributionTarget: .ref(name: "refs/heads/must-not-reseed"),
            seedWorktreeRoot: worktreeRoot
        )
        let secondComposition = try await BridgeDevelopmentServerCoreComposition.prepare(
            configuration: secondConfiguration
        )
        let restoredSource = secondComposition.productSource
        try await secondComposition.shutdown()

        // Assert
        #expect(firstSource.paneID == paneID)
        #expect(restoredSource.paneID == paneID)
        #expect(firstSource.repoID == restoredSource.repoID)
        #expect(firstSource.worktreeID == restoredSource.worktreeID)
        #expect(restoredSource.worktreeRoot == worktreeRoot.standardizedFileURL)
        #expect(
            restoredSource.paneState.source
                == .workspace(
                    rootPath: worktreeRoot.standardizedFileURL.path,
                    baseline: .ref(name: "refs/heads/original-base")
                )
        )
    }

    @Test("server configuration is fixed to IPv4 loopback")
    func serverConfigurationUsesLoopback() throws {
        // Arrange
        let paneID = try #require(UUID(uuidString: "019fe721-7d8b-7ca0-b5c7-89e5fd7463f3"))

        // Act
        let configuration = try BridgeDevelopmentServerConfiguration(
            dataRoot: URL(fileURLWithPath: "/tmp/bridge-development-data"),
            paneID: paneID,
            port: 43_871,
            seedContributionTarget: .ref(name: "refs/heads/review-base"),
            seedWorktreeRoot: URL(fileURLWithPath: "/tmp/repository")
        )

        // Assert
        #expect(configuration.applicationConfiguration.address == .hostname("127.0.0.1", port: 43_871))
        #expect(configuration.dataRoot.path == "/tmp/bridge-development-data")
        #expect(configuration.paneID == paneID)
        #expect(configuration.seedContributionTarget == .ref(name: "refs/heads/review-base"))
        #expect(configuration.seedWorktreeRoot.path == "/tmp/repository")
    }

    @Test("health route reports readiness without a response body")
    func healthRouteReportsReadiness() async throws {
        // Arrange
        let repositoryURL = try await FilesystemTestGitRepo.create(
            named: "bridge-development-http-health"
        )
        defer { FilesystemTestGitRepo.destroy(repositoryURL) }
        try await FilesystemTestGitRepo.seedTrackedAndUntrackedChanges(at: repositoryURL)
        let host = try await makeHTTPDevelopmentProductHost(worktreeRoot: repositoryURL)
        try await withDevelopmentHost(host) {
            // Act / Assert
            try await withBridgeDevelopmentHTTPRouterTestClient(host: host) { client in
                try await client.execute(
                    uri: "/__bridge-product/health",
                    method: .get
                ) { response in
                    #expect(response.status == .noContent)
                    #expect(response.body.readableBytes == 0)
                }
            }
        }
    }

    @Test("a live server announces one readiness line naming its bound port once it is listening")
    func liveServerAnnouncesReadinessAfterBinding() async throws {
        // Arrange
        let repositoryURL = try await FilesystemTestGitRepo.create(
            named: "bridge-development-http-readiness-announcement"
        )
        defer { FilesystemTestGitRepo.destroy(repositoryURL) }
        try await FilesystemTestGitRepo.seedTrackedAndUntrackedChanges(at: repositoryURL)
        let host = try await makeHTTPDevelopmentProductHost(worktreeRoot: repositoryURL)
        let announcedLines = Mutex<[String?]>([])
        try await withDevelopmentHost(host) {
            let application = BridgeDevelopmentHTTPApplication.make(
                host: host,
                onServerRunning: { channel in
                    let line = BridgeDevelopmentServerReadinessAnnouncement.line(
                        boundTo: channel,
                        processIdentifier: 4242
                    )
                    announcedLines.withLock { $0.append(line) }
                }
            )

            // Act — the live framework hands the client its port only after onServerRunning.
            try await application.test(.live) { client in
                let port = try #require(client.port)

                // Assert
                #expect(
                    announcedLines.withLock { $0 } == [
                        "bridge-development-server ready port=\(port) pid=4242\n"
                    ]
                )
            }
        }
    }

    @Test("health route reports unavailable after runtime readiness is lost")
    func healthRouteReportsUnavailable() async throws {
        // Arrange
        let repositoryURL = try await FilesystemTestGitRepo.create(
            named: "bridge-development-http-unavailable"
        )
        defer { FilesystemTestGitRepo.destroy(repositoryURL) }
        try await FilesystemTestGitRepo.seedTrackedAndUntrackedChanges(at: repositoryURL)
        let host = try await makeHTTPDevelopmentProductHost(worktreeRoot: repositoryURL)
        try await withDevelopmentHost(host) {
            // Act / Assert
            try await withBridgeDevelopmentHTTPRouterTestClient(
                host: host,
                healthIsReady: { false },
                test: { client in
                    try await client.execute(
                        uri: "/__bridge-product/health",
                        method: .get
                    ) { response in
                        #expect(response.status == .serviceUnavailable)
                        #expect(response.body.readableBytes == 0)
                    }
                })
        }
    }

    @Test("bootstrap route returns the existing binary session envelope")
    func bootstrapRouteReturnsSessionEnvelope() async throws {
        // Arrange
        let repositoryURL = try await FilesystemTestGitRepo.create(
            named: "bridge-development-http-bootstrap"
        )
        defer { FilesystemTestGitRepo.destroy(repositoryURL) }
        try await FilesystemTestGitRepo.seedTrackedAndUntrackedChanges(at: repositoryURL)
        let host = try await makeHTTPDevelopmentProductHost(worktreeRoot: repositoryURL)
        try await withDevelopmentHost(host) {
            let body = ByteBuffer(
                string:
                    #"{"navigationIntent":{"commandId":"open-file-view","commandKind":"activateContext","surface":"file"},"reason":"initial","tabId":"owner-tab-1"}"#
            )

            // Act / Assert
            try await withBridgeDevelopmentHTTPRouterTestClient(host: host) { client in
                try await client.execute(
                    uri: "/__bridge-product/bootstrap",
                    method: .post,
                    headers: [.contentType: "application/json"],
                    body: body
                ) { response in
                    #expect(response.status == .ok)
                    #expect(response.headers[.contentType] == "application/octet-stream")
                    #expect(response.body.readableBytes > 37)
                    #expect(response.body.getInteger(at: 0, as: UInt8.self) == 1)
                }
            }
        }
    }

    @Test("a second page cannot replace a session with an open metadata stream")
    func secondPageCannotReplaceOpenMetadataStream() async throws {
        // Arrange
        let repositoryURL = try await FilesystemTestGitRepo.create(named: "bridge-http-occupied-session")
        defer { FilesystemTestGitRepo.destroy(repositoryURL) }
        try await FilesystemTestGitRepo.seedTrackedAndUntrackedChanges(at: repositoryURL)
        let host = try await makeHTTPDevelopmentProductHost(worktreeRoot: repositoryURL)
        try await withDevelopmentHost(host) {
            try await withBridgeDevelopmentHTTPRouterTestClient(host: host) { client in
                let connection = try await openHTTPProductConnection(client: client)
                let metadata = try await startHTTPMetadataStream(
                    host: host, connection: connection, streamID: "occupied-session-stream"
                )
                do {
                    _ = try await waitForAcknowledgedMetadataFrame(
                        client: client, connection: connection, recorder: metadata.recorder
                    ) { frame -> Bool? in
                        if case .metadataStreamAccepted = frame { return true }
                        return nil
                    }
                    // Act
                    let response = try await client.execute(
                        uri: "/__bridge-product/bootstrap", method: .post,
                        headers: [.contentType: "application/json"],
                        body: ByteBuffer(
                            string:
                                #"{"navigationIntent":{"commandId":"second-page","commandKind":"activateContext","surface":"file"},"reason":"initial","tabId":"other-tab-2"}"#
                        )
                    )
                    // Assert: no new capability is issued; the original session still serves calls.
                    #expect(response.status == .conflict)
                    _ = try await queryHTTPFileSource(client: client, connection: connection, requestSequence: 2)
                } catch {
                    try await shutdownHTTPHostAndDrainMetadataStream(host: host, drain: metadata.drain)
                    throw error
                }
                try await shutdownHTTPHostAndDrainMetadataStream(host: host, drain: metadata.drain)
            }
        }
    }

    @Test("a competing tab bootstrap receives HTTP 409 before the owner opens its stream")
    func competingTabBootstrapReturnsConflict() async throws {
        let repositoryURL = try await FilesystemTestGitRepo.create(
            named: "bridge-http-competing-tab-before-stream"
        )
        defer { FilesystemTestGitRepo.destroy(repositoryURL) }
        let host = try await makeHTTPDevelopmentProductHost(worktreeRoot: repositoryURL)
        try await withDevelopmentHost(host) {
            try await withBridgeDevelopmentHTTPRouterTestClient(host: host) { client in
                let first = try await client.execute(
                    uri: "/__bridge-product/bootstrap",
                    method: .post,
                    headers: [.contentType: "application/json"],
                    body: ByteBuffer(
                        string:
                            #"{"navigationIntent":{"commandId":"open-file-view","commandKind":"activateContext","surface":"file"},"reason":"initial","tabId":"owner-tab-1"}"#
                    )
                )
                #expect(first.status == .ok)
                let competing = try await client.execute(
                    uri: "/__bridge-product/bootstrap",
                    method: .post,
                    headers: [.contentType: "application/json"],
                    body: ByteBuffer(
                        string:
                            #"{"navigationIntent":{"commandId":"open-file-view","commandKind":"activateContext","surface":"file"},"reason":"initial","tabId":"other-tab-2"}"#
                    )
                )
                #expect(competing.status == .conflict)
            }
        }
    }

    @MainActor
    @Test("first Review bootstrap does not create eager shared content files")
    func firstReviewBootstrapDoesNotCreateEagerSharedContentFiles() async throws {
        // Arrange
        let repositoryURL = try await FilesystemTestGitRepo.create(
            named: "bridge-development-http-review-bootstrap"
        )
        defer { FilesystemTestGitRepo.destroy(repositoryURL) }
        try await FilesystemTestGitRepo.seedTrackedAndUntrackedChanges(at: repositoryURL)
        let dataRoot = FileManager.default.temporaryDirectory.appending(
            path: "bridge-development-http-review-data-\(PaneId.generateUUIDv7().uuid.uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: dataRoot) }
        let harness = try await makeHTTPDevelopmentServerHarness(
            dataRoot: dataRoot,
            worktreeRoot: repositoryURL
        )

        // Act / Assert
        try await withDevelopmentServerHarness(harness) {
            try await withBridgeDevelopmentHTTPRouterTestClient(host: harness.host) { client in
                try await client.execute(
                    uri: "/__bridge-product/bootstrap",
                    method: .post,
                    headers: [.contentType: "application/json"],
                    body: ByteBuffer(
                        string:
                            #"{"navigationIntent":{"commandId":"dev:worktree:review","commandKind":"activateContext","surface":"review"},"reason":"initial","tabId":"owner-tab-1"}"#
                    )
                ) { response in
                    #expect(response.status == .ok)
                    _ = try decodeHTTPBootstrapEnvelope(
                        Data(response.body.readableBytesView)
                    )
                }
            }

            let sharedContentRoot = dataRoot.appending(path: "bridge-review-content")
            #expect(!FileManager.default.fileExists(atPath: sharedContentRoot.path))
        }
    }

    @Test("a cold File target publishes activation before File source discovery")
    func coldFileTargetPublishesActivationBeforeSourceDiscovery() async throws {
        // Arrange
        let repositoryURL = try await FilesystemTestGitRepo.create(named: "bridge-http-file-target-startup")
        defer { FilesystemTestGitRepo.destroy(repositoryURL) }
        try await FilesystemTestGitRepo.seedTrackedAndUntrackedChanges(at: repositoryURL)
        let host = try await makeHTTPDevelopmentProductHost(worktreeRoot: repositoryURL)
        try await withDevelopmentHost(host) {
            try await withBridgeDevelopmentHTTPRouterTestClient(host: host) { client in
                let connection = try await openHTTPProductConnection(
                    client: client,
                    bootstrapRequestBody: ByteBuffer(
                        string:
                            #"{"navigationIntent":{"commandId":"open-cold-file-target","commandKind":"activateTarget","surface":"file","target":{"targetKind":"file","path":"startup.txt","version":"current"}},"reason":"initial","tabId":"owner-tab-1"}"#
                    )
                )
                let metadata = try await startHTTPMetadataStream(
                    host: host,
                    connection: connection,
                    streamID: "cold-file-target-metadata"
                )
                do {
                    // Act — open only the carrier, with no File discovery or Review publication.
                    _ = try await waitForAcknowledgedMetadataFrame(
                        client: client,
                        connection: connection,
                        recorder: metadata.recorder
                    ) { frame -> Bool? in
                        if case .metadataStreamAccepted = frame { return true }
                        return nil
                    }
                    let coordinator = await host.productProvider.metadataCoordinator
                    await coordinator.replayPaneSurfaceSelectionRequest()
                    let observationBoundary = BridgePaneSurfaceSelectionRequest(
                        navigationCommand: .activateContext(
                            commandId: "startup-observation-boundary",
                            bindingRevision: 100,
                            surface: .review
                        ),
                        paneSessionId: connection.bootstrap.paneSessionId,
                        workerInstanceId: connection.bootstrap.workerInstanceId
                    )
                    #expect(
                        await coordinator.publishPaneSurfaceSelectionRequest(
                            observationBoundary,
                            productAdmission: host.productAdmission,
                            streamAbsenceDisposition: .reject
                        )
                    )
                    let firstSelection = try await waitForAcknowledgedMetadataFrame(
                        client: client,
                        connection: connection,
                        recorder: metadata.recorder
                    ) { frame -> BridgeProductNavigationCommand? in
                        guard case .paneSurfaceSelectionRequested(let selection) = frame else { return nil }
                        return selection.navigationCommand
                    }

                    // Assert — the initial File context precedes the boundary without a source-bound target.
                    guard case .activateContext(let commandID, let bindingRevision, let surface) = firstSelection else {
                        throw HTTPAnnotationIntegrationError.unexpectedControlResponse(
                            callSite: "initialFileSelection",
                            receivedKind: String(reflecting: firstSelection)
                        )
                    }
                    #expect(surface == .file)
                    #expect(bindingRevision == 1)
                    #expect(commandID != "open-cold-file-target")
                    #expect(await host.diagnosticCommittedReviewPublication() == nil)
                } catch {
                    try await shutdownHTTPHostAndDrainMetadataStream(host: host, drain: metadata.drain)
                    throw error
                }
                try await shutdownHTTPHostAndDrainMetadataStream(host: host, drain: metadata.drain)
            }
        }
    }

    @Test(
        "command route honors the advertised product body budget",
        arguments: ["normal", "at_limit", "over_limit"]
    )
    func commandRouteForwardsWorkerAdmission(bodySize: String) async throws {
        // Arrange
        let repositoryURL = try await FilesystemTestGitRepo.create(
            named: "bridge-development-http-command"
        )
        defer { FilesystemTestGitRepo.destroy(repositoryURL) }
        try await FilesystemTestGitRepo.seedTrackedAndUntrackedChanges(at: repositoryURL)
        let host = try await makeHTTPDevelopmentProductHost(worktreeRoot: repositoryURL)
        try await withDevelopmentHost(host) {
            // Act / Assert
            try await withBridgeDevelopmentHTTPRouterTestClient(host: host) { client in
                let bootstrapResponse = try await client.execute(
                    uri: "/__bridge-product/bootstrap",
                    method: .post,
                    headers: [.contentType: "application/json"],
                    body: ByteBuffer(
                        string:
                            #"{"navigationIntent":{"commandId":"open-file-view","commandKind":"activateContext","surface":"file"},"reason":"initial","tabId":"owner-tab-1"}"#
                    )
                )
                let envelope = try decodeHTTPBootstrapEnvelope(
                    Data(bootstrapResponse.body.readableBytesView)
                )
                let capability = try BridgeProductCapabilityHeaderEncoding.encode(
                    Array(envelope.capabilityBytes)
                )
                var requestBody = try JSONSerialization.data(
                    withJSONObject: [
                        "kind": "workerSession.open",
                        "paneSessionId": envelope.bootstrap.paneSessionId,
                        "request": NSNull(),
                        "requestId": "request-open-development-http",
                        "requestSequence": 1,
                        "wireVersion": BridgeProductWireContract.version,
                        "workerInstanceId": envelope.bootstrap.workerInstanceId,
                    ],
                    options: [.sortedKeys]
                )
                if bodySize != "normal" {
                    let targetSize =
                        envelope.bootstrap.policy.maximumRequestBodyBytes + (bodySize == "over_limit" ? 1 : 0)
                    try #require(targetSize >= requestBody.count)
                    requestBody.append(Data(repeating: 0x20, count: targetSize - requestBody.count))
                }
                let capabilityHeader = try #require(
                    HTTPField.Name(BridgeProductWireContract.capabilityHeaderName)
                )
                try await client.execute(
                    uri: "/__bridge-product/command",
                    method: .post,
                    headers: [
                        .contentType: "application/json",
                        capabilityHeader: capability,
                    ],
                    body: ByteBuffer(data: requestBody)
                ) { response in
                    if bodySize == "over_limit" {
                        #expect(response.status == .contentTooLarge)
                        return
                    }
                    #expect(response.status == .ok)
                    #expect(response.headers[.contentType] == "application/json")
                    let admission = try BridgeProductStrictJSON.decode(
                        BridgeProductOperationAdmittedResponse.self,
                        from: Data(response.body.readableBytesView)
                    )
                    #expect(admission.correlation.paneSessionId == envelope.bootstrap.paneSessionId)
                    #expect(admission.correlation.workerInstanceId == envelope.bootstrap.workerInstanceId)
                }
            }
        }
    }

    @Test("product requests forward only protocol-required headers")
    func productRequestsForwardOnlyProtocolHeaders() throws {
        // Arrange
        let capabilityHeader = try #require(
            HTTPField.Name(BridgeProductWireContract.capabilityHeaderName)
        )
        let hostHeader = try #require(HTTPField.Name("Host"))
        let destinationURL = try #require(URL(string: BridgeProductWireContract.commandRoute))
        let headers: HTTPFields = [
            .contentType: "application/json; charset=utf-8",
            capabilityHeader: "capability-value",
            .cookie: "private-session=value",
            hostHeader: "127.0.0.1:43123",
            .connection: "keep-alive",
            .transferEncoding: "chunked",
        ]

        // Act
        let request = BridgeDevelopmentHTTPApplication.forwardedProductRequest(
            destinationURL: destinationURL,
            body: Data("{}".utf8),
            headers: headers
        )

        // Assert
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json; charset=utf-8")
        #expect(
            request.value(forHTTPHeaderField: BridgeProductWireContract.capabilityHeaderName)
                == "capability-value"
        )
        #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(request.value(forHTTPHeaderField: "Host") == nil)
        #expect(request.value(forHTTPHeaderField: "Connection") == nil)
        #expect(request.value(forHTTPHeaderField: "Transfer-Encoding") == nil)
    }

    @Test("product response preserves every ordered body chunk beyond the former buffer bound")
    func productResponsePreservesEveryOrderedBodyChunk() async throws {
        // Arrange
        let chunkCount = 80
        let responseURL = try #require(URL(string: BridgeProductWireContract.contentRoute))
        let responseHead = try #require(
            HTTPURLResponse(
                url: responseURL,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/octet-stream"]
            )
        )
        let results = AsyncThrowingStream<URLSchemeTaskResult, any Error> { continuation in
            continuation.yield(.response(responseHead))
            for ordinal in 0..<chunkCount {
                continuation.yield(.data(Data([UInt8(ordinal)])))
            }
            continuation.finish()
        }

        // Act
        let response = try await BridgeDevelopmentHTTPProductResponse.make(from: results)
        let bodyRecorder = BridgeDevelopmentHTTPBodyRecorder()
        try await response.body.write(ForwardingResponseBodyWriter(sink: bodyRecorder))

        // Assert
        #expect(await bodyRecorder.bytes == Array(0..<UInt8(chunkCount)))
        #expect(await bodyRecorder.didFinish)
    }

    @Test("malformed bootstrap metadata length throws instead of constructing an invalid range")
    func malformedBootstrapMetadataLengthThrows() {
        // Arrange
        var data = Data([1, 0, 0, 1, 0])
        data.append(Data(repeating: 0, count: BridgeProductWireContract.capabilityByteLength))

        // Act / Assert
        #expect(throws: (any Error).self) {
            _ = try decodeHTTPBootstrapEnvelope(data)
        }
    }
}

private func makeHTTPDevelopmentProductHost(
    worktreeRoot: URL
) async throws -> BridgeDevelopmentProductHost {
    let paneID = PaneId.generateUUIDv7().uuid
    let canonicalWorktreeRoot = worktreeRoot.standardizedFileURL.resolvingSymlinksInPath()
    let source = BridgeDevelopmentProductSource(
        paneID: paneID,
        paneState: BridgePaneState(
            panelKind: .diffViewer,
            source: .workspace(rootPath: canonicalWorktreeRoot.path, baseline: .ref(name: "HEAD"))
        ),
        repoID: PaneId.generateUUIDv7().uuid,
        reviewedSubjectLabel: worktreeRoot.lastPathComponent,
        worktreeID: PaneId.generateUUIDv7().uuid,
        worktreeRoot: canonicalWorktreeRoot
    )
    return try await BridgeDevelopmentProductHost(
        source: source,
        operationDeadlineClock: TestPushClock(),
        contributionTargetCommit: { target in
            .unchanged(
                BridgePaneState(
                    panelKind: .diffViewer,
                    source: .workspace(
                        rootPath: worktreeRoot.path,
                        baseline: WorkspaceBaseline(contributionTarget: target)
                    )
                )
            )
        },
        makeReviewProvider: { _, _ in BridgeObservabilitySmokeReviewSourceProvider() }
    )
}

@MainActor
private struct HTTPDevelopmentServerHarness {
    let composition: BridgeDevelopmentServerCoreComposition
    let host: BridgeDevelopmentProductHost
}

@MainActor
private func makeHTTPDevelopmentServerHarness(
    dataRoot: URL,
    worktreeRoot: URL
) async throws -> HTTPDevelopmentServerHarness {
    let configuration = try BridgeDevelopmentServerConfiguration(
        dataRoot: dataRoot,
        paneID: PaneId.generateUUIDv7().uuid,
        port: 43_871,
        seedContributionTarget: .ref(name: "HEAD"),
        seedWorktreeRoot: worktreeRoot
    )
    let composition = try await BridgeDevelopmentServerCoreComposition.prepare(
        configuration: configuration
    )
    let host = try await BridgeDevelopmentProductHost(
        source: composition.productSource,
        worktreeAnnotationStore: composition.worktreeAnnotationStore,
        worktreeAnnotationOutputCoordinator: composition.worktreeAnnotationOutputCoordinator,
        operationDeadlineClock: TestPushClock(),
        contributionTargetCommit: { target in
            composition.applyContributionTarget(target)
        }
    )
    return HTTPDevelopmentServerHarness(composition: composition, host: host)
}

@MainActor
private func withDevelopmentServerHarness<Result>(
    _ harness: HTTPDevelopmentServerHarness,
    operation: () async throws -> Result
) async throws -> Result {
    do {
        let result = try await operation()
        await harness.host.shutdown()
        try await harness.composition.shutdown()
        return result
    } catch {
        await harness.host.shutdown()
        try await harness.composition.shutdown()
        throw error
    }
}

private func withDevelopmentHost<Result>(
    _ host: BridgeDevelopmentProductHost,
    operation: () async throws -> Result
) async throws -> Result {
    do {
        let result = try await operation()
        await host.shutdown()
        return result
    } catch {
        await host.shutdown()
        throw error
    }
}

private actor BridgeDevelopmentHTTPBodyRecorder: RecordingResponseBodySink {
    private(set) var bytes: [UInt8] = []
    private(set) var didFinish = false

    func write(_ buffer: ByteBuffer) {
        bytes.append(contentsOf: buffer.readableBytesView)
    }

    func finish(_: HTTPFields?) {
        didFinish = true
    }
}

struct DecodedHTTPBootstrapEnvelope {
    let bootstrap: BridgeProductSessionBootstrap
    let capabilityBytes: Data
}

func decodeHTTPBootstrapEnvelope(
    _ data: Data
) throws -> DecodedHTTPBootstrapEnvelope {
    let envelopeVersionByteCount = 1
    let metadataLengthByteCount = 4
    let prefixByteCount = envelopeVersionByteCount + metadataLengthByteCount
    guard data.count >= prefixByteCount + BridgeProductWireContract.capabilityByteLength else {
        throw CocoaError(.fileReadCorruptFile)
    }
    #expect(data[0] == 1)
    let metadataByteCount = data[1..<prefixByteCount].reduce(0) { length, byte in
        (length << 8) | Int(byte)
    }
    let metadataRange = prefixByteCount..<(prefixByteCount + metadataByteCount)
    guard metadataRange.upperBound <= data.count else {
        throw CocoaError(.fileReadCorruptFile)
    }
    let capabilityRange = metadataRange.upperBound..<data.count
    guard capabilityRange.count == BridgeProductWireContract.capabilityByteLength else {
        throw CocoaError(.fileReadCorruptFile)
    }
    return try DecodedHTTPBootstrapEnvelope(
        bootstrap: JSONDecoder().decode(
            BridgeProductSessionBootstrap.self,
            from: data.subdata(in: metadataRange)
        ),
        capabilityBytes: data.subdata(in: capabilityRange)
    )
}
