import Foundation

package struct ClaudeCodePackageOptions: Equatable, Sendable {
    package let configurationDirectoryPath: String?
    package let providerVersion: String?

    package init(configurationDirectoryPath: String? = nil, providerVersion: String? = nil) {
        self.configurationDirectoryPath = configurationDirectoryPath
        self.providerVersion = providerVersion
    }
}

package enum AgentPackageInstallation: Equatable, Sendable {
    case claude(ClaudeCodePackageOptions)
    case codex(providerHomePath: String?)
    case cursor(providerHomePath: String?)
}

package enum AgentPackageInvocation: Equatable, Sendable {
    case help
    case usageError(String)
    case install(AgentPackageInstallation)
    case snippet(AgentPackageTarget)
    case status(AgentPackageStatusRequest)
}

/// Pure package syntax; provider files belong exclusively to installation.
package enum AgentPackageGrammar {
    package static let usage = """
        Usage: agentstudio package install claude [--config-dir PATH] [--provider-version VERSION]
               agentstudio package install codex [--codex-home PATH | --provider-home PATH]
               agentstudio package install cursor [--provider-home PATH | --codex-home PATH]
               agentstudio package snippet claude|codex|cursor [OPTIONS]
               agentstudio package status [claude|codex|cursor] [--json] [OPTIONS]
        Installs Agent Studio's hooks and skill for one provider. Without a path it uses the provider's default home.
        """

    package static let rootHelpLine =
        "  agentstudio package install|snippet|status claude|codex|cursor [OPTIONS]  (provider hooks and skill; see agentstudio package --help)"

    private static func status(_ arguments: [String]) -> AgentPackageInvocation {
        guard arguments.filter({ $0 == "--json" }).count <= 1 else { return .usageError("--json given more than once") }
        let rest = arguments.filter { $0 != "--json" }
        let json = arguments.contains("--json")
        if rest.isEmpty { return .status(.init(selection: .all, json: json)) }
        guard !rest.contains("--provider-version") else {
            return .usageError("unknown option --provider-version for status")
        }
        switch parse(["install"] + rest) {
        case .install(let installation): return .status(.init(selection: .provider(installation.target), json: json))
        case .usageError(let reason): return .usageError(reason)
        case .help: return .help
        case .snippet, .status: return .usageError("invalid status target")
        }
    }

    package static func parse(_ arguments: [String]) -> AgentPackageInvocation {
        if arguments.contains("--help") { return .help }
        guard let subcommand = arguments.first else { return .usageError("missing subcommand") }
        if subcommand == "status" { return status(Array(arguments.dropFirst())) }
        guard subcommand == "install" || subcommand == "snippet" else {
            return .usageError("unknown subcommand \(subcommand)")
        }
        guard arguments.count > 1 else { return .usageError("missing provider") }
        let provider = arguments[1]
        let acceptedOptions: [String]
        switch provider {
        case "claude": acceptedOptions = ["--config-dir", "--provider-version"]
        case "codex", "cursor": acceptedOptions = ["--codex-home", "--provider-home"]
        default: return .usageError("unknown provider \(provider)")
        }
        var values: [String: String] = [:]
        var index = 2
        while index < arguments.count {
            let option = arguments[index]
            guard option.hasPrefix("--") else { return .usageError("unexpected argument \(option)") }
            guard acceptedOptions.contains(option) else {
                return .usageError("unknown option \(option) for \(provider)")
            }
            guard index + 1 < arguments.count, !arguments[index + 1].isEmpty,
                !arguments[index + 1].hasPrefix("--")
            else { return .usageError("missing value for \(option)") }
            guard values[option] == nil else { return .usageError("\(option) given more than once") }
            if provider != "claude", !values.isEmpty {
                return .usageError("use one of --codex-home or --provider-home")
            }
            values[option] = arguments[index + 1]
            index += 2
        }
        let installation: AgentPackageInstallation
        switch provider {
        case "claude":
            installation = .claude(
                .init(configurationDirectoryPath: values["--config-dir"], providerVersion: values["--provider-version"])
            )
        case "codex": installation = .codex(providerHomePath: values["--codex-home"] ?? values["--provider-home"])
        default: installation = .cursor(providerHomePath: values["--provider-home"] ?? values["--codex-home"])
        }
        return subcommand == "snippet" ? .snippet(installation.target) : .install(installation)
    }
}

package struct AgentPackageTarget: Equatable, Sendable {
    package let provider: AgentPackageProvider
    package let homePath: String?

    package init(provider: AgentPackageProvider, homePath: String?) {
        self.provider = provider
        self.homePath = homePath
    }
}

extension AgentPackageInstallation {
    package var target: AgentPackageTarget {
        switch self {
        case .claude(let options): .init(provider: .claude, homePath: options.configurationDirectoryPath)
        case .codex(let path): .init(provider: .codex, homePath: path)
        case .cursor(let path): .init(provider: .cursor, homePath: path)
        }
    }
}
