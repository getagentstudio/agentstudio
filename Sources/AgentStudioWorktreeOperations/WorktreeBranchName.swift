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

    /// Git's forbidden characters, sequences and component rules are ASCII, and git applies them to the
    /// name's bytes, so they are matched on UTF-8 bytes here too. Comparing `Character`s would let a
    /// combining mark hide one: `a~\u{301}b` holds `~` as git sees it, but not as a `Character`.
    private static let forbiddenBytes: [UInt8] = Array("~^:?*[\\".utf8)
    private static let forbiddenSequences = ["..", "@{", "//"]
    private static let lockSuffix: [UInt8] = Array(".lock".utf8)

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
        let bytes = Array(text.utf8)
        if let forbidden = bytes.first(where: forbiddenBytes.contains) {
            return .containsForbiddenCharacter(Character(Unicode.Scalar(forbidden)))
        }
        if let sequence = forbiddenSequences.first(where: { containsRun(Array($0.utf8), in: bytes) }) {
            return .containsForbiddenSequence(sequence)
        }
        // `git branch` refuses `HEAD` itself and a leading `-`, though a lower-level ref may have either.
        guard !bytes.elementsEqual("HEAD".utf8), bytes.first != UInt8(ascii: "-"),
            rules == .existingBranch || !bytes.elementsEqual("@".utf8)
        else {
            return .invalidComponentBoundary
        }
        let components = bytes.split(separator: UInt8(ascii: "/"), omittingEmptySubsequences: false)
        let hasInvalidComponent = components.contains { component in
            component.isEmpty || component.first == UInt8(ascii: ".")
                || component.suffix(lockSuffix.count).elementsEqual(lockSuffix)
                || (rules == .newBranch && component.last == UInt8(ascii: "."))
        }
        guard !hasInvalidComponent, bytes.last != UInt8(ascii: ".") else { return .invalidComponentBoundary }
        return nil
    }

    private static func containsRun(_ run: [UInt8], in bytes: [UInt8]) -> Bool {
        guard !run.isEmpty, bytes.count >= run.count else { return false }
        return (0...(bytes.count - run.count)).contains { start in
            bytes[start..<(start + run.count)].elementsEqual(run)
        }
    }

    private init(rawValue: String) {
        self.rawValue = rawValue
    }
}
