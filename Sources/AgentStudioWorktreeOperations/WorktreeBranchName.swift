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
        if let rejection = syntaxRejection(text, rules: .newBranch) { return .failure(rejection) }
        return .success(Self(rawValue: text))
    }

    /// Whether `text` could name a branch that already exists, by git's rule for a branch name: what
    /// `git check-ref-format refs/heads/<text>` accepts, less a leading `-` and `HEAD`, which `git branch`
    /// refuses. There is no length cap; only a new branch's ref and destination slug need one.
    package static func isWellFormedExistingName(_ text: String) -> Bool {
        !text.isEmpty && syntaxRejection(text, rules: .existingBranch) == nil
    }

    /// The rules a name is checked by. Both refuse git's forbidden characters and sequences, a leading `-`,
    /// `HEAD`, an empty component, a component starting with `.` or ending in `.lock`, and a name ending in `.`.
    private enum BranchNameRules {
        /// A branch the app creates, by the app's stricter policy, which also keeps its destination slug
        /// clean: any Unicode whitespace, newline, control or format character, a lone `@`, and every
        /// component ending in `.` are refused too.
        case newBranch
        /// A branch that may already exist, by git's rule: of whitespace and control characters only the
        /// ASCII control characters, DEL and the space are refused; `@` alone is a branch name, because git's
        /// single-`@` rule applies to the whole refname; and only the whole name may not end in `.`.
        case existingBranch

        func rejectsAsWhitespaceOrControl(_ scalar: Unicode.Scalar) -> Bool {
            switch self {
            case .newBranch:
                CharacterSet.whitespacesAndNewlines.contains(scalar) || CharacterSet.controlCharacters.contains(scalar)
            case .existingBranch:
                scalar.value < 0x20 || scalar.value == 0x7F || scalar == " "
            }
        }
    }

    private static func syntaxRejection(_ text: String, rules: BranchNameRules) -> WorktreeBranchNameRejection? {
        guard !text.unicodeScalars.contains(where: rules.rejectsAsWhitespaceOrControl) else {
            return .containsWhitespaceOrControlCharacter
        }
        if let forbidden = text.first(where: forbiddenCharacters.contains) {
            return .containsForbiddenCharacter(forbidden)
        }
        if let sequence = forbiddenSequences.first(where: text.contains) {
            return .containsForbiddenSequence(sequence)
        }
        // `git branch` refuses `HEAD` itself and a leading `-`, though a lower-level ref may have either.
        guard text != "HEAD", !text.hasPrefix("-"), rules == .existingBranch || text != "@" else {
            return .invalidComponentBoundary
        }
        let components = text.split(separator: "/", omittingEmptySubsequences: false)
        let hasInvalidComponent = components.contains { component in
            component.isEmpty || component.hasPrefix(".") || component.hasSuffix(".lock")
                || (rules == .newBranch && component.hasSuffix("."))
        }
        guard !hasInvalidComponent, !text.hasSuffix(".") else { return .invalidComponentBoundary }
        return nil
    }

    private init(rawValue: String) {
        self.rawValue = rawValue
    }
}
