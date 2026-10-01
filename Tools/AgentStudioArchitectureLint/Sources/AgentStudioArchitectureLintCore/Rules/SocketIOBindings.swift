import Foundation
import SwiftSyntax

/// Source-local receiver evidence. Names alone (such as `connection` or `queue`)
/// are not types: parameters, constructions, aliases and stored properties are.
struct SocketIOBindings {
    private let bindings: [SocketIOBinding]
    private let returnTypes: [String: Set<String>]

    init(sourceFile: SourceFileSyntax) {
        let collector = SocketIOBindingVisitor()
        collector.walk(sourceFile)
        bindings = collector.bindings
        returnTypes = collector.returnTypes
    }

    func type(of expression: ExprSyntax, at position: AbsolutePosition) -> String? {
        type(of: expression, at: position, visited: [])
    }

    private func type(of expression: ExprSyntax, at position: AbsolutePosition, visited: Set<Int>) -> String? {
        let expression = expression.socketIOUnwrapped
        if expression.trimmedDescription == "DispatchQueue.main" { return "DispatchQueue" }
        if let reference = expression.as(DeclReferenceExprSyntax.self) {
            return bindingType(named: reference.baseName.text, at: position, visited: visited)
        }
        if let member = expression.as(MemberAccessExprSyntax.self), let base = member.base {
            if base.trimmedDescription == "self" {
                return bindingType(named: member.declName.baseName.text, at: position, visited: visited)
            }
            guard let ownerType = type(of: base, at: position, visited: visited) else { return nil }
            let properties = bindings.filter {
                $0.ownerType == ownerType && $0.name == member.declName.baseName.text
            }
            guard properties.count == 1, let property = properties.first else { return nil }
            return resolvedType(of: property, visited: visited)
        }
        guard let call = expression.as(FunctionCallExprSyntax.self) else { return nil }
        if ["withoutBlockingCooperativePool", "valueFromDedicatedThread"].contains(call.socketIOCalledName ?? ""),
            let closure = call.trailingClosure ?? call.arguments.first?.expression.as(ClosureExprSyntax.self),
            let item = closure.statements.last
        {
            if let returned = item.item.as(ReturnStmtSyntax.self)?.expression {
                return type(of: returned, at: returned.position, visited: visited)
            }
            if let returned = item.item.as(ExprSyntax.self) {
                return type(of: returned, at: returned.position, visited: visited)
            }
        }
        if let member = call.calledExpression.as(MemberAccessExprSyntax.self),
            ["global", "init"].contains(member.declName.baseName.text),
            member.base?.trimmedDescription == "DispatchQueue"
                || member.base?.trimmedDescription == "Foundation.DispatchQueue"
        {
            return "DispatchQueue"
        }
        if call.isUnixSocketConnect || call.socketIOCalledName == "connectWithoutBlockingCooperativePool" {
            return "UnixSocketConnection"
        }
        guard let name = call.socketIOCalledName else { return nil }
        if name.first?.isUppercase == true { return name }
        guard let returns = returnTypes[name], returns.count == 1 else { return nil }
        return returns.first
    }

    private func bindingType(named name: String, at position: AbsolutePosition, visited: Set<Int>) -> String? {
        let candidates = bindings.filter {
            $0.name == name && $0.start <= position.utf8Offset && position.utf8Offset < $0.end
                && ($0.ownerType != nil || $0.position <= position.utf8Offset)
        }
        guard
            let binding = candidates.min(by: {
                let leftSize = $0.end - $0.start
                let rightSize = $1.end - $1.start
                return leftSize == rightSize ? $0.position > $1.position : leftSize < rightSize
            })
        else { return nil }
        return resolvedType(of: binding, visited: visited)
    }

    private func resolvedType(of binding: SocketIOBinding, visited: Set<Int>) -> String? {
        if let typeName = binding.typeName { return typeName }
        guard !visited.contains(binding.position), let initializer = binding.initializer else { return nil }
        return type(
            of: initializer, at: AbsolutePosition(utf8Offset: binding.position),
            visited: visited.union([binding.position]))
    }
}

private struct SocketIOBinding {
    let name: String
    let typeName: String?
    let initializer: ExprSyntax?
    let position: Int
    let start: Int
    let end: Int
    let ownerType: String?
}

private final class SocketIOBindingVisitor: SyntaxVisitor {
    var bindings: [SocketIOBinding] = []
    var returnTypes: [String: Set<String>] = [:]

    init() { super.init(viewMode: .sourceAccurate) }

    override func visitPost(_ node: FunctionDeclSyntax) {
        if let returnType = node.signature.returnClause?.type.socketIOTypeName {
            returnTypes[node.name.text, default: []].insert(returnType)
        }
        guard let body = node.body else { return }
        for parameter in node.signature.parameterClause.parameters {
            record(
                name: parameter.secondName?.text ?? parameter.firstName.text,
                typeName: parameter.type.socketIOTypeName,
                initializer: nil, node: Syntax(parameter), scope: Syntax(body))
        }
    }

    override func visitPost(_ node: PatternBindingSyntax) {
        guard let name = node.pattern.as(IdentifierPatternSyntax.self)?.identifier.text else { return }
        let scope = scope(containing: Syntax(node))
        let owner = scope.is(MemberBlockSyntax.self) ? scope.socketIOEnclosingType : nil
        record(
            name: name, typeName: node.typeAnnotation?.type.socketIOTypeName,
            initializer: node.initializer?.value, node: Syntax(node), scope: scope, owner: owner)
    }

    override func visitPost(_ node: ClosureExprSyntax) {
        guard let parameters = node.signature?.parameterClause else { return }
        switch parameters {
        case .simpleInput(let names):
            for name in names {
                record(name: name.name.text, typeName: nil, initializer: nil, node: Syntax(name), scope: Syntax(node))
            }
        case .parameterClause(let clause):
            for parameter in clause.parameters {
                record(
                    name: parameter.secondName?.text ?? parameter.firstName.text,
                    typeName: parameter.type?.socketIOTypeName, initializer: nil,
                    node: Syntax(parameter), scope: Syntax(node))
            }
        }
    }

    private func record(
        name: String, typeName: String?, initializer: ExprSyntax?, node: Syntax, scope: Syntax,
        owner: String? = nil
    ) {
        guard name != "_" else { return }
        bindings.append(
            SocketIOBinding(
                name: name, typeName: typeName, initializer: initializer, position: node.position.utf8Offset,
                start: scope.position.utf8Offset, end: scope.endPosition.utf8Offset, ownerType: owner))
    }

    private func scope(containing node: Syntax) -> Syntax {
        var ancestor = node.parent
        while let current = ancestor {
            if current.is(CodeBlockSyntax.self) || current.is(ClosureExprSyntax.self)
                || current.is(MemberBlockSyntax.self) || current.is(SourceFileSyntax.self)
            {
                return current
            }
            ancestor = current.parent
        }
        return node
    }
}

extension TypeSyntax {
    var socketIOTypeName: String? {
        let text = trimmedDescription.replacingOccurrences(of: "inout ", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard !text.contains("->"), !text.contains("<"), !text.contains("[") else { return nil }
        return text.trimmingCharacters(in: CharacterSet(charactersIn: "?!")).split(separator: ".").last.map(String.init)
    }
}

extension ExprSyntax {
    var socketIOUnwrapped: ExprSyntax {
        if let expression = self.as(TryExprSyntax.self) { return expression.expression.socketIOUnwrapped }
        if let expression = self.as(AwaitExprSyntax.self) { return expression.expression.socketIOUnwrapped }
        if let expression = self.as(OptionalChainingExprSyntax.self) { return expression.expression.socketIOUnwrapped }
        if let tuple = self.as(TupleExprSyntax.self), tuple.elements.count == 1, let element = tuple.elements.first {
            return element.expression.socketIOUnwrapped
        }
        return self
    }
}

extension Syntax {
    var socketIOEnclosingType: String? {
        var node: Syntax? = self
        while let current = node {
            if let declaration = current.as(StructDeclSyntax.self) { return declaration.name.text }
            if let declaration = current.as(ClassDeclSyntax.self) { return declaration.name.text }
            if let declaration = current.as(ActorDeclSyntax.self) { return declaration.name.text }
            if let declaration = current.as(EnumDeclSyntax.self) { return declaration.name.text }
            node = current.parent
        }
        return nil
    }
}

extension FunctionCallExprSyntax {
    var socketIOCalledName: String? {
        calledExpression.as(DeclReferenceExprSyntax.self)?.baseName.text
            ?? calledExpression.as(MemberAccessExprSyntax.self)?.declName.baseName.text
    }

    var isUnixSocketConnect: Bool {
        guard socketIOCalledName == "connect", arguments.first?.label?.text == "endpoint",
            let member = calledExpression.as(MemberAccessExprSyntax.self)
        else { return false }
        return member.base?.trimmedDescription == "UnixSocketClient"
            || member.base?.trimmedDescription == "AgentStudioIPCTransport.UnixSocketClient"
    }
}
