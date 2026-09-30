import Foundation

/// Where pane-agent authorization reports how long each decision took, from
/// the first eligibility check through the own-pane lookup to the outcome.
/// Called once per request that reaches a decision, from the authorizing task
/// rather than the main actor.
package protocol AppIPCAgentAuthorizationTelemetry: Sendable {
    func recordAgentAuthorization(elapsed: Duration, outcome: AppIPCAgentAuthorizationOutcome)
}

/// How pane-agent authorization decided one request. The raw values are the
/// marker's controlled vocabulary.
package enum AppIPCAgentAuthorizationOutcome: String, Equatable, Sendable {
    case authorized
    case notYetAllowed = "not_yet_allowed"
    case refusedForAgent = "refused_for_agent"
}
