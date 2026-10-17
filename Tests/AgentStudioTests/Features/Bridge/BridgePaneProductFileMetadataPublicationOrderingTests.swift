import Foundation
import Testing

@testable import AgentStudioBridge

@Suite("Bridge pane product File metadata publication ordering")
struct FileMetadataPublicationOrderingTests {
    @Test("published descriptor immediately authorizes its content read plan")
    func publishedDescriptorImmediatelyAuthorizesContentReadPlan() async throws {
        // Arrange
        let fixture = try ProductFileSourceFixture(fileCount: 1)
        defer { fixture.remove() }
        let source = fixture.makeSource()
        let openSnapshot = try fixture.openSnapshot()
        try await source.open(
            subscription: openSnapshot,
            productAdmission: fixture.productAdmission.context
        ) { _ in }
        let updatedSnapshot = try fixture.viewDemand()
        let observation = ImmediateFileContentReadPlanObservation()

        // Act
        try await source.applyViewDemand(
            subscriptionId: openSnapshot.subscriptionId,
            demand: updatedSnapshot,
            productAdmission: fixture.productAdmission.context,
            forceRecapture: false
        ) { event in
            guard case .descriptorReady(let ready) = event,
                case .available(let descriptor) = ready.availability
            else { return }
            let request = try fixture.contentRequest(descriptor: descriptor)
            await observation.record(
                await source.contentReadPlan(
                    for: request,
                    productAdmission: fixture.productAdmission.context
                ) != nil
            )
        }

        // Assert
        #expect(await observation.wasImmediatelyAuthorized == true)
    }

    @Test("failed descriptor emission keeps the index-accepted content read plan")
    func failedDescriptorEmissionKeepsAcceptedContentReadPlan() async throws {
        // Arrange
        let fixture = try ProductFileSourceFixture(fileCount: 1)
        defer { fixture.remove() }
        let source = fixture.makeSource()
        let openSnapshot = try fixture.openSnapshot()
        try await source.open(
            subscription: openSnapshot,
            productAdmission: fixture.productAdmission.context
        ) { _ in }
        let updatedSnapshot = try fixture.viewDemand()
        let observation = ImmediateFileContentReadPlanObservation()

        // Act
        do {
            try await source.applyViewDemand(
                subscriptionId: openSnapshot.subscriptionId,
                demand: updatedSnapshot,
                productAdmission: fixture.productAdmission.context,
                forceRecapture: false
            ) { event in
                guard case .descriptorReady(let ready) = event,
                    case .available(let descriptor) = ready.availability
                else { return }
                await observation.record(descriptor)
                throw DescriptorPublicationTestError.expectedEmissionFailure
            }
            Issue.record("Expected descriptor publication to fail")
        } catch DescriptorPublicationTestError.expectedEmissionFailure {
            // Expected.
        }

        // Assert
        let descriptor = try #require(await observation.descriptor)
        let request = try fixture.contentRequest(descriptor: descriptor)
        let readPlan = await source.contentReadPlan(
            for: request,
            productAdmission: fixture.productAdmission.context
        )
        #expect(readPlan != nil)
    }

    @Test("failed replacement emission keeps the old lease and newly accepted descriptor")
    func failedReplacementEmissionKeepsIssuedDescriptors() async throws {
        // Arrange
        let fixture = try ProductFileSourceFixture(fileCount: 1)
        defer { fixture.remove() }
        let source = fixture.makeSource()
        let openSnapshot = try fixture.openSnapshot()
        try await source.open(
            subscription: openSnapshot,
            productAdmission: fixture.productAdmission.context
        ) { _ in }
        let firstSnapshot = try fixture.viewDemand()
        let firstObservation = ImmediateFileContentReadPlanObservation()
        try await source.applyViewDemand(
            subscriptionId: openSnapshot.subscriptionId,
            demand: firstSnapshot,
            productAdmission: fixture.productAdmission.context,
            forceRecapture: false
        ) { event in
            guard case .descriptorReady(let ready) = event,
                case .available(let descriptor) = ready.availability
            else { return }
            await firstObservation.record(descriptor)
        }
        let firstDescriptor = try #require(await firstObservation.descriptor)
        let firstRequest = try fixture.contentRequest(descriptor: firstDescriptor)
        try Data("replacement\n".utf8).write(to: fixture.demandedFileURL)
        let replacementSnapshot = advancedDemand(from: firstSnapshot, revision: 2)
        let replacementObservation = ImmediateFileContentReadPlanObservation()

        // Act
        do {
            try await source.applyViewDemand(
                subscriptionId: openSnapshot.subscriptionId,
                demand: replacementSnapshot,
                productAdmission: fixture.productAdmission.context,
                forceRecapture: false
            ) { event in
                guard case .descriptorReady(let ready) = event,
                    case .available(let descriptor) = ready.availability
                else { return }
                await replacementObservation.record(descriptor)
                throw DescriptorPublicationTestError.expectedEmissionFailure
            }
            Issue.record("Expected replacement descriptor publication to fail")
        } catch DescriptorPublicationTestError.expectedEmissionFailure {
            // Expected.
        }

        // Assert
        let replacementDescriptor = try #require(await replacementObservation.descriptor)
        let replacementRequest = try fixture.contentRequest(descriptor: replacementDescriptor)
        #expect(
            await source.contentReadPlan(
                for: firstRequest,
                productAdmission: fixture.productAdmission.context
            ) != nil
        )
        #expect(
            await source.contentReadPlan(
                for: replacementRequest,
                productAdmission: fixture.productAdmission.context
            ) != nil
        )
    }

    @Test("stale publication completion cannot revoke a newer authorized descriptor")
    func stalePublicationCompletionPreservesNewerDescriptor() async throws {
        // Arrange
        let fixture = try ProductFileSourceFixture(fileCount: 1)
        defer { fixture.remove() }
        let source = fixture.makeSource()
        let openSnapshot = try fixture.openSnapshot()
        try await source.open(
            subscription: openSnapshot,
            productAdmission: fixture.productAdmission.context
        ) { _ in }
        let olderSnapshot = try fixture.viewDemand()
        let olderObservation = ImmediateFileContentReadPlanObservation()
        let olderEmissionGate = ProductFileMaterializationGate()
        let olderUpdate = Task {
            try await source.applyViewDemand(
                subscriptionId: openSnapshot.subscriptionId,
                demand: olderSnapshot,
                productAdmission: fixture.productAdmission.context,
                forceRecapture: false
            ) { event in
                guard case .descriptorReady(let ready) = event,
                    case .available(let descriptor) = ready.availability
                else { return }
                await olderObservation.record(descriptor)
                await olderEmissionGate.markStarted()
                await olderEmissionGate.waitUntilReleased()
            }
        }
        await olderEmissionGate.waitUntilStarted()
        try Data("newer descriptor\n".utf8).write(to: fixture.demandedFileURL)
        let newerSnapshot = advancedDemand(from: olderSnapshot, revision: 2)
        let newerObservation = ImmediateFileContentReadPlanObservation()

        // Act
        try await source.applyViewDemand(
            subscriptionId: openSnapshot.subscriptionId,
            demand: newerSnapshot,
            productAdmission: fixture.productAdmission.context,
            forceRecapture: false
        ) { event in
            guard case .descriptorReady(let ready) = event,
                case .available(let descriptor) = ready.availability
            else { return }
            await newerObservation.record(descriptor)
        }
        await olderEmissionGate.release()
        try await olderUpdate.value

        // Assert
        let olderDescriptor = try #require(await olderObservation.descriptor)
        let newerDescriptor = try #require(await newerObservation.descriptor)
        let olderRequest = try fixture.contentRequest(descriptor: olderDescriptor)
        let newerRequest = try fixture.contentRequest(descriptor: newerDescriptor)
        let olderReadPlan = try #require(
            await source.contentReadPlan(
                for: olderRequest,
                productAdmission: fixture.productAdmission.context
            )
        )
        await #expect(throws: BridgePaneProductFileContentSourceError.self) {
            _ = try await BridgePaneProductFileContentSource.openReadSession(olderReadPlan)
        }
        #expect(
            await source.contentReadPlan(
                for: newerRequest,
                productAdmission: fixture.productAdmission.context
            ) != nil
        )
    }
}

private func advancedDemand(
    from demand: BridgePaneProductFileViewDemand,
    revision: Int
) -> BridgePaneProductFileViewDemand {
    .init(
        admissionSequence: revision,
        handle: demand.handle,
        scopeRevision: revision,
        state: demand.state
    )
}

private actor ImmediateFileContentReadPlanObservation {
    private(set) var descriptor: BridgeProductFileContentDescriptor?
    private(set) var wasImmediatelyAuthorized = false

    func record(_ wasAuthorized: Bool) {
        wasImmediatelyAuthorized = wasAuthorized
    }

    func record(_ descriptor: BridgeProductFileContentDescriptor) {
        self.descriptor = descriptor
    }
}

private enum DescriptorPublicationTestError: Error {
    case expectedEmissionFailure
}
