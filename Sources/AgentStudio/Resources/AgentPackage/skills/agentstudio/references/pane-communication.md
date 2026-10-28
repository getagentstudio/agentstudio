# Pane messages and decisions

This reference owns Agent Line/title, notices and asks. Start with the attached caller identity, intended message or decision, and any retained message ID. Return the observed message/answer state, IDs still needed, and any decision that is actually usable. Complete only after distinguishing a notice, a pending ask and an answered decision.

## Agent Line and title

```sh
"$AS_CLI" line "Migrating staging; checking deployment logs"
"$AS_CLI" line --clear
"$AS_CLI" title "Staging migration"
"$AS_CLI" title --reset
```

This skill targets the matching message-only Agent Studio release: `line MESSAGE` and `line --clear`. The app shows the message after separate hook status, with a fixed message icon and relative age such as "1 min ago". There is no timed expiry or age dimming. Write the message itself; the app supplies its age.

Update it when the work changes and clear obsolete text. Limit line text to 200 UTF-8 bytes, not characters; 120 ordinary Japanese characters can exceed the limit. Titles allow 256 UTF-8 bytes; `--reset` removes the Agent Title layer.

In that matching release, removed work/status/step/detail/expiry options produce this exact error:

```text
Agent Line accepts a message only. Use: agentstudio line "<message>" or agentstudio line --clear. Status comes from harness hooks; use agentstudio ask "<question>" when you need the user.
```

Make the next intended call through the helper: `"$AS_CLI" line "Current message"` or `"$AS_CLI" line --clear`. Legacy help advertising `--done`, `--working`, `--step`, `--detail` or `--expires` is not the target contract; report a version mismatch instead of reviving those forms. Shorten text after a byte-limit refusal.

Claude Code, Codex and Cursor lifecycle hooks own status. Keep their supplied `CLAUDE_CODE_SESSION_ID`, `CODEX_THREAD_ID` or `CURSOR_CONVERSATION_ID`; do not synthesize hook events or bind a session manually. `notify --kind done` is a notice, not a status transition. Use an ask for a decision or "Needs you".

## Notices and asks

```sh
"$AS_CLI" notify "The staging migration finished" --kind done
"$AS_CLI" notify "Review the failed step" --kind attention --open "$LOG_FILE:42"
"$AS_CLI" ask "Which environment should I use?" --choice staging,production --reason question
"$AS_CLI" answers
"$AS_CLI" withdraw "$MESSAGE_ID"
```

Notice importance is `info|attention|done|failure`. `--open file:line` adds a file action. A notice changes neither hook status nor task permission.

An ask is nonblocking unless `--wait` is supplied. Choose reason `approval|question|blocked` (default `question`); comma-separated choices must be nonempty and unique. Without choices, the form is free text. Retain the returned ID and read the answer before dependent work. It stays open across turns until settled or withdrawn.

`answers` reads retained change pages and advances a local bookmark. Entries can repeat when that store is unavailable; inspect IDs/state rather than treating repeats as new decisions. An interrupted read can print partial entries with `more: true` and then fail: keep the partial result and the unresolved read.

`withdraw ID` handles an ask or notice owned by the pane writer. A settled ask returns its committed terminal state; a read notice cannot be withdrawn. Withdrawal is not proof the user never saw a message.

Message bodies allow 4 KiB UTF-8; choices at most 12 with labels at most 200 bytes. Raw forms additionally limit why to 1 KiB, form to 16 properties/8 KiB encoded, and actions to four/1 KiB each. Pane limits are 32 open asks and 200 unread notices. Use concise requests; withdraw obsolete owned messages rather than flooding the pane.

## Waiting for a decision

```sh
"$AS_CLI" approval "May I deploy to staging?" --timeout 30
"$AS_CLI" ask "May I deploy to staging?" --reason approval --choice allow,deny --wait --timeout 30
```

`approval REQUEST [--timeout SECONDS]` always waits. The person sees Approve and Deny plus a Reason (optional) field. An answered approval prints `{"decision":"approve"|"deny","reason"?:string}`; Deny also exits 0. Only an explicit `approve` supplies approval. Other outcomes and failures print and exit exactly as `ask --wait` does; they supply no decision.

Default wait is 60 seconds; the friendly blocking ask's transport budget is timeout plus two seconds. This exception does not apply to arbitrary raw IPC waits. Connection EOF withdraws a blocking ask; stopping can make it stale; the first committed settlement wins.

Inspect the typed result and answer value. `answered` can contain a denial. `expired`, `withdrawn`, `handedBack` and `stale` provide no usable answer. Exit 0 is not approval. Keep dependent work waiting and obtain a fresh explicit decision through chat or a new ask if still needed. A pane response cannot expand provider permissions or the scope the owner authorized.

Good: retain the ID of an expired deployment ask, explain that no approval arrived, and continue independent preparation. Bad: deploy because the command returned zero or because the ask UI was presented.

## Authentication boundaries

Line/title can automatically use the existing pane identity when the token is absent/rejected. A claimed session unknown to the app (`bindingRequired`) also falls back to the pane writer for line/title. Leave that fallback to the CLI; supplied pane/workspace identity and ordering are still required.

Notices, asks, withdrawal, answers and pane context need a recognized token. An ask additionally needs a known provider session. A credentialed shell without a provider-session claim can send a notice; do not add a tracking prerequisite or strip an existing claim. A protected-call refusal can leave `credentialNotRecognized` while line/title and hooks continue working. That warning does not establish message delivery.

Keep background and identity guards from the main path for every next call. If required reporting is unavailable, retain the exact outcome and use chat; recover through the main path's recovery branch rather than installing hooks or editing settings under this skill.
