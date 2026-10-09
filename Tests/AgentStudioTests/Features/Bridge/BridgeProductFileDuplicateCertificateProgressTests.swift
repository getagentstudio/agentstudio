import AgentStudioTestHarness
import Testing

@testable import AgentStudioBridge

@Suite("File duplicate certificate emission progress")
struct BridgeProductFileDuplicateCertificateProgressTests {
    @Test("dropping a duplicate certificate releases the source-open emission waiter")
    func duplicateCertificateReleasesWaiter() async throws {
        let registrations = LocalFactSource<String, BridgeProductViewDomainKey>(
            vocabulary: .init(describeScope: { $0 }, describeFact: { $0.viewId }, isClosing: { _, _ in false }))
        let registrationRecorder = try registrations.attach()
        let registrationSink = registrations.sink
        let completions = LocalFactSource<String, Bool>(
            vocabulary: .init(
                describeScope: { $0 }, describeFact: { $0 ? "completed" : "retired" },
                isClosing: { _, _ in true }))
        let completionRecorder = try completions.attach()
        let completionSink = completions.sink
        let harness = try await BridgeProductSessionLifecycleHarness.opened(
            viewEmissionWaiterRegistrationObserver: { registrationSink("File", $0) })
        let fixture = try await FileChangeDeliveryFixture.open(harness: harness)
        let certificate = try fixture.snapshot(target: 2, complete: true)
        try await fixture.seal(certificate)
        // Begin plus eight real parts exhaust the sender's part-credit window.
        for _ in 0..<9 { _ = try await fixture.nextFrame() }
        let heldEmission = HeldStep<Void>("File certificate at real N3 part-credit barrier")
        defer { heldEmission.release() }
        let emission = Task {
            try await heldEmission.arrive(())
            try await fixture.acknowledge(through: 8)
            for _ in 0..<3 {
                let frame = try await fixture.nextFrame()
                if case .batch(.part(let part)) = frame {
                    try await fixture.acknowledge(through: part.deliverySequence)
                }
            }
        }
        try await heldEmission.firstArrival()
        // A selection recapture can queue the same complete inventory before emission ends.
        try await fixture.seal(certificate)
        let opening = Task {
            let outcome = await harness.session.awaitViewEmissionCompletion(
                for: fixture.domain, handle: fixture.handle)
            completionSink("File", outcome == .completed)
        }
        _ = try await registrationRecorder.expectNext(
            in: "File", where: { $0 == fixture.domain },
            "File source-open emission waiter registered behind duplicate certificate")
        heldEmission.release()
        try await emission.value
        // Exercise the real pump even though no new frame can be emitted for this no-op.
        try await harness.session.enqueueNextViewFrameIfAvailable(for: fixture.lease)
        #expect(await harness.session.pendingFileSnapshotByViewDomain[fixture.domain] == nil)
        #expect(await harness.session.viewSenderState.hasActiveEmission(for: fixture.domain) == false)
        _ = try await completionRecorder.expectNext(
            in: "File", where: { $0 },
            "File source-open emission completion after duplicate certificate became a no-op")
        await opening.value
        registrations.end()
        completions.end()
        try await registrationRecorder.finish()
        try await completionRecorder.finish()
        try await harness.closeProducer(fixture.lease)
    }
}
