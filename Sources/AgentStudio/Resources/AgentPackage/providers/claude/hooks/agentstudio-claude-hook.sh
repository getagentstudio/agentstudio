#!/bin/sh
# Reports Claude Code status events or waits for a person's permission answer.
#
# Arguments: $1 the Claude Code hook event name, $2 the Claude Code release the
# hooks were installed against. The hook document arrives on stdin and is
# forwarded untouched. Remaining arguments select the installer's permission policy.
#
# Outside an Agent Studio pane there is no CLI and no pane credential, so the
# hook exits 0 in silence: Claude Code must never fail a turn because Agent
# Studio is not listening.
[ -x "${AGENTSTUDIO_CLI:-}" ] || exit 0
hook_event="$1"
provider_version="$2"
shift 2
exec "$AGENTSTUDIO_CLI" hook claude "$hook_event" --provider-version "$provider_version" "$@"
