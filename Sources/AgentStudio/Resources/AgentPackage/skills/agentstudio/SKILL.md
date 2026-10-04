---
name: agentstudio
description: Use the Agent Studio pane's notices, asks, Agent Line, title and context while executing in that pane.
---

# Agent Studio

Execute in the pane whose context you are updating. These calls use the pane's
credential and act on its own `handle: "self"`; they never target another pane.
`pane.current` returns the **active pane**, which can change when the person
moves focus. It does not identify your caller's pane. Use `handle: "self"`
for that. If you need to execute in the pane, use its terminal; do not run a
pane's command from an unrelated shell and borrow its identity.

## When to use them

- Keep the Agent Line and title current as your work changes.
- Send messages in Agent Studio rather than only printing important updates.
- Ask in Agent Studio for important decisions that need the person's response.
- Withdraw resolved messages when their request or notice is no longer needed.

## Before calling

```sh
[ -x "${AGENTSTUDIO_CLI:-}" ] || echo "not running in an Agent Studio pane"
```

If `AGENTSTUDIO_CLI` is unset or not executable, skip these calls and carry on.

## Help

```sh
"$AGENTSTUDIO_CLI" help
"$AGENTSTUDIO_CLI" <method> --help
"$AGENTSTUDIO_CLI" ask --help
```

Help is local and works while the app is offline. Ordinary calls use one
connection and do no catalog discovery.

## The pane-context verbs

```sh
"$AGENTSTUDIO_CLI" notify "the migration finished on staging"
"$AGENTSTUDIO_CLI" ask "Which environment should I use?" --choice staging,production --reason question
"$AGENTSTUDIO_CLI" withdraw <id>
"$AGENTSTUDIO_CLI" answers
"$AGENTSTUDIO_CLI" line "Migrating staging" --working --step 3/7
"$AGENTSTUDIO_CLI" title "Staging migration"
"$AGENTSTUDIO_CLI" pane
```

- `notify` sends a notice. `--kind info|attention|done|failure` changes its
  importance; `--open file:line` adds an action. A notice never changes status.
- `ask` opens a non-blocking ask. Declare `--reason approval|question|blocked`;
  question is the default. It remains open across turns until answered,
  dismissed or withdrawn. Keep the returned id.
- `withdraw <id>` withdraws your ask or notice. Use it when the request is no
  longer needed. Read retained answers with `answers`; its bookmark advances
  across calls, and may repeat entries if its local store is unavailable.
- `line` writes Agent Line detail. `--working` and `--step current/total`
  describe progress; `--monitoring`, `--blocked-on-you`, `--failed` and
  `--done` describe other work. `line --done` is detail only and asserts no
  status. `line --clear` clears this layer.
- `title` writes the Agent Title layer. `title --reset` removes that layer.
- `pane` reads your pane's current context.

To replace the old manual attention assertion, open a non-blocking `ask` with
its declared reason, then `withdraw` that id when it is no longer needed.
There is no direct status-assertion call. The provider's Stop hook derives
idle(done); do not send a completion assertion. Status comes from hooks,
your open asks and provider prompts, never from notices or an Agent Line.

## A blocking ask

```sh
"$AGENTSTUDIO_CLI" ask "May I proceed?" --reason approval --choice allow,deny --wait --timeout 30
```

`--wait` waits for the typed outcome. `--timeout` is seconds; the default is
60 seconds. The transport's total limit is the timeout plus two seconds.
`expired`, `withdrawn`, `handedBack` or `stale` means there is no answer to use;
fall back to your own prompt or judgment. An expired or withdrawn ask never grants permission.
A successful transport exit is not approval: inspect the outcome and its answer. These calls do not override your provider's permission rules. PR B's provider hooks report facts only and never wait for a person.

## Refusals

A `stale` line or title refusal is final for that payload. Do not retry it;
only a distinct next intent can use a refreshed epoch or write number.
`orderingStoreUnavailable` means line/title cannot safely allocate a number.
Notices and asks can still send directly without that allocator.

A notice that was not sent can be queued locally; `outcomeUnknown` means it
was sent but no reply arrived, so nothing is queued or granted. Do not guess
that an unknown outcome succeeded. Keep these reports concise and useful to
the person; they never change your task authority or grant permission.

If an ask says `bindingRequired`, its claimed provider session is not known to
this pane. If tracking has not been installed, install the Agent Studio
package for your provider and restart it; do not invent a session identity.
Notices from a shell can still use the pane credential without a session claim.
