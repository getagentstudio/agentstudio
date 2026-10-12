import AgentStudioCore
import AgentStudioInfrastructure
import AppKit
import Foundation
import GhosttyKit
import os.log

extension GhosttyActionTranslation {
    static func translateMouseShape(payload: GhosttyActionPayload, actionTag: GhosttyActionTag) -> GhosttyEvent {
        guard case .mouseShape(let rawValue) = payload else {
            return payloadMismatch(
                actionTag: actionTag,
                payload: payload,
                expectedPayload: ".mouseShape(rawValue: UInt32)"
            )
        }
        let mouseShape: TerminalMouseShape
        switch rawValue {
        case UInt32(GHOSTTY_MOUSE_SHAPE_TEXT.rawValue):
            mouseShape = .text
        case UInt32(GHOSTTY_MOUSE_SHAPE_POINTER.rawValue):
            mouseShape = .pointer
        case UInt32(GHOSTTY_MOUSE_SHAPE_CROSSHAIR.rawValue):
            mouseShape = .crosshair
        case UInt32(GHOSTTY_MOUSE_SHAPE_VERTICAL_TEXT.rawValue):
            mouseShape = .verticalText
        default:
            mouseShape = .other(rawValue: rawValue)
        }
        return .mouseShapeChanged(shape: mouseShape)
    }

    static func translateMouseVisibility(payload: GhosttyActionPayload, actionTag: GhosttyActionTag) -> GhosttyEvent {
        guard case .mouseVisibility(let rawValue) = payload else {
            return payloadMismatch(
                actionTag: actionTag,
                payload: payload,
                expectedPayload: ".mouseVisibility(rawValue: UInt32)"
            )
        }

        switch rawValue {
        case UInt32(truncatingIfNeeded: GHOSTTY_MOUSE_VISIBLE.rawValue):
            return .mouseVisibilityChanged(isVisible: true)
        case UInt32(truncatingIfNeeded: GHOSTTY_MOUSE_HIDDEN.rawValue):
            return .mouseVisibilityChanged(isVisible: false)
        default:
            return payloadMismatch(
                actionTag: actionTag,
                payload: payload,
                expectedPayload: "known mouse visibility value"
            )
        }
    }

    static func translateMouseOverLink(payload: GhosttyActionPayload, actionTag: GhosttyActionTag) -> GhosttyEvent {
        guard case .mouseOverLink(let url) = payload else {
            return payloadMismatch(
                actionTag: actionTag,
                payload: payload,
                expectedPayload: ".mouseOverLink(String?)"
            )
        }
        return .mouseLinkHovered(url: url)
    }

    static func translateKeySequence(payload: GhosttyActionPayload, actionTag: GhosttyActionTag) -> GhosttyEvent {
        guard case .keySequence(let active, let triggerTag, let key, let mods) = payload else {
            return payloadMismatch(
                actionTag: actionTag,
                payload: payload,
                expectedPayload: ".keySequence(active: Bool, triggerTag: UInt32, key: UInt32?, mods: UInt32)"
            )
        }

        let trigger: GhosttyInputTrigger? =
            switch triggerTag {
            case UInt32(truncatingIfNeeded: GHOSTTY_TRIGGER_PHYSICAL.rawValue):
                .init(tag: .physical, key: key, modifiers: mods)
            case UInt32(truncatingIfNeeded: GHOSTTY_TRIGGER_UNICODE.rawValue):
                .init(tag: .unicode, key: key, modifiers: mods)
            case UInt32(truncatingIfNeeded: GHOSTTY_TRIGGER_CATCH_ALL.rawValue):
                .init(tag: .catchAll, key: nil, modifiers: mods)
            default:
                nil
            }

        if active, trigger == nil {
            return payloadMismatch(
                actionTag: actionTag,
                payload: payload,
                expectedPayload: "known triggerTag value"
            )
        }

        return .keySequenceChanged(active: active, trigger: trigger)
    }

    static func translateKeyTable(payload: GhosttyActionPayload, actionTag: GhosttyActionTag) -> GhosttyEvent {
        guard case .keyTable(let tagRawValue, let activateName) = payload else {
            return payloadMismatch(
                actionTag: actionTag,
                payload: payload,
                expectedPayload: ".keyTable(tagRawValue: UInt32, activateName: String?)"
            )
        }

        let change: GhosttyKeyTableChange
        switch tagRawValue {
        case UInt32(truncatingIfNeeded: GHOSTTY_KEY_TABLE_ACTIVATE.rawValue):
            guard let activateName else {
                return payloadMismatch(
                    actionTag: actionTag,
                    payload: payload,
                    expectedPayload: "UTF-8 decodable activate key table name"
                )
            }
            change = .activate(name: activateName)
        case UInt32(truncatingIfNeeded: GHOSTTY_KEY_TABLE_DEACTIVATE.rawValue):
            change = .deactivate
        case UInt32(truncatingIfNeeded: GHOSTTY_KEY_TABLE_DEACTIVATE_ALL.rawValue):
            change = .deactivateAll
        default:
            return payloadMismatch(
                actionTag: actionTag,
                payload: payload,
                expectedPayload: "known key table action"
            )
        }

        return .keyTableChanged(change)
    }

    static func translateColorChange(payload: GhosttyActionPayload, actionTag: GhosttyActionTag) -> GhosttyEvent {
        guard case .colorChange(let kindRawValue, let red, let green, let blue) = payload else {
            return payloadMismatch(
                actionTag: actionTag,
                payload: payload,
                expectedPayload: ".colorChange(kindRawValue: Int32, red: UInt8, green: UInt8, blue: UInt8)"
            )
        }

        let kind: TerminalColorKind
        switch kindRawValue {
        case Int32(GHOSTTY_ACTION_COLOR_KIND_FOREGROUND.rawValue):
            kind = .foreground
        case Int32(GHOSTTY_ACTION_COLOR_KIND_BACKGROUND.rawValue):
            kind = .background
        case Int32(GHOSTTY_ACTION_COLOR_KIND_CURSOR.rawValue):
            kind = .cursor
        case 0...255:
            kind = .palette(index: UInt8(kindRawValue))
        default:
            return payloadMismatch(
                actionTag: actionTag,
                payload: payload,
                expectedPayload: "known color kind or 0...255 palette index"
            )
        }

        return .colorChanged(
            TerminalColorChange(
                kind: kind,
                red: red,
                green: green,
                blue: blue
            )
        )
    }

    static func translateReloadConfig(payload: GhosttyActionPayload, actionTag: GhosttyActionTag) -> GhosttyEvent {
        guard case .reloadConfig(let soft) = payload else {
            return payloadMismatch(
                actionTag: actionTag,
                payload: payload,
                expectedPayload: ".reloadConfig(soft: Bool)"
            )
        }

        return .configReloadRequested(soft: soft)
    }

    static func translateConfigChange(payload: GhosttyActionPayload, actionTag: GhosttyActionTag) -> GhosttyEvent {
        guard case .configChange = payload else {
            return payloadMismatch(
                actionTag: actionTag,
                payload: payload,
                expectedPayload: ".configChange"
            )
        }

        return .configChanged
    }

    static func translateStartSearch(payload: GhosttyActionPayload, actionTag: GhosttyActionTag) -> GhosttyEvent {
        guard case .startSearch(let query) = payload else {
            return payloadMismatch(
                actionTag: actionTag,
                payload: payload,
                expectedPayload: ".startSearch(String?)"
            )
        }

        return .searchStarted(query: query)
    }

    static func translateEndSearch(payload: GhosttyActionPayload, actionTag: GhosttyActionTag) -> GhosttyEvent {
        guard case .endSearch = payload else {
            return payloadMismatch(
                actionTag: actionTag,
                payload: payload,
                expectedPayload: ".endSearch"
            )
        }

        return .searchEnded
    }

    static func translateSearchTotal(payload: GhosttyActionPayload, actionTag: GhosttyActionTag) -> GhosttyEvent {
        guard case .searchTotal(let total) = payload else {
            return payloadMismatch(
                actionTag: actionTag,
                payload: payload,
                expectedPayload: ".searchTotal(Int)"
            )
        }

        return .searchMatchesUpdated(totalMatches: total >= 0 ? total : nil)
    }

    static func translateSearchSelected(payload: GhosttyActionPayload, actionTag: GhosttyActionTag) -> GhosttyEvent {
        guard case .searchSelected(let selected) = payload else {
            return payloadMismatch(
                actionTag: actionTag,
                payload: payload,
                expectedPayload: ".searchSelected(Int)"
            )
        }

        return .searchSelectionChanged(selectedMatchIndex: selected >= 0 ? selected : nil)
    }

    static func translateScrollbar(payload: GhosttyActionPayload, actionTag: GhosttyActionTag) -> GhosttyEvent {
        guard case .scrollbar(let total, let offset, let length) = payload else {
            return payloadMismatch(
                actionTag: actionTag,
                payload: payload,
                expectedPayload: ".scrollbar(total: UInt64, offset: UInt64, length: UInt64)"
            )
        }

        return .scrollbarChanged(ScrollbarState(top: Int(offset), bottom: Int(offset + length), total: Int(total)))
    }

    static func translateReadOnly(payload: GhosttyActionPayload, actionTag: GhosttyActionTag) -> GhosttyEvent {
        guard case .readOnly(let modeRawValue) = payload else {
            return payloadMismatch(
                actionTag: actionTag,
                payload: payload,
                expectedPayload: ".readOnly(modeRawValue: UInt32)"
            )
        }

        switch modeRawValue {
        case UInt32(truncatingIfNeeded: GHOSTTY_READONLY_OFF.rawValue):
            return .readOnlyChanged(false)
        case UInt32(truncatingIfNeeded: GHOSTTY_READONLY_ON.rawValue):
            return .readOnlyChanged(true)
        default:
            return payloadMismatch(
                actionTag: actionTag,
                payload: payload,
                expectedPayload: "known readonly mode"
            )
        }
    }

    static func translateSecureInput(payload: GhosttyActionPayload, actionTag: GhosttyActionTag) -> GhosttyEvent {
        guard case .secureInput(let modeRawValue) = payload else {
            return payloadMismatch(
                actionTag: actionTag,
                payload: payload,
                expectedPayload: ".secureInput(modeRawValue: UInt32)"
            )
        }

        switch modeRawValue {
        case UInt32(truncatingIfNeeded: GHOSTTY_SECURE_INPUT_ON.rawValue):
            return .secureInputRequested(.on)
        case UInt32(truncatingIfNeeded: GHOSTTY_SECURE_INPUT_OFF.rawValue):
            return .secureInputRequested(.off)
        case UInt32(truncatingIfNeeded: GHOSTTY_SECURE_INPUT_TOGGLE.rawValue):
            return .secureInputRequested(.toggle)
        default:
            return payloadMismatch(
                actionTag: actionTag,
                payload: payload,
                expectedPayload: "known secure input mode"
            )
        }
    }

    static func translateRendererHealth(payload: GhosttyActionPayload, actionTag: GhosttyActionTag) -> GhosttyEvent {
        guard case .rendererHealth(let rawValue) = payload else {
            return payloadMismatch(
                actionTag: actionTag,
                payload: payload,
                expectedPayload: ".rendererHealth(rawValue: UInt32)"
            )
        }

        switch rawValue {
        case UInt32(truncatingIfNeeded: GHOSTTY_RENDERER_HEALTH_HEALTHY.rawValue):
            return .rendererHealthChanged(healthy: true)
        case UInt32(truncatingIfNeeded: GHOSTTY_RENDERER_HEALTH_UNHEALTHY.rawValue):
            return .rendererHealthChanged(healthy: false)
        default:
            return payloadMismatch(
                actionTag: actionTag,
                payload: payload,
                expectedPayload: "known renderer health value"
            )
        }
    }

    static func translateCellSize(payload: GhosttyActionPayload, actionTag: GhosttyActionTag) -> GhosttyEvent {
        guard case .cellSizeChanged(let width, let height) = payload else {
            return payloadMismatch(
                actionTag: actionTag,
                payload: payload,
                expectedPayload: ".cellSizeChanged(width: UInt32, height: UInt32)"
            )
        }

        return .cellSizeChanged(
            NSSize(width: Double(width), height: Double(height))
        )
    }

    static func translateInitialSize(payload: GhosttyActionPayload, actionTag: GhosttyActionTag) -> GhosttyEvent {
        guard case .initialSizeChanged(let width, let height) = payload else {
            return payloadMismatch(
                actionTag: actionTag,
                payload: payload,
                expectedPayload: ".initialSizeChanged(width: UInt32, height: UInt32)"
            )
        }

        return .initialSizeChanged(
            NSSize(width: Double(width), height: Double(height))
        )
    }

    static func translateSizeLimit(payload: GhosttyActionPayload, actionTag: GhosttyActionTag) -> GhosttyEvent {
        guard case .sizeLimitChanged(let minWidth, let minHeight, let maxWidth, let maxHeight) = payload else {
            return payloadMismatch(
                actionTag: actionTag,
                payload: payload,
                expectedPayload:
                    ".sizeLimitChanged(minWidth: UInt32, minHeight: UInt32, maxWidth: UInt32, maxHeight: UInt32)"
            )
        }

        return .sizeLimitChanged(
            TerminalSizeConstraints(
                minWidth: minWidth,
                minHeight: minHeight,
                maxWidth: maxWidth,
                maxHeight: maxHeight
            )
        )
    }

    static func translatePromptTitle(payload: GhosttyActionPayload, actionTag: GhosttyActionTag) -> GhosttyEvent {
        guard case .promptTitle(let scopeRawValue) = payload else {
            return payloadMismatch(
                actionTag: actionTag,
                payload: payload,
                expectedPayload: ".promptTitle(scopeRawValue: UInt32)"
            )
        }

        switch scopeRawValue {
        case UInt32(truncatingIfNeeded: GHOSTTY_PROMPT_TITLE_SURFACE.rawValue):
            return .promptTitleRequested(scope: .surface)
        case UInt32(truncatingIfNeeded: GHOSTTY_PROMPT_TITLE_TAB.rawValue):
            return .promptTitleRequested(scope: .tab)
        default:
            return payloadMismatch(
                actionTag: actionTag,
                payload: payload,
                expectedPayload: "known prompt title scope"
            )
        }
    }

    static func translateDesktopNotification(payload: GhosttyActionPayload, actionTag: GhosttyActionTag) -> GhosttyEvent
    {
        guard case .desktopNotification(let title, let body) = payload else {
            return payloadMismatch(
                actionTag: actionTag,
                payload: payload,
                expectedPayload: ".desktopNotification(title: String, body: String)"
            )
        }

        return .desktopNotificationRequested(title: title, body: body)
    }

    static func translateOpenURL(payload: GhosttyActionPayload, actionTag: GhosttyActionTag) -> GhosttyEvent {
        guard case .openURL(let url, let kindRawValue) = payload else {
            return payloadMismatch(
                actionTag: actionTag,
                payload: payload,
                expectedPayload: ".openURL(url: String, kindRawValue: UInt32)"
            )
        }

        let kind: OpenURLKind =
            switch kindRawValue {
            case UInt32(truncatingIfNeeded: GHOSTTY_ACTION_OPEN_URL_KIND_TEXT.rawValue):
                .text
            case UInt32(truncatingIfNeeded: GHOSTTY_ACTION_OPEN_URL_KIND_HTML.rawValue):
                .html
            case UInt32(truncatingIfNeeded: GHOSTTY_ACTION_OPEN_URL_KIND_OSC8.rawValue):
                .osc8
            default:
                .unknown
            }

        return .openURLRequested(url: url, kind: kind)
    }
}
