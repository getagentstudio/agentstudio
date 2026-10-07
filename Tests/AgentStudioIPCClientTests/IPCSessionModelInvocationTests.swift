import AgentStudioPrimitives
import AgentStudioProgrammaticControl
import Foundation
import Testing

@testable import AgentStudioIPCClientCore

@Suite("IPC pane CLI invocations")
struct IPCSessionModelInvocationTests {
    @Test("the seven pane verbs select compiled owners without discovery", arguments: IPCModelCallVariant.allCases)
    func modelVerbsResolveToTheirDescriptors(verb: IPCModelCallVariant) throws {
        let inputs = IPCBuiltInMethodCatalogInputs(examples: .init(illustrativeIdentifier: UUIDv7.generate()))
        let descriptors = try IPCCompiledInvocationResolver().resolve(
            arguments: [verb.rawValue], authenticated: true, inputs: inputs)
        let expected =
            verb.ordered ? ["auth.login", "pane.writer.claimEpoch", verb.methodName] : ["auth.login", verb.methodName]
        #expect(descriptors.map { $0.metadata.name } == expected)
    }

    @Test("typed notice and ask drafts preserve exact text and distinguish their reason and form")
    func modelVerbCarriesItsDeclaredPayload() throws {
        let text = "exact 🧭 notice\nsecond line"
        let notice = try PaneCLIIntent.parse(["notify", text], now: Date(timeIntervalSince1970: 1))
        let ask = try PaneCLIIntent.parse(
            ["ask", text, "--reason", "blocked", "--choice", "allow,deny"], now: Date(timeIntervalSince1970: 1))
        guard case .notify(let draft) = notice, case .ask(let question) = ask else {
            Issue.record("Expected typed drafts")
            return
        }
        #expect(draft.body == text)
        #expect(question.message.body == text)
        #expect(question.reason == .blocked)
        #expect(
            question.form
                == .choice(
                    options: [.init(id: "allow", label: "allow"), .init(id: "deny", label: "deny")],
                    allowsMultiple: false))
        #expect(question.timeout == nil)
    }

    @Test("missing text, a timeout without wait and conflicting work declarations are refused")
    func omittedRequiredArgumentsAreRefused() {
        for arguments in [
            ["notify"], ["ask", "Q", "--timeout", "30"], ["line", "X", "--done", "--working"],
            ["title", "X", "--reset"],
        ] {
            #expect(throws: AgentStudioIPCClientError.self) {
                try PaneCLIIntent.parse(arguments, now: Date(timeIntervalSince1970: 1))
            }
        }
    }

    @Test("waiting changes the compiled owner and shares the timeout plus reply margin")
    func blockingAskUsesItsDeclaredLifetime() throws {
        let inputs = IPCBuiltInMethodCatalogInputs(examples: .init(illustrativeIdentifier: UUIDv7.generate()))
        let arguments = ["ask", "Proceed?", "--wait", "--timeout", "30"]
        let descriptors = try IPCCompiledInvocationResolver().resolve(
            arguments: arguments, authenticated: true, inputs: inputs)
        let intent = try PaneCLIIntent.parse(arguments, now: Date(timeIntervalSince1970: 1))
        #expect(descriptors.map { $0.metadata.name } == ["auth.login", "pane.message.ask"])
        #expect(intent.callLimit == .seconds(32))
    }
}
