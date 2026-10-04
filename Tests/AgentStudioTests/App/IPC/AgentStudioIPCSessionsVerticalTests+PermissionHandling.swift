import AgentStudioAppIPC
import AgentStudioCore
import AgentStudioIPCTransport
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import AgentStudioSessions
import Foundation
import Testing

@testable import AgentStudio

extension AgentStudioIPCSessionsVerticalTests {
    @Test("blocking-ask permission admits activity once and only the open ask supplies approval attention")
    func blockingPermissionUsesAskAttention() async throws {
        try await withPermissionHarness { harness in
            let clock = try #require(harness.appDelegate.paneActivityClock)
            let composition = try #require(harness.appDelegate.appIPCSessionsPaneContextComposition)
            let paneId = PaneId(existingUUID: harness.boundPaneId)
            let conversation = "permission-\(harness.boundPaneId)"
            _ = try await harness.sessionEvent(
                paneId: paneId.uuid, provider: permissionTestProvider, name: "sessionStart",
                conversationId: conversation, authentication: .boundPane)
            let occurrence = UUIDv7.generate()
            let first = permissionParams(harness: harness, conversation: conversation, occurrence: occurrence)
            let admitted: IPCSessionEventResult = try await harness.decoded(
                method: "session.event", params: JSONRPCCodec.encodeJSONValue(first), authentication: .boundPane)
            #expect(admitted.disposition == .admitted)
            #expect(try await clock.settled() == .quiescent)
            let activity = harness.appDelegate.atomStore.core.paneActivityTime
            let firstTime = try #require(activity.value(for: paneId.uuid))
            let firstRevision = activity.revision(for: paneId.uuid)
            let beforeAsk = try await permissionDetail(harness)
            #expect(beforeAsk.session?.providerPrompts.isEmpty == true)
            #expect(beforeAsk.session?.status == .unknown)

            let replay = permissionParams(harness: harness, conversation: conversation, occurrence: occurrence)
            let replayed: IPCSessionEventResult = try await harness.decoded(
                method: "session.event", params: JSONRPCCodec.encodeJSONValue(replay), authentication: .boundPane)
            #expect(replayed.disposition == .admitted)
            #expect(try await clock.settled() == .quiescent)
            #expect(activity.value(for: paneId.uuid) == firstTime)
            #expect(activity.revision(for: paneId.uuid) == firstRevision)
            let snapshot = try await harness.paneSnapshot(paneId: paneId.uuid)
            let binding = try #require(snapshot.currentBinding)
            let askId = AgentMessageId.generateUUIDv7()
            let writer = AgentMessageSender.session(
                provider: try BridgeAgentProviderName(binding.providerIdentifier),
                sessionRef: try BridgeAgentSessionRef(binding.providerConversationId),
                bindingGeneration: binding.bindingGenerationId)
            let sent = await composition.paneContextService.send(
                .init(
                    paneId: paneId, messageId: askId, sender: writer, sourceOccurredAt: nil,
                    importance: .attention, body: "Approve this permission", why: nil, actions: [],
                    shape: .ask(reason: .approval, form: .freeText(placeholder: nil), waiting: .nonBlocking)))
            #expect(sent == .created(askId))
            let withAsk = try await permissionDetail(harness)
            #expect(withAsk.session?.status == .needsYou(reason: .approval))
            #expect(withAsk.session?.providerPrompts.isEmpty == true)
            let dismissed = await composition.paneContextService.dismiss(messageId: askId, paneId: paneId)
            #expect(dismissed == .done)
            let afterAsk = try await permissionDetail(harness)
            #expect(afterAsk.session?.status == .unknown)
            #expect(afterAsk.session?.providerPrompts.isEmpty == true)
            #expect(try await clock.settled() == .quiescent)
            #expect(activity.revision(for: paneId.uuid) == firstRevision)
        }
    }

    @Test("absent and explicit reportOnly permissions retain their provider prompt", arguments: [false, true])
    func reportOnlyPermissionRetainsPrompt(explicit: Bool) async throws {
        try await withPermissionHarness { harness in
            let conversation = "report-only-\(harness.boundPaneId)"
            _ = try await harness.sessionEvent(
                paneId: harness.boundPaneId, provider: permissionTestProvider, name: "sessionStart",
                conversationId: conversation)
            let occurrence = UUIDv7.generate()
            let params = permissionParams(
                harness: harness, conversation: conversation, occurrence: occurrence,
                handling: explicit ? .reportOnly : nil)
            let first: IPCSessionEventResult = try await harness.decoded(
                method: "session.event", params: JSONRPCCodec.encodeJSONValue(params), authentication: .boundPane)
            #expect(first.disposition == .admitted)
            let detail = try await permissionDetail(harness)
            #expect(detail.session?.status == .needsYou(reason: .approval))
            #expect(detail.session?.providerPrompts.count == 1)
            let equivalent = permissionParams(
                harness: harness, conversation: conversation, occurrence: occurrence,
                handling: explicit ? nil : .reportOnly)
            let replay: IPCSessionEventResult = try await harness.decoded(
                method: "session.event", params: JSONRPCCodec.encodeJSONValue(equivalent), authentication: .boundPane)
            #expect(replay.disposition == .admitted)
            let after = try await permissionDetail(harness)
            #expect(after.session == detail.session)
        }
    }

    @Test("permission handling on another event is invalidParams and changed occurrence handling conflicts")
    func permissionHandlingIsValidatedAndFingerprinted() async throws {
        try await withPermissionHarness { harness in
            let conversation = "validation-\(harness.boundPaneId)"
            let invalid = permissionParams(
                harness: harness, conversation: conversation, occurrence: UUIDv7.generate(), name: .sessionStart)
            let refused = try await harness.response(
                method: "session.event", params: JSONRPCCodec.encodeJSONValue(invalid), authentication: .boundPane)
            #expect(refused.error?.code == -32_602)
            guard case .object(let refusalData)? = refused.error?.data else {
                Issue.record("Expected invalidParams details")
                return
            }
            #expect(refusalData["reason"] == .string("invalidParams"))
            #expect(try await harness.sessionQuery(paneId: harness.boundPaneId).sourceHealth == .unbound)
            _ = try await harness.sessionEvent(
                paneId: harness.boundPaneId, provider: permissionTestProvider, name: "sessionStart",
                conversationId: conversation)
            let occurrence = UUIDv7.generate()
            let first = permissionParams(harness: harness, conversation: conversation, occurrence: occurrence)
            let admitted: IPCSessionEventResult = try await harness.decoded(
                method: "session.event", params: JSONRPCCodec.encodeJSONValue(first), authentication: .boundPane)
            #expect(admitted.disposition == .admitted)
            let changed = permissionParams(
                harness: harness, conversation: conversation, occurrence: occurrence, handling: .reportOnly)
            let conflict = try await harness.response(
                method: "session.event", params: JSONRPCCodec.encodeJSONValue(changed), authentication: .boundPane)
            #expect(conflict.error?.code == -32_007)
            guard case .object(let conflictData)? = conflict.error?.data else {
                Issue.record("Expected occurrence conflict details")
                return
            }
            #expect(conflictData["reason"] == .string(IPCSessionFailureReason.correlationConflict))
            let detail = try await permissionDetail(harness)
            #expect(detail.session?.providerPrompts.isEmpty == true)
        }
    }
}

@MainActor
private let permissionTestProvider = SessionsVerticalHarness.qualifiedProvider

@MainActor
private func withPermissionHarness(
    operation: @MainActor (SessionsVerticalHarness) async throws -> Void
) async throws {
    let profile = SessionsProviderProfile(
        providerIdentifier: permissionTestProvider.identifier, exactVersion: permissionTestProvider.version,
        operatingMode: permissionTestProvider.mode, qualifiedCapabilities: [.sessionStart, .permission])
    let harness = try await SessionsVerticalHarness.make(providerProfiles: [profile], installActivityClock: true)
    do {
        try await operation(harness)
        await harness.tearDown()
    } catch {
        await harness.tearDown()
        throw error
    }
}

@MainActor
private func permissionParams(
    harness: SessionsVerticalHarness, conversation: String, occurrence: UUID,
    handling: IPCSessionPermissionHandling? = .blockingAsk, name: IPCSessionEventName = .permission
) -> IPCSessionEventParams {
    .init(
        handle: "self", provider: permissionTestProvider,
        event: .init(
            name: name, conversationId: conversation, turnId: nil, requestId: nil,
            toolId: nil, subagentId: nil, occurrenceId: occurrence),
        correlationId: UUIDv7.generate(), permissionHandling: handling)
}

@MainActor
private func permissionDetail(_ harness: SessionsVerticalHarness) async throws -> IPCPaneContextGetResult {
    try await harness.decoded(
        method: "pane.context.get",
        params: JSONRPCCodec.encodeJSONValue(IPCPaneContextGetParams(handle: "self", page: .first)),
        authentication: .boundPane)
}
