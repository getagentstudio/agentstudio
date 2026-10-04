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

    @Test("argument parsing maps new fork and list options to operation requests")
    func parsesWorktreeCommandsAndPaths() throws {
        let currentDirectory = URL(fileURLWithPath: "/tmp/worktree-cli", isDirectory: true)

        let repository = currentDirectory.appending(path: "repositories/main").standardizedFileURL
        let source = currentDirectory.appending(path: "linked/nested").standardizedFileURL
        let cases: [([String], WorktreeCreateRequest, Bool)] = [
            (
                ["new", "feature/new", "--repo", "repositories/main", "--json"],
                WorktreeCreateRequest(
                    start: repository, branch: "feature/new", source: .mainWorktree, materialization: .copyOnWrite),
                true
            ),
            (
                [
                    "new", "feature/from-source", "--tracked-only", "--from-branch", "feature/source", "--repo",
                    "repositories/main",
                ],
                WorktreeCreateRequest(
                    start: repository, branch: "feature/from-source", source: .mainWorktree,
                    materialization: .trackedOnly(startBranch: "feature/source")), false
            ),
            (
                ["new", "feature/fork", "--from", "linked/nested"],
                WorktreeCreateRequest(
                    start: currentDirectory, branch: "feature/fork", source: .worktree(source),
                    materialization: .copyOnWrite), false
            ),
            (
                ["new", "feature/changes", "--changes-only", "--from", "linked/nested", "--json"],
                WorktreeCreateRequest(
                    start: currentDirectory, branch: "feature/changes", source: .worktree(source),
                    materialization: .changesOnly), true
            ),
        ]
        for (arguments, request, json) in cases {
            #expect(
                try WorktreeCommandLineArgumentParser.parse(arguments, currentDirectory: currentDirectory)
                    == WorktreeCommandLineInvocation(request: .create(request), usesJSONOutput: json))
        }

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
                        fetchPolicy: .defaultBranch
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
                        fetchPolicy: .defaultBranch
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
                            fetchPolicy: .defaultBranch
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
        let malformedForms: [[String]] = [
            [],
            ["unknown"],
            ["list", "--unknown"],
            ["list", "--no-fetch", "--no-fetch"],
            ["new", "feature/new", "--no-fetch"],
            ["fork", "feature/fork", "--repo", "/tmp/repository"],
            ["list", "--repo"],
            ["new", "feature/new", "--repo", "--json"],
            ["new", "feature/new", "--from-branch", "--json"],
            ["new", "feature/new", "--from-branch", "feature/start", "--from-branch", "feature/other"],
            ["new", "feature/new", "--changes-only", "--changes-only"],
            ["new", "feature/new", "--tracked-only", "--tracked-only"],
            ["new", "feature/new", "--json", "--json"],
            ["new", "feature/fork", "--from", "--json"],
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
                    outcome: .refused(.forkUnavailable(.sourceFilesystemNotAPFS, source: .mainWorktree)),
                    humanText:
                        "refused: forkUnavailable sourceFilesystemNotAPFS --tracked-only; options: [--tracked-only: Create a tracked-files checkout.]",
                    jsonText:
                        "{\"alternatives\":[\"trackedOnly\"],\"detail\":\"sourceFilesystemNotAPFS\",\"options\":[{\"effect\":\"Create a tracked-files checkout.\",\"flag\":\"--tracked-only\"}],\"outcome\":\"refused\",\"reason\":\"forkUnavailable\"}",
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
                    WorktreeCreatedSummary(
                        operation: .new,
                        branch: "feature/cli",
                        path: createdPath,
                        repository: repository,
                        materialization: .trackedOnly(
                            GitLargeFileFill(materializedCount: 0, missing: [], residuePaths: [], scan: .complete))
                    )
                ),
                humanText: "created feature/cli at /tmp/worktree-output/repository.feature-cli",
                jsonText:
                    "{\"branch\":\"feature/cli\",\"materialization\":{\"kind\":\"trackedOnly\",\"largeFiles\":{\"materialized\":0,\"missing\":[],\"missingCount\":0,\"scan\":\"complete\"}},\"operation\":\"new\",\"outcome\":\"created\",\"path\":\"/tmp/worktree-output/repository.feature-cli\",\"repository\":\"/tmp/worktree-output/repository\"}",
                exitCode: 0
            ),
            FormatterGolden(
                outcome: .created(
                    WorktreeCreatedSummary(
                        operation: .new,
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
                                normalizedEntries: []
                            ))
                    )
                ),
                humanText: "created feature/cow at /tmp/worktree-output/repository.feature-cli",
                jsonText:
                    "{\"branch\":\"feature/cow\",\"materialization\":{\"clonedRegularFileCount\":0,\"createdDirectoryCount\":0,\"kind\":\"copyOnWrite\",\"logicalRegularFileBytes\":0,\"normalizedEntries\":[],\"preservedGitRepositoryCount\":0,\"preservedHardLinkCount\":0,\"recreatedFIFOCount\":0,\"recreatedSymbolicLinkCount\":0,\"skippedEntries\":[]},\"operation\":\"new\",\"outcome\":\"created\",\"path\":\"/tmp/worktree-output/repository.feature-cli\",\"repository\":\"/tmp/worktree-output/repository\"}",
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
                    "refused: unsupportedWorkingState .gitattributes attributesChanged; options: [commit the changed .gitattributes first: Commit the changed attributes, then retry --changes-only.; stash the changed .gitattributes first: Stash the changed attributes, then retry --changes-only.; agentstudio worktree new <branch> --from <source>: Use the APFS copy-on-write fork without --changes-only.]",
                jsonText:
                    "{\"detail\":\"attributesChanged\",\"options\":[{\"command\":\"commit the changed .gitattributes first\",\"effect\":\"Commit the changed attributes, then retry --changes-only.\"},{\"command\":\"stash the changed .gitattributes first\",\"effect\":\"Stash the changed attributes, then retry --changes-only.\"},{\"command\":\"agentstudio worktree new <branch> --from <source>\",\"effect\":\"Use the APFS copy-on-write fork without --changes-only.\"}],\"outcome\":\"refused\",\"path\":\".gitattributes\",\"reason\":\"unsupportedWorkingState\"}",
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
            arguments: ["new", branch, "--tracked-only", "--repo", repository.path],
            currentDirectory: outsideRepository,
            output: { createProbe.appendOutput($0) },
            errorOutput: { createProbe.appendErrorOutput($0) }
        )
        #expect(createExitCode == 0)
        #expect(createProbe.outputSnapshot() == ["created \(branch) at \(destination.standardizedFileURL.path)"])

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
