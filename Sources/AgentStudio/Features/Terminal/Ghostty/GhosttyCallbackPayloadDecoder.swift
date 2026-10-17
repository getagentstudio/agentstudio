import Foundation
import GhosttyKit

enum GhosttyCallbackPayloadDecodeResult: Sendable {
    case payload(GhosttyActionPayload, handled: Bool)
    case directHost(GhosttyDirectHostUpdate, handled: Bool)
    case intercepted(GhosttyActionTag)
    case rejected
}

enum GhosttyCallbackPayloadDecoder {
    static func decode(_ action: ghostty_action_s) -> GhosttyCallbackPayloadDecodeResult {
        let rawActionTag = UInt32(truncatingIfNeeded: action.tag.rawValue)
        guard let actionTag = GhosttyActionTag(rawValue: rawActionTag) else {
            return .rejected
        }
        if Ghostty.ActionRouter.interceptedTags.contains(actionTag) {
            return .intercepted(actionTag)
        }
        if Ghostty.ActionRouter.unsupportedTags.contains(actionTag) {
            return .rejected
        }

        if let decoded = decodeWorkspacePayload(actionTag, action: action) { return decoded }
        if let decoded = decodeObservedPayload(actionTag, action: action) { return decoded }
        if let decoded = decodeLifecyclePayload(actionTag, action: action) { return decoded }
        preconditionFailure("Ghostty action tag \(actionTag) has no callback payload decoder")
    }

    private static func decodeWorkspacePayload(
        _ actionTag: GhosttyActionTag, action: ghostty_action_s
    ) -> GhosttyCallbackPayloadDecodeResult? {
        switch actionTag {
        case .newTab, .ringBell:
            return .payload(.noPayload, handled: true)
        case .setTitle:
            guard let titlePointer = action.action.set_title.title else { return .rejected }
            return .payload(.titleChanged(String(cString: titlePointer)), handled: true)
        case .setTabTitle:
            guard let titlePointer = action.action.set_tab_title.title else { return .rejected }
            return .payload(.tabTitleChanged(String(cString: titlePointer)), handled: false)
        case .pwd:
            guard let pwdPointer = action.action.pwd.pwd else {
                return .directHost(.workingDirectory(nil), handled: false)
            }
            return .payload(.cwdChanged(String(cString: pwdPointer)), handled: true)
        case .newSplit:
            return .payload(
                .newSplit(directionRawValue: action.action.new_split.rawValue),
                handled: true
            )
        case .gotoSplit:
            return .payload(
                .gotoSplit(directionRawValue: action.action.goto_split.rawValue),
                handled: true
            )
        case .resizeSplit:
            return .payload(
                .resizeSplit(
                    amount: action.action.resize_split.amount,
                    directionRawValue: action.action.resize_split.direction.rawValue
                ),
                handled: true
            )
        case .equalizeSplits, .toggleSplitZoom:
            return .payload(.noPayload, handled: true)
        case .closeTab:
            return .payload(.closeTab(modeRawValue: action.action.close_tab_mode.rawValue), handled: true)
        case .gotoTab:
            return .payload(.gotoTab(targetRawValue: action.action.goto_tab.rawValue), handled: true)
        case .moveTab:
            return .payload(.moveTab(amount: Int(action.action.move_tab.amount)), handled: true)
        case .sizeLimit:
            return .payload(
                .sizeLimitChanged(
                    minWidth: action.action.size_limit.min_width,
                    minHeight: action.action.size_limit.min_height,
                    maxWidth: action.action.size_limit.max_width,
                    maxHeight: action.action.size_limit.max_height
                ),
                handled: false
            )
        case .initialSize:
            return .payload(
                .initialSizeChanged(
                    width: action.action.initial_size.width,
                    height: action.action.initial_size.height
                ),
                handled: false
            )
        case .cellSize:
            return .payload(
                .cellSizeChanged(
                    width: action.action.cell_size.width,
                    height: action.action.cell_size.height
                ),
                handled: false
            )
        default: return nil
        }
    }

    private static func decodeObservedPayload(
        _ actionTag: GhosttyActionTag, action: ghostty_action_s
    ) -> GhosttyCallbackPayloadDecodeResult? {
        switch actionTag {
        case .desktopNotification:
            guard
                let titlePointer = action.action.desktop_notification.title,
                let bodyPointer = action.action.desktop_notification.body
            else {
                return .rejected
            }
            return .payload(
                .desktopNotification(
                    title: String(cString: titlePointer),
                    body: String(cString: bodyPointer)
                ),
                handled: false
            )
        case .promptTitle:
            return .payload(
                .promptTitle(scopeRawValue: UInt32(truncatingIfNeeded: action.action.prompt_title.rawValue)),
                handled: false
            )
        case .mouseShape:
            return .payload(
                .mouseShape(rawValue: UInt32(truncatingIfNeeded: action.action.mouse_shape.rawValue)),
                handled: false
            )
        case .mouseVisibility:
            return .payload(
                .mouseVisibility(rawValue: UInt32(truncatingIfNeeded: action.action.mouse_visibility.rawValue)),
                handled: false
            )
        case .mouseOverLink:
            let url: String?
            if let urlPointer = action.action.mouse_over_link.url, action.action.mouse_over_link.len > 0 {
                let data = Data(bytes: urlPointer, count: Int(action.action.mouse_over_link.len))
                guard let decodedURL = String(data: data, encoding: .utf8) else { return .rejected }
                url = decodedURL
            } else {
                url = nil
            }
            return .payload(.mouseOverLink(url), handled: false)
        case .rendererHealth:
            return .payload(
                .rendererHealth(rawValue: UInt32(truncatingIfNeeded: action.action.renderer_health.rawValue)),
                handled: false
            )
        case .secureInput:
            return .payload(
                .secureInput(modeRawValue: UInt32(truncatingIfNeeded: action.action.secure_input.rawValue)),
                handled: false
            )
        case .keySequence:
            let trigger = action.action.key_sequence.trigger
            return .payload(
                .keySequence(
                    active: action.action.key_sequence.active,
                    triggerTag: UInt32(truncatingIfNeeded: trigger.tag.rawValue),
                    key: keyValue(for: trigger),
                    mods: trigger.mods.rawValue
                ),
                handled: false
            )
        case .keyTable:
            return .payload(
                .keyTable(
                    tagRawValue: UInt32(truncatingIfNeeded: action.action.key_table.tag.rawValue),
                    activateName: keyTableActivateName(from: action.action.key_table)
                ),
                handled: false
            )
        case .colorChange:
            return .payload(
                .colorChange(
                    kindRawValue: action.action.color_change.kind.rawValue,
                    red: action.action.color_change.r,
                    green: action.action.color_change.g,
                    blue: action.action.color_change.b
                ),
                handled: false
            )
        default: return nil
        }
    }

    private static func decodeLifecyclePayload(
        _ actionTag: GhosttyActionTag, action: ghostty_action_s
    ) -> GhosttyCallbackPayloadDecodeResult? {
        switch actionTag {
        case .reloadConfig:
            return .payload(.reloadConfig(soft: action.action.reload_config.soft), handled: false)
        case .configChange:
            return .payload(.configChange, handled: false)
        case .startSearch:
            return .payload(.startSearch(action.action.start_search.needle.map { String(cString: $0) }), handled: false)
        case .endSearch:
            return .payload(.endSearch, handled: false)
        case .searchTotal:
            return .payload(.searchTotal(Int(action.action.search_total.total)), handled: false)
        case .searchSelected:
            return .payload(.searchSelected(Int(action.action.search_selected.selected)), handled: false)
        case .openURL:
            guard let urlPointer = action.action.open_url.url else { return .rejected }
            let urlData = Data(bytes: urlPointer, count: Int(action.action.open_url.len))
            guard let url = String(data: urlData, encoding: .utf8) else { return .rejected }
            return .payload(
                .openURL(
                    url: url,
                    kindRawValue: UInt32(truncatingIfNeeded: action.action.open_url.kind.rawValue)
                ),
                handled: true
            )
        case .progressReport:
            return .payload(
                .progressReport(
                    stateRawValue: UInt32(truncatingIfNeeded: action.action.progress_report.state.rawValue),
                    progress: action.action.progress_report.progress
                ),
                handled: false
            )
        case .scrollbar:
            return .payload(
                .scrollbar(
                    total: action.action.scrollbar.total,
                    offset: action.action.scrollbar.offset,
                    length: action.action.scrollbar.len
                ),
                handled: false
            )
        case .readOnly:
            return .payload(
                .readOnly(modeRawValue: UInt32(truncatingIfNeeded: action.action.readonly.rawValue)),
                handled: false
            )
        case .copyTitleToClipboard, .undo, .redo:
            return .payload(.noPayload, handled: false)
        case .commandFinished:
            let sourceInstant = ContinuousClock.now
            return .payload(
                .commandFinished(
                    exitCode: Int(action.action.command_finished.exit_code),
                    duration: action.action.command_finished.duration,
                    sourceInstant: sourceInstant
                ),
                handled: true
            )
        default: return nil
        }
    }

    private static func keyTableActivateName(from keyTable: ghostty_action_key_table_s) -> String? {
        guard keyTable.tag == GHOSTTY_KEY_TABLE_ACTIVATE,
            let namePointer = keyTable.value.activate.name
        else {
            return nil
        }

        let data = Data(bytes: namePointer, count: Int(keyTable.value.activate.len))
        return String(data: data, encoding: .utf8)
    }

    private static func keyValue(for trigger: ghostty_input_trigger_s) -> UInt32? {
        switch trigger.tag {
        case GHOSTTY_TRIGGER_PHYSICAL:
            return UInt32(truncatingIfNeeded: trigger.key.physical.rawValue)
        case GHOSTTY_TRIGGER_UNICODE:
            return trigger.key.unicode
        case GHOSTTY_TRIGGER_CATCH_ALL:
            return nil
        default:
            return nil
        }
    }
}
