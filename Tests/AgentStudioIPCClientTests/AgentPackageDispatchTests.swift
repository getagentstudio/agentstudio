import AgentStudioIPCClientCore
import AgentStudioPrimitives
import Foundation
import Synchronization
import Testing

@Suite("Package dispatch refuses before calling any provider installer")
struct AgentPackageDispatchTests {
    private struct DispatchReceipt: Sendable {
        var uninstallations: [AgentPackageTarget] = []
        var statuses: [AgentPackageStatusRequest] = []
        var snippets: [AgentPackageTarget] = []
        var installations: [AgentPackageInstallation] = []
        var output: [String] = []
        var errors: [String] = []
    }

    private static let usage = """
        Usage: agentstudio package install claude [--config-dir PATH]
               agentstudio package install codex [--codex-home PATH | --provider-home PATH]
               agentstudio package install cursor [--provider-home PATH | --codex-home PATH]
               agentstudio package snippet claude|codex|cursor [OPTIONS]
               agentstudio package status [claude|codex|cursor] [--json] [OPTIONS]
               agentstudio package uninstall claude|codex|cursor [OPTIONS]
        Installs Agent Studio's hooks and skill for one provider. Without a path it uses the provider's default home.
        """

    @Test("Every grammar outcome crosses real dispatch with exact public results", arguments: PackageGrammarCase.all)
    func packageDispatch(row: PackageGrammarCase) {
        let receipt = Mutex(DispatchReceipt())
        let exitCode = AgentStudioIPCClientCommandLineRunner.run(
            props: .init(
                arguments: ["package"] + row.arguments, environment: [:], executablePath: "/unused/agentstudio",
                bundleExecutableURL: nil,
                standardInput: {
                    Issue.record("Package syntax must not read stdin")
                    return Data()
                },
                identifierGenerator: { UUIDv7.generate() },
                standardOutputSink: { line in receipt.withLock { $0.output.append(line) } },
                standardErrorSink: { line in receipt.withLock { $0.errors.append(line) } },
                installPackage: { installation in
                    receipt.withLock { $0.installations.append(installation) }
                    return 23
                },
                packageSnippet: { target in
                    receipt.withLock { $0.snippets.append(target) }
                    return "fixture snippet"
                },
                packageStatus: { request in
                    receipt.withLock { $0.statuses.append(request) }
                    return 19
                },
                uninstallPackage: { target in
                    receipt.withLock { $0.uninstallations.append(target) }
                    return 29
                }))
        let observed = receipt.withLock { $0 }
        switch row.expected {
        case .help:
            #expect(exitCode == 0)
            #expect(observed.installations.isEmpty)
            #expect(observed.snippets.isEmpty)
            #expect(observed.statuses.isEmpty)
            #expect(observed.uninstallations.isEmpty)
            #expect(observed.output == [Self.usage])
            #expect(observed.errors.isEmpty)
        case .usageError(let reason):
            #expect(exitCode == 64)
            #expect(observed.installations.isEmpty)
            #expect(observed.snippets.isEmpty)
            #expect(observed.statuses.isEmpty)
            #expect(observed.uninstallations.isEmpty)
            #expect(observed.output.isEmpty)
            #expect(observed.errors == ["agentstudio package: \(reason)\n\(Self.usage)"])
        case .uninstall(let target):
            #expect(exitCode == 29)
            #expect(observed.uninstallations == [target])
            #expect(observed.installations.isEmpty)
            #expect(observed.snippets.isEmpty)
            #expect(observed.statuses.isEmpty)
            #expect(observed.output.isEmpty)
            #expect(observed.errors.isEmpty)
        case .status(let request):
            #expect(exitCode == 19)
            #expect(observed.statuses == [request])
            #expect(observed.installations.isEmpty)
            #expect(observed.snippets.isEmpty)
            #expect(observed.output.isEmpty)
            #expect(observed.errors.isEmpty)
        case .snippet(let target):
            #expect(exitCode == 0)
            #expect(observed.snippets == [target])
            #expect(observed.installations.isEmpty)
            #expect(observed.output == ["fixture snippet"])
            #expect(observed.errors.isEmpty)
        case .install(let installation):
            #expect(exitCode == 23)
            #expect(observed.installations == [installation])
            #expect(observed.output.isEmpty)
            #expect(observed.errors.isEmpty)
        }
    }

    @Test(
        "The shared package parser does not claim unrelated or incomplete commands",
        arguments: [
            ["session.query"], ["not-package", "install", "claude"], ["package"],
        ])
    func unrelatedCommandsRemainUnclaimed(arguments: [String]) {
        #expect(AgentPackageSubcommand.parse(arguments) == nil)
    }
}
