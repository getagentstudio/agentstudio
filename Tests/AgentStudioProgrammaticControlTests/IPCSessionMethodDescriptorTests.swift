import AgentStudioPrimitives
import AgentStudioProgrammaticControl
import Foundation
import Testing

@Suite("IPC session method descriptors")
struct IPCSessionMethodDescriptorTests {
    @Test("the four session methods reach every channel with pane targeting")
    func sessionMethodsAreExposedOnEveryChannel() throws {
        let catalog = try makeCatalog()
        let sessions = catalog.sessions
        let descriptors = Self.sessionDescriptors(in: catalog)

        #expect(
            descriptors.map(\.metadata.name)
                == ["session.event", "session.message", "session.query", "session.report"]
        )
        for descriptor in descriptors {
            #expect(descriptor.metadata.exposure == .allChannels)
            #expect(descriptor.metadata.allowedTargetKinds == [.pane])
            #expect(descriptor.metadata.executionOwner == .sessionsIngest)
            #expect(descriptor.metadata.principalAvailability == .authenticated)
        }
        #expect(sessions.sessionReport.requiredPrivileges == [.sessionReportWrite])
        #expect(sessions.sessionMessage.requiredPrivileges == [.sessionReportWrite])
        #expect(sessions.sessionEvent.requiredPrivileges == [.sessionReportWrite])
        #expect(sessions.sessionQuery.requiredPrivileges == [.sessionStateRead])
        #expect(sessions.sessionReport.dataScope == .sessionReport)
        #expect(sessions.sessionQuery.dataScope == .sessionState)
    }

    @Test("mutations require correlation and the read accepts none")
    func correlationPolicyMatchesMutationBoundary() throws {
        let sessions = try makeCatalog().sessions

        #expect(sessions.sessionReport.isMutating)
        #expect(sessions.sessionMessage.isMutating)
        #expect(sessions.sessionEvent.isMutating)
        #expect(!sessions.sessionQuery.isMutating)
        #expect(sessions.sessionReport.correlationPolicy == .required)
        #expect(sessions.sessionMessage.correlationPolicy == .required)
        #expect(sessions.sessionEvent.correlationPolicy == .required)
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

    @Test("only the deliberate verbs and message project model calls")
    func modelCallsCoverTheDeliberateVocabulary() throws {
        let sessions = try makeCatalog().sessions

        #expect(
            sessions.sessionReport.modelCalls.map(\.variant) == [.needsYou, .needsYouClear, .done]
        )
        #expect(sessions.sessionMessage.modelCalls.map(\.variant) == [.message])
        #expect(sessions.sessionEvent.modelCalls.isEmpty)
        #expect(sessions.sessionQuery.modelCalls.isEmpty)

        let replies = Dictionary(
            uniqueKeysWithValues: sessions.sessionReport.modelCalls.map { ($0.variant, $0.successReply) }
        )
        #expect(replies[.needsYou] == "needs-you recorded")
        #expect(replies[.needsYouClear] == "needs-you cleared")
        #expect(replies[.done] == "done recorded")
        #expect(sessions.sessionMessage.modelCalls.first?.successReply == "message sent")
    }

    @Test("model scalar arguments stay optional for needs-you and required for message text")
    func modelScalarArgumentsMatchTheVocabulary() throws {
        let sessions = try makeCatalog().sessions
        let needsYou = try #require(sessions.sessionReport.modelCalls.first { $0.variant == .needsYou })
        let clear = try #require(sessions.sessionReport.modelCalls.first { $0.variant == .needsYouClear })
        let message = try #require(sessions.sessionMessage.modelCalls.first)

        #expect(needsYou.scalarArguments.map(\.parameterField) == ["explanation"])
        #expect(needsYou.scalarArguments.first?.isRequired == false)
        #expect(clear.scalarArguments.isEmpty)
        #expect(message.scalarArguments.map(\.parameterField) == ["text"])
        #expect(message.scalarArguments.first?.isRequired == true)
    }

    @Test("offline eligibility covers needs-you done and message but never a clear or a hook event")
    func offlineEligibilityMatchesSettledScope() throws {
        let sessions = try makeCatalog().sessions

        #expect(sessions.sessionReport.offlineEligibility == .modelCallVariants([.needsYou, .done]))
        #expect(sessions.sessionMessage.offlineEligibility == .modelCallVariants([.message]))
        #expect(sessions.sessionEvent.offlineEligibility == .never)
        #expect(sessions.sessionQuery.offlineEligibility == .never)
    }

    @Test("an omitted handle defaults to the authenticated self pane")
    func handleDefaultsToSelf() throws {
        let sessions = try makeCatalog().sessions
        let correlationId = UUIDv7.generate()

        let report = try sessions.sessionReport.decodeParameters(
            from: encodedObject(["kind": "done", "correlationId": correlationId.uuidString])
        )
        #expect(report.handle == "self")
        #expect(report.kind == .done)
        #expect(report.explanation == nil)

        let query = try sessions.sessionQuery.decodeParameters(from: encodedObject([:]))
        #expect(query.handle == "self")
    }

    @Test("a query page never advertises more than the newest twenty messages")
    func queryPageStaysBounded() throws {
        let sessions = try makeCatalog().sessions
        let document = try #require(
            JSONSerialization.jsonObject(
                with: sessions.sessionQuery.contract.resultSchema.jsonSchemaData()
            ) as? [String: Any]
        )
        let properties = try #require(document["properties"] as? [String: [String: Any]])

        #expect(properties["messages"]?["maxItems"] as? Int == 20)
        #expect(IPCSessionSchemaLimits.maximumQueryMessageCount == 20)
    }

    @Test("an unknown report kind is rejected before any owner sees it")
    func unknownReportKindIsRejected() throws {
        let sessions = try makeCatalog().sessions

        #expect(throws: IPCSchemaValidationError.self) {
            try sessions.sessionReport.decodeParameters(
                from: encodedObject([
                    "handle": "self",
                    "kind": "shipIt",
                    "correlationId": UUIDv7.generate().uuidString,
                ])
            )
        }
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
