import AgentStudioCore
import AgentStudioRepoExplorer
import AgentStudioSharedComponents
import Foundation

enum ToolbarProjection {
    nonisolated static func project(display: PaneContextDisplay?, isDrawer: Bool, now: Date)
        -> (item: ToolbarItemModel, nextChange: Date?)
    {
        let counts = (isDrawer ? display?.own : display?.includingDrawers)?.kinds ?? .zero
        switch PaneContextPresentationRules.toolbarSelection(counts: counts, agentLine: display?.agentLine, now: now) {
        case .none: return (.none, nil)
        case .chips(let chips): return (.chips(chips.map(PaneMessageKindChipProjection.model)), nil)
        case .agentLine(let text, let age):
            return (.agentLine(text: text, bracketedAge: "[\(age.text)]"), age.nextChange)
        }
    }
}
