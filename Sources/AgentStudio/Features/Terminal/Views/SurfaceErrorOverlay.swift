import AgentStudioCore
import AgentStudioInfrastructure
import AppKit
import SwiftUI

/// Overlay view shown when a surface encounters an error
/// Matches Ghostty's SurfaceRendererUnhealthyView and SurfaceErrorView patterns
struct SurfaceErrorOverlay: View {
    let health: SurfaceHealth
    let onRestart: () -> Void
    let onDismiss: (() -> Void)?

    init(health: SurfaceHealth, onRestart: @escaping () -> Void, onDismiss: (() -> Void)? = nil) {
        self.health = health
        self.onRestart = onRestart
        self.onDismiss = onDismiss
    }

    var body: some View {
        if !health.isHealthy {
            ZStack {
                // Semi-transparent background
                Color.black.opacity(0.85)

                // Error content
                VStack(spacing: AppStyles.WorkspaceFocus.Terminal.errorOverlayContentSpacing) {
                    errorContent
                }
                .padding(AppStyles.WorkspaceFocus.Terminal.errorOverlayContentPadding)
                .background(
                    RoundedRectangle(cornerRadius: AppStyles.WorkspaceFocus.Terminal.errorOverlayCornerRadius)
                        .fill(Color(nsColor: .windowBackgroundColor))
                        .shadow(radius: 10)
                )
                .frame(maxWidth: 450)
            }
            .transition(.opacity)
        }
    }

    @ViewBuilder
    private var errorContent: some View {
        switch health {
        case .healthy:
            EmptyView()

        case .unhealthy(let reason):
            unhealthyView(reason: reason)

        case .processExited(let exitCode):
            processExitedView(exitCode: exitCode)

        case .dead:
            deadView()
        }
    }

    private func unhealthyView(reason: SurfaceHealth.UnhealthyReason) -> some View {
        VStack(spacing: AppStyles.WorkspaceFocus.Terminal.errorOverlaySectionSpacing) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: AppStyles.General.Typography.text5xl))
                .foregroundColor(.orange)

            Text("Terminal Unhealthy")
                .font(.system(size: AppStyles.General.Typography.textXl, weight: .bold))

            Text(unhealthyMessage(for: reason))
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
                .frame(maxWidth: 350)

            actionButtons
        }
    }

    private func processExitedView(exitCode: Int32?) -> some View {
        VStack(spacing: AppStyles.WorkspaceFocus.Terminal.errorOverlaySectionSpacing) {
            Image(systemName: "stop.circle.fill")
                .font(.system(size: AppStyles.General.Typography.text5xl))
                .foregroundColor(.gray)

            Text("Process Exited")
                .font(.system(size: AppStyles.General.Typography.textXl, weight: .bold))

            if let code = exitCode {
                Text("Exit code: \(code)")
                    .font(.system(size: AppStyles.General.Typography.textBase, design: .monospaced))
                    .foregroundColor(.secondary)
            } else {
                Text("The process has terminated.")
                    .foregroundColor(.secondary)
            }

            actionButtons
        }
    }

    private func deadView() -> some View {
        VStack(spacing: AppStyles.WorkspaceFocus.Terminal.errorOverlaySectionSpacing) {
            Image(systemName: "xmark.octagon.fill")
                .font(.system(size: AppStyles.General.Typography.text5xl))
                .foregroundColor(.red)

            Text("Terminal Error")
                .font(.system(size: AppStyles.General.Typography.textXl, weight: .bold))

            Text("The terminal has stopped responding. This may be due to a crash or resource exhaustion.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
                .frame(maxWidth: 350)

            actionButtons
        }
    }

    private var actionButtons: some View {
        HStack(spacing: 12) {
            if let onDismiss {
                Button(AppCommand.closePane.definition.label) {
                    onDismiss()
                }
                .buttonStyle(.bordered)
            }

            Button("Restart Terminal") {
                onRestart()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.top, AppStyles.WorkspaceFocus.Terminal.errorOverlayActionTopPadding)
    }

    private func unhealthyMessage(for reason: SurfaceHealth.UnhealthyReason) -> String {
        switch reason {
        case .rendererUnhealthy:
            return
                "The terminal renderer encountered an issue. This is usually due to exhausting available GPU memory. Please free up resources and try again."
        case .initializationFailed:
            return "The terminal failed to initialize. Please check the logs for more information."
        case .unknown:
            return "An unknown error occurred. Please try restarting the terminal."
        case .coldRestoreFailed:
            return "Restoring this session after restart didn't finish starting. Restart to try again."
        }
    }
}

// MARK: - NSView Wrapper for AppKit Integration

/// AppKit wrapper for SurfaceErrorOverlay
final class SurfaceErrorOverlayView: NSView {
    private var hostingView: NSHostingView<AnyView>?
    private var currentHealth: SurfaceHealth = .healthy

    var onRestart: (() -> Void)?
    var onDismiss: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupView()
    }

    private func setupView() {
        // Initially hidden
        isHidden = true
    }

    func configure(health: SurfaceHealth) {
        currentHealth = health

        // Remove old hosting view
        hostingView?.removeFromSuperview()

        if health.isHealthy {
            isHidden = true
            return
        }

        // Create new hosting view
        let overlay = SurfaceErrorOverlay(
            health: health,
            onRestart: { [weak self] in
                self?.onRestart?()
            },
            onDismiss: { [weak self] in
                self?.onDismiss?()
            }
        )

        let hosting = NSHostingView(
            rootView: AnyView(overlay.tint(AppStyles.General.Accent.primaryColor)))
        hosting.frame = bounds
        hosting.autoresizingMask = [.width, .height]
        addSubview(hosting)
        hostingView = hosting

        isHidden = false
    }

    func hide() {
        isHidden = true
        hostingView?.removeFromSuperview()
        hostingView = nil
    }
}

// MARK: - Preview

#if DEBUG
    struct SurfaceErrorOverlay_Previews: PreviewProvider {
        static var previews: some View {
            Group {
                SurfaceErrorOverlay(
                    health: .unhealthy(reason: .rendererUnhealthy),
                    onRestart: {},
                    onDismiss: {}
                )
                .previewDisplayName("Unhealthy")

                SurfaceErrorOverlay(
                    health: .processExited(exitCode: 1),
                    onRestart: {},
                    onDismiss: {}
                )
                .previewDisplayName("Process Exited")

                SurfaceErrorOverlay(
                    health: .dead,
                    onRestart: {},
                    onDismiss: {}
                )
                .previewDisplayName("Dead")
            }
            .frame(width: 600, height: 400)
            .background(Color.black)
        }
    }
#endif
