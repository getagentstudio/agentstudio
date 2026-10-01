import AgentStudioGit
import Foundation

extension WorktreeRemovalRunner {
    func branchAssessment(
        _ branchName: String,
        repositoryPath: URL,
        target: WorktreeIntegrationTarget?
    ) async -> BranchAssessment {
        var grade: GitBranchIntegrationGrade?
        var commit: String?
        if let target, branchName != target.branchName {
            do {
                let report = try await client.assessBranchIntegration(
                    GitBranchIntegrationRequest(
                        repositoryPath: repositoryPath,
                        branchNames: [branchName],
                        targetCommit: target.commit,
                        squashSearchCommitLimit: WorktreeLifecyclePolicy.squashSearchCommitLimit
                    ))
                let row = report.assessments.first { $0.branchName == branchName }
                grade = row?.grade ?? .unknown(.branchNotFound)
                commit = row?.branchCommit
            } catch {
                grade = .unknown(.readFailed)
            }
        }

        if commit == nil {
            do {
                let resolved = try await client.resolveRevision(
                    GitRevisionResolutionRequest(
                        repositoryPath: repositoryPath,
                        target: .named("refs/heads/\(branchName)")
                    ))
                commit = resolved.oid
            } catch {
                if grade == nil { grade = .unknown(.readFailed) }
            }
        }

        return BranchAssessment(
            branchName: branchName,
            grade: grade,
            commit: commit,
            document: WorktreeRemovalOutcomeProjector.assessmentDocument(
                branchName: branchName,
                target: target,
                grade: grade
            )
        )
    }

    func preflight(
        _ snapshot: GitWorktreeSnapshot,
        request: WorktreeRemovalRequest,
        mainWorktreePath: URL
    ) async -> WorktreePreflight {
        if let stop = initialPreflightStop(snapshot, callerDirectory: request.callerDirectory) {
            return stoppedPreflight(stop)
        }

        let statusResult = await statusPreflight(snapshot, discardWorkingChanges: request.discardWorkingChanges)
        if let stop = statusResult.stop {
            return stoppedPreflight(stop, status: statusResult.status)
        }

        let evidence = await WorktreeTmpEvidenceScanner().scan(worktreePath: snapshot.canonicalPath)
        if let stop = evidenceStop(evidence, policy: request.evidencePolicy) {
            return stoppedPreflight(stop, status: statusResult.status, evidence: evidence)
        }

        let activity = await activityProbe.activity(forWorktreeAt: snapshot.canonicalPath)
        if let stop = activityStop(activity, request: request) {
            return stoppedPreflight(stop, status: statusResult.status, evidence: evidence, activity: activity)
        }

        let archiveDestination = Self.archiveDestination(
            policy: request.evidencePolicy,
            evidence: evidence,
            worktreePath: snapshot.canonicalPath,
            mainWorktreePath: mainWorktreePath
        )
        return WorktreePreflight(
            stop: nil,
            status: statusResult.status,
            evidence: evidence,
            activity: activity,
            archiveDestination: archiveDestination,
            archiveDestinationStop: Self.archiveDestinationStop(
                archiveDestination,
                worktreePath: snapshot.canonicalPath
            )
        )
    }

    private func initialPreflightStop(
        _ snapshot: GitWorktreeSnapshot,
        callerDirectory: URL?
    ) -> WorktreeStopDetails? {
        if snapshot.isMainWorktree { return .mainWorktree }
        if let callerDirectory,
            Self.contains(
                rootPath: snapshot.canonicalPath.standardizedFileURL.resolvingSymlinksInPath().path,
                candidatePath: callerDirectory.standardizedFileURL.resolvingSymlinksInPath().path
            )
        {
            return .targetIsCurrent(path: snapshot.canonicalPath.standardizedFileURL.path)
        }
        if snapshot.isLocked { return .worktreeLocked(reason: snapshot.lockReason) }
        return nil
    }

    private func statusPreflight(
        _ snapshot: GitWorktreeSnapshot,
        discardWorkingChanges: Bool
    ) async -> (status: GitStatusFactsRead?, stop: WorktreeStopDetails?) {
        let status: GitStatusFactsRead?
        do {
            status = try await client.statusFacts(
                for: snapshot.canonicalPath,
                options: GitStatusOptions(includeIgnored: false, includeUntracked: true),
                observationPlan: nil
            )
        } catch {
            status = nil
        }
        guard !discardWorkingChanges else { return (status, nil) }
        guard let status else { return (nil, .changesUnknown) }
        guard Self.isDirty(status) else { return (status, nil) }
        return (status, .dirty(Self.dirtyDetails(status)))
    }

    private func evidenceStop(
        _ evidence: WorktreeTmpEvidenceScanResult,
        policy: WorktreeEvidencePolicy
    ) -> WorktreeStopDetails? {
        if case .unknown(let path) = evidence, policy != .discard {
            return .evidenceUnknown(path: path.standardizedFileURL.path)
        }
        if case .nonEmpty(let fileCount, let byteCount, let firstPaths) = evidence, policy == .requireEmpty {
            return .evidenceInTmp(fileCount: fileCount, byteCount: byteCount, firstPaths: firstPaths)
        }
        return nil
    }

    private func activityStop(
        _ activity: WorktreeActivityDocument,
        request: WorktreeRemovalRequest
    ) -> WorktreeStopDetails? {
        guard case .openPanes(let panes) = activity,
            !request.closePanes,
            !request.removeWithOpenPanes
        else {
            return nil
        }
        return .openInPane(panes: panes.map { WorktreeStopPaneDetails(paneId: $0.id, title: $0.displayTitle) })
    }

    private func stoppedPreflight(
        _ stop: WorktreeStopDetails,
        status: GitStatusFactsRead? = nil,
        evidence: WorktreeTmpEvidenceScanResult = .empty,
        activity: WorktreeActivityDocument = .notChecked
    ) -> WorktreePreflight {
        WorktreePreflight(
            stop: stop,
            status: status,
            evidence: evidence,
            activity: activity,
            archiveDestination: nil,
            archiveDestinationStop: nil
        )
    }

    func dryRunLockCheck(
        snapshot: GitWorktreeSnapshot?,
        branchName: String?,
        assessment: BranchAssessment?,
        request: WorktreeRemovalRequest,
        repository: RepositoryContext,
        fetchTarget: WorktreeIntegrationTarget?
    ) -> DryRunLockCheck {
        var facts: [GitLockFact] = []
        if let snapshot {
            facts.append(
                GitLockFact(
                    path: URL(fileURLWithPath: snapshot.indexPath.path + ".lock"),
                    resource: .index(worktreePath: snapshot.canonicalPath)
                ))
        }
        if let branchName,
            shouldDeleteBranch(branchName, assessment: assessment, request: request, target: fetchTarget)
        {
            let referenceName = "refs/heads/\(branchName)"
            facts.append(
                GitLockFact(
                    path: repository.commonDirectory.appending(path: "\(referenceName).lock"),
                    resource: .reference(name: referenceName)
                ))
            facts.append(
                GitLockFact(
                    path: repository.commonDirectory.appending(path: "packed-refs.lock"),
                    resource: .packedRefs
                ))
        }

        var wouldRemovePaths: [String] = []
        for fact in facts {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: fact.path.path),
                attributes[.type] as? FileAttributeType == .typeRegular
            else {
                continue
            }
            let lockAssessment = staleLockAssessment.inspect(fact)
            if request.removeStaleLock, lockAssessment.observation.looksStale {
                wouldRemovePaths.append(fact.path.standardizedFileURL.path)
            } else {
                return DryRunLockCheck(
                    stop: .gitLockHeld(lockAssessment.observation),
                    wouldRemovePaths: wouldRemovePaths
                )
            }
        }
        return DryRunLockCheck(stop: nil, wouldRemovePaths: wouldRemovePaths)
    }

    func plannedEntry(_ input: WorktreePlanEntryRequest) -> WorktreeRemovalEntry {
        let target = input.target
        let inputs = input.inputs
        let isWorktree = input.isWorktree
        let request = input.request
        let fetchStatus = input.fetchStatus
        let preflight = input.preflight
        let assessment = input.assessment
        let fetchTarget = input.fetchTarget
        let stop = input.stop
        let wouldRemoveLockPaths = input.wouldRemoveLockPaths
        let lockDetail =
            wouldRemoveLockPaths.isEmpty
            ? nil : "would remove stale lock \(wouldRemoveLockPaths.joined(separator: ", "))"
        var steps = [
            WorktreeRemovalPlanStep(kind: .fetch, disposition: .wouldRun, detail: Self.fetchDetail(fetchStatus)),
            WorktreeRemovalPlanStep(kind: .checks, disposition: .wouldRun, detail: lockDetail),
        ]
        if isWorktree {
            let archiveDisposition: WorktreeRemovalPlanStepDisposition =
                preflight?.archiveDestination == nil
                ? .skipped
                : .wouldRun
            steps.append(
                WorktreeRemovalPlanStep(
                    kind: .archive,
                    disposition: archiveDisposition,
                    detail: preflight?.archiveDestination?.standardizedFileURL.path
                ))
            steps.append(
                WorktreeRemovalPlanStep(
                    kind: .directoryRemoval,
                    disposition: stop == nil ? .wouldRemove : .skipped
                ))
        } else {
            steps.append(WorktreeRemovalPlanStep(kind: .archive, disposition: .skipped, detail: "notApplicable"))
            steps.append(
                WorktreeRemovalPlanStep(kind: .directoryRemoval, disposition: .skipped, detail: "notApplicable"))
        }

        let branchDisposition: WorktreeRemovalPlanStepDisposition
        let branchDetail: String?
        let branchName = assessment?.branchName ?? (isWorktree ? nil : target)
        if let reason = branchRetentionReason(
            branchName,
            assessment: assessment,
            request: request,
            target: fetchTarget
        ) {
            branchDisposition = .skipped
            branchDetail = Self.branchReasonName(reason)
        } else if shouldDeleteBranch(
            branchName,
            assessment: assessment,
            request: request,
            target: fetchTarget
        ) {
            branchDisposition = .wouldDelete
            branchDetail = nil
        } else {
            branchDisposition = .skipped
            branchDetail = assessment == nil ? "noBranch" : "branchTipUnavailable"
        }
        steps.append(
            WorktreeRemovalPlanStep(kind: .branchDisposition, disposition: branchDisposition, detail: branchDetail))

        let refusal = stop.map(WorktreeRefusalDocument.init(details:))
        return .planned(
            WorktreePlannedEntryDocument(
                target: target,
                inputs: inputs,
                plan: WorktreeRemovalPlanDocument(steps: steps, stopsAt: refusal)
            ))
    }

    func branchRetentionReason(
        _ branchName: String?,
        assessment: BranchAssessment?,
        request: WorktreeRemovalRequest,
        target: WorktreeIntegrationTarget?
    ) -> WorktreeBranchRetentionReason? {
        guard let branchName else { return nil }
        if branchName == target?.branchName { return .defaultBranch }
        if request.branchPolicy == .keep { return .branchPolicyKeep }
        guard request.branchPolicy == .deleteIfIntegrated else { return nil }
        switch assessment?.grade {
        case .hasRemainingContribution:
            return .hasRemainingContribution
        case .unknown, nil:
            return .unknownAssessment
        case .integrated:
            return nil
        }
    }

    func shouldDeleteBranch(
        _ branchName: String?,
        assessment: BranchAssessment?,
        request: WorktreeRemovalRequest,
        target: WorktreeIntegrationTarget?
    ) -> Bool {
        guard let branchName, branchName != target?.branchName,
            request.branchPolicy != .keep,
            assessment?.commit != nil
        else {
            return false
        }
        if request.branchPolicy == .deleteAtObservedCommit { return true }
        if case .integrated? = assessment?.grade { return true }
        return false
    }

    static func fetchDetail(_ status: WorktreeFetchStatus) -> String {
        WorktreeCommandLineFormatter.fetchHumanLine(status)
    }

    static func branchReasonName(_ reason: WorktreeBranchRetentionReason) -> String {
        switch reason {
        case .defaultBranch:
            "defaultBranch"
        case .branchPolicyKeep:
            "branchPolicyKeep"
        case .hasRemainingContribution:
            "hasRemainingContribution"
        case .unknownAssessment:
            "unknownAssessment"
        case .checkedOut:
            "checkedOut"
        case .checkoutUnknown:
            "checkoutUnknown"
        case .movedSinceAssessment:
            "movedSinceAssessment"
        }
    }

    static func isDirty(_ status: GitStatusFactsRead) -> Bool {
        status.facts.summary.changedFileCount > 0
            || status.facts.summary.stagedFileCount > 0
            || status.facts.summary.unstagedFileCount > 0
            || status.facts.summary.untrackedFileCount > 0
            || conflictCount(status) > 0
    }

    static func dirtyDetails(_ status: GitStatusFactsRead) -> WorktreeDirtyStopDetails {
        let firstPaths = Set(status.facts.entries.filter { !$0.ignored }.map(\.path)).sorted()
        return WorktreeDirtyStopDetails(
            staged: status.facts.summary.stagedFileCount,
            unstaged: status.facts.summary.unstagedFileCount,
            untracked: status.facts.summary.untrackedFileCount,
            conflicted: conflictCount(status),
            firstPaths: Array(firstPaths.prefix(WorktreeLifecyclePolicy.firstPathsLimit))
        )
    }

    static func conflictCount(_ status: GitStatusFactsRead) -> Int {
        Set(
            status.facts.entries.compactMap { entry -> String? in
                entry.indexState == .unmerged || entry.worktreeState == .unmerged ? entry.path : nil
            }
        ).count
    }

    static func evidenceDisposition(
        for evidence: WorktreeTmpEvidenceScanResult,
        policy: WorktreeEvidencePolicy
    ) -> WorktreeEvidenceDispositionDocument {
        switch evidence {
        case .empty:
            .noEvidence
        case .nonEmpty:
            policy == .discard ? .discarded : .noEvidence
        case .unknown:
            policy == .discard ? .discarded : .noEvidence
        }
    }

    static func archiveDestination(
        policy: WorktreeEvidencePolicy,
        evidence: WorktreeTmpEvidenceScanResult,
        worktreePath: URL,
        mainWorktreePath: URL
    ) -> URL? {
        guard case .nonEmpty = evidence else { return nil }
        let folderName = worktreePath.lastPathComponent
        let destination: URL
        switch policy {
        case .archiveToMain:
            destination = WorktreeLifecyclePolicy.archiveToMainDestination(
                mainWorktree: mainWorktreePath,
                worktreeFolder: folderName
            )
        case .archive(let folder):
            destination = folder.appending(path: folderName, directoryHint: .isDirectory)
        case .requireEmpty, .discard:
            return nil
        }
        return destination.standardizedFileURL
    }

    static func archiveDestinationStop(
        _ destination: URL?,
        worktreePath: URL
    ) -> WorktreeStopDetails? {
        guard let destination else { return nil }
        let normalizedDestination = destination.standardizedFileURL.resolvingSymlinksInPath()
        if FileManager.default.fileExists(atPath: normalizedDestination.path) {
            return .archiveDestinationExists(path: normalizedDestination.path)
        }
        let rootPath = worktreePath.standardizedFileURL.resolvingSymlinksInPath().path
        if contains(rootPath: rootPath, candidatePath: normalizedDestination.path) {
            return .archiveDestinationInsideWorktree(path: normalizedDestination.path)
        }
        return nil
    }

    static func contains(rootPath: String, candidatePath: String) -> Bool {
        candidatePath == rootPath || candidatePath.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/")
    }

}
