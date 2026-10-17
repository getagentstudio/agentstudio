import Foundation
import Testing

@testable import AgentStudioBridge

extension BridgePaneProductFileMetadataSourceTests {
    @Test("accepted-source observer receives the exact emitted File identity")
    func acceptedSourceObserverReceivesEmittedIdentity() async throws {
        // Arrange
        let fixture = try ProductFileSourceFixture(fileCount: 1)
        defer { fixture.remove() }
        let acceptedSourceRecorder = AcceptedFileSourceRecorder()
        let source = fixture.makeSource(sourceAcceptedObserver: { acceptedSource in
            await acceptedSourceRecorder.record(acceptedSource)
        })
        let collector = ProductFileSourceFactCollector()
        let subscription = try fixture.openSnapshot()

        // Act
        do {
            try await source.open(
                subscription: subscription,
                productAdmission: fixture.productAdmission.context
            ) { event in
                await collector.append(event, source: source)
            }
        } catch {
            await source.cancel(subscriptionId: subscription.subscriptionId)
            throw error
        }
        await source.cancel(subscriptionId: subscription.subscriptionId)
        let observedSource = try #require(await acceptedSourceRecorder.source)

        // Assert
        let emittedSource = try #require(
            (await collector.events).compactMap { event -> BridgeProductFileSourceIdentity? in
                guard case .sourceAccepted(let accepted) = event else { return nil }
                return accepted
            }.first
        )
        #expect(observedSource == emittedSource)
    }
}

private actor AcceptedFileSourceRecorder {
    private(set) var source: BridgeProductFileSourceIdentity?

    func record(_ source: BridgeProductFileSourceIdentity) {
        self.source = source
    }
}
