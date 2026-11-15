import AgentStudioInfrastructure
import SwiftUI

package enum PaneLineGlyphMotion: Equatable, Sendable {
    case still
    case opacityPulse
    case rotate
}

/// Renders already-projected status paint and motion; each host owns its icon and placement.
package struct PaneStatusGlyph<Icon: View>: View {
    private let icon: Icon
    private let toneColor: Color
    private let motion: PaneLineGlyphMotion
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulseIsDimmed = false

    package init(
        toneColor: Color, motion: PaneLineGlyphMotion, size: CGFloat,
        @ViewBuilder icon: (CGFloat) -> Icon
    ) {
        self.icon = icon(size)
        self.toneColor = toneColor
        self.motion = motion
    }

    package var body: some View {
        icon
            .opacity(
                opacityPulseIsActive && pulseIsDimmed
                    ? AppStyles.Shell.Sidebar.paneLinePulseMinimumOpacity
                    : AppStyles.Shell.Sidebar.paneLinePulseMaximumOpacity
            )
            .animation(
                opacityPulseIsActive
                    ? .easeInOut(duration: AppStyles.Shell.Sidebar.paneLinePulsePeriod / 2)
                        .repeatForever(autoreverses: true)
                    : nil,
                value: pulseIsDimmed
            )
            .onChange(of: opacityPulseIsActive, initial: true) { _, active in pulseIsDimmed = active }
            .symbolEffect(
                .rotate,
                options: .repeating.speed(AppStyles.Shell.Sidebar.paneLineRotationSpeed),
                isActive: !reduceMotion && motion == .rotate
            )
            .foregroundStyle(toneColor)
    }

    private var opacityPulseIsActive: Bool { !reduceMotion && motion == .opacityPulse }
}
