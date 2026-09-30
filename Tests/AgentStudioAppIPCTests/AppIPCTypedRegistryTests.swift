import AgentStudioAppIPC
import AgentStudioIPCTransport
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import Foundation
import Testing

@Suite("App IPC registered typed catalog")
struct AppIPCTypedRegistryTests {
    @Test("debug registry derives its full capabilities from the callable registrations")
    func debugRegistryDerivesCapabilitiesFromHandlers() throws {
        let fixture = BuiltInMethodRegistrationsFixture()
        let registrations = try fixture.registrations()
        let registry = try makeTestAppIPCMethodRegistry(
            registrations: registrations, recognizedCommands: [], channel: .debug)
        let names = registry.capabilities.methods.map(\.name)
        #expect(names.count == 48)
        #expect(names == names.sorted())
        #expect(Set(names).count == names.count)
        #expect(names.filter { $0 == "system.capabilities" }.count == 1)
        #expect(registry.registration(named: "permission.request") == nil)
        #expect(registry.registration(named: "file.open") == nil)
        for name in names {
            #expect(
                registry.registration(named: name)?.descriptor.metadata
                    == registry.capabilities.methods.first { $0.name == name })
        }
        let decoded = try IPCMethodCatalogDecoder.decode(JSONEncoder().encode(registry.capabilities))
        #expect(decoded == registry.capabilities)
    }

    @Test(
        "stable and beta omit diagnostic registrations and keep agent-eligible methods",
        arguments: [AgentStudioIPCChannel.stable, .beta])
    func productionRegistryOmitsDiagnosticMethods(channel: AgentStudioIPCChannel) throws {
        let fixture = BuiltInMethodRegistrationsFixture()
        let registry = try makeTestAppIPCMethodRegistry(
            registrations: fixture.registrations(), recognizedCommands: [], channel: channel)
        // 12 established all-channel methods plus the 13 methods pane agents
        // may run in A1, which reach agents on every channel.
        #expect(registry.capabilities.methods.count == 25)
        #expect(registry.capabilities.methods.allSatisfy { $0.exposure == .allChannels })
        #expect(registry.registration(named: "session.report") != nil)
        #expect(registry.registration(named: "session.query") != nil)
        #expect(registry.registration(named: "terminal.send") != nil)
        #expect(registry.registration(named: "pane.snapshot") != nil)
        #expect(registry.registration(named: "ui.commandBar.open") == nil)
        #expect(registry.registration(named: "pane.focus") == nil)
    }

    @Test("duplicate registration identities reject composition")
    func duplicatesRejectComposition() throws {
        let fixture = BuiltInMethodRegistrationsFixture()
        let registrations = try fixture.registrations()
        let duplicate = try #require(registrations.first)
        let capabilitiesComposition = try makeTestIPCSystemCapabilitiesComposition(
            registrations: registrations,
            channel: .debug
        )
        #expect(throws: AppIPCMethodRegistryError.self) {
            try AppIPCMethodRegistry(
                registrations: registrations + [duplicate],
                recognizedCommands: [],
                channel: .debug,
                capabilitiesComposition: capabilitiesComposition
            )
        }
    }

    @Test("registry rejects a capabilities composition missing a registered method")
    func registryRejectsCapabilitiesCompositionMissingMethod() throws {
        let fixture = BuiltInMethodRegistrationsFixture()
        let registrations = try fixture.registrations()
        let omittedRegistration = try #require(
            registrations.first { $0.descriptor.metadata.name != "system.ping" })
        let incompleteRegistrations = registrations.filter {
            $0.descriptor.metadata.name != omittedRegistration.descriptor.metadata.name
        }
        let incompleteComposition = try makeTestIPCSystemCapabilitiesComposition(
            registrations: incompleteRegistrations,
            channel: .debug
        )

        #expect(throws: AppIPCMethodRegistryError.capabilitiesCompositionMismatch) {
            try AppIPCMethodRegistry(
                registrations: registrations,
                recognizedCommands: [],
                channel: .debug,
                capabilitiesComposition: incompleteComposition
            )
        }
    }

    @Test("registry rejects a capabilities composition with an extra method")
    func registryRejectsCapabilitiesCompositionWithExtraMethod() throws {
        let fixture = BuiltInMethodRegistrationsFixture()
        let registrations = try fixture.registrations()
        let extraRegistration = try #require(
            registrations.first { $0.descriptor.metadata.name != "system.ping" })
        let incompleteRegistrations = registrations.filter {
            $0.descriptor.metadata.name != extraRegistration.descriptor.metadata.name
        }
        let completeComposition = try makeTestIPCSystemCapabilitiesComposition(
            registrations: registrations,
            channel: .debug
        )

        #expect(throws: AppIPCMethodRegistryError.capabilitiesCompositionMismatch) {
            try AppIPCMethodRegistry(
                registrations: incompleteRegistrations,
                recognizedCommands: [],
                channel: .debug,
                capabilitiesComposition: completeComposition
            )
        }
    }

    @Test("registry rejects a capabilities composition with mismatched recognized-unexposed methods")
    func registryRejectsCapabilitiesCompositionWithRecognizedUnexposedMismatch() throws {
        let fixture = BuiltInMethodRegistrationsFixture()
        let registrations = try fixture.registrations()
        let allChannelRegistrations = registrations.filter {
            $0.descriptor.metadata.exposure == .allChannels
        }
        let incompleteRecognizedUnexposedComposition = try makeTestIPCSystemCapabilitiesComposition(
            registrations: allChannelRegistrations,
            channel: .stable
        )

        #expect(throws: AppIPCMethodRegistryError.capabilitiesCompositionMismatch) {
            try AppIPCMethodRegistry(
                registrations: registrations,
                recognizedCommands: [],
                channel: .stable,
                capabilitiesComposition: incompleteRecognizedUnexposedComposition
            )
        }
    }

    @Test("registry capabilities handler returns the same validated catalog")
    func capabilitiesHandlerMatchesRegistryProjection() async throws {
        let fixture = BuiltInMethodRegistrationsFixture()
        let registry = try makeTestAppIPCMethodRegistry(
            registrations: fixture.registrations(), recognizedCommands: [], channel: .debug)
        let registration = try #require(registry.registration(named: "system.capabilities"))
        let principal = fixture.diagnosticPrincipal
        let result = try await registration.invoke(
            parameters: .object([:]), connectionContext: fixture.connectionContext(principal: principal),
            targetResolutionTools: fixture.targetResolutionTools(),
            authorize: { _, request in
                #expect(request.requiredPrivileges == [.systemRead])
                #expect(request.target == .app)
            }
        )
        let decoded = try IPCMethodCatalogDecoder.decode(JSONEncoder().encode(result))
        #expect(decoded == registry.capabilities)
    }
}
