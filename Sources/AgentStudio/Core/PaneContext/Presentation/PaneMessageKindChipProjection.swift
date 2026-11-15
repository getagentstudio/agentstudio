import AgentStudioSharedComponents

/// Shared model and spec projections for the sidebar, toolbar and Arrangements count readout.
package enum PaneMessageKindChipProjection {
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
        project(chip, spec: LocalActionSpec.showPaneMessageKind(messageKind(for: chip)).actionSpec)
    }

    package static func readout(_ chip: KindChipModel) -> PaneContextControlModel {
        project(
            chip,
            spec: LocalActionSpec.filterPaneMessageCount(kind: messageKind(for: chip), count: chip.count).actionSpec)
    }

    private static func messageKind(for chip: KindChipModel) -> MessageKind {
        switch chip.kind {
        case .failure: .failure
        case .needsYou: .needsYou
        case .done: .done
        case .info: .info
        }
    }

    private static func project(_ chip: KindChipModel, spec: ActionSpec) -> PaneContextControlModel {
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
