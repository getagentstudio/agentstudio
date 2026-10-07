import Foundation
import Testing

@testable import AgentStudioTerminal

/// SR2a; Program Design item 5: this suite proves the pure comparison only —
/// the detection half of the recreation check. Real zmx's own boundary
/// behavior (a same-name daemon actually replaced between check and attach)
/// is proven separately, with real zmx, wherever this gets wired into the
/// live mount path.
@Suite("Pane recreation checker")
struct PaneRecreationCheckerTests {
    @Test("an unchanged identity reports unchanged, never a false recreation")
    func unchangedIdentityReportsUnchanged() {
        let identity = Data([1, 2, 3, 4])

        let result = PaneRecreationChecker.checkForRecreation(
            baselineIdentity: identity,
            observedIdentity: identity
        )

        #expect(result == .unchanged)
    }

    @Test("a different observed identity reports recreated -- the same-name-replacement case")
    func differentIdentityReportsRecreated() {
        let result = PaneRecreationChecker.checkForRecreation(
            baselineIdentity: Data([1, 2, 3, 4]),
            observedIdentity: Data([9, 9, 9, 9])
        )

        #expect(result == .recreated)
    }

    @Test("a missing baseline (an unverified pane never had one) reports couldNotCheck, never recreated")
    func missingBaselineReportsCouldNotCheck() {
        let result = PaneRecreationChecker.checkForRecreation(
            baselineIdentity: nil,
            observedIdentity: Data([1, 2, 3, 4])
        )

        #expect(result == .couldNotCheck)
    }

    @Test("a failed post-attach observation reports couldNotCheck, never recreated on mere absence of proof")
    func failedObservationReportsCouldNotCheck() {
        let result = PaneRecreationChecker.checkForRecreation(
            baselineIdentity: Data([1, 2, 3, 4]),
            observedIdentity: nil
        )

        #expect(result == .couldNotCheck)
    }

    @Test("both missing reports couldNotCheck")
    func bothMissingReportsCouldNotCheck() {
        let result = PaneRecreationChecker.checkForRecreation(
            baselineIdentity: nil,
            observedIdentity: nil
        )

        #expect(result == .couldNotCheck)
    }
}
