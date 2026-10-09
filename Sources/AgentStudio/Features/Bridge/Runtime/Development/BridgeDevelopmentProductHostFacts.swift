import Foundation

package struct BridgeDevelopmentProductHostFactScope: Hashable, Sendable {
    package let paneID: UUID

    package init(paneID: UUID) {
        self.paneID = paneID
    }
}

package enum BridgeDevelopmentProductHostFact: Equatable, Sendable {
    case shutdownStarted
    case shutdownResolved(BridgeDevelopmentProductHostShutdownResult)
}

package typealias BridgeDevelopmentProductHostFactSink =
    @Sendable (BridgeDevelopmentProductHostFactScope, BridgeDevelopmentProductHostFact) -> Void
