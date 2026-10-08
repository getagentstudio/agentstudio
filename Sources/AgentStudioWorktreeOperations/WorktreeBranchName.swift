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
        if let rejection = syntaxRejection(text, whitespaceAndControl: .newBranch) { return .failure(rejection) }
        return .success(Self(rawValue: text))
    }

    /// Whether `text` could name a branch that already exists: `validated`'s rules without the length cap,
    /// which only a new branch's ref and destination slug need, and refusing only the whitespace and control
    /// characters Git itself refuses, so a Git-legal name with other Unicode spacing can still be a start.
    package static func isWellFormedExistingName(_ text: String) -> Bool {
        !text.isEmpty && syntaxRejection(text, whitespaceAndControl: .existingBranch) == nil
    }

    /// Which whitespace and control characters make a name unusable.
    private enum WhitespaceAndControlRule {
        /// A branch the app creates: any Unicode whitespace, newline, control or format character, which
        /// also keeps its destination slug clean.
        case newBranch
        /// A branch that may already exist: only what `git check-ref-format` refuses, the ASCII control
        /// characters, DEL and the space.
        case existingBranch

        func rejects(_ scalar: Unicode.Scalar) -> Bool {
            switch self {
            case .newBranch:
                CharacterSet.whitespacesAndNewlines.contains(scalar) || CharacterSet.controlCharacters.contains(scalar)
            case .existingBranch:
                scalar.value < 0x20 || scalar.value == 0x7F || scalar == " "
            }
        }
    }

    private static func syntaxRejection(
        _ text: String,
        whitespaceAndControl: WhitespaceAndControlRule
    ) -> WorktreeBranchNameRejection? {
        guard !text.unicodeScalars.contains(where: whitespaceAndControl.rejects) else {
            return .containsWhitespaceOrControlCharacter
        }
        if let forbidden = text.first(where: forbiddenCharacters.contains) {
            return .containsForbiddenCharacter(forbidden)
        }
        if let sequence = forbiddenSequences.first(where: text.contains) {
            return .containsForbiddenSequence(sequence)
        }
        // `--branch` rejects `HEAD` itself, though a lower-level ref may contain it.
        guard text != "@", text != "HEAD", !text.hasPrefix("-") else { return .invalidComponentBoundary }
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
