// Typed fixture shapes for the recreation kit. Scene fixtures build immutable
// values of these types; kit components render them and never own content.

import type { KitIconName } from "./kit-icon-names";

/**
 * Whether an element is present in a scene's settled (final) frame. Collapsed
 * elements stay in the markup so a scene can show them earlier in its timeline.
 */
export type KitSettledPresence = "shown" | "collapsed";

/** How a kit element behaves in the phone layout's focused crop. */
export type KitPhoneRole = "shown" | "hidden";

export type KitBadge =
  | { readonly kind: "diff"; readonly added: number; readonly removed: number }
  | { readonly kind: "sync"; readonly ahead: number; readonly behind: number }
  | { readonly kind: "recency"; readonly label: string }
  | { readonly kind: "pull-requests"; readonly count: number };

export interface KitToolbarTab {
  readonly title: string;
  readonly shortcutNumber: number;
  readonly selected: boolean;
}

export interface KitToolbarModel {
  readonly arrangementLabel: string;
  /** Appended to the arrangement chip, e.g. "Zoom" while a pane is zoomed. */
  readonly arrangementSuffix?: string;
  readonly tabs: readonly KitToolbarTab[];
  readonly tabCount: number;
}

export interface KitSidebarWorktreeRow {
  readonly worktreeName: string;
  readonly branchName: string;
  readonly badges: readonly KitBadge[];
  readonly settledPresence: KitSettledPresence;
  readonly scenePart?: string;
}

export interface KitSidebarRepoGroup {
  readonly repoName: string;
  readonly settledPresence: KitSettledPresence;
  readonly worktrees: readonly KitSidebarWorktreeRow[];
  readonly scenePart?: string;
}

export interface KitSidebarModel {
  readonly filterPlaceholder: string;
  /** The settled filter text; an empty string settles on the placeholder. */
  readonly filterQuery: string;
  readonly groupingLabel: string;
  readonly sectionTitle: string;
  readonly repos: readonly KitSidebarRepoGroup[];
}

export type KitTerminalTone =
  | "plain"
  | "muted"
  | "strong"
  | "path"
  | "branch"
  | "command"
  | "remote"
  | "added"
  | "removed"
  | "hash"
  | "reference";

export interface KitTerminalSegment {
  readonly text: string;
  readonly tone: KitTerminalTone;
}

interface KitTerminalLineBase {
  readonly scenePart?: string;
  /** Lines the phone focused crop leaves out so the pane stays readable. */
  readonly phoneRole?: KitPhoneRole;
}

export type KitTerminalLine =
  | (KitTerminalLineBase & {
      readonly kind: "shell-prompt";
      readonly worktreeName: string;
      readonly branchName: string;
      /** Typed after the prompt; omitted when the prompt waits with a cursor. */
      readonly command?: string;
    })
  | (KitTerminalLineBase & { readonly kind: "user-message"; readonly text: string })
  | (KitTerminalLineBase & { readonly kind: "agent-message"; readonly text: string })
  | (KitTerminalLineBase & { readonly kind: "agent-activity"; readonly text: string })
  | (KitTerminalLineBase & {
      readonly kind: "output";
      readonly segments: readonly KitTerminalSegment[];
    })
  | (KitTerminalLineBase & { readonly kind: "agent-input" })
  | (KitTerminalLineBase & { readonly kind: "blank" });

export interface KitPaneFooterModel {
  readonly badges: readonly KitBadge[];
  /** Renders the primary-tinted "Zoomed" chip that Pane Zoom shows. */
  readonly zoomed: boolean;
}

export interface KitCommandBarRow {
  readonly icon: KitIconName;
  readonly label: string;
  readonly meta?: string;
  readonly subtitle?: string;
  readonly selected: boolean;
  readonly settledPresence: KitSettledPresence;
  readonly scenePart?: string;
}

export interface KitCommandBarSection {
  readonly title: string;
  readonly settledPresence: KitSettledPresence;
  readonly rows: readonly KitCommandBarRow[];
  readonly scenePart?: string;
}

export interface KitCommandBarModel {
  readonly placeholder: string;
  readonly query: string;
  readonly contextLabel: string;
  readonly shortcutHint?: string;
  readonly sections: readonly KitCommandBarSection[];
  readonly scopeHints: readonly string[];
  readonly closeHint: string;
  readonly actionHints: readonly { readonly icon: KitIconName; readonly label: string }[];
}

export type KitFileKind = "folder" | "typescript" | "markdown" | "document";

export interface KitFileTreeRow {
  readonly depth: number;
  readonly kind: KitFileKind;
  readonly name: string;
  readonly expanded?: boolean;
  readonly selected?: boolean;
  readonly scenePart?: string;
}

export type KitCodeTone =
  | "plain"
  | "keyword"
  | "type"
  | "function"
  | "string"
  | "comment"
  | "punctuation";

export interface KitCodeToken {
  readonly text: string;
  readonly tone: KitCodeTone;
}

export interface KitSourceLine {
  readonly lineNumber: number;
  readonly tokens: readonly KitCodeToken[];
}

export interface KitSourceViewModel {
  readonly filePath: string;
  readonly lines: readonly KitSourceLine[];
}

export type KitDiffLine =
  | {
      readonly kind: "context" | "added" | "removed";
      readonly lineNumber: number;
      readonly text: string;
      readonly scenePart?: string;
    }
  | { readonly kind: "collapsed"; readonly label: string };

export interface KitDiffViewModel {
  readonly fileName: string;
  readonly added: number;
  readonly removed: number;
  readonly lines: readonly KitDiffLine[];
}
