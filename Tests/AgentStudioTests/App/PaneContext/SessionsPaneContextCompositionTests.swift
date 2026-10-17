import AgentStudioAppIPC
import AgentStudioCore
import AgentStudioIPCTransport
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioSessions

@MainActor
@Suite(
    "Sessions and PaneContext production composition", .serialized,
    SessionsVerticalHarnessTrait())
struct SessionsPaneContextCompositionTests {
    @Test("Boot connects real ask, line and session-end owners before admitting provider events")
    func bootCompositionConnectsSessionsAndPaneContext() async throws {
        let composition = try #require(
            SessionsVerticalHarnessContext.current?.harness.appDelegate.appIPCSessionsPaneContextComposition,
            "Boot did not construct the Sessions/PaneContext composition")
        let uiAdapter = try #require(
            SessionsVerticalHarnessContext.current?.harness.appDelegate.appIPCPaneContextUIAdapter,
            "Boot did not publish the lazy UI adapter after preparation")
        let fixture = try #require(SessionsVerticalHarnessContext.current)
        let harness = try await fixture.freshPanePair()
        let paneId = PaneId(existingUUID: harness.boundPaneId)
        let conversationId = UUIDv7.generate().uuidString
        #expect(
            try await harness.sessionEvent(
                paneId: paneId.uuid, provider: SessionsVerticalHarness.testProvider, name: "sessionStart",
                conversationId: conversationId
            ).disposition == .admitted)
        #expect(
            try await harness.sessionEvent(
                paneId: paneId.uuid, provider: SessionsVerticalHarness.testProvider, name: "turnStart",
                conversationId: conversationId
            ).disposition == .admitted)
        let binding = try #require(
            try await composition.ingestion.repository.statusContext(paneId: paneId.uuid)
                .currentBinding)
        let writer = AgentMessageSender.session(
            provider: try BridgeAgentProviderName(binding.providerIdentifier),
            sessionRef: try BridgeAgentSessionRef(binding.providerConversationId),
            bindingGeneration: binding.bindingGenerationId)
        let askId = AgentMessageId.generateUUIDv7()
        #expect(
            await composition.paneContextService.send(
                .init(
                    paneId: paneId, messageId: askId, sender: writer, sourceOccurredAt: nil, importance: .attention,
                    body: "Choose a response", why: nil, actions: [],
                    shape: .ask(reason: .question, form: .freeText(placeholder: nil), waiting: .nonBlocking)))
                == .created(askId))
        #expect(try await composition.ingestion.sessionSummary(paneId: paneId.uuid)?.status == .needsYou(.question))
        let uiRead = await uiAdapter.readDetail(.init(paneId: paneId, page: .first))
        let uiDetail: PaneContextDetail?
        if case .detail(let value) = uiRead { uiDetail = value } else { uiDetail = nil }
        #expect(try #require(uiDetail).messages.contains { $0.id == askId })
        #expect(await composition.paneContextService.dismiss(messageId: askId, paneId: paneId) == .done)
        let claim = await composition.paneContextService.claimEpoch(
            .init(paneId: paneId, writer: writer, stream: .line, claimId: UUIDv7.generate()))
        let claimedEpoch: UInt64?
        if case .claimed(let epoch) = claim { claimedEpoch = epoch } else { claimedEpoch = nil }
        let epoch = try #require(claimedEpoch)
        #expect(
            await composition.paneContextService.setLine(
                .init(
                    paneId: paneId, writer: writer,
                    line: .init(
                        summary: "Watching checks", work: .monitoring("checks"), detail: nil, refs: [],
                        lifetime: .untilReplaced), writeNumber: .init(epoch: epoch, counter: 1))) == .applied)
        #expect(try await composition.ingestion.sessionSummary(paneId: paneId.uuid)?.status == .working(.monitoring))
        #expect(
            try await harness.sessionEvent(
                paneId: paneId.uuid, provider: SessionsVerticalHarness.testProvider, name: "sessionEnd",
                conversationId: conversationId
            ).disposition == .admitted)
        let read = await composition.paneContextService.readDetail(.init(paneId: paneId, page: .first))
        let detail: PaneContextDetail?
        if case .detail(let value) = read { detail = value } else { detail = nil }
        #expect(try #require(detail).agentLine?.stale == true)
        #expect(try await composition.ingestion.sessionSummary(paneId: paneId.uuid)?.status == .idle(.ended))
    }

    @Test("the live adapter persists drawer ownership from the real canonical graph")
    func bootCompositionUsesAuthoritativeDrawerOwner() async throws {
        let composition = try #require(
            SessionsVerticalHarnessContext.current?.harness.appDelegate.appIPCSessionsPaneContextComposition,
            "Boot did not construct the Sessions/PaneContext composition")
        let fixture = try #require(SessionsVerticalHarnessContext.current)
        let harness = try await fixture.freshPanePair()
        let parentId = harness.boundPaneId
        let drawer = try #require(harness.commandHarness.store.addDrawerPane(to: parentId))
        let params = IPCSessionEventParams(
            handle: drawer.id.uuidString, provider: SessionsVerticalHarness.testProvider,
            event: .init(
                name: .sessionStart, conversationId: UUIDv7.generate().uuidString, turnId: nil,
                requestId: nil, toolId: nil, subagentId: nil, occurrenceId: UUIDv7.generate()),
            correlationId: UUIDv7.generate())
        #expect(
            try await composition.liveSessionsAdapter.recordProviderEvent(
                paneId: drawer.id, params: params, provenance: .matchingPane
            ).disposition == .admitted)
        let binding = try #require(
            try await composition.ingestion.repository.statusContext(paneId: drawer.id)
                .currentBinding)
        #expect(binding.ownerPaneId == parentId)
        #expect(binding.paneId == drawer.id)
    }

    @Test("the real boot server routes credential-bound pane methods to its assembled IPC adapter")
    func bootServerUsesPaneContextPort() async throws {
        _ = try #require(
            SessionsVerticalHarnessContext.current?.harness.appDelegate.appIPCSessionsPaneContextComposition,
            "Boot did not construct the Sessions/PaneContext composition")
        let fixture = try #require(SessionsVerticalHarnessContext.current)
        let harness = try await Self.withPaneCredential(try await fixture.freshPanePair())
        let messageId = UUIDv7.generate()
        let send = IPCPaneMessageSendParams(
            handle: "self", messageId: messageId, importance: .info,
            body: "A production-wired notice", actions: [], shape: .notice, correlationId: UUIDv7.generate())
        let sent: IPCPaneMessageSendResult = try await harness.decoded(
            method: "pane.message.send", params: JSONRPCCodec.encodeJSONValue(send), authentication: .boundPane)
        #expect(sent == .created(id: messageId))
        let detail: IPCPaneContextGetResult = try await harness.decoded(
            method: "pane.context.get",
            params: JSONRPCCodec.encodeJSONValue(
                IPCPaneContextGetParams(handle: "self", page: .first)),
            authentication: .boundPane)
        #expect(detail.paneId == harness.boundPaneId)
        #expect(detail.messages.contains { $0.id == messageId && $0.sourcePaneId == harness.boundPaneId })
    }

    @Test("Boot connects permanent retirement to the service that admits pane messages")
    func bootCompositionForwardsPermanentRetirement() async throws {
        let composition = try #require(
            SessionsVerticalHarnessContext.current?.harness.appDelegate.appIPCSessionsPaneContextComposition,
            "Boot did not construct the Sessions/PaneContext composition")
        let fixture = try #require(SessionsVerticalHarnessContext.current)
        let harness = try await fixture.freshPanePair()
        let coordinator = harness.commandHarness.coordinator
        #expect(coordinator.paneContextService === composition.paneContextService)
        let paneId = PaneId(existingUUID: harness.boundPaneId)
        let first = AgentMessageId.generateUUIDv7()
        #expect(
            await composition.paneContextService.send(
                .init(
                    paneId: paneId, messageId: first, sender: .pane(paneId), sourceOccurredAt: nil,
                    importance: .info, body: "Before retirement", why: nil, actions: [], shape: .notice))
                == .created(first))
        coordinator.retirePanesPermanently([paneId.uuid])
        #expect(
            await composition.paneContextService.send(
                .init(
                    paneId: paneId, messageId: .generateUUIDv7(), sender: .pane(paneId), sourceOccurredAt: nil,
                    importance: .info, body: "After retirement", why: nil, actions: [], shape: .notice))
                == .refused(.paneGone))
    }

    // Reuse the suite's real server/datastore; only the credential-bearing value changes.
    private static func withPaneCredential(_ harness: SessionsVerticalHarness) async throws -> SessionsVerticalHarness {
        let token = AgentStudioIPCSubjectToken(rawValue: "s3c-pane-\(UUIDv7.generate().uuidString)")
        try harness.appDelegate.appIPCPrincipalRegistry.registerIssuedPaneCredential(
            paneID: harness.boundPaneId, workspaceID: harness.commandHarness.store.identityAtom.workspaceId,
            credentialRecordID: UUIDv7.generate(),
            verifierSHA256: await SessionsVerticalHarness.credentialVerifier(for: token.rawValue))
        return SessionsVerticalHarness(
            appDelegate: harness.appDelegate, commandHarness: harness.commandHarness,
            rootDirectory: harness.rootDirectory, socketPath: harness.socketPath, token: harness.token,
            boundPaneToken: token, boundPaneId: harness.boundPaneId, sparePaneId: harness.sparePaneId,
            workspaceWindowId: harness.workspaceWindowId)
    }

}
