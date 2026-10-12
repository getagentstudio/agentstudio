import Foundation

/// Copied values decoded synchronously at the native callback boundary.
package enum GhosttyActionPayload: Sendable, Equatable {
    case noPayload
    case titleChanged(String)
    case cwdChanged(String)
    case commandFinished(exitCode: Int, duration: UInt64, sourceInstant: ContinuousClock.Instant)
    case tabTitleChanged(String)
    case closeTab(modeRawValue: UInt32)
    case gotoTab(targetRawValue: Int32)
    case moveTab(amount: Int)
    case newSplit(directionRawValue: UInt32)
    case gotoSplit(directionRawValue: UInt32)
    case resizeSplit(amount: UInt16, directionRawValue: UInt32)
    case progressReport(stateRawValue: UInt32, progress: Int8)
    case readOnly(modeRawValue: UInt32)
    case secureInput(modeRawValue: UInt32)
    case rendererHealth(rawValue: UInt32)
    case cellSizeChanged(width: UInt32, height: UInt32)
    case initialSizeChanged(width: UInt32, height: UInt32)
    case sizeLimitChanged(minWidth: UInt32, minHeight: UInt32, maxWidth: UInt32, maxHeight: UInt32)
    case mouseShape(rawValue: UInt32)
    case mouseVisibility(rawValue: UInt32)
    case mouseOverLink(String?)
    case keySequence(active: Bool, triggerTag: UInt32, key: UInt32?, mods: UInt32)
    case keyTable(tagRawValue: UInt32, activateName: String?)
    case colorChange(kindRawValue: Int32, red: UInt8, green: UInt8, blue: UInt8)
    case reloadConfig(soft: Bool)
    case configChange
    case startSearch(String?)
    case endSearch
    case searchTotal(Int)
    case searchSelected(Int)
    case scrollbar(total: UInt64, offset: UInt64, length: UInt64)
    case promptTitle(scopeRawValue: UInt32)
    case desktopNotification(title: String, body: String)
    case openURL(url: String, kindRawValue: UInt32)
}
