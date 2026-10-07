import AgentStudioAppIPC
import AgentStudioCLIStore
import AgentStudioInfrastructure
import CryptoKit
import Foundation
import Security
import os.log

struct PaneIPCEnvironment: Sendable, Equatable {
    let paneID: UUID
    let workspaceID: UUID
    let credentialRecordID: UUID
    let environmentVariables: [String: String]
}

enum PaneIPCIdentityOwnerError: Error, Equatable {
    case paneNotInWorkspace
    case invalidRandomByteCount
    case randomBytesUnavailable
}

@MainActor
final class PaneIPCIdentityOwner {
    private static let logger = Logger(subsystem: "com.agentstudio", category: "PaneIPCIdentityOwner")
    private static let authorityEnvironmentKeys = [
        "AGENTSTUDIO_PANE_ID",
        "AGENTSTUDIO_WORKSPACE_ID",
        "AGENTSTUDIO_IPC_SOCKET",
        "AGENTSTUDIO_PANE_TOKEN",
        "AGENTSTUDIO_CLI_STORE",
        "AGENTSTUDIO_CLI_STORE_CHANNEL",
        "AGENTSTUDIO_CLI",
    ]
    private let principalRegistry: AgentStudioIPCPrincipalRegistry
    private let socketURL: URL
    private let cliStoreURL: URL
    private let cliStoreChannel: CLIStoreChannel
    private let cliExecutableURL: URL
    private let inheritedEnvironment: [String: String]
    private let canonicalPaneMembership: @Sendable (UUID, UUID) -> Bool
    private let randomBytes: @Sendable () throws -> Data
    private var environmentsByPaneID: [UUID: PaneIPCEnvironment] = [:]

    init(
        principalRegistry: AgentStudioIPCPrincipalRegistry,
        socketURL: URL,
        cliStoreURL: URL,
        cliStoreChannel: CLIStoreChannel,
        cliExecutableURL: URL,
        inheritedEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        canonicalPaneMembership: @escaping @Sendable (UUID, UUID) -> Bool,
        randomBytes: @escaping @Sendable () throws -> Data = secureRandomBytes
    ) {
        self.principalRegistry = principalRegistry
        self.socketURL = socketURL
        self.cliStoreURL = cliStoreURL
        self.cliStoreChannel = cliStoreChannel
        self.cliExecutableURL = cliExecutableURL
        self.inheritedEnvironment = inheritedEnvironment
        self.canonicalPaneMembership = canonicalPaneMembership
        self.randomBytes = randomBytes
    }

    func environment(paneID: UUID, workspaceID: UUID) throws -> PaneIPCEnvironment {
        guard canonicalPaneMembership(paneID, workspaceID) else {
            throw PaneIPCIdentityOwnerError.paneNotInWorkspace
        }
        if let cached = environmentsByPaneID[paneID] {
            guard cached.workspaceID == workspaceID else {
                throw PaneIPCIdentityOwnerError.paneNotInWorkspace
            }
            return cached
        }

        let credentialBytes = try randomBytes()
        guard credentialBytes.count == 32 else {
            throw PaneIPCIdentityOwnerError.invalidRandomByteCount
        }
        let rawToken = AgentStudioIPCSubjectToken(rawValue: credentialBytes.base64EncodedString())
        let verifierSHA256 = Data(SHA256.hash(data: Data(rawToken.rawValue.utf8)))
        let credentialRecordID = UUIDv7.generate()
        try principalRegistry.registerIssuedPaneCredential(
            paneID: paneID,
            workspaceID: workspaceID,
            credentialRecordID: credentialRecordID,
            verifierSHA256: verifierSHA256
        )
        let environment = PaneIPCEnvironment(
            paneID: paneID,
            workspaceID: workspaceID,
            credentialRecordID: credentialRecordID,
            environmentVariables: makeEnvironment(
                paneID: paneID,
                workspaceID: workspaceID,
                rawToken: rawToken
            )
        )
        environmentsByPaneID[paneID] = environment
        return environment
    }

    func terminalEnvironment(paneID: UUID, workspaceID: UUID) -> [String: String] {
        do {
            return try environment(paneID: paneID, workspaceID: workspaceID).environmentVariables
        } catch {
            Self.logger.warning("Pane IPC environment unavailable; terminal startup continuing without IPC authority")
            var environment = makeTerminalShellEnvironment()
            for key in Self.authorityEnvironmentKeys {
                environment[key] = ""
            }
            return environment
        }
    }

    /// The credential record ID stays out of the pane's environment: it is
    /// persistence and correlation identity, not authority, and nothing in the
    /// pane reads it.
    private func makeEnvironment(
        paneID: UUID,
        workspaceID: UUID,
        rawToken: AgentStudioIPCSubjectToken
    ) -> [String: String] {
        var environmentVariables = makeTerminalShellEnvironment()
        environmentVariables["AGENTSTUDIO_PANE_ID"] = paneID.uuidString
        environmentVariables["AGENTSTUDIO_WORKSPACE_ID"] = workspaceID.uuidString
        environmentVariables["AGENTSTUDIO_IPC_SOCKET"] = socketURL.path
        environmentVariables["AGENTSTUDIO_PANE_TOKEN"] = rawToken.rawValue
        environmentVariables["AGENTSTUDIO_CLI_STORE"] = cliStoreURL.path
        environmentVariables["AGENTSTUDIO_CLI_STORE_CHANNEL"] = cliStoreChannel.rawValue
        environmentVariables["AGENTSTUDIO_CLI"] = cliExecutableURL.path
        return environmentVariables
    }

    private func makeTerminalShellEnvironment() -> [String: String] {
        var environment = inheritedEnvironment
        let helpersDirectory = cliExecutableURL.deletingLastPathComponent()
        let macOSDirectory = helpersDirectory.deletingLastPathComponent().appending(path: "MacOS").path
        let inheritedPath = inheritedEnvironment["PATH"] ?? ""
        var pathEntries = inheritedPath.isEmpty ? [] : inheritedPath.components(separatedBy: ":")
        pathEntries.removeAll { $0 == macOSDirectory }
        pathEntries.append(helpersDirectory.path)
        // Ghostty applies surface overrides after its own executable-directory
        // injection. Its post-startup shell hook must expose the CLI directory.
        environment["PATH"] = pathEntries.joined(separator: ":")
        environment["GHOSTTY_BIN_DIR"] = helpersDirectory.path
        return environment
    }
}

private func secureRandomBytes() throws -> Data {
    var bytes = Data(count: 32)
    let result = bytes.withUnsafeMutableBytes { buffer in
        SecRandomCopyBytes(kSecRandomDefault, 32, buffer.baseAddress!)
    }
    guard result == errSecSuccess else {
        throw PaneIPCIdentityOwnerError.randomBytesUnavailable
    }
    return bytes
}
