import AgentStudioIPCClientCore
import AgentStudioProgrammaticControl
import Foundation
import Testing

@Suite("Model invocation failure replies")
struct IPCModelInvocationFailureReplyTests {
    @Test("an unbound pane answers a deliberate verb in one line")
    func bindingRequiredAnswersInOneLine() {
        let reply = IPCModelInvocationFailureReply.line(
            forDocumentedReason: IPCSessionFailureReason.bindingRequired
        )

        #expect(
            reply == "No agent session is bound to this pane; install the Agent Studio hooks for your provider."
        )
        #expect(reply?.contains("\n") == false)
    }

    @Test("an undocumented reason keeps the structured presentation")
    func undocumentedReasonsFallBackToStructuredOutput() {
        #expect(IPCModelInvocationFailureReply.line(forDocumentedReason: nil) == nil)
        #expect(IPCModelInvocationFailureReply.line(forDocumentedReason: "targetNotFound") == nil)
        #expect(
            IPCModelInvocationFailureReply.line(
                forDocumentedReason: IPCSessionFailureReason.correlationConflict
            ) == nil
        )
    }

    @Test("the reply reason matches a reason the session descriptors declare")
    func replyReasonIsDeclaredBySessionDescriptors() throws {
        let catalog = try IPCBuiltInMethodCatalog(
            inputs: .init(
                relationships: .init(
                    paneFocus: .noInteractiveIdentity,
                    paneClose: .noInteractiveIdentity,
                    drawerToggle: .noInteractiveIdentity,
                    drawerAddPane: .noInteractiveIdentity,
                    bridgeDiffLoad: .noInteractiveIdentity,
                    bridgeFileViewOpen: .noInteractiveIdentity
                ),
                examples: .init(illustrativeIdentifier: UUID())
            )
        )
        let reportErrors = catalog.sessions.sessionReport.documentedErrors.map(\.reason)

        #expect(reportErrors.contains(IPCSessionFailureReason.bindingRequired))
        #expect(reportErrors.contains(IPCSessionFailureReason.correlationConflict))
    }
}
