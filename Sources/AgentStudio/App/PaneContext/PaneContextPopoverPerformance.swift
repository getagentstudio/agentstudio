import AgentStudioInfrastructure
import Foundation

/// Bounded diagnostic vocabulary; pane identities and rendered text never enter telemetry.
struct PaneContextPopoverPerformance: Sendable {
    enum Stage: String, CaseIterable {
        case observed, coalesced, deferred, admission, execution
        case storageRead = "storage_read"
        case projection, publication
        case validationPublication = "validation_publication"
        case inputPublication = "input_publication"
        case wake
        case emptyWake = "empty_wake"
        case capture, materialize, admit, classify, complete, equal, superseded, cancelled, retired
        case familyAdmission = "family_admission"
    }
    enum Kind: String {
        case notApplicable = "none"
        case opening, background, age, action, page
    }
    let recorder: AgentStudioPerformanceTraceRecorder?

    func record(_ stage: Stage, key: PaneContextPopoverConsumerKey? = nil, kind: Kind = .notApplicable) {
        recorder?.record(.paneContextPopover, attributes: attributes(stage, key: key, kind: kind))
    }

    /// This closure is synchronous, so its duration cannot include an actor suspension.
    @MainActor func mainActorHeld<Result>(
        _ stage: Stage, key: PaneContextPopoverConsumerKey, operation: () -> Result
    ) -> Result {
        guard let recorder, recorder.isEnabled else { return operation() }
        let start = ContinuousClock.now
        let result = operation()
        recorder.recordDuration(
            .paneContextPopoverMainActorHeld, duration: start.duration(to: .now),
            attributes: attributes(stage, key: key, kind: .notApplicable))
        return result
    }

    func observe(_ scope: PaneContextPopoverOwnerScope, _ fact: PaneContextPopoverOwnerFact) {
        let key: PaneContextPopoverConsumerKey?
        switch scope {
        case .consumer(let value, _), .execution(let value, _): key = value
        case .deadline, .input, .page: key = nil
        }
        switch fact {
        case .observed: record(.observed, key: key)
        case .coalesced: record(.coalesced, key: key)
        case .deferred: record(.deferred, key: key)
        case .admitted(let kind):
            let reason: Kind
            switch kind {
            case .opening: reason = .opening
            case .background: reason = .background
            case .age: reason = .age
            case .action: reason = .action
            case .page: reason = .page
            }
            record(.admission, key: key, kind: reason)
        case .readStarted: record(.storageRead, key: key)
        default: break
        }
    }

    private func attributes(_ stage: Stage, key: PaneContextPopoverConsumerKey?, kind: Kind)
        -> [String: AgentStudioTraceValue]
    {
        let surface: String
        switch key?.surface {
        case .sidebarMessages?: surface = "sidebar_messages"
        case .paneMessages?: surface = "pane_messages"
        case .cardMessages?: surface = "card_messages"
        case .agentLine?: surface = "agent_line"
        case .managementCard?: surface = "management_card"
        case .toolbar?: surface = "toolbar"
        case nil: surface = "shared"
        }
        return [
            "agentstudio.performance.pane_context.popover.stage": .string(stage.rawValue),
            "agentstudio.performance.pane_context.popover.surface": .string(surface),
            "agentstudio.performance.pane_context.popover.kind": .string(kind.rawValue),
        ]
    }
}
