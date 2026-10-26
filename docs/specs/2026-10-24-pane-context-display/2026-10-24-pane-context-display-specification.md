# Pane context display: specification

**Status:** r5, approved by the owner on 2026-10-25. Program Design is not written yet.

**Requirements:** [the pane context display requirements](2026-10-24-pane-context-display-requirements.md) (U1–U7, Q1).
**Renders:** the storyboard HTML in this folder realizes these rules. These rules govern; the renders illustrate them.

## Entities

| ID | Term | Identity | Holds | Display states |
| --- | --- | --- | --- | --- |
| E1 | **Pane** | pane id | the surface viewed; a main pane may have drawer panes | — |
| E2 | **Pane agent** | provider + conversation id | the conversation the app currently has **verified session evidence** for in this pane. 0 or 1 per pane. | bound / none |
| E3 | **Agent status** | belongs to E2 | the existing status vocabulary: Working; Working · monitoring; Needs you · approval \| question \| blocked; Failed; Failed · category; Idle · done \| ready \| interrupted \| ended; unknown | as listed |
| E4 | **Agent Line** | 0 or 1 per pane | the latest one-line message, written by the agent session **or** by a pane writer, and when it was set. **No expiry:** it stays until cleared or replaced. | present / none |
| E5 | **Message** | **(source pane id, message id)** | a **notice** (kind info, attention, done or failure; body; optional explanation; optional file or PR target) or an **ask** (reason approval, question or blocked; body; an answer form) | see "Display states of E5" |
| E6 | **Pane activity** | 0 or 1 per pane | the time of the pane's last known activity: terminal output or hook activity. **Not** the person's interaction. May be unknown. | known / unknown |
| E7 | **Provider prompts** | belongs to E2; **0 to many**, in the session's existing returned order (newest first, stable tie-break), plus a supplied omitted count | each prompt is the provider's own pending request: reason, observation time, **optional** summary. **Not** an E5 ask: no message identity, no in-app answer form. | present / none |

**Ask answer forms** (existing, plus the owner's 2026-10-24 addition):

- **single choice:** a list of options, pick one;
- **multiple choice:** a list of options, pick any, then submit;
- **free text:** an optional placeholder;
- **structured elicitation:** a schema of fields;
- **approval (new; owner decision 2026-10-24):** sent with `agentstudio approval "<request>"`. It is answered with **[Approve]** or **[Deny]** plus an optional reason, and returns `{decision: approve | deny, reason?}` to the agent. This matches the standard approval pattern in Claude Code, Codex and MCP elicitation. Its CLI and IPC contract is defined in Program Design.

### Display states of E5

| Item | State | Shown where | Label | Actions |
| --- | --- | --- | --- | --- |
| Notice | unread, failure | **Failed** | none | Open file / Open pull request when targeted; Dismiss |
| Notice | unread, attention | **Needs you** | none | Open file / Open pull request when targeted; Dismiss |
| Notice | unread, done / info | **Done** / **Info** | none | as above |
| Notice | read, done / info | **Done** / **Info**, dimmed | none | as above |
| Notice | read, attention or failure | **Resolved**, dimmed | "Read" | as above |
| Notice | withdrawn | **Resolved** | "Withdrawn by the agent" | none |
| Notice | dismissed | not shown | — | — |
| Ask | open | **Needs you** | none | its answer form (below); Dismiss |
| Ask | answered, receipt pending | **Resolved** | "Answer sent, waiting for the agent" | none |
| Ask | answered, receipt confirmed | **Resolved** | "Answered: <answer summary>" | none |
| Ask | answered, receipt unconfirmed | **Resolved** | "Answer sent; the agent didn't confirm it" | none |
| Ask | dismissed, blocking ask | **Resolved** | "Handed back to the agent" | none |
| Ask | dismissed, non-blocking ask | **Resolved** | "Dismissed" | none |
| Ask | expired, withdrawn or stale | **Resolved** | "Expired" / "Withdrawn by the agent" / "No longer current" | none |

- **Resolved** holds the settled asks the app still retains, read attention and failure notices, and withdrawn notices. Retention is unchanged by this design.
- Answering never implies that status changed. The status shows whatever E3 says.

### Derived terms (one scope everywhere: see O8)

- **Needs-you items:** open asks; unread attention and failure notices; any E7 provider prompt.
- **The compact prompt:** where a surface shows one E7 prompt (O11, O31), it is the **first** prompt in E7's returned order, the same one on every surface.
- **Unread count:** open asks plus unread notices of every kind, informational included. E7 isn't counted because it has no message identity; it shows through status instead (O11).
- **Urgency:** failure > needs you (ask, attention, provider prompt) > done > info.

## Shared rules (every surface)

- **O1 (one story; U1):** wherever two surfaces present the same fact for a pane (E3 status text, E4 text and age, unread count, needs-you presence), they present the same value. Each value equals what the input facts dictate; agreement is not enough on its own (see V3).
- **O2 (time format; U2):** ages read `Now` under 1 minute, `N min ago` under 1 hour, `N hr ago` under 1 day, then `1 day ago` / `N days ago`. They sit one space after the text they date, never pinned to an edge.
  - **Square brackets are for the Agent Line's age only** (owner 2026-10-24: "brackets in status line for agent, not in the chips"): `💬 Running tests (3/7) [2 min ago]`, wherever the Agent Line appears (sidebar, toolbar, card).
  - Everywhere else, the age is plain secondary text with **no brackets**: popover rows, the card's ACTIVE row (`1 min ago`), and the toolbar's notification item.
  - The sidebar **activity chip** keeps its compact form, `◷ 1m` / `◷ Now` / `◷ 9m`, with no brackets (O13).
- **O3 (truncation; U2, U5):** in single-line places (sidebar, toolbar), the text truncates with an ellipsis before its age does, and an age is never truncated or dropped. In popovers, text wraps fully (O42).
- **O4 (no empty marks; U3):**
  - a count chip appears only when its count is greater than 0;
  - unknown status shows nothing;
  - no indicator restates information already on the same surface. The ▶ "active" mark is removed.
- **O5 (status only from evidence; U6):** E3 and E7 show only when E2 exists. **E4 and E5 show by their own availability, with or without E2**: a pane writer's line and pane notices still show on an unbound pane.
- **O6 (titles; U3):** leading spinner glyphs that terminal titles carry (for example ✳ and the braille spinners ⠃ ⠋) are not shown.
- **O7 (urgency colour; U3, U4):** failure red, needs you amber, done green, info neutral, on the same tokens on every surface. Colour is never the only carrier: an icon or word says the same thing.
- **O8 (scope; U1):**
  - for a **main pane**, every surface counts and lists the items of the pane **and its drawer panes** (the existing "including drawers" scope);
  - for a **drawer pane** opened on its own, only its own items;
  - in the Messages popover, items from a drawer pane carry their source pane label;
  - every action targets exactly one (source pane id, message id).

## Sidebar pane row

- **O10 (U1, U3):** line 1 is the pane title (O6).
- **O11 (U1, U4, U6):**
  - line 2 is the E3 status, icon plus text, shown only when known (O4, O5);
  - "Needs you · …" uses the needs-you colour;
  - when E7 is present and the compact prompt (the first) has a summary, the status reads "Needs you · <reason>: <summary>", truncating the summary.
- **O12 (U1, U2; owner 2026-10-24: "each on its own line… chips after agent line"):** the sidebar row is a stack, each part on **its own line**, in this order:
  1. the title (O6);
  2. the **status note** (O11);
  3. the **Agent Line**: message icon, text clamped to a fixed maximum width (proposed 220 pt; it never stretches to fill the row), then its age in square brackets (O2). The text truncates with an ellipsis and the age stays (O3);
  4. the **chips** (O13).

  A line whose content is absent isn't drawn, and leaves no gap. The sidebar row has **no `|` dividers**.
- **O13 (U3; Q1):** the chip line holds at most:
  - **one chip per kind present** (owner decision 2026-10-24): `✕ N` failure (red), `⚑ N` needs you (open asks + unread attention, amber), `✓ N` done (green), `ⓘ N` info (neutral). They appear in that urgency order, and a kind with a count of 0 is not shown (O4). Clicking a chip opens the Messages popover scrolled to **that chip's section** (O41; owner decision 2026-10-26, option A);
  - an **activity chip** with E6's age, only when the row has no E4 and E6 is known. That gives one age per row, per Q1.
- **O14 (U4):** clicking the bell opens the Messages popover; clicking the Agent Line opens the Agent Line popover.

## Pane drawer toolbar

- **O20 (U1, U2, U4; owner 2026-10-24: "all the chips shown, or the agent line"):** the drawer toolbar shows, after its buttons and a **`|` divider after the notes (pencil) button** (owner 2026-10-24: "the divider after notes"), on **exactly one line**, never wrapping, **never agent status**:
  - while any unread notification or open ask exists: **all the item chips**, one per kind present, the same chips and order as the sidebar (O13): `✕ N` `⚑ N` `✓ N` `i N`, hidden at 0. Clicking a chip opens the Messages popover scrolled to that chip's section (O41);
  - once they're all cleared: **the Agent Line**, as the message icon, its text, then its age in square brackets (O2);
  - with neither: nothing.

  The Agent Line text is clamped (proposed 360 pt) and truncates before its age. It hides rather than adding a line.
- **O21:** (merged into O20.)

## ⌘R card

- **O30 (U1):** the title (O6), then a status chip with the O11 status text, then the Agent Line with its age (O12), when present. The one exception: when the O31 block shows the compact prompt's summary, the chip omits the summary ("Needs you · <reason>"), so the card doesn't repeat it (O4).
- **O31 (U4):** the card shows the **most urgent open needs-you request**, in this order:
  1. the oldest open ask: its full body, then its answer form, then **Dismiss**:
     - **single choice:** one button per option, and clicking one submits it;
     - **multiple choice:** a toggle per option plus **Submit**;
     - **free text:** a text field plus **Submit**;
     - **structured elicitation:** an **Answer…** button that opens it in the Messages popover;
     - **approval:** **[Approve]** **[Deny]** and an optional reason field;
  2. otherwise, the compact E7 prompt (the first in returned order): its summary if it has one (otherwise nothing invented), then the note "Answer in the agent's terminal" with **Go to pane**. The status chip above already says "Needs you · <reason>", so the block doesn't repeat it (O4). Further prompts and the omitted count go into "+N more".

  "+N more" opens the Messages popover when other needs-you items exist.
- **O32 (U4):** when the unread count is greater than 0, one line reads "N unread", with a link that opens the Messages popover.
- **O33 (U1, U6):** the existing conditional identity metadata is preserved as it is today: repo, branch, worktree, CWD, SESSION only with verified identity, PANE, and fallback. A row **ACTIVE  N min ago** (plain age, no brackets or parentheses, O2) is added when E6 is known. Recency no longer appears as a chip on the card.

## Messages popover

- **O40 (U5):**
  - fixed readable width (proposed 380 pt);
  - height follows its content up to a maximum (proposed 480 pt), then the list scrolls;
  - every label is shown in full at that width;
  - loading shows "Loading…" and an unavailable service shows its note, and neither collapses the width.
- **O41 (U3, U4, U5):**
  - sections mirror the kind chips (owner decision 2026-10-26, option A: "why are they clumped up"), in order: **Failed** (unread failure notices), **Needs you** (open asks, unread attention notices, and **every** returned E7 prompt, with "+N more not shown" when the supplied omitted count is above 0), **Done**, **Info**, **Resolved** (per the E5 table);
  - each section header except Resolved carries its kind chip (O13) showing **the same number as that kind's sidebar/toolbar chip**: the unread count for the popover's scope (O8), including rows not yet loaded by paging. Read rows listed in Done or Info are shown dimmed and aren't counted; E7 prompts aren't counted. A count of 0 shows no chip, and the section still shows its read rows (Lead ruling 2026-10-26 on D26);
  - opening from a chip scrolls that chip's section into view; opening from the bell or the card opens at the top;
  - newest first within each group; empty groups are hidden;
  - the five filter buttons, "Count informational" and "Mark read" are removed. Read state still shows by dimming, per the E5 table.
- **O42 (U4, U5):**
  - a row shows its coloured kind icon, then the **full body, wrapped with no line cap**, then the explanation if any, then the age (O2), then the source pane label when it comes from a drawer pane (O8);
  - actions follow the E5 display-state table; an open ask shows its answer form as in O31, with an elicitation shown inline here;
  - an E7 row shows its reason, its summary if any, and "Answer in the agent's terminal". The footer's **Go to pane** is the action; the row doesn't repeat it (O4).
- **O43 (U5):** the footer holds **Dismiss all notices** (only when unread or read notices exist) and **Go to pane**, both in full.

## Agent Line popover

- **O50 (U2, U5):** at the O40 width: the full line text (wrapped), its age (O2), its writer (agent session or pane), its references if any, and **Go to pane**. E7 handling isn't here; it's covered by O11, O31 and O42.

## Proof obligations

- **V1 (renders before build; U7):** the storyboard HTML shows every scenario below on each surface it involves. The owner reviews it before implementation starts.
- **V2 (built frames; U7):** after implementation, debug-app frames for every scenario at three window widths are compared with the storyboard. The Lead inspects them and shows them to the owner before "done".
- **V3 (facts, not just agreement; O1):** for each scenario, a table of input facts determines the expected displayed value and presence for each surface. Tests assert each surface's projection equals the expected value, not merely each other. **Counterexamples that must fail:**
  - dropping info notices from every projection;
  - one stale status shown everywhere;
  - an answered ask still offering its form.
- **V4 (format; O2–O4):**
  - age wording at 59 s, 60 s, 59 min, 60 min, 23 hr, 24 hr and 48 hr;
  - chip suppression at count 0;
  - unknown status shows nothing.
- **V5 (actions; U4):** after each action, the displayed row reflects the **settlement and receipt the service actually returned**:
  - pending, then confirmed **only when a confirmed receipt arrives**;
  - unconfirmed if the service says so;
  - Dismiss shows "Handed back" for a blocking ask and "Dismissed" for a non-blocking ask;
  - no action changes the displayed status by itself.

## Scenarios (storyboard rows)

| | Scenario |
| --- | --- |
| S1 | Bound, Idle · ready, nothing else; activity known. |
| S2 | Working, no line. |
| S3 | Agent Line set: "Running tests (3/7)" (Now). |
| S4 | The same line, 2 minutes later. |
| S5 | + an info notice "Branch rebased onto main". |
| S6 | + a done notice "Tests passed (412)". |
| S7 | + an attention notice "Review the migration plan before I apply it". |
| S8 | + a failure notice "Build failed: 3 errors in SessionsIngestion.swift", with a file target. |
| S9 | A single-choice question, "Pick a color for the test?" (red / blue), with Needs you · question. |
| S10 | S9 answered (blue): the row shows "Answer sent, waiting for the agent", then confirmed. Status shows whatever E3 says (Working in the render). |
| S11 | Busy main pane at sidebar width 260 pt: 4 unread including 1 from a drawer pane, and a long line. |
| S12 | Unbound pane with no line and no messages: plain title, activity chip only. |
| S13 | Unbound pane with a **pane-written** line and an unread notice: no status, but the line and the bell show (O5). |
| S14 | A multiple-choice question (toggles + Submit). |
| S15 | An approval ("Approve running the migration?"): **[Approve] [Deny]** plus an optional reason field. |
| S16 | **Provider prompt without an in-app ask:** Needs you · approval with summary "Allow write to ~/.zshrc?", and the same without a summary. "Answer in the agent's terminal" + Go to pane. No bell, since nothing is counted. |
| S17 | A long failure notice with no target (6 lines of body), fully readable in the popover. |
| S18 | Two provider prompts (approval "Allow write to ~/.zshrc?" newest, then question "Use staging DB?") plus omitted count 1. The sidebar and card show the first; the popover lists both plus "+1 more not shown". |
| S19 | Resolved group mix: a dismissed non-blocking ask, an unconfirmed answer, a withdrawn notice, a read failure. |

## Traceability

| Need | Rules |
| --- | --- |
| U1 | O1, O5, O8, O10–O12, O20–O21, O30, O33 |
| U2 | O2, O3, O12, O20, O50 |
| U3 | O4, O6, O7, O10, O13, O41 |
| U4 | O7, O11, O14, O21, O31, O32, O41, O42, V5, S16, S18, S19 |
| U5 | O3, O40–O43, O50 |
| U6 | O5, O11, O33 |
| U7 | V1, V2 |
