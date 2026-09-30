import SwiftSyntax

/// Test doubles wait through the typed-fact harness so failures have an owner
/// and the hang report can name the missing fact. Hand-built continuations
/// hide that missing fact behind an unbounded suspension.
struct AdHocContinuationWaitRule: ArchitectureRule {
    private static let continuationFunctionNames: Set<String> = [
        "withCheckedContinuation",
        "withCheckedThrowingContinuation",
        "withUnsafeContinuation",
        "withUnsafeThrowingContinuation",
    ]
    private static let continuationTypeNames: Set<String> = [
        "CheckedContinuation",
        "UnsafeContinuation",
    ]

    let id = "agentstudio_no_adhoc_continuation_wait"
    let severity = ArchitectureSeverity.error
    let message =
        "Hand-built continuation waiter: a test double that parks a continuation has no failure path and hides "
        + "the missing fact from the hang report. Use HeldStep, FactRecorder expectations, or H12 discovery "
        + "instead — docs/architecture/testing/testing_architecture.md#typed-facts"

    func validate(context: ArchitectureLintContext) -> [ArchitectureDiagnostic] {
        guard context.isRepositoryTestSourceOutsideHarness else {
            return []
        }

        let visitor = AdHocContinuationWaitVisitor()
        visitor.walk(context.sourceFile)
        return visitor.positions.map { diagnostic(context: context, position: $0) }
    }

    fileprivate static func isContinuationFunction(_ name: String) -> Bool {
        continuationFunctionNames.contains(name)
    }

    fileprivate static func isContinuationType(_ name: String) -> Bool {
        continuationTypeNames.contains(name)
    }
}

extension ArchitectureLintContext {
    fileprivate var isRepositoryTestSourceOutsideHarness: Bool {
        let path = workspaceRelativePath ?? normalizedPath
        let testPath = "/\(path)"
        let isUnderRepositoryTests =
            workspaceRelativePath.map { $0.hasPrefix("Tests/") }
            ?? testPath.contains("/Tests/")
        return isUnderRepositoryTests
            && testPath.hasSuffix(".swift")
            && !testPath.contains("/Tests/AgentStudioTestHarness/")
    }
}

private final class AdHocContinuationWaitVisitor: SyntaxVisitor {
    private(set) var positions: [AbsolutePosition] = []

    override init(viewMode: SyntaxTreeViewMode = .sourceAccurate) {
        super.init(viewMode: viewMode)
    }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        let calledName =
            node.calledExpression.as(DeclReferenceExprSyntax.self)?.baseName
            ?? node.calledExpression.as(MemberAccessExprSyntax.self)?.declName.baseName
        if let calledName, AdHocContinuationWaitRule.isContinuationFunction(calledName.text) {
            positions.append(calledName.positionAfterSkippingLeadingTrivia)
        }
        return .visitChildren
    }

    override func visitPost(_ node: VariableDeclSyntax) {
        guard node.parent?.is(MemberBlockItemSyntax.self) == true else {
            return
        }

        for binding in node.bindings where Self.isStoredProperty(binding) {
            guard let propertyType = binding.typeAnnotation?.type else {
                continue
            }
            let typeVisitor = ContinuationTypeNameVisitor()
            typeVisitor.walk(propertyType)
            if let continuationName = typeVisitor.names.first {
                positions.append(continuationName.positionAfterSkippingLeadingTrivia)
            }
        }
    }

    private static func isStoredProperty(_ binding: PatternBindingSyntax) -> Bool {
        guard let accessorBlock = binding.accessorBlock else {
            return true
        }
        switch accessorBlock.accessors {
        case .getter:
            return false
        case .accessors(let accessors):
            let accessorNames = Set(accessors.map(\.accessorSpecifier.text))
            let computedAccessorNames = Set(["get", "set", "_read", "read", "_modify", "modify"])
            return accessorNames.isDisjoint(with: computedAccessorNames)
        }
    }
}

private final class ContinuationTypeNameVisitor: SyntaxVisitor {
    private(set) var names: [TokenSyntax] = []

    override init(viewMode: SyntaxTreeViewMode = .sourceAccurate) {
        super.init(viewMode: viewMode)
    }

    override func visit(_ node: IdentifierTypeSyntax) -> SyntaxVisitorContinueKind {
        record(node.name)
        return .visitChildren
    }

    override func visit(_ node: MemberTypeSyntax) -> SyntaxVisitorContinueKind {
        record(node.name)
        return .visitChildren
    }

    private func record(_ name: TokenSyntax) {
        if AdHocContinuationWaitRule.isContinuationType(name.text) {
            names.append(name)
        }
    }
}
