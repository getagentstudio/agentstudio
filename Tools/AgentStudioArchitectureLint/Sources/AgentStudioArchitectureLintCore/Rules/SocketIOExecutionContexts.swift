import SwiftSyntax

/// A task boundary overrides an outer dispatch/thread owner. A function body
/// needs its callers proved separately; its declaration site is not execution.
enum SocketIOExecutionContext {
    case offPool
    case caller
    case unknown
}

enum SocketIOExecutionContexts {
    static func context(of node: Syntax, bindings: SocketIOBindings) -> SocketIOExecutionContext {
        var ancestor = node.parent
        while let current = ancestor {
            if current.is(FunctionDeclSyntax.self) { return .caller }
            if let closure = current.as(ClosureExprSyntax.self) {
                if let invocation = closure.socketIOInvocation {
                    let name = invocation.socketIOCalledName
                    let taskBase = invocation.calledExpression.as(MemberAccessExprSyntax.self)?.base?.trimmedDescription
                    if name == "Task" || name == "detached" && (taskBase == "Task" || taskBase == "Swift.Task") {
                        return .unknown
                    }
                    if isOffPoolSubmission(invocation, bindings: bindings) { return .offPool }
                }
                if isNetworkListenerHandler(closure, bindings: bindings) { return .offPool }
                if closure.parent?.is(InitializerClauseSyntax.self) == true
                    || closure.parent?.is(ReturnStmtSyntax.self) == true
                {
                    return .unknown
                }
            }
            ancestor = current.parent
        }
        return .unknown
    }

    static func isOffPoolSubmission(_ call: FunctionCallExprSyntax, bindings: SocketIOBindings) -> Bool {
        guard let name = call.socketIOCalledName else { return false }
        if ["withoutBlockingCooperativePool", "valueFromDedicatedThread"].contains(name) {
            if call.calledExpression.is(DeclReferenceExprSyntax.self) { return true }
            let base = call.calledExpression.as(MemberAccessExprSyntax.self)?.base?.trimmedDescription
            return base == "AgentStudioTestHarness" || base == "AgentStudioTestSupport"
        }
        if name == "Thread",
            call.calledExpression.is(DeclReferenceExprSyntax.self)
                || call.calledExpression.trimmedDescription == "Foundation.Thread"
        {
            return true
        }
        guard let member = call.calledExpression.as(MemberAccessExprSyntax.self), let base = member.base else {
            return false
        }
        let receiverType = bindings.type(of: base, at: call.positionAfterSkippingLeadingTrivia)
        if receiverType == "DispatchQueue", ["async", "asyncAfter"].contains(name) { return true }
        if name == "detachNewThread",
            base.trimmedDescription == "Thread" || base.trimmedDescription == "Foundation.Thread"
        {
            return true
        }
        return name == "start" && receiverType == "UnixSocketListener"
    }

    private static func isNetworkListenerHandler(_ closure: ClosureExprSyntax, bindings: SocketIOBindings) -> Bool {
        guard
            let sequence = closure.parent?.as(SequenceExprSyntax.self)
                ?? closure.parent?.parent?.as(SequenceExprSyntax.self),
            let assignment = ExprSyntax(sequence).assignment,
            assignment.value.id == closure.id,
            let member = assignment.target.as(MemberAccessExprSyntax.self),
            member.declName.baseName.text == "newConnectionHandler", let base = member.base
        else { return false }
        return bindings.type(of: base, at: closure.positionAfterSkippingLeadingTrivia) == "NWListener"
    }
}

extension ClosureExprSyntax {
    /// Only the passed closure is offloaded. Eager expressions in the same
    /// call's other arguments execute on the caller and stay in scope.
    var socketIOInvocation: FunctionCallExprSyntax? {
        if let call = parent?.as(FunctionCallExprSyntax.self) { return call }
        if let argument = parent?.as(LabeledExprSyntax.self) {
            return argument.parent?.parent?.as(FunctionCallExprSyntax.self)
        }
        return nil
    }
}

struct SocketIOFunctionIdentity: Hashable {
    let source: String
    let offset: Int
}

struct SocketIOFunction {
    let identity: SocketIOFunctionIdentity
    let name: String
    let labels: [String]
    let requiredParameterCount: Int
    let ownerType: String?
    let isAsync: Bool

    init(_ node: FunctionDeclSyntax, source: String) {
        identity = SocketIOFunctionIdentity(source: source, offset: node.position.utf8Offset)
        name = node.name.text
        labels = node.signature.parameterClause.parameters.map { $0.firstName.text == "_" ? "" : $0.firstName.text }
        requiredParameterCount = node.signature.parameterClause.parameters.filter { $0.defaultValue == nil }.count
        ownerType = Syntax(node).socketIOEnclosingType
        isAsync = node.signature.effectSpecifiers?.asyncSpecifier != nil
    }

    func accepts(labels supplied: [String]) -> Bool {
        supplied.count >= requiredParameterCount && supplied.count <= labels.count
            && Array(labels.prefix(supplied.count)) == supplied
    }
}

struct SocketIOInvocation {
    let source: String
    let name: String
    let labels: [String]?
    let receiverType: String?
    let caller: SocketIOFunctionIdentity?
    let offPool: Bool
    let isEscapingReference: Bool
}

/// A synchronous helper is safe only with observed callers, every one either
/// directly off-pool or another proved helper. Unknown/escaping references and
/// mixed callers keep it unsafe. Cycles without a proved entry stay unsafe.
enum SocketIOHelperOwnership {
    static func offPoolFunctions(
        functions: [SocketIOFunction], invocations: [SocketIOInvocation]
    ) -> Set<SocketIOFunctionIdentity> {
        let functionsByName = Dictionary(grouping: functions, by: \.name)
        var callers: [SocketIOFunctionIdentity: [SocketIOInvocation]] = [:]
        for invocation in invocations {
            let named = (functionsByName[invocation.name] ?? []).filter {
                $0.name == invocation.name && (invocation.labels.map($0.accepts(labels:)) ?? true)
                    && (invocation.receiverType == nil || $0.ownerType == invocation.receiverType)
            }
            let local = named.filter { $0.identity.source == invocation.source }
            let candidates = local.isEmpty ? named : local
            // Ambiguity never fabricates ownership: every possible target gets
            // an unknown caller, rather than granting all overloads an exemption.
            for candidate in candidates {
                var caller = invocation
                if candidates.count != 1 {
                    caller = SocketIOInvocation(
                        source: invocation.source, name: invocation.name, labels: invocation.labels,
                        receiverType: invocation.receiverType, caller: nil, offPool: false, isEscapingReference: true)
                }
                callers[candidate.identity, default: []].append(caller)
            }
        }
        var proved: Set<SocketIOFunctionIdentity> = []
        var changed = true
        while changed {
            changed = false
            for function in functions where !function.isAsync && !proved.contains(function.identity) {
                guard let uses = callers[function.identity], !uses.isEmpty,
                    uses.allSatisfy({
                        !$0.isEscapingReference && ($0.offPool || $0.caller.map(proved.contains) == true)
                    })
                else { continue }
                proved.insert(function.identity)
                changed = true
            }
        }
        return proved
    }
}
