import AgentStudioInfrastructure
import AppKit
import SwiftUI

package enum AppEntityIcon: Equatable, Sendable {
    enum Symbol: Equatable, Sendable {
        case system(SystemSymbol)
        case octicon(OcticonSymbol)
    }

    enum SystemSymbol: String, Equatable, Sendable {
        case building2 = "building.2"
        case squareSplit2x1 = "square.split.2x1"
        case rectangleBottomhalfFilled = "rectangle.bottomhalf.filled"
        case squareStackFill = "square.stack.fill"
        case tray
        case clock
        case pin
        case house
    }

    enum OcticonSymbol: String, Equatable, Sendable {
        case gitWorktree = "octicon-git-worktree"
        case repo = "octicon-repo"
        case starFill = "octicon-star-fill"
    }

    case repo
    case coloredRepo(colorHex: String)
    case checkout(colorHex: String, isMain: Bool)
    case pane
    case drawer
    case paneGroup
    case tab
    case tabGroup
    case workspace
    case otherSources
    case activity
    case pin
    case home

    var symbol: Symbol {
        switch self {
        case .repo, .coloredRepo:
            return .octicon(.repo)
        case .checkout(_, let isMain):
            return .octicon(isMain ? .starFill : .gitWorktree)
        case .drawer:
            return .system(.rectangleBottomhalfFilled)
        case .pane, .paneGroup:
            return .system(.squareSplit2x1)
        case .tab, .tabGroup:
            return .system(.squareStackFill)
        case .workspace:
            return .system(.building2)
        case .home:
            return .system(.house)
        case .otherSources:
            return .system(.tray)
        case .activity:
            return .system(.clock)
        case .pin:
            return .system(.pin)
        }
    }

    var symbolName: String {
        switch symbol {
        case .system(let systemSymbol):
            return systemSymbol.rawValue
        case .octicon(let octiconSymbol):
            return octiconSymbol.rawValue
        }
    }

    /// `foregroundOverride` wins over the icon's own baked style. SwiftUI resolves the innermost
    /// `foregroundStyle`, so callers that need a selection color (e.g. the grouping segmented
    /// control) cannot override from outside this view; the override must be applied here.
    @MainActor
    @ViewBuilder
    package func swiftUIImage(
        loader: OcticonLoader,
        size: CGFloat,
        foregroundOverride: Color? = nil
    ) -> some View {
        switch self {
        case .pane, .drawer, .paneGroup, .tab, .tabGroup, .workspace, .otherSources, .activity, .pin, .home:
            Image(systemName: symbolName)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(foregroundOverride ?? foregroundStyle)
        case .repo, .coloredRepo, .checkout:
            OcticonImage(name: symbolName, size: size, loader: loader)
                .foregroundStyle(foregroundOverride ?? foregroundStyle)
                .rotationEffect(.degrees(rotationDegrees))
        }
    }

    /// Font-sized SF Symbols have different intrinsic bounds. Group headers use
    /// the same bounded glyph box for both symbol and Octicon sources.
    @MainActor
    @ViewBuilder
    func groupHeaderImage(loader: OcticonLoader) -> some View {
        let size = AppStyles.Shell.Sidebar.groupIconSize
        switch symbol {
        case .system(let symbol):
            Image(systemName: symbol.rawValue)
                .resizable()
                .scaledToFit()
                .font(.system(size: size, weight: .medium))
                .frame(width: size, height: size)
                .foregroundStyle(foregroundStyle)
        case .octicon:
            swiftUIImage(loader: loader, size: size)
                .frame(width: size, height: size)
        }
    }

    var foregroundStyle: Color {
        switch self {
        case .coloredRepo(let colorHex), .checkout(let colorHex, _):
            return Color(nsColor: NSColor(hex: colorHex) ?? AppStyles.General.Accent.primaryNSColor)
        case .tabGroup:
            return AppStyles.Shell.Sidebar.tabGroupIconColor
        case .repo, .pane, .drawer, .paneGroup, .tab, .workspace, .otherSources, .activity, .pin, .home:
            return .secondary
        }
    }

    var rotationDegrees: Double {
        switch self {
        case .checkout(_, let isMain):
            return isMain ? 0 : 180
        case .repo, .coloredRepo, .pane, .drawer, .paneGroup, .tab, .tabGroup, .workspace, .otherSources, .activity,
            .pin, .home:
            return 0
        }
    }
}
