import AgentStudioCore
import CryptoKit
import Foundation
import Testing

@testable import AgentStudioBridge

@Suite("Bridge File descriptor renewal after invalidation")
struct BridgePaneProductFileDescriptorRenewalTests {
    @Test("retained interests receive fresh descriptor authority when their file changes", arguments: [false, true])
    func retainedInterestsRenewInvalidatedDescriptor(includesUndemandedChange: Bool) async throws {
        // Arrange
        let fixture = try ProductFileSourceFixture(fileCount: includesUndemandedChange ? 2 : 1)
        defer { fixture.remove() }
        let refreshAdmission = await BridgePaneRefreshWorkAdmissionTestContext.foreground()
        let source = fixture.makeSource()
        let opened = try fixture.openSnapshot()
        try await source.open(
            subscription: opened,
            productAdmission: fixture.productAdmission.context
        ) { _ in }
        let interests = try fixture.viewDemand()
        let initialEvents = ProductFileSourceFactCollector()
        try await source.applyViewDemand(
            subscriptionId: opened.subscriptionId,
            demand: interests,
            productAdmission: fixture.productAdmission.context,
            forceRecapture: false
        ) { await initialEvents.append($0, source: source) }
        let previousDescriptor = try #require(
            (await initialEvents.events).compactMap(availableRenewalDescriptor).first
        )
        let previousRequest = try fixture.contentRequest(descriptor: previousDescriptor)
        let replacementBytes = Data("replacement content for retained selection\n".utf8)
        try replacementBytes.write(to: fixture.demandedFileURL)
        let changedPaths =
            includesUndemandedChange ? [fixture.demandedPath, "File-0001.swift"] : [fixture.demandedPath]
        if includesUndemandedChange {
            try Data("unselected file changed\n".utf8).write(to: fixture.rootURL.appending(path: "File-0001.swift"))
        }

        // Act — isolate production capability from the caller deciding to renew demand.
        let published = try await source.publish(
            changeset: FileChangeset(
                worktreeId: fixture.worktreeId,
                repoId: fixture.repoId,
                rootPath: fixture.rootURL,
                paths: changedPaths,
                timestamp: .now,
                batchSeq: 1
            ),
            productAdmission: fixture.productAdmission.context,
            foregroundWorkAdmission: refreshAdmission.admission
        )
        let staleReadPlan = await source.contentReadPlan(
            for: previousRequest,
            productAdmission: fixture.productAdmission.context
        )
        // The live metadata owner must advance existing demand without a changed interest set.
        let publishedDescriptors = published.compactMap { availableRenewalDescriptor($0.fact) }
        #expect(publishedDescriptors.count == 1)
        // A path without a materialized descriptor must not become a global content reset.
        #expect(
            !published.contains { emission in
                if case .invalidated(let invalidation) = emission.fact { return invalidation.fileId == nil }
                return false
            })
        let renewedEvents = ProductFileSourceFactCollector()
        try await source.applyViewDemand(
            subscriptionId: opened.subscriptionId,
            demand: interests,
            productAdmission: fixture.productAdmission.context,
            forceRecapture: false
        ) { await renewedEvents.append($0, source: source) }

        // Assert — this explicit-renewal control does not claim automatic recovery.
        let renewedDescriptor = try #require(
            (publishedDescriptors + (await renewedEvents.events).compactMap(availableRenewalDescriptor)).first
        )
        let expectedSha256 = SHA256.hash(data: replacementBytes)
            .map { String(format: "%02x", $0) }.joined()
        let retainedReadPlan = try #require(staleReadPlan)
        await #expect(throws: BridgePaneProductFileContentSourceError.self) {
            _ = try await BridgePaneProductFileContentSource.openReadSession(retainedReadPlan)
        }
        #expect(renewedDescriptor != previousDescriptor)
        #expect(renewedDescriptor.expectedSha256 == expectedSha256)
        let replacementInInvalidation = published.compactMap { emission -> BridgeProductFileContentDescriptor? in
            guard case .invalidated(let invalidation) = emission.fact,
                let replacement = invalidation.replacementDescriptor,
                case .available(let descriptor) = replacement.availability
            else { return nil }
            return descriptor
        }
        #expect(replacementInInvalidation == [renewedDescriptor])
        let renewedRequest = try fixture.contentRequest(descriptor: renewedDescriptor)
        #expect(
            await source.contentReadPlan(
                for: renewedRequest,
                productAdmission: fixture.productAdmission.context
            ) != nil
        )
        print(
            "File renewal diagnostic: changeset descriptors=\(published.compactMap { availableRenewalDescriptor($0.fact) }.count), explicit same-interest renewal descriptors=\((await renewedEvents.events).compactMap(availableRenewalDescriptor).count)"
        )
    }

    @Test("a superseded refresh admission cannot publish over newer descriptor authority")
    @MainActor
    func supersededRefreshAdmissionCannotPublishOverNewerDescriptor() async throws {
        // Arrange
        let fixture = try ProductFileSourceFixture(fileCount: 1)
        defer { fixture.remove() }
        let materializationGate = OverlappingFileDescriptorMaterializationGate()
        let source = fixture.makeSource(descriptorMaterializer: { request in
            let materialization = try await BridgePaneProductFileContentSource.materialize(request)
            await materializationGate.holdFirstArmedMaterialization()
            return materialization
        })
        let opened = try fixture.openSnapshot()
        try await source.open(
            subscription: opened,
            productAdmission: fixture.productAdmission.context
        ) { _ in }
        let interests = try fixture.viewDemand()
        try await source.applyViewDemand(
            subscriptionId: opened.subscriptionId,
            demand: interests,
            productAdmission: fixture.productAdmission.context,
            forceRecapture: false
        ) { _ in }
        let olderBytes = Data("overlapping renewal A\n".utf8)
        try olderBytes.write(to: fixture.demandedFileURL)
        let refreshCoordinator = BridgePaneRefreshAdmissionCoordinator(initialActivity: .foreground)
        let olderChangeset = fixture.changeset(batchSequence: 1)
        refreshCoordinator.recordInvalidation(
            fileChangeset: olderChangeset,
            requiresReviewRefresh: false
        )
        let olderReservation = try #require(
            refreshCoordinator.reserveForegroundRefreshPass(for: .file)
        )
        await materializationGate.arm()
        let olderPublicationTask = Task {
            try await source.publish(
                changeset: olderChangeset,
                productAdmission: fixture.productAdmission.context,
                foregroundWorkAdmission: olderReservation.foregroundWorkAdmission
            )
        }
        await materializationGate.waitUntilHeld()
        let newerBytes = Data("overlapping renewal B\n".utf8)
        let newerChangeset = fixture.changeset(batchSequence: 2)
        let newerPublicationTask: Task<[BridgePaneProductFileMetadataEmission], any Error>
        do {
            try newerBytes.write(to: fixture.demandedFileURL)
            refreshCoordinator.recordInvalidation(
                fileChangeset: newerChangeset,
                requiresReviewRefresh: false
            )
            let newerReservation = try #require(
                refreshCoordinator.reserveForegroundRefreshPass(for: .file)
            )
            newerPublicationTask = Task {
                try await source.publish(
                    changeset: newerChangeset,
                    productAdmission: fixture.productAdmission.context,
                    foregroundWorkAdmission: newerReservation.foregroundWorkAdmission
                )
            }
        } catch {
            await materializationGate.release()
            _ = await olderPublicationTask.result
            throw error
        }

        // Act
        let newerPublicationResult = await newerPublicationTask.result
        await materializationGate.release()
        let lateOlderPublicationResult = await olderPublicationTask.result
        let newerPublication = try newerPublicationResult.get()
        let lateOlderPublication = try lateOlderPublicationResult.get()

        // Assert
        let newerDescriptor = try #require(
            newerPublication.compactMap { availableRenewalDescriptor($0.fact) }.first
        )
        let expectedNewerSHA256 = SHA256.hash(data: newerBytes)
            .map { String(format: "%02x", $0) }.joined()
        #expect(newerDescriptor.expectedSha256 == expectedNewerSHA256)
        #expect(
            olderReservation.foregroundWorkAdmission.withValidAdmission {
                lateOlderPublication
            } == nil
        )
        let newerRequest = try fixture.contentRequest(descriptor: newerDescriptor)
        #expect(
            await source.contentReadPlan(
                for: newerRequest,
                productAdmission: fixture.productAdmission.context
            ) != nil
        )
    }
}

private func availableRenewalDescriptor(
    _ observation: ProductFileSourceObservation
) -> BridgeProductFileContentDescriptor? {
    availableRenewalDescriptor(observation.fact)
}

private func availableRenewalDescriptor(
    _ event: BridgePaneProductFileSourceFact
) -> BridgeProductFileContentDescriptor? {
    let payload: BridgeProductFileDescriptorReadyPayload?
    switch event {
    case .descriptorReady(let ready): payload = ready
    case .invalidated(let invalidation): payload = invalidation.replacementDescriptor
    default: payload = nil
    }
    guard let payload, case .available(let descriptor) = payload.availability else { return nil }
    return descriptor
}

private actor OverlappingFileDescriptorMaterializationGate {
    private var armed = false
    private var held = false
    private var heldWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func arm() {
        armed = true
    }

    func holdFirstArmedMaterialization() async {
        guard armed else { return }
        armed = false
        held = true
        let waiters = heldWaiters
        heldWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters { waiter.resume() }
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitUntilHeld() async {
        if held { return }
        await withCheckedContinuation { continuation in
            heldWaiters.append(continuation)
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

extension ProductFileSourceFixture {
    fileprivate func changeset(batchSequence: UInt64) -> FileChangeset {
        FileChangeset(
            worktreeId: worktreeId,
            repoId: repoId,
            rootPath: rootURL,
            paths: [demandedPath],
            timestamp: .now,
            batchSeq: batchSequence
        )
    }
}
