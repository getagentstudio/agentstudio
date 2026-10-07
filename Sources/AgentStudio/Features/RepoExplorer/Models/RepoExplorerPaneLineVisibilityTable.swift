enum RepoExplorerPaneLineKind: Hashable, Sendable {
    case title, worktreeBranch, note, agentLine, sessionStatus, chips
}
enum RepoExplorerPaneLineVisibility: Sendable {
    case always, whenPresent, selectedWhenPresent

    func shows(present: Bool, selected: Bool) -> Bool {
        switch self {
        case .always: true
        case .whenPresent: present
        case .selectedWhenPresent: present && selected
        }
    }
}

/// Spec R13/R21a: ordered rows in this one table own selection and presence policy.
enum RepoExplorerPaneLineVisibilityTable {
    static let rows: [(kind: RepoExplorerPaneLineKind, visibility: RepoExplorerPaneLineVisibility)] = [
        (.title, .always),
        (.worktreeBranch, .whenPresent),
        (.note, .whenPresent),
        (.agentLine, .whenPresent),
        (.sessionStatus, .whenPresent),
        (.chips, .always),
    ]
    static func showsChips(selected: Bool) -> Bool {
        rows.first { $0.kind == .chips }?.visibility.shows(present: true, selected: selected) == true
    }
    static func lines(
        _ candidates: [RepoExplorerPaneLineKind: RepoExplorerPaneRowLine], selected: Bool
    ) -> [RepoExplorerPaneRowLine] {
        rows.compactMap { row in
            guard row.visibility.shows(present: candidates[row.kind] != nil, selected: selected) else { return nil }
            return candidates[row.kind]
        }
    }
}
