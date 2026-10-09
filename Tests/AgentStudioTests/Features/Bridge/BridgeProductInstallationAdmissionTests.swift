import AgentStudioInfrastructure
import AgentStudioTestHarness
import AgentStudioTestSupport
import Foundation
import Synchronization
import Testing

@testable import AgentStudioBridge

@Suite("Bridge installation admission")
struct BridgeProductInstallationAdmissionTests {
    @Test("composed permit and installation close admit only the winning ordering")
    func composedPermitLinearizesWithInstallationClose() async throws {
        let pane = BridgeProductAdmissionGate()
        let installation = BridgeProductAdmissionGate()
        let admission = try #require(pane.acquire()?.withInstallation(installation))
        let mutation = HeldStep<Void>("composed admission mutation")
        let admitted = Task {
            try await withoutBlockingCooperativePool {
                try admission.withValidAdmission {
                    try mutation.arriveBlocking(())
                    return true
                }
            }
        }
        try await mutation.firstArrival()
        let (closeEvents, closeSignal) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
        let closing = Task {
            await withoutBlockingCooperativePool {
                closeSignal.yield(())
                closeSignal.finish()
                installation.close()
            }
        }
        var closeIterator = closeEvents.makeAsyncIterator()
        #expect(await closeIterator.next() != nil)
        mutation.release()
        #expect(try await admitted.value == true)
        await closing.value
        #expect(admission.withValidAdmission { true } == nil)
        #expect(pane.acquire()?.withValidAdmission { true } == true)
    }

    @Test("close racing composed observation registration signals exactly once")
    func observationRegistrationLinearizesWithClose() async throws {
        let pane = BridgeProductAdmissionGate()
        let installation = BridgeProductAdmissionGate()
        let admission = try #require(pane.acquire()?.withInstallation(installation))
        let observed = Mutex(0)
        let registration = Task { admission.observeClose { observed.withLock { $0 += 1 } } }
        let closing = Task {
            installation.close()
            pane.close()
        }
        let observation = await registration.value
        await closing.value
        #expect(observed.withLock { $0 } == 1)
        observation.cancel()
    }

    @Test("development replacement fences before held host tail and denied tab keeps A usable")
    @MainActor
    func developmentIngressFencesBeforeHostTail() async throws {
        let root = try await FilesystemTestGitRepo.create(named: "rr2-development-ingress")
        defer { FilesystemTestGitRepo.destroy(root) }
        let host = try await BridgeDevelopmentProductHost(
            source: makeDevelopmentProductSource(worktreeRoot: root),
            contributionTargetCommit: developmentContributionTargetCommit(worktreeRoot: root))
        let request = try developmentDisplayBootstrapRequest(reason: "initial", surface: "file", tabId: "rr2-owner")
        let worker = try DevelopmentDisplayWorkerClient(host: host, delivery: await host.issueBootstrap(for: request))
        try await worker.openSession()
        var metadata = try worker.startMetadataStream()
        try await metadata.requireOpeningFrame()
        let owner = await host.productSessionOwner
        let first = try #require(await owner.activeInstallation)
        let firstAdmission = try #require(first.productAdapter.acquireAdmission())
        let denied = try developmentDisplayBootstrapRequest(reason: "initial", surface: "file", tabId: "rr2-other")
        await #expect(throws: BridgeDevelopmentProductHostError.sessionAlreadyOpen) {
            _ = try await host.issueBootstrap(for: denied)
        }
        #expect(firstAdmission.withValidAdmission { true } == true)
        let blocked = HeldStep<Void>("development bootstrap tail")
        let tail = Task { try? await blocked.arrive(()) }
        await host.replaceBootstrapTailForTest(Task { _ = await tail.value })
        try await blocked.firstArrival()
        let (closedEvents, closeSignal) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
        let observation = firstAdmission.observeClose {
            closeSignal.yield(())
            closeSignal.finish()
        }
        let replacing = Task { try await host.issueBootstrap(for: request) }
        var closeIterator = closedEvents.makeAsyncIterator()
        #expect(await closeIterator.next() != nil)
        #expect(firstAdmission.withValidAdmission { true } == nil)
        #expect(owner.productAdmissionGate.acquire() != nil)
        blocked.release()
        _ = await tail.value
        let next = try DevelopmentDisplayWorkerClient(host: host, delivery: await replacing.value)
        try await next.openSession()
        #expect(next.workerInstanceId != worker.workerInstanceId)
        observation.cancel()
        await metadata.stop()
        _ = await host.shutdown()
    }

    @Test("queued N2 dispatch and completion obey E1 fence before session revoke")
    func undispatchedOperationIsFenced() async throws {
        let owner = try BridgePaneProductSessionOwner(
            paneSessionId: bridgeProductTestPaneSessionId,
            provider: BridgePaneProductSessionProviderGate(), productAdmissionGate: BridgeProductAdmissionGate())
        let installation = try await installFirstCandidate(in: owner)
        let capability = try BridgeProductCapabilityHeaderEncoding.encode(installation.capabilityBytes)
        guard
            case .admitted(let claim) = await owner.schemeRouter.claimActiveAdapter(
                presentedCapability: capability, schemeTaskId: UUIDv7.generate(), route: .command)
        else {
            Issue.record("Expected router claim")
            return
        }
        let requestBytes = try JSONSerialization.data(withJSONObject: [
            "kind": "workerSession.open", "paneSessionId": installation.bootstrap.paneSessionId,
            "request": NSNull(), "requestId": "rr2-queued-open", "requestSequence": 1,
            "wireVersion": BridgeProductWireContract.version,
            "workerInstanceId": installation.bootstrap.workerInstanceId,
        ])
        guard
            case .execute(let token, let request) = await installation.session.beginControl(
                exactRequestBytes: requestBytes, presentedCapability: capability,
                productAdmission: claim.productAdmission)
        else {
            Issue.record("Expected operation admission")
            return
        }
        let queued = HeldStep<Void>("queued N2 provider execution")
        let operation = try await installation.session.admitControlOperation(token: token) { _ in
            try? await queued.arrive(())
        }
        try await queued.firstArrival()
        _ = owner.closeActiveInstallation()
        #expect(!(await installation.session.markOperationDispatched(operationId: operation.operationId)))
        let response = try BridgeProductControlResponse.workerSessionAccepted(correlating: request)
        #expect(
            try await installation.session.completeControl(
                token: token,
                exactResponseBytes: JSONEncoder().encode(response)) == .noEffect)
        queued.release()
        await installation.session.waitForOperationExecution(operationId: operation.operationId)
        await claim.finish()
        _ = await owner.retire(reason: .paneDisposal)
    }

    @Test("late A retirement and stale replacement never close or replace B")
    func staleTransitionKeepsSuccessorAdmission() async throws {
        let owner = try BridgePaneProductSessionOwner(
            paneSessionId: bridgeProductTestPaneSessionId,
            provider: BridgePaneProductSessionProviderGate(), productAdmissionGate: BridgeProductAdmissionGate(),
            retirementClock: TestPushClock()
        )
        let first = try await installFirstCandidate(in: owner)
        let predecessor = owner.installationFenceProjection.snapshot
        let pane = try #require(owner.productAdmissionGate.acquire())
        let staleCandidate = try await owner.prepareCandidate(productAdmission: pane)
        let successor = try await installFirstCandidate(in: owner)
        #expect(await owner.retire(reason: .workerReplacement, installation: predecessor) == .retired)
        #expect(
            await owner.activatePreparedCandidate(staleCandidate, productAdmission: pane, replacing: predecessor)
                == .invalidCandidate)
        #expect(staleCandidate.productAdapter.acquireAdmission() == nil)
        #expect(first.productAdapter.acquireAdmission() == nil)
        #expect(successor.productAdapter.acquireAdmission()?.withValidAdmission { true } == true)
        #expect(await owner.activeInstallation?.bootstrap == successor.bootstrap)
        #expect(await owner.schemeRouter.activeInstallation?.bootstrap == successor.bootstrap)
        #expect(await owner.retire(reason: .paneDisposal) == .retired)
    }

    @Test("takeover checks authorization revision and current metadata claims in its close turn")
    func takeoverRejectsStaleAuthorizationAndReopenedMetadata() async throws {
        let owner = try BridgePaneProductSessionOwner(
            paneSessionId: bridgeProductTestPaneSessionId,
            provider: BridgePaneProductSessionProviderGate(), productAdmissionGate: BridgeProductAdmissionGate(),
            retirementClock: TestPushClock()
        )
        let installation = try await installFirstCandidate(in: owner)
        let projection = BridgeDevelopmentBootstrapAuthorizationProjection(
            paneSessionId: bridgeProductTestPaneSessionId)
        let original = projection.snapshot
        let capability = try BridgeProductCapabilityHeaderEncoding.encode(installation.capabilityBytes)
        guard
            case .admitted(let oldStream) = await owner.schemeRouter.claimActiveAdapter(
                presentedCapability: capability, schemeTaskId: UUIDv7.generate(), route: .metadataStream)
        else {
            Issue.record("Expected metadata admission")
            return
        }
        await oldStream.finish()
        #expect(await owner.schemeRouter.metadataStreamHasEnded(for: installation.bootstrap.workerInstanceId))
        projection.publish(tabId: "new-owner", navigationBindingRevision: 1, isShutdown: false)
        #expect(
            !(await owner.schemeRouter.closeTerminatedInstallation(
                installation.installationFence,
                authorization: original, projection: projection)))
        #expect(installation.productAdapter.acquireAdmission() != nil)
        let current = projection.snapshot
        guard
            case .admitted(let newStream) = await owner.schemeRouter.claimActiveAdapter(
                presentedCapability: capability, schemeTaskId: UUIDv7.generate(), route: .metadataStream)
        else {
            Issue.record("Expected reopened metadata admission")
            return
        }
        #expect(
            !(await owner.schemeRouter.closeTerminatedInstallation(
                installation.installationFence,
                authorization: current, projection: projection)))
        #expect(installation.productAdapter.acquireAdmission() != nil)
        await newStream.finish()
        #expect(
            await owner.schemeRouter.closeTerminatedInstallation(
                installation.installationFence,
                authorization: current, projection: projection))
        #expect(installation.productAdapter.acquireAdmission() == nil)
        #expect(await owner.retire(reason: .paneDisposal) == .retired)
    }

    @Test("composed close observation is sticky and once across pane and E1 close")
    func composedCloseObservationIsStickyAndOnce() throws {
        let pane = BridgeProductAdmissionGate()
        let installation = BridgeProductAdmissionGate()
        let admission = try #require(pane.acquire()?.withInstallation(installation))
        let observed = Mutex(0)
        let observation = admission.observeClose { observed.withLock { $0 += 1 } }
        installation.close()
        pane.close()
        installation.close()
        #expect(observed.withLock { $0 } == 1)
        observation.cancel()
        let late = admission.observeClose { observed.withLock { $0 += 1 } }
        #expect(observed.withLock { $0 } == 2)
        late.cancel()
    }

    @Test(
        "E1 retirement fences original router admission before provider revoke",
        arguments: [BridgePaneProductSessionRetirementReason.pageReload, .workerReplacement])
    func retirementFencesBeforeProviderRevoke(reason: BridgePaneProductSessionRetirementReason) async throws {
        let revocation = HeldStep<String>("old worker revoke before session actor")
        let provider = BridgePaneProductSessionProviderGate(workerRevocation: revocation)
        let owner = try BridgePaneProductSessionOwner(
            paneSessionId: bridgeProductTestPaneSessionId,
            provider: provider,
            productAdmissionGate: BridgeProductAdmissionGate()
        )
        let installation = try await installFirstCandidate(in: owner)
        let capability = try BridgeProductCapabilityHeaderEncoding.encode(installation.capabilityBytes)
        guard
            case .admitted(let claim) = await owner.schemeRouter.claimActiveAdapter(
                presentedCapability: capability,
                schemeTaskId: UUIDv7.generate(),
                route: .command
            )
        else {
            Issue.record("Expected original installation scheme admission")
            return
        }
        let retiring = Task { await owner.retire(reason: reason) }
        let workerInstanceId = try await revocation.firstArrival()
        #expect(workerInstanceId == installation.bootstrap.workerInstanceId)
        // The real retirement is held before it can reach session-actor revoke.
        #expect(claim.productAdmission.withValidAdmission { true } == nil)
        #expect(owner.productAdmissionGate.acquire()?.withValidAdmission { true } == true)
        await claim.finish()
        revocation.release()
        #expect(await retiring.value == .retired)
        #expect(await owner.waitForRetirement(of: workerInstanceId))
    }

    @Test("replacement router admissions distinguish installations sharing the pane")
    func replacementAdmissionDoesNotMatchPriorInstallation() async throws {
        let provider = BridgePaneProductSessionProviderGate()
        let owner = try BridgePaneProductSessionOwner(
            paneSessionId: bridgeProductTestPaneSessionId,
            provider: provider,
            productAdmissionGate: BridgeProductAdmissionGate(),
            retirementClock: TestPushClock()
        )
        let first = try await installFirstCandidate(in: owner)
        guard
            case .admitted(let firstClaim) = await owner.schemeRouter.claimActiveAdapter(
                presentedCapability: try BridgeProductCapabilityHeaderEncoding.encode(first.capabilityBytes),
                schemeTaskId: UUIDv7.generate(), route: .command
            )
        else {
            Issue.record("Expected A admission")
            return
        }
        let next = try await installFirstCandidate(in: owner)
        guard
            case .admitted(let nextClaim) = await owner.schemeRouter.claimActiveAdapter(
                presentedCapability: try BridgeProductCapabilityHeaderEncoding.encode(next.capabilityBytes),
                schemeTaskId: UUIDv7.generate(), route: .command
            )
        else {
            Issue.record("Expected B admission")
            return
        }
        #expect(!firstClaim.productAdmission.matches(nextClaim.productAdmission))
        #expect(firstClaim.productAdmission.withValidAdmission { true } == nil)
        #expect(nextClaim.productAdmission.withValidAdmission { true } == true)
        await firstClaim.finish()
        await nextClaim.finish()
        #expect(await owner.retire(reason: .paneDisposal) == .retired)
    }

}

extension BridgeDevelopmentProductHost {
    func replaceBootstrapTailForTest(_ tail: Task<Void, Never>) { bootstrapTransitionTail = tail }
}
