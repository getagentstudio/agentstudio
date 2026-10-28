import Foundation

extension WorkspacePaneGraphAtom {
    /// Canonical metadata copied by demanded presentation captures.
    package func paneRawTitle(_ paneId: UUID) -> String? {
        paneState(paneId)?.metadata.title
    }

    package func paneRawNote(_ paneId: UUID) -> String? {
        paneState(paneId)?.metadata.note
    }
}
