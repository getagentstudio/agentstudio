import AgentStudioCore
import AgentStudioIPCClientCore
import AgentStudioIPCTransport
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import AgentStudioSessions
import AgentStudioTestHarness
import AgentStudioTestSupport
import Foundation
import Synchronization
import Testing

@testable import AgentStudio

@Suite("Provider permission hook real socket and person actions", .serialized)
struct ProviderPermissionHookIntegrationTests {
    @Test("Human Allow, Deny and Ask reach the waiting provider hook", arguments: PermissionHookTestProvider.allCases)
    func personDecisionsReachHook(provider: PermissionHookTestProvider) async throws {
        try await withPermissionHookTestContext(provider: provider) { context in
            let recorder = try context.domain.facts.attach()
            var messageIds = Set<AgentMessageId>()
            for choice in ["Allow", "Deny", "Ask"] {
                let pending = context.startHook()
                try await recorder.expectNext(in: context.domain.paneId, .openAskCount(1))
                let message = try await context.openApproval()
                #expect(messageIds.insert(message.id).inserted)
                #expect(message.body.contains("tool-proof"))
                #expect(message.body.contains("operation-proof"))
                #expect(context.port.asks.last?.writer?.conversationId == context.conversationId)
                #expect(context.port.asks.last?.writer?.provider == provider.identifier)
                #expect(
                    await context.uiAdapter.answer(
                        .init(
                            messageId: message.id, paneId: context.paneId, by: .localUser,
                            value: .choices([try AskChoiceId(choice)]))) == .answered)
                try await recorder.expectNext(in: context.domain.paneId, .openAskCount(0))
                try await recorder.expectNext(in: context.domain.paneId, .clientExited)
                let output = await pending.value
                #expect(output.exitCode == 0)
                #expect(output.standardError.isEmpty)
                switch choice {
                case "Allow": #expect(try context.decision(in: output)?.behavior == "allow")
                case "Deny":
                    let decision = try #require(try context.decision(in: output))
                    #expect(decision.behavior == "deny")
                    #expect(decision.message == "The person denied this permission request.")
                default: #expect(output.standardOutput.isEmpty)
                }
            }
            // Identical tool inputs in one provider turn received three separate human decisions.
            #expect(messageIds.count == 3)
            #expect(context.port.asks.count == 3)
            try await recorder.finish()
        }
    }

    @Test("Dismissing hands back; withdrawing never grants", arguments: PermissionHookTestProvider.allCases)
    func dismissAndWithdrawNeverGrant(provider: PermissionHookTestProvider) async throws {
        try await withPermissionHookTestContext(provider: provider) { context in
            let recorder = try context.domain.facts.attach()
            let dismissing = context.startHook()
            try await recorder.expectNext(in: context.domain.paneId, .openAskCount(1))
            let first = try await context.openApproval()
            #expect(await context.uiAdapter.dismiss(messageId: first.id, paneId: context.paneId) == .done)
            try await recorder.expectNext(in: context.domain.paneId, .openAskCount(0))
            try await recorder.expectNext(in: context.domain.paneId, .clientExited)
            #expect(await dismissing.value.standardOutput.isEmpty)
            #expect(
                await context.domain.service.waitForAskOutcome(messageId: first.id, paneId: context.paneId)
                    == .handedBack)
            let withdrawing = context.startHook()
            try await recorder.expectNext(in: context.domain.paneId, .openAskCount(1))
            let second = try await context.openApproval()
            #expect(
                await context.domain.service.withdraw(
                    messageId: second.id, paneId: context.paneId, writer: second.sender) == .withdrawn)
            try await recorder.expectNext(in: context.domain.paneId, .openAskCount(0))
            try await recorder.expectNext(in: context.domain.paneId, .clientExited)
            #expect(await withdrawing.value.standardOutput.isEmpty)
            try await recorder.finish()
        }
    }

    @Test(
        "Controlled deadline expiry and late human Allow yield no hook grant",
        arguments: PermissionHookTestProvider.allCases)
    func expiryRejectsLateAllow(provider: PermissionHookTestProvider) async throws {
        try await withPermissionHookTestContext(provider: provider) { context in
            let recorder = try context.domain.facts.attach()
            let pending = context.startHook()
            try await recorder.expectNext(in: context.domain.paneId, .openAskCount(1))
            let message = try await context.openApproval()
            // The real scheduler announces when the expiry deadline is installed.
            await context.domain.clock.waitForPendingSleepCount(atLeast: 1)
            context.domain.clock.advance(by: .seconds(61))
            try await recorder.expectNext(in: context.domain.paneId, .openAskCount(0))
            #expect(
                await context.uiAdapter.answer(
                    .init(
                        messageId: message.id, paneId: context.paneId, by: .localUser,
                        value: .choices([try AskChoiceId("Allow")]))) == .refused(.expired))
            try await recorder.expectNext(in: context.domain.paneId, .clientExited)
            #expect(await pending.value.standardOutput.isEmpty)
            try await recorder.finish()
        }
    }

    @Test(
        "Real commit failure produces no grant or provider stream diagnostics",
        arguments: PermissionHookTestProvider.allCases)
    func storageFailureNeverGrants(provider: PermissionHookTestProvider) async throws {
        try await withPermissionHookTestContext(provider: provider) { context in
            let recorder = try context.domain.facts.attach()
            let held = HeldStep<Void>("permission ask before real commit", cancellation: .holdThroughCancellation)
            context.domain.access.holdNextWrite(
                before: held,
                beforeWriteReached: {
                    context.domain.facts.sink(context.domain.paneId, .writeAdmissionReached)
                })
            let pending = context.startHook()
            try await recorder.expectNext(in: context.domain.paneId, .writeAdmissionReached)
            try await held.firstArrival()
            held.fail(PermissionHookStorageTestFailure())
            try await recorder.expectNext(in: context.domain.paneId, .clientExited)
            let output = await pending.value
            #expect(output.exitCode == 0)
            #expect(output.standardOutput.isEmpty)
            #expect(output.standardError.isEmpty)
            try await recorder.finish()
        }
    }

    @Test(
        "Missing policy, malformed input and wrong credentials stay silent",
        arguments: PermissionHookTestProvider.allCases)
    func invocationFailuresNeverGrant(provider: PermissionHookTestProvider) async throws {
        try await withPermissionHookTestContext(provider: provider) { context in
            let recorder = try context.domain.facts.attach()
            for failure in PermissionHookTestFailure.allCases {
                let pending = context.startHook(failure: failure)
                try await recorder.expectNext(in: context.domain.paneId, .clientExited)
                let output = await pending.value
                #expect(output.exitCode == 0)
                #expect(output.standardOutput.isEmpty)
                #expect(output.standardError.isEmpty)
            }
            #expect(context.port.asks.isEmpty)
            try await recorder.finish()
        }
    }
}

private struct PermissionHookStorageTestFailure: Error {}

struct PermissionHookDecisionValue: Decodable {
    let behavior: String
    let message: String?
}
