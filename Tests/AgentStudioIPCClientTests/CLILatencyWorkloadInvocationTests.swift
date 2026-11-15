import AgentStudioPrimitives
import AgentStudioProgrammaticControl
import Foundation
import Testing

@testable import AgentStudioIPCClientCore

@Suite("CLI latency workload invocation contracts")
struct CLILatencyWorkloadInvocationTests {
    private struct Manifest: Decodable {
        struct Family: Decodable {
            let name: String
            let argv: [String]
        }
        let families: [Family]
    }

    @Test("every benchmark family is accepted by its real production invocation parser")
    func everyWorkloadParsesThroughItsOwner() throws {
        // Arrange: substitute exactly the fixture tokens the benchmark supplies.
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let manifest = try JSONDecoder().decode(
            Manifest.self, from: Data(contentsOf: repository.appending(path: "scripts/cli-latency-workloads.json")))
        try #require(!manifest.families.isEmpty)
        let replacements = [
            "${sampleId}": "sample-1", "${conversationId}": "fixture-session",
            "${workspaceWindowId}": UUIDv7.generate().uuidString, "${paneId}": UUIDv7.generate().uuidString,
        ]
        let identifier = UUIDv7.generate()
        let inputs = IPCBuiltInMethodCatalogInputs(examples: .init(illustrativeIdentifier: identifier))

        // Act / Assert: no unknown route or parser refusal is silently skipped.
        for family in manifest.families {
            let arguments = family.argv.map { argument in
                replacements.reduce(argument) { $0.replacingOccurrences(of: $1.key, with: $1.value) }
            }
            #expect(!arguments.contains { $0.contains("${") }, "Unknown fixture token in \(family.name)")
            do {
                let name = try #require(arguments.first, "Empty argv for \(family.name)")
                if PaneCLIVerb(rawValue: name) != nil {
                    _ = try PaneCLIIntent.parse(arguments, now: Date(timeIntervalSince1970: 1_800_000_000))
                } else if name == "hook" {
                    guard case .hook = AgentPackageSubcommand.parse(arguments) else {
                        Issue.record("Hook parser refused benchmark family \(family.name)")
                        continue
                    }
                } else if name == "system.capabilities" || name == "command.list" {
                    // Explicit discovery uses this parser/schema path before
                    // the runner selects compiled invocation descriptors.
                    let schema = try IPCEmptyParams.ipcSchema()
                    _ = try schema.normalize(
                        IPCDescriptorInvocationParser.toolingParameterData(
                            arguments: Array(arguments.dropFirst()), schema: schema, standardInput: nil))
                } else {
                    let descriptors = try IPCCompiledInvocationResolver().resolve(
                        arguments: arguments, authenticated: false, inputs: inputs)
                    if name == "command.execute" {
                        let descriptor = try #require(descriptors.first)
                        _ = try IPCCommandCLIInvocationParser.parse(
                            global: .init(
                                configuration: .init(socketPath: "/unused-workload-parser.sock", authToken: nil),
                                methodArguments: arguments, consumesTokenInput: false),
                            descriptor: descriptor, readInput: { Data() }, correlationIDGenerator: { identifier })
                    } else {
                        _ = try IPCDescriptorInvocationParser.parse(
                            arguments, descriptors: descriptors, correlationIDGenerator: { identifier })
                    }
                }
            } catch {
                Issue.record("Production parser refused benchmark family \(family.name): \(error)")
            }
        }
    }
}
