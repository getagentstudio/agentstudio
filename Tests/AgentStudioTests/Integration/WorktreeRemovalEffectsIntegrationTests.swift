import AgentStudioGit
import AgentStudioInfrastructure
import AgentStudioWorktreeOperations
import Foundation
import Testing

@Suite("Worktree removal effects with real Git")
struct WorktreeRemovalEffectsIntegrationTests {
    @Test("archives evidence, removes the linked worktree, and matches the JSON contract")
    func archivesAndFormatsRemovedEntry() async throws {
        var fixture = try await WorktreeRemovalRepository.create(named: "worktree-remove-archive-success")
        defer { fixture.destroy() }
        let worktree = try await fixture.addWorktree(branch: "feature/archive")
        _ = try addEvidence("archive me", to: worktree)
        let archiveRoot = fixture.path.appending(path: "archives", directoryHint: .isDirectory)
        let archiveDestination = archiveRoot.appending(path: worktree.lastPathComponent, directoryHint: .isDirectory)
        let branchCommit = try await removalGit(fixture.path, "rev-parse", "refs/heads/feature/archive")
        let request = worktreeRemovalRequest(
            repository: fixture.path,
            targets: [worktree.path],
            callerDirectory: fixture.path,
            branchPolicy: .keep,
            evidencePolicy: .archive(to: archiveRoot)
        )

        let outcome = await WorktreeOperationRunner(client: fixture.client).run(.remove(request))
        guard case .removal(let report) = outcome,
            case .removed(let entry)? = report.entries.first
        else {
            Issue.record("expected one removed entry, got \(outcome)")
            return
        }
        #expect(report.exitCode == 0)
        #expect(entry.effects.directory == .removed)
        #expect(entry.effects.administration == .removed)
        #expect(entry.effects.branch?.disposition == .retained)
        #expect(entry.effects.branch?.reason == .branchPolicyKeep)
        #expect(entry.effects.branch?.options.isEmpty == true)
        #expect(entry.effects.evidence == .archived(path: archiveDestination.path, files: 1))
        #expect(entry.effects.lockResidue.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: worktree.path))
        #expect(try Data(contentsOf: archiveDestination.appending(path: "evidence.txt")) == Data("archive me".utf8))
        #expect(try await removalGit(fixture.path, "rev-parse", "refs/heads/feature/archive") == branchCommit)

        let response = try WorktreeCommandLineFormatter.format(outcome: outcome, usesJSONOutput: true)
        let expected =
            #"{"entries":[{"details":{"effects":{"activity":{"status":"notChecked"},"administration":"removed","assessment":{"grade":"integrated","proof":{"proof":"sameCommit"}},"branch":{"cleanupWarnings":[],"commit":"\#(branchCommit)","disposition":"retained","name":"feature/archive","options":[],"reason":{"kind":"branchPolicyKeep"}},"directory":"removed","evidence":{"files":1,"path":"\#(archiveDestination.path)","status":"archived"},"lockResidue":[]},"inputs":["\#(worktree.path)"],"target":"\#(worktree.path)"},"status":"removed"}],"fetch":{"reason":"noFetchFlag","status":"skipped"},"outcome":"removal"}"#
        #expect(response.exitCode == 0)
        #expect(response.text == expected)
    }

    @Test("archive-to-main writes verified evidence under the main worktree tmp folder")
    func archivesToMainWorktreeTmp() async throws {
        var fixture = try await WorktreeRemovalRepository.create(named: "worktree-remove-archive-main")
        defer { fixture.destroy() }
        let worktree = try await fixture.addWorktree(branch: "feature/archive-main")
        _ = try addEvidence("main archive", to: worktree)
        let mainTmp = fixture.path.appending(path: "tmp", directoryHint: .isDirectory)
        let destination = mainTmp.appending(path: worktree.lastPathComponent, directoryHint: .isDirectory)

        let report = await WorktreeRemovalRunner(client: fixture.client).run(
            worktreeRemovalRequest(
                repository: fixture.path,
                targets: [worktree.path],
                callerDirectory: fixture.path,
                branchPolicy: .keep,
                evidencePolicy: .archiveToMain
            )
        )
        guard case .removed(let entry)? = report.entries.first else {
            Issue.record("expected archive-to-main removal, got \(report)")
            return
        }
        #expect(entry.effects.evidence == .archived(path: destination.path, files: 1))
        #expect(try Data(contentsOf: destination.appending(path: "evidence.txt")) == Data("main archive".utf8))
    }

    @Test("a pre-existing index lock refuses before archive-to-main")
    func refusesPreExistingIndexLockBeforeArchiveToMain() async throws {
        var fixture = try await WorktreeRemovalRepository.create(named: "worktree-remove-archive-index-lock")
        defer { fixture.destroy() }
        let worktree = try await fixture.addWorktree(branch: "feature/archive-index-lock")
        let evidence = try addEvidence("keep this evidence", to: worktree)
        let snapshot = try #require(
            await fixture.client.worktrees(for: fixture.path).first {
                $0.canonicalPath.standardizedFileURL.path == worktree.standardizedFileURL.path
            }
        )
        let lockPath = URL(fileURLWithPath: snapshot.indexPath.path + ".lock")
        let foreignBytes = Data("foreign index writer\n".utf8)
        try foreignBytes.write(to: lockPath)
        let archiveDestination = WorktreeLifecyclePolicy.archiveToMainDestination(
            mainWorktree: fixture.path,
            worktreeFolder: worktree.lastPathComponent
        )

        let report = await WorktreeRemovalRunner(client: fixture.client).run(
            worktreeRemovalRequest(
                repository: fixture.path,
                targets: [worktree.path],
                callerDirectory: fixture.path,
                branchPolicy: .keep,
                evidencePolicy: .archiveToMain
            )
        )

        guard case .refused(let entry)? = report.entries.first,
            case .gitLockHeld(let observation) = entry.refusal.details
        else {
            Issue.record("expected a pre-archive index-lock refusal, got \(report)")
            return
        }
        #expect(observation.path == lockPath.standardizedFileURL.path)
        guard case .index(let observedWorktreePath) = observation.resource else {
            Issue.record("expected an index lock resource, got \(observation.resource)")
            return
        }
        #expect(observedWorktreePath.standardizedFileURL.path == worktree.standardizedFileURL.path)
        #expect(FileManager.default.fileExists(atPath: worktree.path))
        #expect(FileManager.default.fileExists(atPath: evidence.path))
        #expect(!FileManager.default.fileExists(atPath: archiveDestination.path))
        #expect(try Data(contentsOf: lockPath) == foreignBytes)
    }

    @Test("preview and execution refuse a pre-existing branch ref lock before archive")
    func previewAndExecutionMatchForPreExistingBranchRefLock() async throws {
        var fixture = try await WorktreeRemovalRepository.create(named: "worktree-remove-archive-ref-lock")
        defer { fixture.destroy() }
        let branchName = "feature/archive-ref-lock"
        let worktree = try await fixture.addWorktree(branch: branchName)
        let evidence = try addEvidence("keep this evidence", to: worktree)
        let lockPath = fixture.path.appending(path: ".git/refs/heads/feature/archive-ref-lock.lock")
        let foreignBytes = Data("foreign branch writer\n".utf8)
        try FileManager.default.createDirectory(
            at: lockPath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try foreignBytes.write(to: lockPath)
        let archiveDestination = WorktreeLifecyclePolicy.archiveToMainDestination(
            mainWorktree: fixture.path,
            worktreeFolder: worktree.lastPathComponent
        )
        let runner = WorktreeRemovalRunner(client: fixture.client)

        let preview = await runner.run(
            worktreeRemovalRequest(
                repository: fixture.path,
                targets: [worktree.path],
                callerDirectory: fixture.path,
                branchPolicy: .deleteAtObservedCommit,
                evidencePolicy: .archiveToMain,
                dryRun: true
            )
        )
        guard case .planned(let planned)? = preview.entries.first,
            planned.plan.stopsAt?.reason == .gitLockHeld,
            case .gitLockHeld(let previewObservation) = planned.plan.stopsAt?.details
        else {
            Issue.record("expected a planned branch-lock stop, got \(preview)")
            return
        }
        #expect(previewObservation.path == lockPath.standardizedFileURL.path)
        #expect(previewObservation.resource == .reference(name: "refs/heads/\(branchName)"))
        #expect(!previewObservation.looksStale)

        let report = await runner.run(
            worktreeRemovalRequest(
                repository: fixture.path,
                targets: [worktree.path],
                callerDirectory: fixture.path,
                branchPolicy: .deleteAtObservedCommit,
                evidencePolicy: .archiveToMain
            )
        )
        guard case .refused(let refused)? = report.entries.first,
            case .gitLockHeld(let observation) = refused.refusal.details
        else {
            Issue.record("expected execution to refuse at the same branch lock, got \(report)")
            return
        }

        #expect(observation.path == lockPath.standardizedFileURL.path)
        #expect(observation.resource == .reference(name: "refs/heads/\(branchName)"))
        #expect(FileManager.default.fileExists(atPath: worktree.path))
        #expect(FileManager.default.fileExists(atPath: evidence.path))
        #expect(!FileManager.default.fileExists(atPath: archiveDestination.path))
        #expect(try Data(contentsOf: lockPath) == foreignBytes)
        #expect(
            try await removalGit(fixture.path, "show-ref", "--verify", "refs/heads/\(branchName)").isEmpty == false)
    }

    @Test("force discards working changes; discard-tmp removes ignored evidence with the worktree")
    func appliesSeparateWorkingChangeAndEvidencePolicies() async throws {
        var fixture = try await WorktreeRemovalRepository.create(named: "worktree-remove-discard-policies")
        defer { fixture.destroy() }
        let dirtyPath = try await fixture.addWorktree(branch: "feature/force-discard")
        let evidencePath = try await fixture.addWorktree(branch: "feature/discard-tmp")
        try "discarded change\n".write(
            to: dirtyPath.appending(path: "tracked.txt"),
            atomically: true,
            encoding: .utf8
        )
        let evidenceFile = try addEvidence("discard evidence", to: evidencePath)

        let dirtyReport = await WorktreeRemovalRunner(client: fixture.client).run(
            worktreeRemovalRequest(
                repository: fixture.path,
                targets: [dirtyPath.path],
                callerDirectory: fixture.path,
                discardWorkingChanges: true,
                branchPolicy: .keep
            )
        )
        guard let dirtyEntry = dirtyReport.entries.first,
            case .removed = dirtyEntry
        else {
            Issue.record("expected -f to permit discarding working changes, got \(dirtyReport)")
            return
        }

        let evidenceReport = await WorktreeRemovalRunner(client: fixture.client).run(
            worktreeRemovalRequest(
                repository: fixture.path,
                targets: [evidencePath.path],
                callerDirectory: fixture.path,
                branchPolicy: .keep,
                evidencePolicy: .discard
            )
        )
        guard case .removed(let evidenceEntry)? = evidenceReport.entries.first else {
            Issue.record("expected --discard-tmp removal, got \(evidenceReport)")
            return
        }
        #expect(evidenceEntry.effects.evidence == .discarded)
        #expect(!FileManager.default.fileExists(atPath: evidencePath.path))
        #expect(!FileManager.default.fileExists(atPath: evidenceFile.path))
    }

    @Test("archive copy failure retains the worktree and reports the partial destination")
    func reportsPartialArchiveCopy() async throws {
        var fixture = try await WorktreeRemovalRepository.create(named: "worktree-remove-archive-failure")
        defer { fixture.destroy() }
        let worktree = try await fixture.addWorktree(branch: "feature/archive-failure")
        _ = try addEvidence("preserve source", to: worktree)
        let archiveRoot = fixture.path.deletingLastPathComponent()
            .appending(path: "read-only-archive-\(UUIDv7.generate().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: archiveRoot, withIntermediateDirectories: true)
        let originalPermissions = try FileManager.default.attributesOfItem(atPath: archiveRoot.path)[.posixPermissions]
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: originalPermissions ?? 0o755], ofItemAtPath: archiveRoot.path)
            try? FileManager.default.removeItem(at: archiveRoot)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: archiveRoot.path)

        let outcome = await WorktreeOperationRunner(client: fixture.client).run(
            .remove(
                worktreeRemovalRequest(
                    repository: fixture.path,
                    targets: [worktree.path],
                    callerDirectory: fixture.path,
                    branchPolicy: .keep,
                    evidencePolicy: .archive(to: archiveRoot)
                ))
        )
        guard case .removal(let report) = outcome,
            case .failed(let entry)? = report.entries.first,
            case .archiveFailed = entry.failure.kind,
            case .partialCopy(let destination) = entry.failure.effects.evidence
        else {
            Issue.record("expected archiveFailed with partialCopy, got \(outcome)")
            return
        }
        #expect(report.exitCode == 2)
        #expect(destination == archiveRoot.appending(path: worktree.lastPathComponent).path)
        #expect(entry.failure.effects.directory == .retained)
        #expect(entry.failure.effects.administration == .retained)
        #expect(FileManager.default.fileExists(atPath: worktree.path))
        #expect(try Data(contentsOf: worktree.appending(path: "tmp/evidence.txt")) == Data("preserve source".utf8))
    }

    @Test("a lock after a completed archive is a failed entry carrying the full stop")
    func carriesLockStopAfterArchive() async throws {
        var fixture = try await WorktreeRemovalRepository.create(named: "worktree-remove-archive-lock")
        defer { fixture.destroy() }
        let worktree = try await fixture.addWorktree(branch: "feature/archive-lock")
        _ = try addEvidence("archive before lock", to: worktree)
        let snapshot = try #require(
            await fixture.client.worktrees(for: fixture.path).first {
                $0.canonicalPath.standardizedFileURL.path == worktree.standardizedFileURL.path
            }
        )
        let lockPath = URL(fileURLWithPath: snapshot.indexPath.path + ".lock")
        let foreignBytes = Data("active index writer\n".utf8)
        let mainSnapshot = try #require(
            await fixture.client.worktrees(for: fixture.path).first(where: \.isMainWorktree)
        )
        let identity = try await fixture.client.repositoryIdentity(for: fixture.path)
        let client = WorktreeOperationClientStub(
            startPath: fixture.path,
            snapshot: mainSnapshot,
            identity: identity,
            baseClient: fixture.client,
            removeWorktreeHandler: { _ in
                do {
                    try foreignBytes.write(to: lockPath)
                } catch {
                    return .failure(.unsupported(message: "could not plant the post-archive index lock"))
                }
                return .failure(
                    .lockHeld(
                        GitLockFact(
                            path: lockPath,
                            resource: .index(worktreePath: worktree.standardizedFileURL)
                        )))
            }
        )
        let archiveRoot = fixture.path.appending(path: "archives", directoryHint: .isDirectory)
        let archiveDestination = archiveRoot.appending(path: worktree.lastPathComponent, directoryHint: .isDirectory)

        let outcome = await WorktreeOperationRunner(client: client).run(
            .remove(
                worktreeRemovalRequest(
                    repository: fixture.path,
                    targets: [worktree.path],
                    callerDirectory: fixture.path,
                    discardWorkingChanges: true,
                    branchPolicy: .keep,
                    evidencePolicy: .archive(to: archiveRoot)
                ))
        )
        guard case .removal(let report) = outcome,
            case .failed(let entry)? = report.entries.first,
            let stop = entry.failure.stop,
            case .gitLockHeld(let observation) = stop.details
        else {
            Issue.record("expected a failed entry with gitLockHeld stop details, got \(outcome)")
            return
        }
        #expect(report.exitCode == 2)
        #expect(entry.failure.effects.directory == .retained)
        #expect(entry.failure.effects.administration == .retained)
        #expect(entry.failure.effects.evidence == .archived(path: archiveDestination.path, files: 1))
        #expect(observation.path == lockPath.standardizedFileURL.path)
        #expect(FileManager.default.fileExists(atPath: lockPath.path))
        guard case .index(let observedWorktreePath) = observation.resource else {
            Issue.record("expected index lock resource, got \(observation.resource)")
            return
        }
        #expect(observedWorktreePath.standardizedFileURL.path == worktree.standardizedFileURL.path)
        #expect(try Data(contentsOf: lockPath) == foreignBytes)
        #expect(
            try Data(contentsOf: archiveDestination.appending(path: "evidence.txt")) == Data("archive before lock".utf8)
        )

        let response = try WorktreeCommandLineFormatter.format(outcome: outcome, usesJSONOutput: true)
        #expect(response.text.contains(#""kind":"removalIncomplete""#))
        #expect(response.text.contains(#""reason":"gitLockHeld""#))
        #expect(response.text.contains(lockPath.standardizedFileURL.path))
        #expect(response.text.contains(#""evidence":{"files":1,"path":""#))

        let humanResponse = try WorktreeCommandLineFormatter.format(removalReport: report, usesJSONOutput: false)
        #expect(humanResponse.exitCode == 2)
        #expect(humanResponse.text.contains(lockPath.standardizedFileURL.path))
        #expect(humanResponse.text.contains("gitLockHeld"))
        #expect(humanResponse.text.contains("retry"))
        #expect(humanResponse.text.contains("directory=retained"))
        #expect(humanResponse.text.contains("evidence=archived"))
    }

    @Test("mixed targets stay in input order, merge duplicates, aggregate exit, and retry safely")
    func processesEveryTargetAndRepeat() async throws {
        var fixture = try await WorktreeRemovalRepository.create(named: "worktree-remove-many")
        defer { fixture.destroy() }
        let dirtyPath = try await fixture.addWorktree(branch: "feature/dirty-many")
        let cleanPath = try await fixture.addWorktree(branch: "feature/clean-many")
        try "dirty\n".write(to: dirtyPath.appending(path: "tracked.txt"), atomically: true, encoding: .utf8)

        let outcome = await WorktreeOperationRunner(client: fixture.client).run(
            .remove(
                worktreeRemovalRequest(
                    repository: fixture.path,
                    targets: ["feature/already-gone", dirtyPath.path, cleanPath.path, dirtyPath.path],
                    callerDirectory: fixture.path,
                    branchPolicy: .keep
                ))
        )
        guard case .removal(let report) = outcome else {
            Issue.record("expected removal report, got \(outcome)")
            return
        }
        #expect(report.entries.count == 3)
        guard report.entries.count == 3,
            case .alreadyRemoved(let absent) = report.entries[0],
            case .refused(let refused) = report.entries[1],
            case .removed(let removed) = report.entries[2]
        else {
            Issue.record("expected alreadyRemoved, refused, removed in input order; got \(report.entries)")
            return
        }
        #expect(absent.target == "feature/already-gone")
        #expect(refused.refusal.reason == .dirty)
        #expect(refused.inputs == [dirtyPath.path, dirtyPath.path])
        #expect(removed.target == cleanPath.standardizedFileURL.path)
        #expect(report.exitCode == 1)
        #expect(!FileManager.default.fileExists(atPath: cleanPath.path))
        #expect(FileManager.default.fileExists(atPath: dirtyPath.path))

        let retry = await WorktreeOperationRunner(client: fixture.client).run(
            .remove(
                worktreeRemovalRequest(
                    repository: fixture.path,
                    targets: [cleanPath.path],
                    callerDirectory: fixture.path,
                    branchPolicy: .keep
                ))
        )
        guard case .removal(let retryReport) = retry,
            case .alreadyRemoved(let retryEntry)? = retryReport.entries.first
        else {
            Issue.record("expected an alreadyRemoved retry, got \(retry)")
            return
        }
        #expect(retryEntry.target == cleanPath.path)
        #expect(retryReport.exitCode == 0)
    }

    @Test("a mixed call continues after refusal and failure and gives failure exit precedence")
    func aggregateFailureTakesPrecedenceAndLaterTargetsRun() async throws {
        var fixture = try await WorktreeRemovalRepository.create(named: "worktree-remove-mixed-failure")
        defer { fixture.destroy() }
        let dirtyPath = try await fixture.addWorktree(branch: "feature/mixed-dirty")
        let removedPath = try await fixture.addWorktree(branch: "feature/mixed-removed")
        let failedPath = try await fixture.addWorktree(branch: "feature/mixed-failed")
        try "dirty\n".write(to: dirtyPath.appending(path: "tracked.txt"), atomically: true, encoding: .utf8)
        let mainSnapshot = try #require(
            await fixture.client.worktrees(for: fixture.path).first(where: \.isMainWorktree))
        let identity = try await fixture.client.repositoryIdentity(for: fixture.path)
        let realClient = fixture.client
        let permissionPath = fixture.path.appending(path: ".git/refs/heads/feature/mixed-failed")
        let branchFailure = GitLockedOperationFailure<GitDeleteLocalBranchErrorReason>(
            reason: .gitFailure(.permissionDenied(path: permissionPath)),
            lockResidue: []
        )
        let client = WorktreeOperationClientStub(
            startPath: fixture.path,
            snapshot: mainSnapshot,
            identity: identity,
            baseClient: realClient,
            deleteLocalBranchHandler: { request in
                if request.branchName == "feature/mixed-failed" {
                    return .failure(branchFailure)
                }
                return await executeBranchDeletionThroughSDK(realClient, request: request)
            }
        )

        let report = await WorktreeRemovalRunner(client: client).run(
            worktreeRemovalRequest(
                repository: fixture.path,
                targets: [dirtyPath.path, removedPath.path, failedPath.path],
                callerDirectory: fixture.path,
                branchPolicy: .deleteAtObservedCommit
            )
        )
        #expect(report.entries.count == 3)
        guard case .refused(let refused) = report.entries[0],
            case .removed = report.entries[1],
            case .failed(let failed) = report.entries[2]
        else {
            Issue.record("expected refusal, removal, then failure in input order; got \(report.entries)")
            return
        }
        #expect(refused.refusal.reason == .dirty)
        #expect(failed.failure.kind == .branchDeletionFailed(.permissionDenied(path: permissionPath)))
        #expect(report.exitCode == 2)
        #expect(FileManager.default.fileExists(atPath: dirtyPath.path))
        #expect(!FileManager.default.fileExists(atPath: removedPath.path))
        #expect(!FileManager.default.fileExists(atPath: failedPath.path))
        #expect(
            try await removalGit(fixture.path, "show-ref", "--verify", "refs/heads/feature/mixed-failed").isEmpty
                == false)
    }

    @Test("partial SDK removal effects fail truthfully and never delete the branch")
    func partialRemovalEffectsPreventBranchDeletion() async throws {
        var fixture = try await WorktreeRemovalRepository.create(named: "worktree-remove-partial-effects")
        defer { fixture.destroy() }
        let worktree = try await fixture.addWorktree(branch: "feature/partial-effects")
        let mainSnapshot = try #require(
            await fixture.client.worktrees(for: fixture.path).first(where: \.isMainWorktree))
        let identity = try await fixture.client.repositoryIdentity(for: fixture.path)
        let realClient = fixture.client
        let client = WorktreeOperationClientStub(
            startPath: fixture.path,
            snapshot: mainSnapshot,
            identity: identity,
            baseClient: realClient,
            removeWorktreeHandler: { request in
                switch await executeWorktreeRemovalThroughSDK(realClient, request: request) {
                case .success(let result):
                    return .success(
                        GitWorktreeRemovalResult(
                            removedWorktreeID: result.removedWorktreeID,
                            effects: GitWorktreeRemovalEffects(
                                administration: .partial,
                                workingDirectory: .removed,
                                failure: .removalIncomplete,
                                lockResidue: []
                            )
                        ))
                case .failure(let error):
                    return .failure(error)
                }
            }
        )

        let report = await WorktreeRemovalRunner(client: client).run(
            worktreeRemovalRequest(
                repository: fixture.path,
                targets: [worktree.path],
                callerDirectory: fixture.path,
                branchPolicy: .deleteAtObservedCommit
            )
        )
        guard case .failed(let entry)? = report.entries.first else {
            Issue.record("expected failed partial-removal entry, got \(report)")
            return
        }
        #expect(entry.failure.kind == .removalIncomplete)
        #expect(entry.failure.effects.directory == .removed)
        #expect(entry.failure.effects.administration == .partial)
        #expect(entry.failure.effects.branch?.disposition == .retained)
        #expect(
            try await removalGit(fixture.path, "show-ref", "--verify", "refs/heads/feature/partial-effects").isEmpty
                == false)
    }

    @Test("SDK-owned lock residue is included on the removal result")
    func reportsOwnedLockResidueFromRemovalResult() async throws {
        var fixture = try await WorktreeRemovalRepository.create(named: "worktree-remove-owned-residue")
        defer { fixture.destroy() }
        let worktree = try await fixture.addWorktree(branch: "feature/owned-residue")
        let mainSnapshot = try #require(
            await fixture.client.worktrees(for: fixture.path).first(where: \.isMainWorktree))
        let identity = try await fixture.client.repositoryIdentity(for: fixture.path)
        let realClient = fixture.client
        let residue = fixture.path.appending(path: ".git/index.lock")
        let client = WorktreeOperationClientStub(
            startPath: fixture.path,
            snapshot: mainSnapshot,
            identity: identity,
            baseClient: realClient,
            removeWorktreeHandler: { request in
                switch await executeWorktreeRemovalThroughSDK(realClient, request: request) {
                case .success(let result):
                    return .success(
                        GitWorktreeRemovalResult(
                            removedWorktreeID: result.removedWorktreeID,
                            effects: GitWorktreeRemovalEffects(
                                administration: result.effects.administration,
                                workingDirectory: result.effects.workingDirectory,
                                failure: result.effects.failure,
                                lockResidue: [residue]
                            )
                        ))
                case .failure(let error):
                    return .failure(error)
                }
            }
        )

        let report = await WorktreeRemovalRunner(client: client).run(
            worktreeRemovalRequest(
                repository: fixture.path,
                targets: [worktree.path],
                callerDirectory: fixture.path,
                branchPolicy: .keep
            )
        )
        guard case .failed(let entry)? = report.entries.first else {
            Issue.record("expected lockCleanupIncomplete for reported owned residue, got \(report)")
            return
        }
        #expect(entry.failure.kind == .lockCleanupIncomplete)
        #expect(entry.failure.effects.lockResidue == [residue.path])
        #expect(!FileManager.default.fileExists(atPath: worktree.path))
    }
}
