# Pane UI outcomes

The pane-context oracle is the owner's approved specification r5 at
`docs/specs/2026-10-24-pane-context-display/2026-10-24-pane-context-display-specification.md`,
its verbatim `owner-rules-checklist.md` and storyboard/renders. Program Design r5's
later contracts govern structure. The specification governs observable outcomes.
Historical targets require their explicit oracle; current rendering cannot
replace it. `pane-context-scenarios.md` links setup to its source owners.
The tracked specification O31/O40–O44 at `f00068402` incorporates the current UI
round. [J9](messages-popover.md) owns its disclosure, filter, form, footer and
proof-boundary procedure; earlier boards/flat-row text cannot replace those
outcomes. Decisions ledgers are optional context, not required oracles.

## Shared facts and ages

Every applicable surface equals independent input facts, not just the others.
E3/E7 require verified evidence; E4/E5 remain available on unbound panes. Verified
ended status remains Idle · ended; SESSION keeps its verified-live metadata rule.
Main-pane E5/E7 scope includes owned drawers; drawer-alone scope is its own.
Actions retain source pane/message identity. First scoped prompt is the same
newest/stably ordered prompt on row/card/list; asks take priority on the card.

Ages: Now below 60s, N min ago below 1h, N hr ago below 24h, 1 day ago/N days ago.
Ages sit one space after what they date except Messages, where age has its own
secondary line under the body. Square brackets decorate **Agent Line
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
partial/clipped/wrapped chips or second row. The same measured fit rule applies
at every width (including 520 and 390), with a ≥1400 positive witness showing
all four chips plus complete Git. Do not shorten the Git fixture to create fit;
the fixed 520 expectation is withdrawn. Fixed owner rules are unchanged.

## Card and popovers

Card: title → status chip → Agent Line → selected request → unread link, then
existing conditional warning/note/metadata/git content. When the request block
shows a compact prompt summary the status chip omits that summary; an E5 ask
block does not erase the chip's available prompt summary. Oldest open ask in
scope wins, even beyond first-page budget; otherwise compact E7 plus terminal
instruction and Go to pane. +N more counts other needs-you items including E7
omissions, while N unread excludes E7 and includes info notices.

D23: the card Agent Line inherits O12—one line, existing 220pt sidebar text cap,
ellipsis before the complete bracketed age. The toolbar's 360pt cap does not
apply to the card. D25: the ask row head has body + plain age with Dismiss beside
it, then the form below; approval's optional reason precedes Approve/Deny. The
card's unread summary follows the entire request block, as in approved S15.
D42 keeps that card arrangement while adopting the action roles in J9. Messages
instead follows O42: separate age line, top-trailing icon-only Dismiss,
and form actions aligned to the body text edge.

Single choice picks locally then Submit, disabled until a pick; native radio or
picker follows J9's 4-option/32-character rule. Multiple/free text use Submit. Approval
has Approve/Deny and optional reason. Elicitation is inline in Messages and
Answer… on the card opens that exact request in Messages. Every open ask is
answerable/dismissible from sidebar/pane/card subject to that elicitation rule.
Settled asks have no answer/dismiss/action controls. Exact service labels/receipt
states come from the E5 table, never optimistic UI state. Failed card refresh
removes stale actionable form. E3 changes only through its existing owner.

Messages groups Failed/Needs you/Done/Info/Resolved; newest-first mixed E5/E7,
empty hidden. Headings are sentence case with a plain count and no chip.
Body initially shows six visual lines with exact remaining-line disclosure;
explanation/age/source are separate. Expansion exposes the full body; J9 owns
first paint, count landing and collapse checks.
J9 owns the newline-only fixed-width body rule, first-line glyph/dismiss geometry,
utility/alternative/commit roles and Messages form appearance checks.
Read rows dim; read attention/failure move to Resolved/Read. Withdrawn notices
have no actions; dismissed notices disappear. The header filter menu hides only
loaded groups; paging stays shared and bulk dismissal keeps the whole scope.
No old filter-button strip, Count informational or Mark read control. Footer
paint is Dismiss all / To pane; full AX/help stays Dismiss all notices / Go to
pane. J10 shares that navigation projection. Long content scrolls to final actions.
The six-line visual disclosure does not mark read. New notices stay
unread/countable until dismissed; opening/scrolling/expanding
does not mark read. Retained read-state presentation is unchanged, but read-notice
journey setup is product-test-only/a named live gap, including S19's read failure.
Under D43a, Loading starts at clamped 480pt. First ready content chooses Messages
width once: 560pt with any multiline body, otherwise 480pt; that one change is
allowed, then later updates/loading/unavailability retain the chosen width. Screen
clamp/floor are unit-test coverage as distinguished from native width in J9.
Messages height remains capped at 480pt. Agent Line popover remains 380pt wide,
showing full line, age/writer/refs/Go to pane and no E7. Native capture must visibly
include the actual popover.

## Metadata/copy and warning policy, unchanged

One field per caption row: REPO, BRANCH, WORKTREE only if different from REPO,
CWD only if different from root, SESSION only verified live, PANE always, plus
plain ACTIVE when E6 known. Preserve fallback/no-repo and git chips last. The
caption column is sized for WORKTREE. Values align and copy icons follow inline
at the same small gap, always visible. No width-based two-column card.

Normal repo/branch fit at 420pt and wider. SESSION/PANE can middle-truncate with
readable ends/full tooltip/inline copy. Oversized paths/branch keep adopted middle
truncation; the title retains its natural one/two-line boundary and the Agent
Line retains D23's single-line cap/whole-age boundary. Copy SESSION
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
