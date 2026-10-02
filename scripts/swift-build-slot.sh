#!/usr/bin/env bash
# Source, then acquire the worktree's one build slot. Callers own the EXIT trap
# and invoke swift_build_slot_release from that handler.
#
# Each worktree has ONE build directory, .build-agent-1, shared by build tasks
# and test tasks (owner decision 2026-10-01: a second directory per worktree
# costs several GB of disk). The `build` or `test` name labels the claimant in
# logs and holder notes; both claim the same lock, so a test run waits for a
# build in the same worktree and vice versa.
#
# A slot is a kernel flock on <build dir>/.slot.lock, held by a small perl
# holder process started for the acquiring shell. The kernel drops the lock
# whenever that holder exits: on release, on an error, on Ctrl-C, on kill -9 or
# a crash. So there is no stale-claim reaping and no process inspection (no ps,
# no lsof), and it works inside agent sandboxes that deny process metadata.
#
# Never delete a .slot.lock file. The lock is the kernel flock on it, not the
# file's existence; deleting it while held would let a second claimant in.
#
# Known limit: if the acquiring shell is killed without running its EXIT trap,
# the holder exits when the shell's pipe to it closes. A background child the
# shell leaked keeps that pipe open, so the slot stays held until that child
# exits too.

swift_build_slot_resolve_directory() {
  case "$1" in
    build | test) printf '%s\n' '.build-agent-1' ;;
    *)
      echo "swift-build-slot: expected slot 'build' or 'test', got '$1'" >&2
      return 2
      ;;
  esac
}

# Arguments: lock file, holder note, task label, acquiring shell pid, ready
# FIFO, slot name. Takes the lock (waiting in the kernel when it is busy),
# records the holder, reports "ACQUIRED <pid>", then holds until the acquiring
# shell's pipe closes or release sends TERM. perl marks the lock descriptor
# close-on-exec, and the holder never runs anything, so no other process ever
# inherits the lock.
SWIFT_BUILD_SLOT_HOLDER_PERL='
use strict;
use warnings;
use Fcntl qw(:flock);
my ($lock_path, $note_path, $task, $owner_pid, $ready_path, $slot) = @ARGV;
$| = 1;
open(my $ready, ">", $ready_path) or exit 3;
open(my $lock, ">>", $lock_path) or die "swift-build-slot: cannot open $lock_path: $!\n";
if (!flock($lock, LOCK_EX | LOCK_NB)) {
  my $holder = "holder_task=unknown";
  if (open(my $note, "<", $note_path)) {
    local $/;
    my $contents = <$note>;
    close($note);
    if (defined $contents) { $contents =~ s/\s+\z//; $holder = $contents if length $contents; }
  }
  print STDOUT "[swift-build-slot] waiting slot=$slot $holder\n";
  flock($lock, LOCK_EX) or die "swift-build-slot: cannot lock $lock_path: $!\n";
}
my $started = scalar localtime;
if (open(my $note, ">", $note_path)) {
  print $note "holder_task=$task holder_pid=$owner_pid holder_start=$started\n";
  close($note);
}
$SIG{TERM} = sub { unlink($note_path); exit 0; };
$SIG{INT} = "IGNORE";
{ my $old = select($ready); $| = 1; select($old); }
print $ready "ACQUIRED $$\n";
close($ready);
while (defined(my $line = <STDIN>)) { }
unlink($note_path);
exit 0;
'

swift_build_slot_acquire() {
  local requested_slot="${1:-}"
  local task_label="${2:-}"
  local build_directory ready_fifo hold_fifo ready_status holder_process_id ready_holder_process_id

  if [ -n "${SWIFT_BUILD_DIR:-}" ]; then
    if { [ "${CI:-}" = "true" ] || [ "${GITHUB_ACTIONS:-}" = "true" ]; } &&
      [ "$SWIFT_BUILD_DIR" = '.build-ci' ]
    then
      echo "[swift-build-slot] using CI build path $SWIFT_BUILD_DIR"
      return 0
    fi
    echo "swift-build-slot: local SWIFT_BUILD_DIR overrides are not supported" >&2
    return 1
  fi

  if [ -z "$task_label" ]; then
    echo "swift-build-slot: task label is required" >&2
    return 2
  fi

  build_directory="$(swift_build_slot_resolve_directory "$requested_slot")" || return $?
  if ! mkdir -p "$build_directory"; then
    echo "swift-build-slot: cannot create build directory $build_directory" >&2
    return 1
  fi
  if ! command -v perl >/dev/null 2>&1; then
    echo "swift-build-slot: perl is required to hold a slot lock" >&2
    return 2
  fi

  ready_fifo="$build_directory/.slot.ready.$$"
  hold_fifo="$build_directory/.slot.hold.$$"
  /bin/rm -f "$ready_fifo" "$hold_fifo"
  if ! mkfifo "$ready_fifo" "$hold_fifo"; then
    /bin/rm -f "$ready_fifo" "$hold_fifo"
    echo "swift-build-slot: cannot create slot channels in $build_directory" >&2
    return 2
  fi

  # The holder reads the hold FIFO; this shell keeps its write end open on fd 97,
  # so the holder also ends when this shell goes away without its EXIT trap.
  # Named FIFOs, not process substitution: agent sandboxes deny /dev/fd pipes.
  perl -e "$SWIFT_BUILD_SLOT_HOLDER_PERL" \
    "$build_directory/.slot.lock" "$build_directory/.slot.holder" \
    "$task_label" "$$" "$ready_fifo" "$requested_slot" < "$hold_fifo" &
  holder_process_id="$!"
  if ! { exec 97> "$hold_fifo"; } 2>/dev/null; then
    kill -TERM "$holder_process_id" 2>/dev/null || true
    /bin/rm -f "$ready_fifo" "$hold_fifo"
    echo "swift-build-slot: cannot open the slot holder channel for slot $requested_slot" >&2
    return 2
  fi
  /bin/rm -f "$hold_fifo"

  ready_status=""
  ready_holder_process_id=""
  IFS=' ' read -r ready_status ready_holder_process_id < "$ready_fifo" || true
  /bin/rm -f "$ready_fifo"
  if [ "$ready_status" != "ACQUIRED" ] || [ "$ready_holder_process_id" != "$holder_process_id" ]; then
    exec 97>&-
    kill -TERM "$holder_process_id" 2>/dev/null || true
    echo "swift-build-slot: could not acquire slot $requested_slot" >&2
    return 2
  fi

  SWIFT_BUILD_SLOT_NAME="$requested_slot"
  SWIFT_BUILD_SLOT_TASK="$task_label"
  SWIFT_BUILD_SLOT_HOLDER_PID="$holder_process_id"
  SWIFT_BUILD_SLOT_CLAIM_DIRECTORY="$build_directory"
  SWIFT_BUILD_DIR="$build_directory"
  export SWIFT_BUILD_DIR
  echo "[swift-build-slot] using slot=$SWIFT_BUILD_SLOT_NAME path=$SWIFT_BUILD_DIR task=$SWIFT_BUILD_SLOT_TASK"
  return 0
}

swift_build_slot_release() {
  local exit_status=$?

  [ -n "${SWIFT_BUILD_SLOT_HOLDER_PID:-}" ] || return "$exit_status"
  kill -TERM "$SWIFT_BUILD_SLOT_HOLDER_PID" 2>/dev/null || true
  exec 97>&-
  echo "[swift-build-slot] released slot=${SWIFT_BUILD_SLOT_NAME:-unknown} task=${SWIFT_BUILD_SLOT_TASK:-unknown}"

  unset SWIFT_BUILD_SLOT_NAME SWIFT_BUILD_SLOT_TASK
  unset SWIFT_BUILD_SLOT_HOLDER_PID SWIFT_BUILD_SLOT_CLAIM_DIRECTORY
  return "$exit_status"
}

# Exit 0 when the slot's lock is free right now (it is taken and immediately
# released), 1 when another process holds it. Used by cleanup tasks, which must
# never remove a slot's files while it is held.
swift_build_slot_lock_is_free() {
  local build_directory="$1"
  perl -MFcntl=:flock -e '
    open(my $lock, ">>", $ARGV[0]) or exit 2;
    exit(flock($lock, LOCK_EX | LOCK_NB) ? 0 : 1);
  ' "$build_directory/.slot.lock"
}
