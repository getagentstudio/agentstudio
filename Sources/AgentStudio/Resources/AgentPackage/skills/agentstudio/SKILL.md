---
name: agentstudio
description: Report your status to the Agent Studio pane you are running in. Use when you need the user's attention, when you finish the work they asked for, or when you have one short thing to tell them while they are looking elsewhere.
---

# Agent Studio

You are running inside an Agent Studio pane. Agent Studio shows the person one
row per pane: whether you are working, whether you are waiting on them, and
whatever you last told them. These calls are how that row gets filled in, so
they can leave you working and look away.

## Before you call anything

```sh
[ -x "${AGENTSTUDIO_CLI:-}" ] || echo "not running in an Agent Studio pane"
```

If `AGENTSTUDIO_CLI` is unset or not executable, you are not in a pane. Do not
call anything and do not mention it again.

## The four calls

```sh
"$AGENTSTUDIO_CLI" message "the migration finished on staging"
"$AGENTSTUDIO_CLI" needs-you "waiting on the production credential"
"$AGENTSTUDIO_CLI" needs-you --clear
"$AGENTSTUDIO_CLI" done
```

- `message <text>` — one short line the person will read in the sidebar. Use it
  when something happened that they would want to know without opening the
  pane. Not progress narration.
- `needs-you [why]` — you are blocked on them. Say what you need in a few words.
- `needs-you --clear` — you are unblocked and working again.
- `done` — the work you were asked to do is finished.

## Everything else

`"$AGENTSTUDIO_CLI" help` lists what you can call from this pane.
`"$AGENTSTUDIO_CLI" <method> --help` shows the arguments and an example.
Act on your own pane only. Anything marked "not yet allowed" will be refused.

## What to expect back

Each call prints one short line, such as `needs-you recorded` or `done
recorded`, and exits. That line is the whole reply; there is nothing to parse,
nothing to retry, and nothing to follow up on. Say nothing about the call in
your own output.

## When to use them

Call `needs-you` the moment you are actually waiting on the person, not before.
Call `done` once, when the task is finished — not at the end of every step. Use
`message` sparingly; a row that updates constantly tells the person nothing.
Report the user-visible truth, not every internal step.

## If a call is refused

If a call replies `bindingRequired`, the Agent Studio hooks are not installed
for this provider, so Agent Studio is not tracking this session. Tell the person
once, in one line, and carry on with the work — the hooks are theirs to install,
not yours. Under Claude Code the line to give them is:

> Agent Studio is not tracking this session. Run
> `"$AGENTSTUDIO_CLI" package install claude` and restart Claude Code.

Under the Cursor CLI the line is
`"$AGENTSTUDIO_CLI" package install cursor`, then restart `cursor-agent`.

Then carry on without calling the status verbs again this session. A free-text
`message` still works and is still worth sending.

## If you are a subagent

Do not call `done` and do not call `needs-you`. Those speak for the whole pane
and only the main agent owns that. `message` is fine if you have something the
person genuinely needs to see.

These calls are for the person's attention only. They never change what you do
next, and no answer comes back through them.
