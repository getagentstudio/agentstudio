import AgentStudioCore
import AgentStudioInfrastructure
import Foundation

/// One in-flight query belongs to the command bar session that issued it.
struct InFlightForkEligibilityQuery {
    let rootSessionGeneration: Int
    let token: UUID
    let task: Task<Void, Never>
}

struct InFlightDefaultStartPointQuery {
    let rootSessionGeneration: Int
    let token: UUID
    let task: Task<Void, Never>
}

struct InFlightBranchListingQuery {
    let rootSessionGeneration: Int
    let openingToken: UUID
    let task: Task<Void, Never>
}

extension CommandBarPanelController {
    func requestCreationQueriesIfNeeded(for level: CommandBarLevel) {
        switch level.creationQuery {
        case .branchListing(let repository):
            state.invalidateBranchListing(forRepositoryId: repository.id)
            requestDefaultStartPointIfNeeded(for: repository)
            requestBranchListingIfNeeded(for: repository, openingToken: UUIDv7.generate())
            requestForkEligibilityIfNeeded(for: repository)
        case .worktreeEligibility(let repository, let worktree):
            requestForkEligibilityIfNeeded(for: repository, worktrees: [worktree])
        case nil:
            break
        }
        if case .some(.branchListing(let repository)) = level.creationQuery {
            refreshCreationLevel(for: repository)
        }
        if case .some(.worktreeEligibility(let repository, _)) = level.creationQuery {
            refreshCreationLevel(for: repository)
        }
    }

    private func requestDefaultStartPointIfNeeded(for repository: Repo) {
        let generation = state.rootSessionGeneration
        guard let defaultStartPointResolver,
            state.defaultStartPointByRepositoryId[repository.id] == nil,
            defaultStartPointQueriesByRepositoryId[repository.id]?.rootSessionGeneration != generation
        else { return }
        let token = UUIDv7.generate()
        let task = Task { @MainActor [weak self] in
            do {
                let resolution = try await defaultStartPointResolver.resolveDefaultStartPoint(
                    repositoryPath: repository.repoPath)
                guard let self, self.state.rootSessionGeneration == generation else { return }
                if self.defaultStartPointQueriesByRepositoryId[repository.id]?.token == token {
                    self.defaultStartPointQueriesByRepositoryId.removeValue(forKey: repository.id)
                }
                self.state.recordDefaultStartPoint(resolution, forRepositoryId: repository.id)
                self.refreshCreationLevel(for: repository)
            } catch {
                guard let self, self.state.rootSessionGeneration == generation else { return }
                if self.defaultStartPointQueriesByRepositoryId[repository.id]?.token == token {
                    self.defaultStartPointQueriesByRepositoryId.removeValue(forKey: repository.id)
                }
                self.state.recordDefaultStartPointQueryFailure(forRepositoryId: repository.id)
                self.refreshCreationLevel(for: repository)
            }
        }
        defaultStartPointQueriesByRepositoryId[repository.id] = InFlightDefaultStartPointQuery(
            rootSessionGeneration: generation,
            token: token,
            task: task
        )
    }

    private func requestBranchListingIfNeeded(for repository: Repo, openingToken: UUID) {
        let generation = state.rootSessionGeneration
        guard let branchListing else { return }
        let task = Task { @MainActor [weak self] in
            do {
                let branchNames = try await branchListing.branchNames(
                    forRepositoryId: repository.id,
                    repositoryPath: repository.repoPath,
                    openingToken: openingToken)
                guard let self,
                    self.state.rootSessionGeneration == generation,
                    self.branchListingQueriesByRepositoryId[repository.id]?.openingToken == openingToken
                else { return }
                self.branchListingQueriesByRepositoryId.removeValue(forKey: repository.id)
                self.state.recordBranchNames(branchNames, forRepositoryId: repository.id)
                self.refreshCreationLevel(for: repository)
            } catch {
                guard let self,
                    self.state.rootSessionGeneration == generation,
                    self.branchListingQueriesByRepositoryId[repository.id]?.openingToken == openingToken
                else { return }
                self.branchListingQueriesByRepositoryId.removeValue(forKey: repository.id)
                self.state.recordBranchListingQueryFailure(forRepositoryId: repository.id)
                self.refreshCreationLevel(for: repository)
            }
        }
        branchListingQueriesByRepositoryId[repository.id] = InFlightBranchListingQuery(
            rootSessionGeneration: generation,
            openingToken: openingToken,
            task: task
        )
    }

    private func requestForkEligibilityIfNeeded(for repository: Repo, worktrees: [Worktree]? = nil) {
        guard let worktreeForkEligibility else { return }
        let generation = state.rootSessionGeneration
        for worktree in worktrees ?? repository.worktrees {
            guard state.forkEligibilityBySourceWorktreeId[worktree.id] == nil,
                currentSessionForkEligibilityQuery(for: worktree.id) == nil
            else { continue }
            let token = UUIDv7.generate()
            let task = Task { @MainActor [weak self] in
                let eligibility = await worktreeForkEligibility.forkEligibility(
                    sourceWorktreePath: worktree.path,
                    destinationDirectory: repository.repoPath.standardizedFileURL.deletingLastPathComponent()
                )
                guard let self else { return }
                if self.forkEligibilityQueriesBySourceWorktreeId[worktree.id]?.token == token {
                    self.forkEligibilityQueriesBySourceWorktreeId.removeValue(forKey: worktree.id)
                }
                guard self.state.rootSessionGeneration == generation else { return }
                self.state.recordForkEligibility(eligibility, forSourceWorktreeId: worktree.id)
                self.refreshCreationLevel(for: repository)
            }
            forkEligibilityQueriesBySourceWorktreeId[worktree.id] = InFlightForkEligibilityQuery(
                rootSessionGeneration: generation,
                token: token,
                task: task
            )
        }
    }

    private func refreshCreationLevel(for repository: Repo) {
        for level in state.navigationStack {
            refreshCreationLevel(level, for: repository)
        }
    }

    private func refreshCreationLevel(_ level: CommandBarLevel, for repository: Repo) {
        switch level.creationQuery {
        case .branchListing(let queriedRepository) where queriedRepository.id == repository.id:
            break
        case .worktreeEligibility(let queriedRepository, _) where queriedRepository.id == repository.id:
            break
        default:
            return
        }
        guard let currentRepository = CommandBarDataSource.availableRepository(repository, store: store) else {
            replaceCreationLevelWithoutActions(level)
            return
        }
        switch level.creationQuery {
        case .branchListing(let queriedRepository) where queriedRepository.id == repository.id:
            state.replaceLevel(
                CommandBarDataSource.worktreeCreationMenuLevel(
                    repository: currentRepository,
                    store: store,
                    repoCache: repoCache,
                    defaultStartPoint: state.defaultStartPointByRepositoryId[repository.id],
                    defaultQueryFailed: state.defaultStartPointQueryFailures.contains(repository.id),
                    branchNames: state.branchNamesByRepositoryId[repository.id],
                    branchListingFailed: state.branchListingQueryFailures.contains(repository.id),
                    eligibilityByWorktreeId: state.forkEligibilityBySourceWorktreeId,
                    focusedWorktreeId: focusedWorktreeId(in: currentRepository)
                ))
            if state.currentLevel?.id == level.id, !state.searchQuery.isEmpty {
                queryChanged(text: state.rawInput)
            }
        case .worktreeEligibility(let queriedRepository, let worktree) where queriedRepository.id == repository.id:
            guard let currentWorktree = currentRepository.worktrees.first(where: { $0.id == worktree.id }) else {
                replaceCreationLevelWithoutActions(level)
                return
            }
            let presence = CommandBarDataSource.buildWorktreePresence(
                worktree: currentWorktree,
                repo: currentRepository,
                store: store
            )
            state.replaceLevel(
                CommandBarDataSource.buildWorktreeActionsLevel(
                    worktree: currentWorktree,
                    presence: presence,
                    canOpenInCurrentTab: canOpenWorktreeInCurrentTab,
                    dispatcher: dispatcher,
                    repository: currentRepository,
                    forkEligibility: state.forkEligibilityBySourceWorktreeId[currentWorktree.id]
                ))
        default:
            break
        }
        searchContextChanged()
    }

    private func replaceCreationLevelWithoutActions(_ level: CommandBarLevel) {
        state.replaceLevel(
            CommandBarLevel(
                id: level.id,
                title: level.title,
                parentLabel: level.parentLabel,
                scopeLabel: level.scopeLabel,
                breadcrumbIcon: level.breadcrumbIcon,
                items: [],
                creationQuery: level.creationQuery
            ))
        searchContextChanged()
    }

    private func focusedWorktreeId(in repository: Repo) -> UUID? {
        let workspaceTab = WorkspaceTabLayoutDerived(
            shellAtom: store.tabShellAtom,
            arrangementAtom: store.tabArrangementAtom
        )
        let focusedPane = atom(\.workspaceFocusedPane).resolve(
            workspaceTab: workspaceTab,
            workspacePane: store.paneAtom,
            requestedOwner: atom(\.workspaceFocusOwner).owner
        )
        guard focusedPane?.repoId == repository.id else { return nil }
        return focusedPane?.worktreeId
    }

    private func currentSessionForkEligibilityQuery(for sourceWorktreeId: UUID) -> InFlightForkEligibilityQuery? {
        guard let query = forkEligibilityQueriesBySourceWorktreeId[sourceWorktreeId],
            query.rootSessionGeneration == state.rootSessionGeneration
        else { return nil }
        return query
    }
}
