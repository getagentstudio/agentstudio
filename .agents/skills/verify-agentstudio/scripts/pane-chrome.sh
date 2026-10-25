#!/bin/bash
# J4–J10 guarded native inventory/PNG collection. Never launches,
# activates, quits, sends IPC, reads escrow or changes permissions.
set -euo pipefail
PANE_CHROME_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

usage() {
  cat <<'HELP'
pane-chrome.sh --help | --self-test
pane-chrome.sh guard PID EXPECTED_EXECUTABLE EXPECTED_LSTART
pane-chrome.sh inventory PID EXPECTED_EXECUTABLE EXPECTED_LSTART NEW_ABSOLUTE_JSON
pane-chrome.sh capture PID NATIVE_WINDOW_ID EXPECTED_EXECUTABLE EXPECTED_LSTART NEW_ABSOLUTE_PNG

guard performs locale-stable ps reads.
capture requires a separately authorized, declared debug target and evidence
path; confirm its numeric native window ID first with PID-targeted inventory.
A popover can be a different window; inspect its original pixels before credit.
inventory retains the raw local window list, stderr and exit code.
It repeats the PID/start guard and collects one non-focusing window PNG.
Exit 0 is collection, never a UI PASS. No action retries or cleanup are implicit.
HELP
}

valid_identity() {
  case "$1" in ''|*[!0-9]*|0) return 1 ;; esac
  case "$2" in
    /*/.agentstudio-db/*/apps/*Debug*.app/Contents/MacOS/AgentStudio) ;;
    *) return 1 ;;
  esac
  [ -n "$3" ]
}

guard() {
  valid_identity "$1" "$2" "$3" || { echo 'Invalid declared debug identity' >&2; return 2; }
  actual_executable="$(LC_ALL=C /bin/ps -p "$1" -o comm=)"
  actual_start="$(LC_ALL=C /bin/ps -p "$1" -o lstart= | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  [ "$actual_executable" = "$2" ] && [ "$actual_start" = "$3" ] || {
    echo 'Target changed or process inventory incomplete; HOLD' >&2; return 2;
  }
}

pane_chrome_main() {
case "${1:---help}" in
  --help) usage ;;
  --self-test)
    # shellcheck source=.agents/skills/verify-agentstudio/scripts/pane-chrome-self-test.sh
    source "$PANE_CHROME_DIR/pane-chrome-self-test.sh"
    pane_chrome_self_test
    ;;
  guard)
    [ "$#" = 4 ] || { usage >&2; exit 2; }
    guard "$2" "$3" "$4" || return
    echo 'Process guard matched; source/window/fixture still require the declared receipt'
    ;;
  capture)
    [ "$#" = 6 ] || { usage >&2; exit 2; }
    case "$3" in ''|*[!0-9]*|0) echo 'Need native numeric window ID' >&2; exit 2 ;; esac
    case "$6" in /*.png) ;; *) echo 'Need a new absolute PNG path' >&2; exit 2 ;; esac
    [ -d "$(dirname -- "$6")" ] && [ ! -e "$6" ] && [ ! -L "$6" ] || {
      echo 'Output parent missing or PNG already exists; HOLD' >&2; exit 2;
    }
    guard "$2" "$4" "$5" || return
    peekaboo see --pid "$2" --window-id "$3" --mode window --no-remote --no-elements --path "$6" || return
    guard "$2" "$4" "$5" || return
    [ -s "$6" ] || { echo 'No PNG collected; UNKNOWN' >&2; exit 2; }
    echo 'PNG collected; inspect original/state/geometry before a verdict'
    ;;
  inventory)
    [ "$#" = 5 ] || { usage >&2; exit 2; }
    case "$5" in /*.json) ;; *) echo 'Need a new absolute JSON path' >&2; exit 2 ;; esac
    [ -d "$(dirname -- "$5")" ] && [ ! -e "$5" ] && [ ! -e "$5.stderr" ] && [ ! -e "$5.rc" ] || {
      echo 'Evidence parent missing or inventory exists; HOLD' >&2; exit 2;
    }
    guard "$2" "$3" "$4" || return
    inventory_status=0
    peekaboo window list --pid "$2" --no-remote --json > "$5" 2> "$5.stderr" || inventory_status=$?
    printf '%s\n' "$inventory_status" > "$5.rc"
    [ "$inventory_status" -eq 0 ] || exit "$inventory_status"
    guard "$2" "$3" "$4" || return
    echo 'Inventory retained; select actual popover/window ID, never infer from order'
    ;;
  *) usage >&2; exit 2 ;;
esac
}
if [ "${BASH_SOURCE[0]}" = "$0" ]; then pane_chrome_main "$@"; fi
