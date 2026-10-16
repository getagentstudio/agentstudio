import Foundation
import Testing

@testable import AgentStudioCore

@Suite("Repository retention policy")
struct RepositoryRetentionPolicyTests {
    private let start = RepositoryRetentionTime(
        utc: Date(timeIntervalSince1970: 1_700_000_000),
        bootID: "fixture-boot",
        uptimeNanoseconds: 1_000_000_000
    )

    @Test("repeated authoritative absence preserves the original retention interval")
    func repeatedAbsencePreservesFirstObservation() throws {
        let first = try #require(RepositoryRetentionPolicy.confirmedAbsence(retaining: nil, at: start))
        let later = time(after: 10 * 86_400)

        let repeated = RepositoryRetentionPolicy.confirmedAbsence(retaining: first, at: later)

        #expect(repeated == first)
        #expect(!RepositoryRetentionPolicy.isDue(first, at: later))
        #expect(RepositoryRetentionPolicy.isDue(first, at: time(after: 30 * 86_400)))
    }

    @Test("an unconfirmed legacy marker has no collection deadline")
    func legacyAbsenceCannotInventAge() throws {
        #expect(!RepositoryRetentionPolicy.isDue(.unconfirmed, at: time(after: 100 * 86_400)))
        let confirmed = try #require(
            RepositoryRetentionPolicy.confirmedAbsence(retaining: .unconfirmed, at: time(after: 100 * 86_400))
        )
        #expect(!RepositoryRetentionPolicy.isDue(confirmed, at: time(after: 100 * 86_400)))
    }

    @Test("wall clock jumps during the same boot cannot accelerate collection")
    func sameBootUsesContinuousTime() throws {
        let absence = try #require(RepositoryRetentionPolicy.confirmedAbsence(retaining: nil, at: start))
        let jumped = RepositoryRetentionTime(
            utc: start.utc.addingTimeInterval(365 * 86_400),
            bootID: start.bootID,
            uptimeNanoseconds: start.uptimeNanoseconds + 1_000_000_000
        )
        #expect(RepositoryRetentionPolicy.elapsedSeconds(for: absence, at: jumped) == 1)
        #expect(!RepositoryRetentionPolicy.isDue(absence, at: jumped))
    }

    @Test("backward reboot time and invalid uptime defer collection")
    func invalidClockDefersCollection() throws {
        let absence = try #require(RepositoryRetentionPolicy.confirmedAbsence(retaining: nil, at: start))
        let reboot = RepositoryRetentionTime(
            utc: start.utc.addingTimeInterval(-1), bootID: "new-boot", uptimeNanoseconds: 0
        )
        #expect(RepositoryRetentionPolicy.elapsedSeconds(for: absence, at: reboot) == nil)
        let invalid = RepositoryRetentionTime(utc: start.utc, bootID: start.bootID, uptimeNanoseconds: -1)
        #expect(!RepositoryRetentionPolicy.isDue(absence, at: invalid))
    }

    @Test("confirmed absence survives Codable round trip without resetting its age")
    func persistedAbsencePreservesDeadline() throws {
        let absence = try #require(RepositoryRetentionPolicy.confirmedAbsence(retaining: nil, at: start))
        let restored = try JSONDecoder().decode(
            RepositoryLocationAbsence.self, from: JSONEncoder().encode(absence)
        )
        #expect(restored == absence)
        #expect(!RepositoryRetentionPolicy.isDue(restored, at: time(after: 30 * 86_400 - 1)))
        #expect(RepositoryRetentionPolicy.isDue(restored, at: time(after: 30 * 86_400)))
    }

    @Test("a confirmed observation after reboot prevents later wall jumps from adding age")
    func rebootAnchorIgnoresLaterWallClockJump() throws {
        let absence = try #require(RepositoryRetentionPolicy.confirmedAbsence(retaining: nil, at: start))
        let reboot = RepositoryRetentionTime(
            utc: start.utc.addingTimeInterval(25 * 86_400), bootID: "new-boot", uptimeNanoseconds: 1_000_000_000
        )
        let reanchored = try #require(RepositoryRetentionPolicy.confirmedAbsence(retaining: absence, at: reboot))
        let jumped = RepositoryRetentionTime(
            utc: reboot.utc.addingTimeInterval(365 * 86_400), bootID: reboot.bootID,
            uptimeNanoseconds: reboot.uptimeNanoseconds + 1_000_000_000
        )

        let elapsed = try #require(RepositoryRetentionPolicy.elapsedSeconds(for: reanchored, at: jumped))
        #expect(elapsed == TimeInterval(25 * 86_400 + 1))
        #expect(!RepositoryRetentionPolicy.isDue(reanchored, at: jumped))
        guard case .confirmed(let timing) = reanchored else {
            Issue.record("Reanchored absence did not remain confirmed")
            return
        }
        #expect(timing.firstAbsentAt == start.utc)
    }

    private func time(after seconds: Int64) -> RepositoryRetentionTime {
        RepositoryRetentionTime(
            utc: start.utc.addingTimeInterval(Double(seconds)),
            bootID: start.bootID,
            uptimeNanoseconds: start.uptimeNanoseconds + seconds * 1_000_000_000
        )
    }
}
