import AgentStudioGit
import Foundation

extension WorktreeCommandLineFormatter {
    package static func removalHumanLine(_ entry: WorktreeRemovalEntry) -> String {
        switch entry {
        case .removed(let details):
            return "removed \(details.target); \(removalEffectsHumanLine(details.effects))"
        case .alreadyRemoved(let details):
            return "alreadyRemoved \(details.target)"
        case .refused(let details):
            return "refused \(details.target); \(stopHumanLine(details.refusal))"
        case .failed(let details):
            let stop = details.failure.stop.map { "; \(stopHumanLine($0))" } ?? ""
            return
                "failed \(details.target): \(removalFailureName(details.failure.kind)); \(removalEffectsHumanLine(details.failure.effects))\(stop)"
        case .planned(let details):
            let steps = details.plan.steps.map { step in
                let detail = step.detail.map { " (\($0))" } ?? ""
                return "\(step.kind.rawValue)=\(step.disposition.rawValue)\(detail)"
            }.joined(separator: ", ")
            let stop = details.plan.stopsAt.map { "; \(stopHumanLine($0))" } ?? ""
            return "planned \(details.target); steps: [\(steps)]\(stop)"
        }
    }

    package static func removalHumanLines(_ report: WorktreeRemovalReport) -> String {
        if let failure = report.fetchingReadFailure {
            return fetchingReadFailureHumanLine(failure)
        }
        return ([fetchHumanLine(report.fetch)] + report.entries.map(removalHumanLine)).joined(separator: "\n")
    }

    private static func removalFailureName(_ failure: WorktreeRemovalFailureKindDocument) -> String {
        switch failure {
        case .archiveFailed:
            "archiveFailed"
        case .activityChanged:
            "activityChanged"
        case .pruneFailed:
            "pruneFailed"
        case .observationFailed:
            "observationFailed"
        case .removalIncomplete:
            "removalIncomplete"
        case .branchDeletionUncertain:
            "branchDeletionUncertain"
        case .branchDeletionFailed(let cause):
            "branchDeletionFailed(\(cause.name))"
        case .lockCleanupIncomplete:
            "lockCleanupIncomplete"
        }
    }

    private static func removalEffectsHumanLine(_ effects: WorktreeRemovalEffectsDocument) -> String {
        let branch = effects.branch.map(branchDispositionHumanLine) ?? "notApplicable"
        return [
            "directory=\(effects.directory.rawValue)",
            "administration=\(effects.administration.rawValue)",
            "branch=\(branch)",
            "evidence=\(evidenceHumanLine(effects.evidence))",
            "assessment=\(assessmentHumanLine(effects.assessment))",
            "activity=\(activityHumanLine(effects.activity))",
            "lockResidue=[\(effects.lockResidue.joined(separator: ", "))]",
        ].joined(separator: "; ")
    }

    private static func branchDispositionHumanLine(_ branch: WorktreeBranchDispositionDocument) -> String {
        var line = "\(branch.disposition.rawValue) \(branch.name)"
        if let commit = branch.commit { line += "@\(commit)" }
        if let reason = branch.reason {
            line += " reason=\(branchReasonHumanLine(reason))"
            line += " options=[\(branch.options.joined(separator: "; "))]"
        }
        if !branch.cleanupWarnings.isEmpty {
            line += " cleanupWarnings=[\(branch.cleanupWarnings.map(\.rawValue).joined(separator: ", "))]"
        }
        return line
    }

    private static func branchReasonHumanLine(_ reason: WorktreeBranchRetentionReason) -> String {
        switch reason {
        case .defaultBranch:
            "defaultBranch"
        case .defaultBranchUnverified:
            "defaultBranchUnverified"
        case .branchPolicyKeep:
            "branchPolicyKeep"
        case .hasRemainingContribution:
            "hasRemainingContribution"
        case .unknownAssessment:
            "unknownAssessment"
        case .checkedOut(let worktreePaths):
            "checkedOut paths=[\(worktreePaths.joined(separator: ", "))]"
        case .checkoutUnknown:
            "checkoutUnknown"
        case .movedSinceAssessment:
            "movedSinceAssessment"
        }
    }

    private static func evidenceHumanLine(_ evidence: WorktreeEvidenceDispositionDocument) -> String {
        switch evidence {
        case .archived(let path, let files, let skippedSpecialFiles):
            "archived path=\(path) files=\(files)"
                + skippedSpecialFilesHumanSuffix(skippedSpecialFiles)
        case .partialCopy(let path):
            "partialCopy path=\(path)"
        case .discarded:
            "discarded"
        case .noEvidence:
            "none"
        }
    }

    private static func skippedSpecialFilesHumanSuffix(_ skippedSpecialFiles: [String]) -> String {
        guard !skippedSpecialFiles.isEmpty else { return "" }
        let fileLabel = skippedSpecialFiles.count == 1 ? "file" : "files"
        let paths = skippedSpecialFiles.joined(separator: ", ")
        return " skipped \(skippedSpecialFiles.count) special \(fileLabel) (not copyable): \(paths)"
    }

    package static func assessmentHumanLine(_ assessment: WorktreeIntegrationAssessmentDocument?) -> String {
        guard let assessment else { return "notApplicable" }
        return switch assessment {
        case .integrated(let proof):
            switch proof {
            case .sameCommit:
                "integrated(sameCommit)"
            case .ancestor:
                "integrated(ancestor)"
            case .sameContent:
                "integrated(sameContent)"
            case .emptyDelta:
                "integrated(emptyDelta)"
            case .squash(let commit):
                "integrated(squash \(commit))"
            }
        case .hasRemainingContribution:
            "hasRemainingContribution"
        case .unknown(let reason):
            "unknown(\(reason.rawValue))"
        }
    }

    private static func activityHumanLine(_ activity: WorktreeActivityDocument) -> String {
        switch activity {
        case .notChecked:
            return "notChecked"
        case .noActivity:
            return "none"
        case .openPanes(let panes):
            let paneDescriptions = panes.map { pane in
                "\(pane.id):\(pane.displayTitle)"
            }
            return "openPanes=[\(paneDescriptions.joined(separator: ", "))]"
        }
    }

    package static func stopHumanLine(_ refusal: WorktreeRefusalDocument) -> String {
        let details = stopDetailsHumanLine(refusal.details)
        let options = refusal.options.map { option in
            switch option.action {
            case .flag(let flag):
                "\(flag): \(option.effect)"
            case .command(let command):
                "\(command): \(option.effect)"
            }
        }
        let detailSuffix = details.isEmpty ? "" : "; details: \(details)"
        let optionSuffix = options.isEmpty ? "" : "; options: [\(options.joined(separator: "; "))]"
        return "stop=\(refusal.reason.rawValue); \(refusal.message)\(detailSuffix)\(optionSuffix)"
    }

    private static func stopDetailsHumanLine(_ details: WorktreeStopDetails) -> String {
        switch details {
        case .creation(let stop):
            [stop.path, stop.humanDetail].compactMap { $0 }.joined(separator: " ")
        case .defaultBranch, .defaultBranchUnverified, .mainWorktree, .changesUnknown:
            ""
        case .gitLockUnidentified(let resource):
            "resource=\(lockResourceHumanLine(resource))"
        case .notFound(let target), .alreadyRemoved(let target):
            "target=\(target)"
        case .startBranchNotFound(let branch):
            "branch=\(branch)"
        case .unsupportedWorkingState(let refusal):
            "path=\(refusal.relativePath ?? "unknown") reason=\(refusal.reason.rawValue)"
        case .targetIsCurrent(let path):
            "path=\(path)"
        case .worktreeLocked(let reason):
            reason.map { "reason=\($0)" } ?? ""
        case .dirty(let changes):
            "staged=\(changes.staged) unstaged=\(changes.unstaged) untracked=\(changes.untracked) conflicted=\(changes.conflicted) paths=[\(changes.firstPaths.joined(separator: ", "))]"
        case .evidenceInTmp(let fileCount, let byteCount, let firstPaths):
            "files=\(fileCount) bytes=\(byteCount) paths=[\(firstPaths.joined(separator: ", "))]"
        case .evidenceUnknown(let path):
            "path=\(path)"
        case .openInPane(let panes):
            "panes=[\(panes.map(\.paneId).joined(separator: ", "))]"
        case .gitLockHeld(let observation):
            "path=\(observation.path) resource=\(lockResourceHumanLine(observation.resource)) ageSeconds=\(observation.ageSeconds) gitProcessFound=\(observation.gitProcessFound) looksStale=\(observation.looksStale)"
        case .archiveDestinationExists(let path), .archiveDestinationInsideWorktree(let path):
            "path=\(path)"
        case .forkUnavailable(let reason):
            "reason=\(reason)"
        }
    }

    private static func lockResourceHumanLine(_ resource: GitLockResource) -> String {
        switch resource {
        case .index(let worktreePath):
            "index \(worktreePath.path)"
        case .reference(let name):
            "reference \(name)"
        case .packedRefs:
            "packed-refs"
        case .config:
            "config"
        }
    }
}
