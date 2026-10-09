import Foundation

package enum WorktreeDestinationNaming {
    /// Folder-safe form of a branch name: `feat/worktree-commands` becomes
    /// `feat-worktree-commands`. Returns `nil` when the branch has no folder-safe characters.
    package static func folderSlug(for branchName: WorktreeBranchName) -> String? {
        folderSlug(forRawName: branchName.rawValue)
    }

    /// The same slug for any typed text, a valid branch name or not. Everything outside ASCII letters,
    /// digits and `._-` becomes `-` (a run becomes one), and leading and trailing `.` and `-` are trimmed.
    /// So the slug holds no `/`, and the sibling folder it names, `<repository folder>.<slug>`, is one path
    /// component that is never `.` or `..`: no input can name a path outside the repository's parent.
    package static func folderSlug(forRawName rawName: String) -> String? {
        var slug = ""
        for character in rawName {
            let isFolderSafe =
                character.isASCII && (character.isLetter || character.isNumber || "._-".contains(character))
            let mapped: Character = isFolderSafe ? character : "-"
            guard !(mapped == "-" && slug.last == "-") else { continue }
            slug.append(mapped)
        }
        slug = trimmedSlug(String(slug.prefix(WorktreeCreationPolicy.maximumDestinationSlugLength)))
        return slug.isEmpty ? nil : slug
    }

    /// Places the new worktree beside the supplied repository checkout, using the
    /// command bar's branch-derived sibling-name rule.
    package static func siblingPath(repositoryPath: URL, branchName: WorktreeBranchName) -> URL? {
        siblingPath(repositoryPath: repositoryPath, rawName: branchName.rawValue)
    }

    /// The sibling folder `folderSlug(forRawName:)` names for any typed text.
    package static func siblingPath(repositoryPath: URL, rawName: String) -> URL? {
        guard let slug = folderSlug(forRawName: rawName) else { return nil }
        let repositoryFolder = repositoryPath.standardizedFileURL
        return repositoryFolder.deletingLastPathComponent().appending(
            path: repositoryFolder.lastPathComponent + WorktreeCreationPolicy.destinationSlugSeparator + slug,
            directoryHint: .isDirectory
        ).standardizedFileURL
    }

    private static func trimmedSlug(_ slug: String) -> String {
        slug.trimmingCharacters(in: CharacterSet(charactersIn: ".-"))
    }
}
