import Foundation
import SwiftSyntax

struct OwnerFactSinkViolation {
    let position: AbsolutePosition
    let message: String
}

final class OwnerFactSinkBoundaryVisitor: SyntaxVisitor {
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
            let aliasName = Self.baseTypeName(parameter.type.trimmedDescription)
            guard let alias = aliases[aliasName] else { continue }
            if !alias.ownerNames.contains(ownerName) {
                record(
                    parameter.positionAfterSkippingLeadingTrivia,
                    "A fact sink may only enter through its owning initializer, never a forwarding initializer"
                )
                continue
            }
            let isOptional = parameter.type.trimmedDescription.contains("?")
            let defaultsToNil = parameter.defaultValue?.value.trimmedDescription == "nil"
            if !isOptional || !defaultsToNil {
                record(
                    parameter.positionAfterSkippingLeadingTrivia,
                    "Owner fact-sink initializers must use an optional sink defaulted to nil"
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
            if Self.isStoredProperty(node),
                let ownerName = node.enclosingOwnerTypeName,
                let bindingType,
                let alias = aliases[Self.baseTypeName(bindingType)],
                !alias.ownerNames.contains(ownerName)
            {
                record(
                    binding.positionAfterSkippingLeadingTrivia,
                    "An owner-local fact sink may only be stored by its owning type"
                )
            }
            if let bindingType,
                Self.isDirectScopeType(bindingType, scopeTypeNames: Self.scopeTypeNames(in: aliases)),
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
                        statement.endPosition < node.position,
                        FactSinkGateSyntax.exitsScope(guardStatement.body)
                    else {
                        return false
                    }
                    return FactSinkGateSyntax.establishesSink(guardStatement.conditions, sinkNames: sinkNames)
                })
            {
                return true
            }
            if let codeBlock = ancestor.as(CodeBlockSyntax.self),
                codeBlock.statements.contains(where: { statement in
                    guard statement.position < node.position,
                        statement.endPosition < node.position,
                        let ifExpression = statement.item.as(IfExprSyntax.self)
                            ?? statement.item.as(ExpressionStmtSyntax.self)?.expression.as(IfExprSyntax.self),
                        FactSinkGateSyntax.exitsScope(ifExpression.body)
                    else {
                        return false
                    }
                    return FactSinkGateSyntax.isExitOnNilSink(ifExpression.conditions, sinkNames: sinkNames)
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
                if isDirectScopeType(type, scopeTypeNames: scopeTypeNames) {
                    return baseTypeName(type)
                }
            }
            if ancestor.is(ReturnStmtSyntax.self) {
                var returnOwner = ancestor.parent
                while let owner = returnOwner {
                    if let function = owner.as(FunctionDeclSyntax.self),
                        let type = function.signature.returnClause?.type.trimmedDescription
                    {
                        if isDirectScopeType(type, scopeTypeNames: scopeTypeNames) {
                            return baseTypeName(type)
                        }
                    }
                    returnOwner = owner.parent
                }
            }
            current = ancestor.parent
        }
        return nil
    }

    private static func isDirectScopeType(_ typeDescription: String, scopeTypeNames: Set<String>) -> Bool {
        let normalizedType = typeDescription.trimmingCharacters(in: .whitespaces)
        guard !normalizedType.contains("[") && !normalizedType.contains("<") && !normalizedType.contains(",") else {
            return false
        }
        return scopeTypeNames.contains(baseTypeName(normalizedType))
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

extension FunctionCallExprSyntax {
    fileprivate var directCalleeBaseName: String? {
        if let name = calledExpression.as(DeclReferenceExprSyntax.self) {
            return name.baseName.text
        }
        return calledExpression.as(MemberAccessExprSyntax.self)?.declName.baseName.text
    }
}
