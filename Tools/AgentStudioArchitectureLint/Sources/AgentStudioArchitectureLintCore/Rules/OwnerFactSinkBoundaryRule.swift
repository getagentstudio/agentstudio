import Foundation
import SwiftSyntax

/// Keeps synchronous test-observation sinks local to the owner and makes
/// observation-only preparation lazy when the optional sink is nil.
struct OwnerFactSinkBoundaryRule: ArchitectureRule {
    let id = "agentstudio_owner_fact_sink_boundary"
    let severity = ArchitectureSeverity.error
    let message = "Owner-local fact sinks must not be forwarded or do observation-only work when absent"

    private let aliases: [String: FactSinkAlias]
    private let scopeFactoryIndex: FactScopeFactoryIndex
    private let sinkNames: Set<String>

    init() {
        aliases = [:]
        scopeFactoryIndex = .empty
        sinkNames = []
    }

    private init(
        aliases: [String: FactSinkAlias],
        scopeFactoryIndex: FactScopeFactoryIndex,
        sinkNames: Set<String>
    ) {
        self.aliases = aliases
        self.scopeFactoryIndex = scopeFactoryIndex
        self.sinkNames = sinkNames
    }

    func prepared(for contexts: [ArchitectureLintContext]) -> any ArchitectureRule {
        var aliases = Self.collectAliases(contexts)
        Self.collectOwnerTypes(contexts, aliases: &aliases)
        let sinkNames = Self.collectSinkNames(contexts, aliases: aliases)
        let scopeFactoryIndex = Self.collectScopeFactoryIndex(
            contexts,
            aliases: aliases,
            sinkNames: sinkNames
        )
        return Self(aliases: aliases, scopeFactoryIndex: scopeFactoryIndex, sinkNames: sinkNames)
    }

    func validate(context: ArchitectureLintContext) -> [ArchitectureDiagnostic] {
        guard Self.isProductionOrRuleFixtureSource(context) else { return [] }
        let visitor = OwnerFactSinkBoundaryVisitor(
            aliases: aliases,
            scopeFactoryIndex: scopeFactoryIndex,
            sinkNames: sinkNames
        )
        visitor.walk(context.sourceFile)
        return visitor.violations.map { violation in
            diagnostic(context: context, position: violation.position, message: violation.message)
        }
    }

    private static func collectAliases(_ contexts: [ArchitectureLintContext]) -> [String: FactSinkAlias] {
        var aliases: [String: FactSinkAlias] = [:]
        for context in contexts where isProductionOrRuleFixtureSource(context) {
            let ownerHints = FactSinkOwnerHintCollector(path: context.normalizedPath)
            ownerHints.walk(context.sourceFile)
            let visitor = FactSinkAliasCollector(ownerTypeHints: ownerHints.ownerTypeNames)
            visitor.walk(context.sourceFile)
            for alias in visitor.aliases {
                if var indexedAlias = aliases[alias.name] {
                    indexedAlias.ownerTypeHints.formUnion(alias.ownerTypeHints)
                    aliases[alias.name] = indexedAlias
                } else {
                    aliases[alias.name] = alias
                }
            }
        }
        return aliases
    }

    private static func collectOwnerTypes(
        _ contexts: [ArchitectureLintContext],
        aliases: inout [String: FactSinkAlias]
    ) {
        let visitor = FactSinkOwnerTypeCollector(aliasNames: Set(aliases.keys))
        for context in contexts where isProductionOrRuleFixtureSource(context) {
            visitor.walk(context.sourceFile)
        }
        for (aliasName, ownerName) in visitor.owners {
            guard aliases[aliasName]?.ownerTypeHints.contains(ownerName) == true else { continue }
            aliases[aliasName]?.ownerNames.insert(ownerName)
        }
    }

    private static func collectScopeFactoryIndex(
        _ contexts: [ArchitectureLintContext],
        aliases: [String: FactSinkAlias],
        sinkNames: Set<String>
    ) -> FactScopeFactoryIndex {
        let scopeNames = Set(aliases.values.map(\.scopeType))
        var index = FactScopeFactoryIndex.empty
        for context in contexts where isProductionOrRuleFixtureSource(context) {
            let visitor = FactScopeFactoryCollector(scopeNames: scopeNames, sinkNames: sinkNames)
            visitor.walk(context.sourceFile)
            index.outerGateRequired.formUnion(visitor.outerGateRequiredNames)
        }
        return index
    }

    private static func collectSinkNames(
        _ contexts: [ArchitectureLintContext],
        aliases: [String: FactSinkAlias]
    ) -> Set<String> {
        let ownerNames = Set(aliases.values.flatMap(\.ownerNames))
        var names: Set<String> = []
        for context in contexts where isProductionOrRuleFixtureSource(context) {
            let visitor = FactSinkNameCollector(aliasNames: Set(aliases.keys), ownerNames: ownerNames)
            visitor.walk(context.sourceFile)
            names.formUnion(visitor.names)
        }
        return names
    }

    private static func isProductionOrRuleFixtureSource(_ context: ArchitectureLintContext) -> Bool {
        guard let relativePath = context.workspaceRelativePath else { return false }
        let components = relativePath.split(separator: "/")
        guard !components.contains(where: { $0 == "Tests" }) else { return false }
        return components.first == "Sources"
    }
}
