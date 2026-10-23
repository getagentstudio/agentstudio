#!/bin/sh
# Agent Studio hook for cursor, integration version 1. Installed by `agentstudio package install`.
exec >/dev/null 2>&1
[ -x "${AGENTSTUDIO_CLI:-}" ] || exit 0
"$AGENTSTUDIO_CLI" hook cursor "$1"
exit 0
