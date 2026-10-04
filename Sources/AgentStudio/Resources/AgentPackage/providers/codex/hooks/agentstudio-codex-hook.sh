#!/bin/sh
# Codex hook entry point for Agent Studio.
#
# Codex pipes the hook payload on stdin. The bundled CLI reports status events
# or waits for a person's permission answer under the installer-selected policy.
# Only an explicit Allow or Deny answer produces a provider decision document.
# Outside an Agent Studio pane AGENTSTUDIO_CLI is unset and the hook is a no-op.
[ -x "${AGENTSTUDIO_CLI:-}" ] || exit 0
hook_event="$1"
shift
exec "$AGENTSTUDIO_CLI" hook codex "$hook_event" "$@"
