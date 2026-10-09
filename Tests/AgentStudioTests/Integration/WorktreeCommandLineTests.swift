import AgentStudioGit
import AgentStudioInfrastructure
import AgentStudioTestSupport
import AgentStudioWorktreeOperations
import Foundation
import Testing

@Suite("Worktree command line")
struct WorktreeCommandLineTests {
    private struct FormatterGolden {
        let outcome: WorktreeOperationOutcome
        let humanText: String
        let jsonText: String
        let exitCode: Int32
    }

    private static func runnerThatWouldFailIfCalled() -> WorktreeOperationRunner {
        let start = URL(fileURLWithPath: "/path/that/does/not/exist", isDirectory: true)
        let repository = URL(fileURLWithPath: "/path/that/does/not/exist/repository", isDirectory: true)
        let repositoryID = GitRepositoryID(rawValue: "common:/path/that/does/not/exist/repository.git")
        let snapshot = GitWorktreeSnapshot(
            id: GitWorktreeID(rawValue: "help|worktree:source"),
            repositoryID: repositoryID,
            displayName: "main",
            path: start,
            canonicalPath: start,
            gitDirectory: start.appending(path: ".git"),
            indexPath: start.appending(path: ".git/index"),
            isMainWorktree: true,
            isLocked: false,
            lockReason: nil,
            head: nil
        )
        let identity = GitRepositoryIdentity(
            id: repositoryID,
            canonicalCommonDirectory: repository.appending(path: ".git"),
            mainWorktreePath: repository
        )
        let client = WorktreeOperationClientStub(
            startPath: start,
            snapshot: snapshot,
            identity: identity,
            failsWorktreeListing: true,
            failsDefaultTargetResolution: true
        )
        return WorktreeOperationRunner(client: client)
    }

    @Test(
        "worktree help prints the overview without invoking the runner",
        arguments: [[], ["--help"], ["-h"], ["help"]])
    func printsOverviewHelp(arguments: [String]) async {
        let probe = WorktreeCommandLineTestProbe()
        let exitCode = await WorktreeCommandLine.run(
            arguments: arguments,
            currentDirectory: URL(fileURLWithPath: "/path/that/does/not/exist", isDirectory: true),
            output: { probe.appendOutput($0) },
            errorOutput: { probe.appendErrorOutput($0) },
            runner: Self.runnerThatWouldFailIfCalled())

        #expect(exitCode == 0)
        #expect(probe.outputSnapshot() == [WorktreeCommandLineHelp.overview])
        #expect(probe.errorOutputSnapshot().isEmpty)
    }

    @Test(
        "each worktree verb help prints its usage without invoking the runner",
        arguments: ["new", "list", "remove", "prune"])
    func printsVerbHelp(command: String) async {
        let expected = WorktreeCommandLineHelp.usage(for: command) ?? ""
        for helpFlag in ["--help", "-h"] {
            let probe = WorktreeCommandLineTestProbe()
            let exitCode = await WorktreeCommandLine.run(
                arguments: [command, helpFlag],
                currentDirectory: URL(fileURLWithPath: "/path/that/does/not/exist", isDirectory: true),
                output: { probe.appendOutput($0) },
                errorOutput: { probe.appendErrorOutput($0) },
                runner: Self.runnerThatWouldFailIfCalled())

            #expect(exitCode == 0)
            #expect(probe.outputSnapshot() == [expected])
            #expect(probe.errorOutputSnapshot().isEmpty)
        }
    }

    @Test("worktree help documents every option accepted by the parser")
    func helpDocumentsParserOptions() {
        let acceptedOptions: [String: [String]] = [
            "new": [
                "-c", "--create", "--repo", "--from", "--from-branch", "--no-fork", "--changes-only",
                "--no-fetch", "--json",
            ],
            "list": ["--repo", "--no-fetch", "--json"],
            "remove": [
                "--repo", "--no-fetch", "-f", "--force", "-D", "--no-delete-branch", "--archive-to-main",
                "--archive-to", "--discard-tmp", "--remove-stale-lock", "--dry-run", "--json",
            ],
            "prune": ["--repo", "--no-fetch", "--archive-to-main", "--archive-to", "--apply", "--json"],
        ]

        for (command, options) in acceptedOptions {
            let help = WorktreeCommandLineHelp.usage(for: command) ?? ""
            for option in options {
                #expect(help.contains(option), "missing \(option) from \(command) help")
            }
        }

        #expect(!WorktreeCommandLineHelp.newUsage.contains("--tracked-only"))
        #expect(!WorktreeCommandLineHelp.pruneUsage.contains("--force"))
        #expect(!WorktreeCommandLineHelp.pruneUsage.contains("-D"))
    }

    @Test("argument parsing maps list --repo to an absolute start")
    func parsesListRepositoryPath() throws {
        let currentDirectory = URL(fileURLWithPath: "/tmp/worktree-cli", isDirectory: true)

        let list = try WorktreeCommandLineArgumentParser.parse(
            ["list", "--repo", "/tmp/another-repository"],
            currentDirectory: currentDirectory
        )
        #expect(
            list
                == WorktreeCommandLineInvocation(
                    request: .list(
                        start: URL(fileURLWithPath: "/tmp/another-repository"),
                        callerDirectory: currentDirectory,
                        targets: [],
                        fetchPolicy: .fetch
                    ),
                    usesJSONOutput: false
                ))
    }

    @Test("list preserves caller directory, filters, and fetch policy")
    func parsesListCallerDirectoryTargetsAndFetchPolicy() throws {
        let currentDirectory = URL(fileURLWithPath: "/tmp/linked-worktree/nested", isDirectory: true)
        let repository = URL(fileURLWithPath: "/tmp/another-repository")

        let noFetch = try WorktreeCommandLineArgumentParser.parse(
            ["list", "feature/search", "../worktrees/one", "--repo", repository.path, "--no-fetch", "--json"],
            currentDirectory: currentDirectory
        )
        #expect(
            noFetch
                == WorktreeCommandLineInvocation(
                    request: .list(
                        start: repository,
                        callerDirectory: currentDirectory,
                        targets: ["feature/search", "../worktrees/one"],
                        fetchPolicy: .skip
                    ),
                    usesJSONOutput: true
                ))

        let defaultFetch = try WorktreeCommandLineArgumentParser.parse(
            ["list"],
            currentDirectory: currentDirectory
        )
        #expect(
            defaultFetch
                == WorktreeCommandLineInvocation(
                    request: .list(
                        start: currentDirectory,
                        callerDirectory: currentDirectory,
                        targets: [],
                        fetchPolicy: .fetch
                    ),
                    usesJSONOutput: false
                ))
    }

    @Test("prune parsing preserves caller directory, fetch, archive, and apply policy")
    func parsesPrunePolicies() throws {
        let currentDirectory = URL(fileURLWithPath: "/tmp/linked-worktree/nested", isDirectory: true)
        let repository = currentDirectory.appending(path: "../repositories/main").standardizedFileURL

        let preview = try WorktreeCommandLineArgumentParser.parse(
            ["prune", "--repo", "../repositories/main", "--no-fetch", "--json"],
            currentDirectory: currentDirectory
        )
        #expect(
            preview
                == WorktreeCommandLineInvocation(
                    request: .prune(
                        WorktreePruneRequest(
                            start: repository,
                            callerDirectory: currentDirectory,
                            apply: false,
                            evidencePolicy: .requireEmpty,
                            fetchPolicy: .skip
                        )
                    ),
                    usesJSONOutput: true
                ))

        let apply = try WorktreeCommandLineArgumentParser.parse(
            ["prune", "--repo", repository.path, "--apply", "--archive-to-main"],
            currentDirectory: currentDirectory
        )
        #expect(
            apply
                == WorktreeCommandLineInvocation(
                    request: .prune(
                        WorktreePruneRequest(
                            start: repository,
                            callerDirectory: currentDirectory,
                            apply: true,
                            evidencePolicy: .archiveToMain,
                            fetchPolicy: .fetch
                        )
                    ),
                    usesJSONOutput: false
                ))
    }

    @Test("remove accepts --force as the -f alias and prune rejects it")
    func parsesForceAliasOnlyForRemoval() throws {
        let currentDirectory = URL(fileURLWithPath: "/tmp/worktree-cli", isDirectory: true)
        let shortForce = try WorktreeCommandLineArgumentParser.parse(
            ["remove", "feature/force", "-f"],
            currentDirectory: currentDirectory
        )
        let longForce = try WorktreeCommandLineArgumentParser.parse(
            ["remove", "feature/force", "--force"],
            currentDirectory: currentDirectory
        )
        #expect(longForce == shortForce)

        do {
            _ = try WorktreeCommandLineArgumentParser.parse(
                ["remove", "feature/force", "-f", "--force"],
                currentDirectory: currentDirectory
            )
            Issue.record("expected aliases for one option to be rejected as duplicates")
        } catch let error as WorktreeCommandLineArgumentError {
            #expect(error == .duplicateOption("--force"))
        }

        do {
            _ = try WorktreeCommandLineArgumentParser.parse(
                ["prune", "--force"],
                currentDirectory: currentDirectory
            )
            Issue.record("expected prune --force to be rejected")
        } catch let error as WorktreeCommandLineArgumentError {
            #expect(error == .unsupportedOption)
        }
    }

    @Test("path options reject another option as their value")
    func pathOptionsRejectFollowingFlagsAsValues() throws {
        let currentDirectory = URL(fileURLWithPath: "/tmp/worktree-cli", isDirectory: true)
        let argumentCases: [(arguments: [String], option: String)] = [
            (arguments: ["new", "feature/new", "--repo", "--json"], option: "--repo"),
            (arguments: ["new", "feature/fork", "--from", "--json"], option: "--from"),
        ]

        for argumentCase in argumentCases {
            do {
                _ = try WorktreeCommandLineArgumentParser.parse(
                    argumentCase.arguments,
                    currentDirectory: currentDirectory
                )
                Issue.record("expected \(argumentCase.option) to reject the following flag as a missing value")
            } catch let error as WorktreeCommandLineArgumentError {
                #expect(error == .missingOptionValue(argumentCase.option))
            }
        }
    }

    @Test("malformed arguments write one usage line to stderr and return 64")
    func reportsMalformedArgumentsAsUsageErrors() async {
        // A bare `worktree` prints help (LR32); an option with no command is still a usage error.
        let malformedForms: [[String]] = [
            ["--json"],
            ["unknown"],
            ["list", "--unknown"],
            ["list", "--no-fetch", "--no-fetch"],
            ["fork", "feature/fork", "--repo", "/tmp/repository"],
            ["list", "--repo"],
            ["new", "feature/new", "--repo", "--json"],
            ["new", "feature/new", "--from-branch", "--json"],
            ["new", "feature/new", "--from-branch", "feature/start", "--from-branch", "feature/other"],
            ["new", "feature/new", "--changes-only", "--changes-only"],
            ["new", "feature/new", "--tracked-only"],
            ["new", "feature/new", "--no-fork", "--no-fork"],
            ["new", "feature/new", "--json", "--json"],
            ["new", "feature/fork", "--from", "--json"],
            ["new", "feature/new", "--from-branch", "feature/start"],
            ["new", "feature/new", "-c", "--create"],
            ["list", "-c"],
            ["fork", "feature/fork", "--from-branch", "feature/start"],
            ["fork", "feature/fork", "--changes-only", "--changes-only"],
            ["new"],
            ["fork"],
        ]
        let currentDirectory = URL(fileURLWithPath: "/tmp/worktree-cli", isDirectory: true)

        for malformedForm in malformedForms {
            for includeJSONFlag in [false, true] {
                let arguments = includeJSONFlag ? malformedForm + ["--json"] : malformedForm
                let probe = WorktreeCommandLineTestProbe()
                let exitCode = await WorktreeCommandLine.run(
                    arguments: arguments,
                    currentDirectory: currentDirectory,
                    output: { probe.appendOutput($0) },
                    errorOutput: { probe.appendErrorOutput($0) }
                )

                #expect(exitCode == 64)
                #expect(probe.outputSnapshot().isEmpty)
                let errorLines = probe.errorOutputSnapshot()
                #expect(errorLines.count == 1)
                #expect(errorLines.first?.isEmpty == false)
                #expect(errorLines.first?.contains("\n") == false)
            }
        }
    }

    @Test("human and JSON formatters cover created listed refused and failed outcomes")
    func formatsEveryOutcomeKind() throws {
        let repository = URL(fileURLWithPath: "/tmp/worktree-output/repository")
        let createdPath = URL(fileURLWithPath: "/tmp/worktree-output/repository.feature-cli")
        let failureResidue = WorktreeCleanupLeftover(
            kind: .createdBranch,
            location: "refs/heads/feature/cli",
            base: .branchReference
        )
        let cases =
            createdFormatterGoldens(repository: repository, createdPath: createdPath) + [
                FormatterGolden(
                    outcome: .listed(
                        WorktreeListingSummary(
                            repository: repository,
                            target: nil,
                            fetch: .skipped(reason: .noTarget),
                            worktrees: []
                        )
                    ),
                    humanText: "fetch: skipped (noTarget)",
                    jsonText:
                        "{\"fetch\":{\"reason\":\"noTarget\",\"status\":\"skipped\"},\"outcome\":\"listed\",\"repository\":\"/tmp/worktree-output/repository\",\"target\":null,\"worktrees\":[]}",
                    exitCode: 0
                ),
                FormatterGolden(
                    outcome: .fetchingReadFailure(WorktreeFetchingReadFailure(fetch: .skipped(reason: .noTarget))),
                    humanText: "failed: readFailed; leftovers: notNeeded; fetch: skipped (noTarget)",
                    jsonText:
                        "{\"failure\":{\"kind\":\"readFailed\"},\"fetch\":{\"reason\":\"noTarget\",\"status\":\"skipped\"},\"leftovers\":{\"status\":\"notNeeded\"},\"outcome\":\"failed\"}",
                    exitCode: 2
                ),
                FormatterGolden(
                    outcome: .refused(.destinationExists(createdPath)),
                    humanText: "refused: destinationExists /tmp/worktree-output/repository.feature-cli",
                    jsonText:
                        "{\"outcome\":\"refused\",\"path\":\"/tmp/worktree-output/repository.feature-cli\",\"reason\":\"destinationExists\"}",
                    exitCode: 1
                ),
                FormatterGolden(
                    outcome: .refused(.forkUnavailable(.sourceFilesystemNotAPFS, offersChangesOnly: false)),
                    humanText:
                        "refused: forkUnavailable sourceFilesystemNotAPFS --no-fork; options: [--no-fork: A plain checkout of tracked files at the same commit; no ignored files or build outputs.]",
                    jsonText:
                        "{\"alternatives\":[\"checkout\"],\"detail\":\"sourceFilesystemNotAPFS\",\"options\":[{\"effect\":\"A plain checkout of tracked files at the same commit; no ignored files or build outputs.\",\"flag\":\"--no-fork\"}],\"outcome\":\"refused\",\"reason\":\"forkUnavailable\"}",
                    exitCode: 1
                ),
                FormatterGolden(
                    outcome: .refused(.creationStopped(.sourceIndexUnreadable)),
                    humanText:
                        "refused: sourceIndexUnreadable; options: [retry: Retry after the source can be read.; --no-fork: A plain checkout of tracked files at the same commit; no ignored files or build outputs.]",
                    jsonText:
                        "{\"details\":{\"sourceIndexUnreadable\":{}},\"message\":\"The source index could not be read.\",\"options\":[{\"command\":\"retry\",\"effect\":\"Retry after the source can be read.\"},{\"effect\":\"A plain checkout of tracked files at the same commit; no ignored files or build outputs.\",\"flag\":\"--no-fork\"}],\"outcome\":\"refused\",\"reason\":\"sourceIndexUnreadable\"}",
                    exitCode: 1
                ),
                FormatterGolden(
                    outcome: .refused(.creationStopped(.branchAlreadyExists(branch: "feature/cli"))),
                    humanText:
                        "refused: branchAlreadyExists feature/cli; options: [agentstudio worktree new <branch>: Open the existing branch in a new worktree.; use another branch name: Create a new branch under a name that does not exist.]",
                    jsonText:
                        "{\"detail\":\"feature/cli\",\"details\":{\"branchAlreadyExists\":{\"branch\":\"feature/cli\"}},\"message\":\"A branch with that name already exists.\",\"options\":[{\"command\":\"agentstudio worktree new <branch>\",\"effect\":\"Open the existing branch in a new worktree.\"},{\"command\":\"use another branch name\",\"effect\":\"Create a new branch under a name that does not exist.\"}],\"outcome\":\"refused\",\"reason\":\"branchAlreadyExists\"}",
                    exitCode: 1
                ),
                FormatterGolden(
                    outcome: .refused(.creationStopped(.branchCheckedOut(path: createdPath.path))),
                    humanText:
                        "refused: branchCheckedOut /tmp/worktree-output/repository.feature-cli; options: [cd <path>: Work in the worktree that already has the branch checked out.]",
                    jsonText:
                        "{\"details\":{\"branchCheckedOut\":{\"path\":\"/tmp/worktree-output/repository.feature-cli\"}},\"message\":\"The branch is checked out in another worktree.\",\"options\":[{\"command\":\"cd <path>\",\"effect\":\"Work in the worktree that already has the branch checked out.\"}],\"outcome\":\"refused\",\"path\":\"/tmp/worktree-output/repository.feature-cli\",\"reason\":\"branchCheckedOut\"}",
                    exitCode: 1
                ),
                FormatterGolden(
                    outcome: .refused(.creationStopped(.branchMoved)),
                    humanText:
                        "refused: branchMoved; options: [retry: Run the command again to resolve the branch at its new tip.]",
                    jsonText:
                        "{\"details\":{\"branchMoved\":{}},\"message\":\"The branch moved after it was resolved, so nothing was changed.\",\"options\":[{\"command\":\"retry\",\"effect\":\"Run the command again to resolve the branch at its new tip.\"}],\"outcome\":\"refused\",\"reason\":\"branchMoved\"}",
                    exitCode: 1
                ),
                FormatterGolden(
                    outcome: .failed(
                        WorktreeOperationFailure(
                            failure: .rejectedAfterChange(.branchAlreadyExists),
                            leftovers: .incomplete([failureResidue])
                        )
                    ),
                    humanText:
                        "failed: rejectedAfterChange branchAlreadyExists; leftovers: incomplete [createdBranch refs/heads/feature/cli (branch reference)]",
                    jsonText:
                        "{\"failure\":{\"kind\":\"rejectedAfterChange\",\"reason\":\"branchAlreadyExists\"},\"leftovers\":{\"items\":[{\"base\":\"branchReference\",\"kind\":\"createdBranch\",\"location\":\"refs/heads/feature/cli\"}],\"status\":\"incomplete\"},\"outcome\":\"failed\"}",
                    exitCode: 2
                ),
            ]

        try expectFormatterGoldens(cases)
    }

    private func createdFormatterGoldens(repository: URL, createdPath: URL) -> [FormatterGolden] {
        [
            FormatterGolden(
                outcome: .created(
                    makeCreatedSummary(
                        branch: "feature/cli",
                        path: createdPath,
                        repository: repository,
                        materialization: .checkout(
                            GitLargeFileFill(materializedCount: 0, missing: [], residuePaths: [], scan: .complete))
                    )
                ),
                humanText: "created feature/cli at /tmp/worktree-output/repository.feature-cli (checkout)",
                jsonText:
                    "{\"branch\":{\"name\":\"feature/cli\",\"status\":\"created\",\"upstream\":null},\"fetch\":{\"branch\":null,\"reason\":\"noRemote\",\"remote\":null,\"status\":\"skipped\"},\"materialization\":{\"kind\":\"checkout\",\"largeFiles\":{\"materialized\":0,\"missing\":[],\"missingCount\":0,\"scan\":\"complete\"}},\"operation\":\"new\",\"outcome\":\"created\",\"path\":\"/tmp/worktree-output/repository.feature-cli\",\"repository\":\"/tmp/worktree-output/repository\",\"start\":{\"commit\":\"1111111111111111111111111111111111111111\",\"from\":\"sourceHead\",\"localOnlyCommits\":null,\"ref\":null}}",
                exitCode: 0
            ),
            FormatterGolden(
                outcome: .created(
                    makeCreatedSummary(
                        branch: "feature/cow",
                        path: createdPath,
                        repository: repository,
                        materialization: .copyOnWrite(
                            GitWorktreeMaterializationReport(
                                clonedRegularFileCount: 0,
                                createdDirectoryCount: 0,
                                recreatedSymbolicLinkCount: 0,
                                preservedHardLinkCount: 0,
                                preservedGitRepositoryCount: 0,
                                recreatedFIFOCount: 0,
                                logicalRegularFileBytes: 0,
                                skippedEntries: [],
                                normalizedEntries: [],
                                ignoredIncludedPatterns: [], ignoredExcludedCount: 0, nestedWorktreesSkipped: [],
                                sourceState: .asIs, submodulesNotAtStart: [], largeFiles: nil
                            ))
                    )
                ),
                humanText: "created feature/cow at /tmp/worktree-output/repository.feature-cli (copy-on-write)",
                jsonText:
                    "{\"branch\":{\"name\":\"feature/cow\",\"status\":\"created\",\"upstream\":null},\"fetch\":{\"branch\":null,\"reason\":\"noRemote\",\"remote\":null,\"status\":\"skipped\"},\"materialization\":{\"clonedRegularFileCount\":0,\"createdDirectoryCount\":0,\"ignoredExcludedCount\":0,\"ignoredIncludedPatterns\":[],\"kind\":\"copyOnWrite\",\"logicalRegularFileBytes\":0,\"nestedWorktreesSkipped\":[],\"normalizedEntries\":[],\"preservedGitRepositoryCount\":0,\"preservedHardLinkCount\":0,\"recreatedFIFOCount\":0,\"recreatedSymbolicLinkCount\":0,\"skippedEntries\":[],\"sourceState\":\"asIs\",\"submodulesNotAtStart\":[]},\"operation\":\"new\",\"outcome\":\"created\",\"path\":\"/tmp/worktree-output/repository.feature-cli\",\"repository\":\"/tmp/worktree-output/repository\",\"start\":{\"commit\":\"1111111111111111111111111111111111111111\",\"from\":\"sourceHead\",\"localOnlyCommits\":null,\"ref\":null}}",
                exitCode: 0
            ),
        ]
    }

    @Test("working-state outcomes preserve the SDK refusal details in human and JSON output")
    func formatsWorkingStateOutcomes() throws {
        let cases: [FormatterGolden] = [
            FormatterGolden(
                outcome: .refused(
                    .unsupportedWorkingState(
                        GitWorktreeWorkingStateRefusal(reason: .attributesChanged, relativePath: ".gitattributes"))
                ),
                humanText:
                    "refused: unsupportedWorkingState .gitattributes attributesChanged; options: [commit the changed .gitattributes first: Commit the changed attributes, then retry --changes-only.; stash the changed .gitattributes first: Stash the changed attributes, then retry --changes-only.; agentstudio worktree new -c <branch> --from <source>: Use the APFS copy-on-write fork without --changes-only.]",
                jsonText:
                    "{\"detail\":\"attributesChanged\",\"options\":[{\"command\":\"commit the changed .gitattributes first\",\"effect\":\"Commit the changed attributes, then retry --changes-only.\"},{\"command\":\"stash the changed .gitattributes first\",\"effect\":\"Stash the changed attributes, then retry --changes-only.\"},{\"command\":\"agentstudio worktree new -c <branch> --from <source>\",\"effect\":\"Use the APFS copy-on-write fork without --changes-only.\"}],\"outcome\":\"refused\",\"path\":\".gitattributes\",\"reason\":\"unsupportedWorkingState\"}",
                exitCode: 1
            ),
            FormatterGolden(
                outcome: .failed(
                    WorktreeOperationFailure(
                        failure: .workingStateUnsupported(
                            GitWorktreeWorkingStateRefusal(reason: .customFilter, relativePath: "tracked.bin")),
                        leftovers: .noLeftovers
                    )
                ),
                humanText: "failed: workingStateUnsupported customFilter tracked.bin; leftovers: noLeftovers",
                jsonText:
                    "{\"failure\":{\"kind\":\"workingStateUnsupported\",\"reason\":\"customFilter\",\"relativePath\":\"tracked.bin\"},\"leftovers\":{\"status\":\"noLeftovers\"},\"outcome\":\"failed\"}",
                exitCode: 2
            ),
        ]

        for testCase in cases {
            #expect(
                try WorktreeCommandLineFormatter.format(outcome: testCase.outcome, usesJSONOutput: false)
                    == WorktreeCommandLineResponse(text: testCase.humanText, exitCode: testCase.exitCode))
            let jsonResponse = try WorktreeCommandLineFormatter.format(
                outcome: testCase.outcome,
                usesJSONOutput: true
            )
            #expect(jsonResponse.text == testCase.jsonText)
            #expect(jsonResponse.exitCode == testCase.exitCode)
        }
    }

    private func expectFormatterGoldens(_ cases: [FormatterGolden]) throws {
        for testCase in cases {
            #expect(
                try WorktreeCommandLineFormatter.format(outcome: testCase.outcome, usesJSONOutput: false)
                    == WorktreeCommandLineResponse(text: testCase.humanText, exitCode: testCase.exitCode))
            let jsonResponse = try WorktreeCommandLineFormatter.format(
                outcome: testCase.outcome,
                usesJSONOutput: true
            )
            #expect(jsonResponse.text == testCase.jsonText)
            #expect(jsonResponse.exitCode == testCase.exitCode)
        }
    }

    @Test("new and list use --repo while dispatch bypasses IPC creation and credential reads")
    func createsAndListsFromExplicitRepositoryBeforeIPCDispatch() async throws {
        let repository = try await FilesystemTestGitRepo.create(named: "cli-explicit-repository")
        defer { FilesystemTestGitRepo.destroy(repository) }
        try await FilesystemTestGitRepo.seedTrackedAndUntrackedChanges(at: repository)
        let branch = "feature/cli-new"
        let branchName = try WorktreeBranchName.validated(branch).get()
        guard
            let destination = WorktreeDestinationNaming.siblingPath(
                repositoryPath: repository,
                branchName: branchName
            )
        else {
            Issue.record("expected a sibling destination for the validated branch")
            return
        }
        defer { try? FileManager.default.removeItem(at: destination) }

        let outsideRepository = repository.deletingLastPathComponent()
        let dispatchProbe = WorktreeCommandLineTestProbe()
        let dispatchExitCode = await WorktreeCommandLine.dispatch(
            arguments: ["worktree", "list", "--repo", repository.path],
            currentDirectory: outsideRepository,
            output: { dispatchProbe.appendOutput($0) },
            errorOutput: { dispatchProbe.appendErrorOutput($0) },
            runIPCCommand: {
                dispatchProbe.recordIPCClientFactoryCall()
                dispatchProbe.recordCredentialReaderCall()
                return 99
            }
        )
        #expect(dispatchExitCode == 0)
        #expect(
            dispatchProbe.outputSnapshot()
                == [
                    "fetch: skipped (noRemote)\nmain main at \(repository.standardizedFileURL.path)  dirty  isTarget"
                ])
        #expect(dispatchProbe.ipcClientFactoryCallCount() == 0)
        #expect(dispatchProbe.credentialReaderCallCount() == 0)

        let createProbe = WorktreeCommandLineTestProbe()
        let createExitCode = await WorktreeCommandLine.run(
            arguments: ["new", "-c", branch, "--no-fork", "--repo", repository.path],
            currentDirectory: outsideRepository,
            output: { createProbe.appendOutput($0) },
            errorOutput: { createProbe.appendErrorOutput($0) }
        )
        #expect(createExitCode == 0)
        #expect(
            createProbe.outputSnapshot() == ["created \(branch) at \(destination.standardizedFileURL.path) (checkout)"])

        let createdListingProbe = WorktreeCommandLineTestProbe()
        let listAfterCreateExitCode = await WorktreeCommandLine.run(
            arguments: ["list", "--repo", repository.path],
            currentDirectory: outsideRepository,
            output: { createdListingProbe.appendOutput($0) },
            errorOutput: { createdListingProbe.appendErrorOutput($0) }
        )
        #expect(listAfterCreateExitCode == 0)
        let createdListingOutput = createdListingProbe.outputSnapshot()
        #expect(createdListingOutput.count == 1)
        #expect(createdListingOutput[0].contains("feature/cli-new at \(destination.standardizedFileURL.path)"))
    }

    @Test("non-worktree dispatch preserves the IPC command path")
    func dispatchesOtherCommandsToIPCRunner() async {
        let dispatchProbe = WorktreeCommandLineTestProbe()
        let exitCode = await WorktreeCommandLine.dispatch(
            arguments: ["command", "list"],
            currentDirectory: URL(fileURLWithPath: "/tmp", isDirectory: true),
            output: { dispatchProbe.appendOutput($0) },
            errorOutput: { dispatchProbe.appendErrorOutput($0) },
            runIPCCommand: {
                dispatchProbe.recordIPCCommandCall()
                return 7
            }
        )

        #expect(exitCode == 7)
        #expect(dispatchProbe.ipcCommandCallCount() == 1)
        #expect(dispatchProbe.outputSnapshot().isEmpty)
    }
}

private final class WorktreeCommandLineTestProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var outputs: [String] = []
    private var errorOutputs: [String] = []
    private var ipcClientFactoryCalls = 0
    private var credentialReaderCalls = 0
    private var ipcCommandCalls = 0

    func appendOutput(_ output: String) {
        lock.lock()
        outputs.append(output)
        lock.unlock()
    }

    func appendErrorOutput(_ output: String) {
        lock.lock()
        errorOutputs.append(output)
        lock.unlock()
    }

    func recordIPCClientFactoryCall() {
        lock.lock()
        ipcClientFactoryCalls += 1
        lock.unlock()
    }

    func recordCredentialReaderCall() {
        lock.lock()
        credentialReaderCalls += 1
        lock.unlock()
    }

    func recordIPCCommandCall() {
        lock.lock()
        ipcCommandCalls += 1
        lock.unlock()
    }

    func outputSnapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return outputs
    }

    func errorOutputSnapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return errorOutputs
    }

    func ipcClientFactoryCallCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return ipcClientFactoryCalls
    }

    func credentialReaderCallCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return credentialReaderCalls
    }

    func ipcCommandCallCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return ipcCommandCalls
    }
}
