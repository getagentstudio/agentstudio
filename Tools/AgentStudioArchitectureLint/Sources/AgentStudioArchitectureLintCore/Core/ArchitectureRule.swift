import SwiftSyntax

protocol ArchitectureRule: Sendable {
    var id: String { get }
    var severity: ArchitectureSeverity { get }
    var message: String { get }

    func prepared(for contexts: [ArchitectureLintContext]) -> any ArchitectureRule
    func validate(context: ArchitectureLintContext) -> [ArchitectureDiagnostic]
    /// Problems with the rule's own allowances against the whole corpus,
    /// such as a named owner whose file is gone. Reported only by a full run,
    /// where every file is in scope, so a scoped run keeps full-run parity.
    func configurationDiagnostics() -> [ArchitectureDiagnostic]
}

extension ArchitectureRule {
    func prepared(for contexts: [ArchitectureLintContext]) -> any ArchitectureRule {
        self
    }

    func configurationDiagnostics() -> [ArchitectureDiagnostic] {
        []
    }

    func diagnostic(
        context: ArchitectureLintContext,
        position: AbsolutePosition,
        message: String? = nil
    ) -> ArchitectureDiagnostic {
        let location = context.location(for: position)
        return ArchitectureDiagnostic(
            path: context.path,
            line: location.line,
            column: location.column,
            severity: severity,
            ruleID: id,
            message: message ?? self.message
        )
    }
}

enum ArchitectureRuleRegistry {
    static let rules: [any ArchitectureRule] = [
        ImportDirectionRule(),
        OwnedToolbarControlRule(),
        RetiredWorktrunkCLIRule(),
        ProductAtomBoundaryRule(),
        CanonicalAtomMutationRule(),
        SharedComponentsStatelessRule(),
        AtomLibGenericRule(),
        DerivedAtomDeclaredInputsRule(),
        RepoCacheKeyedReadsRule(),
        HotPaneSnapshotReadsRule(),
        WorktreeEnrichmentComparatorRule(),
        StateActorPathRule(),
        IPCProgrammaticControlBoundaryRule(),
        AppIPCPortBoundaryRule(),
        IPCCompositionLocationRule(),
        FeatureAppIPCImportBoundaryRule(),
        IPCPublicSurfaceSanitizationRule(),
        IPCNoDirectAtomAccessRule(),
        ForbiddenArchitectureMarkerRule(),
        GenericClockSleepRule(),
        TestTaskSleepRule(),
        TestPollingWaitRule(),
        ForbiddenTestWaitRule(),
        AdHocContinuationWaitRule(),
        TestBlockingSocketIORule(),
        TestBlockingWaitOffCooperativePoolRule(),
        TestExpectationOffTestTaskRule(),
        ProcessSingletonRule(),
        TestElapsedTimeBudgetRule(),
        TestCoreAtomFallbackOwnershipRule(),
        CompletionHandleNotDiscardableRule(),
        TooltipSourceRule(),
        EventBusSubscriberPolicyRule(),
        TerminalLocalDispositionPublicationRule(),
        ComparisonTargetQueryControlProductionRule(),
        ObservationCaptureKeyedReadsRule(),
        MainActorUnboundedCollectionWorkRule(),
        PerformanceConstantsInAppPoliciesRule(),
        NonisolatedAsyncBlockingIORule(),
        ObservationRearmGuardedRule(),
        SwiftUIBodyDerivationRule(),
        AtomAssignOnlyRule(),
        MainActorHopPerElementRule(),
        ProbeReportsOffMainRule(),
        TestAdHocGateRule(),
        TestWaitHelperReturnsObservationRule(),
    ]

    static let documentRules: [any ArchitectureDocumentRule] = [
        AgentDocReferenceRule()
    ]
}
