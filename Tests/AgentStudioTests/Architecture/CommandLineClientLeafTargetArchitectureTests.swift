import Foundation
import Testing

@testable import AgentStudioTestSupport

/// The `agentstudio-cli` helper is shipped inside the app bundle as
/// `Contents/Helpers/agentstudio`. Worktree verbs intentionally link libgit2
/// through `AgentStudioWorktreeOperations`; the CLI store intentionally links
/// GRDB. The helper must stay off `AgentStudioInfrastructure` and its OTel base.
///
/// These tests pin the allowed module imports of the CLI-side targets, the
/// worktree-operation leaf, and the test targets that cover the CLI so a direct
/// Infrastructure or SDK import cannot bypass the shared operation boundary.
@Suite("Command-line client leaf targets")
struct CommandLineClientLeafTargetArchitectureTests {

    /// Every module the CLI-side targets may import directly. The worktree
    /// operation leaf is the only AgentStudio product boundary besides the
    /// existing CLI modules; Infrastructure remains forbidden.
    private static let allowedImportedModules: Set<String> = [
        "Dispatch",
        "Foundation",
        "CryptoKit",
        "Security",
        "System",
        "Darwin",
        // Provider-silent CLI diagnostics go to the unified log.
        "os",
        "AgentStudioIPCClientCore",
        "AgentStudioCLIStore",
        "AgentStudioIPCTransport",
        "AgentStudioPrimitives",
        "AgentStudioProgrammaticControl",
        "AgentStudioWorktreeOperations",
    ]

    private static let allowedWorktreeOperationsImportedModules: Set<String> = [
        "AgentStudioGit",
        "AgentStudioPrimitives",
        "Foundation",
    ]

    private static let commandLineClientTargetPaths = [
        "Sources/AgentStudioIPCClient",
        "Sources/AgentStudioIPCClientCore",
        "Sources/AgentStudioIPCTransport",
        "Sources/AgentStudioProgrammaticControl",
    ]

    /// The suites covering the CLI side keep the same leaf-only graph, plus the
    /// test framework and the causal-test harness, itself a leaf over the
    /// standard library, Foundation and Synchronization. A test target that
    /// drags Infrastructure back in rebuilds GRDB, OTel and libgit2 for every
    /// `mise run test:swift`.
    private static let allowedTestImportedModules = allowedImportedModules.union([
        "Testing",
        "AgentStudioTestHarness",
    ])

    private static let commandLineClientTestTargetPaths = [
        "Tests/AgentStudioIPCClientTests",
        "Tests/AgentStudioProgrammaticControlTests",
    ]

    @Test("the raw CLI hard cutover leaves no eager or typed-command admission API")
    func retiredClientAdmissionPathsAreRemoved() throws {
        let root = URL(fileURLWithPath: TestPathResolver.projectRoot(from: #filePath))
        let forbidden: [String: [String]] = [
            "Sources/AgentStudioProgrammaticControl/BuiltInDescriptors/IPCBuiltInMethodCatalog+Discovery.swift": [
                "func bootstrapDescriptors", "func locallyResolvableDescriptors", "func resolvesLocally",
                "func matchingDiscoveredMethods",
            ],
            "Sources/AgentStudioIPCClientCore/IPCCommandDiscovery.swift": [
                "func makeInvocation", "func decodeResult", "requestEnvelopeDescriptor",
            ],
            "Sources/AgentStudioProgrammaticControl/IPCCommandCatalogResult.swift": [
                "func normalizeDiscoveryResult"
            ],
            "Sources/AgentStudioIPCClientCore/IPCDescriptorClientResponse.swift": [
                "case protocolRejected", "case unsupportedVersion",
            ],
            "Sources/AgentStudioIPCClientCore/AgentStudioIPCClientCommandLineRunner.swift": [
                "init(unsupportedVersion"
            ],
        ]
        for (path, declarations) in forbidden {
            let url = root.appending(path: path)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let source = try String(contentsOf: url, encoding: .utf8)
            for declaration in declarations {
                #expect(!source.contains(declaration), "retired declaration: \(path): \(declaration)")
            }
        }
    }

    @Test("CLI diagnostics persist controlled public reasons instead of free-form debug messages")
    func diagnosticsKeepPayloadFreePersistedReasons() throws {
        let root = URL(fileURLWithPath: TestPathResolver.projectRoot(from: #filePath))
        let source = try String(
            contentsOf: root.appending(path: "Sources/AgentStudioIPCClientCore/CLIDiagnostics.swift"), encoding: .utf8)
        #expect(source.contains("logger.notice(") || source.contains("logger.error("))
        #expect(source.contains("privacy: .public"))
        #expect(!source.contains("record(_ message: String)"))
        #expect(!source.contains("logger.debug("))
    }

    @Test("CLI-side targets import only their approved low-level modules")
    func commandLineClientTargetsImportOnlyApprovedModules() throws {
        // Arrange
        let projectRoot = URL(fileURLWithPath: TestPathResolver.projectRoot(from: #filePath))

        // Act
        let disallowed = try Self.commandLineClientTargetPaths.flatMap { targetPath in
            try Self.importedModules(inTargetAt: targetPath, projectRoot: projectRoot)
                .filter { !Self.allowedImportedModules.contains($0.moduleName) }
        }

        // Assert
        #expect(
            disallowed.isEmpty,
            """
            The agentstudio-cli helper must build from leaf targets only. \
            Disallowed imports: \
            \(disallowed.map { "\($0.relativePath): import \($0.moduleName)" }.sorted().joined(separator: ", "))
            """
        )
    }

    @Test("worktree operations is bounded to the SDK and primitive leaf")
    func worktreeOperationsTargetImportsOnlyItsDeclaredDependencies() throws {
        // Arrange
        let projectRoot = URL(fileURLWithPath: TestPathResolver.projectRoot(from: #filePath))

        // Act
        let disallowed = try Self.importedModules(
            inTargetAt: "Sources/AgentStudioWorktreeOperations",
            projectRoot: projectRoot
        ).filter { !Self.allowedWorktreeOperationsImportedModules.contains($0.moduleName) }

        // Assert
        #expect(
            disallowed.isEmpty,
            """
            AgentStudioWorktreeOperations must own its SDK access without reaching through Infrastructure. \
            Disallowed imports: \
            \(disallowed.map { "\($0.relativePath): import \($0.moduleName)" }.sorted().joined(separator: ", "))
            """
        )
    }

    @Test("the CLI executable does not reach for AgentStudioInfrastructure")
    func commandLineClientDoesNotImportInfrastructure() throws {
        // Arrange
        let projectRoot = URL(fileURLWithPath: TestPathResolver.projectRoot(from: #filePath))

        // Act
        let infrastructureImports = try Self.commandLineClientTargetPaths.flatMap { targetPath in
            try Self.importedModules(inTargetAt: targetPath, projectRoot: projectRoot)
                .filter { $0.moduleName == "AgentStudioInfrastructure" }
        }

        // Assert
        #expect(
            infrastructureImports.isEmpty,
            """
            AgentStudioInfrastructure pulls GRDB, OTel and libgit2 into the bundled \
            helper. Pure Foundation-only helpers belong in AgentStudioPrimitives. \
            Offending files: \(infrastructureImports.map(\.relativePath).sorted().joined(separator: ", "))
            """
        )
    }

    @Test("CLI-side test targets import only Foundation-level modules and each other")
    func commandLineClientTestTargetsImportOnlyLeafModules() throws {
        // Arrange
        let projectRoot = URL(fileURLWithPath: TestPathResolver.projectRoot(from: #filePath))

        // Act
        let disallowed = try Self.commandLineClientTestTargetPaths.flatMap { targetPath in
            try Self.importedModules(inTargetAt: targetPath, projectRoot: projectRoot)
                .filter { !Self.allowedTestImportedModules.contains($0.moduleName) }
        }

        // Assert
        #expect(
            disallowed.isEmpty,
            """
            The suites covering the CLI side must stay on the same leaf graph. \
            Pure Foundation-only helpers belong in AgentStudioPrimitives. \
            Disallowed imports: \
            \(disallowed.map { "\($0.relativePath): import \($0.moduleName)" }.sorted().joined(separator: ", "))
            """
        )
    }

    @Test("Package.swift keeps the CLI product off the Infrastructure dependency edge")
    func packageManifestKeepsCommandLineClientOffInfrastructure() throws {
        // Arrange
        let projectRoot = URL(fileURLWithPath: TestPathResolver.projectRoot(from: #filePath))
        let manifest = try String(contentsOf: projectRoot.appending(path: "Package.swift"), encoding: .utf8)

        // Act
        let commandLineClientTargetNames = [
            "AgentStudioIPCClient",
            "AgentStudioIPCClientCore",
            "AgentStudioIPCClientTests",
            "AgentStudioProgrammaticControlTests",
            "AgentStudioWorktreeOperations",
        ]
        let commandLineClientDependencyBlocks =
            commandLineClientTargetNames
            .compactMap { targetName in
                Self.dependencyBlock(forTargetNamed: targetName, in: manifest).map { (targetName, $0) }
            }

        // Assert
        #expect(commandLineClientDependencyBlocks.count == commandLineClientTargetNames.count)
        for (targetName, dependencyBlock) in commandLineClientDependencyBlocks {
            #expect(
                !dependencyBlock.contains("AgentStudioInfrastructure"),
                "\(targetName) must not depend on AgentStudioInfrastructure"
            )
        }

        let cliDependencies = Self.dependencyBlock(forTargetNamed: "AgentStudioIPCClient", in: manifest)
        let worktreeOperationsDependencies =
            Self.dependencyBlock(forTargetNamed: "AgentStudioWorktreeOperations", in: manifest)
        #expect(cliDependencies?.contains("\"AgentStudioWorktreeOperations\"") == true)
        #expect(worktreeOperationsDependencies?.contains("\"AgentStudioPrimitives\"") == true)
        #expect(worktreeOperationsDependencies?.contains("AgentStudioGit") == true)
    }

    // MARK: - Source scanning

    private struct ImportedModuleRecord {
        let relativePath: String
        let moduleName: String
    }

    private static func importedModules(
        inTargetAt targetPath: String,
        projectRoot: URL
    ) throws -> [ImportedModuleRecord] {
        let targetDirectory = projectRoot.appending(path: targetPath)
        guard
            let enumerator = FileManager.default.enumerator(
                at: targetDirectory,
                includingPropertiesForKeys: nil
            )
        else {
            Issue.record("Missing CLI-side target directory: \(targetPath)")
            return []
        }

        var records: [ImportedModuleRecord] = []
        let targetDirectoryPath = targetDirectory.standardizedFileURL.path
        for case let fileURL as URL in enumerator where fileURL.pathExtension == "swift" {
            let source = try String(contentsOf: fileURL, encoding: .utf8)
            let suffix = fileURL.standardizedFileURL.path.replacingOccurrences(
                of: targetDirectoryPath,
                with: ""
            )
            let relativePath = "\(targetPath)\(suffix)"
            for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
                guard let moduleName = importedModuleName(inLine: String(line)) else { continue }
                records.append(ImportedModuleRecord(relativePath: relativePath, moduleName: moduleName))
            }
        }
        return records
    }

    /// Declaration-kind imports name the module in the *second* token, as in
    /// `import struct Foundation.Data`.
    private static let importDeclarationKinds: Set<String> = [
        "typealias", "struct", "class", "enum", "protocol", "let", "var", "func",
    ]

    /// Matches `import Foo`, `@testable import Foo`, `@_exported import Foo` and
    /// submodule imports such as `import Foo.Bar`, returning the root module.
    private static func importedModuleName(inLine line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let importRange = trimmed.range(of: #"^(@\w+\s+)*import\s+"#, options: .regularExpression) else {
            return nil
        }
        let components = trimmed[importRange.upperBound...].split(separator: " ", omittingEmptySubsequences: true)
        guard let first = components.first else { return nil }
        let modulePath: Substring
        if importDeclarationKinds.contains(String(first)) {
            guard components.count > 1 else { return nil }
            modulePath = components[1]
        } else {
            modulePath = first
        }
        return modulePath.split(separator: ".").first.map(String.init)
    }

    private static func dependencyBlock(forTargetNamed targetName: String, in manifest: String) -> String? {
        guard let nameRange = manifest.range(of: "name: \"\(targetName)\"") else { return nil }
        let remainder = manifest[nameRange.upperBound...]
        guard
            let dependenciesStart = remainder.range(of: "dependencies: ["),
            let dependenciesEnd = remainder[dependenciesStart.upperBound...].range(of: "]")
        else {
            return nil
        }
        return String(remainder[dependenciesStart.upperBound..<dependenciesEnd.lowerBound])
    }
}
