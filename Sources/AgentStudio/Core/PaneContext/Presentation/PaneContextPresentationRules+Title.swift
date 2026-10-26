import Foundation

extension PaneContextPresentationRules {
    package static func displayTitle(
        raw: String, agentTitle: String? = nil, cwd: URL?, shell: String?, isDrawer: Bool = false
    ) -> String {
        if let agentTitle, !agentTitle.isEmpty { return strippingTitleSpinners(agentTitle) }
        let title = strippingTitleSpinners(raw)
        let cwdPath = cwd?.standardizedFileURL.path
        let isPath = title.hasPrefix("/") || title.hasPrefix("~") || title.hasPrefix("…/") || title.hasPrefix(".../")
        let matchesCWD = cwdPath.map { title == $0 || title.hasPrefix("\($0)/") } ?? false
        let isDrawerPlaceholder = isDrawer && title.caseInsensitiveCompare("Drawer") == .orderedSame
        guard isDrawerPlaceholder || title.isEmpty || isPath || matchesCWD else { return title }
        guard !isDrawerPlaceholder else { return "zsh" }
        let shellName = shell.map { URL(fileURLWithPath: $0).lastPathComponent }
        return shellName.flatMap { $0.isEmpty ? nil : $0 } ?? "zsh"
    }

    package static func strippingTitleSpinners(_ raw: String) -> String {
        var title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while let character = title.first, let scalar = character.unicodeScalars.first,
            scalar.value == 0x2733 || (0x2800...0x28FF).contains(scalar.value)
        {
            title.removeFirst()
            title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return title
    }
}
