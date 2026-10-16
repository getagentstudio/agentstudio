import AgentStudioPrimitives
import AgentStudioProgrammaticControl
import Foundation
import Testing

@Suite("Pane context wire contracts")
struct IPCPaneContextWireContractTests {
    @Test("The full production built-in catalog validates every schema and example")
    func productionBuiltInCatalogConstructs() throws {
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
                examples: .init(illustrativeIdentifier: UUIDv7.generate())
            )
        )
        let methodNames = catalog.erasedDescriptors.map(\.metadata.name)
        #expect(methodNames.contains("system.ping"))
        #expect(methodNames.contains("pane.message.ask"))
        #expect(methodNames.contains("pane.writer.claimEpoch"))
        #expect(Set(methodNames).count == methodNames.count)
    }

    @Test("Single-case object schemas preserve the exact tagged encodings")
    func singleCaseTaggedBytesRoundTrip() throws {
        let waiting = IPCPaneBlockingWaiting.blocking(deadline: Date(timeIntervalSinceReferenceDate: 60))
        try expectTaggedBytes(waiting, expectedJSON: #"{"deadline":60,"kind":"blocking"}"#)
        try expectTaggedBytes(
            IPCPaneBlockingAskShape.ask(reason: .approval, form: .freeText(placeholder: nil), waiting: waiting),
            expectedJSON:
                #"{"form":{"kind":"freeText"},"kind":"ask","reason":"approval","waiting":{"deadline":60,"kind":"blocking"}}"#
        )
        try expectTaggedBytes(IPCPaneEpochClaimResult.claimed(epoch: 1), expectedJSON: #"{"epoch":1,"kind":"claimed"}"#)
    }

    @Test("Source-page requests round-trip the accepted moreSources UUID cursor")
    func sourcePageRequestRoundTrip() throws {
        let identifier = UUIDv7.generate()
        let input = Data(
            "{\"handle\":\"self\",\"page\":{\"kind\":\"moreSources\",\"after\":\"\(identifier.uuidString)\"}}".utf8)
        let value = try IPCPaneContextGetParams.ipcSchema().decode(IPCPaneContextGetParams.self, from: input)
        let encoded = try JSONEncoder().encode(value)
        let fields = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let page = try #require(fields["page"] as? [String: String])
        #expect(fields["handle"] as? String == "self")
        #expect(page["kind"] == "moreSources")
        #expect(page["after"].flatMap(UUID.init(uuidString:)) == identifier)
        #expect(try IPCPaneContextGetParams.ipcSchema().decode(IPCPaneContextGetParams.self, from: encoded) == value)
    }

    @Test(
        "Source truncation preserves the remaining count and optional next UUID",
        arguments: [Int(0), 1, Int(IPCSchemaScalars.maximumExactInteger)])
    func sourceTruncationRoundTrip(remaining: Int) throws {
        let identifier = UUIDv7.generate()
        let cursor = remaining == 0 ? "null" : "\"\(identifier.uuidString)\""
        let input = Data("{\"omitted\":[],\"remainingLiveSources\":\(remaining),\"nextSourcesAfter\":\(cursor)}".utf8)
        let value = try IPCPaneDetailTruncation.ipcSchema().decode(IPCPaneDetailTruncation.self, from: input)
        let encoded = try JSONEncoder().encode(value)
        let fields = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let count = try #require(fields["remainingLiveSources"] as? NSNumber)
        #expect(count.int64Value == Int64(remaining))
        let next = (fields["nextSourcesAfter"] as? String).flatMap(UUID.init(uuidString:))
        #expect(next == (remaining == 0 ? nil : identifier))
        #expect(try IPCPaneDetailTruncation.ipcSchema().decode(IPCPaneDetailTruncation.self, from: encoded) == value)
    }

    @Test(
        "All monotonic fields use exact JSON numbers",
        arguments: [UInt64(0), 1, UInt64(IPCSchemaScalars.maximumExactInteger)])
    func safeIntegerRoundTrip(value: UInt64) throws {
        let identifier = UUIDv7.generate()
        try expectRoundTrip(IPCPaneWriteNumber(epoch: value, counter: value))
        try expectRoundTrip(IPCPaneEpochClaimResult.claimed(epoch: value))
        try expectRoundTrip(IPCPaneMessageChangesParams(handle: "self", after: value, correlationId: identifier))
        try expectRoundTrip(IPCPaneMessageChangesResult(entries: [], nextPosition: value, more: false))
        try expectRoundTrip(
            IPCPaneMessageChangeEntry(id: identifier, position: value, messageId: identifier, kind: .withdrawal))
        try expectRoundTrip(IPCPaneLiveMessageCursor(rank: 0, position: value))
        try expectRoundTrip(detail(revision: value))
        let data = try JSONEncoder().encode(IPCPaneWriteNumber(epoch: value, counter: value))
        let fields = try #require(JSONSerialization.jsonObject(with: data) as? [String: NSNumber])
        #expect(fields["epoch"]?.uint64Value == value)
        #expect(fields["counter"]?.uint64Value == value)
    }

    @Test(
        "Decode refuses unsafe, fractional and negative monotonic values", arguments: ["9007199254740992", "1.5", "-1"])
    func invalidIntegerDecode(raw: String) throws {
        let identifier = UUIDv7.generate().uuidString
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(IPCPaneWriteNumber.self, from: Data("{\"epoch\":\(raw),\"counter\":0}".utf8))
        }
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(IPCPaneWriteNumber.self, from: Data("{\"epoch\":0,\"counter\":\(raw)}".utf8))
        }
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(
                IPCPaneEpochClaimResult.self, from: Data("{\"kind\":\"claimed\",\"epoch\":\(raw)}".utf8))
        }
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(
                IPCPaneMessageChangesParams.self,
                from: Data("{\"handle\":\"self\",\"after\":\(raw),\"correlationId\":\"\(identifier)\"}".utf8))
        }
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(
                IPCPaneMessageChangesResult.self,
                from: Data("{\"entries\":[],\"nextPosition\":\(raw),\"more\":false}".utf8))
        }
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(
                IPCPaneMessageChangeEntry.self,
                from: Data(
                    "{\"id\":\"\(identifier)\",\"position\":\(raw),\"messageId\":\"\(identifier)\",\"kind\":{\"kind\":\"withdrawal\"}}"
                        .utf8))
        }
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(IPCPaneLiveMessageCursor.self, from: Data("{\"rank\":0,\"position\":\(raw)}".utf8))
        }
        let encoded = try JSONEncoder().encode(detail(revision: 1))
        let text = try #require(String(data: encoded, encoding: .utf8))
        let invalid = text.replacingOccurrences(of: "\"revision\":1", with: "\"revision\":\(raw)")
        #expect(invalid != text)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(IPCPaneContextGetResult.self, from: Data(invalid.utf8))
        }
    }

    @Test("Encode refuses unsafe counters with the typed internal invariant error")
    func invalidIntegerEncode() throws {
        let value = UInt64(IPCSchemaScalars.maximumExactInteger) + 1
        let identifier = UUIDv7.generate()
        expectEncodingRefusal(IPCPaneWriteNumber(epoch: value, counter: 0))
        expectEncodingRefusal(IPCPaneWriteNumber(epoch: 0, counter: value))
        expectEncodingRefusal(IPCPaneEpochClaimResult.claimed(epoch: value))
        expectEncodingRefusal(IPCPaneMessageChangesParams(handle: "self", after: value, correlationId: identifier))
        expectEncodingRefusal(IPCPaneMessageChangesResult(entries: [], nextPosition: value, more: false))
        expectEncodingRefusal(
            IPCPaneMessageChangeEntry(id: identifier, position: value, messageId: identifier, kind: .withdrawal))
        expectEncodingRefusal(IPCPaneLiveMessageCursor(rank: 0, position: value))
        expectEncodingRefusal(detail(revision: value))
    }

    @Test("Ask forms and answers preserve every supported variant")
    func formRoundTrips() throws {
        let propertyTypes: [IPCPaneElicitationPropertyType] = [
            .string(choices: ["one", "two"], minLength: 1, maxLength: 20, format: .email),
            .string(choices: nil, minLength: nil, maxLength: nil, format: .uri),
            .string(choices: nil, minLength: nil, maxLength: nil, format: .date),
            .number(minimum: 0, maximum: 10), .integer(minimum: 0, maximum: 10), .boolean,
        ]
        for property in propertyTypes { try expectRoundTrip(property) }
        let schema = IPCPaneElicitationSchema(
            properties: propertyTypes.enumerated().map {
                IPCPaneElicitationProperty(
                    name: "field\($0.offset)", title: "Input", description: "Value", type: $0.element)
            }, required: ["field0"])
        let forms: [IPCPaneAskForm] = [
            .choice(options: [IPCPaneAskChoice(id: "yes", label: "Yes")], allowsMultiple: false),
            .choice(options: [IPCPaneAskChoice(id: "yes", label: "Yes")], allowsMultiple: true),
            .freeText(placeholder: nil), .freeText(placeholder: "Your answer"), .elicitation(schema: schema),
        ]
        for form in forms { try expectRoundTrip(form) }
        let answers: [IPCPaneAskAnswerValue] = [
            .choices(ids: ["yes"]), .text(value: "Proceed"),
            .form(
                values: IPCPaneElicitationValues(properties: [
                    "text": .string(value: "a"), "number": .number(value: 1.5),
                    "integer": .integer(value: 2), "boolean": .boolean(value: true),
                ])),
        ]
        for answer in answers { try expectRoundTrip(answer) }
    }

    @Test("Terminal states and receipts preserve the answer and its attribution")
    func stateRoundTrips() throws {
        let receipts: [IPCPaneAnswerReceipt] = [
            .notYetConfirmed, .unconfirmed, .confirmed(at: Date(timeIntervalSinceReferenceDate: 10)),
        ]
        for receipt in receipts {
            try expectRoundTrip(receipt)
            try expectRoundTrip(IPCPaneAskState.answered(by: .localUser, value: .text(value: "yes"), receipt: receipt))
            try expectRoundTrip(
                IPCPaneTerminalState.ask(state: .answered(by: .localUser, value: .text(value: "yes"), receipt: receipt))
            )
        }
        let states: [IPCPaneAskState] = [.open, .handedBack, .dismissed, .expired, .withdrawn, .stale]
        for state in states { try expectRoundTrip(state) }
        let terminals: [IPCPaneAskTerminalState] = [.handedBack, .dismissed, .expired, .withdrawn, .stale]
        for state in terminals {
            try expectRoundTrip(IPCPaneMessageWithdrawResult.alreadySettled(state: .ask(state: state)))
        }
        for state in IPCPaneNoticeState.allCases { try expectRoundTrip(state) }
        for state in IPCPaneNoticeTerminalState.allCases {
            try expectRoundTrip(IPCPaneTerminalState.notice(state: state))
        }
        let outcomes: [IPCPaneAskOutcome] = [
            .answered(value: .text(value: "yes")), .handedBack, .expired, .withdrawn, .stale,
        ]
        for outcome in outcomes { try expectRoundTrip(outcome) }
    }

    @Test("Line, ordering, sender, session, PR and page unions preserve their tagged cases")
    func detailUnionRoundTrips() throws {
        let identifier = UUIDv7.generate()
        let works: [IPCPaneAgentLineWork] = [
            .working(progress: .indeterminate), .working(progress: .step(current: 1, total: 2)),
            .monitoring(target: "CI"), .blockedOnYou(action: "approve"), .done, .failed(summary: "compile"),
        ]
        for work in works { try expectRoundTrip(work) }
        try expectRoundTrip(IPCPaneAgentLineLifetime.untilReplaced)
        try expectRoundTrip(IPCPaneAgentLineLifetime.expires(at: Date(timeIntervalSinceReferenceDate: 1)))
        let stale: [IPCPaneWriteStaleness] = [
            .lastAccepted(writeNumber: IPCPaneWriteNumber(epoch: 1, counter: 2)), .epochSuperseded, .writerReplaced,
        ]
        for reason in stale { try expectRoundTrip(IPCPaneOrderedWriteResult.stale(reason: reason)) }
        try expectRoundTrip(IPCPaneMessageSender.pane(paneId: identifier))
        try expectRoundTrip(
            IPCPaneMessageSender.session(
                provider: "claude-code", conversationId: "session", bindingGeneration: identifier))
        let statuses: [IPCPaneSessionStatus] =
            IPCPaneAskReason.allCases.map { .needsYou(reason: $0) }
            + IPCPaneSessionWorkingState.allCases.map { .working(state: $0) }
            + IPCPaneSessionIdleState.allCases.map { .idle(state: $0) }
            + [.unknown, .failed(category: "authentication")]
        for status in statuses { try expectRoundTrip(status) }
        for checks in IPCPanePullRequestCheckStatus.allCases {
            for review in IPCPanePullRequestReviewStatus.allCases {
                try expectRoundTrip(
                    IPCPanePullRequestMemberRow.pullRequest(
                        worktreeId: identifier, number: 1, checks: checks, review: review))
            }
        }
        let summaries: [IPCPanePullRequestSummaryState] = [.needsAttention(count: 2), .running, .allGood, .noInfo]
        for summary in summaries { try expectRoundTrip(summary) }
        try expectRoundTrip(IPCPaneContextReadPage.first)
        try expectRoundTrip(
            IPCPaneContextReadPage.more(source: identifier, after: IPCPaneLiveMessageCursor(rank: 1, position: 2)))
    }

    private func detail(revision: UInt64) -> IPCPaneContextGetResult {
        IPCPaneContextGetResult(
            paneId: UUIDv7.generate(), revision: revision, messages: [], drawerMessages: [], links: .unknown,
            pullRequests: .notApplicable)
    }

    @Test("A bounded session projection explicitly reports omitted provider prompts")
    func omittedProviderPromptsRoundTrip() throws {
        let identifier = UUIDv7.generate()
        let summary = IPCPaneSessionSummary(
            id: identifier, provider: "claude-code", conversationId: "session", bindingGeneration: identifier,
            status: .needsYou(reason: .approval),
            providerPrompts: [
                IPCPaneProviderPromptSummary(
                    reason: .approval, observedAt: Date(timeIntervalSinceReferenceDate: 10), summary: "Approve")
            ], omittedPromptCount: 3)
        try expectTaggedBytes(
            summary,
            expectedJSON:
                "{\"bindingGeneration\":\"\(identifier.uuidString)\",\"conversationId\":\"session\",\"id\":\"\(identifier.uuidString)\",\"omittedPromptCount\":3,\"provider\":\"claude-code\",\"providerPrompts\":[{\"observedAt\":10,\"reason\":\"approval\",\"summary\":\"Approve\"}],\"status\":{\"kind\":\"needsYou\",\"reason\":\"approval\"}}"
        )
    }

    @Test("Omitted provider prompt counts are required non-negative safe integers")
    func omittedProviderPromptCountValidation() throws {
        let identifier = UUIDv7.generate()
        let base =
            "{\"id\":\"\(identifier.uuidString)\",\"provider\":\"claude-code\",\"conversationId\":\"session\",\"bindingGeneration\":\"\(identifier.uuidString)\",\"status\":{\"kind\":\"unknown\"},\"providerPrompts\":[]"
        for count in [0, 1, Int(IPCSchemaScalars.maximumExactInteger)] {
            let input = Data("\(base),\"omittedPromptCount\":\(count)}".utf8)
            let summary = try IPCPaneSessionSummary.ipcSchema().decode(IPCPaneSessionSummary.self, from: input)
            #expect(summary.omittedPromptCount == count)
            try expectRoundTrip(summary)
        }
        for suffix in [
            "}", ",\"omittedPromptCount\":-1}", ",\"omittedPromptCount\":1.5}",
            ",\"omittedPromptCount\":9007199254740992}",
        ] {
            let input = Data("\(base)\(suffix)".utf8)
            #expect(throws: (any Error).self) { try JSONDecoder().decode(IPCPaneSessionSummary.self, from: input) }
            #expect(throws: (any Error).self) {
                try IPCPaneSessionSummary.ipcSchema().decode(IPCPaneSessionSummary.self, from: input)
            }
        }
        for count in [-1, Int(IPCSchemaScalars.maximumExactInteger) + 1] {
            expectEncodingRefusal(
                IPCPaneSessionSummary(
                    id: identifier, provider: "claude-code", conversationId: "session", bindingGeneration: identifier,
                    status: .unknown, providerPrompts: [], omittedPromptCount: count))
        }
    }

    private func expectEncodingRefusal<Value: Encodable>(_ value: Value) {
        #expect(throws: IPCPaneNumericEncodingError.aboveSafeIntegerBound) {
            try JSONEncoder().encode(value)
        }
    }

    private func expectRoundTrip<Value: IPCSchemaProviding & Equatable>(_ value: Value) throws {
        let data = try JSONEncoder().encode(value)
        #expect(try Value.ipcSchema().decode(Value.self, from: data) == value)
    }

    private func expectTaggedBytes<Value: IPCSchemaProviding & Equatable>(
        _ value: Value, expectedJSON: String
    ) throws {
        // Canonical key order makes the fixture compare bytes without depending
        // on JSONEncoder's unspecified object-key order. Production codecs keep
        // their existing encoder settings.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let expectedBytes = Data(expectedJSON.utf8)
        let encoded = try encoder.encode(value)
        #expect(encoded == expectedBytes)
        let decoded = try Value.ipcSchema().decode(Value.self, from: encoded)
        #expect(decoded == value)
        #expect(try encoder.encode(decoded) == expectedBytes)
    }
}
