import AgentStudioInfrastructure
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioCore

extension PaneContextPopoverPerformanceTests {
    @Test("S6 actual family publications distinguish resolved, execution-validation and input frames")
    func inputFramesAreSeparateFromResolvedPublications() async throws {
        let trace = PaneContextPopoverTraceFixture()
        let family = PaneContextPopoverDetailFamily(performance: .init(recorder: trace.recorder))
        let key = PaneContextPopoverConsumerKey(
            hostId: UUIDv7.generate(), surface: .managementCard, paneId: .generateUUIDv7())
        let epoch = UUIDv7.generate()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        do {
            let atom = try #require(family.materialize(for: key))
            let port = try #require(family.projectionPort(for: key))
            // Canonical values stand in outside this family/emitter claim; the family, kernel and completion are real.
            for index in 1...4 {
                let identity = PaneContextPopoverRequestIdentity(
                    key: key, openingEpoch: 1, serviceEpoch: epoch, requestGeneration: UInt64(index),
                    inputGeneration: UInt64(index), ageGeneration: 0, pageGeneration: 0,
                    producer: index == 2 ? .input(UUIDv7.generate()) : .execution(UUIDv7.generate()),
                    validationPhase: index >= 3 ? .resolved : .pending)
                let snapshot = PaneContextPopoverSnapshot(
                    identity: identity,
                    demand: .init(content: .card, location: .pane, includingDrawers: true, screenVisibleWidth: 1400),
                    capture: .init(
                        observationGeneration: UInt64(index), serviceEpoch: epoch,
                        sources: [
                            key.paneId: .init(
                                structuralFacts: nil, title: "Private frame \(min(index, 3))", note: nil, session: nil,
                                display: nil, activity: nil)
                        ]),
                    state: .ready(.compact), wallNow: now, frozenWidth: 480)
                let outcome = await port.admit(snapshot)
                if index == 4 {
                    guard case .equal = outcome else { throw PublicationProofFailure.notEqual }
                } else {
                    guard case .published = outcome else { throw PublicationProofFailure.notPublished }
                }
                #expect(atom.latestAcceptedValue?.publication.request == identity)
            }
            await family.stop()
            let records = try await trace.records()
            #expect(PaneContextPopoverTraceFixture.count("publication", in: records) == 1)
            #expect(PaneContextPopoverTraceFixture.count("validation_publication", in: records) == 1)
            #expect(PaneContextPopoverTraceFixture.count("input_publication", in: records) == 1)
            #expect(PaneContextPopoverTraceFixture.count("projection", in: records) == 4)
            #expect(PaneContextPopoverTraceFixture.count("family_admission", in: records) == 4)
            #expect(PaneContextPopoverTraceFixture.count("equal", in: records) == 1)
            #expect(!String(describing: records).contains("Private frame"))
            try await trace.close()
        } catch {
            await family.stop()
            try? await trace.close()
            throw error
        }
    }
}

private enum PublicationProofFailure: Error { case notPublished, notEqual }
