import AgentStudioInfrastructure
import Foundation
import SwiftUI

/// The one paint-font source used by the view and by worker-side font resolution.
package enum PaneContextMessageBodyFont: Sendable, Equatable {
    case proportional(pointSize: CGFloat)
    case monospaced(pointSize: CGFloat)

    package var paintFont: Font {
        switch self {
        case .proportional(let size): .system(size: size)
        case .monospaced(let size): .system(size: size, design: .monospaced)
        }
    }

    package var lineSpacing: CGFloat {
        switch self {
        case .proportional: AppStyles.Components.PaneContext.bodyLineSpacing
        case .monospaced: AppStyles.Components.PaneContext.monospacedLineSpacing
        }
    }
}

/// Actual layout inputs copied by the UI; font resolution and text layout stay in the worker.
package struct PaneContextMessageBodyGeometry: Equatable, Sendable {
    package let effectiveWidth: CGFloat
    package let fontContext: Font.Context
    package init(effectiveWidth: CGFloat, fontContext: Font.Context) {
        self.effectiveWidth = effectiveWidth
        self.fontContext = fontContext
    }
}

package enum PaneContextMessageBodyLayout: Equatable, Sendable {
    case pendingWidth
    case ready(geometry: PaneContextMessageBodyGeometry, visualLines: Int, more: PaneContextControlModel?)
}
