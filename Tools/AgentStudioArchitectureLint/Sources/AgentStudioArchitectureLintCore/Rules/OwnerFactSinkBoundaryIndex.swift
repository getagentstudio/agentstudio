import Foundation
import SwiftSyntax

struct FactSinkAlias: Sendable {
    let name: String
    let scopeType: String
    let factType: String
    var ownerTypeHints: Set<String> = []
    var ownerNames: Set<String> = []
}

struct FactScopeFactoryIndex {
    var outerGateRequired: Set<String>

    static let empty = Self(outerGateRequired: [])
}

extension SyntaxProtocol {
    var enclosingOwnerTypeName: String? {
        var current = parent
        while let node = current {
            if let type = node.as(StructDeclSyntax.self) { return type.name.text }
            if let type = node.as(ClassDeclSyntax.self) { return type.name.text }
            if let type = node.as(ActorDeclSyntax.self) { return type.name.text }
            if let type = node.as(EnumDeclSyntax.self) { return type.name.text }
            if let ext = node.as(ExtensionDeclSyntax.self) {
                return ext.extendedType.trimmedDescription.split(separator: ".").last.map(String.init)
            }
            current = node.parent
        }
        return nil
    }
}

final class FactSinkAliasCollector: SyntaxVisitor {
    private let ownerTypeHints: Set<String>
    private(set) var aliases: [FactSinkAlias] = []

    init(ownerTypeHints: Set<String>) {
        self.ownerTypeHints = ownerTypeHints
        super.init(viewMode: .sourceAccurate)
    }

    override func visitPost(_ node: TypeAliasDeclSyntax) {
        guard node.name.text.hasSuffix("FactSink"),
            let functionType = Self.functionType(node.initializer.value),
            functionType.parameters.count == 2,
            functionType.effectSpecifiers?.asyncSpecifier == nil,
            functionType.effectSpecifiers?.throwsClause?.throwsSpecifier == nil,
            functionType.returnClause.type.trimmedDescription == "Void"
        else {
            // Async throwing product-delivery callbacks are not test observers.
            return
        }
        aliases.append(
            FactSinkAlias(
                name: node.name.text,
                scopeType: Self.baseTypeName(functionType.parameters.first!.type.trimmedDescription),
                factType: Self.baseTypeName(functionType.parameters.last!.type.trimmedDescription),
                ownerTypeHints: ownerTypeHints.union(node.enclosingOwnerTypeName.map { [$0] } ?? [])
            )
        )
    }

    private static func functionType(_ type: TypeSyntax) -> FunctionTypeSyntax? {
        if let functionType = type.as(FunctionTypeSyntax.self) { return functionType }
        if let attributedType = type.as(AttributedTypeSyntax.self) {
            return functionType(attributedType.baseType)
        }
        return nil
    }

    private static func baseTypeName(_ typeDescription: String) -> String {
        typeDescription
            .replacingOccurrences(of: "?", with: "")
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "_" })
            .last
            .map(String.init) ?? typeDescription
    }
}

final class FactSinkOwnerHintCollector: SyntaxVisitor {
    private(set) var ownerTypeNames: Set<String>

    init(path: String) {
        let fileStem = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        let baseName = fileStem.split(separator: "+", maxSplits: 1).first.map(String.init) ?? fileStem
        let supportedSuffixes = ["Facts", "Support", "Contracts"]
        let ownerStem =
            supportedSuffixes.first(where: { baseName.hasSuffix($0) }).map {
                String(baseName.dropLast($0.count))
            } ?? baseName
        ownerTypeNames = [ownerStem]
        super.init(viewMode: .sourceAccurate)
    }

    override func visitPost(_ node: ExtensionDeclSyntax) {
        let ownerName = node.extendedType.trimmedDescription.split(separator: ".").last.map(String.init)
        if let ownerName { ownerTypeNames.insert(ownerName) }
    }
}

final class FactSinkOwnerTypeCollector: SyntaxVisitor {
    private let aliasNames: Set<String>
    private var propertyOwnersByAlias: [String: Set<String>] = [:]
    private var initializerOwnersByAlias: [String: Set<String>] = [:]
    var owners: [(aliasName: String, ownerName: String)] {
        propertyOwnersByAlias.flatMap { aliasName, propertyOwners in
            propertyOwners.intersection(initializerOwnersByAlias[aliasName] ?? []).map {
                (aliasName, $0)
            }
        }
    }

    init(aliasNames: Set<String>) {
        self.aliasNames = aliasNames
        super.init(viewMode: .sourceAccurate)
    }

    override func visitPost(_ node: VariableDeclSyntax) {
        guard Self.isStoredProperty(node), let ownerName = node.enclosingOwnerTypeName else { return }
        for binding in node.bindings {
            guard
                !FactScopeFactoryCollector.isComputedProperty(binding),
                let type = binding.typeAnnotation?.type.trimmedDescription
            else {
                continue
            }
            let normalizedType = type.replacingOccurrences(of: "?", with: "").trimmingCharacters(in: .whitespaces)
            guard aliasNames.contains(normalizedType) else { continue }
            propertyOwnersByAlias[normalizedType, default: []].insert(ownerName)
        }
    }

    override func visitPost(_ node: InitializerDeclSyntax) {
        guard let ownerName = node.enclosingOwnerTypeName else { return }
        for parameter in node.signature.parameterClause.parameters {
            let normalizedType = parameter.type.trimmedDescription
                .replacingOccurrences(of: "?", with: "")
                .replacingOccurrences(of: "@escaping", with: "")
                .trimmingCharacters(in: .whitespaces)
            guard aliasNames.contains(normalizedType) else { continue }
            initializerOwnersByAlias[normalizedType, default: []].insert(ownerName)
        }
    }

    private static func isStoredProperty(_ node: VariableDeclSyntax) -> Bool {
        var current = node.parent
        while let ancestor = current {
            if ancestor.is(FunctionDeclSyntax.self)
                || ancestor.is(InitializerDeclSyntax.self)
                || ancestor.is(ClosureExprSyntax.self)
                || ancestor.is(AccessorDeclSyntax.self)
            {
                return false
            }
            if ancestor.is(StructDeclSyntax.self)
                || ancestor.is(ClassDeclSyntax.self)
                || ancestor.is(ActorDeclSyntax.self)
                || ancestor.is(EnumDeclSyntax.self)
                || ancestor.is(ExtensionDeclSyntax.self)
            {
                return true
            }
            current = ancestor.parent
        }
        return false
    }
}

final class FactSinkNameCollector: SyntaxVisitor {
    private let aliasNames: Set<String>
    private let ownerNames: Set<String>
    private(set) var names: Set<String> = []

    init(aliasNames: Set<String>, ownerNames: Set<String>) {
        self.aliasNames = aliasNames
        self.ownerNames = ownerNames
        super.init(viewMode: .sourceAccurate)
    }

    override func visitPost(_ node: InitializerDeclSyntax) {
        guard let ownerName = node.enclosingOwnerTypeName, ownerNames.contains(ownerName) else { return }
        for parameter in node.signature.parameterClause.parameters {
            let normalizedType = parameter.type.trimmedDescription
                .replacingOccurrences(of: "?", with: "")
                .replacingOccurrences(of: "@escaping", with: "")
                .trimmingCharacters(in: .whitespaces)
            guard aliasNames.contains(normalizedType) else { continue }
            names.insert(parameter.secondName?.text ?? parameter.firstName.text)
        }
    }

    override func visitPost(_ node: VariableDeclSyntax) {
        for binding in node.bindings {
            let normalizedType = binding.typeAnnotation?.type.trimmedDescription
                .replacingOccurrences(of: "?", with: "")
                .trimmingCharacters(in: .whitespaces)
            guard let normalizedType, aliasNames.contains(normalizedType),
                let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text
            else {
                continue
            }
            names.insert(name)
        }
    }
}

final class FactScopeFactoryCollector: SyntaxVisitor {
    private let scopeNames: Set<String>
    private let sinkNames: Set<String>
    private(set) var outerGateRequiredNames: Set<String> = []

    init(scopeNames: Set<String>, sinkNames: Set<String>) {
        self.scopeNames = scopeNames
        self.sinkNames = sinkNames
        super.init(viewMode: .sourceAccurate)
    }

    override func visitPost(_ node: FunctionDeclSyntax) {
        guard let returnType = node.signature.returnClause?.type.trimmedDescription,
            Self.isDirectScopeType(returnType, scopeNames: scopeNames)
        else {
            return
        }
        if let firstGuard = node.body?.statements.first?.item.as(GuardStmtSyntax.self),
            FactSinkGateSyntax.exitsScope(firstGuard.body),
            FactSinkGateSyntax.establishesSink(firstGuard.conditions, sinkNames: sinkNames)
        {
            return
        } else {
            outerGateRequiredNames.insert(node.name.text)
        }
    }

    override func visitPost(_ node: VariableDeclSyntax) {
        for binding in node.bindings {
            guard Self.isComputedProperty(binding),
                let scopeType = binding.typeAnnotation?.type.trimmedDescription,
                Self.isDirectScopeType(scopeType, scopeNames: scopeNames),
                let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text
            else {
                continue
            }
            outerGateRequiredNames.insert(name)
        }
    }

    static func isComputedProperty(_ binding: PatternBindingSyntax) -> Bool {
        guard let accessorBlock = binding.accessorBlock else { return false }
        switch accessorBlock.accessors {
        case .getter:
            return true
        case .accessors(let accessors):
            return accessors.contains { $0.accessorSpecifier.text == "get" }
        }
    }

    private static func isDirectScopeType(_ description: String, scopeNames: Set<String>) -> Bool {
        let normalizedType =
            description
            .replacingOccurrences(of: "?", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard !normalizedType.contains("[") && !normalizedType.contains("<") && !normalizedType.contains(",") else {
            return false
        }
        let typeName =
            normalizedType.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "_" })
            .last
            .map(String.init) ?? normalizedType
        return scopeNames.contains(typeName)
    }
}

enum FactSinkGateSyntax {
    static func exitsScope(_ body: CodeBlockSyntax) -> Bool {
        body.statements.contains { statement in
            statement.item.is(ReturnStmtSyntax.self)
                || statement.item.is(ThrowStmtSyntax.self)
                || statement.item.is(ContinueStmtSyntax.self)
                || statement.item.is(BreakStmtSyntax.self)
        }
    }

    static func establishesSink(
        _ conditions: ConditionElementListSyntax,
        sinkNames: Set<String>
    ) -> Bool {
        conditions.contains { element in
            if let optionalBinding = element.condition.as(OptionalBindingConditionSyntax.self),
                let identifier = optionalBinding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text
            {
                if let initializer = optionalBinding.initializer?.value {
                    return referencesSink(initializer, sinkNames: sinkNames)
                }
                return sinkNames.contains(identifier)
            }
            guard let expression = element.condition.as(ExprSyntax.self) else { return false }
            guard !expression.tokens(viewMode: .sourceAccurate).contains(where: { $0.text == "||" }) else {
                return false
            }
            return expression.binaryOperands(operator: "!=").contains { comparison in
                let leftIsSink =
                    comparison.left.as(DeclReferenceExprSyntax.self)
                    .map { sinkNames.contains($0.baseName.text) } ?? false
                let rightIsSink =
                    comparison.right.as(DeclReferenceExprSyntax.self)
                    .map { sinkNames.contains($0.baseName.text) } ?? false
                let leftIsNil = comparison.left.as(NilLiteralExprSyntax.self) != nil
                let rightIsNil = comparison.right.as(NilLiteralExprSyntax.self) != nil
                return (leftIsSink && rightIsNil) || (rightIsSink && leftIsNil)
            }
        }
    }

    static func isExitOnNilSink(
        _ conditions: ConditionElementListSyntax,
        sinkNames: Set<String>
    ) -> Bool {
        guard conditions.count == 1,
            let expression = conditions.first?.condition.as(ExprSyntax.self),
            !expression.tokens(viewMode: .sourceAccurate).contains(where: {
                $0.text == "||" || $0.text == "&&"
            })
        else {
            return false
        }
        return expression.binaryOperands(operator: "==").contains { comparison in
            let leftIsSink = referencesSink(comparison.left, sinkNames: sinkNames)
            let rightIsSink = referencesSink(comparison.right, sinkNames: sinkNames)
            let leftIsNil = comparison.left.as(NilLiteralExprSyntax.self) != nil
            let rightIsNil = comparison.right.as(NilLiteralExprSyntax.self) != nil
            return (leftIsSink && rightIsNil) || (rightIsSink && leftIsNil)
        }
    }

    private static func referencesSink(_ expression: ExprSyntax, sinkNames: Set<String>) -> Bool {
        if let reference = expression.as(DeclReferenceExprSyntax.self) {
            return sinkNames.contains(reference.baseName.text)
        }
        if let member = expression.as(MemberAccessExprSyntax.self) {
            return sinkNames.contains(member.declName.baseName.text)
        }
        if let optional = expression.as(OptionalChainingExprSyntax.self) {
            return referencesSink(optional.expression, sinkNames: sinkNames)
        }
        return false
    }
}
