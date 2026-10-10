import Foundation
import SwiftSyntax

/// Keeps synchronous test-observation sinks local to the owner and makes
/// observation-only preparation lazy when the optional sink is nil.
struct OwnerFactSinkBoundaryRule: ArchitectureRule {
    let id = "agentstudio_owner_fact_sink_boundary"
    let severity = ArchitectureSeverity.error
    let message = "Owner-local fact sinks must not be forwarded or do observation-only work when absent"

    private let aliases: [String: FactSinkAlias]
    private let scopeFactoryIndex: FactScopeFactoryIndex
    private let sinkNames: Set<String>

    init() {
        aliases = [:]
        scopeFactoryIndex = .empty
        sinkNames = []
    }

    private init(
        aliases: [String: FactSinkAlias],
        scopeFactoryIndex: FactScopeFactoryIndex,
        sinkNames: Set<String>
    ) {
        self.aliases = aliases
        self.scopeFactoryIndex = scopeFactoryIndex
        self.sinkNames = sinkNames
    }

    func prepared(for contexts: [ArchitectureLintContext]) -> any ArchitectureRule {
        var aliases = Self.collectAliases(contexts)
        Self.collectOwnerProperties(contexts, aliases: &aliases)
        let sinkNames = Self.collectSinkNames(contexts, aliases: aliases)
        let scopeFactoryIndex = Self.collectScopeFactoryIndex(
            contexts,
            aliases: aliases,
            sinkNames: sinkNames
        )
        return Self(aliases: aliases, scopeFactoryIndex: scopeFactoryIndex, sinkNames: sinkNames)
    }

    func validate(context: ArchitectureLintContext) -> [ArchitectureDiagnostic] {
        guard Self.isProductionOrRuleFixtureSource(context) else { return [] }
        let visitor = OwnerFactSinkBoundaryVisitor(
            aliases: aliases,
            scopeFactoryIndex: scopeFactoryIndex,
            sinkNames: sinkNames
        )
        visitor.walk(context.sourceFile)
        return visitor.violations.map { violation in
            diagnostic(context: context, position: violation.position, message: violation.message)
        }
    }

    private static func collectAliases(_ contexts: [ArchitectureLintContext]) -> [String: FactSinkAlias] {
        var aliases: [String: FactSinkAlias] = [:]
        for context in contexts {
            let visitor = FactSinkAliasCollector()
            visitor.walk(context.sourceFile)
            for alias in visitor.aliases { aliases[alias.name] = alias }
        }
        return aliases
    }

    private static func collectOwnerProperties(
        _ contexts: [ArchitectureLintContext],
        aliases: inout [String: FactSinkAlias]
    ) {
        for context in contexts {
            let visitor = FactSinkOwnerPropertyCollector(aliasNames: Set(aliases.keys))
            visitor.walk(context.sourceFile)
            for (aliasName, ownerName) in visitor.owners {
                aliases[aliasName]?.ownerNames.insert(ownerName)
            }
        }
    }

    private static func collectScopeFactoryIndex(
        _ contexts: [ArchitectureLintContext],
        aliases: [String: FactSinkAlias],
        sinkNames: Set<String>
    ) -> FactScopeFactoryIndex {
        let scopeNames = Set(aliases.values.map(\.scopeType))
        var index = FactScopeFactoryIndex.empty
        for context in contexts {
            let visitor = FactScopeFactoryCollector(scopeNames: scopeNames, sinkNames: sinkNames)
            visitor.walk(context.sourceFile)
            index.outerGateRequired.formUnion(visitor.outerGateRequiredNames)
        }
        return index
    }

    private static func collectSinkNames(
        _ contexts: [ArchitectureLintContext],
        aliases: [String: FactSinkAlias]
    ) -> Set<String> {
        let ownerNames = Set(aliases.values.flatMap(\.ownerNames))
        var names: Set<String> = []
        for context in contexts {
            let visitor = FactSinkNameCollector(aliasNames: Set(aliases.keys), ownerNames: ownerNames)
            visitor.walk(context.sourceFile)
            names.formUnion(visitor.names)
        }
        return names
    }

    private static func isProductionOrRuleFixtureSource(_ context: ArchitectureLintContext) -> Bool {
        guard let relativePath = context.workspaceRelativePath else { return false }
        let components = relativePath.split(separator: "/")
        guard !components.contains(where: { $0 == "Tests" }) else { return false }
        return components.first == "Sources"
    }
}

private struct FactSinkAlias: Sendable {
    let name: String
    let scopeType: String
    let factType: String
    var ownerNames: Set<String> = []
}

private struct OwnerFactSinkViolation {
    let position: AbsolutePosition
    let message: String
}

private struct FactScopeFactoryIndex {
    var outerGateRequired: Set<String>

    static let empty = Self(outerGateRequired: [])
}

private final class FactSinkAliasCollector: SyntaxVisitor {
    private(set) var aliases: [FactSinkAlias] = []

    init() {
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
                factType: Self.baseTypeName(functionType.parameters.last!.type.trimmedDescription)
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

private final class FactSinkOwnerPropertyCollector: SyntaxVisitor {
    private let aliasNames: Set<String>
    private(set) var owners: [(aliasName: String, ownerName: String)] = []

    init(aliasNames: Set<String>) {
        self.aliasNames = aliasNames
        super.init(viewMode: .sourceAccurate)
    }

    override func visitPost(_ node: VariableDeclSyntax) {
        guard let ownerName = node.enclosingOwnerTypeName else { return }
        for binding in node.bindings {
            guard let identifier = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text,
                identifier.lowercased().contains("sink"),
                let type = binding.typeAnnotation?.type.trimmedDescription
            else {
                continue
            }
            let normalizedType = type.replacingOccurrences(of: "?", with: "").trimmingCharacters(in: .whitespaces)
            guard aliasNames.contains(normalizedType) else { continue }
            owners.append((normalizedType, ownerName))
        }
    }
}

private final class FactSinkNameCollector: SyntaxVisitor {
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

private final class FactScopeFactoryCollector: SyntaxVisitor {
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
            scopeNames.contains(returnType.replacingOccurrences(of: "?", with: "").trimmingCharacters(in: .whitespaces))
        else {
            return
        }
        if let firstGuard = node.body?.statements.first?.item.as(GuardStmtSyntax.self),
            firstGuard.body.exitsScope,
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
                scopeNames.contains(
                    scopeType.replacingOccurrences(of: "?", with: "").trimmingCharacters(in: .whitespaces)),
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
}

private enum FactSinkGateSyntax {
    static func establishesSink(
        _ conditions: ConditionElementListSyntax,
        sinkNames: Set<String>
    ) -> Bool {
        conditions.contains { element in
            if let optionalBinding = element.condition.as(OptionalBindingConditionSyntax.self),
                let identifier = optionalBinding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text,
                sinkNames.contains(identifier)
            {
                return true
            }
            guard let expression = element.condition.as(ExprSyntax.self) else { return false }
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
}

private final class OwnerFactSinkBoundaryVisitor: SyntaxVisitor {
    private let aliases: [String: FactSinkAlias]
    private let scopeFactoryIndex: FactScopeFactoryIndex
    private let sinkNames: Set<String>
    private(set) var violations: [OwnerFactSinkViolation] = []

    init(
        aliases: [String: FactSinkAlias],
        scopeFactoryIndex: FactScopeFactoryIndex,
        sinkNames: Set<String>
    ) {
        self.aliases = aliases
        self.scopeFactoryIndex = scopeFactoryIndex
        self.sinkNames = sinkNames
        super.init(viewMode: .sourceAccurate)
    }

    override func visitPost(_ node: InitializerDeclSyntax) {
        guard let ownerName = node.enclosingOwnerTypeName else { return }
        for parameter in node.signature.parameterClause.parameters {
            guard aliases[Self.baseTypeName(parameter.type.trimmedDescription)] != nil else { continue }
            if let alias = aliases[Self.baseTypeName(parameter.type.trimmedDescription)],
                !alias.ownerNames.contains(ownerName)
            {
                record(
                    parameter.positionAfterSkippingLeadingTrivia,
                    "A fact sink may only enter through its owning initializer, never a forwarding initializer"
                )
            }
        }
    }

    override func visitPost(_ node: FunctionDeclSyntax) {
        guard let ownerName = node.enclosingOwnerTypeName, let body = node.body else { return }
        let parameters = node.signature.parameterClause.parameters.compactMap { parameter -> (String, FactSinkAlias)? in
            let aliasName = Self.baseTypeName(parameter.type.trimmedDescription)
            guard let alias = aliases[aliasName] else { return nil }
            return (parameter.secondName?.text ?? parameter.firstName.text, alias)
        }
        for (parameterName, alias) in parameters where !alias.ownerNames.contains(ownerName) {
            let callCollector = FactSinkForwardingCallCollector(parameterName: parameterName)
            callCollector.walk(body)
            for position in callCollector.positions {
                record(position, "An owner-local fact sink must not be forwarded through another type")
            }
        }
    }

    override func visitPost(_ node: VariableDeclSyntax) {
        for binding in node.bindings {
            let bindingType = binding.typeAnnotation?.type.trimmedDescription
            if let bindingType,
                aliases.values.contains(where: { $0.scopeType == Self.baseTypeName(bindingType) }),
                bindingType.contains("?") == false,
                !FactScopeFactoryCollector.isComputedProperty(binding),
                Self.isStoredProperty(node)
            {
                record(
                    node.positionAfterSkippingLeadingTrivia,
                    "A fact-only scope must not be stored as unconditional production state"
                )
            }
        }
    }

    override func visitPost(_ node: FunctionCallExprSyntax) {
        let calleeName = node.directCalleeBaseName
        if let calleeName, scopeFactoryIndex.outerGateRequired.contains(calleeName), !isBehindSinkGate(Syntax(node)) {
            record(
                node.calledExpression.positionAfterSkippingLeadingTrivia,
                "A fact-scope factory must only be called behind the optional sink gate"
            )
        }
        if Self.scopeConstructorType(Syntax(node), scopeTypeNames: Self.scopeTypeNames(in: aliases)) != nil,
            !isInsideIndexedScopeFactory(Syntax(node)),
            !isBehindSinkGate(Syntax(node))
        {
            record(
                node.calledExpression.positionAfterSkippingLeadingTrivia,
                "Fact scope construction must happen only after the optional sink is present"
            )
        }
        if calleeName?.hasPrefix("begin") == true,
            calleeName?.contains("Fact") == true,
            !isBehindSinkGate(Syntax(node)),
            node.arguments.contains(where: { argument in
                argument.label.map { ["lane", "in", "scope"].contains($0.text) } == true
                    && Self.isFactLaneConstructor(argument.expression)
            })
        {
            record(
                node.calledExpression.positionAfterSkippingLeadingTrivia,
                "Fact-only lane values must be created behind the optional sink gate"
            )
        }
        let callerOwner = node.enclosingOwnerTypeName
        for argument in node.arguments where argument.label?.text.lowercased().contains("factsink") == true {
            guard argument.expression.trimmedDescription != "nil",
                !isSameOwnerFactOperation(node, callerOwner: callerOwner)
            else {
                continue
            }
            record(
                argument.positionAfterSkippingLeadingTrivia,
                "Production construction must not supply an owner-local test fact sink"
            )
        }
        for argument in node.arguments where argument.label?.text.lowercased().contains("factsink") == true {
            guard let callerOwner,
                aliases.values.contains(where: { $0.ownerNames.contains(callerOwner) }),
                aliases.values.contains(where: {
                    $0.ownerNames.contains(calleeName ?? "") && !$0.ownerNames.contains(callerOwner)
                })
            else { continue }
            record(
                argument.positionAfterSkippingLeadingTrivia,
                "An owner-local fact sink must not be forwarded to another product type"
            )
        }
    }

    private func isSameOwnerFactOperation(_ call: FunctionCallExprSyntax, callerOwner: String?) -> Bool {
        guard let callerOwner else { return false }
        return aliases.values.contains { $0.ownerNames.contains(callerOwner) }
    }

    override func visitPost(_ node: MemberAccessExprSyntax) {
        if scopeFactoryIndex.outerGateRequired.contains(node.declName.baseName.text),
            !isBehindSinkGate(Syntax(node))
        {
            record(
                node.positionAfterSkippingLeadingTrivia,
                "A fact-scope factory must only be read behind the optional sink gate"
            )
            return
        }
        guard node.parent?.is(FunctionCallExprSyntax.self) != true,
            Self.scopeConstructorType(Syntax(node), scopeTypeNames: Self.scopeTypeNames(in: aliases)) != nil,
            !isInsideIndexedScopeFactory(Syntax(node)),
            !isBehindSinkGate(Syntax(node))
        else { return }
        record(
            node.positionAfterSkippingLeadingTrivia,
            "Fact scope construction must happen only after the optional sink is present"
        )
    }

    private func isBehindSinkGate(_ node: Syntax) -> Bool {
        var current = node.parent
        while let ancestor = current {
            if let ifExpression = ancestor.as(IfExprSyntax.self),
                FactSinkGateSyntax.establishesSink(ifExpression.conditions, sinkNames: sinkNames),
                ifExpression.body.position <= node.position,
                node.position <= ifExpression.body.endPosition
            {
                return true
            }
            if let codeBlock = ancestor.as(CodeBlockSyntax.self),
                codeBlock.statements.contains(where: { statement in
                    guard statement.position < node.position,
                        let guardStatement = statement.item.as(GuardStmtSyntax.self),
                        guardStatement.body.exitsScope
                    else {
                        return false
                    }
                    return FactSinkGateSyntax.establishesSink(guardStatement.conditions, sinkNames: sinkNames)
                })
            {
                return true
            }
            if let call = ancestor.as(FunctionCallExprSyntax.self),
                let optionalCall = call.calledExpression.as(OptionalChainingExprSyntax.self),
                let sinkReference = optionalCall.expression.as(DeclReferenceExprSyntax.self),
                sinkNames.contains(sinkReference.baseName.text),
                call.arguments.contains(where: {
                    $0.expression.position <= node.position && node.position <= $0.expression.endPosition
                })
            {
                return true
            }
            if let closure = ancestor.as(ClosureExprSyntax.self), isOptionalSinkMap(closure) {
                return true
            }
            current = ancestor.parent
        }
        return false
    }

    private func isInsideIndexedScopeFactory(_ syntax: Syntax) -> Bool {
        var current = syntax.parent
        while let ancestor = current {
            if let function = ancestor.as(FunctionDeclSyntax.self),
                let returnType = function.signature.returnClause?.type.trimmedDescription,
                Self.scopeTypeNames(in: aliases).contains(Self.baseTypeName(returnType))
            {
                return true
            }
            if let variable = ancestor.as(VariableDeclSyntax.self) {
                for binding in variable.bindings {
                    guard FactScopeFactoryCollector.isComputedProperty(binding),
                        let scopeType = binding.typeAnnotation?.type.trimmedDescription,
                        Self.scopeTypeNames(in: aliases).contains(Self.baseTypeName(scopeType)),
                        let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text,
                        scopeFactoryIndex.outerGateRequired.contains(name)
                    else {
                        continue
                    }
                    return true
                }
            }
            current = ancestor.parent
        }
        return false
    }

    private func isOptionalSinkMap(_ closure: ClosureExprSyntax) -> Bool {
        guard let call = closure.parent?.as(FunctionCallExprSyntax.self),
            let member = call.calledExpression.as(MemberAccessExprSyntax.self),
            member.declName.baseName.text == "map",
            let base = member.base,
            let sinkName = Self.lastMemberName(base),
            sinkNames.contains(sinkName)
        else {
            return false
        }
        return call.trailingClosure?.id == closure.id
            || call.arguments.contains(where: { $0.expression.as(ClosureExprSyntax.self)?.id == closure.id })
    }

    private static func lastMemberName(_ expression: ExprSyntax) -> String? {
        if let reference = expression.as(DeclReferenceExprSyntax.self) {
            return reference.baseName.text
        }
        if let member = expression.as(MemberAccessExprSyntax.self) {
            return member.declName.baseName.text
        }
        if let optional = expression.as(OptionalChainingExprSyntax.self) {
            return lastMemberName(optional.expression)
        }
        return nil
    }

    private func record(_ position: AbsolutePosition, _ message: String) {
        violations.append(OwnerFactSinkViolation(position: position, message: message))
    }

    private static func baseTypeName(_ typeDescription: String) -> String {
        typeDescription
            .replacingOccurrences(of: "?", with: "")
            .replacingOccurrences(of: "@escaping", with: "")
            .trimmingCharacters(in: .whitespaces)
    }

    private static func scopeTypeNames(in aliases: [String: FactSinkAlias]) -> Set<String> {
        Set(aliases.values.map(\.scopeType))
    }

    private static func scopeConstructorType(_ syntax: Syntax, scopeTypeNames: Set<String>) -> String? {
        let calledExpression: ExprSyntax?
        if let call = syntax.as(FunctionCallExprSyntax.self) {
            calledExpression = call.calledExpression
        } else {
            calledExpression = syntax.as(ExprSyntax.self)
        }
        guard let calledExpression else { return nil }
        if let scopeType = scopeTypeReference(in: calledExpression, scopeTypeNames: scopeTypeNames) {
            return scopeType
        }
        if let memberAccess = calledExpression.as(MemberAccessExprSyntax.self) {
            if let base = memberAccess.base,
                let scopeType = scopeTypeReference(in: base, scopeTypeNames: scopeTypeNames)
            {
                return scopeType
            }
            if memberAccess.base == nil,
                let contextualType = contextualScopeType(for: syntax, scopeTypeNames: scopeTypeNames)
            {
                return contextualType
            }
        }
        return nil
    }

    private static func scopeTypeReference(in expression: ExprSyntax, scopeTypeNames: Set<String>) -> String? {
        if let reference = expression.as(DeclReferenceExprSyntax.self),
            scopeTypeNames.contains(reference.baseName.text)
        {
            return reference.baseName.text
        }
        if let memberAccess = expression.as(MemberAccessExprSyntax.self) {
            if scopeTypeNames.contains(memberAccess.declName.baseName.text) {
                return memberAccess.declName.baseName.text
            }
            if let base = memberAccess.base {
                return scopeTypeReference(in: base, scopeTypeNames: scopeTypeNames)
            }
        }
        return nil
    }

    private static func contextualScopeType(for syntax: Syntax, scopeTypeNames: Set<String>) -> String? {
        var current = syntax.parent
        while let ancestor = current {
            if let binding = ancestor.as(PatternBindingSyntax.self),
                let type = binding.typeAnnotation?.type.trimmedDescription
            {
                let typeName = baseTypeName(type)
                if scopeTypeNames.contains(typeName) { return typeName }
            }
            if ancestor.is(ReturnStmtSyntax.self) {
                var returnOwner = ancestor.parent
                while let owner = returnOwner {
                    if let function = owner.as(FunctionDeclSyntax.self),
                        let type = function.signature.returnClause?.type.trimmedDescription
                    {
                        let typeName = baseTypeName(type)
                        if scopeTypeNames.contains(typeName) { return typeName }
                    }
                    returnOwner = owner.parent
                }
            }
            current = ancestor.parent
        }
        return nil
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

    private static func isFactLaneConstructor(_ expression: ExprSyntax) -> Bool {
        if let call = expression.as(FunctionCallExprSyntax.self),
            let memberAccess = call.calledExpression.as(MemberAccessExprSyntax.self)
        {
            return memberAccess.declName.baseName.text == "workspace"
        }
        if let memberAccess = expression.as(MemberAccessExprSyntax.self) {
            return memberAccess.declName.baseName.text == "application"
        }
        return false
    }
}

private final class FactSinkForwardingCallCollector: SyntaxVisitor {
    private let parameterName: String
    private(set) var positions: [AbsolutePosition] = []

    init(parameterName: String) {
        self.parameterName = parameterName
        super.init(viewMode: .sourceAccurate)
    }

    override func visitPost(_ node: FunctionCallExprSyntax) {
        guard
            node.arguments.contains(where: {
                $0.label?.text.lowercased().contains("factsink") == true
                    && $0.expression.trimmedDescription == parameterName
            })
        else {
            return
        }
        positions.append(node.calledExpression.positionAfterSkippingLeadingTrivia)
    }
}

extension SyntaxProtocol {
    fileprivate var enclosingOwnerTypeName: String? {
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

extension FunctionCallExprSyntax {
    fileprivate var directCalleeBaseName: String? {
        if let name = calledExpression.as(DeclReferenceExprSyntax.self) {
            return name.baseName.text
        }
        return calledExpression.as(MemberAccessExprSyntax.self)?.declName.baseName.text
    }
}
