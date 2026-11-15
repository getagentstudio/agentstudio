import Foundation

package struct KindChipModel: Equatable, Sendable {
    package enum Kind: Hashable, Sendable { case failure, needsYou, done, info }
    package let kind: Kind
    package let count: Int
    package init(kind: Kind, count: Int) {
        self.kind = kind
        self.count = count
    }
}

package enum ToolbarItemModel: Equatable, Sendable {
    // The empty toolbar selection is explicit.
    // swiftlint:disable:next discouraged_none_name
    case none
    case chips([KindChipModel])
    case agentLine(text: String, bracketedAge: String)
}
