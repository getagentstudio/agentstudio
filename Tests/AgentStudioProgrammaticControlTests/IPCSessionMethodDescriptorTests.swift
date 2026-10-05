import AgentStudioPrimitives
import AgentStudioProgrammaticControl
import Foundation
import Testing

@Suite("IPC session method descriptors")
struct IPCSessionMethodDescriptorTests {
    @Test("the three session methods reach every channel with pane targeting")
    func sessionMethodsAreExposedOnEveryChannel() throws {
        let catalog = try makeCatalog()
        let sessions = catalog.sessions
        let descriptors = Self.sessionDescriptors(in: catalog)

        #expect(
            descriptors.map(\.metadata.name)
                == ["session.event", "session.query", "session.refusal"]
        )
        for descriptor in descriptors {
            #expect(descriptor.metadata.exposure == .allChannels)
            #expect(descriptor.metadata.allowedTargetKinds == [.pane])
            #expect(descriptor.metadata.executionOwner == .sessionsIngest)
            #expect(descriptor.metadata.principalAvailability == .authenticated)
        }
        #expect(sessions.sessionEvent.requiredPrivileges == [.sessionReportWrite])
        #expect(sessions.sessionRefusal.requiredPrivileges == [.sessionReportWrite])
        #expect(sessions.sessionQuery.requiredPrivileges == [.sessionStateRead])
        #expect(sessions.sessionQuery.dataScope == .sessionState)
    }

    @Test("mutations require correlation and the read accepts none")
    func correlationPolicyMatchesMutationBoundary() throws {
        let sessions = try makeCatalog().sessions

        #expect(sessions.sessionEvent.isMutating)
        #expect(sessions.sessionRefusal.isMutating)
        #expect(!sessions.sessionQuery.isMutating)
        #expect(sessions.sessionEvent.correlationPolicy == .required)
        #expect(sessions.sessionRefusal.correlationPolicy == .required)
        #expect(sessions.sessionQuery.correlationPolicy == .notAccepted)
    }

    @Test("every session example normalizes through its declared schemas")
    func declaredExamplesNormalize() throws {
        for descriptor in Self.sessionDescriptors(in: try makeCatalog()) {
            #expect(!descriptor.metadata.examples.isEmpty)
            _ = try descriptor.catalogEntrySchema.decode(
                IPCMethodCatalogEntry.self,
                from: JSONEncoder().encode(descriptor.metadata)
            )
        }
    }

    @Test("session descriptors expose no deliberate scalar projections or retired methods")
    func modelCallsCoverTheDeliberateVocabulary() throws {
        let catalog = try makeCatalog()
        #expect(catalog.sessions.sessionEvent.modelCalls.isEmpty)
        #expect(catalog.sessions.sessionQuery.modelCalls.isEmpty)
        #expect(
            !catalog.erasedDescriptors.contains {
                $0.metadata.name == "session.message" || $0.metadata.name == "session.report"
            })
    }

    @Test("the replacement notice carries a required exact body and optional writer")
    func modelScalarArgumentsMatchTheVocabulary() throws {
        let catalog = try makeCatalog()
        let descriptor = try #require(catalog.erasedDescriptors.first { $0.metadata.name == "pane.message.send" })
        guard case .object(let fields) = descriptor.metadata.parameterSchema else {
            Issue.record("Expected message fields")
            return
        }
        #expect(fields.first { $0.name == "body" }?.presence == .required)
        #expect(fields.first { $0.name == "writer" }?.presence == .optional)
    }

    @Test("retained hook and query methods never queue")
    func offlineEligibilityMatchesSettledScope() throws {
        let sessions = try makeCatalog().sessions

        #expect(sessions.sessionEvent.offlineEligibility == .never)
        #expect(sessions.sessionQuery.offlineEligibility == .never)
    }

    @Test("an omitted handle defaults to the authenticated self pane")
    func handleDefaultsToSelf() throws {
        let sessions = try makeCatalog().sessions
        let query = try sessions.sessionQuery.decodeParameters(from: encodedObject([:]))
        #expect(query.handle == "self")
    }

    @Test("query exposes exactly the shared status summary and a required nullable session")
    func queryHasOneSummaryShape() throws {
        let sessions = try makeCatalog().sessions
        let decoded = try JSONSerialization.jsonObject(
            with: sessions.sessionQuery.contract.resultSchema.jsonSchemaData())
        let document = try #require(decoded as? [String: Any])
        let properties = try #require(document["properties"] as? [String: [String: Any]])
        #expect(Set(properties.keys) == ["paneId", "sourceHealth", "session"])
        let required = try #require(document["required"] as? [String])
        #expect(Set(required) == ["paneId", "sourceHealth", "session"])
        let result = IPCSessionQueryResult(paneId: UUIDv7.generate(), sourceHealth: .unbound, session: nil)
        let encoded = try JSONEncoder().encode(result)
        let object = try JSONSerialization.jsonObject(with: encoded)
        let fields = try #require(object as? [String: Any])
        #expect(fields["session"] is NSNull)
        let roundtrip = try JSONDecoder().decode(IPCSessionQueryResult.self, from: encoded)
        #expect(roundtrip == result)
        var missing = fields
        missing.removeValue(forKey: "session")
        let missingData = try JSONSerialization.data(withJSONObject: missing)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(IPCSessionQueryResult.self, from: missingData)
        }
        var contradictory = fields
        contradictory["sourceHealth"] = "live"
        let contradictoryData = try JSONSerialization.data(withJSONObject: contradictory)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(IPCSessionQueryResult.self, from: contradictoryData)
        }
    }

    @Test("a retired report cannot be looked up as a compiled method")
    func unknownReportKindIsRejected() throws {
        #expect(IPCBuiltInMethodIndex().entry(named: "session.report") == nil)
        #expect(IPCBuiltInMethodIndex().entry(named: "session.message") == nil)
    }

    @Test("refusal wire round trips with pane authentication metadata and never queues")
    func refusalContractRoundTrips() throws {
        let descriptor = try makeCatalog().sessions.sessionRefusal
        let params = IPCSessionRefusalParams(
            handle: "self", reason: .noSessionId, event: "PreToolUse", correlationId: UUIDv7.generate())
        #expect(try descriptor.decodeParameters(from: JSONEncoder().encode(params)) == params)
        let result = IPCSessionRefusalResult(paneId: UUIDv7.generate())
        #expect(try JSONDecoder().decode(IPCSessionRefusalResult.self, from: JSONEncoder().encode(result)) == result)
        #expect(descriptor.isMutating)
        #expect(descriptor.correlationPolicy == .required)
        #expect(descriptor.offlineEligibility == .never)
        #expect(IPCBuiltInMethodIndex().entry(named: "session.refusal") != nil)
    }

    @Test("refusal requires a valid UUID correlation field")
    func refusalRequiresCorrelationField() throws {
        let descriptor = try makeCatalog().sessions.sessionRefusal
        let params = IPCSessionRefusalParams(handle: "self", reason: .noSessionId, correlationId: UUIDv7.generate())
        var fields = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(params)) as? [String: Any])
        fields.removeValue(forKey: "correlationId")
        #expect(throws: IPCSchemaValidationError.self) {
            try descriptor.decodeParameters(from: JSONSerialization.data(withJSONObject: fields))
        }
        fields["correlationId"] = "not-a-uuid"
        #expect(throws: IPCSchemaValidationError.self) {
            try descriptor.decodeParameters(from: JSONSerialization.data(withJSONObject: fields))
        }
    }

    @Test("hook events round trip and reject removed permissionHandling and sourceOccurredAt")
    func removedHookFieldsAreStrictlyRefused() throws {
        let descriptor = try makeCatalog().sessions.sessionEvent
        let params = IPCSessionEventParams(
            handle: "self",
            provider: .init(identifier: "claude-code", version: "9.9.9", mode: "cli"),
            event: .init(
                name: .permission, conversationId: "running-session", turnId: "turn-A",
                requestId: nil, toolId: nil, subagentId: nil, occurrenceId: UUIDv7.generate()),
            correlationId: UUIDv7.generate())
        let encoded = try JSONEncoder().encode(params)
        #expect(try descriptor.decodeParameters(from: encoded) == params)
        var document = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        document["permissionHandling"] = "blockingAsk"
        let oldPermission = try JSONSerialization.data(withJSONObject: document)
        #expect(throws: (any Error).self) { try descriptor.decodeParameters(from: oldPermission) }
        document.removeValue(forKey: "permissionHandling")
        var event = try #require(document["event"] as? [String: Any])
        event["sourceOccurredAt"] = 1_700_000_000
        document["event"] = event
        let oldTimestamp = try JSONSerialization.data(withJSONObject: document)
        #expect(throws: (any Error).self) { try descriptor.decodeParameters(from: oldTimestamp) }
    }

    private static func sessionDescriptors(
        in catalog: IPCBuiltInMethodCatalog
    ) -> [IPCAnyMethodDescriptor] {
        catalog.erasedDescriptors.filter { $0.metadata.name.hasPrefix("session.") }
    }

    private func makeCatalog() throws -> IPCBuiltInMethodCatalog {
        try IPCBuiltInMethodCatalog(
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
    }

    private func encodedObject(_ value: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }
}
