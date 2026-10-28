import AgentStudioCore
import AgentStudioSharedComponents

package enum RepoExplorerPaneKindChipProjection {
    package static func model(_ chip: KindCount) -> KindChipModel {
        let kind: KindChipModel.Kind =
            switch chip.kind {
            case .failure: .failure
            case .needsYou: .needsYou
            case .done: .done
            case .info: .info
            }
        return .init(kind: kind, count: chip.count)
    }

    package static func control(_ chip: KindChipModel) -> PaneContextControlModel {
        let kind: MessageKind =
            switch chip.kind {
            case .failure: .failure
            case .needsYou: .needsYou
            case .done: .done
            case .info: .info
            }
        let spec = LocalActionSpec.showPaneMessageKind(kind).actionSpec
        let icon: PaneContextControlModel.Icon =
            switch spec.icon {
            case .system(let symbol): .system(symbol.rawValue)
            case .octicon(let symbol): .octicon(symbol.rawValue)
            }
        return .init(
            identifier: "pane-context.messages.\(chip.kind)", label: spec.label, icon: icon,
            tooltip: spec.controlTooltipRenderValue(provenance: .localAction(rawValue: "showPaneMessages")))
    }
}
