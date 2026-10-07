import AgentStudioInfrastructure
import Foundation
import Testing

@testable import AgentStudioCore

@Suite("Pane context bounds")
struct PaneContextBoundsTests {
    @Test("The floor holds maximal message, current values and bounded Sessions metadata together")
    func floorIncludesWholeOwnerMetadata() async throws {
        try await withPaneContextService { fixture, _ in
            let summary = SessionSummary(
                id: UUIDv7.generate(), provider: try BridgeAgentProviderName(String(repeating: "p", count: 128)),
                sessionRef: try BridgeAgentSessionRef(String(repeating: "s", count: 512)),
                bindingGeneration: try fixture.bindingGenerationId,
                status: .failed(
                    SessionFailureSummary(
                        category: String(repeating: "f", count: AppPolicies.Sessions.maximumFailureSummaryBytes))),
                providerPrompts: Array(
                    repeating: SessionProviderPromptSummary(
                        reason: .approval, observedAt: fixture.time.now,
                        summary: String(repeating: "p", count: AppPolicies.Sessions.maximumPromptSummaryBytes)),
                    count: AppPolicies.Sessions.maximumListedOpenPrompts),
                omittedPromptCount: 10_000
            )
            let service = fixture.makeService(sessionSummary: { _ in summary })
            do {
                let prefix = "{\"kind\":\"openFile\",\"path\":\"\"}".utf8.count
                let action = MessageAction.openFile(path: String(repeating: "x", count: 1024 - prefix), line: nil)
                let ask = PaneMessageSendRequest(
                    paneId: fixture.paneId, messageId: .generateUUIDv7(), sender: fixture.sender,
                    sourceOccurredAt: fixture.time.now, importance: .failure, body: String(repeating: "x", count: 4096),
                    why: String(repeating: "x", count: 1024), actions: Array(repeating: action, count: 4),
                    shape: .ask(
                        reason: .approval, form: try boundaryForm(.freeText, encodedBytes: 8192),
                        waiting: .nonBlocking))
                try await fixture.sendCreated(ask, to: service)
                try #require(
                    await service.answer(
                        AnswerAskRequest(
                            messageId: ask.messageId, paneId: fixture.paneId, by: .localUser,
                            value: .text(String(repeating: "x", count: 8192)))) == .answered)
                let titleEpoch = try await fixture.epoch(service)
                try #require(
                    await service.setTitle(
                        fixture.title(String(repeating: "t", count: 256), epoch: titleEpoch, counter: 1)) == .applied)
                let lineEpoch = try await fixture.epoch(service, stream: .line)
                let ref = MessageAction.openFile(path: String(repeating: "x", count: 512 - prefix), line: nil)
                let line = AgentLineInput(
                    summary: String(repeating: "l", count: 200), work: .monitoring(String(repeating: "w", count: 200)),
                    detail: String(repeating: "d", count: 2048), refs: Array(repeating: ref, count: 8),
                    lifetime: .untilReplaced)
                try #require(
                    await service.setLine(
                        PaneLineWriteRequest(
                            paneId: fixture.paneId, writer: fixture.sender, line: line,
                            writeNumber: WriteNumber(epoch: lineEpoch, counter: 1))) == .applied)
                let result = await service.readDetail(
                    PaneContextReadRequest(paneId: fixture.paneId, page: .first), maximumDetailBytes: 0)
                guard case .detail(let detail) = result else {
                    Issue.record("The floor must hold all bounded owner metadata: \(result)")
                    await service.stop()
                    return
                }
                #expect(detail.session == summary)
                #expect(detail.agentTitle?.utf8.count == 256)
                #expect(detail.agentLine?.refs.count == 8)
                #expect(detail.messages.map(\.id) == [ask.messageId])
                #expect(PaneContextDetailBudget.detailBytes(detail) <= AppPolicies.PaneContext.minimumDetailBytes)
                #expect(detail.truncation == nil)
                await service.stop()
            } catch {
                await service.stop()
                throw error
            }
        }
    }
    @Test(
        "Complete tagged forms are admitted below and at 8192 and refused above", arguments: BoundaryFormShape.allCases,
        [8191, 8192, 8193])
    func completeEncodedFormBoundary(shape: BoundaryFormShape, encodedBytes: Int) async throws {
        try await withPaneContextService { fixture, service in
            let before = try await fixture.detail(service)
            let form = try boundaryForm(shape, encodedBytes: encodedBytes)
            let measured = PaneContextAdmission.formBytes(form)
            #expect(measured == encodedBytes)
            let request = fixture.ask(form: form)
            let sent = await service.send(request)
            if encodedBytes > 8192 {
                #expect(sent == .refused(.tooLarge(.form)))
                let after = try await fixture.detail(service)
                #expect(after == before)
            } else {
                #expect(sent == .created(request.messageId))
                let after = try await fixture.detail(service)
                #expect(after.messages.first?.id == request.messageId)
            }
        }
    }

    @Test(
        "JSON escaping counts toward the complete form limit for every shape", arguments: BoundaryFormShape.allCases,
        ["\"", "\\", "\n"])
    func escapingCannotBypassFormBound(shape: BoundaryFormShape, escaped: String) async throws {
        try await withPaneContextService { fixture, service in
            let before = try await fixture.detail(service)
            let form = try boundaryForm(shape, payload: String(repeating: escaped, count: 4096))
            #expect(PaneContextAdmission.formBytes(form) > 8192)
            let refusal = await service.send(fixture.ask(form: form))
            #expect(refusal == .refused(.tooLarge(.form)))
            let after = try await fixture.detail(service)
            #expect(after == before)
        }
    }

    @Test("The computed read floor holds a message with every admitted payload field at its bound")
    func floorHoldsMaximalMessage() async throws {
        try await withPaneContextService { fixture, service in
            let actionPrefixBytes = "{\"kind\":\"openFile\",\"path\":\"\"}".utf8.count
            let action = MessageAction.openFile(
                path: String(repeating: "x", count: 1024 - actionPrefixBytes), line: nil)
            let ask = PaneMessageSendRequest(
                paneId: fixture.paneId, messageId: .generateUUIDv7(), sender: fixture.sender,
                sourceOccurredAt: fixture.time.now, importance: .failure, body: String(repeating: "x", count: 4096),
                why: String(repeating: "x", count: 1024), actions: Array(repeating: action, count: 4),
                shape: .ask(
                    reason: .approval, form: try boundaryForm(.freeText, encodedBytes: 8192),
                    waiting: .nonBlocking))
            try await fixture.sendCreated(ask, to: service)
            try #require(
                await service.answer(
                    AnswerAskRequest(
                        messageId: ask.messageId, paneId: fixture.paneId, by: .localUser,
                        value: .text(String(repeating: "x", count: 8192)))) == .answered)
            let result = await service.readDetail(
                PaneContextReadRequest(paneId: fixture.paneId, page: .first), maximumDetailBytes: 0)
            guard case .detail(let detail) = result else {
                Issue.record("The minimum budget must return detail: \(result)")
                return
            }
            let message = try #require(detail.messages.first)
            #expect(message.id == ask.messageId)
            #expect(
                message.body.utf8.count + (message.why?.utf8.count ?? 0) + 8192 + 8192 + 4 * 1024
                    <= AppPolicies.PaneContext.minimumDetailBytes)
            #expect(detail.truncation == nil)
        }
    }
    @Test(
        "Message body bounds use UTF-8 bytes, and refusal leaves no message",
        arguments: [String(repeating: "x", count: 4097), String(repeating: "🛰", count: 1025)])
    func oversizedBodyHasNoEffect(body: String) async throws {
        try await withPaneContextService { fixture, service in
            let before = try await fixture.detail(service)

            #expect(await service.send(fixture.message(body: body)) == .refused(.tooLarge(.body)))

            #expect(try await fixture.detail(service) == before)
        }
    }

    @Test("The exact body byte limit is accepted")
    func exactBodyLimitIsAccepted() async throws {
        try await withPaneContextService { fixture, service in
            let request = fixture.message(body: String(repeating: "x", count: 4096))
            try await fixture.sendCreated(request, to: service)
            #expect(try await fixture.detail(service).messages.first?.body == request.body)
        }
    }

    @Test(
        "Why, choice count, choice labels, schema and action limits are checked before writes",
        arguments: OversizedMessageField.allCases)
    func fieldBoundsHaveNoEffect(field: OversizedMessageField) async throws {
        try await withPaneContextService { fixture, service in
            let before = try await fixture.detail(service)
            let request = try field.request(fixture)

            #expect(await service.send(request) == .refused(.tooLarge(field.limit)))
            #expect(try await fixture.detail(service) == before)
        }
    }

    @Test("The thirty-third open ask is refused until one settles")
    func openAskCapacityIsBounded() async throws {
        try await withPaneContextService { fixture, service in
            var asks: [PaneMessageSendRequest] = []
            for _ in 0..<32 {
                let ask = fixture.ask()
                try await fixture.sendCreated(ask, to: service)
                asks.append(ask)
            }
            let extra = fixture.ask()
            let before = try await fixture.detail(service)
            #expect(await service.send(extra) == .refused(.tooLarge(.openAsks)))
            #expect(try await fixture.detail(service) == before)
            try #require(await service.dismiss(messageId: asks[0].messageId, paneId: fixture.paneId) == .done)

            try await fixture.sendCreated(extra, to: service)
        }
    }

    @Test("The two-hundred-first unread notice is refused, and only person-read frees capacity")
    func unreadNoticeCapacityPreservesReadOwnership() async throws {
        try await withPaneContextService { fixture, service in
            var notices: [PaneMessageSendRequest] = []
            for _ in 0..<200 {
                let notice = fixture.message()
                try await fixture.sendCreated(notice, to: service)
                notices.append(notice)
            }
            let extra = fixture.message()
            #expect(await service.send(extra) == .refused(.tooLarge(.unreadNotices)))
            _ = try await fixture.detail(service)
            #expect(await service.send(extra) == .refused(.tooLarge(.unreadNotices)))
            try #require(await service.markRead(messageId: notices[0].messageId, paneId: fixture.paneId) == .done)

            try await fixture.sendCreated(extra, to: service)
        }
    }

    @Test("Title bounds use bytes and preserve the previous value", arguments: [256, 257])
    func titleBoundary(bytes: Int) async throws {
        try await withPaneContextService { fixture, service in
            let epoch = try await fixture.epoch(service)
            let text = String(repeating: "x", count: bytes)

            let result = await service.setTitle(fixture.title(text, epoch: epoch, counter: 1))

            #expect(result == (bytes == 256 ? .applied : .refused(.tooLarge(.title))))
            #expect(try await fixture.detail(service).agentTitle == (bytes == 256 ? text : nil))
        }
    }

    @Test("Agent Line summary bounds are enforced before an ordered write commits", arguments: [200, 201])
    func lineSummaryBoundary(bytes: Int) async throws {
        try await withPaneContextService { fixture, service in
            let epoch = try await fixture.epoch(service, stream: .line)
            let summary = String(repeating: "x", count: bytes)

            #expect(
                await service.setLine(fixture.line(summary, epoch: epoch, counter: 1))
                    == (bytes == 200 ? .applied : .refused(.tooLarge(.agentLine))))
            #expect(try await fixture.detail(service).agentLine?.summary == (bytes == 200 ? summary : nil))
        }
    }
}

enum OversizedMessageField: CaseIterable, Sendable {
    case why
    case choices
    case label
    case properties
    case schemaBytes
    case actionCount
    case actionBytes

    var limit: PaneContextLimitField {
        switch self {
        case .why: .why
        case .choices: .choices
        case .label: .choiceLabel
        case .properties, .schemaBytes: .form
        case .actionCount, .actionBytes: .actions
        }
    }

    func request(_ fixture: PaneContextServiceFixture) throws -> PaneMessageSendRequest {
        switch self {
        case .why: return fixture.message(why: String(repeating: "x", count: 1025))
        case .choices:
            let choices = try (0..<13).map { AskChoice(id: try AskChoiceId("choice-\($0)"), label: "choice") }
            return fixture.ask(form: .choice(options: choices, allowsMultiple: false))
        case .label:
            return fixture.ask(
                form: .choice(
                    options: [AskChoice(id: try AskChoiceId("choice"), label: String(repeating: "x", count: 201))],
                    allowsMultiple: false))
        case .properties:
            let properties = (0..<17).map {
                ElicitationProperty(name: "property-\($0)", title: nil, description: nil, type: .boolean)
            }
            return fixture.ask(form: .elicitation(ElicitationSchema(properties: properties, required: [])))
        case .schemaBytes:
            let property = ElicitationProperty(
                name: "property", title: nil, description: String(repeating: "x", count: 8193), type: .boolean)
            return fixture.ask(form: .elicitation(ElicitationSchema(properties: [property], required: [])))
        case .actionCount: return fixture.message(actions: Array(repeating: .goToPane(fixture.paneId), count: 5))
        case .actionBytes:
            return fixture.message(actions: [.openFile(path: String(repeating: "x", count: 1025), line: nil)])
        }
    }
}

enum BoundaryFormShape: CaseIterable, Sendable { case freeText, choice, elicitation }

private func boundaryForm(_ shape: BoundaryFormShape, encodedBytes: Int) throws -> AskForm {
    let framing: String =
        switch shape {
        case .freeText: #"{"kind":"freeText","placeholder":""}"#
        case .choice: #"{"kind":"choice","options":[{"id":"","label":"Choice"}],"allowsMultiple":false}"#
        case .elicitation:
            #"{"kind":"elicitation","schema":{"properties":[{"name":"flag","description":"","type":{"kind":"boolean"}}],"required":[]}}"#
        }
    return try boundaryForm(shape, payload: String(repeating: "x", count: encodedBytes - framing.utf8.count))
}

private func boundaryForm(_ shape: BoundaryFormShape, payload: String) throws -> AskForm {
    switch shape {
    case .freeText: return .freeText(placeholder: payload)
    case .choice: return .choice(options: [.init(id: try AskChoiceId(payload), label: "Choice")], allowsMultiple: false)
    case .elicitation:
        return .elicitation(
            .init(properties: [.init(name: "flag", title: nil, description: payload, type: .boolean)], required: []))
    }
}
