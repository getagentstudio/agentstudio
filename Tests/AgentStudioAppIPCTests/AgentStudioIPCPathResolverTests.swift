import AgentStudioAppIPC
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import Foundation
import Testing

@Suite("AgentStudio IPC paths and filesystem trust")
struct AgentStudioIPCPathResolverTests {
    @Test("derives runtime metadata and socket paths under the channel root")
    func derivesRuntimeMetadataAndSocketPathsUnderChannelRoot() {
        let root = URL(fileURLWithPath: "/tmp/asipc-root")
        let paths = AgentStudioIPCPathResolver().paths(rootDirectory: root)

        #expect(paths.ipcDirectory == root.appendingPathComponent("ipc", isDirectory: true))
        #expect(paths.socketDirectory == paths.ipcDirectory)
        #expect(paths.metadataURL == root.appendingPathComponent("ipc/runtime.json"))
        #expect(paths.socketURL == root.appendingPathComponent("ipc/agentstudio.sock"))
        #expect(paths.spoolDirectory == root.appendingPathComponent("ipc/spool/v2", isDirectory: true))
    }

    @Test("can keep metadata under root while binding socket in a separate trusted directory")
    func canKeepMetadataUnderRootWhileBindingSocketInSeparateTrustedDirectory() throws {
        let fixture = try IPCPathFixture()
        defer { fixture.cleanup() }
        let socketDirectory = fixture.root.appendingPathComponent("short-socket", isDirectory: true)
        let paths = AgentStudioIPCPathResolver().paths(
            rootDirectory: fixture.root,
            socketDirectory: socketDirectory
        )

        try AgentStudioIPCFilesystem.prepare(paths: paths)

        #expect(paths.ipcDirectory == fixture.root.appendingPathComponent("ipc", isDirectory: true))
        #expect(paths.metadataURL == fixture.root.appendingPathComponent("ipc/runtime.json"))
        #expect(paths.socketDirectory == socketDirectory)
        #expect(paths.socketURL == socketDirectory.appendingPathComponent("agentstudio.sock"))
        #expect(try fixture.mode(for: paths.socketDirectory) & 0o777 == 0o700)
    }

    @Test("creates owner-only ipc directory")
    func createsOwnerOnlyIPCDirectory() throws {
        let fixture = try IPCPathFixture()
        defer { fixture.cleanup() }

        let paths = AgentStudioIPCPathResolver().paths(rootDirectory: fixture.root)

        try AgentStudioIPCFilesystem.prepare(paths: paths)

        #expect(try fixture.mode(for: paths.ipcDirectory) & 0o777 == 0o700)
    }

    @Test("allows a group-readable data root while keeping the ipc directory owner-only")
    func allowsGroupReadableDataRoot() throws {
        let fixture = try IPCPathFixture(rootMode: 0o755)
        defer { fixture.cleanup() }

        let paths = AgentStudioIPCPathResolver().paths(rootDirectory: fixture.root)

        try AgentStudioIPCFilesystem.prepare(paths: paths)

        #expect(try fixture.mode(for: fixture.root) & 0o777 == 0o755)
        #expect(try fixture.mode(for: paths.ipcDirectory) & 0o777 == 0o700)
    }

    @Test("rejects group- or world-writable data roots with a distinct reason")
    func rejectsGroupOrWorldWritableDataRoots() throws {
        for rootMode in [mode_t(0o775), mode_t(0o757)] {
            let fixture = try IPCPathFixture(rootMode: rootMode)
            defer { fixture.cleanup() }

            let paths = AgentStudioIPCPathResolver().paths(rootDirectory: fixture.root)
            let error = filesystemTrustError(for: paths)

            #expect(error?.reason == .groupOrWorldWritable)
            #expect(error?.path == fixture.root.path)
        }
    }

    @Test("fails closed for a symlinked data root")
    func failsClosedForSymlinkedDataRoot() throws {
        let fixture = try IPCPathFixture()
        defer { fixture.cleanup() }
        let symlinkRoot = FileManager.default.temporaryDirectory
            .appending(path: "asipc-path-link-\(UUIDv7.generate().uuidString.prefix(8))", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: symlinkRoot) }
        try FileManager.default.createSymbolicLink(at: symlinkRoot, withDestinationURL: fixture.root)

        let paths = AgentStudioIPCPathResolver().paths(rootDirectory: symlinkRoot)
        let error = filesystemTrustError(for: paths)

        #expect(error?.reason == .symlinkNotAllowed)
        #expect(error?.path == symlinkRoot.path)
    }

    @Test("keeps a pre-existing ipc directory owner-only under a 0755 data root")
    func rejectsGroupAccessibleIPCDirectoryWithinGroupReadableDataRoot() throws {
        let fixture = try IPCPathFixture(rootMode: 0o755)
        defer { fixture.cleanup() }

        let paths = AgentStudioIPCPathResolver().paths(rootDirectory: fixture.root)
        try FileManager.default.createDirectory(
            at: paths.ipcDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o755]
        )
        let error = filesystemTrustError(for: paths)

        #expect(error?.reason == .groupOrWorldAccessible)
        #expect(error?.path == paths.ipcDirectory.path)
    }

    @Test("fails closed for symlinked ipc directories")
    func failsClosedForSymlinkedIPCDirectories() throws {
        let fixture = try IPCPathFixture()
        defer { fixture.cleanup() }

        let paths = AgentStudioIPCPathResolver().paths(rootDirectory: fixture.root)
        let target = fixture.root.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: paths.ipcDirectory, withDestinationURL: target)

        #expect(throws: AgentStudioIPCFilesystemTrustError.self) {
            try AgentStudioIPCFilesystem.prepare(paths: paths)
        }
    }

    @Test("writes runtime metadata atomically without subject tokens")
    func writesRuntimeMetadataAtomicallyWithoutSubjectTokens() throws {
        let fixture = try IPCPathFixture()
        defer { fixture.cleanup() }

        let paths = AgentStudioIPCPathResolver().paths(rootDirectory: fixture.root)
        try AgentStudioIPCFilesystem.prepare(paths: paths)

        let runtimeId = UUID()
        let metadata = AgentStudioIPCRuntimeMetadata(
            runtimeId: runtimeId,
            processIdentifier: 12_345,
            channel: .debug,
            socketPath: paths.socketURL.path,
            startedAt: Date(timeIntervalSince1970: 0)
        )

        try AgentStudioIPCFilesystem.writeMetadata(metadata, paths: paths)

        let data = try Data(contentsOf: paths.metadataURL)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains(runtimeId.uuidString))
        #expect(json.contains("agentstudio-ipc-jsonrpc-2"))
        #expect(!json.localizedCaseInsensitiveContains("token"))
        #expect(try fixture.mode(for: paths.metadataURL) & 0o777 == 0o600)
    }

    @Test("hands the debug credential over through an owner-only escrow file")
    func writesDebugCredentialEscrowOwnerOnly() throws {
        let fixture = try IPCPathFixture()
        defer { fixture.cleanup() }
        let escrowURL = fixture.root.appendingPathComponent("debug-escrow.json")
        let document = IPCDebugCredentialEscrowDocument(
            runtimeId: UUID(),
            socketPath: "/tmp/asipc-escrow/agentstudio.sock",
            token: Data(repeating: 0x2B, count: 32).base64EncodedString()
        )

        try AgentStudioIPCFilesystem.writeDebugCredentialEscrow(document, to: escrowURL)

        let decoded = try JSONDecoder().decode(
            IPCDebugCredentialEscrowDocument.self,
            from: try Data(contentsOf: escrowURL)
        )
        #expect(decoded == document)
        #expect(try fixture.mode(for: escrowURL) & 0o777 == 0o600)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path) == ["debug-escrow.json"])

        AgentStudioIPCFilesystem.removeDebugCredentialEscrow(at: escrowURL)
        #expect(!FileManager.default.fileExists(atPath: escrowURL.path))
    }

    @Test("refuses a debug escrow path whose directory the launcher never created")
    func refusesDebugCredentialEscrowWithoutItsDirectory() throws {
        let fixture = try IPCPathFixture()
        defer { fixture.cleanup() }
        let escrowURL = fixture.root.appendingPathComponent("missing/debug-escrow.json")

        #expect(throws: AgentStudioIPCFilesystemTrustError.self) {
            try AgentStudioIPCFilesystem.writeDebugCredentialEscrow(
                IPCDebugCredentialEscrowDocument(
                    runtimeId: UUID(),
                    socketPath: "/tmp/asipc-escrow/agentstudio.sock",
                    token: "unused"
                ),
                to: escrowURL
            )
        }
    }

    @Test("classifies stale socket probe outcomes")
    func classifiesStaleSocketProbeOutcomes() throws {
        let resolver = AgentStudioIPCStaleSocketResolver()
        let runtimeId = UUID()

        #expect(resolver.decision(for: .sameRuntime(runtimeId), expectedRuntimeId: runtimeId) == .keepExisting)
        #expect(resolver.decision(for: .dead, expectedRuntimeId: runtimeId) == .unlinkAndBind)
        #expect(
            resolver.decision(for: .differentRuntime(UUID()), expectedRuntimeId: runtimeId)
                == .refuseDifferentLiveRuntime
        )
    }
}

private func filesystemTrustError(for paths: AgentStudioIPCPaths) -> AgentStudioIPCFilesystemTrustError? {
    do {
        try AgentStudioIPCFilesystem.prepare(paths: paths)
        return nil
    } catch let error as AgentStudioIPCFilesystemTrustError {
        return error
    } catch {
        return nil
    }
}

private struct IPCPathFixture {
    let root: URL

    init(rootMode: mode_t = 0o700) throws {
        root = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("asipc-path-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        chmod(root.path, rootMode)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }

    func mode(for url: URL) throws -> mode_t {
        var statBuffer = stat()
        guard lstat(url.path, &statBuffer) == 0 else {
            throw POSIXError(.ENOENT)
        }

        return statBuffer.st_mode
    }
}
