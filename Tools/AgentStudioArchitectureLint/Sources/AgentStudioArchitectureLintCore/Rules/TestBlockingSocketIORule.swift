import SwiftSyntax

/// Synchronous client shims hide blocking I/O just as surely as a raw receive.
/// Prove the executor structurally, including cross-file listener helpers;
/// neither a support filename nor an async/concurrent annotation is an owner.
struct TestBlockingSocketIORule: ArchitectureRule {
    let id = "agentstudio_no_blocking_socket_io_in_tests"
    let severity = ArchitectureSeverity.error
    let message =
        "Blocking socket I/O in tests must run in withoutBlockingCooperativePool, valueFromDedicatedThread, "
        + "or a typed dispatch, thread or listener owner"

    private var preparedDiagnostics: [String: [ArchitectureDiagnostic]]?

    func prepared(for contexts: [ArchitectureLintContext]) -> any ArchitectureRule {
        var rule = self
        rule.preparedDiagnostics = diagnostics(for: contexts)
        return rule
    }

    func validate(context: ArchitectureLintContext) -> [ArchitectureDiagnostic] {
        guard Self.isTestSource(context) else { return [] }
        return preparedDiagnostics?[context.syntaxScopeSourceIdentity]
            ?? diagnostics(for: [context])[context.syntaxScopeSourceIdentity] ?? []
    }

    private func diagnostics(for contexts: [ArchitectureLintContext]) -> [String: [ArchitectureDiagnostic]] {
        let contexts = contexts.filter(Self.isTestSource)
        let files = contexts.map { context -> SocketIOFileFacts in
            let visitor = SocketIOCallVisitor(context: context)
            visitor.walk(context.sourceFile)
            return visitor.facts
        }
        let functions = files.flatMap(\.functions)
        let names = Set(functions.map(\.name))
        let invocations = files.flatMap(\.invocations).filter { names.contains($0.name) }
        let proved = SocketIOHelperOwnership.offPoolFunctions(functions: functions, invocations: invocations)
        var result: [String: [ArchitectureDiagnostic]] = [:]
        for (context, file) in zip(contexts, files) {
            result[context.syntaxScopeSourceIdentity] = file.sites.compactMap { site in
                if site.execution == .offPool { return nil }
                if site.execution == .caller, site.caller.map(proved.contains) == true { return nil }
                return diagnostic(context: context, position: site.position)
            }
        }
        return result
    }

    private static func isTestSource(_ context: ArchitectureLintContext) -> Bool {
        if let relative = context.workspaceRelativePath {
            return relative.hasPrefix("Tests/") && relative.hasSuffix(".swift")
        }
        // Parity with the corpus tests' mirrored repository paths; package
        // tests under Tools/ are not product test sources.
        let path = "/\(context.normalizedPath)"
        return
            (path.hasPrefix("/Tests/") || path.contains("/Fixtures/Good/Tests/")
            || path.contains("/Fixtures/Bad/Tests/")) && path.hasSuffix(".swift")
    }
}

private struct SocketIOFileFacts {
    var functions: [SocketIOFunction] = []
    var invocations: [SocketIOInvocation] = []
    var sites: [SocketIOSite] = []
}

private struct SocketIOSite {
    let position: AbsolutePosition
    let execution: SocketIOExecutionContext
    let caller: SocketIOFunctionIdentity?
}

private final class SocketIOCallVisitor: SyntaxVisitor {
    var facts = SocketIOFileFacts()
    private let source: String
    private let bindings: SocketIOBindings
    private var functions: [SocketIOFunction] = []

    init(context: ArchitectureLintContext) {
        source = context.syntaxScopeSourceIdentity
        bindings = SocketIOBindings(sourceFile: context.sourceFile)
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        let function = SocketIOFunction(node, source: source)
        facts.functions.append(function)
        functions.append(function)
        return .visitChildren
    }

    override func visitPost(_: FunctionDeclSyntax) { functions.removeLast() }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        let execution = SocketIOExecutionContexts.context(of: Syntax(node), bindings: bindings)
        let member = node.calledExpression.as(MemberAccessExprSyntax.self)
        let receiverType = member?.base.flatMap { bindings.type(of: $0, at: node.positionAfterSkippingLeadingTrivia) }
        if let name = node.socketIOCalledName {
            facts.invocations.append(
                invocation(
                    name: name, labels: node.arguments.map { $0.label?.text ?? "" },
                    receiverType: receiverType,
                    execution: execution))
        }
        if isBlockingSocketCall(node, receiverType: receiverType) {
            facts.sites.append(
                SocketIOSite(
                    position: node.calledExpression.positionAfterSkippingLeadingTrivia,
                    execution: execution, caller: functions.last?.identity))
        }
        return .visitChildren
    }

    override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
        // Function values can escape their original executor. A bare reference
        // passed directly to a typed owner is an invocation on that owner;
        // any other reference conservatively prevents helper exemption.
        if node.parent?.as(FunctionCallExprSyntax.self)?.calledExpression.id == node.id { return .visitChildren }
        if node.isMemberAccessName { return .visitChildren }
        let enclosingCall = node.parent?.as(LabeledExprSyntax.self)?.parent?.parent?.as(FunctionCallExprSyntax.self)
        let offPool =
            enclosingCall.map { SocketIOExecutionContexts.isOffPoolSubmission($0, bindings: bindings) } == true
        facts.invocations.append(
            SocketIOInvocation(
                source: source, name: node.baseName.text, labels: nil, receiverType: nil,
                caller: nil, offPool: offPool, isEscapingReference: !offPool))
        return .visitChildren
    }

    override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
        guard node.parent?.as(FunctionCallExprSyntax.self)?.calledExpression.id != node.id,
            let base = node.base,
            let receiverType = bindings.type(of: base, at: node.positionAfterSkippingLeadingTrivia)
        else { return .visitChildren }
        let call = node.parent?.as(LabeledExprSyntax.self)?.parent?.parent?.as(FunctionCallExprSyntax.self)
        let offPool = call.map { SocketIOExecutionContexts.isOffPoolSubmission($0, bindings: bindings) } == true
        facts.invocations.append(
            SocketIOInvocation(
                source: source, name: node.declName.baseName.text, labels: nil, receiverType: receiverType,
                caller: nil, offPool: offPool, isEscapingReference: !offPool))
        return .visitChildren
    }

    private func invocation(
        name: String, labels: [String], receiverType: String?, execution: SocketIOExecutionContext
    ) -> SocketIOInvocation {
        SocketIOInvocation(
            source: source, name: name, labels: labels, receiverType: receiverType,
            caller: execution == .caller ? functions.last?.identity : nil,
            offPool: execution == .offPool, isEscapingReference: false)
    }

    private func isBlockingSocketCall(_ call: FunctionCallExprSyntax, receiverType: String?) -> Bool {
        if call.isUnixSocketConnect { return true }
        let labels = call.arguments.map { $0.label?.text ?? "" }
        if call.calledExpression.is(DeclReferenceExprSyntax.self) {
            if call.socketIOCalledName == "sendRequest" {
                return ["connection", "socketPath"].contains(labels.first ?? "") && labels.contains("request")
            }
            if call.socketIOCalledName == "login" {
                return labels.first == "connection" && labels.contains("reader")
            }
        }
        guard call.calledExpression.is(MemberAccessExprSyntax.self) else { return false }
        switch call.socketIOCalledName {
        case "send":
            return receiverType == "UnixSocketConnection" && labels.first?.isEmpty == true
        case "receive":
            return labels.first == "maxBytes" && (receiverType == nil || receiverType == "UnixSocketConnection")
        case "receiveResponse", "receiveFrame":
            // SessionsVerticalFrameReader has async methods with these names;
            // the TestFrameReader synchronous methods cannot be hidden by await.
            return labels.first == "connection"
                && (receiverType == "TestFrameReader" || receiverType == nil && !isAwaited(call))
        default:
            return false
        }
    }

    private func isAwaited(_ call: FunctionCallExprSyntax) -> Bool {
        var parent = call.parent
        while let current = parent {
            if current.is(AwaitExprSyntax.self) { return true }
            if !current.is(TryExprSyntax.self) && !current.is(TupleExprSyntax.self)
                && !current.is(LabeledExprSyntax.self) && !current.is(LabeledExprListSyntax.self)
            {
                return false
            }
            parent = current.parent
        }
        return false
    }
}
