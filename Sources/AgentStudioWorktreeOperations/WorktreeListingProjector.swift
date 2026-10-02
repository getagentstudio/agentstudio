import AgentStudioGit
import Foundation

package struct WorktreeListingProjectionInput: Sendable {
    package let snapshot: GitWorktreeSnapshot
    package let repositoryPath: URL
    package let callerDirectory: URL?
    package let targetResolution: WorktreeIntegrationTargetResolution
    package let integrationGrade: GitBranchIntegrationGrade?
    package let status: GitStatusFactsRead?
    package let evidence: WorktreeTmpEvidenceScanResult

    package init(
        snapshot: GitWorktreeSnapshot,
        repositoryPath: URL,
        callerDirectory: URL?,
        targetResolution: WorktreeIntegrationTargetResolution,
        integrationGrade: GitBranchIntegrationGrade?,
        status: GitStatusFactsRead?,
        evidence: WorktreeTmpEvidenceScanResult
    ) {
        self.snapshot = snapshot
        self.repositoryPath = repositoryPath
        self.callerDirectory = callerDirectory
        self.targetResolution = targetResolution
        self.integrationGrade = integrationGrade
        self.status = status
        self.evidence = evidence
    }
}

package enum WorktreeListingProjector {
    package static func filteredWorktrees(
        _ snapshots: [GitWorktreeSnapshot],
        targets: [String],
        callerDirectory: URL?
    ) -> [GitWorktreeSnapshot] {
        guard !targets.isEmpty else { return snapshots }
        return snapshots.filter { snapshot in
            targets.contains { targetMatches($0, snapshot: snapshot, callerDirectory: callerDirectory) }
        }
    }

    package static func listing(_ input: WorktreeListingProjectionInput) -> WorktreeListing {
        let snapshot = input.snapshot
        let repositoryPath = input.repositoryPath
        let callerDirectory = input.callerDirectory
        let targetResolution = input.targetResolution
        let integrationGrade = input.integrationGrade
        let status = input.status
        let evidence = input.evidence
        let branch = branchName(in: snapshot.head)
        let changes = changesDocument(status)
        let integration = integrationDocument(
            branch: branch,
            resolution: targetResolution,
            grade: integrationGrade
        )
        let temporaryStatus = temporaryDocument(evidence)
        let currentPath = callerDirectory?.standardizedFileURL.resolvingSymlinksInPath().path
        let worktreePath = snapshot.canonicalPath.standardizedFileURL.resolvingSymlinksInPath().path
        let isCurrent = currentPath.map { Self.contains(rootPath: worktreePath, candidatePath: $0) } ?? false
        let blockers = blockerDocuments(
            snapshot: snapshot,
            isCurrent: isCurrent,
            changes: changes,
            status: status,
            evidence: evidence
        )
        let removable = blockers.isEmpty
        let remove =
            removable
            ? "agentstudio worktree remove --repo \(shellArgument(repositoryPath.standardizedFileURL.path)) \(shellArgument(snapshot.canonicalPath.standardizedFileURL.path))"
            : nil

        return WorktreeListing(
            path: snapshot.canonicalPath,
            branch: branch,
            isMain: snapshot.isMainWorktree,
            isCurrent: isCurrent,
            isLocked: snapshot.isLocked,
            changes: changes,
            integration: integration,
            tmp: temporaryStatus,
            activity: .notChecked,
            removable: removable,
            blockers: blockers,
            remove: remove
        )
    }

    private static func targetMatches(
        _ target: String,
        snapshot: GitWorktreeSnapshot,
        callerDirectory: URL?
    ) -> Bool {
        if let callerDirectory {
            let unresolvedTarget =
                target.hasPrefix("/")
                ? URL(fileURLWithPath: target)
                : callerDirectory.appending(path: target, directoryHint: .isDirectory)
            let targetPath = unresolvedTarget.standardizedFileURL.resolvingSymlinksInPath()
            var isDirectory = ObjCBool(false)
            if FileManager.default.fileExists(atPath: targetPath.path, isDirectory: &isDirectory), isDirectory.boolValue
            {
                let rootPath = snapshot.canonicalPath.standardizedFileURL.resolvingSymlinksInPath().path
                return contains(rootPath: rootPath, candidatePath: targetPath.path)
            }
        }
        return branchName(in: snapshot.head) == target
    }

    package static func branchName(in head: GitHeadSnapshot?) -> String? {
        guard let head else { return nil }
        switch head.kind {
        case .branch, .unborn:
            return head.shortName
        case .detached:
            return nil
        }
    }

    private static func changesDocument(_ status: GitStatusFactsRead?) -> WorktreeChangesDocument {
        guard let status else {
            return WorktreeChangesDocument(
                status: .unknown, staged: nil, unstaged: nil, untracked: nil, conflicted: nil)
        }
        let conflicts = Set(
            status.facts.entries.compactMap { entry -> String? in
                entry.indexState == .unmerged || entry.worktreeState == .unmerged ? entry.path : nil
            }
        ).count
        let hasChanges =
            status.facts.summary.changedFileCount > 0
            || status.facts.summary.stagedFileCount > 0
            || status.facts.summary.unstagedFileCount > 0
            || status.facts.summary.untrackedFileCount > 0
            || conflicts > 0
        return WorktreeChangesDocument(
            status: hasChanges ? .dirty : .clean,
            staged: status.facts.summary.stagedFileCount,
            unstaged: status.facts.summary.unstagedFileCount,
            untracked: status.facts.summary.untrackedFileCount,
            conflicted: conflicts
        )
    }

    private static func integrationDocument(
        branch: String?,
        resolution: WorktreeIntegrationTargetResolution,
        grade: GitBranchIntegrationGrade?
    ) -> WorktreeIntegrationAssessmentDocument? {
        guard let branch else { return nil }
        if resolution.hasReadFailure { return .unknown(.readFailed) }
        let target = resolution.target
        guard let target else { return .unknown(.noTarget) }
        guard branch != target.branchName else { return nil }
        guard let grade else { return .unknown(.readFailed) }

        switch grade {
        case .integrated(let proof):
            switch proof {
            case .sameCommit:
                return .integrated(.sameCommit)
            case .ancestor:
                return .integrated(.ancestor)
            case .sameContent:
                return .integrated(.sameContent)
            case .emptyDelta:
                return .integrated(.emptyDelta)
            case .squash(let commit):
                return .integrated(.squash(commit: commit))
            }
        case .hasRemainingContribution:
            return .hasRemainingContribution
        case .unknown(let reason):
            switch reason {
            case .branchNotFound:
                return .unknown(.branchNotFound)
            case .noMergeBase:
                return .unknown(.noMergeBase)
            case .multipleMergeBases:
                return .unknown(.multipleMergeBases)
            case .historyLimitReached:
                return .unknown(.historyLimitReached)
            case .incompleteHistory:
                return .unknown(.incompleteHistory)
            case .missingObjects:
                return .unknown(.missingObjects)
            case .readFailed:
                return .unknown(.readFailed)
            }
        }
    }

    private static func temporaryDocument(_ evidence: WorktreeTmpEvidenceScanResult)
        -> WorktreeTmpEvidenceStatusDocument
    {
        switch evidence {
        case .empty:
            .empty
        case .nonEmpty:
            .nonEmpty
        case .unknown:
            .unknown
        }
    }

    private static func blockerDocuments(
        snapshot: GitWorktreeSnapshot,
        isCurrent: Bool,
        changes: WorktreeChangesDocument,
        status: GitStatusFactsRead?,
        evidence: WorktreeTmpEvidenceScanResult
    ) -> [WorktreeRefusalDocument] {
        var details: [WorktreeStopDetails] = []
        if snapshot.isMainWorktree {
            details.append(.mainWorktree)
        }
        if isCurrent {
            details.append(.targetIsCurrent(path: snapshot.canonicalPath.standardizedFileURL.path))
        }
        if snapshot.isLocked {
            details.append(.worktreeLocked(reason: snapshot.lockReason))
        }

        if let status {
            if changes.status == .dirty {
                details.append(
                    .dirty(
                        WorktreeDirtyStopDetails(
                            staged: status.facts.summary.stagedFileCount,
                            unstaged: status.facts.summary.unstagedFileCount,
                            untracked: status.facts.summary.untrackedFileCount,
                            conflicted: changes.conflicted ?? 0,
                            firstPaths: Array(
                                status.facts.entries
                                    .filter { !$0.ignored }
                                    .map(\.path)
                                    .prefix(WorktreeLifecyclePolicy.firstPathsLimit)
                            )
                        )
                    ))
            }
        } else {
            details.append(.changesUnknown)
        }

        switch evidence {
        case .empty:
            break
        case .nonEmpty(let fileCount, let byteCount, let firstPaths):
            details.append(.evidenceInTmp(fileCount: fileCount, byteCount: byteCount, firstPaths: firstPaths))
        case .unknown(let path):
            details.append(.evidenceUnknown(path: path.standardizedFileURL.path))
        }

        let order = Dictionary(uniqueKeysWithValues: WorktreeStopReason.lr11Order.enumerated().map { ($1, $0) })
        return
            details
            .sorted { (order[$0.reason] ?? Int.max) < (order[$1.reason] ?? Int.max) }
            .map(WorktreeRefusalDocument.init(details:))
    }

    private static func contains(rootPath: String, candidatePath: String) -> Bool {
        candidatePath == rootPath || candidatePath.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/")
    }

    package static func shellArgument(_ argument: String) -> String {
        guard argument.range(of: #"^[A-Za-z0-9_./:@+-]+$"#, options: .regularExpression) == nil else {
            return argument
        }
        return "'\(argument.replacingOccurrences(of: "'", with: "'\"'\"'"))'"
    }
}
