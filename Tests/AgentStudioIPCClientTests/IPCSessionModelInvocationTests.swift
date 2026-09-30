import AgentStudioIPCClientCore
import AgentStudioPrimitives
import AgentStudioProgrammaticControl
import Foundation
import Testing

@Suite("Session model invocations from the built-in catalog")
struct IPCSessionModelInvocationTests {
    @Test("the four model verbs resolve to their session descriptors and one-line replies")
    func modelVerbsResolveToSessionDescriptors() throws {
        let expectations = [
            ModelVerbExpectation(
                arguments: ["needs-you", "waiting on approval"],
                method: "session.report",
                variant: .needsYou,
                reply: "needs-you recorded",
                isOfflineEligible: true
            ),
            ModelVerbExpectation(
                arguments: ["needs-you", "--clear"],
                method: "session.report",
                variant: .needsYouClear,
                reply: "needs-you cleared",
                isOfflineEligible: false
            ),
            ModelVerbExpectation(
                arguments: ["done"],
                method: "session.report",
                variant: .done,
                reply: "done recorded",
                isOfflineEligible: true
            ),
            ModelVerbExpectation(
                arguments: ["message", "hello"],
                method: "session.message",
                variant: .message,
                reply: "message sent",
                isOfflineEligible: true
            ),
        ]

        for expectation in expectations {
            let invocation = try parse(expectation.arguments)
            #expect(invocation.descriptor.metadata.name == expectation.method)
            guard case .model(let presentation) = invocation.presentation else {
                Issue.record("\(expectation.arguments) did not resolve to a model invocation")
                continue
            }
            #expect(presentation.variant == expectation.variant)
            #expect(presentation.successReply == expectation.reply)
            #expect(presentation.isOfflineEligible == expectation.isOfflineEligible)
            #expect(presentation.showsDetail == false)
        }
    }

    @Test("a model verb carries its selector, scalar text and a generated correlation without a handle")
    func modelVerbsCarryScalarArgumentsAndGeneratedCorrelation() throws {
        let generated = UUIDv7.generate()
        let invocation = try parse(["needs-you", "waiting on approval"], correlationId: generated)
        let parameters = try JSONDecoder().decode(
            SessionReportInvocationEnvelope.self, from: invocation.normalizedParameters.data
        )

        #expect(parameters.kind == "needsYou")
        #expect(parameters.explanation == "waiting on approval")
        #expect(parameters.handle == "self")
        #expect(parameters.correlationId == generated)
    }

    @Test("an omitted needs-you explanation stays absent and message text stays required")
    func optionalAndRequiredScalarArgumentsAreEnforced() throws {
        let parameters = try JSONDecoder().decode(
            SessionReportInvocationEnvelope.self,
            from: try parse(["needs-you"]).normalizedParameters.data
        )
        #expect(parameters.explanation == nil)
        #expect(parameters.kind == "needsYou")

        #expect(throws: IPCDescriptorInvocationError.self) {
            _ = try parse(["message"])
        }
    }

    @Test("--detail requests the typed result without changing the resolved descriptor")
    func detailRequestsTypedResult() throws {
        let invocation = try parse(["done", "--detail"])

        guard case .model(let presentation) = invocation.presentation else {
            Issue.record("done did not resolve to a model invocation")
            return
        }
        #expect(presentation.showsDetail)
        #expect(invocation.descriptor.metadata.name == "session.report")
    }

    private func parse(
        _ arguments: [String],
        correlationId: UUID = UUIDv7.generate()
    ) throws -> IPCDescriptorInvocation {
        try IPCDescriptorInvocationParser.parse(
            arguments,
            descriptors: try IPCBuiltInMethodCatalog(
                inputs: .init(
                    terminalWaitMaximumSeconds: 9,
                    relationships: .init(
                        paneFocus: .noInteractiveIdentity,
                        paneClose: .noInteractiveIdentity,
                        drawerToggle: .noInteractiveIdentity,
                        drawerAddPane: .noInteractiveIdentity,
                        bridgeDiffLoad: .noInteractiveIdentity,
                        bridgeFileViewOpen: .noInteractiveIdentity
                    ),
                    examples: .init(illustrativeIdentifier: UUIDv7.generate())
                )
            ).erasedDescriptors,
            correlationIDGenerator: { correlationId }
        )
    }
}

private struct ModelVerbExpectation {
    let arguments: [String]
    let method: String
    let variant: IPCModelCallVariant
    let reply: String
    let isOfflineEligible: Bool
}

private struct SessionReportInvocationEnvelope: Decodable {
    let handle: String
    let kind: String
    let explanation: String?
    let correlationId: UUID
}
