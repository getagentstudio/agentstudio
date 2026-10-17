package enum AppCommandToolbarSurface: Hashable, Sendable {
    case app
    case pane
    case terminalZoom
}

package enum AppCommandSurface: Hashable, Sendable {
    case commandBar
    case mainMenu
    case contextMenu
    case toolbar(AppCommandToolbarSurface)
    case inlineControl
    case bridgePage
}

package enum AppCommandSurfacePolicy: Equatable, Sendable {
    case exposed(Set<AppCommandSurface>)
    case notPresented

    package var isValid: Bool {
        switch self {
        case .exposed(let surfaces):
            return !surfaces.isEmpty
        case .notPresented:
            return true
        }
    }

    package func exposes(_ surface: AppCommandSurface) -> Bool {
        guard case .exposed(let surfaces) = self else { return false }
        return surfaces.contains(surface)
    }
}

package enum AppCommandPreferredInvocation: Equatable, Sendable {
    case contextual
    case targetSelection
}

package enum AppCommandTargeting: Equatable, Sendable {
    case contextual
    case targeted(Set<SearchItemType>)
    case contextualAndTargeted(
        Set<SearchItemType>,
        preferredInvocation: AppCommandPreferredInvocation
    )

    package var isValid: Bool {
        switch self {
        case .contextual:
            return true
        case .targeted(let targetTypes), .contextualAndTargeted(let targetTypes, _):
            return !targetTypes.isEmpty
        }
    }

    package var supportsContextualInvocation: Bool {
        switch self {
        case .contextual, .contextualAndTargeted:
            return true
        case .targeted:
            return false
        }
    }

    package var targetTypes: Set<SearchItemType> {
        switch self {
        case .contextual:
            return []
        case .targeted(let targetTypes), .contextualAndTargeted(let targetTypes, _):
            return targetTypes
        }
    }

    package var preferredInvocation: AppCommandPreferredInvocation {
        switch self {
        case .contextual:
            return .contextual
        case .targeted:
            return .targetSelection
        case .contextualAndTargeted(_, let preferredInvocation):
            return preferredInvocation
        }
    }

    package func supports(targetType: SearchItemType) -> Bool {
        targetTypes.contains(targetType)
    }
}

package enum AppCommandPresentationSubject: Equatable, Sendable {
    case contextual(CommandContext)
    case targeted(SearchItemType)
    case contextualTarget(CommandContext, SearchItemType)
}

package struct AppCommandPresentationQuery: Equatable, Sendable {
    package let surface: AppCommandSurface
    package let subject: AppCommandPresentationSubject

    package init(
        surface: AppCommandSurface,
        subject: AppCommandPresentationSubject
    ) {
        self.surface = surface
        self.subject = subject
    }
}

extension AppCommandSpec {
    package func shouldPresent(_ query: AppCommandPresentationQuery) -> Bool {
        guard surfacePolicy.isValid, targeting.isValid else { return false }
        guard surfacePolicy.exposes(query.surface) else { return false }

        switch query.subject {
        case .contextual(let commandContext):
            return visibleWhen.isSubset(of: commandContext.satisfiedRequirements)
        case .targeted(let targetType):
            return targeting.supports(targetType: targetType)
        case .contextualTarget(let commandContext, let targetType):
            return targeting.supports(targetType: targetType)
                && visibleWhen.isSubset(of: commandContext.satisfiedRequirements)
        }
    }
}
