import Foundation
import Testing
import WebKit

@testable import AgentStudio
@testable import AgentStudioBridge

@Suite
struct BridgeProductStreamWebKitFeasibilityTests {
    @Test("feasibility policy aliases the permissive frozen G0 request-body ceiling")
    func feasibilityPolicyUsesFrozenRequestBodyCeiling() {
        #expect(
            BridgeProductStreamWebKitFeasibilityPolicy.maxRequestBodyBytes
                == BridgeProductWireContract.maximumRequestBodyBytes)
        #expect(BridgeProductWireContract.maximumRequestBodyBytes == 256 * 1024)
        #expect(
            BridgeProductStreamWebKitFeasibilityConfiguration.measuredProductContract.maximumRequestBodyBytes
                == 256 * 1024)
        #expect(
            BridgeProductStreamWebKitFeasibilityConfiguration.productContract.maximumRequestBodyBytes
                == 256 * 1024)
    }

    @Test("timing summary reports nearest-rank p50 p95 p99 and maximum")
    func timingSummaryUsesNearestRankPercentiles() throws {
        let summary = try #require(
            BridgeWebKitTimingSummary(samples: Array(1...100).map(UInt64.init)))

        #expect(summary.sampleCount == 100)
        #expect(summary.p50Microseconds == 50)
        #expect(summary.p95Microseconds == 95)
        #expect(summary.p99Microseconds == 99)
        #expect(summary.maxMicroseconds == 100)
    }

    @Test("diagnostic source mints a canonical G0 capability without unbounded page retention")
    func diagnosticSourceUsesCanonicalCapabilityAndBoundedRetention() throws {
        let source = try String(
            contentsOfFile:
                "Sources/AgentStudio/App/Boot/BridgeProductStreamWebKitFeasibilityDiagnostic.swift",
            encoding: .utf8
        )

        #expect(source.contains("SecRandomCopyBytes"))
        #expect(source.contains("BridgeProductCapabilityHeaderEncoding.encode"))
        #expect(!source.contains("UUID().uuidString"))
        #expect(source.contains("private static var retainedPage: WebPage?"))
        #expect(!source.contains("retainedPages: [WebPage]"))
    }

    @Test("packaged page accepts only the closed product stream completion event")
    func packagedPageRequiresClosedCompletionDiscriminant() async throws {
        let oracle = BridgeProductStreamWebKitFeasibilityOracle()
        let handler = makeHandler(
            capability: "test-only-product-capability",
            oracle: oracle
        )
        var request = URLRequest(url: URL(string: "agentstudio://s2a/index.html")!)
        request.httpMethod = "GET"

        let html = try await responseBody(for: request, using: handler)

        #expect(html.contains("message.kind === 's2a.completed'"))
        #expect(html.contains("message.mode === 'product-stream-s2a'"))
        #expect(html.contains("typeof message.succeeded === 'boolean'"))
        #expect(html.contains("keys.length === 3"))
        #expect(html.contains("isProductStreamCompletion({ succeeded: true })"))
        #expect(html.contains("extra: true"))
        #expect(html.contains("document.title = isProductStreamCompletion(event.data)"))
        #expect(!html.contains("event.data && event.data.succeeded === true"))
    }

    @Test("minted capability is canonical unpadded base64url for exactly 32 bytes")
    @MainActor
    func mintedCapabilityUsesFrozenCanonicalEncoding() throws {
        let capabilityHeader = BridgeProductStreamWebKitFeasibilityDiagnostic.mintCapabilityHeader()
        let paddedBase64 =
            capabilityHeader
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
            .appending("=")
        let decodedCapability = try #require(Data(base64Encoded: paddedBase64))

        #expect(capabilityHeader.utf8.count == 43)
        #expect(!capabilityHeader.contains("="))
        #expect(
            capabilityHeader.utf8.allSatisfy { byte in
                byte >= 48 && byte <= 57
                    || byte >= 65 && byte <= 90
                    || byte >= 97 && byte <= 122
                    || byte == 45
                    || byte == 95
            })
        #expect(decodedCapability.count == BridgeProductWireContract.capabilityByteLength)
    }

    @Test("authentication rejects before either body representation is touched")
    func authenticationRejectsBeforeBodyAccess() async throws {
        let capability = "test-only-product-capability"
        let body = Data(#"{"kind":"s2a.stream.open"}"#.utf8)
        let requests = [
            makeRequest(path: "/missing-capability", capability: nil, body: body),
            makeRequest(
                path: "/wrong-capability",
                capability: "wrong-product-capability",
                bodyStream: InputStream(data: body)
            ),
        ]

        for (index, request) in requests.enumerated() {
            // Arrange
            let oracle = BridgeProductStreamWebKitFeasibilityOracle()
            let handler = makeHandler(capability: capability, oracle: oracle)

            // Act
            let status = try await responseStatus(for: request, using: handler)
            let snapshot = await oracle.snapshot()

            // Assert
            #expect(status == (index == 0 ? 401 : 403))
            let observation = try #require(snapshot.requestAPIObservations.only)
            #expect(observation.bodySource == .unread)
            #expect(observation.bodyByteCount == 0)
            #expect(snapshot.bodyReadCount == 0)
            #expect(snapshot.decodeCallCount == 0)
            #expect(snapshot.providerCallCount == 0)
            #expect(snapshot.unauthorizedBodyReadCount == 0)
        }
    }

    @Test("oversized capability rejection remains bodyless")
    func oversizedCapabilityRejectsBeforeBodyAccess() async throws {
        // Arrange
        let expectedCapability = "test-only-product-capability"
        let body = Data(#"{"kind":"s2a.stream.open"}"#.utf8)
        let oracle = BridgeProductStreamWebKitFeasibilityOracle()
        let handler = makeHandler(capability: expectedCapability, oracle: oracle)
        let request = makeRequest(
            path: "/wrong-capability",
            capability: String(repeating: "x", count: 1_000_000),
            bodyStream: InputStream(data: body)
        )

        // Act
        let status = try await responseStatus(for: request, using: handler)
        let snapshot = await oracle.snapshot()

        // Assert
        #expect(status == 403)
        let observation = try #require(snapshot.requestAPIObservations.only)
        #expect(observation.bodySource == .unread)
        #expect(observation.bodyByteCount == 0)
        #expect(snapshot.bodyReadCount == 0)
        #expect(snapshot.decodeCallCount == 0)
        #expect(snapshot.providerCallCount == 0)
    }

    @Test("packaged probe fixture uses frozen content framing and a full data payload")
    func packagedProbeFixtureUsesFrozenContentFrames() throws {
        // Arrange
        let fixture = try BridgeProductStreamWebKitFeasibilityContentFrames.makeFixture()
        let decoder = try BridgeProductContentFrameDecoder()
        let validator = BridgeProductContentStreamValidator(expectedRequest: fixture.request)
        var decodedFrames: [BridgeProductContentFrame] = []
        var terminal: BridgeProductContentTerminalResult?

        // Act
        for encodedFrame in fixture.completedFrames {
            let frames = try decoder.append(encodedFrame)
            decodedFrames.append(contentsOf: frames)
            for frame in frames {
                terminal = try validator.accept(frame) ?? terminal
            }
        }
        try decoder.finish()
        try validator.finish()

        // Assert
        #expect(decodedFrames.count == 3)
        guard decodedFrames.count == 3 else { return }
        #expect(decodedFrames[0].header.contentSequence == 0)
        #expect(decodedFrames[1].header.contentSequence == 1)
        #expect(decodedFrames[1].payload.count == BridgeProductWireContract.maximumContentDataPayloadBytes)
        #expect(decodedFrames[2].header.contentSequence == 2)
        guard case .complete(let completed) = terminal else {
            Issue.record("Expected the packaged fixture to end with complete content")
            return
        }
        #expect(completed.bytes.count == BridgeProductWireContract.maximumContentDataPayloadBytes)
        #expect(completed.observedSha256 == BridgeProductStreamWebKitFeasibilityContentFrames.payloadSHA256)
    }

    @Test("worker result receipt requires explicit browser-observed acknowledgement")
    func workerResultReceiptRequiresExplicitAcknowledgement() async {
        // Arrange
        let oracle = BridgeProductStreamWebKitFeasibilityOracle()
        let producer = BridgeWebKitFeasibilityProducerKind.cancellableStream
        let producerTask = Task<Void, Never> {}
        #expect(await oracle.registerProducer(producer, task: producerTask))
        await producerTask.value
        await oracle.finishProducerWork(producer, cancelled: true)
        await oracle.unregisterFinishedProducer(producer)

        // Act
        await oracle.recordWorkerResult(
            exactFrames: true,
            incrementalFrames: true,
            cancellationObserved: true,
            nearCapTiming: .empty
        )
        let receivedSnapshot = await oracle.snapshot()
        let completedBeforeAcknowledgement = await oracle.isComplete()
        let acknowledgementAccepted = await oracle.recordWorkerResultAcknowledged()

        // Assert
        #expect(
            receivedSnapshot.cancellationOrder == [
                .producerStopped, .producerUnregistered,
            ])
        #expect(!completedBeforeAcknowledgement)
        #expect(acknowledgementAccepted)
        #expect(await oracle.isComplete())
    }

    @Test("diagnostic failure evidence retains partial handler and producer progress")
    func diagnosticFailureEvidenceRetainsPartialHandlerAndProducerProgress() async throws {
        // Arrange
        let capability = "test-only-product-capability"
        let configuration = BridgeProductStreamWebKitFeasibilityConfiguration.measuredProductContract
        let oracle = BridgeProductStreamWebKitFeasibilityOracle(configuration: configuration)
        let handler = makeHandler(
            capability: capability,
            oracle: oracle,
            configuration: configuration
        )

        // Act: admit the worker start and three measured requests through the real handler.
        let workerStarted = makeRequest(
            path: "/worker-started",
            capability: capability,
            body: Data(#"{"kind":"s2a.worker.started"}"#.utf8)
        )
        #expect(try await responseStatus(for: workerStarted, using: handler) == 204)
        for sampleIndex in 0..<3 {
            let measuredRequest = makeRequest(
                path: "/near-cap",
                capability: capability,
                body: makeNearCapBody(
                    byteCount: configuration.maximumRequestBodyBytes,
                    phase: .measured,
                    sampleIndex: sampleIndex
                )
            )
            #expect(try await responseStatus(for: measuredRequest, using: handler) == 204)
        }

        // Drive a real oracle producer receipt and cancellation transition before the
        // diagnostic takes its failure snapshot.
        let producer = BridgeWebKitFeasibilityProducerKind.cancellableStream
        let producerTask = Task<Void, Never> {}
        #expect(await oracle.registerProducer(producer, task: producerTask))
        let receipt = BridgeWebKitFeasibilityFrameReceipt(producer: producer, sequence: 0)
        #expect(await oracle.enqueueFrame(producer: producer, sequence: 0, terminal: true))
        #expect(await oracle.recordFrameYielded(producer: producer, sequence: 0))
        #expect(await oracle.recordFrameObserved(receipt))
        await producerTask.value
        await oracle.finishProducerWork(producer, cancelled: true)
        await oracle.unregisterFinishedProducer(producer)

        let snapshot = await oracle.snapshot()
        let proof = await oracle.proof(timedOut: true)
        let decoratedProof = BridgeProductStreamWebKitFeasibilityProof.decoratingIncompleteDiagnostic(
            proof: proof,
            observedPageTitle: "S2a Ready"
        )

        // Assert: the failure keeps raw progress, including fields whose worker-side
        // result has not arrived yet, and presents the last observed phase explicitly.
        #expect(decoratedProof.diagnosticSnapshot == snapshot)
        #expect(decoratedProof.workerStartPostObserved)
        #expect(decoratedProof.measuredRequestsAdmitted == 3)
        #expect(decoratedProof.requestAPIObservations.count == 4)
        #expect(decoratedProof.frameReceiptCount == 1)
        #expect(decoratedProof.cancellationOrder == [.producerStopped, .producerUnregistered])
        #expect(decoratedProof.activeProducerCount == 0)
        #expect(decoratedProof.workerEncodeTiming == nil)
        #expect(decoratedProof.workerFetchCompletionTiming == nil)
        #expect(decoratedProof.diagnosticPhase == .workerProgress(measuredRequestsAdmitted: 3))
        #expect(decoratedProof.failureReason == "product_stream_probe_timeout")
        #expect(!decoratedProof.succeeded)
    }

    @Test("diagnostic page failure keeps its source unknown")
    func diagnosticPageFailureKeepsItsSourceUnknown() async {
        let proof = BridgeProductStreamWebKitFeasibilityProof.decoratingIncompleteDiagnostic(
            proof: .failed(reason: "none"),
            observedPageTitle: "S2a Fail"
        )

        #expect(proof.diagnosticPhase == .pageReportedFailure)
        #expect(proof.failureReason == "worker_result_not_acknowledged")
        #expect(!proof.succeeded)
        #expect(proof.diagnosticSnapshot == nil)
        #expect(proof.bodyReadCount == 0)
    }

    @Test("accepted admission decodes without claiming provider work")
    func acceptedAdmissionDoesNotClaimProviderWork() throws {
        // Arrange
        let capability = "test-only-product-capability"
        let body = Data(#"{"kind":"s2a.worker.started"}"#.utf8)
        let request = makeRequest(
            path: "/worker-started",
            capability: capability,
            body: body
        )
        let admission = BridgeProductStreamWebKitFeasibilityAdmission(
            expectedCapability: capability,
            maximumRequestBodyBytes: BridgeProductStreamWebKitFeasibilityPolicy.maxRequestBodyBytes
        )

        // Act
        let outcome = admission.admit(request, route: "/worker-started")

        // Assert
        guard case .accepted(_, let observation) = outcome else {
            Issue.record("Expected valid body admission")
            return
        }
        #expect(observation.decodeCallCount == 1)
        #expect(observation.providerCallCount == 0)
        #expect(observation.admissionOutcome == .accepted)
    }

    @Test("missing Content-Length accepts exact bounded httpBody bytes")
    func missingContentLengthAcceptsHTTPBody() async throws {
        let capability = "test-only-product-capability"
        let body = Data(#"{"kind":"s2a.worker.started"}"#.utf8)
        let oracle = BridgeProductStreamWebKitFeasibilityOracle()
        let handler = makeHandler(capability: capability, oracle: oracle)
        let request = makeRequest(path: "/worker-started", capability: capability, body: body)

        let status = try await responseStatus(for: request, using: handler)
        let snapshot = await oracle.snapshot()

        #expect(status == 204)
        let observation = try #require(snapshot.requestAPIObservations.only)
        #expect(observation.declaredLengthHeaderState == .missing)
        #expect(observation.bodySource == .httpBody)
        #expect(observation.bodyByteCount == body.count)
        #expect(observation.decodeCallCount == 1)
        #expect(observation.providerCallCount == 1)
        #expect(observation.bodyBytesExact)
        #expect(observation.admissionOutcome == .accepted)
    }

    @Test("missing Content-Length accepts exact bounded httpBodyStream bytes")
    func missingContentLengthAcceptsHTTPBodyStream() async throws {
        let capability = "test-only-product-capability"
        let body = Data(#"{"kind":"s2a.worker.started"}"#.utf8)
        let oracle = BridgeProductStreamWebKitFeasibilityOracle()
        let handler = makeHandler(capability: capability, oracle: oracle)
        let request = makeRequest(
            path: "/worker-started",
            capability: capability,
            bodyStream: InputStream(data: body)
        )

        let status = try await responseStatus(for: request, using: handler)
        let snapshot = await oracle.snapshot()

        #expect(status == 204)
        let observation = try #require(snapshot.requestAPIObservations.only)
        #expect(observation.declaredLengthHeaderState == .missing)
        #expect(observation.bodySource == .httpBodyStream)
        #expect(observation.bodyByteCount == body.count)
        #expect(observation.bodyBytesExact)
        #expect(observation.admissionOutcome == .accepted)
    }

    @Test("product 256 KiB exact valid body decodes and calls provider once for both body APIs")
    func productExactBodyAcceptsBothFoundationBodySources() async throws {
        let capability = "test-only-product-capability"
        let configuration = BridgeProductStreamWebKitFeasibilityConfiguration.measuredProductContract
        let body = makeNearCapBody(byteCount: configuration.maximumRequestBodyBytes)
        let requests = [
            makeRequest(path: "/near-cap", capability: capability, body: body),
            makeRequest(
                path: "/near-cap",
                capability: capability,
                bodyStream: InputStream(data: body)
            ),
        ]

        for request in requests {
            // Arrange
            let oracle = BridgeProductStreamWebKitFeasibilityOracle(configuration: configuration)
            let handler = makeHandler(
                capability: capability,
                oracle: oracle,
                configuration: configuration
            )

            // Act
            let status = try await responseStatus(for: request, using: handler)
            let snapshot = await oracle.snapshot()

            // Assert
            #expect(status == 204)
            let observation = try #require(snapshot.requestAPIObservations.only)
            #expect(observation.declaredLengthHeaderState == .missing)
            #expect(observation.bodyByteCount == 256 * 1024)
            #expect(observation.decodeCallCount == 1)
            #expect(observation.providerCallCount == 1)
            #expect(observation.bodyBytesExact)
            #expect(observation.admissionOutcome == .accepted)
        }
    }

    @Test("product 256 KiB plus one valid body rejects before decode and provider for both body APIs")
    func oversizedActualBodyRejectsBeforeDecodeOrProviderWork() async throws {
        let capability = "test-only-product-capability"
        let configuration = BridgeProductStreamWebKitFeasibilityConfiguration.measuredProductContract
        let oversizedBody = makeNearCapBody(byteCount: configuration.maximumRequestBodyBytes + 1)
        let requests = [
            makeRequest(path: "/oversized-body", capability: capability, body: oversizedBody),
            makeRequest(
                path: "/oversized-body",
                capability: capability,
                bodyStream: InputStream(data: oversizedBody)
            ),
        ]

        for request in requests {
            // Arrange
            let oracle = BridgeProductStreamWebKitFeasibilityOracle(configuration: configuration)
            let handler = makeHandler(
                capability: capability,
                oracle: oracle,
                configuration: configuration
            )

            // Act
            let status = try await responseStatus(for: request, using: handler)
            let snapshot = await oracle.snapshot()

            // Assert
            #expect(status == 413)
            let observation = try #require(snapshot.requestAPIObservations.only)
            #expect(observation.bodyByteCount == 256 * 1024 + 1)
            #expect(observation.decodeCallCount == 0)
            #expect(observation.providerCallCount == 0)
            #expect(observation.admissionOutcome == .rejected(.oversizedBody))
        }
    }

    @Test("closed body union rejects route mismatch and unknown keys before provider work")
    func strictBodyUnionRejectsHostileVariants() async throws {
        let capability = "test-only-product-capability"
        let hostileBodies = [
            (
                "/route-mismatch",
                Data(#"{"kind":"s2a.worker.started"}"#.utf8),
                BridgeProductStreamWebKitFeasibilityRejection.routeBodyMismatch
            ),
            (
                "/strict-extra",
                Data(#"{"kind":"s2a.stream.open","extra":true}"#.utf8),
                BridgeProductStreamWebKitFeasibilityRejection.invalidBody
            ),
            (
                "/strict-extra",
                Data(#"{"\u212aind":"s2a.worker.started"}"#.utf8),
                BridgeProductStreamWebKitFeasibilityRejection.invalidBody
            ),
        ]

        for (route, body, expectedRejection) in hostileBodies {
            // Arrange
            let oracle = BridgeProductStreamWebKitFeasibilityOracle()
            let handler = makeHandler(capability: capability, oracle: oracle)
            let request = makeRequest(path: route, capability: capability, body: body)

            // Act
            let status = try await responseStatus(for: request, using: handler)
            let snapshot = await oracle.snapshot()

            // Assert
            #expect(status == 400)
            let observation = try #require(snapshot.requestAPIObservations.only)
            #expect(observation.decodeCallCount == 1)
            #expect(observation.providerCallCount == 0)
            #expect(observation.admissionOutcome == .rejected(expectedRejection))
        }
    }

    @Test("duplicate request members reject before semantic decode and provider work")
    func duplicateRequestMembersRejectBeforeDecodeOrProviderWork() async throws {
        let capability = "test-only-product-capability"
        let duplicateBodies = [
            Data(#"{"kind":"s2a.stream.open","kind":"s2a.worker.started"}"#.utf8),
            Data(#"{"kind":"s2a.worker.started","\u006bind":"s2a.stream.open"}"#.utf8),
        ]

        for body in duplicateBodies {
            let oracle = BridgeProductStreamWebKitFeasibilityOracle()
            let handler = makeHandler(capability: capability, oracle: oracle)
            let request = makeRequest(
                path: "/worker-started",
                capability: capability,
                body: body
            )

            let status = try await responseStatus(for: request, using: handler)
            let snapshot = await oracle.snapshot()

            #expect(status == 400)
            let observation = try #require(snapshot.requestAPIObservations.only)
            #expect(observation.decodeCallCount == 0)
            #expect(observation.providerCallCount == 0)
            #expect(observation.admissionOutcome == .rejected(.invalidBody))
        }
    }

    @Test("producer queue retains terminal reserve and drains on cancellation")
    func producerQueueRetainsTerminalReserve() async {
        let oracle = BridgeProductStreamWebKitFeasibilityOracle()
        let producer = BridgeWebKitFeasibilityProducerKind.cancellableStream
        let producerTask = Task<Void, Never> {}

        #expect(await oracle.registerProducer(producer, task: producerTask))
        #expect(await oracle.enqueueFrame(producer: producer, sequence: 0, terminal: false))
        #expect(!(await oracle.enqueueFrame(producer: producer, sequence: 1, terminal: false)))
        #expect(await oracle.enqueueFrame(producer: producer, sequence: 1, terminal: true))
        let queuedSnapshot = await oracle.snapshot().producers
        producerTask.cancel()
        await producerTask.value
        await oracle.finishProducerWork(producer, cancelled: true)
        await oracle.unregisterFinishedProducer(producer)
        let cancelledSnapshot = await oracle.snapshot().producers

        #expect(queuedSnapshot.maximumQueuedFrameCount == 2)
        #expect(queuedSnapshot.producerOverflowCount == 1)
        #expect(cancelledSnapshot.activeProducerCount == 0)
        #expect(cancelledSnapshot.activeProducerTaskCount == 0)
        #expect(cancelledSnapshot.queuedFrameCount == 0)
    }

    @Test("rejected duplicate producer cannot finish the active producer")
    func rejectedDuplicateProducerCannotFinishActiveProducer() async throws {
        // Arrange
        let capability = "test-only-product-capability"
        let body = Data(#"{"kind":"s2a.cancel-stream.open"}"#.utf8)
        let oracle = BridgeProductStreamWebKitFeasibilityOracle()
        let handler = makeHandler(capability: capability, oracle: oracle)
        let request = makeRequest(path: "/cancel-stream", capability: capability, body: body)
        let (activeFrameEvents, activeFrameContinuation) = AsyncStream<Void>.makeStream()
        let activeRequestTask = Task {
            for try await result in handler.reply(for: request) {
                if case .data = result {
                    activeFrameContinuation.yield()
                    activeFrameContinuation.finish()
                }
            }
        }
        var activeFrameIterator = activeFrameEvents.makeAsyncIterator()
        _ = await activeFrameIterator.next()
        let activeSnapshot = await oracle.snapshot()

        // Act
        let duplicateStatus = try await responseStatus(for: request, using: handler)
        let duplicateSnapshot = await oracle.snapshot()

        // Assert
        #expect(activeSnapshot.producers.activeProducerCount == 1)
        #expect(duplicateStatus == 409)
        #expect(duplicateSnapshot.producers.activeProducerCount == 1)
        #expect(duplicateSnapshot.cancellationOrder.isEmpty)

        activeRequestTask.cancel()
        _ = try? await activeRequestTask.value
        #expect(await oracle.waitUntilZeroProducerResidue())
    }

    @Test("registered producer cancelled before operation drains its registration")
    func registeredProducerCancelledBeforeOperationDrainsRegistration() async {
        // Arrange
        let oracle = BridgeProductStreamWebKitFeasibilityOracle()
        let producer = BridgeWebKitFeasibilityProducerKind.cancellableStream
        let (startEvents, startContinuation) = AsyncStream<Void>.makeStream()
        let producerTask = Task {
            for await _ in startEvents {}
            guard !Task.isCancelled else { return }
        }
        #expect(await oracle.registerProducer(producer, task: producerTask))

        // Act
        producerTask.cancel()
        startContinuation.finish()
        await producerTask.value
        await oracle.finalizeProducerRegistration(
            producer,
            cancelled: producerTask.isCancelled
        )
        let snapshot = await oracle.snapshot()

        // Assert
        #expect(snapshot.cancellationOrder == [.producerStopped, .producerUnregistered])
        #expect(snapshot.producers.activeProducerCount == 0)
        #expect(snapshot.producers.activeProducerTaskCount == 0)
        #expect(snapshot.producers.queuedFrameCount == 0)
        #expect(await oracle.waitUntilZeroProducerResidue())
    }

    @Test("producer registry rejects post-terminal frames")
    func producerRegistryRejectsPostTerminalFrames() async {
        let oracle = BridgeProductStreamWebKitFeasibilityOracle()
        let producer = BridgeWebKitFeasibilityProducerKind.completedStream
        let producerTask = Task<Void, Never> {}

        #expect(await oracle.registerProducer(producer, task: producerTask))
        await producerTask.value
        await oracle.finishProducerWork(producer, cancelled: false)
        await oracle.unregisterFinishedProducer(producer)
        #expect(!(await oracle.enqueueFrame(producer: producer, sequence: 1, terminal: false)))
        let snapshot = await oracle.snapshot().producers

        #expect(snapshot.activeProducerCount == 0)
        #expect(snapshot.activeProducerTaskCount == 0)
        #expect(snapshot.queuedFrameCount == 0)
        #expect(snapshot.postTerminalFrameCount == 1)
    }

    @Test("terminal admission rejects later frames before producer finish")
    func terminalAdmissionRejectsLaterFramesBeforeProducerFinish() async {
        // Arrange
        let oracle = BridgeProductStreamWebKitFeasibilityOracle()
        let producer = BridgeWebKitFeasibilityProducerKind.completedStream
        let producerTask = Task<Void, Never> {}

        // Act
        #expect(await oracle.registerProducer(producer, task: producerTask))
        #expect(await oracle.enqueueFrame(producer: producer, sequence: 0, terminal: true))
        #expect(await oracle.recordFrameYielded(producer: producer, sequence: 0))
        let laterFrameAccepted = await oracle.enqueueFrame(
            producer: producer,
            sequence: 1,
            terminal: false
        )
        let preFinishSnapshot = await oracle.snapshot().producers
        await producerTask.value
        await oracle.finishProducerWork(producer, cancelled: false)
        await oracle.unregisterFinishedProducer(producer)
        let finishedSnapshot = await oracle.snapshot().producers

        // Assert
        #expect(!laterFrameAccepted)
        #expect(preFinishSnapshot.activeProducerCount == 1)
        #expect(preFinishSnapshot.queuedFrameCount == 0)
        #expect(preFinishSnapshot.producerOverflowCount == 0)
        #expect(preFinishSnapshot.postTerminalFrameCount == 1)
        #expect(finishedSnapshot.activeProducerCount == 0)
        #expect(finishedSnapshot.activeProducerTaskCount == 0)
        #expect(finishedSnapshot.queuedFrameCount == 0)
    }

    @Test("frame receipts are ordered, unique, and tied to emitted frames")
    func frameReceiptsRequireOrderedEmittedFrames() async {
        let oracle = BridgeProductStreamWebKitFeasibilityOracle()
        let producer = BridgeWebKitFeasibilityProducerKind.completedStream
        let producerTask = Task<Void, Never> {}
        let receipt0 = BridgeWebKitFeasibilityFrameReceipt(producer: producer, sequence: 0)
        let receipt1 = BridgeWebKitFeasibilityFrameReceipt(producer: producer, sequence: 1)

        #expect(await oracle.registerProducer(producer, task: producerTask))
        #expect(await oracle.enqueueFrame(producer: producer, sequence: 0, terminal: false))
        #expect(await oracle.recordFrameYielded(producer: producer, sequence: 0))
        #expect(!(await oracle.recordFrameObserved(receipt1)))
        #expect(await oracle.recordFrameObserved(receipt0))
        #expect(!(await oracle.recordFrameObserved(receipt0)))

        let snapshot = await oracle.snapshot()
        await producerTask.value
        await oracle.finishProducerWork(producer, cancelled: false)
        await oracle.unregisterFinishedProducer(producer)
        #expect(snapshot.frameReceipts == [receipt0])
    }

    private func makeHandler(
        capability: String,
        oracle: BridgeProductStreamWebKitFeasibilityOracle,
        configuration: BridgeProductStreamWebKitFeasibilityConfiguration = .productContract
    ) -> BridgeProductStreamWebKitFeasibilitySchemeHandler {
        BridgeProductStreamWebKitFeasibilitySchemeHandler(
            expectedCapability: capability,
            workerSource: "",
            oracle: oracle,
            configuration: configuration
        )
    }

    private func makeNearCapBody(
        byteCount: Int,
        phase: BridgeWebKitNearCapMeasurementPhase = .warmup,
        sampleIndex: Int = 0
    ) -> Data {
        let prefix =
            "{\"kind\":\"s2a.near-cap\",\"phase\":\"\(phase.rawValue)\",\"sampleIndex\":\(sampleIndex),\"padding\":\""
        let suffix = "\"}"
        precondition(byteCount >= prefix.utf8.count + suffix.utf8.count)
        let padding = String(
            repeating: "x",
            count: byteCount - prefix.utf8.count - suffix.utf8.count
        )
        return Data("\(prefix)\(padding)\(suffix)".utf8)
    }

    private func makeRequest(
        path: String,
        capability: String?,
        body: Data? = nil,
        bodyStream: InputStream? = nil
    ) -> URLRequest {
        var request = URLRequest(url: URL(string: "agentstudio://s2a\(path)")!)
        request.httpMethod = BridgeProductWireContract.requestMethod
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let capability {
            request.setValue(
                capability, forHTTPHeaderField: BridgeProductStreamWebKitFeasibilityPolicy.capabilityHeader)
        }
        if let body {
            request.httpBody = body
        } else if let bodyStream {
            request.httpBodyStream = bodyStream
        }
        request.setValue(nil, forHTTPHeaderField: "Content-Length")
        return request
    }

    private func responseStatus(
        for request: URLRequest,
        using handler: BridgeProductStreamWebKitFeasibilitySchemeHandler
    ) async throws -> Int? {
        for try await result in handler.reply(for: request) {
            if case .response(let response) = result {
                return (response as? HTTPURLResponse)?.statusCode
            }
        }
        return nil
    }

    private func responseBody(
        for request: URLRequest,
        using handler: BridgeProductStreamWebKitFeasibilitySchemeHandler
    ) async throws -> String {
        var body = Data()
        for try await result in handler.reply(for: request) {
            if case .data(let chunk) = result {
                body.append(chunk)
            }
        }
        return try #require(String(data: body, encoding: .utf8))
    }
}

extension Collection {
    fileprivate var only: Element? {
        count == 1 ? first : nil
    }
}
