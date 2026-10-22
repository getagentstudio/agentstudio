import Foundation

package enum PaneManagementIcon: Equatable {
    case octicon(String)
    case system(String)
}

package struct PaneManagementIdentityRow: Equatable, Identifiable {
    package let id: String
    package let icon: PaneManagementIcon
    package let text: String
    package let toolTip: String?
    package let copyValue: String?

    package init(id: String, icon: PaneManagementIcon, text: String, toolTip: String?, copyValue: String? = nil) {
        self.id = id
        self.icon = icon
        self.text = text
        self.toolTip = toolTip
        self.copyValue = copyValue
    }
}

package struct WorkspaceStatusChipsModel: Equatable {
    package let branchStatus: GitBranchStatus

    package init(branchStatus: GitBranchStatus) {
        self.branchStatus = branchStatus
    }
}

@MainActor
package struct PaneManagementContext: Equatable {
    package let paneId: UUID
    package let identityRows: [PaneManagementIdentityRow]
    package let statusChips: WorkspaceStatusChipsModel?
    package let targetPath: URL?
    package let showsIdentityBlock: Bool

    package static func project(
        paneId: UUID,
        store: WorkspaceStore
    ) -> Self {
        let workspacePane = store.paneAtom
        let workspaceRepositoryTopology = store.repositoryTopologyAtom
        let parts = atom(\.paneDisplay).displayParts(for: paneId)
        let repoCache = atom(\.repoCache)
        let pane = workspacePane.pane(paneId)
        let resolvedContext = workspaceRepositoryTopology.validatedAssociation(
            repoId: pane?.repoId,
            worktreeId: pane?.worktreeId
        )
        let resolvedTargetPath = pane?.metadata.cwd
        let hasWorkspaceAssociation =
            resolvedContext != nil
            || parts.repoName != nil
            || parts.worktreeFolderName != nil
        let showsIdentityBlock: Bool = {
            switch pane?.metadata.contentType {
            case .browser:
                return hasWorkspaceAssociation
            case .none:
                return false
            default:
                return true
            }
        }()

        let statusChips: WorkspaceStatusChipsModel?
        if let resolvedWorktreeId = resolvedContext?.worktree.id {
            let worktreeEnrichment = repoCache.worktreeEnrichment(for: resolvedWorktreeId)
            let pullRequestFacts = pullRequestFacts(
                for: worktreeEnrichment,
                repoCache: repoCache
            )
            let branchStatus = GitBranchStatus.status(
                enrichment: worktreeEnrichment,
                pullRequestFacts: pullRequestFacts
            )
            statusChips = WorkspaceStatusChipsModel(branchStatus: branchStatus)
        } else {
            statusChips = nil
        }

        let identityRows = projectIdentityRows(
            pane: pane,
            resolvedContext: resolvedContext,
            displayParts: parts,
            targetPath: resolvedTargetPath
        )

        return Self(
            paneId: paneId,
            identityRows: identityRows,
            statusChips: statusChips,
            targetPath: resolvedTargetPath,
            showsIdentityBlock: showsIdentityBlock
        )
    }

    package func includingVerifiedLiveSession(_ session: SessionSummary?) -> Self {
        var rows = identityRows
        if let previousSession = rows.firstIndex(where: { $0.id == "session" }) {
            rows.remove(at: previousSession)
        }
        if let session {
            let identity = "\(session.provider.value) · \(session.sessionRef.value)"
            rows.insert(
                .init(
                    id: "session", icon: .system("person.crop.circle"), text: identity, toolTip: identity,
                    copyValue: session.sessionRef.value),
                at: rows.firstIndex { $0.id == "pane" } ?? rows.endIndex)
        }
        return Self(
            paneId: paneId, identityRows: rows, statusChips: statusChips,
            targetPath: targetPath, showsIdentityBlock: showsIdentityBlock)
    }

    private static func pullRequestFacts(
        for enrichment: WorktreeEnrichment?,
        repoCache: RepoCacheAtom
    ) -> PullRequestFacts? {
        enrichment.flatMap { enrichment in
            RepoBranchKey(repoId: enrichment.repoId, branch: enrichment.branch)
                .flatMap(repoCache.pullRequestFacts(for:))
        }
    }

    private static func projectIdentityRows(
        pane: Pane?,
        resolvedContext: (repo: Repo, worktree: Worktree)?,
        displayParts: PaneDisplayParts,
        targetPath: URL?
    ) -> [PaneManagementIdentityRow] {
        var rows: [PaneManagementIdentityRow] = []

        if let repoName = resolvedContext?.repo.name ?? displayParts.repoName {
            rows.append(
                PaneManagementIdentityRow(
                    id: "repo",
                    icon: .octicon("octicon-repo"),
                    text: repoName,
                    toolTip: nil
                )
            )
        }

        if let branchName = displayParts.branchName {
            rows.append(
                PaneManagementIdentityRow(
                    id: "branch",
                    icon: .octicon("octicon-git-branch"),
                    text: branchName,
                    toolTip: nil
                )
            )
        }

        if let worktree = resolvedContext?.worktree {
            rows.append(
                PaneManagementIdentityRow(
                    id: "worktree",
                    icon: .octicon(worktree.isMainWorktree ? "octicon-star-fill" : "octicon-git-worktree"),
                    text: worktree.name,
                    toolTip: worktree.path.path
                )
            )
        }

        if let targetPath {
            let compactPath = compactPathLabel(
                for: targetPath,
                worktreeRoot: resolvedContext?.worktree.path
            )
            rows.append(
                PaneManagementIdentityRow(
                    id: "cwd",
                    icon: .system("folder"),
                    text: compactPath,
                    toolTip: targetPath.path
                )
            )
        }

        if rows.isEmpty, let fallback = displayParts.cwdFolderName ?? displayParts.primaryLabel.nilIfEmpty {
            rows.append(
                PaneManagementIdentityRow(
                    id: "fallback",
                    icon: .system("terminal"),
                    text: fallback,
                    toolTip: nil
                )
            )
        }

        if let pane {
            rows.append(
                .init(
                    id: "pane", icon: .system("terminal"), text: pane.id.uuidString, toolTip: pane.id.uuidString,
                    copyValue: pane.id.uuidString))
        }
        return rows
    }

    private static func compactPathLabel(for targetPath: URL, worktreeRoot: URL?) -> String {
        let normalizedTarget = targetPath.standardizedFileURL.path

        if let worktreeRoot {
            let normalizedRoot = worktreeRoot.standardizedFileURL.path
            if normalizedTarget == normalizedRoot {
                let folderName = targetPath.lastPathComponent
                return folderName.isEmpty ? normalizedTarget : folderName
            }
            let prefix = normalizedRoot.hasSuffix("/") ? normalizedRoot : normalizedRoot + "/"
            if normalizedTarget.hasPrefix(prefix) {
                return String(normalizedTarget.dropFirst(prefix.count))
            }
        }

        return normalizedTarget
    }
}

extension String {
    fileprivate var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
