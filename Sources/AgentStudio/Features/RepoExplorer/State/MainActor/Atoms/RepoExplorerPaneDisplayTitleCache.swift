import AgentStudioCore
import Foundation

/// Memoizes `PaneContextPresentationRules.displayTitle`'s normalized sidebar row title per pane.
///
/// F6: the projection capture path (`paneRowFactsByPaneId`) previously re-derived every pane's
/// title against its CWD URL and shell executable path on every capture, repeating on the
/// sidebar's periodic projection cadence even when neither input had changed. This cache holds
/// the normalized result keyed by pane id and only re-derives when `liveTitle`, `cwd`, or
/// `shellExecutablePath` actually differ from the last resolve for that pane, so capture becomes
/// a plain keyed read on the common (unchanged) path.
///
/// Owned per `RepoExplorerView` identity via `@State`, matching the existing
/// `projectionAdapter` pattern in that file for state that must persist across the view struct's
/// repeated re-initialization but does not belong in a cross-feature Core atom.
@MainActor
final class RepoExplorerPaneDisplayTitleCache {
    private struct Entry: Equatable {
        let liveTitle: String
        let cwd: URL?
        let shellExecutablePath: String?
        let normalizedTitle: String
    }

    private var entriesByPaneId: [UUID: Entry] = [:]
    private let normalize: @MainActor @Sendable (String, URL?, String?) -> String

    init(
        normalize: @escaping @MainActor @Sendable (String, URL?, String?) -> String = { title, cwd, shell in
            PaneContextPresentationRules.displayTitle(raw: title, cwd: cwd, shell: shell)
        }
    ) {
        self.normalize = normalize
    }

    /// Returns the normalized title for `paneId`, re-deriving only when the inputs differ from
    /// this pane's last resolve.
    func resolve(paneId: UUID, liveTitle: String, cwd: URL?, shellExecutablePath: String?) -> String {
        if let existing = entriesByPaneId[paneId],
            existing.liveTitle == liveTitle,
            existing.cwd == cwd,
            existing.shellExecutablePath == shellExecutablePath
        {
            return existing.normalizedTitle
        }
        let normalizedTitle = normalize(liveTitle, cwd, shellExecutablePath)
        entriesByPaneId[paneId] = Entry(
            liveTitle: liveTitle,
            cwd: cwd,
            shellExecutablePath: shellExecutablePath,
            normalizedTitle: normalizedTitle
        )
        return normalizedTitle
    }

    /// Drops entries for panes no longer present, so a closed pane's entry does not persist for
    /// the remaining lifetime of this cache.
    func retainOnly(paneIds: Set<UUID>) {
        entriesByPaneId = entriesByPaneId.filter { paneIds.contains($0.key) }
    }
}
