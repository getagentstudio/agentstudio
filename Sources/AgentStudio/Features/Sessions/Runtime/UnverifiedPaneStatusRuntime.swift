import AgentStudioCore
import AgentStudioInfrastructure
import Foundation

/// Main election and status only. No identity, repository, resume or message effects.
struct UnverifiedPaneStatusRuntime: Sendable {
    struct MainIdentity: Hashable, Sendable {
        let provider: String
        let sessionId: String
    }
    struct PaneState: Sendable {
        var main: MainIdentity?
        var establishedAt: ContinuousClock.Instant
        var status: SessionStatusState
        var released: Set<MainIdentity> = []
        var sequence: Int64 = 0
    }
    var panes: [UUID: PaneState] = [:]

    mutating func apply(_ hook: SessionsHookAdmission) -> Bool {
        guard let signal = hook.signal else { return false }
        let candidate = MainIdentity(provider: hook.providerIdentifier, sessionId: hook.sessionId)
        var pane: PaneState
        if let previous = panes[hook.paneId] {
            pane = previous
            let cursorPrompt = candidate.provider == "cursor" && signal.name == .turnStart
            if let main = pane.main, main != candidate {
                guard cursorPrompt, main.provider == "cursor" else { return false }
                pane.released.insert(main)
                pane.main = nil
            }
            if pane.main == nil {
                guard !pane.released.contains(candidate) || signal.name == .sessionStart || cursorPrompt else {
                    return false
                }
                pane.main = candidate
                pane.establishedAt = hook.admissionInstant
                pane.status = SessionStatusState(binding: .bound(UUIDv7.generate()))
            }
        } else {
            pane = PaneState(
                main: candidate, establishedAt: hook.admissionInstant,
                status: SessionStatusState(binding: .bound(UUIDv7.generate())))
        }
        guard case .bound(let generation) = pane.status.binding else { return false }
        let input = signal.statusInput(occurrenceId: hook.recordId, bindingId: generation)
        pane.sequence += 1
        SessionStatusReducer.apply(
            .init(
                input: input, sequence: pane.sequence, occurredAt: hook.admittedAt,
                admittedAt: hook.admissionInstant, turnId: hook.turnId), to: &pane.status)
        if signal.name == .sessionEnd {
            pane.released.insert(candidate)
            pane.main = nil
        }
        panes[hook.paneId] = pane
        return true
    }

    @discardableResult
    mutating func commandFinished(paneId: UUID, reportedAt: ContinuousClock.Instant, at: Date) -> Bool {
        guard var pane = panes[paneId], let main = pane.main, pane.establishedAt < reportedAt else { return false }
        pane.sequence += 1
        SessionStatusReducer.apply(
            .init(
                input: .sessionEnd, sequence: pane.sequence, occurredAt: at,
                admittedAt: reportedAt, turnId: nil), to: &pane.status)
        pane.released.insert(main)
        pane.main = nil
        panes[paneId] = pane
        return true
    }

    mutating func viewed(paneId: UUID, at: ContinuousClock.Instant) {
        guard var pane = panes[paneId] else { return }
        SessionStatusReducer.apply(
            .init(input: .paneViewed(at), sequence: 0, occurredAt: Date(), admittedAt: at, turnId: nil),
            to: &pane.status)
        panes[paneId] = pane
    }

    func status(paneId: UUID) -> AgentSessionStatus? {
        panes[paneId].map { SessionStatusReducer.status(of: $0.status) }
    }
}
