import Foundation

package struct BridgeDevelopmentProductHostFactScope: Hashable, Sendable {
    package let paneID: UUID

    package init(paneID: UUID) {
        self.paneID = paneID
    }
}

package enum BridgeDevelopmentProductHostFact: Equatable, Sendable {
    /// Product admission is closed and host-owned comparison work is cancelled.
    /// Physical drains may still be pending when this fact is emitted.
    case shutdownStarted
    case shutdownResolved(BridgeDevelopmentProductHostShutdownResult)
}

package typealias BridgeDevelopmentProductHostFactSink =
    @Sendable (BridgeDevelopmentProductHostFactScope, BridgeDevelopmentProductHostFact) -> Void
