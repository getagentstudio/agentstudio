import Foundation

package enum RepoExplorerPaneTitleNormalizer {
    package static func normalizedTitle(
        liveTitle: String,
        cwd: URL?,
        shellExecutablePath: String?,
        isDrawer: Bool = false
    ) -> String {
        let normalizedTitle = liveTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let cwdPath = cwd?.standardizedFileURL.path
        let titleIsPathShaped =
            normalizedTitle.hasPrefix("/")
            || normalizedTitle.hasPrefix("~")
            || normalizedTitle.hasPrefix("…/")
            || normalizedTitle.hasPrefix(".../")
        let titleMatchesCWD =
            cwdPath.map { cwdPath in
                normalizedTitle == cwdPath || normalizedTitle.hasPrefix("\(cwdPath)/")
            } ?? false
        let isDrawerPlaceholder =
            isDrawer && normalizedTitle.caseInsensitiveCompare("Drawer") == .orderedSame
        guard isDrawerPlaceholder || normalizedTitle.isEmpty || titleIsPathShaped || titleMatchesCWD else {
            return normalizedTitle
        }

        guard !isDrawerPlaceholder else { return "zsh" }
        let shellName = shellExecutablePath.flatMap { executablePath -> String? in
            let lastPathComponent = URL(fileURLWithPath: executablePath).lastPathComponent
            return lastPathComponent.isEmpty ? nil : lastPathComponent
        }
        return shellName ?? "zsh"
    }

}
