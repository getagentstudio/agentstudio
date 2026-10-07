import AgentStudioInfrastructure
import AppKit
import Observation
import SwiftUI

struct RepoExplorerTableRowReuseToken: Hashable {
    let rawValue: UInt64
}

struct RepoExplorerTableRowBindingIdentity: Equatable {
    let visibleGeneration: UInt64
    let rowID: RepoExplorerRowID
    let reuseToken: RepoExplorerTableRowReuseToken
}

struct RepoExplorerTableRowBinding: Equatable {
    let identity: RepoExplorerTableRowBindingIdentity
    let row: RepoExplorerMaterializedRow
    let commandPresentationSnapshot: RepoExplorerCommandPresentationSnapshot
}

@MainActor
@Observable
final class RepoExplorerTableRowSlot {
    private(set) var binding: RepoExplorerTableRowBinding?
    private(set) var keyboardPresentation = RepoExplorerRowKeyboardPresentation.inactive
    let interactions: RepoExplorerTableInteractions

    init(interactions: RepoExplorerTableInteractions) {
        self.interactions = interactions
    }

    func install(_ binding: RepoExplorerTableRowBinding) {
        self.binding = binding
    }

    func clear() {
        binding = nil
        keyboardPresentation = .inactive
    }

    func applyKeyboardPresentation(_ presentation: RepoExplorerRowKeyboardPresentation) {
        guard keyboardPresentation != presentation else { return }
        keyboardPresentation = presentation
    }

    func performCommand(
        _ request: RepoExplorerCommandPresentationRequest,
        identity: RepoExplorerTableRowBindingIdentity,
        commandGeneration: UInt64
    ) {
        guard binding?.identity == identity,
            binding?.commandPresentationSnapshot.generation == commandGeneration
        else { return }
        interactions.onCommandRequest(request)
    }

    func toggleGroup(
        _ groupID: String,
        identity: RepoExplorerTableRowBindingIdentity
    ) {
        guard binding?.identity == identity else { return }
        interactions.onToggleGroup(groupID)
    }

    func focusPane(
        _ paneID: UUID,
        identity: RepoExplorerTableRowBindingIdentity
    ) {
        guard binding?.identity == identity else { return }
        interactions.onFocusPane(paneID)
    }
}

struct RepoExplorerTableRowHostingRoot: View {
    @Bindable var slot: RepoExplorerTableRowSlot
    let octiconLoader: OcticonLoader

    var body: some View {
        Group {
            if let binding = slot.binding {
                RepoExplorerMaterializedRowView(
                    row: binding.row,
                    commandPresentationSnapshot: binding.commandPresentationSnapshot,
                    octiconLoader: octiconLoader,
                    paneContextControl: slot.interactions.paneContextControl,
                    keyboardPresentation: slot.keyboardPresentation,
                    onCommandRequest: { request in
                        slot.performCommand(
                            request,
                            identity: binding.identity,
                            commandGeneration: binding.commandPresentationSnapshot.generation
                        )
                    },
                    onToggleGroup: { groupID in
                        slot.toggleGroup(groupID, identity: binding.identity)
                    },
                    onFocusPane: { paneID in
                        slot.focusPane(paneID, identity: binding.identity)
                    }
                )
                .id(binding.identity.rowID)
            }
        }
    }
}

@MainActor
final class RepoExplorerTableRowCell: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("repo-explorer-hosted-row")

    let hostingView: NSHostingView<RepoExplorerTableRowHostingRoot>
    private let slot: RepoExplorerTableRowSlot
    private var reuseSequence: UInt64 = 0

    var currentBindingIdentity: RepoExplorerTableRowBindingIdentity? {
        slot.binding?.identity
    }

    var currentCommandGeneration: UInt64? {
        slot.binding?.commandPresentationSnapshot.generation
    }

    func applyKeyboardPresentation(_ presentation: RepoExplorerRowKeyboardPresentation) {
        slot.applyKeyboardPresentation(presentation)
    }

    init(
        octiconLoader: OcticonLoader,
        interactions: RepoExplorerTableInteractions = .inert
    ) {
        let stableSlot = RepoExplorerTableRowSlot(interactions: interactions)
        slot = stableSlot
        hostingView = NSHostingView(
            rootView: RepoExplorerTableRowHostingRoot(
                slot: stableSlot,
                octiconLoader: octiconLoader
            )
        )
        super.init(frame: .zero)

        identifier = Self.reuseIdentifier
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAccessibilityRole(.row)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    @discardableResult
    func bind(
        row: RepoExplorerMaterializedRow,
        visibleGeneration: UInt64,
        commandPresentationSnapshot: RepoExplorerCommandPresentationSnapshot = .empty
    ) -> RepoExplorerTableRowBindingIdentity {
        if let currentBinding = slot.binding,
            currentBinding.identity.visibleGeneration == visibleGeneration,
            currentBinding.row == row,
            currentBinding.commandPresentationSnapshot == commandPresentationSnapshot
        {
            return currentBinding.identity
        }
        return installBinding(
            row: row,
            visibleGeneration: visibleGeneration,
            commandPresentationSnapshot: commandPresentationSnapshot
        )
    }

    private func installBinding(
        row: RepoExplorerMaterializedRow,
        visibleGeneration: UInt64,
        commandPresentationSnapshot: RepoExplorerCommandPresentationSnapshot
    ) -> RepoExplorerTableRowBindingIdentity {
        if let currentBinding = slot.binding,
            currentBinding.identity.visibleGeneration == visibleGeneration,
            currentBinding.row == row
        {
            slot.install(
                RepoExplorerTableRowBinding(
                    identity: currentBinding.identity,
                    row: row,
                    commandPresentationSnapshot: commandPresentationSnapshot
                )
            )
            return currentBinding.identity
        }
        clearBindingForReuse()
        reuseSequence &+= 1
        let identity = RepoExplorerTableRowBindingIdentity(
            visibleGeneration: visibleGeneration,
            rowID: row.id,
            reuseToken: RepoExplorerTableRowReuseToken(rawValue: reuseSequence)
        )
        slot.install(
            RepoExplorerTableRowBinding(
                identity: identity,
                row: row,
                commandPresentationSnapshot: commandPresentationSnapshot
            )
        )
        setAccessibilityLabel(RepoExplorerMaterializedRowView.accessibilityLabel(for: row))
        return identity
    }

    func clearBindingForReuse() {
        slot.clear()
        setAccessibilityLabel(nil)
    }

    @discardableResult
    func performIfCurrent(
        _ identity: RepoExplorerTableRowBindingIdentity,
        operation: () -> Void
    ) -> Bool {
        guard currentBindingIdentity == identity else { return false }
        operation()
        return true
    }

    @discardableResult
    func performCommandIfCurrent(
        _ identity: RepoExplorerTableRowBindingIdentity,
        commandGeneration: UInt64,
        operation: () -> Void
    ) -> Bool {
        guard currentBindingIdentity == identity,
            slot.binding?.commandPresentationSnapshot.generation == commandGeneration
        else { return false }
        operation()
        return true
    }
}
