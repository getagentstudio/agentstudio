import SwiftSyntax

struct IPCProgrammaticControlBoundaryRule: ArchitectureRule {
    let id = "agentstudio_ipc_programmatic_control_boundary"
    let severity = ArchitectureSeverity.error
    let message = "AgentStudioProgrammaticControl must remain transport/app/UI independent contract code"

    func validate(context: ArchitectureLintContext) -> [ArchitectureDiagnostic] {
        let classifier = AgentStudioPathClassifier(path: context.normalizedPath)
        guard classifier.isProgrammaticControlSource else {
            return []
        }

        var violations: [ArchitectureViolation] = []
        let importVisitor = ImportCollectingVisitor()
        importVisitor.walk(context.sourceFile)
        violations.append(contentsOf: importVisitor.imports.compactMap(programmaticControlImportViolation))

        let referenceVisitor = ReferenceCollectingVisitor()
        referenceVisitor.walk(context.sourceFile)
        violations.append(contentsOf: referenceVisitor.references.compactMap(programmaticControlReferenceViolation))

        return violations.map {
            diagnostic(context: context, position: $0.position, message: $0.message)
        }
    }

    private func programmaticControlImportViolation(_ importRecord: ImportRecord) -> ArchitectureViolation? {
        let importName = importRecord.path.joined(separator: ".")
        let deniedImports = Set(["AgentStudio", "AgentStudioAppIPC", "AppKit", "SwiftUI"])
        guard
            deniedImports.contains(importRecord.path.first ?? "")
                || deniedImports.contains(importName)
                || importName.contains(".App.")
                || importName.contains(".Core.")
                || importName.contains(".Features.")
        else {
            return nil
        }
        return ArchitectureViolation(
            position: importRecord.position,
            message: "Programmatic-control contracts must not import app, feature, runtime, AppKit, or SwiftUI modules"
        )
    }

    private func programmaticControlReferenceViolation(_ reference: ReferenceRecord) -> ArchitectureViolation? {
        let deniedNames = ArchitectureAllowlists.concreteAppRuntimeOwnerNames
            .union(["NSView", "NSWindow", "View"])
        guard deniedNames.contains(reference.name) else {
            return nil
        }
        return ArchitectureViolation(
            position: reference.position,
            message: "Programmatic-control contracts must not reference UI or concrete app/runtime owner types"
        )
    }
}

struct AppIPCPortBoundaryRule: ArchitectureRule {
    let id = "agentstudio_appipc_port_boundary"
    let severity = ArchitectureSeverity.error
    let message = "AgentStudioAppIPC must expose ports instead of importing concrete app/runtime owners"

    func validate(context: ArchitectureLintContext) -> [ArchitectureDiagnostic] {
        let classifier = AgentStudioPathClassifier(path: context.normalizedPath)
        guard classifier.isAppIPCSource else {
            return []
        }

        var violations: [ArchitectureViolation] = []
        let importVisitor = ImportCollectingVisitor()
        importVisitor.walk(context.sourceFile)
        violations.append(contentsOf: importVisitor.imports.compactMap(appIPCImportViolation))

        let referenceVisitor = ReferenceCollectingVisitor()
        referenceVisitor.walk(context.sourceFile)
        violations.append(contentsOf: referenceVisitor.references.compactMap(appIPCReferenceViolation))

        return violations.map {
            diagnostic(context: context, position: $0.position, message: $0.message)
        }
    }

    private func appIPCImportViolation(_ importRecord: ImportRecord) -> ArchitectureViolation? {
        let importName = importRecord.path.joined(separator: ".")
        guard
            importRecord.path.first == "AgentStudio"
                || importRecord.path.first == "AppKit"
                || importRecord.path.first == "SwiftUI"
                || importName.contains(".App.")
                || importName.contains(".Core.")
                || importName.contains(".Features.")
        else {
            return nil
        }
        return ArchitectureViolation(
            position: importRecord.position,
            message: "AppIPC must not import the executable, UI frameworks, features, or runtime-owner modules"
        )
    }

    private func appIPCReferenceViolation(_ reference: ReferenceRecord) -> ArchitectureViolation? {
        guard ArchitectureAllowlists.concreteAppRuntimeOwnerNames.contains(reference.name) else {
            return nil
        }
        return ArchitectureViolation(
            position: reference.position,
            message: "AppIPC must depend on protocol ports, not concrete app/runtime owner types"
        )
    }
}

struct IPCCompositionLocationRule: ArchitectureRule {
    let id = "agentstudio_ipc_composition_location"
    let severity = ArchitectureSeverity.error
    let message = "Concrete AppIPC port implementations and method contributions must live under App/IPCComposition"

    private let portProtocolNames = Set([
        "ApprovalPolicyStore",
        "PermissionApprovalPort",
        "AppIPCQueryPort",
        "AppIPCLayoutPort",
        "AppIPCRuntimePort",
        "AppIPCCommandPort",
        "AppIPCUIPresentationPort",
        "AppIPCWindowRenderPort",
        "AppIPCPermissionApprovalPort",
        "AppIPCEventPort",
    ])

    func validate(context: ArchitectureLintContext) -> [ArchitectureDiagnostic] {
        let classifier = AgentStudioPathClassifier(path: context.normalizedPath)
        guard classifier.isAgentStudioSource,
            !classifier.isIPCCompositionSource
        else {
            return []
        }

        var diagnostics: [ArchitectureDiagnostic] = []

        let inheritanceVisitor = InheritanceCollectingVisitor()
        inheritanceVisitor.walk(context.sourceFile)
        diagnostics.append(
            contentsOf: inheritanceVisitor.inheritedTypes.compactMap { inheritedType in
                let inheritedName = inheritedType.name.split(separator: ".").last.map(String.init) ?? inheritedType.name
                guard portProtocolNames.contains(inheritedName) || inheritedName.hasSuffix("AppIPCPort") else {
                    return nil
                }
                return diagnostic(
                    context: context,
                    position: inheritedType.position,
                    message: "Move concrete AppIPC port implementations under Sources/AgentStudio/App/IPCComposition"
                )
            })

        let contributionVisitor = AppIPCContributionConstructionVisitor()
        contributionVisitor.walk(context.sourceFile)
        diagnostics.append(
            contentsOf: contributionVisitor.constructions.map { construction in
                diagnostic(
                    context: context,
                    position: construction.position,
                    message: "Move AppIPC method contributions under Sources/AgentStudio/App/IPCComposition"
                )
            })

        return diagnostics
    }
}

private struct AppIPCContributionConstructionRecord {
    let position: AbsolutePosition
}

private final class AppIPCContributionConstructionVisitor: SyntaxVisitor {
    private(set) var constructions: [AppIPCContributionConstructionRecord] = []

    override init(viewMode: SyntaxTreeViewMode = .sourceAccurate) {
        super.init(viewMode: viewMode)
    }

    override func visitPost(_ node: FunctionCallExprSyntax) {
        guard node.calledExpression.appIPCContributionTypeName == "AppIPCMethodContribution" else {
            return
        }
        constructions.append(
            AppIPCContributionConstructionRecord(position: node.calledExpression.positionAfterSkippingLeadingTrivia)
        )
    }
}

extension ExprSyntax {
    fileprivate var appIPCContributionTypeName: String? {
        if let reference = self.as(DeclReferenceExprSyntax.self) {
            return reference.baseName.text
        }
        if let memberAccess = self.as(MemberAccessExprSyntax.self) {
            return memberAccess.declName.baseName.text
        }
        return nil
    }
}

struct FeatureAppIPCImportBoundaryRule: ArchitectureRule {
    let id = "agentstudio_features_do_not_import_appipc"
    let severity = ArchitectureSeverity.error
    let message = "Feature slices must not import AgentStudioAppIPC; app composition owns IPC adapters"

    func validate(context: ArchitectureLintContext) -> [ArchitectureDiagnostic] {
        let classifier = AgentStudioPathClassifier(path: context.normalizedPath)
        guard classifier.featureName != nil else {
            return []
        }

        let visitor = ImportCollectingVisitor()
        visitor.walk(context.sourceFile)
        return visitor.imports.compactMap { importRecord in
            guard importRecord.path.first == "AgentStudioAppIPC" else {
                return nil
            }
            return diagnostic(
                context: context,
                position: importRecord.position,
                message: "Features must expose capability seams for App/IPCComposition instead of importing AppIPC"
            )
        }
    }
}

struct IPCPublicSurfaceSanitizationRule: ArchitectureRule {
    let id = "agentstudio_ipc_public_surface_sanitization"
    let severity = ArchitectureSeverity.error
    let message = "Public IPC surfaces must not expose zmx names or raw runtime payload types"

    func validate(context: ArchitectureLintContext) -> [ArchitectureDiagnostic] {
        let classifier = AgentStudioPathClassifier(path: context.normalizedPath)
        guard classifier.isProgrammaticControlSource || classifier.isAppIPCSource else {
            return []
        }

        let visitor = IPCPublicSurfaceVisitor()
        visitor.walk(context.sourceFile)
        return visitor.violations.map {
            diagnostic(context: context, position: $0.position, message: $0.message)
        }
    }
}

private final class IPCPublicSurfaceVisitor: SyntaxVisitor {
    private(set) var violations: [ArchitectureViolation] = []

    override init(viewMode: SyntaxTreeViewMode = .sourceAccurate) {
        super.init(viewMode: viewMode)
    }

    override func visitPost(_ node: DeclReferenceExprSyntax) {
        guard ArchitectureAllowlists.rawRuntimePayloadNames.contains(node.baseName.text) else {
            return
        }
        violations.append(
            ArchitectureViolation(
                position: node.positionAfterSkippingLeadingTrivia,
                message: "Public IPC surfaces must use exported DTOs instead of raw runtime or zmx payload types"
            )
        )
    }

    override func visitPost(_ node: StringLiteralExprSyntax) {
        guard node.segments.description.contains("zmx.") else {
            return
        }
        violations.append(
            ArchitectureViolation(
                position: node.positionAfterSkippingLeadingTrivia,
                message: "Public IPC surfaces must not expose a zmx.* namespace"
            )
        )
    }
}

struct IPCNoDirectAtomAccessRule: ArchitectureRule {
    let id = "agentstudio_ipc_no_direct_atom_access"
    let severity = ArchitectureSeverity.error
    let message = "AppIPC services and adapters must route through ports and owners instead of atom access"

    func validate(context: ArchitectureLintContext) -> [ArchitectureDiagnostic] {
        let classifier = AgentStudioPathClassifier(path: context.normalizedPath)
        guard classifier.isAppIPCSource || classifier.isIPCCompositionSource else {
            return []
        }

        let visitor = IPCAtomAccessVisitor()
        visitor.walk(context.sourceFile)
        return visitor.violations.map {
            diagnostic(context: context, position: $0.position, message: $0.message)
        }
    }
}

private final class IPCAtomAccessVisitor: SyntaxVisitor {
    private(set) var violations: [ArchitectureViolation] = []

    override init(viewMode: SyntaxTreeViewMode = .sourceAccurate) {
        super.init(viewMode: viewMode)
    }

    override func visitPost(_ node: DeclReferenceExprSyntax) {
        let name = node.baseName.text
        guard
            name == "atom"
                || ArchitectureAllowlists.atomAccessNames.contains(name)
                || name.hasSuffix("Atom")
        else {
            return
        }
        violations.append(
            ArchitectureViolation(
                position: node.positionAfterSkippingLeadingTrivia,
                message: "IPC services and adapters must use app/runtime owner ports instead of direct atom access"
            )
        )
    }
}

struct ForbiddenArchitectureMarkerRule: ArchitectureRule {
    let id = "agentstudio_no_forbidden_architecture_marker"
    let severity = ArchitectureSeverity.error
    let message = "Remove the forbidden architecture marker; this proves AgentStudio architecture rules are active"

    func validate(context: ArchitectureLintContext) -> [ArchitectureDiagnostic] {
        let visitor = ForbiddenArchitectureMarkerVisitor()
        visitor.walk(context.sourceFile)
        return visitor.positions.map {
            diagnostic(context: context, position: $0)
        }
    }
}

private final class ForbiddenArchitectureMarkerVisitor: SyntaxVisitor {
    private(set) var positions: [AbsolutePosition] = []

    override init(viewMode: SyntaxTreeViewMode = .sourceAccurate) {
        super.init(viewMode: viewMode)
    }

    override func visitPost(_ node: DeclReferenceExprSyntax) {
        guard node.baseName.text == "AGENTSTUDIO_FORBIDDEN_ARCHITECTURE_MARKER" else {
            return
        }
        positions.append(node.positionAfterSkippingLeadingTrivia)
    }
}
