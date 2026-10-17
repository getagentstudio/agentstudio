#!/bin/bash
# Plan "one real checkout" row: `new -c <b> --from-branch origin/main` in an agentstudio checkout. Runs against a fresh
# scratch clone (no real repository is touched), checks the created tree is clean at origin/main and that the one
# line is right, then removes the created tree with the CLI itself. Usage: dbg-real-checkout.sh <cli-binary> <work-dir>
set -u
CLI="$1"; WORK="$2"; URL=https://github.com/getagentstudio/agentstudio.git
[ -e "$WORK" ] && { echo "work dir exists: $WORK"; exit 2; }
mkdir -p "$WORK"; cd "$WORK" || exit 2
run() { env -u AGENTSTUDIO_PANE_ID -u AGENTSTUDIO_IPC_TOKEN "$CLI" worktree "$@" 2>&1; }
pass=0; fail=0
check() { if [ "$2" = "$3" ]; then pass=$((pass+1)); printf 'ok    %-62s %s\n' "$1" "$2"; else fail=$((fail+1)); printf 'FAIL  %-62s got=[%s] want=[%s]\n' "$1" "$2" "$3"; fi; }

echo "# free space before: $(df -h "$WORK" | tail -1 | awk '{print $4}')"
GIT_LFS_SKIP_SMUDGE=1 git clone -q "$URL" agentstudio || { echo "clone failed"; exit 3; }
origin_main=$(git -C agentstudio rev-parse origin/main)
dest="$WORK/agentstudio.zz-real"

o=$(run new -c zz-real --from-branch origin/main --repo agentstudio); rc=$?
echo "$o" | sed 's/^/# output: /'
check "real checkout: exit 0" "$rc" "0"
check "real checkout: one line" "$(echo "$o" | grep -c .)" "1"
line=$(echo "$o" | tail -1)
printed=$(echo "$line" | sed -E 's/^created zz-real at (.*) \(copy-on-write; from origin\/main\)$/\1/')
# macOS: the CLI prints the standardized path (/tmp/...), the same directory as $dest (/private/tmp/...).
check "real checkout: the line's shape" "$(echo "$line" | sed -E 's/^created zz-real at .* \(copy-on-write; from origin\/main\)$/ok/')" "ok"
check "real checkout: the line names the created tree" "$(cd "$printed" 2>/dev/null && pwd -P)" "$(cd "$dest" 2>/dev/null && pwd -P)"
check "real checkout: HEAD at origin/main" "$(git -C "$dest" rev-parse HEAD 2>/dev/null)" "$origin_main"
check "real checkout: on branch zz-real" "$(git -C "$dest" symbolic-ref --short HEAD 2>/dev/null)" "zz-real"
submodules=$(git -C agentstudio config -f .gitmodules --get-regexp 'submodule\..*\.path' 2>/dev/null | awk '{print $2}' | sort | tr '\n' ' ')
echo "# listed submodules: ${submodules:-none}"
printf '%s\n' $submodules > "$WORK/submodule-paths.txt"
dirty=$(git -C "$dest" status --porcelain 2>/dev/null | awk '{print $NF}' | grep -vxF -f "$WORK/submodule-paths.txt" | tr '\n' ' ')
check "real checkout: status clean except listed submodules" "${dirty:-clean}" "clean"
check "real checkout: source untouched" "$(git -C agentstudio status --porcelain | wc -l | tr -d ' ')" "0"

r=$(run remove zz-real --repo agentstudio); rrc=$?
echo "$r" | sed 's/^/# remove: /'
check "cleanup: remove exit 0" "$rrc" "0"
check "cleanup: created tree gone" "$([ -e "$dest" ] && echo present || echo gone)" "gone"
check "cleanup: worktree unregistered" "$(git -C agentstudio worktree list --porcelain | grep -c "/agentstudio\.zz-real$")" "0"
echo "# free space after: $(df -h "$WORK" | tail -1 | awk '{print $4}')"
echo "pass=$pass fail=$fail"
[ "$fail" = 0 ]
