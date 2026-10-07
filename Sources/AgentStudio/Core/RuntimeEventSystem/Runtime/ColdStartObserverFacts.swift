import Foundation

/// Which callback actually ran `checkForSocketAndAdvance`'s mandatory check
/// -- the kqueue registration handler (A2's own confirmed-registration
/// guarantee) or an ordinary vnode write event. A real write event can mask
/// removal of the mandatory registration check (it reaches the same check
/// through a different door), so a test proving A2 needs to tell these
/// apart rather than observe only that the check ran at all.
package enum ColdStartSocketCheckTrigger: Equatable, Sendable {
    case registration
    case directoryEvent
}

/// What `settleFromSetsidWatch` did with one setsid-watch callback, decided
/// by its own `isSettled`/`hasBegunHandoffWatch` guard (A3). `ignoredAsStale`
/// is the closing fact a negative proof needs: without it, "nothing changed
/// after the stale callback" is indistinguishable from "nothing has run yet".
package enum ColdStartSetsidSettlementDisposition: Equatable, Sendable {
    case applied
    case ignoredAsStale
}

/// Synchronous observations of one `ColdStartObserver` attempt's own
/// register-then-check guards, never a bus event. One observer per attempt
/// (`observeColdStart` may be called exactly once), so no correlation scope
/// is needed here the way `TerminalActivityProjectorFact` needs one across
/// concurrently open panes.
package enum ColdStartObserverFact: Equatable, Sendable {
    case socketCheckRan(ColdStartSocketCheckTrigger)
    case setsidSettlementProcessed(ColdStartSetsidSettlementDisposition)
}

package typealias ColdStartObserverFactSink = @Sendable (ColdStartObserverFact) -> Void
