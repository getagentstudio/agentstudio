import Foundation

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

public struct ArchitectureLintCommand {
    private static let specializedRuleIDByLedgerFilename: [String: String] = [
        "forbidden-test-wait-ledger.tsv": "agentstudio_no_forbidden_test_wait",
        "adhoc-continuation-wait-ledger.tsv": "agentstudio_no_adhoc_continuation_wait",
    ]

    private let fileManager: FileManager
    private let standardOutput: FileHandle
    private let standardError: FileHandle
    private let rules: [any ArchitectureRule]
    private let documentRules: [any ArchitectureDocumentRule]
    private let workspaceRootPath: String

    public init(
        fileManager: FileManager,
        standardOutput: FileHandle,
        standardError: FileHandle
    ) {
        self.init(
            fileManager: fileManager,
            standardOutput: standardOutput,
            standardError: standardError,
            rules: ArchitectureRuleRegistry.rules,
            workspaceRootPath: FileManager.default.currentDirectoryPath
        )
    }

    init(
        fileManager: FileManager,
        standardOutput: FileHandle,
        standardError: FileHandle,
        rules: [any ArchitectureRule],
        documentRules: [any ArchitectureDocumentRule] = ArchitectureRuleRegistry.documentRules,
        workspaceRootPath: String = FileManager.default.currentDirectoryPath
    ) {
        self.fileManager = fileManager
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.rules = rules
        self.documentRules = documentRules
        self.workspaceRootPath = Self.canonicalFileSystemPath(workspaceRootPath)
    }

    private static func canonicalFileSystemPath(_ path: String) -> String {
        let standardizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        guard let resolvedPath = standardizedPath.withCString({ realpath($0, nil) }) else {
            return standardizedPath
        }
        defer { free(resolvedPath) }
        return String(cString: resolvedPath)
    }

    public func run(arguments: [String]) -> Int32 {
        let parsedArguments: ArchitectureLintArguments
        do {
            parsedArguments = try ArchitectureLintArguments.parse(arguments)
        } catch {
            writeError("agentstudio-architecture-lint: \(error)\n")
            return 2
        }

        do {
            switch parsedArguments.mode {
            case .help:
                writeOutput(helpText)
                return 0
            case .printRules:
                let inventory =
                    rules.map { ($0.id, $0.severity) } + documentRules.map { ($0.id, $0.severity) }
                for (id, severity) in inventory.sorted(by: { $0.0 < $1.0 }) {
                    writeOutput("\(id) \(severity.rawValue)\n")
                }
                return 0
            case .checkLedgerRatchet(let basePath):
                return try checkLedgerRatchet(arguments: parsedArguments, basePath: basePath)
            case .lint:
                return try lint(arguments: parsedArguments)
            }
        } catch {
            writeError("agentstudio-architecture-lint: \(error)\n")
            return 2
        }
    }

    private func lint(arguments: ArchitectureLintArguments) throws -> Int32 {
        let requestedRoots = arguments.roots.isEmpty ? ["Sources", "Tests"] : arguments.roots
        let discovery = SourceFileDiscovery(fileManager: fileManager)
        let onlyFiles = try discovery.lintedFiles(under: arguments.onlyPaths.map(workspacePath))
        let rootFiles = try discovery.lintedFiles(under: requestedRoots.map(workspacePath))
        let rootFileSet = Set(rootFiles)
        let files = rootFiles + onlyFiles.filter { !rootFileSet.contains($0) }
        let run = try ArchitectureLintEngine(
            rules: rules,
            documentRules: documentRules,
            workspaceRootPath: workspaceRootPath
        )
        .lint(
            files: files,
            validatedFiles: arguments.onlyPaths.isEmpty ? nil : Set(onlyFiles)
        )

        let diagnostics = try reconcile(run: run, arguments: arguments)

        for diagnostic in diagnostics {
            writeOutput(diagnostic.rendered)
        }
        if arguments.printsTimings {
            writeOutput(run.timings.renderedLines)
        }
        return diagnostics.isEmpty ? 0 : 1
    }

    private func reconcile(run: ArchitectureLintRun, arguments: ArchitectureLintArguments) throws
        -> [ArchitectureDiagnostic]
    {
        guard !arguments.ledgerPaths.isEmpty else { return run.siteDiagnostics }
        let ledgers = try arguments.ledgerPaths.map(loadLedger)
        try validateLedgerOwnership(ledgers)
        let specializedRuleIDs = Set(
            ledgers.compactMap { Self.specializedRuleID(forLedgerPath: $0.sourcePath) }
        )
        let allRuleIDs = Set(rules.map(\.id) + documentRules.map(\.id))
        let ownedRules = Set(
            ledgers.flatMap { ledger in
                if let specializedRuleID = Self.specializedRuleID(forLedgerPath: ledger.sourcePath) {
                    return [specializedRuleID]
                }
                return allRuleIDs.filter { !specializedRuleIDs.contains($0) }
            })
        var diagnostics = run.siteDiagnostics.filter { !ownedRules.contains($0.ruleID) }

        for var ledger in ledgers {
            let specializedRuleID = Self.specializedRuleID(forLedgerPath: ledger.sourcePath)
            let sites = run.siteDiagnostics.filter {
                if let specializedRuleID {
                    return $0.ruleID == specializedRuleID
                }
                return !specializedRuleIDs.contains($0.ruleID)
            }
            let reconciliation = normalizedReconciliation(run: run, ledger: ledger)
            var outcome = reconciliation.reconcile(diagnostics: sites) { relativeWorkspacePath($0.path) }
            if arguments.lowersLedgerCounts {
                let lowered = reconciliation.lowered(observedCounts: outcome.observedCounts)
                if lowered != ledger {
                    try lowered.rendered.write(
                        toFile: workspacePath(ledger.sourcePath), atomically: true, encoding: .utf8
                    )
                    writeOutput("agentstudio-architecture-lint: lowered counts in \(ledger.sourcePath)\n")
                }
                ledger = lowered
                outcome = normalizedReconciliation(run: run, ledger: ledger)
                    .reconcile(diagnostics: sites) { relativeWorkspacePath($0.path) }
            }
            diagnostics.append(contentsOf: outcome.diagnostics)
        }
        return diagnostics.sorted()
    }

    private func normalizedReconciliation(
        run: ArchitectureLintRun, ledger: ArchitectureDebtLedger
    ) -> DebtLedgerReconciliation {
        var validatedPaths: [String: String] = [:]
        for context in run.validatedContexts {
            if let relative = relativeWorkspacePath(context.path) { validatedPaths[relative] = context.path }
        }
        for document in run.validatedDocuments {
            if let relative = relativeWorkspacePath(document.path) { validatedPaths[relative] = document.path }
        }
        return DebtLedgerReconciliation(ledger: ledger, validatedPaths: validatedPaths, isFullRun: run.isFullRun)
    }

    private func relativeWorkspacePath(_ path: String) -> String? {
        let canonical = Self.canonicalFileSystemPath(path)
        let prefix = "\(workspaceRootPath)/"
        guard canonical.hasPrefix(prefix) else { return nil }
        return String(canonical.dropFirst(prefix.count))
    }

    private func validateLedgerOwnership(_ ledgers: [ArchitectureDebtLedger]) throws {
        var seenKeys: Set<DebtLedgerKey> = []
        var seenKinds: Set<String> = []
        let specializedRuleIDs = Set(Self.specializedRuleIDByLedgerFilename.values)
        for ledger in ledgers {
            for entry in ledger.entries {
                guard seenKeys.insert(entry.key).inserted else {
                    throw DebtLedgerError.malformed(
                        path: ledger.sourcePath, line: entry.line,
                        reason: "duplicate row across ledgers for \(entry.key.ruleID) \(entry.key.path)"
                    )
                }
            }
        }
        for ledger in ledgers {
            let specializedRuleID = Self.specializedRuleID(forLedgerPath: ledger.sourcePath)
            for entry in ledger.entries {
                let entryBelongsToLedger =
                    specializedRuleID.map { $0 == entry.key.ruleID }
                    ?? !specializedRuleIDs.contains(entry.key.ruleID)
                guard entryBelongsToLedger else {
                    throw DebtLedgerError.malformed(
                        path: ledger.sourcePath, line: entry.line,
                        reason: "rule \(entry.key.ruleID) belongs in the other Swift debt ledger"
                    )
                }
            }
            let ledgerKind = specializedRuleID ?? "general"
            guard seenKinds.insert(ledgerKind).inserted else {
                throw DebtLedgerError.malformed(
                    path: ledger.sourcePath, line: 1, reason: "a ledger for this rule family was already supplied"
                )
            }
        }
    }

    private static func specializedRuleID(forLedgerPath path: String) -> String? {
        let filename = URL(fileURLWithPath: path).lastPathComponent
        return specializedRuleIDByLedgerFilename[filename]
    }

    /// A merge base without a ledger has nothing to ratchet against: the
    /// ledger is new in that change, and every row it adds is its baseline.
    private func checkLedgerRatchet(arguments: ArchitectureLintArguments, basePath: String) throws -> Int32 {
        guard let ledgerPath = arguments.ledgerPaths.first else {
            throw ArchitectureLintArgumentsError.requiresLedger
        }
        let current = try loadLedger(ledgerPath)
        guard fileManager.fileExists(atPath: workspacePath(basePath)) else {
            writeOutput("agentstudio-architecture-lint: no debt ledger at the merge base; nothing to ratchet\n")
            return 0
        }
        let base = try ArchitectureDebtLedger.load(path: workspacePath(basePath), displayPath: basePath)
        let violations = DebtLedgerRatchet.violations(current: current, base: base)
        for violation in violations {
            writeOutput(violation.rendered)
        }
        return violations.isEmpty ? 0 : 1
    }

    private func loadLedger(_ ledgerPath: String) throws -> ArchitectureDebtLedger {
        try ArchitectureDebtLedger.load(path: workspacePath(ledgerPath), displayPath: ledgerPath)
    }

    /// A root or scoped path as an absolute, canonical path, so the same
    /// file named two ways is one file.
    private func workspacePath(_ path: String) -> String {
        guard !path.hasPrefix("/") else {
            return Self.canonicalFileSystemPath(path)
        }
        return URL(
            fileURLWithPath: path,
            relativeTo: URL(fileURLWithPath: workspaceRootPath, isDirectory: true)
        ).standardizedFileURL.path
    }

    private var helpText: String {
        """
        Usage:
          agentstudio-architecture-lint [--timings] [--ledger file]... [--lower-ledger-counts] [--only file]... [paths...]
          agentstudio-architecture-lint --ledger file --check-ledger-ratchet base-file
          agentstudio-architecture-lint --print-rules

        Defaults to linting Sources and Tests when no paths are provided.
        --only validates just the named files; every path is still parsed so
        cross-file rules see the whole corpus.
        --timings prints per-stage and per-rule times; they never change the exit code.
        --ledger reconciles violation sites with their owning debt ledgers: a file may hold
        exactly its permitted count per rule. --lower-ledger-counts rewrites
        the ledger down to what this run found; it never raises a count.
        --check-ledger-ratchet fails when --ledger raises a count or adds a row
        compared with base-file (the ledger at the merge base).
        Diagnostics use path:line:column: severity: [rule] message.

        """
    }

    private func writeOutput(_ text: String) {
        if let data = text.data(using: .utf8) {
            standardOutput.write(data)
        }
    }

    private func writeError(_ text: String) {
        if let data = text.data(using: .utf8) {
            standardError.write(data)
        }
    }
}
