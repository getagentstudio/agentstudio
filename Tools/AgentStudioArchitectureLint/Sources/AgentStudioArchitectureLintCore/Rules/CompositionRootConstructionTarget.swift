import SwiftSyntax

enum CompositionRootConstructionTarget: Equatable {
    case nativeEngine
    case callbackHandling
    case commandDispatcher
    case runtimeRegistry
    case terminalLookup
    case nativeAppHandle

    static func matching(expression: ExprSyntax) -> Self? {
        guard let components = pathComponents(of: expression) else { return nil }
        return matching(path: components)
    }

    static func matching(type: TypeSyntax) -> Self? {
        guard let components = pathComponents(of: type) else { return nil }
        return matching(path: components)
    }

    static func matching(path components: [String]) -> Self? {
        let path = components
        guard let finalName = path.last else { return nil }

        if path.suffix(2).elementsEqual(["Ghostty", "App"]) { return .nativeEngine }
        if path.suffix(2).elementsEqual(["Ghostty", "ActionRouter"]) { return .callbackHandling }
        if path.suffix(2).elementsEqual(["Ghostty", "AppHandle"]) { return .nativeAppHandle }

        switch finalName {
        case "AppCommandDispatcher": return .commandDispatcher
        case "RuntimeRegistry": return .runtimeRegistry
        case "SurfaceManager": return .terminalLookup
        case "AppHandle" where path.count == 1: return .nativeAppHandle
        default: return nil
        }
    }

    static func pathComponents(of expression: ExprSyntax) -> [String]? {
        if let reference = expression.as(DeclReferenceExprSyntax.self) {
            return [identifierName(reference.baseName)]
        }
        if let memberAccess = expression.as(MemberAccessExprSyntax.self) {
            let memberName = identifierName(memberAccess.declName.baseName)
            guard let base = memberAccess.base else { return [memberName] }
            return pathComponents(of: base).map { $0 + [memberName] }
        }
        return nil
    }

    static func pathComponents(of type: TypeSyntax) -> [String]? {
        if let identifier = type.as(IdentifierTypeSyntax.self) {
            return [identifierName(identifier.name)]
        }
        if let member = type.as(MemberTypeSyntax.self) {
            return pathComponents(of: member.baseType).map { $0 + [identifierName(member.name)] }
        }
        if let optional = type.as(OptionalTypeSyntax.self) {
            return pathComponents(of: optional.wrappedType)
        }
        if let optional = type.as(ImplicitlyUnwrappedOptionalTypeSyntax.self) {
            return pathComponents(of: optional.wrappedType)
        }
        if let attributed = type.as(AttributedTypeSyntax.self) {
            return pathComponents(of: attributed.baseType)
        }
        if let someOrAny = type.as(SomeOrAnyTypeSyntax.self) {
            return pathComponents(of: someOrAny.constraint)
        }
        return nil
    }

    private static func identifierName(_ token: TokenSyntax) -> String {
        let text = token.text
        guard text.count >= 2, text.first == "`", text.last == "`" else { return text }
        return String(text.dropFirst().dropLast())
    }

    var startupPropertyName: String? {
        switch self {
        case .nativeEngine: return "startupNativeEngine"
        case .callbackHandling: return "startupCallbackHandling"
        case .commandDispatcher: return "startupCommandDispatcher"
        case .runtimeRegistry: return "startupRuntimeRegistry"
        case .terminalLookup: return "startupTerminalLookup"
        case .nativeAppHandle: return nil
        }
    }

    var mayBeConstructedByTests: Bool {
        switch self {
        case .nativeEngine, .nativeAppHandle: return false
        case .callbackHandling, .commandDispatcher, .runtimeRegistry, .terminalLookup: return true
        }
    }
}
