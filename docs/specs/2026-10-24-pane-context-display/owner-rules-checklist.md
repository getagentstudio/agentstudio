# Owner rules checklist (verbatim). Every render pass is checked against every row.

| # | Owner's words (2026-10-24) | Rule | Applies to | Check in every scenario at 1400 / 520 / 390 |
| --- | --- | --- | --- | --- |
| R1 | "brackets in status line for agent not in the chips" | Square brackets only on the Agent Line's age | all surfaces | every "[" belongs to an Agent Line age; chip `◷ 1m`, ACTIVE, popover and toolbar-chip ages have none |
| R2 | "each on its own line" + "chips after agent line" | Sidebar row: title / status / Agent Line / chips, each on its own line; empty lines not drawn | sidebar | line order exactly that; chips never on the status line |
| R3 | "all the chips shown, or agent line" + "one or the other" | Toolbar: all chips while unread, otherwise the Agent Line; never both | toolbar | either chips only, or Agent Line only, or empty |
| R4 | "status is not necessary in drawer toolbar" | No status in the toolbar | toolbar | no "Working" / "Needs you" / "Idle" text |
| R5 | "multi line tool bar is not ok" | Toolbar is exactly one line | toolbar | one line at 390 too |
| R6 | "the divider after notes" | `\|` divider after the notes (pencil) button | toolbar | divider present before the item; none trailing when empty |
| R7 | "one chip per kind, or not shown if not there" | One chip per kind, hidden at 0 | sidebar, toolbar | no 0 chips; each kind at most once |
| R8 | "clamp" (not "up to a max width") | Agent Line text clamped to a max width; never fills the row | sidebar, toolbar, card | text truncates before the age |
| R9 | "approval should be its own form… agentstudio approval" | Approval form: [Approve] [Deny] | card, popover | buttons present |
| R10 | "Now or 2 min ago" | Age words: Now / N min ago | all | no "just now" |

