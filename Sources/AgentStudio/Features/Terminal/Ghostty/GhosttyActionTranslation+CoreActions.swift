import AgentStudioCore
import AgentStudioInfrastructure
import AppKit
import Foundation
import GhosttyKit
import os.log

extension GhosttyActionTranslation {
    static func translateSetTitle(payload: GhosttyActionPayload, actionTag: GhosttyActionTag) -> GhosttyEvent {
        guard case .titleChanged(let title) = payload else {
            return payloadMismatch(
                actionTag: actionTag,
                payload: payload,
                expectedPayload: ".titleChanged(String)"
            )
        }
        return .titleChanged(title)
    }

    static func translateSetTabTitle(payload: GhosttyActionPayload, actionTag: GhosttyActionTag) -> GhosttyEvent {
        guard case .tabTitleChanged(let title) = payload else {
            return payloadMismatch(
                actionTag: actionTag,
                payload: payload,
                expectedPayload: ".tabTitleChanged(String)"
            )
        }
        return .tabTitleChanged(title)
    }

    static func translatePwd(payload: GhosttyActionPayload, actionTag: GhosttyActionTag) -> GhosttyEvent {
        guard case .cwdChanged(let cwdPath) = payload else {
            return payloadMismatch(
                actionTag: actionTag,
                payload: payload,
                expectedPayload: ".cwdChanged(String)"
            )
        }
        return .cwdChanged(cwdPath)
    }

    static func translateCommandFinished(payload: GhosttyActionPayload, actionTag: GhosttyActionTag) -> GhosttyEvent {
        guard case .commandFinished(let exitCode, let duration, _) = payload else {
            return payloadMismatch(
                actionTag: actionTag,
                payload: payload,
                expectedPayload:
                    ".commandFinished(exitCode: Int, duration: UInt64, sourceInstant: ContinuousClock.Instant)"
            )
        }
        return .commandFinished(exitCode: exitCode, duration: duration)
    }

    static func translateCloseTab(payload: GhosttyActionPayload, actionTag: GhosttyActionTag) -> GhosttyEvent {
        guard
            case .closeTab(let modeRawValue) = payload,
            let mode = closeTabMode(from: modeRawValue)
        else {
            return payloadMismatch(
                actionTag: actionTag,
                payload: payload,
                expectedPayload: ".closeTab(modeRawValue: UInt32)"
            )
        }
        return .closeTab(mode: mode)
    }

    static func translateGotoTab(payload: GhosttyActionPayload, actionTag: GhosttyActionTag) -> GhosttyEvent {
        guard
            case .gotoTab(let targetRawValue) = payload,
            let target = gotoTabTarget(from: targetRawValue)
        else {
            return payloadMismatch(
                actionTag: actionTag,
                payload: payload,
                expectedPayload: ".gotoTab(targetRawValue: Int32)"
            )
        }
        return .gotoTab(target: target)
    }

    static func translateMoveTab(payload: GhosttyActionPayload, actionTag: GhosttyActionTag) -> GhosttyEvent {
        guard case .moveTab(let amount) = payload else {
            return payloadMismatch(
                actionTag: actionTag,
                payload: payload,
                expectedPayload: ".moveTab(amount: Int)"
            )
        }
        return .moveTab(amount: amount)
    }

    static func translateNewSplit(payload: GhosttyActionPayload, actionTag: GhosttyActionTag) -> GhosttyEvent {
        guard
            case .newSplit(let directionRawValue) = payload,
            let direction = splitDirection(from: directionRawValue)
        else {
            return payloadMismatch(
                actionTag: actionTag,
                payload: payload,
                expectedPayload: ".newSplit(directionRawValue: UInt32)"
            )
        }
        return .newSplit(direction: direction)
    }

    static func translateGotoSplit(payload: GhosttyActionPayload, actionTag: GhosttyActionTag) -> GhosttyEvent {
        guard
            case .gotoSplit(let directionRawValue) = payload,
            let direction = gotoSplitDirection(from: directionRawValue)
        else {
            return payloadMismatch(
                actionTag: actionTag,
                payload: payload,
                expectedPayload: ".gotoSplit(directionRawValue: UInt32)"
            )
        }
        return .gotoSplit(direction: direction)
    }

    static func translateResizeSplit(payload: GhosttyActionPayload, actionTag: GhosttyActionTag) -> GhosttyEvent {
        guard
            case .resizeSplit(let amount, let directionRawValue) = payload,
            let direction = resizeSplitDirection(from: directionRawValue)
        else {
            return payloadMismatch(
                actionTag: actionTag,
                payload: payload,
                expectedPayload: ".resizeSplit(amount: UInt16, directionRawValue: UInt32)"
            )
        }
        return .resizeSplit(amount: amount, direction: direction)
    }

    static func translateProgressReport(payload: GhosttyActionPayload, actionTag: GhosttyActionTag) -> GhosttyEvent {
        guard case .progressReport(let stateRawValue, let progress) = payload else {
            return payloadMismatch(
                actionTag: actionTag,
                payload: payload,
                expectedPayload: ".progressReport(stateRawValue: UInt32, progress: Int8)"
            )
        }

        switch stateRawValue {
        case UInt32(truncatingIfNeeded: GHOSTTY_PROGRESS_STATE_REMOVE.rawValue):
            return .progressReportUpdated(nil)
        case UInt32(truncatingIfNeeded: GHOSTTY_PROGRESS_STATE_SET.rawValue):
            return .progressReportUpdated(ProgressState(kind: .set, percent: progressPercent(progress)))
        case UInt32(truncatingIfNeeded: GHOSTTY_PROGRESS_STATE_ERROR.rawValue):
            return .progressReportUpdated(ProgressState(kind: .error, percent: progressPercent(progress)))
        case UInt32(truncatingIfNeeded: GHOSTTY_PROGRESS_STATE_INDETERMINATE.rawValue):
            return .progressReportUpdated(
                ProgressState(kind: .indeterminate, percent: progressPercent(progress))
            )
        case UInt32(truncatingIfNeeded: GHOSTTY_PROGRESS_STATE_PAUSE.rawValue):
            return .progressReportUpdated(ProgressState(kind: .paused, percent: progressPercent(progress)))
        default:
            return payloadMismatch(
                actionTag: actionTag,
                payload: payload,
                expectedPayload: "known progress report state"
            )
        }
    }

    static func closeTabMode(from rawValue: UInt32) -> GhosttyCloseTabMode? {
        switch rawValue {
        case GHOSTTY_ACTION_CLOSE_TAB_MODE_THIS.rawValue:
            return .thisTab
        case GHOSTTY_ACTION_CLOSE_TAB_MODE_OTHER.rawValue:
            return .otherTabs
        case GHOSTTY_ACTION_CLOSE_TAB_MODE_RIGHT.rawValue:
            return .rightTabs
        default:
            return nil
        }
    }

    static func gotoTabTarget(from rawValue: Int32) -> GhosttyGotoTabTarget? {
        switch rawValue {
        case GHOSTTY_GOTO_TAB_PREVIOUS.rawValue:
            return .previous
        case GHOSTTY_GOTO_TAB_NEXT.rawValue:
            return .next
        case GHOSTTY_GOTO_TAB_LAST.rawValue:
            return .last
        default:
            guard rawValue >= 1 else { return nil }
            return .index(Int(rawValue))
        }
    }

    static func splitDirection(from rawValue: UInt32) -> GhosttySplitDirection? {
        switch rawValue {
        case GHOSTTY_SPLIT_DIRECTION_LEFT.rawValue:
            return .left
        case GHOSTTY_SPLIT_DIRECTION_RIGHT.rawValue:
            return .right
        case GHOSTTY_SPLIT_DIRECTION_UP.rawValue:
            return .up
        case GHOSTTY_SPLIT_DIRECTION_DOWN.rawValue:
            return .down
        default:
            return nil
        }
    }

    static func gotoSplitDirection(from rawValue: UInt32) -> GhosttyGotoSplitDirection? {
        switch rawValue {
        case GHOSTTY_GOTO_SPLIT_PREVIOUS.rawValue:
            return .previous
        case GHOSTTY_GOTO_SPLIT_NEXT.rawValue:
            return .next
        case GHOSTTY_GOTO_SPLIT_LEFT.rawValue:
            return .left
        case GHOSTTY_GOTO_SPLIT_RIGHT.rawValue:
            return .right
        case GHOSTTY_GOTO_SPLIT_UP.rawValue:
            return .up
        case GHOSTTY_GOTO_SPLIT_DOWN.rawValue:
            return .down
        default:
            return nil
        }
    }

    static func resizeSplitDirection(from rawValue: UInt32) -> GhosttyResizeSplitDirection? {
        switch rawValue {
        case GHOSTTY_RESIZE_SPLIT_LEFT.rawValue:
            return .left
        case GHOSTTY_RESIZE_SPLIT_RIGHT.rawValue:
            return .right
        case GHOSTTY_RESIZE_SPLIT_UP.rawValue:
            return .up
        case GHOSTTY_RESIZE_SPLIT_DOWN.rawValue:
            return .down
        default:
            return nil
        }
    }

    static func progressPercent(_ rawProgress: Int8) -> UInt8? {
        rawProgress >= 0 ? UInt8(rawProgress) : nil
    }
}
