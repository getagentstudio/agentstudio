import SwiftSyntax

/// Resolves names that Swift leaves contextual, such as `Self`, `.init`, and
/// an unqualified nested type referenced from its namespace extension.
struct CompositionRootConstructionContext {
    private let lexicalTypePath: [String]

    init(around node: some SyntaxProtocol) {
        lexicalTypePath = Self.lexicalTypePath(around: node)
    }

    func hasNearestTypePath(_ suffix: [String]) -> Bool {
        lexicalTypePath.suffix(suffix.count).elementsEqual(suffix)
    }

    func hasExactTypePath(_ path: [String]) -> Bool {
        lexicalTypePath == path
    }

    func target(for expression: ExprSyntax) -> CompositionRootConstructionTarget? {
        if let exactTarget = CompositionRootConstructionTarget.matching(expression: expression) {
            return exactTarget
        }

        guard let components = CompositionRootConstructionTarget.pathComponents(of: expression) else {
            return nil
        }
        if components == ["Self"] {
            return targetForCurrentType()
        }
        return targetForUnqualifiedGhosttyType(components)
    }

    func target(for type: TypeSyntax) -> CompositionRootConstructionTarget? {
        if let exactTarget = CompositionRootConstructionTarget.matching(type: type) {
            return exactTarget
        }

        guard let components = CompositionRootConstructionTarget.pathComponents(of: type) else {
            return nil
        }
        if components == ["Self"] {
            return targetForCurrentType()
        }
        return targetForUnqualifiedGhosttyType(components)
    }

    func targetForImplicitInitializer() -> CompositionRootConstructionTarget? {
        targetForCurrentType()
    }

    private func targetForCurrentType() -> CompositionRootConstructionTarget? {
        CompositionRootConstructionTarget.matching(path: lexicalTypePath)
    }

    private func targetForUnqualifiedGhosttyType(_ components: [String]) -> CompositionRootConstructionTarget? {
        guard components.count == 1, lexicalTypePath.contains("Ghostty") else { return nil }
        switch components[0] {
        case "App":
            return CompositionRootConstructionTarget.matching(path: ["Ghostty", "App"])
        case "ActionRouter":
            return CompositionRootConstructionTarget.matching(path: ["Ghostty", "ActionRouter"])
        default:
            return nil
        }
    }

    private static func lexicalTypePath(around node: some SyntaxProtocol) -> [String] {
        var nestedTypeNames: [String] = []
        var ancestor = node.parent

        while let current = ancestor {
            if let declaration = current.as(ClassDeclSyntax.self) {
                nestedTypeNames.append(declaration.name.text)
            } else if let declaration = current.as(StructDeclSyntax.self) {
                nestedTypeNames.append(declaration.name.text)
            } else if let declaration = current.as(EnumDeclSyntax.self) {
                nestedTypeNames.append(declaration.name.text)
            } else if let declaration = current.as(ActorDeclSyntax.self) {
                nestedTypeNames.append(declaration.name.text)
            } else if let declaration = current.as(ExtensionDeclSyntax.self) {
                let extensionPath = CompositionRootConstructionTarget.pathComponents(of: declaration.extendedType) ?? []
                return extensionPath + Array(nestedTypeNames.reversed())
            }
            ancestor = current.parent
        }

        return Array(nestedTypeNames.reversed())
    }
}
