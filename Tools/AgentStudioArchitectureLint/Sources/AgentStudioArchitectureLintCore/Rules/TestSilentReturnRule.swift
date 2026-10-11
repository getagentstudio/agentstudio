import SwiftSyntax

/// A guard in a test body must report a failed setup condition before it
/// returns. A bare return makes a broken prerequisite look like a passing test.
struct TestSilentReturnRule: ArchitectureRule {
    let id = "agentstudio_no_silent_test_return"
    let severity = ArchitectureSeverity.error
    let message =
        "Test guard failures record an issue, expectation, throw, or fatal error before returning"

    func validate(context: ArchitectureLintContext) -> [ArchitectureDiagnostic] {
        guard context.isTestSourceOutsideHarness else {
            return []
        }
        let visitor = SilentTestReturnVisitor()
        visitor.walk(context.sourceFile)
        return visitor.positions.map { diagnostic(context: context, position: $0) }
    }
}

private final class SilentTestReturnVisitor: SyntaxVisitor {
    private(set) var positions: [AbsolutePosition] = []

    override init(viewMode: SyntaxTreeViewMode = .sourceAccurate) {
        super.init(viewMode: viewMode)
    }

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        guard node.attributes.contains(where: Self.isTestAttribute), let body = node.body else {
            return .visitChildren
        }

        let guardVisitor = TestBodyGuardVisitor()
        guardVisitor.walk(body)
        positions.append(contentsOf: guardVisitor.positions)
        return .skipChildren
    }

    private static func isTestAttribute(_ element: AttributeListSyntax.Element) -> Bool {
        guard let attribute = element.as(AttributeSyntax.self) else {
            return false
        }
        return attribute.trimmedDescription.hasPrefix("@Test")
    }
}

private final class TestBodyGuardVisitor: SyntaxVisitor {
    private(set) var positions: [AbsolutePosition] = []

    override init(viewMode: SyntaxTreeViewMode = .sourceAccurate) {
        super.init(viewMode: viewMode)
    }

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        // A nested helper owns its own return; it is not the test verdict.
        .skipChildren
    }

    override func visitPost(_ node: GuardStmtSyntax) {
        guard node.body.statements.contains(where: Self.isBareReturn),
            !FailureSignalVisitor.containsFailureSignal(in: Syntax(node.body))
        else {
            return
        }
        positions.append(node.positionAfterSkippingLeadingTrivia)
    }

    private static func isBareReturn(_ item: CodeBlockItemSyntax) -> Bool {
        guard let returnStatement = item.item.as(ReturnStmtSyntax.self) else {
            return false
        }
        return returnStatement.expression == nil
    }
}

private final class FailureSignalVisitor: SyntaxVisitor {
    private(set) var foundFailureSignal = false

    static func containsFailureSignal(in syntax: Syntax) -> Bool {
        let visitor = Self()
        visitor.walk(syntax)
        return visitor.foundFailureSignal
    }

    override init(viewMode: SyntaxTreeViewMode = .sourceAccurate) {
        super.init(viewMode: viewMode)
    }

    override func visit(_ node: MacroExpansionExprSyntax) -> SyntaxVisitorContinueKind {
        if ["expect", "require"].contains(node.macroName.text) {
            foundFailureSignal = true
        }
        return .visitChildren
    }

    override func visit(_ node: ThrowStmtSyntax) -> SyntaxVisitorContinueKind {
        foundFailureSignal = true
        return .skipChildren
    }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        let calleeName: String?
        let isIssueRecord: Bool
        if let reference = node.calledExpression.as(DeclReferenceExprSyntax.self) {
            calleeName = reference.baseName.text
            isIssueRecord = false
        } else if let member = node.calledExpression.as(MemberAccessExprSyntax.self) {
            calleeName = member.declName.baseName.text
            let base = member.base?.trimmedDescription ?? ""
            isIssueRecord = calleeName == "record" && (base == "Issue" || base.hasSuffix(".Issue"))
        } else {
            calleeName = nil
            isIssueRecord = false
        }

        if calleeName == "fatalError" || isIssueRecord {
            foundFailureSignal = true
        }
        return .visitChildren
    }
}
