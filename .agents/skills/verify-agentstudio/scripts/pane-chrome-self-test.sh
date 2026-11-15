#!/bin/bash
# Real wrapper dispatch with private process/capture stubs; no desktop access.
pane_chrome_self_test() (
  set -euo pipefail
  umask 077
  native_fixture="$(mktemp -d "${TMPDIR:-/tmp}/pane-chrome.XXXXXX")"
  native_fixture="$(cd "$native_fixture" && pwd -P)"
  trap 'rm -rf -- "$native_fixture"' EXIT
  valid_identity 1 '/tmp/.agentstudio-db/fixture/apps/AgentStudio Debug fixture.app/Contents/MacOS/AgentStudio' 'fixture-start'
  if valid_identity 1 '/Applications/AgentStudio.app/Contents/MacOS/AgentStudio' x; then exit 1; fi
  if valid_identity 0 '/tmp/.agentstudio-db/x/apps/Debug.app/Contents/MacOS/AgentStudio' x; then exit 1; fi
  if valid_identity invalid '/tmp/.agentstudio-db/x/apps/Debug.app/Contents/MacOS/AgentStudio' x; then exit 1; fi
  guard() { [ "${NATIVE_TEST_GUARD:-ok}" = ok ]; }
  peekaboo() {
    printf '%s\n' "$*" >> "$native_fixture/calls"
    if [ "${NATIVE_TEST_DENY:-no}" = yes ]; then echo 'fixture capture denied' >&2; return 73; fi
    if [ "$1" = window ]; then printf '{"fixture":"owned-popover-inventory"}\n'; return; fi
    local screenshot_path=''
    while [ "$#" -gt 0 ]; do
      if [ "$1" = --path ]; then screenshot_path="$2"; break; fi
      shift
    done
    [ -n "$screenshot_path" ]
    printf 'fixture-png-not-real-pixels' > "$screenshot_path"
  }
  # Failed calls run in a child: the real command can exit without ending tests.
  pane_chrome_main inventory 42 fixture-exe fixture-start "$native_fixture/windows.json" >/dev/null
  [ "$(cat "$native_fixture/windows.json.rc")" = 0 ]
  [ "$(cat "$native_fixture/calls")" = 'window list --pid 42 --no-remote --json' ]
  pane_chrome_main capture 42 99 fixture-exe fixture-start "$native_fixture/popover.png" >/dev/null
  [ -s "$native_fixture/popover.png" ]
  [ "$(tail -1 "$native_fixture/calls")" = "see --pid 42 --window-id 99 --mode window --no-remote --no-elements --path $native_fixture/popover.png" ]
  calls_before="$(cat "$native_fixture/calls")"
  if (pane_chrome_main capture 42 99 fixture-exe fixture-start "$native_fixture/popover.png") >/dev/null 2>&1; then exit 1; fi
  [ "$calls_before" = "$(cat "$native_fixture/calls")" ]
  NATIVE_TEST_GUARD=changed
  if (pane_chrome_main inventory 42 fixture-exe fixture-start "$native_fixture/changed.json") >/dev/null 2>&1; then exit 1; fi
  [ "$calls_before" = "$(cat "$native_fixture/calls")" ]
  NATIVE_TEST_GUARD=ok; NATIVE_TEST_DENY=yes
  denied_status=0
  (pane_chrome_main inventory 42 fixture-exe fixture-start "$native_fixture/denied.json") >/dev/null 2>&1 || denied_status=$?
  [ "$denied_status" = 73 ] && [ "$(cat "$native_fixture/denied.json.rc")" = 73 ]
  [ "$(cat "$native_fixture/denied.json.stderr")" = 'fixture capture denied' ]
  printf '9 passed, 0 failed; identity plus stubbed PID inventory/capture checks, no desktop calls\n'
)
