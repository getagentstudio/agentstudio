import SwiftUI

private struct PaneContextUIReadersKey: EnvironmentKey {
    static let defaultValue: PaneContextUIReaders? = nil
}
extension EnvironmentValues {
    var paneContextUIReaders: PaneContextUIReaders? {
        get { self[PaneContextUIReadersKey.self] }
        set { self[PaneContextUIReadersKey.self] = newValue }
    }
}
