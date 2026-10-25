import AgentStudioCore
import Foundation

extension TerminalActivationScheduler {
    enum ResumeEligibility { case awaitingClassification, awaitingResumeReadiness, installing, ready, retired }

    package func enqueueRestoreKind(_ kind: TerminalRestoreKind?, for paneID: PaneId) async {
        await enqueueRestoreKinds(kind.map { [paneID: $0] } ?? [:], for: [paneID])
    }

    /// A batch becomes selectable in one actor turn so dictionary/producer order
    /// cannot outrank the scheduler's foreground-first queue.
    package func enqueueRestoreKinds(_ kinds: [PaneId: TerminalRestoreKind], for paneIDs: [PaneId]) async {
        var readyKinds: [PaneId: TerminalRestoreKind] = [:]
        var readyPaneIDs: [PaneId] = []
        for paneID in paneIDs {
            guard var member = membersByPaneID[paneID], member.resumeEligibility == .awaitingClassification,
                !isTerminalExecution(member.execution)
            else { continue }
            if case .cold = kinds[paneID] {
                member.resumeEligibility = .awaitingResumeReadiness
            } else {
                member.resumeEligibility = .installing
                readyPaneIDs.append(paneID)
                if let kind = kinds[paneID] { readyKinds[paneID] = kind }
            }
            membersByPaneID[paneID] = member
        }
        await installAndReleaseKinds(readyKinds, paneIDs: readyPaneIDs)
    }

    /// The App-supplied decision performs readiness, cold end and B1 on their
    /// owning lanes. Eligibility remains held until its final plan is installed.
    package func releaseAwaitingResumeReadiness(
        _ plans: [PaneId: TerminalColdRestorePlan],
        deciding: @Sendable (PaneId, TerminalColdRestorePlan) async -> TerminalColdRestorePlan = { _, plan in plan }
    ) async {
        var accepted: [PaneId: TerminalRestoreKind] = [:]
        for (paneID, plan) in plans {
            guard var member = membersByPaneID[paneID], member.resumeEligibility == .awaitingResumeReadiness,
                !isTerminalExecution(member.execution)
            else { continue }
            member.resumeEligibility = .installing
            membersByPaneID[paneID] = member
            let decided = await deciding(paneID, plan)
            guard let current = membersByPaneID[paneID], current.resumeEligibility == .installing,
                !isTerminalExecution(current.execution)
            else { continue }
            accepted[paneID] = .cold(decided)
        }
        accepted = accepted.filter { paneID, _ in
            guard let member = membersByPaneID[paneID] else { return false }
            return member.resumeEligibility == .installing && !isTerminalExecution(member.execution)
        }
        guard !accepted.isEmpty else { return }
        await installAndReleaseKinds(accepted, paneIDs: Array(accepted.keys))
    }

    package func retireAwaitingResumeReadiness(_ paneID: PaneId) {
        guard var member = membersByPaneID[paneID], !isTerminalExecution(member.execution),
            member.resumeEligibility != .ready, member.resumeEligibility != .retired
        else { return }
        member.resumeEligibility = .retired
        member.execution = .terminal(
            .failedTerminal(
                failure: .attachmentRejected(code: "pane_retired"), retry: .notRequested(attemptCount: 0)))
        membersByPaneID[paneID] = member
        eligibilityWaiter?.yield(())
    }

    private func installAndReleaseKinds(_ kinds: [PaneId: TerminalRestoreKind], paneIDs: [PaneId]) async {
        if !kinds.isEmpty { await admissionPort.installRestoreKinds(kinds) }
        for paneID in paneIDs { markResumeEligible(paneID) }
        eligibilityWaiter?.yield(())
    }

    private func markResumeEligible(_ paneID: PaneId) {
        guard var member = membersByPaneID[paneID], member.resumeEligibility == .installing,
            !isTerminalExecution(member.execution)
        else { return }
        member.resumeEligibility = .ready
        membersByPaneID[paneID] = member
    }

    func isTerminalExecution(_ execution: MemberExecution) -> Bool {
        if case .terminal = execution { return true }
        return false
    }

    func hasPendingResumeEligibility() -> Bool {
        membersByPaneID.values.contains { member in
            guard !isTerminalExecution(member.execution) else { return false }
            switch member.resumeEligibility {
            case .awaitingClassification, .awaitingResumeReadiness, .installing: return true
            case .ready, .retired: return false
            }
        }
    }
}
