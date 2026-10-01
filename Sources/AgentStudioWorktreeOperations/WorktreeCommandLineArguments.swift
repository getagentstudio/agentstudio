import Foundation

package struct WorktreeCommandLineInvocation: Sendable, Equatable {
    package let request: WorktreeOperationRequest
    package let usesJSONOutput: Bool

    package init(request: WorktreeOperationRequest, usesJSONOutput: Bool) {
        self.request = request
        self.usesJSONOutput = usesJSONOutput
    }
}

package enum WorktreeCommandLineArgumentError: Error, Equatable, Sendable {
    case missingSubcommand
    case unknownSubcommand
    case missingBranch
    case unexpectedArgument
    case unknownOption
    case unsupportedOption
    case missingOptionValue(String)
    case emptyOptionValue(String)
    case duplicateOption(String)

    package var message: String {
        switch self {
        case .missingSubcommand:
            "usage: agentstudio worktree new|fork|list [target...]"
        case .unknownSubcommand:
            "unknown worktree subcommand; expected new, fork, or list [target...]"
        case .missingBranch:
            "a branch name is required for worktree new and fork"
        case .unexpectedArgument:
            "unexpected positional argument"
        case .unknownOption:
            "unknown worktree option"
        case .unsupportedOption:
            "option is not supported for this worktree subcommand"
        case .missingOptionValue(let option):
            "\(option) requires a path"
        case .emptyOptionValue(let option):
            "\(option) path must not be empty"
        case .duplicateOption(let option):
            "\(option) may be specified only once"
        }
    }
}

package enum WorktreeCommandLineArgumentParser {
    package static func parse(
        _ arguments: [String],
        currentDirectory: URL
    ) throws -> WorktreeCommandLineInvocation {
        guard let subcommand = arguments.first else {
            throw WorktreeCommandLineArgumentError.missingSubcommand
        }

        let allowedPathOptions: Set<String>
        switch subcommand {
        case "new", "list":
            allowedPathOptions = ["--repo"]
        case "fork":
            allowedPathOptions = ["--from"]
        default:
            throw WorktreeCommandLineArgumentError.unknownSubcommand
        }

        let parsedArguments = try parseArguments(
            arguments.dropFirst(),
            subcommand: subcommand,
            currentDirectory: currentDirectory,
            allowedPathOptions: allowedPathOptions
        )
        let request = try makeRequest(
            subcommand: subcommand,
            positionalArguments: parsedArguments.positionalArguments,
            repositoryPath: parsedArguments.repositoryPath,
            sourcePath: parsedArguments.sourcePath,
            callerDirectory: currentDirectory,
            listFetchPolicy: parsedArguments.listFetchPolicy
        )
        return WorktreeCommandLineInvocation(request: request, usesJSONOutput: parsedArguments.usesJSONOutput)
    }

    private static func parseArguments(
        _ arguments: ArraySlice<String>,
        subcommand: String,
        currentDirectory: URL,
        allowedPathOptions: Set<String>
    ) throws -> ParsedArguments {
        var positionalArguments: [String] = []
        var repositoryPath: URL?
        var sourcePath: URL?
        var usesJSONOutput = false
        var listFetchPolicy = WorktreeFetchPolicy.defaultBranch
        var noFetchSpecified = false
        var index = arguments.startIndex

        while index < arguments.endIndex {
            let argument = arguments[index]
            if argument == "--json" {
                usesJSONOutput = true
                index += 1
                continue
            }

            if argument == "--no-fetch" {
                guard subcommand == "list" else {
                    throw WorktreeCommandLineArgumentError.unsupportedOption
                }
                guard !noFetchSpecified else {
                    throw WorktreeCommandLineArgumentError.duplicateOption(argument)
                }
                noFetchSpecified = true
                listFetchPolicy = .skip
                index += 1
                continue
            }

            if argument != "--repo" && argument != "--from" {
                if argument.hasPrefix("-") {
                    throw WorktreeCommandLineArgumentError.unknownOption
                }
                positionalArguments.append(argument)
                arguments.formIndex(after: &index)
                continue
            }

            guard allowedPathOptions.contains(argument) else {
                throw WorktreeCommandLineArgumentError.unsupportedOption
            }
            let valueIndex = arguments.index(after: index)
            guard valueIndex < arguments.endIndex else {
                throw WorktreeCommandLineArgumentError.missingOptionValue(argument)
            }
            let pathValue = arguments[valueIndex]
            guard !pathValue.isEmpty else {
                throw WorktreeCommandLineArgumentError.emptyOptionValue(argument)
            }
            guard !pathValue.hasPrefix("-") else {
                throw WorktreeCommandLineArgumentError.missingOptionValue(argument)
            }

            let path = URL(fileURLWithPath: pathValue, relativeTo: currentDirectory).standardizedFileURL
            if argument == "--repo" {
                guard repositoryPath == nil else {
                    throw WorktreeCommandLineArgumentError.duplicateOption(argument)
                }
                repositoryPath = path
            } else {
                guard sourcePath == nil else {
                    throw WorktreeCommandLineArgumentError.duplicateOption(argument)
                }
                sourcePath = path
            }
            index = arguments.index(after: valueIndex)
        }

        return ParsedArguments(
            positionalArguments: positionalArguments,
            repositoryPath: repositoryPath,
            sourcePath: sourcePath,
            usesJSONOutput: usesJSONOutput,
            listFetchPolicy: listFetchPolicy
        )
    }

    private static func makeRequest(
        subcommand: String,
        positionalArguments: [String],
        repositoryPath: URL?,
        sourcePath: URL?,
        callerDirectory: URL,
        listFetchPolicy: WorktreeFetchPolicy
    ) throws -> WorktreeOperationRequest {
        let request: WorktreeOperationRequest
        switch subcommand {
        case "new":
            guard let branch = positionalArguments.first else {
                throw WorktreeCommandLineArgumentError.missingBranch
            }
            guard positionalArguments.count == 1 else {
                throw WorktreeCommandLineArgumentError.unexpectedArgument
            }
            request = .createFromDefault(start: repositoryPath ?? callerDirectory, branch: branch)
        case "fork":
            guard let branch = positionalArguments.first else {
                throw WorktreeCommandLineArgumentError.missingBranch
            }
            guard positionalArguments.count == 1 else {
                throw WorktreeCommandLineArgumentError.unexpectedArgument
            }
            request = .fork(start: sourcePath ?? callerDirectory, branch: branch)
        case "list":
            request = .list(
                start: repositoryPath ?? callerDirectory,
                callerDirectory: callerDirectory,
                targets: positionalArguments,
                fetchPolicy: listFetchPolicy
            )
        default:
            throw WorktreeCommandLineArgumentError.unknownSubcommand
        }

        return request
    }
}

private struct ParsedArguments {
    let positionalArguments: [String]
    let repositoryPath: URL?
    let sourcePath: URL?
    let usesJSONOutput: Bool
    let listFetchPolicy: WorktreeFetchPolicy
}
