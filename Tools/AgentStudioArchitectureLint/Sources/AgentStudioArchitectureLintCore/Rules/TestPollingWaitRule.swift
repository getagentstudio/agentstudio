import SwiftSyntax

/// A polling wait is a loop that repeats around a scheduler yield, a sleep, or a
/// clock deadline until a condition holds. Its verdict is a function of how fast
/// the machine is: the same loop that clears in three turns on a sixteen-core
/// developer Mac can still be in flight when the budget expires on a three-core
/// runner, where the cooperative pool has three threads and the work the loop is
/// waiting for is queued behind the loop itself.
///
/// The shape is what makes it wrong, not the helper's name, so this rule matches
/// the shape: a `while`, `for`, or `repeat` whose own condition or body contains
/// a yield, a `sleep` call, or a wall-clock read. `for await` over a stream is
/// not a poll — it suspends on delivery — and a loop with none of those signals
/// is just a loop.
///
/// The permitted forms are in
/// `docs/architecture/testing/testing_architecture.md#how-a-test-may-wait`.
/// Existing polling waits are frozen per file by count in the debt ledger.
struct TestPollingWaitRule: ArchitectureRule {
    let id = "agentstudio_no_polling_wait_in_tests"
    let severity = ArchitectureSeverity.error
    let message =
        "Polling wait: a loop around a yield, sleep, or clock deadline decides a test by machine speed"

    func validate(context: ArchitectureLintContext) -> [ArchitectureDiagnostic] {
        guard let targetPath = Self.targetPath(for: context),
            targetPath.contains("/Tests/"), targetPath.hasSuffix(".swift")
        else {
            return []
        }

        let clockBindingNames = ClockBindingCollector.names(in: context.sourceFile)
        let visitor = TestPollingWaitVisitor(clockBindingNames: clockBindingNames)
        visitor.walk(context.sourceFile)
        return visitor.violations.map {
            diagnostic(context: context, position: $0.position, message: $0.message)
        }
    }

    private static func targetPath(for context: ArchitectureLintContext) -> String? {
        let normalizedPath = context.normalizedPath
        let pathForFixtureMatching = normalizedPath.hasPrefix("/") ? normalizedPath : "/\(normalizedPath)"
        for marker in ["/Fixtures/Bad/", "/Fixtures/Good/"] {
            if let range = pathForFixtureMatching.range(of: marker) {
                return "/\(pathForFixtureMatching[range.upperBound...])"
            }
        }
        guard let relativePath = context.workspaceRelativePath else {
            return nil
        }
        return relativePath.hasPrefix("/") ? relativePath : "/\(relativePath)"
    }
}

/// Finds loops that own a polling signal at their own nesting level.
///
/// Nested loops are each judged on their own: the signal search stops at a
/// nested loop, so an outer `for` over panes is not blamed for the inner `while`
/// that actually polls, and the inner loop still gets its own diagnostic.
private final class TestPollingWaitVisitor: SyntaxVisitor {
    private(set) var violations: [ArchitectureViolation] = []
    private let clockBindingNames: Set<String>

    init(clockBindingNames: Set<String>) {
        self.clockBindingNames = clockBindingNames
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: WhileStmtSyntax) -> SyntaxVisitorContinueKind {
        // A `while` repeats until its condition holds, so any of the three
        // signals anywhere inside it is the wait.
        recordIfPolling(
            keyword: node.whileKeyword,
            signals: PollingSignalVisitor.signals(
                in: [Syntax(node.conditions), Syntax(node.body)],
                clockBindingNames: clockBindingNames
            )
        )
        return .visitChildren
    }

    override func visit(_ node: ForStmtSyntax) -> SyntaxVisitorContinueKind {
        // `for await` suspends until the stream delivers; that is the permitted
        // form, not a poll.
        guard node.awaitKeyword == nil else {
            return .visitChildren
        }
        // A `for` already ends on its own. It is a wait only when the body
        // yields or sleeps each turn, or when its own control expressions read
        // a clock — a `for` body that stamps a fixture with `ContinuousClock().now`
        // is building data, not waiting.
        var controlExpressions: [Syntax] = [Syntax(node.sequence)]
        if let whereClause = node.whereClause {
            controlExpressions.append(Syntax(whereClause))
        }
        var signals = PollingSignalVisitor.signals(
            in: controlExpressions,
            clockBindingNames: clockBindingNames
        )
        signals.formUnion(
            PollingSignalVisitor.signals(in: [Syntax(node.body)], clockBindingNames: clockBindingNames)
                .subtracting([.clockRead])
        )
        recordIfPolling(keyword: node.forKeyword, signals: signals)
        return .visitChildren
    }

    override func visit(_ node: RepeatStmtSyntax) -> SyntaxVisitorContinueKind {
        recordIfPolling(
            keyword: node.repeatKeyword,
            signals: PollingSignalVisitor.signals(
                in: [Syntax(node.body), Syntax(node.condition)],
                clockBindingNames: clockBindingNames
            )
        )
        return .visitChildren
    }

    private func recordIfPolling(keyword: TokenSyntax, signals: Set<PollingSignal>) {
        guard !signals.isEmpty else {
            return
        }
        violations.append(
            ArchitectureViolation(
                position: keyword.positionAfterSkippingLeadingTrivia,
                message:
                    "Polling wait: a loop around a yield, sleep, or clock deadline decides a test by "
                    + "machine speed. Await the owner's typed fact, the event, or the observed state instead — "
                    + "docs/architecture/testing/testing_architecture.md#how-a-test-may-wait"
            )
        )
    }
}

private enum PollingSignal {
    case yield
    case sleep
    case clockRead
}

/// Names bound to a clock construction or a clock-typed parameter/annotation in
/// this file. `.now` on those bindings is a wall-clock read even when the
/// identifier does not contain `clock`.
private enum ClockBindingCollector {
    static func names(in sourceFile: SourceFileSyntax) -> Set<String> {
        let collector = ClockBindingVisitor()
        collector.walk(sourceFile)
        return collector.names
    }
}

private final class ClockBindingVisitor: SyntaxVisitor {
    private(set) var names: Set<String> = []

    override init(viewMode: SyntaxTreeViewMode = .sourceAccurate) {
        super.init(viewMode: viewMode)
    }

    override func visitPost(_ node: PatternBindingSyntax) {
        guard let identifier = node.pattern.as(IdentifierPatternSyntax.self)?.identifier.text else {
            return
        }
        if node.initializer?.value.isClockConstruction == true {
            names.insert(identifier)
        }
        if node.typeAnnotation?.type.namesAClockType == true {
            names.insert(identifier)
        }
    }

    override func visitPost(_ node: FunctionParameterSyntax) {
        let parameterName = node.secondName?.text ?? node.firstName.text
        guard parameterName != "_", node.type.namesAClockType else {
            return
        }
        names.insert(parameterName)
    }
}

/// Collects the polling signals present in the searched syntax, without
/// descending into a nested loop — each loop is judged on what it owns itself.
private final class PollingSignalVisitor: SyntaxVisitor {
    private(set) var signals: Set<PollingSignal> = []
    private let clockBindingNames: Set<String>

    static func signals(in searched: [Syntax], clockBindingNames: Set<String>) -> Set<PollingSignal> {
        var found: Set<PollingSignal> = []
        for syntax in searched {
            let visitor = PollingSignalVisitor(clockBindingNames: clockBindingNames)
            visitor.walk(syntax)
            found.formUnion(visitor.signals)
        }
        return found
    }

    init(clockBindingNames: Set<String>) {
        self.clockBindingNames = clockBindingNames
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: WhileStmtSyntax) -> SyntaxVisitorContinueKind { .skipChildren }
    override func visit(_ node: ForStmtSyntax) -> SyntaxVisitorContinueKind { .skipChildren }
    override func visit(_ node: RepeatStmtSyntax) -> SyntaxVisitorContinueKind { .skipChildren }

    override func visitPost(_ node: FunctionCallExprSyntax) {
        if let memberAccess = node.calledExpression.as(MemberAccessExprSyntax.self) {
            let calleeName = memberAccess.declName.baseName.text
            if calleeName == "sleep" {
                signals.insert(.sleep)
                return
            }
            if calleeName == "yield", memberAccess.base?.isTaskTypeReference == true {
                signals.insert(.yield)
                return
            }
            return
        }
        guard let reference = node.calledExpression.as(DeclReferenceExprSyntax.self) else {
            return
        }
        if reference.baseName.text == "sleep" || reference.baseName.text == "usleep" {
            signals.insert(.sleep)
            return
        }
        if reference.baseName.text == "CFAbsoluteTimeGetCurrent" {
            signals.insert(.clockRead)
            return
        }
        // Bare `Date()` reads the wall clock. `Date(timeIntervalSince1970:)` and
        // every other argument form builds a fixed instant, which is a fixture
        // value, not a deadline.
        if reference.baseName.text == "Date", node.arguments.isEmpty, node.trailingClosure == nil {
            signals.insert(.clockRead)
        }
    }

    override func visitPost(_ node: MemberAccessExprSyntax) {
        if node.declName.baseName.text == "systemUptime" {
            signals.insert(.clockRead)
            return
        }
        guard node.declName.baseName.text == "now" else {
            return
        }
        if node.base?.namesAClock == true {
            signals.insert(.clockRead)
            return
        }
        if let reference = node.base?.as(DeclReferenceExprSyntax.self),
            clockBindingNames.contains(reference.baseName.text)
        {
            signals.insert(.clockRead)
        }
    }
}

private enum ClockTypeName {
    static let exact: Set<String> = [
        "ContinuousClock",
        "SuspendingClock",
        "DispatchTime",
        "Date",
    ]
    static let constructable: Set<String> = [
        "ContinuousClock",
        "SuspendingClock",
    ]
}

extension ExprSyntax {
    /// The expression names a type a wall-clock instant can be read from:
    /// `ContinuousClock`, `SuspendingClock`, `DispatchTime`, `Date`, or a
    /// spelling that contains `clock`. Bindings of those types are collected
    /// separately so `ticker.now` is a clock read without relying on the local
    /// name.
    fileprivate var namesAClock: Bool {
        if let reference = self.as(DeclReferenceExprSyntax.self) {
            let name = reference.baseName.text
            return ClockTypeName.exact.contains(name)
                || name.containsIgnoringASCIICase("clock")
        }
        if let call = self.as(FunctionCallExprSyntax.self) {
            return call.calledExpression.namesAClock
        }
        if let memberAccess = self.as(MemberAccessExprSyntax.self) {
            let name = memberAccess.declName.baseName.text
            return ClockTypeName.exact.contains(name)
                || name.containsIgnoringASCIICase("clock")
                || memberAccess.base?.namesAClock == true
        }
        return false
    }

    fileprivate var isClockConstruction: Bool {
        guard let call = self.as(FunctionCallExprSyntax.self) else {
            return false
        }
        if let reference = call.calledExpression.as(DeclReferenceExprSyntax.self) {
            return ClockTypeName.constructable.contains(reference.baseName.text)
        }
        if let memberAccess = call.calledExpression.as(MemberAccessExprSyntax.self) {
            return ClockTypeName.constructable.contains(memberAccess.declName.baseName.text)
        }
        return false
    }
}

extension TypeSyntax {
    fileprivate var namesAClockType: Bool {
        if let identifier = self.as(IdentifierTypeSyntax.self) {
            let name = identifier.name.text
            return ClockTypeName.exact.contains(name)
                || name.containsIgnoringASCIICase("clock")
        }
        if let member = self.as(MemberTypeSyntax.self) {
            let name = member.name.text
            return ClockTypeName.exact.contains(name)
                || name.containsIgnoringASCIICase("clock")
                || member.baseType.namesAClockType
        }
        if let someOrAny = self.as(SomeOrAnyTypeSyntax.self) {
            return someOrAny.constraint.namesAClockType
        }
        if let attributed = self.as(AttributedTypeSyntax.self) {
            return attributed.baseType.namesAClockType
        }
        if let optional = self.as(OptionalTypeSyntax.self) {
            return optional.wrappedType.namesAClockType
        }
        return false
    }
}
