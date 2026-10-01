import AgentStudioInfrastructure
import AgentStudioTestHarness
import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudioBridge

@Suite("Bridge pane product session owner")
struct BridgePaneProductSessionOwnerTests {
    @Test("successful retirement reports the exact worker after local release")
    func successfulRetirementReportsExactWorker() async throws {
        // Arrange
        let provider = BridgePaneProductSessionProviderGate()
        let retiredWorkers = RetiredWorkerRecorder()
        let owner = try BridgePaneProductSessionOwner(
            paneSessionId: bridgeProductTestPaneSessionId,
            provider: provider,
            productAdmissionGate: BridgeProductAdmissionGate(),
            didRetireWorkerInstance: { workerInstanceId in
                await retiredWorkers.record(workerInstanceId)
            }
        )
        let installation = try await installFirstCandidate(in: owner)
        try await openBridgePaneProductSession(installation)

        // Act
        let result = await owner.retire(reason: .pageReload)
        let didRelease = await owner.waitForRetirement(
            of: installation.bootstrap.workerInstanceId
        )

        // Assert
        #expect(result == .retired)
        #expect(didRelease)
        #expect(await retiredWorkers.values == [installation.bootstrap.workerInstanceId])
    }

    @Test("prepared candidates use fresh secure identity and remain off-path")
    func preparedCandidatesAreFreshAndUnexposed() async throws {
        // Arrange
        let provider = BridgePaneProductSessionProviderGate()
        let owner = try BridgePaneProductSessionOwner(
            paneSessionId: bridgeProductTestPaneSessionId,
            provider: provider,
            productAdmissionGate: BridgeProductAdmissionGate()
        )
        let productAdmission = try #require(owner.productAdmissionGate.acquire())

        // Act
        let firstCandidate = try await owner.prepareCandidate(productAdmission: productAdmission)
        let secondCandidate = try await owner.prepareCandidate(productAdmission: productAdmission)

        // Assert
        #expect(firstCandidate.capabilityBytes.count == BridgeProductWireContract.capabilityByteLength)
        #expect(secondCandidate.capabilityBytes.count == BridgeProductWireContract.capabilityByteLength)
        #expect(firstCandidate.capabilityBytes != secondCandidate.capabilityBytes)
        #expect(firstCandidate.bootstrap.paneSessionId == bridgeProductTestPaneSessionId)
        #expect(secondCandidate.bootstrap.paneSessionId == bridgeProductTestPaneSessionId)
        #expect(firstCandidate.bootstrap.workerInstanceId != secondCandidate.bootstrap.workerInstanceId)
        #expect(await owner.activeInstallation == nil)
        #expect(await owner.schemeRouter.activeInstallation == nil)
    }

    @Test("replacement serves the candidate before old revocation finishes")
    func replacementDoesNotWaitForOldRevocationBarrier() async throws {
        // Arrange
        let provider = BridgePaneProductSessionProviderGate()
        let owner = try BridgePaneProductSessionOwner(
            paneSessionId: bridgeProductTestPaneSessionId,
            provider: provider,
            productAdmissionGate: BridgeProductAdmissionGate()
        )
        let oldInstallation = try await installFirstCandidate(in: owner)
        try await openBridgePaneProductSession(oldInstallation)
        let oldReply = try await startContentReply(
            installation: oldInstallation,
            provider: provider,
            identitySuffix: "held-replacement"
        )
        await provider.holdLifecycleAcknowledgements()
        let productAdmission = try #require(owner.productAdmissionGate.acquire())
        let candidate = try await owner.prepareCandidate(productAdmission: productAdmission)

        // Act
        let replacementTask = Task {
            await owner.activatePreparedCandidate(
                candidate,
                productAdmission: productAdmission
            )
        }
        _ = await provider.waitForLifecycleAcknowledgement(count: 1)
        let activationResult = await replacementTask.value

        // Assert
        #expect(activationResult == .activated)
        #expect(
            await owner.activeInstallation?.bootstrap.workerInstanceId
                == candidate.bootstrap.workerInstanceId
        )
        #expect(
            await owner.schemeRouter.activeInstallation?.bootstrap.workerInstanceId
                == candidate.bootstrap.workerInstanceId
        )
        #expect(!(await provider.lifecycleAcknowledgementsWereReleased))
        #expect(!(await oldInstallation.session.producerSnapshot()).hasZeroResidue)
        try await openBridgePaneProductSession(candidate)

        await provider.releaseLifecycleAcknowledgements(result: true)
        #expect(await owner.waitForRetirement(of: oldInstallation.bootstrap.workerInstanceId))
        #expect((await oldInstallation.session.producerSnapshot()).hasZeroResidue)
        #expect(await provider.comparisonTargetReservationInvalidationCount == 1)
        _ = try? await oldReply.value
    }

    @Test("failed old revocation stays visible and retryable while the candidate serves")
    func failedRevocationDoesNotBlockCandidate() async throws {
        // Arrange
        let provider = BridgePaneProductSessionProviderGate()
        let owner = try BridgePaneProductSessionOwner(
            paneSessionId: bridgeProductTestPaneSessionId,
            provider: provider,
            productAdmissionGate: BridgeProductAdmissionGate()
        )
        let oldInstallation = try await installFirstCandidate(in: owner)
        try await openBridgePaneProductSession(oldInstallation)
        let oldReply = try await startContentReply(
            installation: oldInstallation,
            provider: provider,
            identitySuffix: "failed-replacement"
        )
        let productAdmission = try #require(owner.productAdmissionGate.acquire())
        let candidate = try await owner.prepareCandidate(productAdmission: productAdmission)
        await provider.failLifecycleAcknowledgements()

        // Act
        let firstResult = await owner.activatePreparedCandidate(
            candidate,
            productAdmission: productAdmission
        )
        _ = await provider.waitForLifecycleAcknowledgement(count: 1)
        let didReleaseInitially = await owner.waitForRetirement(
            of: oldInstallation.bootstrap.workerInstanceId
        )
        let firstAcknowledgements = await provider.lifecycleAcknowledgements

        // Assert
        #expect(firstResult == .activated)
        #expect(!didReleaseInitially)
        #expect(
            await owner.activeInstallation?.bootstrap.workerInstanceId
                == candidate.bootstrap.workerInstanceId
        )
        #expect(
            await owner.schemeRouter.activeInstallation?.bootstrap.workerInstanceId
                == candidate.bootstrap.workerInstanceId
        )
        #expect((await owner.snapshot()).retiringInstallationCount == 1)
        #expect(!(await oldInstallation.session.producerSnapshot()).hasZeroResidue)
        let firstAcknowledgement = try #require(firstAcknowledgements.first)

        await provider.succeedLifecycleAcknowledgements()
        let retryResult = await owner.retryRetirement(
            of: oldInstallation.bootstrap.workerInstanceId
        )
        let allAcknowledgements = await provider.lifecycleAcknowledgements

        #expect(retryResult)
        #expect(allAcknowledgements.count >= 2)
        #expect(allAcknowledgements[0] == firstAcknowledgement)
        #expect(allAcknowledgements[1] == firstAcknowledgement)
        #expect((await oldInstallation.session.producerSnapshot()).hasZeroResidue)
        #expect(
            await owner.activeInstallation?.bootstrap.workerInstanceId
                == candidate.bootstrap.workerInstanceId
        )
        _ = try? await oldReply.value
    }

    @Test("concurrent replacements preserve invocation order without waiting for old release")
    func concurrentReplacementsPreserveInvocationOrder() async throws {
        // Arrange
        let provider = BridgePaneProductSessionProviderGate()
        let owner = try BridgePaneProductSessionOwner(
            paneSessionId: bridgeProductTestPaneSessionId,
            provider: provider,
            productAdmissionGate: BridgeProductAdmissionGate()
        )
        let oldInstallation = try await installFirstCandidate(in: owner)
        try await openBridgePaneProductSession(oldInstallation)
        let oldReply = try await startContentReply(
            installation: oldInstallation,
            provider: provider,
            identitySuffix: "concurrent-replacement"
        )
        let productAdmission = try #require(owner.productAdmissionGate.acquire())
        let firstCandidate = try await owner.prepareCandidate(productAdmission: productAdmission)
        let secondCandidate = try await owner.prepareCandidate(productAdmission: productAdmission)
        await provider.holdLifecycleAcknowledgements()

        // Act
        let firstReplacementTask = Task {
            await owner.activatePreparedCandidate(
                firstCandidate,
                productAdmission: productAdmission
            )
        }
        _ = await provider.waitForLifecycleAcknowledgement(count: 1)
        let secondReplacementTask = Task {
            await owner.activatePreparedCandidate(
                secondCandidate,
                productAdmission: productAdmission
            )
        }
        let firstResult = await firstReplacementTask.value
        let secondResult = await secondReplacementTask.value
        let secondPublishedBeforeFirstRevocation =
            await owner.activeInstallation?.bootstrap.workerInstanceId
            == secondCandidate.bootstrap.workerInstanceId

        // Assert
        #expect(secondPublishedBeforeFirstRevocation)
        #expect(firstResult == .activated)
        #expect(secondResult == .activated)
        #expect(!(await provider.lifecycleAcknowledgementsWereReleased))
        await provider.releaseLifecycleAcknowledgements(result: true)
        #expect(await owner.waitForRetirement(of: oldInstallation.bootstrap.workerInstanceId))
        #expect(
            await owner.activeInstallation?.bootstrap.workerInstanceId
                == secondCandidate.bootstrap.workerInstanceId
        )
        #expect(
            await owner.schemeRouter.activeInstallation?.bootstrap.workerInstanceId
                == secondCandidate.bootstrap.workerInstanceId
        )
        #expect((await oldInstallation.session.producerSnapshot()).hasZeroResidue)
        _ = try? await oldReply.value
    }

    @Test("replacement follows a page reload fence before old retirement finishes")
    func replacementAfterPageReloadDoesNotWaitForRelease() async throws {
        // Arrange
        let provider = BridgePaneProductSessionProviderGate()
        let owner = try BridgePaneProductSessionOwner(
            paneSessionId: bridgeProductTestPaneSessionId,
            provider: provider,
            productAdmissionGate: BridgeProductAdmissionGate()
        )
        let paneAdmission = try #require(owner.productAdmissionGate.acquire())
        let oldInstallation = try await installFirstCandidate(in: owner)
        try await openBridgePaneProductSession(oldInstallation)
        let oldReply = try await startContentReply(
            installation: oldInstallation,
            provider: provider,
            identitySuffix: "page-reload"
        )
        let replacementCandidate = try await owner.prepareCandidate(
            productAdmission: paneAdmission
        )
        await provider.holdLifecycleAcknowledgements()

        // Act
        let retirementTask = Task {
            await owner.retire(reason: .pageReload)
        }
        _ = await provider.waitForLifecycleAcknowledgement(count: 1)
        let replacementTask = Task {
            await owner.activatePreparedCandidate(
                replacementCandidate,
                productAdmission: paneAdmission
            )
        }
        let retirementResult = await retirementTask.value
        let replacementResult = await replacementTask.value
        let candidatePublishedBeforeRetirement =
            await owner.activeInstallation?.bootstrap.workerInstanceId
            == replacementCandidate.bootstrap.workerInstanceId

        // Assert
        #expect(candidatePublishedBeforeRetirement)
        #expect(retirementResult == .retired)
        #expect(replacementResult == .activated)
        #expect(!(await provider.lifecycleAcknowledgementsWereReleased))
        await provider.releaseLifecycleAcknowledgements(result: true)
        #expect(await owner.waitForRetirement(of: oldInstallation.bootstrap.workerInstanceId))
        #expect(
            await owner.activeInstallation?.bootstrap.workerInstanceId
                == replacementCandidate.bootstrap.workerInstanceId
        )
        #expect(
            paneAdmission.withValidAdmission { true } == true
        )
        #expect((await oldInstallation.session.producerSnapshot()).hasZeroResidue)
        _ = try? await oldReply.value
    }

    @Test("pane disposal is terminal before its retirement acknowledgement completes")
    func paneDisposalRejectsConcurrentAndFutureActivation() async throws {
        // Arrange
        let provider = BridgePaneProductSessionProviderGate()
        let owner = try BridgePaneProductSessionOwner(
            paneSessionId: bridgeProductTestPaneSessionId,
            provider: provider,
            productAdmissionGate: BridgeProductAdmissionGate()
        )
        let oldInstallation = try await installFirstCandidate(in: owner)
        try await openBridgePaneProductSession(oldInstallation)
        let oldReply = try await startContentReply(
            installation: oldInstallation,
            provider: provider,
            identitySuffix: "terminal-pane-disposal"
        )
        let productAdmission = try #require(owner.productAdmissionGate.acquire())
        let candidate = try await owner.prepareCandidate(productAdmission: productAdmission)
        await provider.holdLifecycleAcknowledgements()

        // Act
        let retirementTask = Task {
            await owner.retire(reason: .paneDisposal)
        }
        _ = await provider.waitForLifecycleAcknowledgement(count: 1)
        let activationResult = await owner.activatePreparedCandidate(
            candidate,
            productAdmission: productAdmission
        )

        await provider.releaseLifecycleAcknowledgements(result: true)
        let retirementResult = await retirementTask.value

        // Assert
        #expect(activationResult == .ownerDisposed)
        #expect(retirementResult == .retired)
        #expect(await owner.activeInstallation == nil)
        #expect(await owner.schemeRouter.activeInstallation == nil)
        #expect((await oldInstallation.session.producerSnapshot()).hasZeroResidue)
        #expect((await candidate.session.snapshot).lifecycle == .revoked)
        await #expect(throws: BridgePaneProductSessionOwnerError.ownerDisposed) {
            _ = try await owner.prepareCandidate(productAdmission: productAdmission)
        }
        _ = try? await oldReply.value
    }

    @Test("tracked pane disposal drains scheme tasks producers leases and acknowledgements")
    func trackedDisposalReachesZeroResidue() async throws {
        // Arrange
        let fixture = try makeBridgePaneProductSessionOwnerFrameWaiterFixture()
        let provider = fixture.provider
        let owner = fixture.owner
        let installation = fixture.installation
        try await openBridgePaneProductSession(installation)
        let metadataFirstDataReceipt = HeldStep<Void>(
            "metadata delivery reaches its collector",
            cancellation: .holdThroughCancellation
        )
        let contentFirstDataReceipt = HeldStep<Void>(
            "content delivery reaches its collector",
            cancellation: .holdThroughCancellation
        )
        let schemeRouter = await owner.schemeRouter
        let handler = BridgeSchemeHandler(
            paneId: UUID(),
            appRootURL: testBridgeAppRootURL(),
            productSessionRouter: schemeRouter
        )
        let metadataReply = try await startBridgePaneProductMetadataReply(
            installation: installation,
            provider: provider,
            handler: handler,
            firstDataReceipt: metadataFirstDataReceipt
        )
        let contentReply = try await startContentReply(
            installation: installation,
            provider: provider,
            identitySuffix: "pane-disposal",
            handler: handler,
            firstDataReceipt: contentFirstDataReceipt
        )
        _ = try await metadataFirstDataReceipt.firstArrival()
        _ = try await contentFirstDataReceipt.firstArrival()
        let firstRegisteredLease = try await fixture.firstFrameWaiterRegistration.firstArrival()
        let secondRegisteredLease = try await fixture.secondFrameWaiterRegistration.firstArrival()
        #expect(firstRegisteredLease != secondRegisteredLease)
        let liveSnapshot = await owner.snapshot()

        // Act
        let retirementTask = Task {
            await owner.retire(reason: .paneDisposal)
        }
        _ = await provider.waitForLifecycleAcknowledgement(count: 1)
        metadataFirstDataReceipt.release()
        contentFirstDataReceipt.release()
        fixture.firstFrameWaiterRegistration.release()
        fixture.secondFrameWaiterRegistration.release()
        let retirement = await retirementTask.value
        _ = try? await metadataReply.value
        _ = try? await contentReply.value
        let finalSnapshot = await owner.snapshot()

        // Assert
        #expect(liveSnapshot.activeSchemeTaskCount == 2)
        #expect(liveSnapshot.activeProducerCount == 2)
        #expect(liveSnapshot.activeProducerTaskCount == 2)
        #expect(liveSnapshot.activeContentLeaseCount == 1)
        #expect(liveSnapshot.pendingFrameWaiterCount == 2)
        let liveDeliveryResidueCount =
            liveSnapshot.queuedFrameCount
            + liveSnapshot.pendingFrameWaiterCount
            + liveSnapshot.inFlightFrameReceiptCount
        #expect((2...4).contains(liveDeliveryResidueCount))
        #expect(
            (liveSnapshot.queuedFrameCount == 0)
                == (liveSnapshot.queuedByteCount == 0)
        )
        #expect(liveSnapshot.pendingLifecycleAcknowledgementCount == 0)
        #expect(liveSnapshot.nextMetadataStreamSequence == 1)
        #expect(retirement == .retired)
        #expect(await owner.activeInstallation == nil)
        #expect(await owner.schemeRouter.activeInstallation == nil)
        #expect(finalSnapshot.activeSchemeTaskCount == 0)
        #expect(finalSnapshot.activeProducerCount == 0)
        #expect(finalSnapshot.activeProducerTaskCount == 0)
        #expect(finalSnapshot.activeContentLeaseCount == 0)
        #expect(finalSnapshot.activeTransportLeaseCount == 0)
        #expect(finalSnapshot.queuedFrameCount == 0)
        #expect(finalSnapshot.queuedByteCount == 0)
        #expect(finalSnapshot.pendingFrameWaiterCount == 0)
        #expect(finalSnapshot.inFlightFrameReceiptCount == 0)
        #expect(finalSnapshot.pendingLifecycleAcknowledgementCount == 0)
        #expect(finalSnapshot.nextMetadataStreamSequence == 0)
        #expect(finalSnapshot.hasZeroResidue)
    }

    @Test("control-only work remains visible as an execution after its admission claim ends")
    func controlOnlyWorkTracksOperationWithoutProducers() async throws {
        // Arrange
        let provider = BridgePaneProductSessionProviderGate()
        let owner = try BridgePaneProductSessionOwner(
            paneSessionId: bridgeProductTestPaneSessionId,
            provider: provider,
            productAdmissionGate: BridgeProductAdmissionGate()
        )
        let installation = try await installFirstCandidate(in: owner)
        try await openBridgePaneProductSession(installation)
        await provider.holdProductCallResponses()
        let schemeRouter = await owner.schemeRouter
        let handler = BridgeSchemeHandler(
            paneId: UUID(),
            appRootURL: testBridgeAppRootURL(),
            productSessionRouter: schemeRouter
        )
        let request = try paneOwnerProductCallSchemeRequest(
            installation: installation,
            identitySuffix: "control-only"
        )

        // Act
        let replyTask = Task {
            try await collectBridgeSchemeHandlerProductReply(
                handler: handler,
                request: request
            )
        }
        await provider.waitUntilProductCallStarted()
        let liveSnapshot = await owner.snapshot()
        let retirementTask = Task {
            await owner.retire(reason: .paneDisposal)
        }
        await schemeRouter.waitUntilCleared()
        let retiringSnapshot = await owner.snapshot()
        let retiredCapability = try BridgeProductCapabilityHeaderEncoding.encode(
            installation.capabilityBytes
        )
        let postFenceAdmission = await schemeRouter.claimActiveAdapter(
            presentedCapability: retiredCapability,
            schemeTaskId: UUIDv7.generate(),
            route: .metadataStream
        )

        // Assert
        #expect(liveSnapshot.activeOperationExecutionCount == 1)
        #expect(liveSnapshot.activeProducerCount == 0)
        #expect(liveSnapshot.activeProducerTaskCount == 0)
        #expect(liveSnapshot.activeContentLeaseCount == 0)
        #expect(retiringSnapshot.activeOperationExecutionCount == 1)
        #expect(retiringSnapshot.retiringInstallationCount == 1)
        #expect(!retiringSnapshot.hasZeroResidue)
        if case .conflict = postFenceAdmission {
            // Expected: authenticated pane identity remains distinguishable after clear.
        } else {
            Issue.record("Expected the cleared product router to reject with conflict")
        }

        await provider.releaseProductCallResponses()
        #expect(await retirementTask.value == .retired)
        _ = try? await replyTask.value
        #expect(await owner.snapshot() == .empty)
    }

    @Test("failed background retirement keeps exact acknowledgement and visible residue")
    func failedRetirementPreservesVisibleResidueForExactRetry() async throws {
        // Arrange
        let provider = BridgePaneProductSessionProviderGate()
        let owner = try BridgePaneProductSessionOwner(
            paneSessionId: bridgeProductTestPaneSessionId,
            provider: provider,
            productAdmissionGate: BridgeProductAdmissionGate()
        )
        let installation = try await installFirstCandidate(in: owner)
        try await openBridgePaneProductSession(installation)
        let contentReply = try await startContentReply(
            installation: installation,
            provider: provider,
            identitySuffix: "visible-retry-residue"
        )
        await provider.holdLifecycleAcknowledgements()

        // Act
        let firstRetirementTask = Task {
            await owner.retire(reason: .pageReload)
        }
        let firstAcknowledgement = await provider.waitForLifecycleAcknowledgement(count: 1)
        let retiringSnapshot = await owner.snapshot()
        await provider.releaseLifecycleAcknowledgements(result: false)
        let firstResult = await firstRetirementTask.value
        let didReleaseInitially = await owner.waitForRetirement(
            of: installation.bootstrap.workerInstanceId
        )
        let failedSnapshot = await owner.snapshot()

        // Assert
        #expect(!retiringSnapshot.hasZeroResidue)
        #expect(retiringSnapshot.pendingLifecycleAcknowledgementCount == 1)
        #expect(firstResult == .retired)
        #expect(!didReleaseInitially)
        #expect(!failedSnapshot.hasZeroResidue)
        #expect(failedSnapshot.pendingLifecycleAcknowledgementCount == 1)
        #expect(failedSnapshot.retiringInstallationCount == 1)

        await provider.succeedLifecycleAcknowledgements()
        let retryResult = await owner.retryRetirement(
            of: installation.bootstrap.workerInstanceId
        )
        let acknowledgements = await provider.lifecycleAcknowledgements
        #expect(retryResult)
        #expect(acknowledgements.count >= 2)
        #expect(acknowledgements[0] == firstAcknowledgement)
        #expect(acknowledgements[1] == firstAcknowledgement)
        #expect(await owner.snapshot() == .empty)
        _ = try? await contentReply.value
    }

    @Test("the sole live scheme handler delegates every product route to the session router")
    func liveSchemeOwnershipIsProductOnly() throws {
        // Arrange
        let projectRoot = URL(fileURLWithPath: TestPathResolver.projectRoot(from: #filePath))
        let bootstrapSource = try String(
            contentsOf: projectRoot.appending(
                path: "Sources/AgentStudio/Features/Bridge/Runtime/BridgePaneController+Bootstrap.swift"
            ),
            encoding: .utf8
        )
        let bootstrapModelsSource = try String(
            contentsOf: projectRoot.appending(
                path: "Sources/AgentStudio/Features/Bridge/Runtime/BridgePaneController+BootstrapModels.swift"
            ),
            encoding: .utf8
        )
        let schemeHandlerSource = try String(
            contentsOf: projectRoot.appending(
                path: "Sources/AgentStudio/Features/Bridge/Transport/BridgeSchemeHandler.swift"
            ),
            encoding: .utf8
        )

        // Act / Assert
        #expect(bootstrapSource.contains("BridgePaneProductSessionOwner"))
        #expect(bootstrapModelsSource.contains("BridgeProductSchemeSessionRouter"))
        #expect(bootstrapSource.contains("productSessionRouter: input.productSessionRouter"))
        #expect(schemeHandlerSource.contains("BridgeProductSchemeSessionRouter"))
        #expect(schemeHandlerSource.contains("BridgeProductWireContract.commandRoute"))
        #expect(schemeHandlerSource.contains("BridgeProductWireContract.streamRoute"))
        #expect(schemeHandlerSource.contains("BridgeProductWireContract.contentRoute"))
        #expect(!bootstrapSource.contains("rpcDispatcher: input.rpcDispatcher"))
        #expect(!schemeHandlerSource.contains("case rpcCommand"))
    }
}

private actor RetiredWorkerRecorder {
    private(set) var values: [String] = []

    func record(_ workerInstanceId: String) {
        values.append(workerInstanceId)
    }
}

func installFirstCandidate(
    in owner: BridgePaneProductSessionOwner
) async throws -> BridgeProductSessionInstallation {
    let productAdmission = try #require(owner.productAdmissionGate.acquire())
    let candidate = try await owner.prepareCandidate(productAdmission: productAdmission)
    #expect(
        await owner.activatePreparedCandidate(
            candidate,
            productAdmission: productAdmission
        ) == .activated
    )
    return candidate
}
