import SwiftSyntax

/// Dedicated threads do not inherit Swift Testing's task-local test context.
/// Expectations there become unattributed issues even when the owning test passes.
struct TestExpectationOffTestTaskRule: ArchitectureRule {
    let id = "agentstudio_no_expectation_off_test_task"
    let severity = ArchitectureSeverity.error
    let message = "return observations from the closure; assert in the test task"

    func validate(context: ArchitectureLintContext) -> [ArchitectureDiagnostic] {
        guard let targetPath = Self.targetPath(for: context),
            targetPath.contains("/Tests/"), targetPath.hasSuffix(".swift")
        else {
            return []
        }
        let visitor = OffTestTaskExpectationVisitor()
        visitor.walk(context.sourceFile)
        return visitor.expectationPositions.map { diagnostic(context: context, position: $0) }
    }

    private static func targetPath(for context: ArchitectureLintContext) -> String? {
        let normalizedPath = context.normalizedPath
        let pathForFixtureMatching = normalizedPath.hasPrefix("/") ? normalizedPath : "/\(normalizedPath)"
        for marker in ["/Fixtures/Bad/", "/Fixtures/Good/"] {
            if let range = pathForFixtureMatching.range(of: marker) {
                return "/\(pathForFixtureMatching[range.upperBound...])"
            }
        }
        guard let relativePath = context.workspaceRelativePath else { return nil }
        return relativePath.hasPrefix("/") ? relativePath : "/\(relativePath)"
    }
}

private final class OffTestTaskExpectationVisitor: SyntaxVisitor {
    private(set) var expectationPositions: [AbsolutePosition] = []
    private var offTaskClosureDepth = 0

    override init(viewMode: SyntaxTreeViewMode = .sourceAccurate) {
        super.init(viewMode: viewMode)
    }

    override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind {
        if node.isOffTestTaskClosureArgument { offTaskClosureDepth += 1 }
        return .visitChildren
    }

    override func visitPost(_ node: ClosureExprSyntax) {
        if node.isOffTestTaskClosureArgument { offTaskClosureDepth -= 1 }
    }

    override func visit(_ node: MacroExpansionExprSyntax) -> SyntaxVisitorContinueKind {
        if offTaskClosureDepth > 0, ["expect", "require"].contains(node.macroName.text) {
            expectationPositions.append(node.positionAfterSkippingLeadingTrivia)
        }
        return .visitChildren
    }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        if offTaskClosureDepth > 0,
            let member = node.calledExpression.as(MemberAccessExprSyntax.self),
            member.declName.baseName.text == "record", member.base?.namesTestingIssue == true
        {
            expectationPositions.append(member.positionAfterSkippingLeadingTrivia)
        }
        return .visitChildren
    }
}

extension ClosureExprSyntax {
    /// Only a closure supplied as an argument crosses this named hop. Eager
    /// argument expressions and closures passed to unrelated calls do not.
    fileprivate var isOffTestTaskClosureArgument: Bool {
        var ancestor = parent
        while let node = ancestor {
            if let call = node.as(FunctionCallExprSyntax.self) {
                guard call.calledExpression.namesOffTestTaskHelper else { return false }
                return call.trailingClosure?.id == id
                    || call.additionalTrailingClosures.contains { $0.closure.id == id }
                    || call.arguments.contains { argument in
                        var container: Syntax? = Syntax(self)
                        while let current = container {
                            if current.id == call.id { return false }
                            if current.id == argument.expression.id { return true }
                            container = current.parent
                        }
                        return false
                    }
            }
            if node.is(ClosureExprSyntax.self) || node.is(FunctionDeclSyntax.self) { return false }
            ancestor = node.parent
        }
        return false
    }
}

extension ExprSyntax {
    fileprivate var namesOffTestTaskHelper: Bool {
        let name: String?
        if let reference = self.as(DeclReferenceExprSyntax.self) {
            name = reference.baseName.text
        } else if let member = self.as(MemberAccessExprSyntax.self) {
            name = member.declName.baseName.text
        } else {
            name = nil
        }
        return name == "valueFromDedicatedThread" || name == "withoutBlockingCooperativePool"
    }

    fileprivate var namesTestingIssue: Bool {
        if let reference = self.as(DeclReferenceExprSyntax.self) {
            return reference.baseName.text == "Issue"
        }
        return self.as(MemberAccessExprSyntax.self)?.declName.baseName.text == "Issue"
    }
}
