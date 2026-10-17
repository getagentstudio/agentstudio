import AgentStudioInfrastructure
import Foundation

/// Page policy delivered independently of the product session whose progress it bounds.
struct BridgePageConfiguration: Codable, Equatable, Sendable {
    let workerBootstrapDeadlineMilliseconds: Int
    let readyAcknowledgementDeadlineMilliseconds: Int

    static let live = Self(
        workerBootstrapDeadlineMilliseconds: Int(
            AppPolicies.Bridge.productPageBootstrapDeadline.components.seconds * 1000
                + AppPolicies.Bridge.productPageBootstrapDeadline.components.attoseconds / 1_000_000_000_000_000
        ),
        readyAcknowledgementDeadlineMilliseconds: Int(
            AppPolicies.Bridge.productPageReadyAcknowledgementDeadline.components.seconds * 1000
                + AppPolicies.Bridge.productPageReadyAcknowledgementDeadline.components.attoseconds
                / 1_000_000_000_000_000
        )
    )
}
