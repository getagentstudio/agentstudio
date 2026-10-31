import AgentStudioInfrastructure
import Foundation
import Synchronization

/// Bounded diagnostic vocabulary; pane identities and rendered text never enter telemetry.
struct PaneContextPopoverPerformance: Sendable {
    final class LayoutCounter: Sendable {
        private let value = Mutex<UInt64>(0)
        var current: UInt64 { value.withLock { $0 } }
        func increment() { value.withLock { $0 &+= 1 } }
    }
    enum Stage: String, CaseIterable {
        case observed, coalesced, deferred, admission, execution
        case storageRead = "storage_read"
        case projection, publication
        case validationPublication = "validation_publication"
        case inputPublication = "input_publication"
        case wake
        case emptyWake = "empty_wake"
        case capture, materialize, admit, classify, apply, complete, equal, superseded, cancelled, retired
        case familyAdmission = "family_admission"
        case textLayout = "text_layout"
        case textLayoutReuse = "text_layout_reuse"
    }
    enum Kind: String {
        case notApplicable = "none"
        case opening, background, age, action, page
    }
    let recorder: AgentStudioPerformanceTraceRecorder?
    let bodyLayoutObserver: (@Sendable (PaneContextMessageBodyMeasurement.Observation) -> Void)?
    let layoutCounter = LayoutCounter()

    init(
        recorder: AgentStudioPerformanceTraceRecorder?,
        bodyLayoutObserver: (@Sendable (PaneContextMessageBodyMeasurement.Observation) -> Void)? = nil
    ) {
        self.recorder = recorder
        self.bodyLayoutObserver = bodyLayoutObserver
    }

    var textLayoutCount: UInt64 { layoutCounter.current }

    func textLayoutCompleted(key: PaneContextPopoverConsumerKey, measurement: PaneContextMessageBodyMeasurement.Key) {
        layoutCounter.increment()
        bodyLayoutObserver?(.completed(measurement))
        guard let recorder, recorder.isEnabled else { return }
        var values = attributes(.textLayout, key: key, kind: .notApplicable)
        values["agentstudio.performance.pane_context.popover.text_layout.count"] = .int(1)
        values["agentstudio.performance.pane_context.popover.off_main"] = .bool(!Thread.isMainThread)
        recorder.record(.paneContextPopover, attributes: values)
    }

    /// The synchronous worker call records both one completed projection and its elapsed work.
    func project<Result>(key: PaneContextPopoverConsumerKey, operation: () -> Result) -> Result {
        guard let recorder, recorder.isEnabled else { return operation() }
        let start = ContinuousClock.now
        let result = operation()
        let duration = start.duration(to: .now)
        var values = attributes(.projection, key: key, kind: .notApplicable)
        values["agentstudio.performance.pane_context.popover.projection_elapsed_ms"] =
            .double(AgentStudioPerformanceTraceRecorder.milliseconds(from: duration))
        values["agentstudio.performance.pane_context.popover.off_main"] = .bool(!Thread.isMainThread)
        recorder.recordDuration(.paneContextPopover, duration: duration, attributes: values)
        return result
    }

    @MainActor func mainActorApplyStarted() -> ContinuousClock.Instant? {
        guard recorder?.isEnabled == true else { return nil }
        return .now
    }

    @MainActor func mainActorApplyCompleted(since start: ContinuousClock.Instant, key: PaneContextPopoverConsumerKey) {
        guard let recorder, recorder.isEnabled else { return }
        let duration = start.duration(to: .now)
        var values = attributes(.apply, key: key, kind: .notApplicable)
        values["agentstudio.performance.pane_context.popover.apply_commit_elapsed_ms"] =
            .double(AgentStudioPerformanceTraceRecorder.milliseconds(from: duration))
        recorder.recordDuration(.paneContextPopoverMainActorHeld, duration: duration, attributes: values)
    }

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
