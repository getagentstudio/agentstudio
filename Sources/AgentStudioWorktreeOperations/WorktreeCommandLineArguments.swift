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
    case missingTarget
    case unexpectedArgument
    case unknownOption
    case unsupportedOption
    case missingOptionValue(String)
    case emptyOptionValue(String)
    case duplicateOption(String)
    case conflictingOptions(String, String)

    package var message: String {
        switch self {
        case .missingSubcommand:
            "usage: agentstudio worktree new|fork|list|remove [target...]"
        case .unknownSubcommand:
            "unknown worktree subcommand; expected new, fork, list, or remove [target...]"
        case .missingBranch:
            "a branch name is required for worktree new and fork"
        case .missingTarget:
            "at least one target is required for worktree remove"
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
        case .conflictingOptions(let first, let second):
            "\(first) and \(second) cannot be used together"
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
        case "remove":
            allowedPathOptions = ["--repo", "--archive-to"]
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
            callerDirectory: currentDirectory,
            parsedArguments: parsedArguments
        )
        return WorktreeCommandLineInvocation(request: request, usesJSONOutput: parsedArguments.usesJSONOutput)
    }

    private static func parseArguments(
        _ arguments: ArraySlice<String>,
        subcommand: String,
        currentDirectory: URL,
        allowedPathOptions: Set<String>
    ) throws -> ParsedArguments {
        var parsedArguments = ParsedArgumentAccumulator()
        var index = arguments.startIndex

        while index < arguments.endIndex {
            let argument = arguments[index]
            if try parsedArguments.consumeFlag(argument, subcommand: subcommand) {
                arguments.formIndex(after: &index)
                continue
            }
            if try parsedArguments.consumePathOption(
                argument,
                from: arguments,
                allowedPathOptions: allowedPathOptions,
                currentDirectory: currentDirectory,
                index: &index
            ) {
                continue
            }

            guard !argument.hasPrefix("-") else {
                throw WorktreeCommandLineArgumentError.unknownOption
            }
            parsedArguments.positionalArguments.append(argument)
            arguments.formIndex(after: &index)
        }

        return try parsedArguments.finish()
    }

    private static func makeRequest(
        subcommand: String,
        callerDirectory: URL,
        parsedArguments: ParsedArguments
    ) throws -> WorktreeOperationRequest {
        let positionalArguments = parsedArguments.positionalArguments
        let repositoryPath = parsedArguments.repositoryPath
        let sourcePath = parsedArguments.sourcePath
        let archivePath = parsedArguments.archivePath
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
                fetchPolicy: parsedArguments.fetchPolicy
            )
        case "remove":
            guard !positionalArguments.isEmpty else {
                throw WorktreeCommandLineArgumentError.missingTarget
            }
            let branchPolicy: WorktreeBranchPolicy
            if parsedArguments.deleteAtObservedCommit {
                branchPolicy = .deleteAtObservedCommit
            } else if parsedArguments.keepBranch {
                branchPolicy = .keep
            } else {
                branchPolicy = .deleteIfIntegrated
            }
            let evidencePolicy: WorktreeEvidencePolicy
            if parsedArguments.archiveToMain {
                evidencePolicy = .archiveToMain
            } else if let archivePath {
                evidencePolicy = .archive(to: archivePath)
            } else if parsedArguments.discardTmp {
                evidencePolicy = .discard
            } else {
                evidencePolicy = .requireEmpty
            }
            request = .remove(
                WorktreeRemovalRequest(
                    start: repositoryPath ?? callerDirectory,
                    callerDirectory: callerDirectory,
                    targets: positionalArguments,
                    discardWorkingChanges: parsedArguments.discardWorkingChanges,
                    branchPolicy: branchPolicy,
                    evidencePolicy: evidencePolicy,
                    fetchPolicy: parsedArguments.fetchPolicy,
                    removeStaleLock: parsedArguments.removeStaleLock,
                    closePanes: false,
                    removeWithOpenPanes: false,
                    dryRun: parsedArguments.dryRun
                ))
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
    let archivePath: URL?
    let usesJSONOutput: Bool
    let fetchPolicy: WorktreeFetchPolicy
    let discardWorkingChanges: Bool
    let deleteAtObservedCommit: Bool
    let keepBranch: Bool
    let archiveToMain: Bool
    let discardTmp: Bool
    let removeStaleLock: Bool
    let dryRun: Bool
}

private struct ParsedArgumentAccumulator {
    var positionalArguments: [String] = []
    var repositoryPath: URL?
    var sourcePath: URL?
    var archivePath: URL?
    var usesJSONOutput = false
    var fetchPolicy = WorktreeFetchPolicy.defaultBranch
    var discardWorkingChanges = false
    var deleteAtObservedCommit = false
    var keepBranch = false
    var archiveToMain = false
    var discardTmp = false
    var removeStaleLock = false
    var dryRun = false
    private var noFetchSpecified = false
    private var evidenceOptionOrder: [String] = []
    private var seenFlags: Set<String> = []

    mutating func consumeFlag(_ argument: String, subcommand: String) throws -> Bool {
        if argument == "--json" {
            usesJSONOutput = true
            return true
        }
        if argument == "--no-fetch" {
            guard subcommand == "list" || subcommand == "remove" else {
                throw WorktreeCommandLineArgumentError.unsupportedOption
            }
            guard !noFetchSpecified else {
                throw WorktreeCommandLineArgumentError.duplicateOption(argument)
            }
            noFetchSpecified = true
            fetchPolicy = .skip
            return true
        }
        guard Self.removeFlags.contains(argument) else { return false }
        guard subcommand == "remove" else {
            throw WorktreeCommandLineArgumentError.unsupportedOption
        }
        guard seenFlags.insert(argument).inserted else {
            throw WorktreeCommandLineArgumentError.duplicateOption(argument)
        }
        switch argument {
        case "-f": discardWorkingChanges = true
        case "-D": deleteAtObservedCommit = true
        case "--no-delete-branch": keepBranch = true
        case "--archive-to-main":
            archiveToMain = true
            evidenceOptionOrder.append(argument)
        case "--discard-tmp":
            discardTmp = true
            evidenceOptionOrder.append(argument)
        case "--remove-stale-lock": removeStaleLock = true
        case "--dry-run": dryRun = true
        default: break
        }
        return true
    }

    mutating func consumePathOption(
        _ argument: String,
        from arguments: ArraySlice<String>,
        allowedPathOptions: Set<String>,
        currentDirectory: URL,
        index: inout ArraySlice<String>.Index
    ) throws -> Bool {
        guard Self.pathOptions.contains(argument) else { return false }
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
        switch argument {
        case "--repo":
            guard repositoryPath == nil else { throw WorktreeCommandLineArgumentError.duplicateOption(argument) }
            repositoryPath = path
        case "--from":
            guard sourcePath == nil else { throw WorktreeCommandLineArgumentError.duplicateOption(argument) }
            sourcePath = path
        case "--archive-to":
            guard archivePath == nil else { throw WorktreeCommandLineArgumentError.duplicateOption(argument) }
            archivePath = path
            evidenceOptionOrder.append(argument)
        default:
            throw WorktreeCommandLineArgumentError.unsupportedOption
        }
        index = arguments.index(after: valueIndex)
        return true
    }

    func finish() throws -> ParsedArguments {
        if deleteAtObservedCommit, keepBranch {
            throw WorktreeCommandLineArgumentError.conflictingOptions("-D", "--no-delete-branch")
        }
        guard evidenceOptionOrder.count <= 1 else {
            throw WorktreeCommandLineArgumentError.conflictingOptions(
                evidenceOptionOrder[0], evidenceOptionOrder[1]
            )
        }
        return ParsedArguments(
            positionalArguments: positionalArguments,
            repositoryPath: repositoryPath,
            sourcePath: sourcePath,
            archivePath: archivePath,
            usesJSONOutput: usesJSONOutput,
            fetchPolicy: fetchPolicy,
            discardWorkingChanges: discardWorkingChanges,
            deleteAtObservedCommit: deleteAtObservedCommit,
            keepBranch: keepBranch,
            archiveToMain: archiveToMain,
            discardTmp: discardTmp,
            removeStaleLock: removeStaleLock,
            dryRun: dryRun
        )
    }

    private static let removeFlags: Set<String> = [
        "-f", "-D", "--no-delete-branch", "--archive-to-main", "--discard-tmp",
        "--remove-stale-lock", "--dry-run",
    ]
    private static let pathOptions: Set<String> = ["--repo", "--from", "--archive-to"]
}
