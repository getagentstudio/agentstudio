package enum WorktreeCommandLineHelp {
    package static let overview = """
        Usage: agentstudio worktree <command> [options]

        Commands:
          new <branch>         Open an existing local or origin branch in a copy-on-write fork of the main checkout
          new -c <branch>      Create <branch> in a copy-on-write fork of the main checkout
          list [target...]     List worktrees: changes, integration, tmp/ evidence, removal readiness
          remove <target...>   Remove worktrees and their integrated branches (destructive)
          prune                Preview removable worktrees; may still fetch; use --no-fetch for a fully read-only preview; --apply removes them

        Run 'agentstudio worktree <command> --help' for that command's options.
        Runs locally through Git; needs no app or IPC.
        """

    package static let newUsage = """
        Usage: agentstudio worktree new <branch> [options]
          -c, --create            Create <branch>; required with --from-branch or --changes-only
          --repo <path>           Use this repository path
          --from <worktree>       Copy the named worktree
          --from-branch <branch>  Start the new branch at <branch>; requires -c
          --no-fork               Use a plain checkout of tracked files
          --changes-only          Carry tracked changes and eligible untracked files; requires -c and --from
          --no-fetch              Use refs already on disk
          --json                  Print machine-readable output
        Example: agentstudio worktree new feature/search
        Example: agentstudio worktree new -c feature/search --from /path/to/worktree --changes-only
        """

    package static let listUsage = """
        Usage: agentstudio worktree list [target...] [options]
          --repo <path>           List worktrees for this repository
          --no-fetch              Skip the integration-target fetch
          --json                  Print machine-readable output
        Example: agentstudio worktree list
        Example: agentstudio worktree list feature/search --repo /path/to/repository --no-fetch
        """

    package static let removeUsage = """
        Usage: agentstudio worktree remove <target...> [options]
          --repo <path>           Remove worktrees from this repository
          --no-fetch              Skip the integration-target fetch
          -f, --force             Discard working changes
          -D                      Delete a branch with remaining contribution
          --no-delete-branch      Keep the local branch
          --archive-to-main       Copy tmp/ evidence to the main worktree
          --archive-to <path>     Copy tmp/ evidence to this folder
          --discard-tmp           Discard tmp/ evidence
          --remove-stale-lock     Remove an identified stale Git lock
          --dry-run               Preview removal; may still fetch; use --no-fetch for a fully read-only preview
          --json                  Print machine-readable output
        Example: agentstudio worktree remove feature/search
        Example: agentstudio worktree remove /path/to/worktree --archive-to-main
        """

    package static let pruneUsage = """
        Usage: agentstudio worktree prune [options]
          --repo <path>           Prune worktrees from this repository
          --no-fetch              Skip the integration-target fetch
          --archive-to-main       Copy tmp/ evidence to the main worktree
          --archive-to <path>     Copy tmp/ evidence to this folder
          --apply                 Remove eligible worktrees
          --json                  Print machine-readable output
        Example: agentstudio worktree prune
        Example: agentstudio worktree prune --apply --archive-to-main
        """

    package static func usage(for command: String) -> String? {
        switch command {
        case "new": newUsage
        case "list": listUsage
        case "remove": removeUsage
        case "prune": pruneUsage
        default: nil
        }
    }

    package static func isCommand(_ argument: String) -> Bool {
        usage(for: argument) != nil
    }
}
