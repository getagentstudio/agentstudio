import AgentStudioInfrastructure
import Foundation
import SwiftUI

package struct PullRequestRowModel: Sendable, Equatable, Identifiable {
    package let id: PullRequestIdentityModel
    package let reference: String
    package let title: String
    package let repository: String?
    package let status: String
    package let sources: String
    package let failure: String?
    package let canRemove: Bool

    package init(
        id: PullRequestIdentityModel, reference: String, title: String, repository: String?,
        status: String, sources: String, failure: String?, canRemove: Bool
    ) {
        self.id = id
        self.reference = reference
        self.title = title
        self.repository = repository
        self.status = status
        self.sources = sources
        self.failure = failure
        self.canRemove = canRemove
    }
}

package struct PullRequestsPopoverModel: Sendable, Equatable {
    package let rows: [PullRequestRowModel]
    package let keyboardItems: [SelectablePopoverKeyboardItem<PullRequestIdentityModel>]
    package init(rows: [PullRequestRowModel], keyboardItems: [SelectablePopoverKeyboardItem<PullRequestIdentityModel>])
    {
        self.rows = rows
        self.keyboardItems = keyboardItems
    }
}

/// Prepared values use the shared panel, compound rows and keyboard route.
package struct PullRequestsPopover: View {
    private let title: String
    private let model: PullRequestsPopoverModel
    private let openControl: PaneContextControlModel
    private let removeControl: PaneContextControlModel
    private let octiconLoader: OcticonLoader
    private let height: PopoverPanelHeight
    private let width: Double
    private let feedback: String?
    private let onOpen: @MainActor (PullRequestIdentityModel) -> Void
    private let onRemove: @MainActor (PullRequestIdentityModel) -> Void
    private let onClose: @MainActor () -> Void
    @State private var highlighted: PullRequestIdentityModel?

    package init(
        title: String, model: PullRequestsPopoverModel, openControl: PaneContextControlModel,
        removeControl: PaneContextControlModel, octiconLoader: OcticonLoader,
        height: PopoverPanelHeight, width: Double, feedback: String? = nil,
        onOpen: @escaping @MainActor (PullRequestIdentityModel) -> Void,
        onRemove: @escaping @MainActor (PullRequestIdentityModel) -> Void,
        onClose: @escaping @MainActor () -> Void
    ) {
        self.title = title
        self.model = model
        self.openControl = openControl
        self.removeControl = removeControl
        self.octiconLoader = octiconLoader
        self.height = height
        self.width = width
        self.feedback = feedback
        self.onOpen = onOpen
        self.onRemove = onRemove
        self.onClose = onClose
    }

    package var body: some View {
        PopoverPanel(
            width: width, height: height, identifier: "pane-context.pull-requests",
            header: {
                Text(title).font(.headline)
            },
            content: {
                if let feedback { PaneContextPopoverNote(feedback) }
                ForEach(model.rows) { row in
                    HStack(alignment: .top, spacing: AppStyles.General.Spacing.tight) {
                        Button {
                            onOpen(row.id)
                        } label: {
                            VStack(alignment: .leading, spacing: AppStyles.General.Spacing.tight) {
                                Text(row.reference + "  " + row.title).font(.headline).lineLimit(2)
                                if let repository = row.repository {
                                    Text(repository).font(.caption).foregroundStyle(.secondary)
                                }
                                Text(row.status).font(.caption)
                                Text(row.sources).font(.caption).foregroundStyle(.secondary)
                                if let failure = row.failure {
                                    Text(failure).font(.caption).foregroundStyle(.secondary)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .controlHelp(openControl.tooltip)
                        .accessibilityIdentifier(
                            "pane-context.pull-request.\(row.id.owner).\(row.id.repository).\(row.id.number)")
                        HStack(spacing: AppStyles.General.Spacing.tight) {
                            PaneContextActionButton(openControl, role: .rowDismiss(octiconLoader)) { onOpen(row.id) }
                            if row.canRemove {
                                PaneContextActionButton(removeControl, role: .rowDismiss(octiconLoader)) {
                                    onRemove(row.id)
                                }
                            }
                        }
                    }
                    .modifier(PopoverCompoundOptionSurface(isSelected: false, isHighlighted: highlighted == row.id))
                    .onHover { if $0 { highlighted = row.id } }
                }
            }
        )
        .background {
            SelectablePopoverKeyboardBridge(
                items: model.keyboardItems, selectedItemId: highlighted,
                auxiliaryAction: .init(trigger: .commandDelete, perform: onRemove),
                onSelect: onOpen, onHighlight: { highlighted = $0 }, onDismiss: onClose,
                matchesAdditionalDismissShortcut: { _ in false }
            )
            .frame(width: 0, height: 0)
        }
        .onAppear(perform: repairHighlight)
        .onChange(of: model.rows) { _, _ in repairHighlight() }
        .onExitCommand(perform: onClose)
    }

    private func repairHighlight() {
        highlighted = SelectablePopoverKeyboardRouter.defaultSelection(
            items: model.keyboardItems, preferredItemId: highlighted)
    }
}
