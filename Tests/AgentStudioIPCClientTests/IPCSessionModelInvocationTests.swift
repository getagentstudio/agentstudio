import AgentStudioPrimitives
import AgentStudioProgrammaticControl
import Foundation
import Testing

@testable import AgentStudioIPCClientCore

@Suite("IPC pane CLI invocations")
struct IPCSessionModelInvocationTests {
    @Test("the eight pane verbs select compiled owners without discovery", arguments: IPCModelCallVariant.allCases)
    func modelVerbsResolveToTheirDescriptors(verb: IPCModelCallVariant) throws {
        let inputs = IPCBuiltInMethodCatalogInputs(examples: .init(illustrativeIdentifier: UUIDv7.generate()))
        let descriptors = try IPCCompiledInvocationResolver().resolve(
            arguments: [verb.rawValue], authenticated: true, inputs: inputs)
        let expected: [String] =
            switch verb {
            case .notify, .ask: ["auth.login", "pane.message.send"]
            case .approval: ["auth.login", "pane.message.ask"]
            case .withdraw: ["auth.login", "pane.message.withdraw"]
            case .answers: ["auth.login", "pane.message.changes"]
            case .line: ["auth.login", "pane.writer.claimEpoch", "pane.line.set"]
            case .title: ["auth.login", "pane.writer.claimEpoch", "pane.title.set"]
            case .pane: ["auth.login", "pane.context.get"]
            }
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

    @Test("missing text, a timeout without wait and conflicting clear or reset forms are refused")
    func omittedRequiredArgumentsAreRefused() {
        for arguments in [
            ["notify"], ["ask", "Q", "--timeout", "30"], ["line", "X", "--clear"],
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

    @Test("Approval always waits on pane.message.ask with its closed form and timeout")
    func approvalUsesItsDeclaredContract() throws {
        let now = Date(timeIntervalSince1970: 1)
        for timeout in [Optional<String>.none, "30"] {
            let arguments = ["approval", "Approve migration?"] + (timeout.map { ["--timeout", $0] } ?? [])
            let descriptors = try IPCCompiledInvocationResolver().resolve(
                arguments: arguments, authenticated: true,
                inputs: .init(examples: .init(illustrativeIdentifier: UUIDv7.generate())))
            #expect(descriptors.map { $0.metadata.name } == ["auth.login", "pane.message.ask"])
            let intent = try PaneCLIIntent.parse(arguments, now: now)
            guard case .ask(let draft) = intent else {
                Issue.record("Approval must use the ask owner")
                return
            }
            #expect(draft.form == .approval)
            #expect(draft.reason == .approval)
            #expect(draft.message.body == "Approve migration?")
            #expect(draft.message.createdAt == now)
            #expect(draft.timeout == (timeout == nil ? 60 : 30))
            #expect(intent.callLimit == (timeout == nil ? .seconds(62) : .seconds(32)))
        }
        for arguments in [["approval"], ["approval", "Q", "--wait"], ["approval", "Q", "--choice", "yes,no"]] {
            #expect(throws: AgentStudioIPCClientError.self) { try PaneCLIIntent.parse(arguments, now: now) }
        }
    }
}
