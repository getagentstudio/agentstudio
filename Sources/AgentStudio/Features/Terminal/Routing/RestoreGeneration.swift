import Foundation

/// One cold-restored pane's restore-phase identity for this launch (SR6b;
/// Program Design item 13). Compared only for equality/dedup — never
/// ordered — so a plain allocator-issued counter is sufficient; it is not
/// tied to `ColdRestoreAttemptID` (Core), which identifies the zmx attach
/// attempt, not the activity-suppression phase.
package struct RestoreGeneration: Sendable, Equatable, Hashable {
    package let rawValue: UInt64

    package init(rawValue: UInt64) {
        self.rawValue = rawValue
    }
}

/// The result of arming a cold pane's restore phase (SR6b; Program Design
/// item 13, choice 13's "Arming"). `.armed` covers both "the router was
/// already bound" and "the router bound while we waited" — activation never
/// proceeds to create the surface without one of those. `.projectorUnbound`
/// is reached only when the wait for the router's bound fact was cancelled
/// before binding ever happened.
package enum RestorePhaseArmAcknowledgment: Sendable, Equatable {
    case armed
    case projectorUnbound
}
