#!/bin/sh
# Projects one Claude Code hook event onto Agent Studio's session.event method.
#
# Arguments: $1 the Claude Code hook event name, $2 the Claude Code release the
# hooks were installed against. The hook document arrives on stdin and is
# forwarded untouched.
#
# Outside an Agent Studio pane there is no CLI and no pane credential, so the
# hook exits 0 in silence: Claude Code must never fail a turn because Agent
# Studio is not listening.
[ -x "${AGENTSTUDIO_CLI:-}" ] || exit 0
exec "$AGENTSTUDIO_CLI" hook claude "$1" --provider-version "$2"
