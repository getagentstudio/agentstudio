export const marketingCopy = {
  productName: "Agent Studio",
  applicationCategory: "DeveloperApplication",
  hero: {
    eyebrow: "Native macOS. Repo-aware. Terminal-first.",
    headline: "Run dozens of agents in one workspace. Stay oriented. Miss nothing.",
    headlineSetupFirst: "Run dozens of agents",
    headlineSetupSecondBeforeAccent: "in one ",
    headlineSetupSecondAccent: "workspace.",
    headlinePayoff: "Stay oriented. Miss nothing.",
    scrollCue: "Scroll",
    scrollCueAriaLabel: "Scroll to the first Agent Studio image",
    description:
      "Agent Studio is a native macOS IDE for parallel coding agents, with your repositories and worktrees within reach. Your agents run in Ghostty terminals with files and diffs right beside them.",
  },
  stories: {
    proofRun: {
      label: "Agents side by side",
      description: "Two agents work in separate worktrees. A drawer shows one worktree's changes.",
      phoneDescription: "Two agents work in separate worktrees in one window.",
    },
    proofReview: {
      label: "Review and comment",
      description: "Read an agent's changes and leave a comment on a line.",
      phoneDescription: "Comment on a line you review.",
    },
    proofPanes: {
      label: "Panes by activity",
      description: "Panes are grouped by recent activity, with the latest activity in Just Now.",
      phoneDescription: "Panes grouped by recent activity.",
    },
    parallelWork: {
      label: "Parallel agents",
      description: "See which repo, worktree, branch, and directory each of your agents is using.",
      phoneDescription: "See every agent's repo, worktree, and branch.",
      imageDescription:
        "Agent Studio All Panes showing active Codex and Claude Code sessions with repository, worktree, branch, and activity context.",
    },
    watchFolders: {
      label: "Watch your repos",
      description: "Agent Studio watches your repos. Stay oriented across every repo and worktree.",
      phoneDescription:
        "Agent Studio watches your repos. You can easily create or view terminals in all your repos.",
    },
    paneDrawer: {
      label: "Pane drawer",
      description: "Keep related terminals and tools attached to the agent that needs them.",
      phoneDescription: "Keep a Git terminal with its task.",
    },
    quickFind: {
      label: "Command bar",
      description: "Press Cmd+P to find your repositories, worktrees, panes, tabs, and commands.",
      phoneDescription: "Find your repos, panes, and commands.",
      imageDescription:
        "Agent Studio command bar showing recent repositories and command, pane, and repository scopes with the global sidebar hidden.",
    },
    files: {
      label: "Files",
      description: "Browse your repository without leaving the task you're working on.",
      phoneDescription: "Keep source beside the task.",
    },
    review: {
      label: "Review",
      description:
        "Review every changed file in one continuous diff, with the Changed Files tree beside it.",
      phoneDescription: "Browse changed files beside the diff.",
      imageDescription:
        "Agent Studio Review showing an AGENTS.md diff and its Changed Files tree, with the global sidebar hidden.",
    },
    reviewComment: {
      label: "Comment on a line",
      description:
        "Leave a Markdown comment on any changed line. The thread opens right in the diff.",
      phoneDescription: "Comment on a line in the diff.",
    },
    gitContext: {
      label: "Git and PR context",
      description: "See the branch, changes, and pull request beside the work.",
      phoneDescription: "See a PR beside its branch and worktree.",
    },
    quitInFlight: {
      label: "Quit with work in flight",
      description:
        "Quit with agents mid-task. Their terminal sessions keep running while the app is closed.",
      phoneDescription: "Quit mid-task; terminals keep running.",
    },
    persistence: {
      label: "Persistent terminal sessions",
      description:
        "Reopen the app to restore tabs, panes, drawers, layouts, and terminal sessions.",
    },
  },
  // Approved feature-detail strings that chapter steps and proof images reuse.
  featureDetails: {
    items: [
      {
        id: "navigation",
        title: {
          beforeAccent: "Find ",
          accent: "your way",
          afterAccent: " around",
        },
        summary: "Filter the sidebar to find matching repositories and worktrees.",
      },
      {
        id: "task-tools",
        imageDescription:
          "Agent Studio showing a Codex task with a related terminal in its attached drawer.",
      },
      {
        id: "arrangements",
        detail: "When one task needs your full attention, Pane Zoom gives it the workspace.",
        paneZoomLabel: "Pane Zoom",
      },
    ],
  },
  chapters: {
    proof: {
      title: { beforeAccent: "See Agent Studio ", accent: "running", afterAccent: "." },
    },
    manyAgents: {
      title: { beforeAccent: "Many agents, ", accent: "one map", afterAccent: "." },
    },
    contextWithTask: {
      title: { beforeAccent: "Context stays with ", accent: "the task", afterAccent: "." },
    },
    findAndFocus: {
      title: { beforeAccent: "Find it, ", accent: "focus it", afterAccent: "." },
    },
    review: {
      title: {
        beforeAccent: "Review without leaving ",
        accent: "the workspace",
        afterAccent: ".",
      },
    },
    comeBack: {
      title: { beforeAccent: "Close the app. ", accent: "Agents keep running", afterAccent: "." },
      sessionRestoreVideoFallback: "This browser cannot play the session restore video.",
    },
  },
  // Accessible names for pause/play controls on motion that runs longer than
  // five seconds (WCAG 2.2.2).
  motionControls: {
    pauseAnimation: "Pause animation",
    playAnimation: "Play animation",
    pauseVideo: "Pause video",
    playVideo: "Play video",
  },
  installation: {
    commands: ["brew tap getagentstudio/agentstudio", "brew install --cask agent-studio"],
    copyButton: "Copy install commands",
    copyButtonVisible: "Copy",
    copiedStatus: "Copied",
    failedStatus: "Select and copy the command",
    systemRequirement: "Requires macOS 26 or later.",
  },
  navigation: {
    skipToContent: "Skip to content",
    homeLabel: "Agent Studio home",
    primaryLabel: "Primary navigation",
    githubAction: "GitHub",
  },
  socialLinks: {
    label: "Shravan Sunder profile links",
    github: {
      label: "Shravan Sunder on GitHub",
      url: "https://github.com/shravansunder",
    },
    x: {
      label: "Shravan Sunder on X",
      url: "https://x.com/shravansunder",
    },
  },
  ghosttyUrl: "https://ghostty.org",
  finalCallToAction: {
    starOnGitHub: "Star on GitHub",
    starShort: "Star",
    copyInstall: "Copy install",
    copyShort: "Copy",
    copiedInstall: "Copied ✓",
    technologyCredit: "👻 Built on Ghostty. ",
    creatorPrefix: "🛠️ Made by ",
    creatorName: "Shravan Sunder",
  },
  githubUrl: "https://github.com/getagentstudio/agentstudio",
} as const;

export const installCommandText = marketingCopy.installation.commands.join("\n");
