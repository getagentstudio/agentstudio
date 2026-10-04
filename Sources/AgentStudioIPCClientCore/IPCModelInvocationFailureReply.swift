import AgentStudioProgrammaticControl
import Foundation

/// One short line for a model call the app refused for a documented reason.
/// R-12 keeps a model reply to a single line, so a structured error envelope
/// never reaches a model that only typed `ask` or `line`. A reason with
/// no line here falls back to the ordinary structured presentation, because
/// inventing prose for an undocumented reason would be a guess.
package enum IPCModelInvocationFailureReply {
    package static func line(forDocumentedReason documentedReason: String?) -> String? {
        switch documentedReason {
        case IPCSessionFailureReason.bindingRequired:
            "No agent session is bound to this pane; install the Agent Studio hooks for your provider."
        default:
            nil
        }
    }
}
