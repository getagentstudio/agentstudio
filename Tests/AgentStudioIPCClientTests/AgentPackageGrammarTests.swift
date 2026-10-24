import AgentStudioIPCClientCore
import Testing

struct PackageGrammarCase: Sendable {
    let arguments: [String]
    let expected: AgentPackageInvocation

    static var all: [Self] {
        var cases: [Self] = [
            .init(arguments: [], expected: .usageError("missing subcommand")),
            .init(arguments: ["uninstall"], expected: .usageError("missing provider")),
            .init(arguments: ["--unknown"], expected: .usageError("unknown subcommand --unknown")),
            .init(arguments: ["install"], expected: .usageError("missing provider")),
            .init(arguments: ["install", "other"], expected: .usageError("unknown provider other")),
            .init(arguments: ["install", "--unknown"], expected: .usageError("unknown provider --unknown")),
        ]
        for provider in ["claude", "codex", "cursor"] {
            cases += providerCases(provider)
        }
        let installs = cases
        for row in installs where row.arguments.first == "install" {
            guard case .install(let installation) = row.expected else { continue }
            cases.append(
                .init(arguments: ["snippet"] + row.arguments.dropFirst(), expected: .snippet(installation.target)))
            cases.append(
                .init(arguments: ["uninstall"] + row.arguments.dropFirst(), expected: .uninstall(installation.target)))
        }
        cases.append(.init(arguments: ["status"], expected: .status(.init(selection: .all, json: false))))
        cases.append(.init(arguments: ["status", "--json"], expected: .status(.init(selection: .all, json: true))))
        for provider in AgentPackageProvider.allCases {
            cases.append(
                .init(
                    arguments: ["status", provider.rawValue, "--json"],
                    expected: .status(.init(selection: .provider(.init(provider: provider, homePath: nil)), json: true))
                ))
        }
        // Help wins at every position, including an option value and beside errors.
        let ordinaryCases = cases
        for row in ordinaryCases {
            for index in 0...row.arguments.count {
                var arguments = row.arguments
                arguments.insert("--help", at: index)
                cases.append(.init(arguments: arguments, expected: .help))
            }
        }
        return cases
    }

    private static func providerCases(_ provider: String) -> [Self] {
        let prefix = ["install", provider]
        let options =
            provider == "claude" ? ["--config-dir"] : ["--codex-home", "--provider-home"]
        var cases: [Self] = [
            .init(arguments: prefix, expected: .install(installation(provider))),
            .init(arguments: prefix + ["extra"], expected: .usageError("unexpected argument extra")),
            .init(
                arguments: prefix + ["--unknown", "/x"],
                expected: .usageError("unknown option --unknown for \(provider)")),
        ]
        let foreignOption = provider == "claude" ? "--provider-home" : "--config-dir"
        cases.append(
            .init(
                arguments: prefix + [foreignOption, "/x"],
                expected: .usageError("unknown option \(foreignOption) for \(provider)")))
        for option in options {
            cases.append(
                .init(arguments: prefix + [option, "/x"], expected: .install(installation(provider, option: option))))
            for missingTail in [[], [""], ["--unknown"]] {
                cases.append(
                    .init(
                        arguments: prefix + [option] + missingTail, expected: .usageError("missing value for \(option)")
                    ))
            }
            cases.append(
                .init(
                    arguments: prefix + [option, "/x", option, "/y"],
                    expected: .usageError("\(option) given more than once")))
            cases.append(
                .init(arguments: prefix + [option, "/x", "extra"], expected: .usageError("unexpected argument extra")))
            cases.append(
                .init(
                    arguments: prefix + [option, "/x", "--unknown"],
                    expected: .usageError("unknown option --unknown for \(provider)")))
        }
        if provider != "claude" {
            for aliases in [options, options.reversed().map { $0 }] {
                cases.append(
                    .init(
                        arguments: prefix + [aliases[0], "/x", aliases[1], "/y"],
                        expected: .usageError("use one of --codex-home or --provider-home")))
            }
        }
        return cases
    }

    private static func installation(_ provider: String, option: String? = nil) -> AgentPackageInstallation {
        switch provider {
        case "claude":
            return .claude(
                .init(
                    configurationDirectoryPath: option == "--config-dir" ? "/x" : nil))
        case "codex": return .codex(providerHomePath: option == nil ? nil : "/x")
        default: return .cursor(providerHomePath: option == nil ? nil : "/x")
        }
    }
}

@Suite("Package grammar refuses malformed installs before provider access")
struct AgentPackageGrammarTests {
    @Test("Package grammar follows the reviewed literal cases", arguments: PackageGrammarCase.all)
    func packageGrammar(row: PackageGrammarCase) {
        #expect(AgentPackageGrammar.parse(row.arguments) == row.expected)
    }
}
