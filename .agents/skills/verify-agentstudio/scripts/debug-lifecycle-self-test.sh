#!/bin/bash
# Deterministic control-path tests for debug-lifecycle.sh. Source through its
# --self-test entry. External process/launcher/quit results are replaced here;
# the actual admission, owner, launch, health and retirement functions run.

verify_lifecycle_self_test() (
  set -eu
  fixture="$(mktemp -d "${TMPDIR:-/tmp}/verify-lifecycle.XXXXXX")"
  fixture="$(builtin cd "$fixture" && builtin pwd -P)"
  VERIFY_PROJECT_ROOT="$fixture"
  VERIFY_STATE_FILE="$fixture/state.env"
  fixture_run="$fixture/tmp/verify-agentstudio/run"
  fixture_build="$fixture/build"
  fixture_watch="$fixture/watch"
  fixture_data="$HOME/.agentstudio-db/t3st"
  fixture_executable="$fixture_data/apps/AgentStudio Debug t3st.app/Contents/MacOS/AgentStudio"
  fixture_start='Thu Oct 22 11:00:00 2026'
  fixture_commit=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  mkdir -p "$fixture_build/debug" "$fixture_watch" "$fixture/tmp/verify-agentstudio"
  : > "$fixture_build/debug/AgentStudio"
  chmod 700 "$fixture_build/debug/AgentStudio"

  cleanup_fixture() {
    # Exact paths created by this synchronous test only; no process was started.
    if [ -d "$fixture_run" ]; then
      rm -f "$fixture_run/owner.env" "$fixture_run/quit-requested" "$fixture_run/quit-confirmed" \
        "$fixture_run/panes-baseline.json" "$fixture_run/mock.stdout"
      rmdir "$fixture_run"
    fi
    rm -f "$fixture/state.env" "$fixture/output" "$fixture/events" "$fixture_build/debug/AgentStudio"
    rmdir "$fixture_build/debug" "$fixture_build" "$fixture_watch" \
      "$fixture/tmp/verify-agentstudio" "$fixture/tmp" "$fixture"
  }
  trap cleanup_fixture EXIT

  # Only the two debug-root filesystem resolutions are virtual. HOME is never
  # changed, and neither real debug nor provider home is read or written.
  virtual_directory=""
  cd() {
    case "$1" in
      "$fixture_data"|"$fixture_data/z") virtual_directory="$1" ;;
      *) builtin cd "$@"; virtual_directory="" ;;
    esac
  }
  pwd() {
    if [ -n "$virtual_directory" ]; then printf '%s\n' "$virtual_directory"; else builtin pwd "$@"; fi
  }
  ps() {
    if [ "$2" = "$$" ]; then
      if [ "$mock_inspection" = denied ]; then echo 'mock inspection denied' >&2; return 77; fi
      printf '%s\n' "$$"; return 0
    fi
    case "$*" in
      *comm=*) printf '%s\n' "$fixture_executable" ;;
      *lstart=*) printf '%s\n' "$mock_start" ;;
      *pid=*)
        case "$mock_target" in
          alive) printf '4242\n' ;;
          absent) return 1 ;;
          denied) echo 'mock target inspection denied' >&2; return 1 ;;
        esac ;;
      *) echo 'unexpected mock ps request' >&2; return 90 ;;
    esac
  }
  pgrep() {
    printf 'inventory\n' >> "$fixture/events"
    case "$mock_inventory" in
      absent) return 1 ;;
      denied) echo 'mock pgrep denied' >&2; return 1 ;;
      empty-success) return 0 ;;
      existing) echo 4242 ;;
      *) return 90 ;;
    esac
  }
  write_handoff() {
    cat > "$VERIFY_STATE_FILE" <<EOF
AGENTSTUDIO_OBSERVABILITY_STATUS=running
AGENTSTUDIO_OBSERVABILITY_RUNTIME_FLAVOR=$mock_flavor
AGENTSTUDIO_OBSERVABILITY_DEBUG_CODE=t3st
AGENTSTUDIO_OBSERVABILITY_PID=4242
AGENTSTUDIO_OBSERVABILITY_PROCESS_START_IDENTITY=1792674000:123
AGENTSTUDIO_OBSERVABILITY_MARKER=$mock_marker
AGENTSTUDIO_OBSERVABILITY_BUNDLE_IDENTIFIER=com.agentstudio.app.debug
EOF
    printf 'AGENTSTUDIO_OBSERVABILITY_APP=%q\n' "$fixture_data/apps/AgentStudio Debug t3st.app" >> "$VERIFY_STATE_FILE"
    printf 'AGENTSTUDIO_OBSERVABILITY_EXECUTABLE=%q\n' "$fixture_executable" >> "$VERIFY_STATE_FILE"
    printf 'AGENTSTUDIO_OBSERVABILITY_DATA_DIR=%q\nAGENTSTUDIO_OBSERVABILITY_ZMX_DIR=%q\n' "$fixture_data" "$fixture_data/z" >> "$VERIFY_STATE_FILE"
    printf 'AGENTSTUDIO_OBSERVABILITY_BUILD_PATH=%q\nAGENTSTUDIO_OBSERVABILITY_ACTIVATION_MODE=background\n' "$fixture_build" >> "$VERIFY_STATE_FILE"
  }
  write_owner() {
    mkdir -p "$fixture_run"
    cat > "$fixture_run/owner.env" <<EOF
VERIFY_PID=4242
VERIFY_KERNEL_START=1792674000:123
VERIFY_MARKER=mock-original
VERIFY_CODE=t3st
VERIFY_SOURCE_COMMIT=$fixture_commit
EOF
    printf 'VERIFY_EXECUTABLE=%q\nVERIFY_DATA_ROOT=%q\nVERIFY_ZMX_DIR=%q\nVERIFY_BUILD_PATH=%q\nVERIFY_PROCESS_START=%q\n' \
      "$fixture_executable" "$fixture_data" "$fixture_data/z" "$fixture_build" "$fixture_start" >> "$fixture_run/owner.env"
  }
  verify_logged() {
    local label="$1"
    shift
    printf '%s\n' "$label" >> "$fixture/events"
    VERIFY_LAST_LOG="$fixture_run/mock"
    case "$label" in
      launch)
        [ "$#" -eq 8 ] && [ "$1" = mise ] && [ "$2" = run ] &&
          [ "$3" = run-debug-observability ] && [ "$4" = -- ] &&
          [ "$5" = --detach ] && [ "$6" = --skip-build ] &&
          [ "$7" = --build-path ] && [ "$8" = "$fixture_build" ] || return 90
        [ "$mock_launch" = success ] || return 71
        write_handoff ;;
      identity|quit)
        [ "$#" -eq 3 ] && [ "$1" = /bin/bash ] &&
          [ "$2" = "$VERIFY_PROJECT_ROOT/scripts/run-debug-observability.sh" ] || return 90
        if [ "$label" = identity ]; then
          [ "$3" = --validate-candidate ] && [ "$mock_metadata_code" = t3st ] || return 91
        else
          [ "$3" = --retire-candidate ] || return 90
          # The launcher consumes the already-validated exact PID/start receipt.
          [ "$STATE_PID" = 4242 ] && [ "$VERIFY_PID" = 4242 ] || return 92
          [ "$mock_quit" != retires ] || mock_target=absent
        fi ;;
      pane-list|window-list)
        [ "$#" -eq 2 ] && [ "$1" = verify_debug_cli ] || return 90
        case "$label:$2" in pane-list:pane.list|window-list:window.list) ;; *) return 90 ;; esac
        printf '{}\n' > "$VERIFY_LAST_LOG.stdout" ;;
      *) echo 'unexpected mocked external action' >&2; return 90 ;;
    esac
  }
  reset_case() {
    local variable_name
    for variable_name in $(compgen -v VERIFY_) $(compgen -v STATE_); do
      unset "$variable_name"
    done
    # Only fixed fixture routing is reintroduced; no prior case's owner or
    # handoff values survive. HOME remains unchanged.
    VERIFY_PROJECT_ROOT="$fixture"
    VERIFY_STATE_FILE="$fixture/state.env"
    virtual_directory=""
    mock_inspection=available; mock_inventory=absent; mock_target=alive
    mock_start="$fixture_start"; mock_marker=mock-original; mock_flavor=debug
    mock_launch=success; mock_quit=retires; mock_metadata_code=t3st
    : > "$fixture/events"
    if [ -d "$fixture_run" ]; then
      rm -f "$fixture_run/owner.env" "$fixture_run/quit-requested" "$fixture_run/quit-confirmed" \
        "$fixture_run/panes-baseline.json" "$fixture_run/mock.stdout"
      rmdir "$fixture_run"
    fi
    write_handoff
  }
  has_event() { case "$(< "$fixture/events")" in *"$1"*) return 0 ;; *) return 1 ;; esac; }
  check_case() {
    local name="$1"; shift
    reset_case
    # A fatal shell error in one case must be counted, not abort the enclosing
    # test before its final failure status. Each case also owns its globals.
    if ( "$@" ) > "$fixture/output" 2>&1; then
      printf 'PASS %s\n' "$name"; passed=$((passed + 1))
    else
      printf 'FAIL %s\n' "$name"; cat "$fixture/output"; failed=$((failed + 1))
    fi
  }
  denied_inspection() {
    mock_inspection=denied
    if verify_preflight t3st "$fixture_build"; then return 1; fi
    ! has_event inventory
  }
  denied_inventory() { mock_inventory=denied; ! verify_preflight t3st "$fixture_build"; }
  empty_inventory() { mock_inventory=empty-success; ! verify_preflight t3st "$fixture_build"; }
  valid_absence() { verify_preflight t3st "$fixture_build"; }
  existing_target() { mock_inventory=existing; ! verify_preflight t3st "$fixture_build"; }
  valid_owner() { write_owner; verify_owned_live "$fixture_run"; }
  changed_handoff() { write_owner; mock_marker=mock-replacement; write_handoff; ! verify_owned_live "$fixture_run"; }
  changed_owner() { write_owner; printf 'VERIFY_PID=9999\n' >> "$fixture_run/owner.env"; ! verify_owned_live "$fixture_run"; }
  wrong_metadata_code() { write_owner; mock_metadata_code=othr; ! verify_owned_live "$fixture_run"; }
  wrong_root() { write_owner; printf 'AGENTSTUDIO_OBSERVABILITY_DATA_DIR=%q\n' "$HOME/.agentstudio-db/othr" >> "$VERIFY_STATE_FILE"; ! verify_owned_live "$fixture_run"; }
  changed_start() { write_owner; mock_start='replacement start'; ! verify_owned_live "$fixture_run"; }
  unowned_quit() {
    # Give the target its routing values explicitly, but no ownership receipt.
    # The forbidden dispatch must remain observable if its guard is removed.
    VERIFY_CODE=t3st; VERIFY_PID=4242; VERIFY_MARKER=mock-original
    VERIFY_RUN_DIR="$fixture_run"
    mkdir -p "$fixture_run"
    if verify_quit "$fixture_run"; then return 1; fi
    ! has_event quit
  }
  denied_retirement() {
    write_owner; mock_quit=holds; mock_target=denied
    if verify_quit "$fixture_run"; then return 1; fi
    [ ! -e "$fixture_run/quit-confirmed" ]
  }
  alive_retirement() {
    write_owner; mock_quit=holds
    if verify_quit "$fixture_run"; then return 1; fi
    [ ! -e "$fixture_run/quit-confirmed" ]
  }
  legitimate_lifecycle() {
    verify_launch "$fixture_run" "$fixture_build" "$fixture_commit" t3st "$fixture_watch" || return
    has_event launch && has_event pane-list && has_event window-list || return
    verify_quit "$fixture_run" || return
    has_event quit && [ -s "$fixture_run/quit-confirmed" ]
  }
  failed_launch() {
    mock_launch=fails
    if verify_launch "$fixture_run" "$fixture_build" "$fixture_commit" t3st "$fixture_watch"; then return 1; fi
    [ ! -e "$fixture_run/owner.env" ] && ! has_event pane-list
  }
  wrong_flavor() { write_owner; mock_flavor=beta; write_handoff; ! verify_owned_live "$fixture_run"; }
  retired_owner() { write_owner; : > "$fixture_run/quit-confirmed"; ! verify_owned_live "$fixture_run"; }
  no_quit_request() { write_owner; mock_target=absent; ! verify_confirm_quit "$fixture_run"; }

  passed=0; failed=0
  check_case 'inspection denial cannot become absence or reach inventory' denied_inspection
  check_case 'pgrep error with exit 1 is not absence' denied_inventory
  check_case 'empty successful inventory is incomplete' empty_inventory
  check_case 'successful inspection plus empty exit-1 inventory admits launch' valid_absence
  check_case 'existing owned-code process blocks a second launch' existing_target
  check_case 'matching owned handoff and process admit reads' valid_owner
  check_case 'changed handoff marker blocks action' changed_handoff
  check_case 'changed owner PID blocks action' changed_owner
  check_case 'changed process start blocks action' changed_start
  check_case 'same bundle ID with another plist code blocks action' wrong_metadata_code
  check_case 'same bundle ID with another data root blocks action' wrong_root
  check_case 'unowned quit never reaches the quit command' unowned_quit
  check_case 'inspection failure cannot certify retirement' denied_retirement
  check_case 'still-live PID cannot certify retirement' alive_retirement
  check_case 'owned launch health quit and observed absence pass' legitimate_lifecycle
  check_case 'failed launch cannot adopt a stale successful handoff' failed_launch
  check_case 'non-debug handoff is refused' wrong_flavor
  check_case 'retired owner cannot act again' retired_owner
  check_case 'absence without an owned quit request is insufficient' no_quit_request
  printf '%s passed, %s failed; controlled command results only, no app/process/IPC call\n' "$passed" "$failed"
  [ "$failed" -eq 0 ]
)
