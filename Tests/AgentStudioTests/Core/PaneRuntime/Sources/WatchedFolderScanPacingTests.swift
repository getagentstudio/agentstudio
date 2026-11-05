import Foundation
import Testing

@testable import AgentStudioCore
@testable import AgentStudioInfrastructure

@Suite("Watched folder scan pacing")
struct WatchedFolderScanPacingTests {
    @Test("quiet eligibility follows the latest trigger by two seconds")
    func quietEligibilityFollowsLatestTrigger() {
        // Arrange
        let sourceID = makeSourceID()
        var pacing = WatchedFolderScanPacing()
        // Act / Assert: literal owner values, not constants read from the subject.
        _ = pacing.recordTrigger(sourceID, reason: .relevantChange, at: .zero)
        #expect(pacing.decision(at: .zero) == .wait(until: .seconds(2)))
        #expect(pacing.decision(at: .milliseconds(1999)) == .wait(until: .seconds(2)))
        #expect(pacing.decision(at: .seconds(2)) == .submit([(sourceID, coveredRevision: UInt64(1))]))
        _ = pacing.recordTrigger(sourceID, reason: .relevantChange, at: .milliseconds(1500))
        #expect(pacing.decision(at: .seconds(2)) == .wait(until: .milliseconds(3500)))
        #expect(pacing.decision(at: .milliseconds(3500)) == .submit([(sourceID, coveredRevision: UInt64(2))]))
    }

    @Test("many drains retain one obligation and one pending interval")
    func manyTriggersRetainOneObligation() {
        // Arrange
        let sourceID = makeSourceID()
        var pacing = WatchedFolderScanPacing()
        // Act
        for index in 0..<50 {
            _ = pacing.recordTrigger(sourceID, reason: .relevantChange, at: .milliseconds(index * 10))
            if index.isMultiple(of: 5) { _ = pacing.decision(at: .milliseconds(index * 10)) }
        }
        // Assert
        #expect(pacing.obligationsBySourceID.count == 1)
        #expect(pacing.obligationsBySourceID[sourceID]?.pendingInterval?.foldedTriggerCount == 50)
        pacing.reserveSubmission(sourceID, sequence: 1, cause: .callback, at: .seconds(3))
        pacing.recordAccepted(
            sourceID, coveredRevision: 50, coverage: coverage(sourceID, generation: 1), at: .seconds(3))
        #expect(pacing.obligationsBySourceID.count == 1)
        _ = pacing.recordTrigger(sourceID, reason: .nativeCoverageLoss, at: .seconds(4))
        #expect(pacing.obligationsBySourceID[sourceID]?.pendingInterval?.triggerRevision == 51)
        #expect(pacing.decision(at: .seconds(4)) == .wait(until: .seconds(6)))
    }

    @Test("a sustained minute becomes eligible at ten seconds of oldest unserved age")
    func sustainedBurstHonorsMaximumWait() {
        // Arrange
        let sourceID = makeSourceID()
        var pacing = WatchedFolderScanPacing()
        var sequence: UInt64 = 0
        var oldestUnserved = 0
        // Act / Assert: acceptance does not complete runs, so this stays one obligation.
        for second in 0..<60 {
            _ = pacing.recordTrigger(sourceID, reason: .relevantChange, at: .seconds(second))
            if case .submit = pacing.decision(at: .seconds(second)) {
                #expect(second - oldestUnserved == 10)
                sequence += 1
                pacing.reserveSubmission(sourceID, sequence: sequence, cause: .callback, at: .seconds(second))
                pacing.recordAccepted(
                    sourceID, coveredRevision: UInt64(second + 1), coverage: coverage(sourceID, generation: sequence),
                    at: .seconds(second))
                oldestUnserved = second + 1
            }
        }
        #expect(sequence == 5)
        #expect(pacing.obligationsBySourceID.count == 1)
        #expect(pacing.decision(at: .seconds(61)) == .submit([(sourceID, coveredRevision: UInt64(60))]))
        #expect(sequence + 1 <= 7)
    }

    @Test("acceptance and older completion cannot close later triggers")
    func completionMustCoverLatestTriggerAndDemand() {
        // Arrange
        let sourceID = makeSourceID()
        var pacing = WatchedFolderScanPacing()
        _ = pacing.recordTrigger(sourceID, reason: .relevantChange, at: .zero)
        pacing.reserveSubmission(sourceID, sequence: 1, cause: .callback, at: .seconds(2))
        let firstCoverage = coverage(sourceID, generation: 1)
        pacing.recordAccepted(sourceID, coveredRevision: 1, coverage: firstCoverage, at: .seconds(2))
        #expect(pacing.obligationsBySourceID.count == 1)
        // Act / Assert
        _ = pacing.recordTrigger(sourceID, reason: .intakeCoverageLoss, at: .seconds(3))
        #expect(pacing.recordRunCompleted(sourceID, coverage: firstCoverage) == .notCovered)
        pacing.reserveSubmission(sourceID, sequence: 2, cause: .callback, at: .seconds(5))
        let nextCoverage = coverage(sourceID, generation: 2)
        pacing.recordAccepted(sourceID, coveredRevision: 2, coverage: nextCoverage, at: .seconds(5))
        #expect(pacing.recordRunCompleted(sourceID, coverage: firstCoverage) == .notCovered)
        #expect(pacing.recordRunCompleted(sourceID, coverage: nextCoverage) == .closed)
        #expect(pacing.recordRunCompleted(sourceID, coverage: nextCoverage) == .notCovered)
        #expect(pacing.obligationsBySourceID.isEmpty)
    }

    @Test("retiring a folder drops its open obligation")
    func retirementDropsOpenObligation() {
        let sourceID = makeSourceID()
        var pacing = WatchedFolderScanPacing()
        _ = pacing.recordTrigger(sourceID, reason: .nativeCoverageLoss, at: .zero)
        pacing.removeFolder(sourceID)
        #expect(pacing.decision(at: .seconds(20)) == .idle)
        #expect(pacing.obligationsBySourceID.isEmpty)
    }

    @Test("seeded trigger traces stay within the recorded span and quiet-gap bound")
    func seededTracesRespectRunBound() {
        // Arrange: deterministic event times; completed work stays real in the pure reducer.
        var seed: UInt64 = 0x581
        for _ in 0..<32 {
            let sourceID = makeSourceID()
            var pacing = WatchedFolderScanPacing()
            var triggerMilliseconds = [0]
            for _ in 0..<100 {
                seed = seed &* 6_364_136_223_846_793_005 &+ 1
                triggerMilliseconds.append((triggerMilliseconds.last ?? 0) + Int((seed >> 32) % 4000 + 1))
            }
            var sequence: UInt64 = 0
            func drain(through limit: Duration) {
                var decision = pacing.decision(at: limit)
                while case .submit = decision {
                    sequence += 1
                    pacing.reserveSubmission(sourceID, sequence: sequence, cause: .callback, at: limit)
                    let acceptedCoverage = coverage(sourceID, generation: sequence)
                    pacing.recordAccepted(
                        sourceID, coveredRevision: pacing.triggerRevisionBySourceID[sourceID] ?? 0,
                        coverage: acceptedCoverage, at: limit)
                    #expect(pacing.recordRunCompleted(sourceID, coverage: acceptedCoverage) == .closed)
                    decision = pacing.decision(at: limit)
                }
            }
            // Act: service each eligibility deadline before the next trigger.
            for milliseconds in triggerMilliseconds {
                if case .wait(let deadline) = pacing.decision(at: .zero), deadline <= .milliseconds(milliseconds) {
                    drain(through: deadline)
                }
                _ = pacing.recordTrigger(sourceID, reason: .relevantChange, at: .milliseconds(milliseconds))
                drain(through: .milliseconds(milliseconds))
            }
            drain(through: .milliseconds((triggerMilliseconds.last ?? 0) + 2000))
            // Assert: independent literal formula from the Specification.
            let gaps = zip(triggerMilliseconds, triggerMilliseconds.dropFirst()).filter { $1 - $0 >= 2000 }.count
            let span = (triggerMilliseconds.last ?? 0) - (triggerMilliseconds.first ?? 0)
            #expect(sequence <= UInt64(1 + gaps + (span + 9999) / 10_000))
        }
    }

    private func makeSourceID() -> FilesystemSourceID {
        .init(kind: .watchedParentMembership, rootID: UUIDv7.generate())
    }

    private func coverage(_ sourceID: FilesystemSourceID, generation: UInt64) -> WatchedFolderScanDemandCoverage {
        .init(
            registration: .init(sourceID: sourceID, registrationGeneration: 1, rootGeneration: 1),
            throughDemandGeneration: .init(rawValue: generation))
    }
}
