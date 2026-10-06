import AgentStudioAppIPC
import AgentStudioCLIStore
import AgentStudioIPCClientCore
import AgentStudioIPCTransport
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import AgentStudioTestHarness
import CryptoKit
import Foundation
import Testing

@testable import AgentStudio

@MainActor
@Suite("Pane IPC identity owner", .serialized)
struct PaneIPCIdentityOwnerTests {
    @Test("first request mints once and later requests reuse one RAM-only pane environment")
    func environmentIsMintedOnceAndReusedWithoutPersistenceSubmission() async throws {
        let fixture = try PaneIPCIdentityOwnerFixture()
        defer { fixture.removeFiles() }
        let paneID = UUIDv7.generate()
        let workspaceID = UUIDv7.generate()
        let rawBytes = Data(repeating: 0xA5, count: 32)
        let randomBytes = PaneCredentialByteSequence([rawBytes])
        let durableResolver = UnexpectedDurableCredentialResolver()
        let registry = makeRegistry(
            durableResolver: durableResolver,
            membership: { candidatePaneID, candidateWorkspaceID in
                candidatePaneID == paneID && candidateWorkspaceID == workspaceID
            }
        )
        let owner = makeIdentityOwner(
            principalRegistry: registry,
            membership: { candidatePaneID, candidateWorkspaceID in
                candidatePaneID == paneID && candidateWorkspaceID == workspaceID
            },
            randomBytes: randomBytes.next,
            fixture: fixture
        )

        let first = try owner.environment(paneID: paneID, workspaceID: workspaceID)
        let second = try owner.environment(paneID: paneID, workspaceID: workspaceID)
        let rawToken = try #require(first.environmentVariables["AGENTSTUDIO_PANE_TOKEN"])
        let verifier = Data(SHA256.hash(data: Data(rawToken.utf8)))

        #expect(first.credentialRecordID == second.credentialRecordID)
        #expect(first.environmentVariables == second.environmentVariables)
        #expect(randomBytes.callCount == 1)
        #expect(first.environmentVariables["AGENTSTUDIO_PANE_ID"] == paneID.uuidString)
        #expect(first.environmentVariables["AGENTSTUDIO_WORKSPACE_ID"] == workspaceID.uuidString)
        #expect(first.environmentVariables["AGENTSTUDIO_IPC_SOCKET"] == fixture.socketURL.path)
        #expect(first.environmentVariables["AGENTSTUDIO_PANE_TOKEN"] == rawBytes.base64EncodedString())
        // The credential record ID is persistence identity, not pane authority,
        // so it is deliberately absent from the pane's environment.
        #expect(first.environmentVariables["AGENTSTUDIO_IPC_CREDENTIAL_RECORD_ID"] == nil)
        #expect(
            first.environmentVariables["AGENTSTUDIO_CLI_STORE"]
                == fixture.rootDirectory.appending(path: "ipc/cli.sqlite").path)
        #expect(first.environmentVariables["AGENTSTUDIO_CLI_STORE_CHANNEL"] == "debug")
        #expect(first.environmentVariables["AGENTSTUDIO_IPC_SPOOL_DIR"] == nil)
        #expect(first.environmentVariables["AGENTSTUDIO_CLI"] == fixture.cliExecutableURL.path)
        #expect(
            first.environmentVariables["PATH"]
                == "/usr/bin:/bin:\(fixture.cliExecutableURL.deletingLastPathComponent().path)"
        )

        let firstContext = try await registry.authenticate(
            subjectToken: AgentStudioIPCSubjectToken(rawValue: rawToken)
        )
        let secondContext = try await registry.authenticate(
            subjectToken: AgentStudioIPCSubjectToken(rawValue: rawToken)
        )
        #expect(firstContext.credentialIdentity == .pane(recordID: first.credentialRecordID))
        #expect(secondContext.credentialIdentity == .pane(recordID: first.credentialRecordID))
        #expect(firstContext.principal.principalId != secondContext.principal.principalId)
        #expect(await durableResolver.lookupCount == 0)
        #expect(registry.issuedCredentialCandidates().map(\.verifierSHA256) == [verifier])
    }

    @Test("nonmember refusal happens before mint or verifier admission")
    func environmentRejectsNonmemberBeforeMint() async throws {
        let fixture = try PaneIPCIdentityOwnerFixture()
        defer { fixture.removeFiles() }
        let randomBytes = PaneCredentialByteSequence([Data(repeating: 0xB4, count: 32)])
        let durableResolver = UnexpectedDurableCredentialResolver()
        let registry = makeRegistry(durableResolver: durableResolver, membership: { _, _ in false })
        let owner = makeIdentityOwner(
            principalRegistry: registry,
            membership: { _, _ in false },
            randomBytes: randomBytes.next,
            fixture: fixture
        )

        #expect(throws: PaneIPCIdentityOwnerError.paneNotInWorkspace) {
            _ = try owner.environment(
                paneID: UUIDv7.generate(),
                workspaceID: UUIDv7.generate()
            )
        }

        #expect(randomBytes.callCount == 0)
        #expect(registry.issuedCredentialCandidates().isEmpty)
        #expect(await durableResolver.lookupCount == 0)
    }

    @Test("terminal startup fails open while clearing inherited Agent Studio authority")
    func terminalEnvironmentClearsInheritedAuthorityWhenMintingFails() throws {
        let fixture = try PaneIPCIdentityOwnerFixture()
        defer { fixture.removeFiles() }
        let inheritedEnvironment = [
            "PATH": "/usr/bin:/bin",
            "AGENTSTUDIO_PANE_ID": "outer-pane",
            "AGENTSTUDIO_WORKSPACE_ID": "outer-workspace",
            "AGENTSTUDIO_IPC_SOCKET": "/tmp/outer.sock",
            "AGENTSTUDIO_PANE_TOKEN": "outer-token",
            "AGENTSTUDIO_CLI_STORE": "/tmp/outer-cli.sqlite",
            "AGENTSTUDIO_CLI_STORE_CHANNEL": "beta",
            "AGENTSTUDIO_CLI": "/tmp/outer-agentstudio",
        ]
        let registry = makeRegistry(
            durableResolver: UnexpectedDurableCredentialResolver(),
            membership: { _, _ in false }
        )
        let owner = makeIdentityOwner(
            principalRegistry: registry,
            membership: { _, _ in false },
            randomBytes: PaneCredentialByteSequence([]).next,
            inheritedEnvironment: inheritedEnvironment,
            fixture: fixture
        )

        let environment = owner.terminalEnvironment(
            paneID: UUIDv7.generate(),
            workspaceID: UUIDv7.generate()
        )

        #expect(environment["PATH"] == "/usr/bin:/bin:\(fixture.cliExecutableURL.deletingLastPathComponent().path)")
        for key in inheritedEnvironment.keys where key.hasPrefix("AGENTSTUDIO_") {
            #expect(environment[key]?.isEmpty == true)
        }
        #expect(registry.issuedCredentialCandidates().isEmpty)
    }

    @Test("the exported pane store environment reaches the real CLI offline writer")
    func paneEnvironmentFeedsTheCLIOfflineWriter() async throws {
        let fixture = try PaneIPCIdentityOwnerFixture()
        defer { fixture.removeFiles() }
        let paneID = UUIDv7.generate()
        let workspaceID = UUIDv7.generate()
        let registry = makeRegistry(
            durableResolver: UnexpectedDurableCredentialResolver(), membership: { _, _ in true })
        let owner = makeIdentityOwner(
            principalRegistry: registry, membership: { _, _ in true },
            randomBytes: { Data(repeating: 0xA5, count: 32) }, fixture: fixture)
        let environment = try owner.environment(paneID: paneID, workspaceID: workspaceID).environmentVariables
        let storeURL = fixture.rootDirectory.appending(path: "ipc/cli.sqlite")
        let legacyDirectory = fixture.spoolDirectory

        let observed = try await valueFromDedicatedThread {
            let descriptors = try IPCBuiltInMethodCatalog.offlineNotificationDescriptors(
                examples: .init(illustrativeIdentifier: UUIDv7.generate()))
            let invocation = try IPCDescriptorInvocationParser.parse(
                ["message", "from pane environment"],
                descriptors: descriptors, correlationIDGenerator: { UUIDv7.generate() })
            let client = AgentStudioIPCClient(
                configuration: .init(socketPath: environment["AGENTSTUDIO_IPC_SOCKET"] ?? ""),
                descriptors: descriptors)
            let handler = PaneNotificationOfflineHandler(environment: environment)

            let outcome = try handler.handleUnreachableApp(invocation: invocation) {
                try client.requestFrame(invocation)
            }

            let rows = try CLIStore.openReader(url: storeURL, expectedChannel: .debug).get().readOutbox(after: 0).get()
                .entries
            return (
                outcome: outcome, rows: rows,
                legacyFileExists: FileManager.default.fileExists(
                    atPath: legacyDirectory.appending(path: "\(paneID.uuidString).notifications.ndjson").path)
            )
        }
        #expect(observed.outcome == .queued(reply: "message queued"))
        #expect(observed.rows.count == 1)
        if let entry = observed.rows.first, case .notice(let notice) = entry {
            #expect(notice.paneID == paneID)
        }
        #expect(!observed.legacyFileExists)
    }

    private func makeIdentityOwner(
        principalRegistry: AgentStudioIPCPrincipalRegistry,
        membership: @escaping @MainActor @Sendable (UUID, UUID) -> Bool,
        randomBytes: @escaping @Sendable () throws -> Data,
        inheritedEnvironment: [String: String] = ["PATH": "/usr/bin:/bin"],
        fixture: PaneIPCIdentityOwnerFixture
    ) -> PaneIPCIdentityOwner {
        PaneIPCIdentityOwner(
            principalRegistry: principalRegistry,
            socketURL: fixture.socketURL,
            cliStoreURL: fixture.rootDirectory.appending(path: "ipc/cli.sqlite"),
            cliStoreChannel: .debug,
            cliExecutableURL: fixture.cliExecutableURL,
            inheritedEnvironment: inheritedEnvironment,
            canonicalPaneMembership: membership,
            randomBytes: randomBytes
        )
    }

    private func makeRegistry(
        durableResolver: any AgentStudioIPCCredentialResolving,
        membership: @escaping @MainActor @Sendable (UUID, UUID) -> Bool
    ) -> AgentStudioIPCPrincipalRegistry {
        AgentStudioIPCPrincipalRegistry(
            runtimeId: UUIDv7.generate(),
            credentialResolver: durableResolver,
            canonicalPaneMembership: membership
        )
    }
}

private struct PaneIPCIdentityOwnerFixture {
    let rootDirectory: URL
    let socketURL: URL
    let spoolDirectory: URL
    let cliExecutableURL: URL

    init() throws {
        rootDirectory = FileManager.default.temporaryDirectory
            .appending(path: "agentstudio-pane-ipc-identity-\(UUIDv7.generate())")
        socketURL = rootDirectory.appending(path: "agentstudio.sock")
        spoolDirectory = rootDirectory.appending(path: "spool/v2", directoryHint: .isDirectory)
        cliExecutableURL = rootDirectory.appending(path: "AgentStudio.app/Contents/Helpers/agentstudio")
        try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
    }

    func removeFiles() {
        try? FileManager.default.removeItem(at: rootDirectory)
    }
}

private actor UnexpectedDurableCredentialResolver: AgentStudioIPCCredentialResolving {
    private(set) var lookupCount = 0

    func resolveCredential(
        _: AgentStudioIPCSubjectToken,
        serverRuntimeID _: UUID
    ) async throws -> AgentStudioIPCCredentialResolution {
        lookupCount += 1
        throw PaneIPCIdentityOwnerTestError.durableLookupUnavailable
    }

}

private final class PaneCredentialByteSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Data]
    private var recordedCallCount = 0

    init(_ values: [Data]) {
        self.values = values
    }

    var callCount: Int {
        lock.withLock { recordedCallCount }
    }

    func next() throws -> Data {
        try lock.withLock {
            recordedCallCount += 1
            guard !values.isEmpty else { throw PaneIPCIdentityOwnerError.randomBytesUnavailable }
            return values.removeFirst()
        }
    }
}

private enum PaneIPCIdentityOwnerTestError: Error {
    case durableLookupUnavailable
}
