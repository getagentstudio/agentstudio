#!/bin/bash
# J4/J5/J6/J7 guarded PNG collection. Never launches,
# activates, quits, sends IPC, reads escrow or changes permissions.
set -euo pipefail

usage() {
  cat <<'HELP'
pane-chrome.sh --help | --self-test
pane-chrome.sh guard PID EXPECTED_EXECUTABLE EXPECTED_LSTART
pane-chrome.sh capture PID NATIVE_WINDOW_ID EXPECTED_EXECUTABLE EXPECTED_LSTART NEW_ABSOLUTE_PNG

guard performs locale-stable ps reads.
capture requires a separately authorized, declared debug target and evidence
path; confirm its numeric native window ID first with peekaboo window list.
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

case "${1:---help}" in
  --help) usage ;;
  --self-test)
    valid_identity 1 '/tmp/.agentstudio-db/fixture/apps/AgentStudio Debug fixture.app/Contents/MacOS/AgentStudio' 'Wed Oct 21 11:36:25 2026'
    if valid_identity 1 '/Applications/AgentStudio.app/Contents/MacOS/AgentStudio' x; then exit 1; fi
    if valid_identity 0 '/tmp/.agentstudio-db/x/apps/Debug.app/Contents/MacOS/AgentStudio' x; then exit 1; fi
    if valid_identity invalid '/tmp/.agentstudio-db/x/apps/Debug.app/Contents/MacOS/AgentStudio' x; then exit 1; fi
    echo '4 pure identity-validation checks passed; no process or app call'
    ;;
  guard)
    [ "$#" = 4 ] || { usage >&2; exit 2; }
    guard "$2" "$3" "$4"
    echo 'Process guard matched; source/window/fixture still require the declared receipt'
    ;;
  capture)
    [ "$#" = 6 ] || { usage >&2; exit 2; }
    case "$3" in ''|*[!0-9]*|0) echo 'Need native numeric window ID' >&2; exit 2 ;; esac
    case "$6" in /*.png) ;; *) echo 'Need a new absolute PNG path' >&2; exit 2 ;; esac
    [ -d "$(dirname -- "$6")" ] && [ ! -e "$6" ] && [ ! -L "$6" ] || {
      echo 'Output parent missing or PNG already exists; HOLD' >&2; exit 2;
    }
    guard "$2" "$4" "$5"
    peekaboo see --pid "$2" --window-id "$3" --mode window --no-elements --path "$6"
    [ -s "$6" ] || { echo 'No PNG collected; UNKNOWN' >&2; exit 2; }
    echo 'PNG collected; inspect original/state/geometry before a verdict'
    ;;
  *) usage >&2; exit 2 ;;
esac
