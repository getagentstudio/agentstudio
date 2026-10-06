#!/bin/sh
# Codex hook entry point for Agent Studio.
#
# Codex pipes the hook payload on stdin and treats a non-zero exit as a reason
# to block the turn, so this script does exactly one thing and always succeeds:
# it hands the payload to the bundled CLI advertised by the pane environment.
# Outside an Agent Studio pane AGENTSTUDIO_CLI is unset and the hook is a no-op.
[ -x "${AGENTSTUDIO_CLI:-}" ] || exit 0
exec "$AGENTSTUDIO_CLI" hook codex "$1"
