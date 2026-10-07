import AgentStudioInfrastructure
import AppKit
import SwiftUI

@MainActor
final class PersistentTabHostView: NSView {
    let tabId: UUID
    let hostingView: NSHostingView<AnyView>

    init(
        tabId: UUID,
        rootView: SingleTabContent,
        paneContextReaders: PaneContextUIReaders? = nil
    ) {
        self.tabId = tabId
        self.hostingView = NSHostingView(
            rootView: AnyView(
                rootView.tint(AppStyles.General.Accent.primaryColor).environment(
                    \.paneContextUIReaders, paneContextReaders)))
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        hostingView.sizingOptions = [.minSize]
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.topAnchor.constraint(equalTo: topAnchor),
            hostingView.leadingAnchor.constraint(equalTo: leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: trailingAnchor),
            hostingView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }
}
