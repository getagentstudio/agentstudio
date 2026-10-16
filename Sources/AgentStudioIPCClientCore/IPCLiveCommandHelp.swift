import Foundation

/// Explicit live help reads only the presentation fields it renders.
/// Catalog validation and command argument admission belong to the app.
struct IPCLiveCommandHelp: Decodable {
    struct Command: Decodable {
        let id: String
        let title: String
        let description: String
    }

    let commands: [Command]
}
