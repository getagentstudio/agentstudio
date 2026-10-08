import Foundation

/// Why typed text cannot name a new worktree branch. Mirrors the subset of
/// `git check-ref-format --branch` a user can reach by typing.
package enum WorktreeBranchNameRejection: Error, Equatable, Sendable {
    case empty
    case tooLong(maximumLength: Int)
    case containsWhitespaceOrControlCharacter
    case containsForbiddenCharacter(Character)
    case containsForbiddenSequence(String)
    case invalidComponentBoundary
}

/// A validated name for a branch the app is about to create. Empty is not a name.
package struct WorktreeBranchName: Equatable, Hashable, Sendable {
    package let rawValue: String

    private static let forbiddenCharacters: Set<Character> = ["~", "^", ":", "?", "*", "[", "\\"]
    private static let forbiddenSequences = ["..", "@{", "//"]

    package static func validated(_ text: String) -> Result<Self, WorktreeBranchNameRejection> {
        guard !text.isEmpty else { return .failure(.empty) }
        let maximumLength = WorktreeCreationPolicy.maximumBranchNameLength
        guard text.count <= maximumLength else { return .failure(.tooLong(maximumLength: maximumLength)) }
        if let rejection = syntaxRejection(text) { return .failure(rejection) }
        return .success(Self(rawValue: text))
    }

    /// Whether `text` could name a branch that already exists: the same `git check-ref-format --branch`
    /// syntax as `validated`, without the length cap only a new branch's ref and destination slug need.
    package static func isWellFormedExistingName(_ text: String) -> Bool {
        !text.isEmpty && syntaxRejection(text) == nil
    }

    private static func syntaxRejection(_ text: String) -> WorktreeBranchNameRejection? {
        let hasWhitespaceOrControl = text.unicodeScalars.contains {
            CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0)
        }
        guard !hasWhitespaceOrControl else { return .containsWhitespaceOrControlCharacter }
        if let forbidden = text.first(where: forbiddenCharacters.contains) {
            return .containsForbiddenCharacter(forbidden)
        }
        if let sequence = forbiddenSequences.first(where: text.contains) {
            return .containsForbiddenSequence(sequence)
        }
        guard text != "@", !text.hasPrefix("-") else { return .invalidComponentBoundary }
        let components = text.split(separator: "/", omittingEmptySubsequences: false)
        let hasInvalidComponent = components.contains { component in
            component.isEmpty || component.hasPrefix(".") || component.hasSuffix(".")
                || component.hasSuffix(".lock")
        }
        guard !hasInvalidComponent else { return .invalidComponentBoundary }
        return nil
    }

    private init(rawValue: String) {
        self.rawValue = rawValue
    }
}
