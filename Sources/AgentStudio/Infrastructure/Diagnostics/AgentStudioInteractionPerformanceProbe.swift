import Foundation

package enum AgentStudioInteractionKind: String, Equatable, Sendable {
    case commandBarOpen = "command_bar_open"
    case commandBarClose = "command_bar_close"
    case tabMove = "tab_move"
    case dividerFrame = "divider_frame"
    case commandRefresh = "cmd_r"
    /// Browser tab selection to the Core Animation commit that mounts the tab's view.
    case browserTabSwitch = "browser_tab_switch"

    fileprivate var surface: AgentStudioInteractionSurface {
        switch self {
        case .commandBarOpen, .commandBarClose:
            .commandBar
        case .tabMove:
            .tabBar
        case .dividerFrame:
            .divider
        case .commandRefresh:
            .commandDispatcher
        case .browserTabSwitch:
            .browserTab
        }
    }
}

package enum AgentStudioInteractionBeginOutcome: Equatable, Sendable {
    case started
    case superseded
}

private enum AgentStudioInteractionSurface: Hashable, Sendable {
    case browserTab
    case commandBar
    case commandDispatcher
    case divider
    case tabBar
}

package final class AgentStudioInteractionPerformanceProbe: @unchecked Sendable {
    package typealias NowNanoseconds = @Sendable () -> UInt64
    package typealias RecordDuration = @Sendable (AgentStudioInteractionKind, Duration) -> Void

    private struct PendingInteraction: Sendable {
        let correlationId: UUID
        let kind: AgentStudioInteractionKind
        let startedAtNanoseconds: UInt64
    }

    private let nowNanoseconds: NowNanoseconds
    private let recordDuration: RecordDuration
    private let lock = NSLock()
    private var pendingBySurface: [AgentStudioInteractionSurface: PendingInteraction] = [:]

    package convenience init(
        recorder: AgentStudioPerformanceTraceRecorder,
        nowNanoseconds: @escaping NowNanoseconds = { DispatchTime.now().uptimeNanoseconds }
    ) {
        self.init(
            nowNanoseconds: nowNanoseconds,
            recordDuration: { kind, duration in
                recorder.recordInteractionLatency(kind: kind, duration: duration)
            }
        )
    }

    package init(
        nowNanoseconds: @escaping NowNanoseconds,
        recordDuration: @escaping RecordDuration
    ) {
        self.nowNanoseconds = nowNanoseconds
        self.recordDuration = recordDuration
    }

    @discardableResult
    package func beginInteraction(
        _ kind: AgentStudioInteractionKind,
        correlationId: UUID
    ) -> AgentStudioInteractionBeginOutcome {
        let pendingInteraction = PendingInteraction(
            correlationId: correlationId,
            kind: kind,
            startedAtNanoseconds: nowNanoseconds()
        )
        return lock.withLock {
            let outcome: AgentStudioInteractionBeginOutcome =
                pendingBySurface[kind.surface] == nil ? .started : .superseded
            pendingBySurface[kind.surface] = pendingInteraction
            return outcome
        }
    }

    @discardableResult
    package func settleInteraction(correlationId: UUID) -> Bool {
        let pendingInteraction: PendingInteraction? = lock.withLock {
            guard
                let matchingEntry = pendingBySurface.first(where: {
                    $0.value.correlationId == correlationId
                })
            else { return nil }
            pendingBySurface.removeValue(forKey: matchingEntry.key)
            return matchingEntry.value
        }
        guard let pendingInteraction else { return false }

        let settledAtNanoseconds = nowNanoseconds()
        let elapsedNanoseconds =
            settledAtNanoseconds >= pendingInteraction.startedAtNanoseconds
            ? settledAtNanoseconds - pendingInteraction.startedAtNanoseconds
            : 0
        recordDuration(
            pendingInteraction.kind,
            .nanoseconds(Int64(clamping: elapsedNanoseconds))
        )
        return true
    }

    @discardableResult
    package func cancelInteraction(correlationId: UUID) -> Bool {
        lock.withLock {
            guard
                let matchingEntry = pendingBySurface.first(where: {
                    $0.value.correlationId == correlationId
                })
            else { return false }
            pendingBySurface.removeValue(forKey: matchingEntry.key)
            return true
        }
    }
}
