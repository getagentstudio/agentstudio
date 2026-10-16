import AgentStudioTestHarness
import CryptoKit
import Foundation
import Testing

@testable import AgentStudioBridge

@Suite("Retained File replay certificate restart")
struct BridgeProductFileResumedCertificateRestartTests {
    @Test("resnapshot during a replay certificate restarts the same File E3 and delivers edited bytes")
    func resnapshotRestartsInterruptedReplay() async throws {
        let facts = LocalFactSource<String, ResumedFileRestartFact>(
            vocabulary: .init(describeScope: { $0 }, describeFact: { $0.description }, isClosing: { _, _ in false }))
        let recorder = try facts.attach()
        let sink = facts.sink
        let context = try await ResumedFileRestartContext.make(sink: { _, fact in sink(fact.recordingScope, fact) })
        defer { context.fixture.remove() }
        let firstStream = try await context.openStream(id: "file-before-resume", barrier: nil)
        try await context.openSubscription()
        let initialSource = try await context.initialSourceHeld.firstArrival()
        try await context.acceptInitialScope()
        context.initialSourceHeld.release()
        let initialPump = Task { try await context.pump(firstStream.pump, holding: nil) }
        _ = try await recorder.expectNext(
            in: "lifecycle", where: { $0.isSuccessfulBootstrap }, "Initial File bootstrap completes")
        let initialDescriptor = try await recorder.expectNext(
            in: "descriptor", where: { $0.descriptor != nil }, "Initial File descriptor is delivered")
        _ = try await recorder.expectNext(
            in: "waiter", where: { $0.isWaiter }, "Initial certificate waiter registered")
        let subscription = try #require(
            await context.harness.session.subscriptionSnapshot(subscriptionId: "file-subscription-1"))
        let initialScope = try #require(
            await context.harness.session.acceptedViewScope(subscriptionId: subscription.subscriptionId))
        #expect(await firstStream.pump.cancel())
        try await initialPump.value
        let barrier = try await context.reconcile(subscription: subscription)
        let replacementBytes = Data("edited after physical metadata disconnect\n".utf8)
        try replacementBytes.write(to: context.fixture.demandedFileURL)
        let expectedSHA = SHA256.hash(data: replacementBytes).map { String(format: "%02x", $0) }.joined()
        #expect(initialDescriptor.descriptor?.expectedSha256 != expectedSHA)
        let resumed = try await context.openStream(id: "file-after-resume", barrier: barrier)
        let replaySource = try await context.replaySourceHeld.firstArrival()
        #expect(replaySource.subscriptionGeneration > initialSource.subscriptionGeneration)
        // Physical recovery first requests a replacement bank for the retained view.
        #expect(try await context.resnapshot(sequence: 5).kind == "subscription.resnapshotAccepted")
        try await context.applyRetainedDemand()
        let certificateHeld = HeldStep<BridgeProductBatchBeginFrame>("Resumed File certificate exhausts real N3 credit")
        defer { certificateHeld.release() }
        let replayPump = Task { try await context.pump(resumed.pump, holding: certificateHeld) }
        context.replaySourceHeld.release()
        let certificate = try await certificateHeld.firstArrival()
        #expect(certificate.identity.handle == initialScope.handle)
        _ = try await recorder.expectNext(
            in: "waiter", where: { $0.isWaiter }, "Replay File source awaits its held certificate")
        let response = try await context.resnapshot(sequence: 6)
        #expect(response.kind == "subscription.resnapshotAccepted")
        certificateHeld.release()
        _ = try await recorder.expectNext(
            in: "lifecycle", where: { $0.isInterruptedBootstrap }, "Resnapshot ends the interrupted replay bootstrap")
        // Record the owner's state without deciding the verdict by a scheduling gap.
        let diagnostics = await context.source.diagnosticSnapshot()
        let deferred = await context.provider.metadataCoordinator.deferredOpenSubscriptionIds
        facts.sink(
            "state",
            .interruptedState(
                contextCount: diagnostics.subscriptionCount, deferred: deferred.contains(subscription.subscriptionId)))
        _ = try await recorder.expectNext(in: "state", where: { _ in true }, "State after interrupted replay bootstrap")
        let repaired = try await recorder.expectNext(
            in: "descriptor", where: { $0.descriptor?.expectedSha256 == expectedSHA },
            "Retained File E3 restarts after replay resnapshot and delivers the post-edit descriptor")
        #expect((repaired.descriptor?.source.subscriptionGeneration ?? 0) > replaySource.subscriptionGeneration)
        let finalScope = try #require(
            await context.harness.session.acceptedViewScope(subscriptionId: subscription.subscriptionId))
        #expect(finalScope.viewDomain == initialScope.viewDomain)
        #expect(finalScope.handle == initialScope.handle)
        #expect(finalScope.revision == initialScope.revision)
        #expect(finalScope.scope == initialScope.scope)
        #expect(
            await context.harness.session.subscriptionSnapshot(subscriptionId: subscription.subscriptionId)
                == subscription)
        #expect(await context.source.diagnosticSnapshot().subscriptionCount == 1)
        #expect(await resumed.pump.cancel())
        try await replayPump.value
        await context.provider.closeAndDrain()
        facts.end()
        try await recorder.finish()
        #expect(await context.harness.session.producerSnapshot().hasZeroResidue)
    }
}
