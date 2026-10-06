import AgentStudioPrimitives
import AgentStudioProgrammaticControl
import Foundation
import Testing

@testable import AgentStudioIPCClientCore

@Suite("CLI selective compiled invocation resolution")
struct IPCCompiledInvocationResolverTests {
    @Test("every static method resolves through the production selective recipes without discovery")
    func everyStaticMethodResolvesThroughCompiledRecipes() throws {
        let index = IPCBuiltInMethodIndex()
        let resolver = IPCCompiledInvocationResolver(index: index)
        let context = inputs
        for entry in index.entries {
            let descriptors = try resolver.resolve(arguments: [entry.name], authenticated: false, inputs: context)
            #expect(descriptors.map(\.metadata.name) == [entry.name])
        }
        #expect(throws: IPCDescriptorInvocationError.self) {
            try resolver.resolve(arguments: ["terminal.sned"], authenticated: false, inputs: context)
        }
    }

    @Test("index construction and metadata lookup never invoke descriptor or help-schema factories")
    func indexMetadataDoesNotConstructDescriptors() throws {
        let observation = ResolverFactoryObservation()
        let index = recordingIndex(observation)
        #expect(index.entries.count == 47)
        #expect(index.entry(named: "session.event")?.name == "session.event")
        #expect(observation.descriptorNames.isEmpty)
        #expect(observation.helpSchemaNames.isEmpty)
    }

    @Test("session.event resolves through real factories for only authentication and the event")
    func sessionEventBuildsOnlyAuthenticationAndEvent() throws {
        let observation = ResolverFactoryObservation()
        let resolver = IPCCompiledInvocationResolver(index: recordingIndex(observation))
        let descriptors = try resolver.resolve(arguments: ["session.event"], authenticated: true, inputs: inputs)
        #expect(observation.descriptorNames.sorted() == ["auth.login", "session.event"])
        #expect(descriptors.map { $0.metadata.name }.sorted() == ["auth.login", "session.event"])
        let event = try #require(descriptors.first { $0.metadata.name == "session.event" })
        let sample = try #require(event.metadata.examples.first)
        let encoded = try JSONEncoder().encode(sample)
        let decoded = try JSONSerialization.jsonObject(with: encoded)
        let object = try #require(decoded as? [String: Any])
        let parameters = try #require(object["parameters"] as? [String: Any])
        _ = try event.normalizeParameters(JSONSerialization.data(withJSONObject: parameters))
    }

    @Test("ordinary methods build only their method and auth.login without duplicate login")
    func ordinaryMethodBuildsOnlyAuthenticationAndSelectedMethod() throws {
        let observation = ResolverFactoryObservation()
        let resolver = IPCCompiledInvocationResolver(index: recordingIndex(observation))
        _ = try resolver.resolve(arguments: ["terminal.status"], authenticated: true, inputs: inputs)
        #expect(observation.descriptorNames.sorted() == ["auth.login", "terminal.status"])
        observation.clear()
        _ = try resolver.resolve(arguments: ["auth.login"], authenticated: true, inputs: inputs)
        #expect(observation.descriptorNames == ["auth.login"])
    }

    @Test("an unknown method is refused before any real descriptor is constructed")
    func unknownMethodConstructsNothing() throws {
        let observation = ResolverFactoryObservation()
        let resolver = IPCCompiledInvocationResolver(index: recordingIndex(observation))
        #expect(throws: IPCDescriptorInvocationError.self) {
            try resolver.resolve(arguments: ["terminal.sned"], authenticated: true, inputs: inputs)
        }
        #expect(observation.descriptorNames.isEmpty)
    }

    @Test("longest model prefix selects only the real owning descriptor and authentication")
    func modelAliasBuildsOnlyOwningMethodAndAuthentication() throws {
        let observation = ResolverFactoryObservation()
        let resolver = IPCCompiledInvocationResolver(index: recordingIndex(observation))
        let fixture = inputs
        let descriptors = try resolver.resolve(
            arguments: ["needs-you", "--clear"], authenticated: true, inputs: fixture)
        #expect(observation.descriptorNames.sorted() == ["auth.login", "session.report"])
        let invocation = try IPCDescriptorInvocationParser.parse(
            ["needs-you", "--clear"], descriptors: descriptors, correlationIDGenerator: { UUIDv7.generate() })
        guard case .model(let projection) = invocation.presentation else {
            Issue.record("The longest model prefix must retain model presentation")
            return
        }
        #expect(projection.variant == .needsYouClear)
    }

    @Test("overview help retains names and summaries without descriptor or schema construction")
    func overviewHelpConstructsNoDescriptors() throws {
        let observation = ResolverFactoryObservation()
        let resolver = IPCCompiledInvocationResolver(index: recordingIndex(observation))
        let rendered = try resolver.localHelp(arguments: ["--help"], inputs: inputs)
        let help = try #require(rendered)
        #expect(help.contains("session.event"))
        #expect(help.contains("Project one provider lifecycle event into Sessions for the target pane."))
        #expect(observation.descriptorNames.isEmpty)
        #expect(observation.helpSchemaNames.isEmpty)
    }

    @Test("detailed help retains options and correlation text and builds only the selected method's example")
    func detailedHelpConstructsOnlySelectedDescriptor() throws {
        let observation = ResolverFactoryObservation()
        let resolver = IPCCompiledInvocationResolver(index: recordingIndex(observation))
        let rendered = try resolver.localHelp(arguments: ["terminal.send", "--help"], inputs: inputs)
        let help = try #require(rendered)
        #expect(help.contains("Send exact input to one terminal pane."))
        #expect(help.contains("handle"))
        #expect(help.contains("input"))
        #expect(help.contains("correlationId"))
        #expect(help.contains("correlationId is generated when omitted"))
        #expect(observation.descriptorNames == ["terminal.send"])
        #expect(observation.helpSchemaNames == ["terminal.send"])
        #expect(help.contains("Example: agentstudio terminal.send --json"))
    }

    private var inputs: IPCBuiltInMethodCatalogInputs {
        .init(examples: .init(illustrativeIdentifier: UUIDv7.generate()))
    }

    private func recordingIndex(_ observation: ResolverFactoryObservation) -> IPCBuiltInMethodIndex {
        IPCBuiltInMethodIndex(
            entries: IPCBuiltInMethodIndex().entries.map { entry in
                IPCBuiltInMethodIndexEntry(
                    name: entry.name, summary: entry.summary, modelCalls: entry.modelCalls,
                    correlationPolicy: entry.correlationPolicy,
                    agentEligibility: entry.agentEligibility,
                    parameterSchema: {
                        observation.recordHelpSchema(entry.name)
                        return try entry.parameterSchema()
                    },
                    makeRepresentation: { inputs in
                        observation.recordDescriptor(entry.name)
                        return try entry.makeRepresentation(inputs: inputs)
                    })
            })
    }
}

private final class ResolverFactoryObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptors: [String] = []
    private var helpSchemas: [String] = []
    var descriptorNames: [String] { lock.withLock { descriptors } }
    var helpSchemaNames: [String] { lock.withLock { helpSchemas } }
    func recordDescriptor(_ name: String) { lock.withLock { descriptors.append(name) } }
    func recordHelpSchema(_ name: String) { lock.withLock { helpSchemas.append(name) } }
    func clear() {
        lock.withLock {
            descriptors.removeAll()
            helpSchemas.removeAll()
        }
    }
}
