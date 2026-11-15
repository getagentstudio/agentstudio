# Pane context display: requirements

**Status:** approved by the owner on 2026-10-25.
**Author:** 🦁 Lead, with the owner.
**Specification:** [the pane context display specification](2026-10-24-pane-context-display-specification.md).

## Who and what for

**Person:** the owner, running many agents at once. Most are background agents (Codex under codex-router, Claude and ACP background sessions) viewed through panes. Some run directly in a pane.

**Job:** glance at the sidebar, a pane's own toolbar, or its ⌘R card, and know three things:

1. what the agent is doing;
2. what it last said;
3. whether it needs them.

Then act in one step: answer, open the item, or go to the pane.

**Today's pain** (owner screenshots 83–90, 2026-10-24, kept in `today/`):

- **The same pane tells different stories on different surfaces.** The card said "Needs you · question" while the sidebar row said "Idle · ready", and the question's text appeared nowhere.
- **Marks with no meaning:** a bell showing 0; a ▶ repeating the "Active" heading; "Now" beside "5 min ago".
- **Times float away from what they date.**
- **The Messages popover is unreadable:** blank filter pills, buttons cut to "Dis…" and "Go…", messages invisible.

## Needs

| ID | Need | Owner's words (rationale) | Priority |
| --- | --- | --- | --- |
| U1 | Every surface tells one consistent story about a pane. | "I want a cohesive story board… what is in side bar what the popup looks like what shows in drawer." | Must |
| U2 | A time is visibly attached to the thing it dates. | "Now or 2 min ago"; put "(xxx)" immediately after "so that it doesn't look like slop with random padding". | Must |
| U3 | Nothing on a surface is meaningless or redundant. | "What does this number do?" | Must |
| U4 | Whatever needs the person is visible at a glance, and they can act on it in one step, or see exactly where to act. | The pane said "Needs you" and hid the question. | Must |
| U5 | Every popover and card is readable at its normal size: full labels, all content reachable. | "How the fuck do I read or understand this?" | Must |
| U6 | Show what the app actually knows, and never invent it. Background agents are the normal case. | "We always use background agents… it's not new." | Must |
| U7 | Changes are shown as realistic renders before they're built, and checked against rendered frames before they're called done. | "Make html with actual render on what it should look like"; "you didn't even look at your UI". | Must |

## Boundaries

- **In scope:** what the sidebar pane row, the pane drawer toolbar, the ⌘R card, the Messages popover and the Agent Line popover show and offer, using information the app already holds.
- **Out of scope:**
  - which server-side conversation belongs to which pane (the parked identity design);
  - how status is detected;
  - message retention and settlement behavior;
  - restore;
  - CLI verbs and notification delivery.
- **Non-goals:** new agent capabilities, a new notification kind, toasts, and an expiry policy for the Agent Line.

## Open owner question

- **Q1, which age a row shows:** the agent message's age, or the pane's last activity (terminal or hook activity, which is not the person's interaction). The proposal shows the message age when there is a message, and the activity age otherwise. The owner confirms or corrects this from the renders.
