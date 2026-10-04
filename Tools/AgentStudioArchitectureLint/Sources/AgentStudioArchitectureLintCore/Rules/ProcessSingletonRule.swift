import SwiftSyntax

/// Production-wide state must be composed and injected; existing sites are
/// frozen by exact per-file counts in the dedicated shrink-only ledger.
struct ProcessSingletonRule: ArchitectureRule {
    let id = "agentstudio_no_new_process_singletons"
    let severity = ArchitectureSeverity.error
    let message =
        "process-wide state: construct it in the app composition and inject it (see the composition-root DI problem statement); existing instances are ledgered"

    func validate(context: ArchitectureLintContext) -> [ArchitectureDiagnostic] {
        guard let targetPath = Self.targetPath(for: context),
            targetPath.hasPrefix("Sources/"), targetPath.hasSuffix(".swift")
        else { return [] }
        let visitor = ProcessStateDeclarationVisitor()
        visitor.walk(context.sourceFile)
        return visitor.statePositions.map { diagnostic(context: context, position: $0) }
    }

    private static func targetPath(for context: ArchitectureLintContext) -> String? {
        for marker in ["/Fixtures/Bad/", "/Fixtures/Good/"] {
            if let range = context.normalizedPath.range(of: marker) {
                return String(context.normalizedPath[range.upperBound...])
            }
        }
        return context.workspaceRelativePath
    }
}

private final class ProcessStateDeclarationVisitor: SyntaxVisitor {
    private(set) var statePositions: [AbsolutePosition] = []

    override init(viewMode: SyntaxTreeViewMode = .sourceAccurate) {
        super.init(viewMode: viewMode)
    }

    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        let isStatic = node.modifiers.contains { $0.name.tokenKind == .keyword(.static) }
        let isMutable = node.bindingSpecifier.tokenKind == .keyword(.var)
        let isGlobal = isMutable && Self.isFileScope(node)
        let isTaskLocal = node.attributes.contains { element in
            guard case .attribute(let attribute) = element else { return false }
            return attribute.attributeName.trimmedDescription.split(separator: ".").last == "TaskLocal"
        }
        for binding in node.bindings {
            let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text
            let isShared = name == "shared" || name == "`shared`"
            if isGlobal || (isStatic && (isShared || (isMutable && !isTaskLocal && Self.isStored(binding)))) {
                statePositions.append(binding.pattern.positionAfterSkippingLeadingTrivia)
            }
        }
        return .visitChildren
    }

    private static func isStored(_ binding: PatternBindingSyntax) -> Bool {
        guard let accessors = binding.accessorBlock?.accessors else { return true }
        switch accessors {
        case .getter:
            return false
        case .accessors(let declarations):
            // willSet/didSet observe storage; get/set and coroutine accessors
            // project a value instead of declaring stored process-wide state.
            let computedNames: Set<String> = ["get", "set", "_read", "read", "_modify", "modify"]
            return declarations.allSatisfy { !computedNames.contains($0.accessorSpecifier.text) }
        }
    }

    private static func isFileScope(_ node: VariableDeclSyntax) -> Bool {
        var ancestor = node.parent
        while let current = ancestor {
            if current.is(MemberBlockItemSyntax.self)
                || current.is(CodeBlockSyntax.self)
                || current.is(SwitchCaseSyntax.self)
                || current.is(FunctionDeclSyntax.self)
                || current.is(InitializerDeclSyntax.self)
                || current.is(AccessorDeclSyntax.self)
                || current.is(ClosureExprSyntax.self)
            {
                return false
            }
            if current.is(SourceFileSyntax.self) { return true }
            ancestor = current.parent
        }
        return false
    }
}
