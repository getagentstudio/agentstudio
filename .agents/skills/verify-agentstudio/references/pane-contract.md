# Pane UI outcomes

The pane-context oracle is the owner's approved specification r5 at
`docs/specs/2026-10-24-pane-context-display/2026-10-24-pane-context-display-specification.md`,
its verbatim `owner-rules-checklist.md` and storyboard/renders. Program Design r4's
later contracts govern structure. The specification governs observable outcomes.
Historical targets require their explicit oracle; current rendering cannot
replace it. `pane-context-scenarios.md` links setup to its source owners.

## Shared facts and ages

Every applicable surface equals independent input facts, not just the others.
E3/E7 require verified evidence; E4/E5 remain available on unbound panes. Verified
ended status remains Idle · ended; SESSION keeps its verified-live metadata rule.
Main-pane E5/E7 scope includes owned drawers; drawer-alone scope is its own.
Actions retain source pane/message identity. First scoped prompt is the same
newest/stably ordered prompt on row/card/list; asks take priority on the card.

Ages: Now below 60s, N min ago below 1h, N hr ago below 24h, 1 day ago/N days ago.
Ages sit one space after what they date. Square brackets decorate **Agent Line
ages only**, including its popover; other message/prompt/ACTIVE ages are plain.
Sidebar activity uses compact Now/Nm/Nh/Nd. Text yields before complete age; no
empty/zero/unknown marks or duplicate play glyph. E4 has no expiry.

## Sidebar and drawer

Sidebar is title / status / Agent Line / chips on separate populated lines,
with no blank slots/dividers. Title strips leading terminal spinners. Chip order
is failure (red), needs-you (amber), done (green), info (neutral), one per nonzero
kind. Status/colours also have icons or words. Activity chip appears only with
no E4 and known E6. S11 is measured at 260pt sidebar width.

Toolbar is one line: after notes/pencil, an item divider then **all nonzero chips
while unread**, otherwise Agent Line, otherwise no item/divider. For this delivery,
the Lead's provisional Amendment 2 (pending owner review; detailed in J4) lets the
passive Git readout hide whole first when the item does not fit, then hides the
whole chip item if it still cannot fit. All action buttons retain presence,
size, order and hit area. The item divider draws only with a drawn item. Never
status or warning. The line's text clamp (360pt in Program Design) remains
separate from icon/age extent, with whole-item hide when needed. No clipped age,
partial/clipped/wrapped chips or second row. Record measured policy order at
390; at 520/wide require all four chips and Git. Fixed owner rules are unchanged.

## Card and popovers

Card: title → status chip → Agent Line → selected request → unread link, then
existing conditional warning/note/metadata/git content. When the request block
shows a compact prompt summary the status chip omits that summary; an E5 ask
block does not erase the chip's available prompt summary. Oldest open ask in
scope wins, even beyond first-page budget; otherwise compact E7 plus terminal
instruction and Go to pane. +N more counts other needs-you items including E7
omissions, while N unread excludes E7 and includes info notices.

Single choice submits once on press. Multiple/free text use Submit. Approval
has Approve/Deny and optional reason. Elicitation is inline in Messages and
Answer… on the card opens that exact request in Messages. Every open ask is
answerable/dismissible from sidebar/pane/card subject to that elicitation rule.
Settled asks have no answer/dismiss/action controls. Exact service labels/receipt
states come from the E5 table, never optimistic UI state. Failed card refresh
removes stale actionable form. E3 changes only through its existing owner.

Messages groups Needs you/Done/Info/Resolved; newest-first mixed E5/E7, empty
hidden. Full body/explanation wraps without cap, followed by plain age/source.
Read rows dim; read attention/failure move to Resolved/Read. Withdrawn notices
have no actions; dismissed notices disappear. Remove filters/Count informational/
Mark read controls. Footer: Dismiss all notices only with unread/read notices,
and Go to pane, both readable. Long content scrolls to final row/actions.
Loading/unavailable retain normal width. Agent Line popover shows full line,
age/writer/refs/Go to pane, no E7. Program Design sizes are 380pt wide/max 480pt
Messages height. Native capture must visibly include the actual popover.

## Metadata/copy and warning policy, unchanged

One field per caption row: REPO, BRANCH, WORKTREE only if different from REPO,
CWD only if different from root, SESSION only verified live, PANE always, plus
plain ACTIVE when E6 known. Preserve fallback/no-repo and git chips last. The
caption column is sized for WORKTREE. Values align and copy icons follow inline
at the same small gap, always visible. No width-based two-column card.

Normal repo/branch fit at 420pt and wider. SESSION/PANE can middle-truncate with
readable ends/full tooltip/inline copy. Oversized paths/branch keep adopted middle
truncation; title/message retain natural one/two-line boundaries. Copy SESSION
is only raw session reference; PANE is full UUID. Actual pasteboard readback is
separate from PNG/AX. Retain J5's five actual-card-width matrix separately from
V2's 1400/520/390 window matrix.

Quiet hook/message/title fallback does not create or clear credential refusal.
A genuine protected failure records the actual refusal; verified binding may
suppress warning. Current #57 warning is plain/card-only, no raw reason codes,
question-mark chip or sidebar/toolbar warning. J6 owns its real refusal journey.

## Displaying-agent status, unchanged

J7 retains four actual setups: foreground, remote Codex app-server, Claude daemon/
attach, Cursor. Standalone remote fills slot (b) only with its declared residual
label “(b) remote app-server — Router wrapper not exercised”. Preserve real host/
viewer containment and selected-session evidence. Synthetic prompt stimuli in
pane-context recipes are not a real J7 provider turn or four-setup status proof.
A real turn expects Working, then Idle · done/ready through actual reduction;
provider prompts expect Needs you. Missing safe setup is UNKNOWN; safely observed
missing displaying-pane status is FAIL under the declared oracle.
