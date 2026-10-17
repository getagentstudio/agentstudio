import AgentStudioCore
import Foundation

/// Closed pre-session escape hatch. Product commands remain on the product transport.
package enum BridgePageCommand: String, Sendable, Codable, CaseIterable {
    case reloadBridgeWebView

    package var appCommand: AppCommand {
        switch self {
        case .reloadBridgeWebView: .reloadBridgeWebView
        }
    }

    var display: BridgePageCommandDisplay {
        let definition = appCommand.definition
        precondition(definition.surfacePolicy.exposes(.bridgePage))
        let action = definition.actionSpec
        let icon: String
        switch action.icon {
        case .system(let symbol): icon = symbol.rawValue
        case .octicon(let symbol): icon = symbol.rawValue
        }
        return BridgePageCommandDisplay(command: self, label: action.label, helpText: action.helpText, icon: icon)
    }
}

struct BridgePageCommandDisplay: Encodable, Sendable, Equatable {
    let command: BridgePageCommand
    let label: String
    let helpText: String
    let icon: String
}
