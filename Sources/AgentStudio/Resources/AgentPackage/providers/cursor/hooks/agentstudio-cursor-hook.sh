#!/bin/sh
# Cursor hooks observe status and never request a provider decision.
[ -x "${AGENTSTUDIO_CLI:-}" ] || exit 0
exec "$AGENTSTUDIO_CLI" hook cursor "$1"
