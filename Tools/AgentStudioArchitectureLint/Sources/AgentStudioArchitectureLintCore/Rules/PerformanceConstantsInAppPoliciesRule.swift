import SwiftSyntax

struct PerformanceConstantsInAppPoliciesRule: ArchitectureRule {
    let id = "agentstudio_performance_constants_in_app_policies"
    let severity = ArchitectureSeverity.error
    let message = "Performance thresholds and timing constants belong in AppPolicies"

    func validate(context: ArchitectureLintContext) -> [ArchitectureDiagnostic] {
        guard !context.normalizedPath.hasSuffix("/Sources/AgentStudio/Infrastructure/AppPolicies.swift"),
            !ArchitectureAllowlists.performanceConstantAllowedPathSuffixes.contains(
                where: context.normalizedPath.hasSuffix
            ),
            !ArchitectureAllowlists.performanceConstantPolicyHomes.contains(
                where: { context.normalizedPath.hasSuffix($0.pathSuffix) }
            )
        else { return [] }
        let visitor = PerformanceConstantVisitor()
        visitor.walk(context.sourceFile)
        return visitor.positions.map { diagnostic(context: context, position: $0) }
    }
}

private final class PerformanceConstantVisitor: SyntaxVisitor {
    private(set) var positions: [AbsolutePosition] = []
    private var appPoliciesDepth = 0

    override init(viewMode: SyntaxTreeViewMode = .sourceAccurate) {
        super.init(viewMode: viewMode)
    }

    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        if node.name.text == "AppPolicies" { appPoliciesDepth += 1 }
        return .visitChildren
    }

    override func visitPost(_ node: EnumDeclSyntax) {
        if node.name.text == "AppPolicies" { appPoliciesDepth -= 1 }
    }

    override func visitPost(_ node: VariableDeclSyntax) {
        guard appPoliciesDepth == 0 else { return }
        for binding in node.bindings {
            guard let identifier = binding.pattern.as(IdentifierPatternSyntax.self),
                binding.initializer?.value.is(IntegerLiteralExprSyntax.self) == true
                    || binding.initializer?.value.is(FloatLiteralExprSyntax.self) == true
            else { continue }
            let name = identifier.identifier.text.lowercased()
            guard
                ArchitectureAllowlists.performanceConstantNameFragments.contains(
                    where: name.contains
                )
            else { continue }
            positions.append(identifier.positionAfterSkippingLeadingTrivia)
        }
    }
}
