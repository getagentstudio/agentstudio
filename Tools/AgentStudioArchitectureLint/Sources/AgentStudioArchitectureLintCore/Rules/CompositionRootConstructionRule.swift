import SwiftSyntax

/// Keeps the selected runtime identities at the startup composition boundary.
/// Tests may build the injectable owners, but may not construct the native app.
struct CompositionRootConstructionRule: ArchitectureRule {
    let id = "agentstudio_composition_root_construction"
    let severity = ArchitectureSeverity.error
    let message =
        "selected runtime identities must be constructed at their admitted startup or Terminal owner boundary"

    func validate(context: ArchitectureLintContext) -> [ArchitectureDiagnostic] {
        guard let path = context.workspaceRelativePath,
            path.hasPrefix("Sources/AgentStudio/") || path.hasPrefix("Tests/")
        else {
            return []
        }

        let visitor = CompositionRootConstructionVisitor(path: path, message: message)
        visitor.walk(context.sourceFile)
        return visitor.violations.map {
            diagnostic(context: context, position: $0.position, message: $0.message)
        }
    }
}

private final class CompositionRootConstructionVisitor: SyntaxVisitor {
    private static let appDelegatePath = "Sources/AgentStudio/App/Boot/AppDelegate.swift"
    private static let mainPath = "Sources/AgentStudio/main.swift"
    private static let startupPropertyNames: Set<String> = [
        "startupCommandDispatcher",
        "startupTerminalLookup",
        "startupNativeEngine",
        "startupCallbackHandling",
        "startupRuntimeRegistry",
    ]
    private static let nativeAppFactoryName = "ghostty_app_new"
    private static let nativeEngineBootMethodName = "initializeNativeEngineForBoot"

    private let path: String
    private let message: String
    private let isTestSource: Bool
    private(set) var violations: [ArchitectureViolation] = []

    init(path: String, message: String, viewMode: SyntaxTreeViewMode = .sourceAccurate) {
        self.path = path
        self.message = message
        self.isTestSource = path.hasPrefix("Tests/")
        super.init(viewMode: viewMode)
    }

    override func visitPost(_ node: FunctionCallExprSyntax) {
        if isTypedSelectedParameterDefault(node) {
            return
        }

        if Self.isNativeAppFactory(node.calledExpression) {
            if !isInsideNativeAppHandleInitializer(node) {
                record(node.calledExpression.positionAfterSkippingLeadingTrivia)
            }
            return
        }

        if Self.calledName(node.calledExpression) == Self.nativeEngineBootMethodName {
            if !isTopLevelMainConstruction(node) {
                record(node.calledExpression.positionAfterSkippingLeadingTrivia)
            }
            return
        }

        guard let target = constructedTarget(for: node) else { return }
        guard isAdmitted(target: target, at: node) else {
            record(node.calledExpression.positionAfterSkippingLeadingTrivia)
            return
        }
    }

    override func visitPost(_ node: MemberAccessExprSyntax) {
        if node.declName.baseName.text == "init",
            constructorTarget(for: node.base, around: node) != nil,
            !Self.isDirectCall(node)
        {
            record(node.positionAfterSkippingLeadingTrivia)
            return
        }

        if node.declName.baseName.text == Self.nativeEngineBootMethodName,
            !Self.isDirectCall(node)
        {
            record(node.positionAfterSkippingLeadingTrivia)
            return
        }

        if node.declName.baseName.text == Self.nativeAppFactoryName,
            !Self.isDirectCall(node)
        {
            record(node.positionAfterSkippingLeadingTrivia)
        }
    }

    override func visitPost(_ node: DeclReferenceExprSyntax) {
        guard node.baseName.text == Self.nativeAppFactoryName,
            !Self.isDirectCall(node)
        else {
            return
        }
        record(node.positionAfterSkippingLeadingTrivia)
    }

    override func visitPost(_ node: TypeAliasDeclSyntax) {
        let context = CompositionRootConstructionContext(around: node)
        guard context.target(for: node.initializer.value) != nil else {
            return
        }
        record(node.initializer.value.positionAfterSkippingLeadingTrivia)
    }

    override func visitPost(_ node: FunctionParameterSyntax) {
        let context = CompositionRootConstructionContext(around: node)
        guard let target = context.target(for: node.type),
            let defaultValue = node.defaultValue?.value,
            Self.isSharedDefault(defaultValue, target: target, context: context)
                || defaultValue.is(FunctionCallExprSyntax.self)
        else {
            return
        }
        record(defaultValue.positionAfterSkippingLeadingTrivia)
    }

    override func visitPost(_ node: SequenceExprSyntax) {
        guard let assignment = ExprSyntax(node).assignment,
            let propertyName = Self.assignedPropertyName(assignment.target),
            Self.startupPropertyNames.contains(propertyName),
            !isInsideAppDelegateInitializer(assignment.target)
        else {
            return
        }
        record(assignment.target.positionAfterSkippingLeadingTrivia)
    }

    private func isAdmitted(target: CompositionRootConstructionTarget, at node: FunctionCallExprSyntax) -> Bool {
        if isTestSource {
            return target.mayBeConstructedByTests && Self.isOwnedTestConstruction(node)
        }

        switch target {
        case .nativeEngine:
            return isTopLevelMainConstruction(node) || isAppDelegateConstruction(node, target: target)
        case .callbackHandling, .commandDispatcher, .runtimeRegistry, .terminalLookup:
            return isAppDelegateConstruction(node, target: target)
        case .nativeAppHandle:
            return isInsideGhosttyAppInitializer(node)
        }
    }

    private func isTopLevelMainConstruction(_ node: some SyntaxProtocol) -> Bool {
        guard path == Self.mainPath else { return false }
        var ancestor = node.parent
        while let current = ancestor {
            if current.is(FunctionDeclSyntax.self)
                || current.is(InitializerDeclSyntax.self)
                || current.is(ClosureExprSyntax.self)
                || current.is(MemberBlockSyntax.self)
                || current.is(ClassDeclSyntax.self)
                || current.is(StructDeclSyntax.self)
                || current.is(EnumDeclSyntax.self)
                || current.is(ActorDeclSyntax.self)
            {
                return false
            }
            ancestor = current.parent
        }
        return true
    }

    private func isAppDelegateConstruction(
        _ node: some SyntaxProtocol,
        target: CompositionRootConstructionTarget
    ) -> Bool {
        guard path == Self.appDelegatePath else { return false }
        if isInsideAppDelegateInitializer(node) {
            return target != .nativeAppHandle
        }

        guard let propertyName = Self.enclosingDirectMemberPropertyName(node),
            propertyName == target.startupPropertyName,
            let declaration = Self.directAppDelegateMemberDeclaration(node),
            Self.allowsStartupPropertyDeclaration(declaration, for: target)
        else {
            return false
        }
        return true
    }

    private func isInsideAppDelegateInitializer(_ node: some SyntaxProtocol) -> Bool {
        guard path == Self.appDelegatePath,
            let initializer = Self.enclosingInitializer(node),
            CompositionRootConstructionContext(around: initializer).hasExactTypePath(["AppDelegate"])
        else {
            return false
        }
        return true
    }

    private func isInsideGhosttyAppInitializer(_ node: some SyntaxProtocol) -> Bool {
        guard path.hasPrefix("Sources/AgentStudio/Features/Terminal/Ghostty/"),
            let initializer = Self.enclosingInitializer(node),
            CompositionRootConstructionContext(around: initializer).hasNearestTypePath(["Ghostty", "App"])
        else {
            return false
        }
        return true
    }

    private func isInsideNativeAppHandleInitializer(_ node: some SyntaxProtocol) -> Bool {
        guard !isTestSource,
            path.hasPrefix("Sources/AgentStudio/Features/Terminal/Ghostty/"),
            let initializer = Self.enclosingInitializer(node),
            CompositionRootConstructionContext(around: initializer).hasNearestTypePath(["Ghostty", "AppHandle"])
        else {
            return false
        }
        return true
    }

    private func record(_ position: AbsolutePosition) {
        violations.append(
            ArchitectureViolation(
                position: position,
                message: message
            )
        )
    }

    private func constructedTarget(for node: FunctionCallExprSyntax) -> CompositionRootConstructionTarget? {
        let context = CompositionRootConstructionContext(around: node)
        if let memberAccess = node.calledExpression.as(MemberAccessExprSyntax.self),
            memberAccess.declName.baseName.text == "init"
        {
            if let base = memberAccess.base {
                return context.target(for: base)
            }
            return inferredTarget(for: node)
        }

        return context.target(for: node.calledExpression)
    }

    private func isTypedSelectedParameterDefault(_ node: FunctionCallExprSyntax) -> Bool {
        var ancestor = node.parent
        while let current = ancestor {
            if let parameter = current.as(FunctionParameterSyntax.self),
                parameter.defaultValue?.value.id == node.id
            {
                return CompositionRootConstructionContext(around: parameter).target(for: parameter.type) != nil
            }
            if current.is(FunctionDeclSyntax.self) { return false }
            ancestor = current.parent
        }
        return false
    }

    private func inferredTarget(for node: FunctionCallExprSyntax) -> CompositionRootConstructionTarget? {
        let context = CompositionRootConstructionContext(around: node)
        var ancestor = node.parent
        while let current = ancestor {
            if let binding = current.as(PatternBindingSyntax.self), let annotation = binding.typeAnnotation {
                return context.target(for: annotation.type)
            }
            if let parameter = current.as(FunctionParameterSyntax.self) {
                return context.target(for: parameter.type)
            }
            if let function = current.as(FunctionDeclSyntax.self),
                let returnType = function.signature.returnClause?.type
            {
                return context.target(for: returnType)
            }
            if current.is(FunctionDeclSyntax.self) || current.is(InitializerDeclSyntax.self) {
                break
            }
            ancestor = current.parent
        }
        return nil
    }

    private func constructorTarget(for expression: ExprSyntax?, around node: some SyntaxProtocol)
        -> CompositionRootConstructionTarget?
    {
        let context = CompositionRootConstructionContext(around: node)
        if let expression {
            return context.target(for: expression)
        }
        return context.targetForImplicitInitializer()
    }

    private static func isNativeAppFactory(_ expression: ExprSyntax) -> Bool {
        calledName(expression) == nativeAppFactoryName
    }

    private static func calledName(_ expression: ExprSyntax) -> String? {
        if let reference = expression.as(DeclReferenceExprSyntax.self) {
            return reference.baseName.text
        }
        if let memberAccess = expression.as(MemberAccessExprSyntax.self) {
            return memberAccess.declName.baseName.text
        }
        return nil
    }

    private static func isDirectCall(_ node: DeclReferenceExprSyntax) -> Bool {
        guard let parent = node.parent?.as(FunctionCallExprSyntax.self) else { return false }
        return parent.calledExpression.id == node.id
    }

    private static func isDirectCall(_ node: MemberAccessExprSyntax) -> Bool {
        guard let parent = node.parent?.as(FunctionCallExprSyntax.self) else { return false }
        return parent.calledExpression.id == node.id
    }

    private static func isSharedDefault(
        _ expression: ExprSyntax,
        target: CompositionRootConstructionTarget,
        context: CompositionRootConstructionContext
    ) -> Bool {
        guard let memberAccess = expression.as(MemberAccessExprSyntax.self),
            memberAccess.declName.baseName.text == "shared"
        else {
            return false
        }
        guard let base = memberAccess.base else { return true }
        return context.target(for: base) == target
    }

    private static func isOwnedTestConstruction(_ node: FunctionCallExprSyntax) -> Bool {
        var ancestor = node.parent
        while let current = ancestor {
            if current.is(FunctionParameterSyntax.self) { return false }
            if current.is(FunctionDeclSyntax.self) || current.is(InitializerDeclSyntax.self) {
                break
            }
            ancestor = current.parent
        }

        guard let binding = enclosingPatternBinding(node),
            let declaration = binding.parent?.parent?.as(VariableDeclSyntax.self)
        else {
            return true
        }

        if declaration.modifiers.contains(where: { modifier in
            modifier.trimmedDescription == "static" || modifier.trimmedDescription == "class"
        }) {
            return false
        }
        return !isFileScope(declaration)
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

    private static func assignedPropertyName(_ expression: ExprSyntax) -> String? {
        if let reference = expression.as(DeclReferenceExprSyntax.self) {
            return reference.baseName.text
        }
        if let memberAccess = expression.as(MemberAccessExprSyntax.self) {
            return memberAccess.declName.baseName.text
        }
        return nil
    }

    private static func enclosingDirectMemberPropertyName(_ node: some SyntaxProtocol) -> String? {
        var ancestor = node.parent
        while let current = ancestor {
            if let binding = current.as(PatternBindingSyntax.self),
                let identifier = binding.pattern.as(IdentifierPatternSyntax.self)
            {
                return identifier.identifier.text
            }
            if current.is(FunctionDeclSyntax.self)
                || current.is(InitializerDeclSyntax.self)
            {
                return nil
            }
            ancestor = current.parent
        }
        return nil
    }

    private static func directAppDelegateMemberDeclaration(_ node: some SyntaxProtocol) -> VariableDeclSyntax? {
        guard let binding = enclosingPatternBinding(node),
            let declaration = binding.parent?.parent?.as(VariableDeclSyntax.self)
        else {
            return nil
        }
        var ancestor = declaration.parent
        while let current = ancestor {
            if current.is(FunctionDeclSyntax.self)
                || current.is(InitializerDeclSyntax.self)
                || current.is(CodeBlockSyntax.self)
            {
                return nil
            }
            if let classDeclaration = current.as(ClassDeclSyntax.self) {
                guard classDeclaration.name.text == "AppDelegate",
                    CompositionRootConstructionContext(around: declaration).hasExactTypePath(["AppDelegate"])
                else {
                    return nil
                }
                return declaration
            }
            ancestor = current.parent
        }
        return nil
    }

    private static func allowsStartupPropertyDeclaration(
        _ declaration: VariableDeclSyntax,
        for target: CompositionRootConstructionTarget
    ) -> Bool {
        let isStaticStorage = declaration.modifiers.contains { modifier in
            modifier.name.tokenKind == .keyword(.static) || modifier.name.tokenKind == .keyword(.class)
        }
        guard !isStaticStorage else { return false }

        switch target {
        case .runtimeRegistry:
            return declaration.bindingSpecifier.tokenKind == .keyword(.let)
        case .nativeEngine, .callbackHandling, .commandDispatcher, .terminalLookup:
            let isPrivate = declaration.modifiers.contains {
                $0.name.tokenKind == .keyword(.private) && $0.detail == nil
            }
            let isLazy = declaration.modifiers.contains { $0.name.tokenKind == .keyword(.lazy) }
            return declaration.bindingSpecifier.tokenKind == .keyword(.var) && isPrivate && isLazy
        case .nativeAppHandle:
            return false
        }
    }

    private static func enclosingPatternBinding(_ node: some SyntaxProtocol) -> PatternBindingSyntax? {
        var ancestor = node.parent
        while let current = ancestor {
            if let binding = current.as(PatternBindingSyntax.self) { return binding }
            if current.is(FunctionDeclSyntax.self) || current.is(InitializerDeclSyntax.self) {
                return nil
            }
            ancestor = current.parent
        }
        return nil
    }

    private static func enclosingInitializer(_ node: some SyntaxProtocol) -> InitializerDeclSyntax? {
        var ancestor = node.parent
        while let current = ancestor {
            if let initializer = current.as(InitializerDeclSyntax.self) { return initializer }
            if current.is(FunctionDeclSyntax.self) { return nil }
            ancestor = current.parent
        }
        return nil
    }

}
