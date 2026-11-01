import Foundation

/// A caller's sizing choice, resolved once from its presenting window at opening.
package enum PopoverPanelSizing: Sendable, Equatable {
    case contentSized(maximumHeight: CGFloat?)
    case windowFraction(CGFloat, minimumHeight: CGFloat)

    package nonisolated func resolve(presentingWindowHeight: CGFloat) -> PopoverPanelHeight {
        switch self {
        case .contentSized(let maximumHeight):
            .contentSized(maximumHeight: maximumHeight)
        case .windowFraction(let fraction, let minimumHeight):
            .fixed(min(presentingWindowHeight, max(minimumHeight, presentingWindowHeight * fraction)))
        }
    }
}

/// Immutable opening bounds; a fixed height scrolls content instead of growing with it.
package enum PopoverPanelHeight: Sendable, Equatable {
    case contentSized(maximumHeight: CGFloat?)
    case fixed(CGFloat)

    package nonisolated var maximumHeight: CGFloat? {
        switch self {
        case .contentSized(let maximumHeight): maximumHeight
        case .fixed(let height): height
        }
    }
}
