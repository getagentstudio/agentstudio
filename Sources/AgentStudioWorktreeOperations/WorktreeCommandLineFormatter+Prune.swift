import Foundation

extension WorktreeCommandLineFormatter {
    package static func pruneHumanLines(_ summary: WorktreePruneSummary) -> String {
        let target = summary.target.map { "\($0.ref)@\($0.commit)" } ?? "none"
        let heading = "pruned apply=\(summary.applied) target=\(target)"
        return ([fetchHumanLine(summary.fetch), heading] + summary.entries.map(pruneHumanLine)).joined(separator: "\n")
    }

    private static func pruneHumanLine(_ entry: WorktreePruneEntry) -> String {
        switch entry {
        case .removed(let details):
            return removalHumanLine(.removed(details))
        case .wouldRemove(let details):
            return
                "wouldRemove \(details.target); branch=\(details.branch); assessment=\(assessmentHumanLine(details.assessment))"
        case .skipped(let details):
            let reason = pruneSkipReason(details.skip.reason)
            let stop = details.skip.details.map { stopHumanLine(WorktreeRefusalDocument(details: $0)) }
            let stopText = stop.map { "; \($0)" } ?? ""
            let options = details.skip.options.joined(separator: "; ")
            return "skipped \(details.target); reason=\(reason)\(stopText); options=[\(options)]"
        case .failed(let details):
            return removalHumanLine(.failed(details))
        }
    }

    private static func pruneSkipReason(_ reason: WorktreePruneSkipReason) -> String {
        switch reason {
        case .stop(let stop):
            stop.rawValue
        case .notIntegrated:
            "notIntegrated"
        case .assessmentUnknown(let assessmentReason):
            "assessmentUnknown(\(assessmentReason.rawValue))"
        case .detached:
            "detached"
        case .defaultBranch:
            "defaultBranch"
        }
    }
}
