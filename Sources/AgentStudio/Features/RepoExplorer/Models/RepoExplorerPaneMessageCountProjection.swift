import AgentStudioCore
import AgentStudioSharedComponents

/// Render arithmetic on already-derived counts, called by the existing worker.
package enum RepoExplorerPaneMessageCountProjection {
    package static func make(display: PaneContextDisplay, isDrawer: Bool) -> PaneMessageChipModel {
        make(isDrawer ? display.own : display.includingDrawers)
    }
    package static func make(_ counts: PaneMessageCounts) -> PaneMessageChipModel {
        let kinds = counts.kinds
        let count = kinds.failure + kinds.needsYou
        let tone: PaneContextChipTone = kinds.failure > 0 ? .danger : count > 0 ? .warning : .neutral
        return PaneMessageChipModel(
            count: count, tone: tone, countIncludingInformational: kinds.unread,
            toneIncludingInformational: count > 0 ? tone : kinds.done > 0 ? .success : kinds.info > 0 ? .info : .neutral
        )
    }
    package static func totalOwn(_ displays: [PaneContextDisplay], includingInformational: Bool = false) -> Int {
        displays.reduce(0) { total, display in
            let model = make(display.own)
            return total + (includingInformational ? model.countIncludingInformational : model.count)
        }
    }
}
