import SwiftSyntax

/// A guard in a test body must report a failed setup condition before it
/// returns. A bare return makes a broken prerequisite look like a passing test.
/// The paired `#expect(E)` then `guard E else { return }` form is already a
/// named failure and is exempted only while the two expressions stay equal.
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

    override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind {
        // Callback and task closures own their returns; the test body does not.
        .skipChildren
    }

    override func visitPost(_ node: GuardStmtSyntax) {
        guard !hasPairedExpectation(for: node),
            SilentReturnPathVisitor.hasUnsignaledReturn(in: node.body)
        else {
            return
        }
        positions.append(node.positionAfterSkippingLeadingTrivia)
    }

    private func hasPairedExpectation(for node: GuardStmtSyntax) -> Bool {
        guard node.conditions.count == 1,
            let condition = node.conditions.first?.condition,
            let item = node.parent?.as(CodeBlockItemSyntax.self),
            let block = item.parent?.as(CodeBlockItemListSyntax.self)
        else {
            return false
        }

        guard let itemIndex = block.firstIndex(where: { $0.id == item.id }), itemIndex > block.startIndex else {
            return false
        }
        let previous = block[block.index(before: itemIndex)]
        guard let expectedExpression = Self.expectationExpression(in: previous) else {
            return false
        }
        return Self.normalized(expectedExpression) == Self.normalized(condition.trimmedDescription)
    }

    private static func expectationExpression(in item: CodeBlockItemSyntax) -> String? {
        let macro: MacroExpansionExprSyntax?
        if let direct = item.item.as(MacroExpansionExprSyntax.self) {
            macro = direct
        } else if let expression = item.item.as(ExpressionStmtSyntax.self) {
            macro = expression.expression.as(MacroExpansionExprSyntax.self)
        } else {
            macro = nil
        }
        guard let macro, macro.macroName.text == "expect", let firstArgument = macro.arguments.first else {
            return nil
        }
        return firstArgument.expression.trimmedDescription
    }

    private static func normalized(_ text: String) -> String {
        text.filter { !$0.isWhitespace }
    }
}

/// Walks the guard's else block one path at a time. Signals in one branch do
/// not suppress a bare return in a sibling branch, and nested functions or
/// closures are outside the guard's return paths.
private final class SilentReturnPathVisitor: SyntaxVisitor {
    private var signalStack: [Bool] = []
    private(set) var hasUnsignaledReturn = false

    static func hasUnsignaledReturn(in body: CodeBlockSyntax) -> Bool {
        let visitor = Self()
        visitor.walk(body)
        return visitor.hasUnsignaledReturn
    }

    override init(viewMode: SyntaxTreeViewMode = .sourceAccurate) {
        super.init(viewMode: viewMode)
    }

    override func visit(_ node: CodeBlockSyntax) -> SyntaxVisitorContinueKind {
        signalStack.append(signalStack.last ?? false)
        return .visitChildren
    }

    override func visitPost(_ node: CodeBlockSyntax) {
        signalStack.removeLast()
    }

    override func visit(_ node: SwitchCaseSyntax) -> SyntaxVisitorContinueKind {
        signalStack.append(signalStack.last ?? false)
        return .visitChildren
    }

    override func visitPost(_ node: SwitchCaseSyntax) {
        signalStack.removeLast()
    }

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        .skipChildren
    }

    override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind {
        .skipChildren
    }

    override func visit(_ node: ReturnStmtSyntax) -> SyntaxVisitorContinueKind {
        if node.expression == nil, signalStack.last != true {
            hasUnsignaledReturn = true
        }
        return .skipChildren
    }

    override func visit(_ node: MacroExpansionExprSyntax) -> SyntaxVisitorContinueKind {
        if ["expect", "require"].contains(node.macroName.text) {
            signalStack[signalStack.index(before: signalStack.endIndex)] = true
        }
        return .visitChildren
    }

    override func visit(_ node: ThrowStmtSyntax) -> SyntaxVisitorContinueKind {
        signalStack[signalStack.index(before: signalStack.endIndex)] = true
        return .skipChildren
    }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        let isFatalError: Bool
        let isIssueRecord: Bool
        if let reference = node.calledExpression.as(DeclReferenceExprSyntax.self) {
            isFatalError = reference.baseName.text == "fatalError"
            isIssueRecord = false
        } else if let member = node.calledExpression.as(MemberAccessExprSyntax.self) {
            isFatalError = member.declName.baseName.text == "fatalError"
            let base = member.base?.trimmedDescription ?? ""
            isIssueRecord =
                member.declName.baseName.text == "record"
                && (base == "Issue" || base.hasSuffix(".Issue"))
        } else {
            isFatalError = false
            isIssueRecord = false
        }
        if isFatalError || isIssueRecord {
            signalStack[signalStack.index(before: signalStack.endIndex)] = true
        }
        return .visitChildren
    }
}
