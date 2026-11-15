import Foundation

package struct AgeText: Sendable, Equatable {
    package let text: String
    package let nextChange: Date
}

package struct StatusLine: Sendable, Equatable {
    package enum Kind: Sendable, Equatable { case working, monitoring, needsYou, failed, idle }
    package let kind: Kind
    package let text: String
}

package enum MessageKind: Sendable, Equatable { case failure, needsYou, done, info }

package struct KindCount: Sendable, Equatable {
    package let kind: MessageKind
    package let count: Int
}

package enum ToolbarSelection: Sendable, Equatable {
    // swiftlint:disable:next discouraged_none_name
    case none
    case chips([KindCount])
    case agentLine(text: String, age: AgeText)
}

package enum MessageGroupKind: Sendable, Equatable { case failed, needsYou, done, info, resolved }

package enum RowActionAvailability: Sendable, Equatable {
    // swiftlint:disable:next discouraged_none_name
    case none
    case noticeActions
    case askForm
}
