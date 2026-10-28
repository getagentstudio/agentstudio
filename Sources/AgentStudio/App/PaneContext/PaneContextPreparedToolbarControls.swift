import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioRepoExplorer
import AgentStudioSharedComponents
import Foundation
import SwiftUI

/// Compact toolbar paint comes from the same demanded off-main owner as its opened details.
struct PaneContextPreparedToolbarControls: View {
    let paneId: PaneId
    let bindings: PaneContextPopoverHostBindings
    let octiconLoader: OcticonLoader
    let onGoToPane: @MainActor (UUID) -> Void
    var onRenderingTaskStarted: @MainActor (Task<Void, Never>) -> Void = { _ in }
    var onConsumerStarted: @MainActor (PaneContextPopoverConsumerHandle) -> Void = { _ in }
    var onConsumerReadCompleted: @MainActor (PaneContextPopoverConsumerHandle) -> Void = { _ in }
    var onApplication: PaneContextPopoverApplicationObserver?
    @State private var hostId = UUIDv7.generate()
    @State private var handle: PaneContextPopoverConsumerHandle?
    @State private var requestedKey: PaneContextPopoverConsumerKey?
    @State private var setupTask: Task<Void, Never>?
    @State private var closeTask: Task<Void, Never>?
    @State private var mounted = false

    private var key: PaneContextPopoverConsumerKey {
        .init(hostId: hostId, surface: .toolbar, paneId: paneId)
    }
    var body: some View {
        ZStack(alignment: .leading) {
            if let prepared = handle?.atom.value?.toolbar {
                ViewThatFits(in: .horizontal) {
                    minimumContents(prepared)
                        .hidden()
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                        .overlay(alignment: .leading) { renderedContents(prepared) }
                    Color.clear.frame(width: 0, height: 0)
                }
            }
            Color.clear.frame(width: 0, height: 0)
        }
        .background {
            if let value = handle?.atom.value, let prepared = value.toolbar, let onApplication {
                let application = PaneContextPopoverApplication(
                    publication: value.publication, value: .pane(prepared), feedback: nil)
                NativePresentationApplication(
                    value: application,
                    onApplied: { onApplication(.applied($0)) }, onRetired: { onApplication(.retired($0)) })
            }
        }
        .onChange(of: handle?.atom.value?.publication.id) { _, _ in
            guard let value = handle?.atom.value, let prepared = value.toolbar else { return }
            onApplication?(.prepared(.init(publication: value.publication, value: .pane(prepared), feedback: nil)))
        }
        .onAppear {
            mounted = true
            startDemand()
        }
        .onChange(of: key) { _, changed in
            if mounted, requestedKey != changed { startDemand() }
        }
        .onDisappear { stopDemand() }
    }

    private func startDemand() {
        guard mounted else { return }
        let openingKey = key
        let retiringKey = requestedKey
        setupTask?.cancel()
        handle = nil
        requestedKey = openingKey
        if let retiringKey { closeTask = bindings.beginClose(retiringKey) }
        let opening = bindings.beginOpen(
            openingKey,
            demand: .init(
                content: .toolbar, location: .pane, includingDrawers: true, screenVisibleWidth: 0))
        let task = Task { @MainActor in
            guard let next = await opening.value else { return }
            guard !Task.isCancelled, mounted else {
                await bindings.retire(next)
                return
            }
            self.handle = next
            onConsumerStarted(next)
            await next.opening.initialExecution.task.value
            guard !Task.isCancelled, mounted, self.handle?.opening.epoch == next.opening.epoch else {
                if self.handle?.opening.epoch == next.opening.epoch { self.handle = nil }
                await bindings.retire(next)
                return
            }
            onConsumerReadCompleted(next)
        }
        setupTask = task
        onRenderingTaskStarted(task)
    }

    private func stopDemand() {
        mounted = false
        setupTask?.cancel()
        setupTask = nil
        let closingKey = requestedKey ?? handle?.key
        requestedKey = nil
        handle = nil
        if let closingKey { closeTask = bindings.beginClose(closingKey) }
    }

    @ViewBuilder private func minimumContents(_ prepared: PaneManagementIdentityCapture.Presentation) -> some View {
        switch prepared.toolbarItem {
        case .none: Color.clear.frame(width: 0, height: 0)
        case .chips(let chips):
            HStack(spacing: AppStyles.Shell.Sidebar.chipRowSpacing) {
                divider(exposesIdentity: false)
                ForEach(chips, id: \.kind) { chip in
                    PaneMessageKindChip(
                        model: chip, control: RepoExplorerPaneKindChipProjection.control(chip),
                        octiconLoader: octiconLoader, onOpen: {}
                    ).minimumSizeContent
                }
            }
            .fixedSize(horizontal: true, vertical: true)
        case .agentLine:
            if case .agentLine(let line)? = prepared.lines.first {
                HStack(spacing: 0) {
                    divider(exposesIdentity: false)
                    line.icon.swiftUIImage(loader: octiconLoader, size: AppStyles.Shell.Sidebar.branchIconSize)
                        .frame(width: AppStyles.Shell.Sidebar.rowLeadingIconColumnWidth, alignment: .leading)
                    Color.clear.frame(width: AppStyles.Shell.Sidebar.groupIconTitleSpacing, height: 0)
                    Text("… " + (line.ageText ?? ""))
                        .font(.system(size: AppStyles.Shell.Sidebar.branchFontSize))
                        .fixedSize()
                }
                .fixedSize(horizontal: true, vertical: true)
            }
        }
    }

    @ViewBuilder private func renderedContents(
        _ prepared: PaneManagementIdentityCapture.Presentation
    ) -> some View {
        switch prepared.toolbarItem {
        case .none: EmptyView()
        case .chips(let chips):
            HStack(spacing: AppStyles.Shell.Sidebar.chipRowSpacing) {
                divider(exposesIdentity: true)
                ForEach(chips, id: \.kind) { chip in
                    PaneContextPreparedPopoverHost(
                        paneId: paneId, presentation: .kind(chip), location: .pane, bindings: bindings,
                        octiconLoader: octiconLoader, onGoToPane: onGoToPane)
                }
            }.fixedSize()
        case .agentLine:
            if case .agentLine(let line)? = prepared.lines.first {
                HStack(spacing: 0) {
                    divider(exposesIdentity: true)
                    RepoExplorerPaneContextLineView(
                        line: line, isAgentLine: true, octiconLoader: octiconLoader, showsTooltip: false,
                        maximumTextWidth: AppStyles.Shell.DrawerToolbar.agentLineMaxWidth)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .background {
                    AccessibilityLabelBridge(
                        identifier: "paneSurfaceToolbar.agentLine", label: line.text, role: .staticText)
                }
            }
        }
    }

    private func divider(exposesIdentity: Bool) -> some View {
        Divider()
            .frame(
                width: AppStyles.Shell.DrawerToolbar.dividerWidth, height: AppStyles.Shell.DrawerToolbar.dividerHeight
            )
            .background {
                if exposesIdentity {
                    AccessibilityLabelBridge(
                        identifier: "paneSurfaceToolbar.contextDivider", label: "", role: .staticText)
                }
            }
            .padding(.horizontal, AppStyles.Shell.DrawerToolbar.dividerHorizontalPadding)
    }

}
