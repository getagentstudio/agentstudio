import SwiftUI

private struct PaneContextUIReadersKey: EnvironmentKey {
    static let defaultValue: PaneContextUIReaders? = nil
}
private struct PaneContextHostVisibleKey: EnvironmentKey {
    static let defaultValue = true
}
private struct PaneContextPopoverAutoOpenStateKey: EnvironmentKey {
    static let defaultValue: PaneContextPopoverAutoOpenState? = nil
}
extension EnvironmentValues {
    var paneContextUIReaders: PaneContextUIReaders? {
        get { self[PaneContextUIReadersKey.self] }
        set { self[PaneContextUIReadersKey.self] = newValue }
    }
    var paneContextHostVisible: Bool {
        get { self[PaneContextHostVisibleKey.self] }
        set { self[PaneContextHostVisibleKey.self] = newValue }
    }
    var paneContextPopoverAutoOpenState: PaneContextPopoverAutoOpenState? {
        get { self[PaneContextPopoverAutoOpenStateKey.self] }
        set { self[PaneContextPopoverAutoOpenStateKey.self] = newValue }
    }
}
