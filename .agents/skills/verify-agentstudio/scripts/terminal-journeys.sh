#!/bin/bash
# J11 terminal rendering, J12 foreground keyboard input, J13 warm reattach.
# Collects one step at a time on a J1-owned debug app; exit 0 is collection,
# never a journey verdict. Source: references/terminal-journeys.md.
set -euo pipefail
TERMINAL_JOURNEYS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

terminal_help() {
  cat <<'HELP'
terminal-journeys.sh --help | --self-test
terminal-journeys.sh fixtures RUN_DIR
terminal-journeys.sh session RUN_DIR NEW_PANE_UUID
terminal-journeys.sh daemon RUN_DIR LABEL
terminal-journeys.sh focus RUN_DIR NATIVE_WINDOW_ID
terminal-journeys.sh type RUN_DIR NATIVE_WINDOW_ID TEXT
terminal-journeys.sh press RUN_DIR NATIVE_WINDOW_ID CHORD
terminal-journeys.sh warm-link PREVIOUS_RUN_DIR RELAUNCH_RUN_DIR

Run from the repository root on a debug app launched by debug-lifecycle.sh.
fixtures   writes harmless printer scripts and a less file under RUN_DIR/fixtures.
session    read-only stored zmx_session_id of a pane created in this run.
daemon     read-only ps rows of this debug root's zmx for that session
           (works after the owned app retired; never lists, kills or signals zmx).
focus      peekaboo window focus on the owned PID/window, then frontmost readback.
type/press foreground keyboard input; refuses unless the owned PID is frontmost
           immediately before, and rechecks after. No retry; observe before resending.
warm-link  joins a retired run to its same-identity relaunch: same code, build,
           commit, pane and stored session; requires the surviving daemon row.
Captures use pane-chrome.sh capture; widths use window-frame.sh resize.
HELP
}

terminal_fail() { printf '%s\n' "$*" >&2; return 2; }

terminal_ps_rows() { LC_ALL=C /bin/ps -axww -o pid=,lstart=,command=; }
terminal_front_pid() {
  local front_asn
  front_asn="$(/usr/bin/lsappinfo front)" || return
  /usr/bin/lsappinfo info -only pid "$front_asn" | sed -n 's/^"pid"=\([0-9][0-9]*\)$/\1/p'
}
terminal_sqlite() { sqlite3 -readonly "$@"; }
terminal_peekaboo() { peekaboo "$@"; }

terminal_write_fixtures() {
  local fixture_dir="$VERIFY_RUN_DIR/fixtures" line_index
  [ ! -e "$fixture_dir" ] || { terminal_fail 'Fixtures already exist; keep the earlier run'; return; }
  mkdir "$fixture_dir"
  cat > "$fixture_dir/plain.sh" <<'FIXTURE'
# J11 plain text: ASCII, punctuation and box drawing. Prints only.
printf 'J11_PLAIN %s The quick brown fox jumps over the lazy dog 0123456789\n' "${1:-tag}"
printf 'J11_PLAIN punctuation ~!@#$%%^&*()_+-={}[]|:;<>,.?/\n'
printf 'J11_PLAIN box \342\224\214\342\224\200\342\224\200\342\224\220 \342\224\202ok\342\224\202 \342\224\224\342\224\200\342\224\200\342\224\230\n'
FIXTURE
  cat > "$fixture_dir/palette256.sh" <<'FIXTURE'
# J11 256-color: indexes 16-231 as 6 rows of 36 two-cell swatches, then 232-255.
printf 'J11_PALETTE256 %s\n' "${1:-tag}"
index=16
while [ "$index" -le 231 ]; do
  printf '\033[48;5;%sm  ' "$index"
  if [ $(((index - 15) % 36)) -eq 0 ]; then printf '\033[0m\n'; fi
  index=$((index + 1))
done
index=232
while [ "$index" -le 255 ]; do printf '\033[48;5;%sm  ' "$index"; index=$((index + 1)); done
printf '\033[0m\nJ11_PALETTE256 end\n'
FIXTURE
  cat > "$fixture_dir/truecolor.sh" <<'FIXTURE'
# J11 truecolor: 64-step red, green and blue 24-bit gradients, two rows each.
printf 'J11_TRUECOLOR %s\n' "${1:-tag}"
for channel in red green blue; do
  for row in 1 2; do
    step=0
    while [ "$step" -lt 64 ]; do
      level=$((step * 4 + 3))
      case "$channel" in
        red) printf '\033[48;2;%s;0;0m ' "$level" ;;
        green) printf '\033[48;2;0;%s;0m ' "$level" ;;
        blue) printf '\033[48;2;0;0;%sm ' "$level" ;;
      esac
      step=$((step + 1))
    done
    printf '\033[0m\n'
  done
done
printf 'J11_TRUECOLOR end\n'
FIXTURE
  {
    printf 'J11_TUI header: less -R -S; every line is longer than any tested width and ends with END\n'
    line_index=1
    while [ "$line_index" -le 200 ]; do
      printf 'L%03d \033[31mred\033[0m \033[32mgreen\033[0m \033[34mblue\033[0m \033[38;5;208morange256\033[0m \033[38;2;17;119;187mtruecolor\033[0m ' "$line_index"
      printf '%0.s-' $(seq 1 260)
      printf ' END%03d\n' "$line_index"
      line_index=$((line_index + 1))
    done
  } > "$fixture_dir/tui.txt"
  cat > "$fixture_dir/interrupt.sh" <<'FIXTURE'
# J12 Ctrl-C target: waits until SIGINT, then writes INTERRUPTED to $1 only.
marker="$1"
trap 'printf "INTERRUPTED\n" > "$marker"; printf "J12_INTERRUPTED\n"; exit 130' INT
printf 'J12_WAITING for Ctrl-C\n'
while :; do sleep 1; done
FIXTURE
  (cd "$fixture_dir" && shasum -a 256 plain.sh palette256.sh truecolor.sh tui.txt interrupt.sh) > "$fixture_dir/SHA256SUMS"
  printf 'Fixtures in %s. Print with: sh %s/<name>.sh <tag>; TUI: less -R -S %s/tui.txt\n' \
    "$fixture_dir" "$fixture_dir" "$fixture_dir"
}

terminal_select_session() {
  local pane_id="$1" stored_session
  [ ! -e "$VERIFY_RUN_DIR/terminal-session.env" ] ||
    { terminal_fail 'Session selection already recorded for this run'; return; }
  verify_logged terminal-session terminal_sqlite "$VERIFY_DATA_ROOT/core.sqlite" \
    "SELECT zmx_session_id FROM pane_content_terminal WHERE upper(pane_id)=upper('$pane_id');" > /dev/null || return
  stored_session="$(< "$VERIFY_LAST_LOG.stdout")"
  verify_validate_uuid "$stored_session" ||
    { terminal_fail 'Need exactly one stored UUID session for this pane'; return; }
  printf 'TERMINAL_PANE_ID=%q\nTERMINAL_SESSION_ID=%q\n' "$pane_id" "$stored_session" \
    > "$VERIFY_RUN_DIR/terminal-session.env"
  printf 'pane=%s session=%s\n' "$pane_id" "$stored_session"
}

terminal_load_session() {
  [ -f "$1/terminal-session.env" ] && [ ! -L "$1/terminal-session.env" ] ||
    { terminal_fail "No recorded session in $1"; return; }
  # shellcheck source=/dev/null
  source "$1/terminal-session.env"
  verify_validate_uuid "$TERMINAL_PANE_ID" && verify_validate_uuid "$TERMINAL_SESSION_ID" ||
    terminal_fail 'Recorded session is malformed'
}

# Rows naming this debug root's zmx and the exact session. The daemon outlives
# the app; attach clients belong to the app's terminal surfaces.
terminal_daemon_rows() {
  local zmx_path="$1" session_id="$2"
  terminal_ps_rows | awk -v zmx="$zmx_path" -v session="$session_id" \
    'index($0, zmx) && index($0, session) { print }'
}

terminal_daemon() {
  local label="$1" output
  [[ "$label" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]] || { terminal_fail 'Invalid label'; return; }
  output="$VERIFY_RUN_DIR/daemon-$label.txt"
  [ ! -e "$output" ] || { terminal_fail 'Daemon label already recorded'; return; }
  terminal_load_session "$VERIFY_RUN_DIR" || return
  verify_inspection_available || return
  terminal_daemon_rows "$VERIFY_DATA_ROOT/bin/zmx" "$TERMINAL_SESSION_ID" > "$output" || return
  printf 'session=%s rows=%s file=%s\n' "$TERMINAL_SESSION_ID" "$(wc -l < "$output" | tr -d ' ')" "$output"
  cat "$output"
}

terminal_require_front() {
  local front_pid
  front_pid="$(terminal_front_pid)" || { terminal_fail 'Frontmost app unreadable; no input'; return; }
  [ "$front_pid" = "$VERIFY_PID" ] ||
    { terminal_fail "Frontmost PID ${front_pid:-unknown} is not owned PID $VERIFY_PID; no input"; return; }
}

terminal_validate_window() {
  case "$1" in ''|*[!0-9]*|0) terminal_fail 'Need the native numeric window id from pane-chrome.sh inventory'; return ;; esac
}

terminal_focus() {
  terminal_validate_window "$1" || return
  verify_logged focus terminal_peekaboo window focus --pid "$VERIFY_PID" --window-id "$1" --verify --no-remote --json > /dev/null || return
  verify_owned_live "$VERIFY_RUN_DIR" || return
  terminal_require_front && printf 'Owned PID %s is frontmost\n' "$VERIFY_PID"
}

terminal_input() {
  local kind="$1" window="$2" payload="$3"
  terminal_validate_window "$window" || return
  [ -n "$payload" ] || { terminal_fail 'Empty input'; return; }
  terminal_require_front || return
  case "$kind" in
    type) verify_logged input-type terminal_peekaboo type "$payload" --pid "$VERIFY_PID" --window-id "$window" --foreground --accept-dispatched --no-remote --json > /dev/null || return ;;
    press) verify_logged input-press terminal_peekaboo press "$payload" --pid "$VERIFY_PID" --window-id "$window" --foreground --no-remote --json > /dev/null || return ;;
  esac
  verify_owned_live "$VERIFY_RUN_DIR" || return
  terminal_require_front || { terminal_fail 'Focus moved during input; inspect where it landed before anything else'; return; }
  printf 'Dispatched %s to owned PID %s window %s; capture before claiming receipt\n' "$kind" "$VERIFY_PID" "$window"
}

terminal_warm_link() {
  local previous_run relaunch_run previous_code previous_build previous_commit previous_pane previous_session
  local survivor_rows relaunch_rows survivor_pid survivor_start
  verify_run_directory "$1" || return; previous_run="$VERIFY_RUN_DIR"
  verify_run_directory "$2" || return; relaunch_run="$VERIFY_RUN_DIR"
  [ "$previous_run" != "$relaunch_run" ] || { terminal_fail 'Need two different runs'; return; }
  [ -f "$previous_run/quit-confirmed" ] || { terminal_fail 'Previous app retirement was not confirmed'; return; }
  [ -s "$previous_run/daemon-after-quit.txt" ] || { terminal_fail 'No surviving daemon row recorded after the previous quit'; return; }
  # shellcheck source=/dev/null
  source "$previous_run/owner.env"
  previous_code="$VERIFY_CODE"; previous_build="$VERIFY_BUILD_PATH"; previous_commit="$VERIFY_SOURCE_COMMIT"
  terminal_load_session "$previous_run" || return
  previous_pane="$TERMINAL_PANE_ID"; previous_session="$TERMINAL_SESSION_ID"
  verify_owned_live "$relaunch_run" || return
  [ "$VERIFY_CODE" = "$previous_code" ] && [ "$VERIFY_BUILD_PATH" = "$previous_build" ] &&
    [ "$VERIFY_SOURCE_COMMIT" = "$previous_commit" ] ||
    { terminal_fail 'Relaunch is not the same debug identity, build and commit'; return; }
  shopt -s nocasematch
  case "$(< "$relaunch_run/panes-baseline.json")" in
    *"$previous_pane"*) shopt -u nocasematch ;;
    *) shopt -u nocasematch; terminal_fail 'Relaunched pane list lacks the previous pane'; return ;;
  esac
  terminal_select_session "$previous_pane" > /dev/null || return
  terminal_load_session "$relaunch_run" || return
  [ "$TERMINAL_SESSION_ID" = "$previous_session" ] ||
    { terminal_fail "Stored session changed: $previous_session -> $TERMINAL_SESSION_ID"; return; }
  terminal_daemon after-relaunch > /dev/null || return
  survivor_rows="$(< "$previous_run/daemon-after-quit.txt")"
  relaunch_rows="$(< "$relaunch_run/daemon-after-relaunch.txt")"
  [ "$(printf '%s\n' "$survivor_rows" | wc -l | tr -d ' ')" = 1 ] ||
    { terminal_fail 'Expected exactly one surviving daemon row after quit'; return; }
  read -r survivor_pid _ <<< "$survivor_rows"
  survivor_start="$(printf '%s\n' "$survivor_rows" | awk '{print $2, $3, $4, $5, $6}')"
  printf '%s\n' "$relaunch_rows" | awk -v pid="$survivor_pid" -v start="$survivor_start" \
    '$1 == pid && ($2" "$3" "$4" "$5" "$6) == start { found = 1 } END { exit !found }' ||
    { terminal_fail "Surviving daemon $survivor_pid is absent after relaunch: not a warm reattach"; return; }
  printf 'warm-link pane=%s session=%s daemon=%s (%s) kept across %s -> %s\n' \
    "$previous_pane" "$previous_session" "$survivor_pid" "$survivor_start" "$previous_run" "$relaunch_run" |
    tee "$relaunch_run/warm-link.txt"
}

terminal_main() {
  local action="${1:---help}"
  case "$action" in
    --help) terminal_help; return ;;
  esac
  # shellcheck source=.agents/skills/verify-agentstudio/scripts/debug-lifecycle.sh
  source "$TERMINAL_JOURNEYS_DIR/debug-lifecycle.sh"
  if [ "$action" = --self-test ]; then
    # shellcheck source=.agents/skills/verify-agentstudio/scripts/terminal-journeys-self-test.sh
    source "$TERMINAL_JOURNEYS_DIR/terminal-journeys-self-test.sh"
    terminal_journeys_self_test
    return
  fi
  verify_require_root || return
  shift
  case "$action" in
    fixtures) [ "$#" -eq 1 ] && verify_owned_live "$1" && terminal_write_fixtures ;;
    session) [ "$#" -eq 2 ] && verify_owned_live "$1" && verify_require_new_pane "$2" && terminal_select_session "$2" ;;
    daemon) [ "$#" -eq 2 ] && verify_load_context "$1" && terminal_daemon "$2" ;;
    focus) [ "$#" -eq 2 ] && verify_owned_live "$1" && terminal_focus "$2" ;;
    type) [ "$#" -eq 3 ] && verify_owned_live "$1" && terminal_input type "$2" "$3" ;;
    press) [ "$#" -eq 3 ] && verify_owned_live "$1" && terminal_input press "$2" "$3" ;;
    warm-link) [ "$#" -eq 2 ] && terminal_warm_link "$1" "$2" ;;
    *) terminal_help >&2; return 2 ;;
  esac
}
if [ "${BASH_SOURCE[0]}" = "$0" ]; then terminal_main "$@"; fi
