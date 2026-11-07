#!/bin/bash
# Deterministic tests for terminal-journeys.sh, sourced through --self-test.
# ps, lsappinfo, sqlite3, peekaboo and the J1 ownership checks are replaced by
# private stubs; fixtures run only in a private mktemp directory. No app, IPC,
# zmx, desktop input or capture is touched.

terminal_journeys_self_test() (
  set -euo pipefail
  umask 077
  fixture="$(mktemp -d "${TMPDIR:-/tmp}/terminal-journeys.XXXXXX")"
  fixture="$(cd "$fixture" && pwd -P)"
  trap 'rm -rf -- "$fixture"' EXIT
  passed=0
  check() { passed=$((passed + 1)); }
  expect_failure() { if ( "$@" ) > /dev/null 2>&1; then printf 'unexpected success: %s\n' "$*" >&2; exit 1; fi; check; }

  VERIFY_PROJECT_ROOT="$fixture"
  first_run="$fixture/tmp/verify-agentstudio/first"
  second_run="$fixture/tmp/verify-agentstudio/second"
  mkdir -p "$first_run" "$second_run"
  pane=01a1b2c3-0000-7000-8000-000000000001
  session=01a1b2c3-0000-7000-8000-0000000000aa
  data_root="$fixture/data"
  zmx="$data_root/bin/zmx"
  owned_pid=4242
  stub_front="$owned_pid"; stub_session="$session"; stub_rows=""
  write_owner() {
    printf 'VERIFY_PID=%s\nVERIFY_CODE=t3st\nVERIFY_BUILD_PATH=%q\nVERIFY_SOURCE_COMMIT=%s\nVERIFY_DATA_ROOT=%q\n' \
      "$2" "$fixture/build" aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa "$data_root" > "$1/owner.env"
  }
  write_owner "$first_run" 4242
  write_owner "$second_run" 5353

  # Ownership is debug-lifecycle.sh's tested contract; here it loads the receipt.
  verify_owned_live() { verify_run_directory "$1"; source "$VERIFY_RUN_DIR/owner.env"; }
  verify_load_context() { verify_owned_live "$1"; }
  verify_inspection_available() { :; }
  terminal_front_pid() { printf '%s\n' "$stub_front"; }
  terminal_sqlite() { printf '%s' "$stub_session"; }
  terminal_ps_rows() { printf '%s\n' "$stub_rows"; }
  terminal_peekaboo() { printf '%s\n' "$*" >> "$fixture/peekaboo.calls"; }

  # Fixtures: written once, print the declared content, write only their marker.
  verify_owned_live "$first_run"
  terminal_write_fixtures > /dev/null; check
  expect_failure terminal_write_fixtures
  fixtures="$first_run/fixtures"
  [[ "$(sh "$fixtures/plain.sh" T1)" == 'J11_PLAIN T1 The quick brown fox'* ]]; check
  [ "$(sh "$fixtures/palette256.sh" T1 | grep -o '48;5;' | wc -l | tr -d ' ')" = 240 ]; check
  [ "$(sh "$fixtures/truecolor.sh" T1 | grep -o '48;2;' | wc -l | tr -d ' ')" = 384 ]; check
  [ "$(wc -l < "$fixtures/tui.txt" | tr -d ' ')" = 201 ]; check
  [ "$(grep -c ' END[0-9][0-9][0-9]$' "$fixtures/tui.txt")" = 200 ]; check
  [ "$(awk 'NR == 2 { print length($0) }' "$fixtures/tui.txt")" -gt 300 ]; check
  (cd "$fixtures" && shasum -a 256 -c SHA256SUMS > /dev/null); check
  # Read the fixture's trap-installed announcement directly; EOF is early exit.
  # The alarm is only a hang guard, never the readiness or interruption verdict.
  interrupt_status=0
  /usr/bin/perl -e '
    my $awaited_fact = "interrupt fixture readiness (SIGINT trap installed)";
    my ($fixture_pid, $fixture_output);
    $SIG{ALRM} = sub { die "hang guard: awaiting $awaited_fact\n" };
    eval {
      alarm 5;
      $fixture_pid = open($fixture_output, "-|");
      defined $fixture_pid or die "cannot start interrupt fixture: $!\n";
      if ($fixture_pid == 0) {
        alarm 0;
        # sh cannot trap SIGINT if it was ignored on entry.
        $SIG{INT} = "DEFAULT";
        exec "sh", @ARGV;
        die "cannot execute interrupt fixture: $!\n";
      }
      my $readiness_line = <$fixture_output>;
      defined $readiness_line or die "interrupt fixture exited before announcing readiness\n";
      $readiness_line =~ /J12_WAITING/ or die "unexpected interrupt fixture readiness: $readiness_line";
      print $readiness_line;
      $awaited_fact = "interrupt fixture termination after SIGINT";
      alarm 5;
      kill("INT", $fixture_pid) == 1 or die "cannot interrupt fixture: $!\n";
      print while <$fixture_output>;
      close $fixture_output;
      my $fixture_status = $?;
      alarm 0;
      exit(($fixture_status & 127) ? 128 + ($fixture_status & 127) : $fixture_status >> 8);
    };
    my $failure = $@;
    alarm 0;
    if (defined $fixture_pid && $fixture_pid > 0) {
      kill "KILL", $fixture_pid;
      waitpid $fixture_pid, 0;
    }
    die $failure;
  ' "$fixtures/interrupt.sh" "$fixture/interrupt.marker" > "$fixture/interrupt.out" || interrupt_status=$?
  [ "$interrupt_status" = 130 ] && [ "$(cat "$fixture/interrupt.marker")" = INTERRUPTED ]; check

  # Session: exactly one stored UUID, recorded once.
  stub_session='not-a-uuid'
  expect_failure terminal_select_session "$pane"
  rm -f "$first_run/terminal-session.env"
  stub_session="$session"$'\n'"$session"
  expect_failure terminal_select_session "$pane"
  stub_session="$session"
  terminal_select_session "$pane" > /dev/null; check
  expect_failure terminal_select_session "$pane"

  # Daemon rows: only this root's zmx and this session.
  start='Fri Nov  6 21:00:00 2026'
  daemon_row="  700 $start $zmx attach $session /bin/zsh -i -l"
  stub_rows="$daemon_row"$'\n'"  701 $start /other/.agentstudio-db/x/bin/zmx attach $session"$'\n'"  702 $start $zmx attach 01a1b2c3-0000-7000-8000-0000000000bb"
  terminal_daemon after-quit > /dev/null
  [ "$(cat "$first_run/daemon-after-quit.txt")" = "$daemon_row" ]; check
  expect_failure terminal_daemon after-quit

  # Foreground input: refused unless the owned PID is frontmost before dispatch.
  : > "$fixture/peekaboo.calls"
  stub_front=999
  expect_failure terminal_input type 77 'echo hi'
  [ ! -s "$fixture/peekaboo.calls" ]; check
  stub_front="$owned_pid"
  expect_failure terminal_input type 0 'echo hi'
  expect_failure terminal_input type 77 ''
  terminal_input type 77 'echo hi' > /dev/null
  grep -qx "type echo hi --pid $owned_pid --window-id 77 --foreground --accept-dispatched --no-remote --json" "$fixture/peekaboo.calls"; check
  terminal_input press 77 ctrl+c > /dev/null
  grep -qx "press ctrl+c --pid $owned_pid --window-id 77 --foreground --no-remote --json" "$fixture/peekaboo.calls"; check

  # Warm link: same identity, pane, session and surviving daemon.
  touch "$first_run/quit-confirmed"
  printf '[{"id":"%s"}]\n' "$pane" > "$second_run/panes-baseline.json"
  stub_front=5353
  link_case() {
    rm -f "$second_run/terminal-session.env" "$second_run/daemon-after-relaunch.txt" "$second_run/warm-link.txt"
    terminal_warm_link "$first_run" "$second_run"
  }
  stub_rows="$daemon_row"$'\n'"  900 Fri Nov  6 21:05:00 2026 $zmx attach $session /bin/sh -c x token"
  link_case > /dev/null
  grep -q "daemon=700 (Fri Nov 6 21:00:00 2026)" "$second_run/warm-link.txt" ||
    grep -q "daemon=700 ($start)" "$second_run/warm-link.txt"; check
  stub_rows="  900 Fri Nov  6 21:05:00 2026 $zmx attach $session /bin/sh -c x token"
  expect_failure link_case
  stub_rows="  700 Fri Nov  6 21:04:00 2026 $zmx attach $session"
  expect_failure link_case
  stub_rows="$daemon_row"
  stub_session=01a1b2c3-0000-7000-8000-0000000000cc
  expect_failure link_case
  stub_session="$session"
  printf '[]\n' > "$second_run/panes-baseline.json"
  expect_failure link_case
  printf '[{"id":"%s"}]\n' "$pane" > "$second_run/panes-baseline.json"
  write_owner "$second_run" 5353
  sed -i '' 's/^VERIFY_SOURCE_COMMIT=.*/VERIFY_SOURCE_COMMIT=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb/' "$second_run/owner.env"
  expect_failure link_case
  write_owner "$second_run" 5353
  rm -f "$first_run/quit-confirmed"
  expect_failure link_case

  printf '%s passed, 0 failed; terminal-journeys control paths with private stubs, no app/zmx/desktop\n' "$passed"
)
