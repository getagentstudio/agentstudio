import AgentStudioCore
import AgentStudioInfrastructure
import AppKit
import SwiftUI

@MainActor
enum PaneTabEmptyStateViewFactory {
    static func make(
        model: WorkspaceEmptyStateModel,
        octiconLoader: OcticonLoader,
        commandDispatcher: any AppCommandDispatching,
        onWatchFolder: @escaping () -> Void,
        onOpenRecent: @escaping (ApplicationRecentEntity) -> Void,
        onOpenAllRecent: @escaping () -> Void
    ) -> NSHostingView<AnyView> {
        let view = NSHostingView(
            rootView: AnyView(
                WorkspaceEmptyStateView(
                    model: model,
                    octiconLoader: octiconLoader,
                    commandDispatcher: commandDispatcher,
                    onWatchFolder: onWatchFolder,
                    onOpenRecent: onOpenRecent,
                    onOpenAllRecent: onOpenAllRecent
                )
                .tint(AppStyles.General.Accent.primaryColor))
        )
        view.sizingOptions = []
        return view
    }
}
