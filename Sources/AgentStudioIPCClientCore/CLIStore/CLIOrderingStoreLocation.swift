import AgentStudioCLIStore
import Foundation

/// The ordering store's existing explicit or runtime-metadata discovery proofs.
struct CLIOrderingStoreLocation {
    let url: URL
    let channel: CLIStoreChannel

    static func resolve(environment: [String: String], socketPath: String?) -> Self? {
        if let path = environment["AGENTSTUDIO_CLI_STORE"], !path.isEmpty {
            guard let channel = environment["AGENTSTUDIO_CLI_STORE_CHANNEL"].flatMap(CLIStoreChannel.init(rawValue:))
            else { return nil }
            return Self(url: URL(fileURLWithPath: path), channel: channel)
        }
        guard let socket = environment["AGENTSTUDIO_IPC_SOCKET"], !socket.isEmpty, socket == socketPath else {
            return nil
        }
        let directory = URL(fileURLWithPath: socket).deletingLastPathComponent()
        guard let data = try? Data(contentsOf: directory.appending(path: "runtime.json")),
            let metadata = try? JSONDecoder().decode(RuntimeMetadata.self, from: data),
            metadata.socketPath == socket, let channel = CLIStoreChannel(rawValue: metadata.channel)
        else { return nil }
        let store = directory.appending(path: "cli.sqlite")
        guard FileManager.default.fileExists(atPath: store.path) else { return nil }
        return Self(url: store, channel: channel)
    }

    private struct RuntimeMetadata: Decodable {
        let socketPath: String
        let channel: String
    }
}
