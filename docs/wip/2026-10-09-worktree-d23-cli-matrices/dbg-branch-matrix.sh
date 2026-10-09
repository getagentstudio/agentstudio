#!/bin/bash
# Debug-CLI matrix for D13-D23 on a synthetic repo with local bare origin and upstream.
# The production remote client refuses file transport: opening falls back to refs on disk, but
# D23 creation fails closed at the origin question. Successful -c rows use --no-fetch explicitly;
# the https matrix proves live origin presence/absence. No network.
# Usage: dbg-branch-matrix.sh <cli-binary> <work-dir>
set -u
CLI="$1"; WORK="$2"
[ -e "$WORK" ] && { echo "work dir exists: $WORK"; exit 2; }
mkdir -p "$WORK"; cd "$WORK" || exit 2
run() { env -u AGENTSTUDIO_PANE_ID -u AGENTSTUDIO_IPC_TOKEN "$CLI" worktree "$@" 2>&1; }
g() { git "$@"; }   # configured identity; never override it
pass=0; fail=0
check() { if [ "$2" = "$3" ]; then pass=$((pass+1)); printf 'ok    %-58s %s\n' "$1" "$2"; else fail=$((fail+1)); printf 'FAIL  %-58s got=[%s] want=[%s]\n' "$1" "$2" "$3"; fi; }

no_worktree() {
  check "$1: no destination" "$([ -e "app.$2" ] && echo present || echo absent)" "absent"
  check "$1: not registered" "$(git -C app worktree list --porcelain | grep -c "/app\.$2$")" "0"
}
nothing_created() {
  no_worktree "$1" "$2"
  check "$1: no local branch" "$(git -C app show-ref --verify --quiet "refs/heads/$2" && echo present || echo absent)" "absent"
}

# --- arrange: bare origin, bare upstream, main clone with branches in each state
g init -q --bare origin.git; g init -q --bare upstream.git
g init -q -b main app; cd app
printf '{"worktree":{"include":["build/"]}}\n' > .agentstudio.config.json
printf 'build/\n' > .gitignore; echo v1 > tracked.txt
g add -A; g commit --no-gpg-sign -qm base; g remote add origin ../origin.git; g remote add upstream ../upstream.git
g push -q origin main
g switch -qc feat; echo feat1 > feat.txt; g add -A; g commit --no-gpg-sign -qm feat1; echo feat2 >> feat.txt; g commit --no-gpg-sign -qam feat2
g push -q origin feat; g switch -q main; g branch -qf feat feat~1             # local feat strictly behind origin/feat
g switch -qc div; echo local > div.txt; g add -A; g commit --no-gpg-sign -qm div-local; g switch -q main
g switch -qc div-remote; echo remote > divr.txt; g add -A; g commit --no-gpg-sign -qm div-remote
g push -q origin div-remote:div; g switch -q main; g branch -qD div-remote  # origin/div and local div diverged
g fetch -q origin
g switch -qc remote-only; echo r > r.txt; g add -A; g commit --no-gpg-sign -qm r; g push -q origin remote-only; g switch -q main; g branch -qD remote-only
g update-ref refs/remotes/origin/gone "$(g rev-parse origin/feat)"   # a tracking ref origin never had, at a commit other than main HEAD
g switch -qc up-only; echo u > u.txt; g add -A; g commit --no-gpg-sign -qm u; g push -q upstream up-only; g switch -q main; g branch -qD up-only
g branch -q local-taken
g switch -qc busy; g switch -q main; g worktree add -q ../app.busy-holder busy
mkdir -p build; echo cache > build/out.o; touch -t 202001010000 build/out.o; echo scratch > untracked.txt; echo dirty >> tracked.txt
main_head=$(g rev-parse HEAD); stale=$(g rev-parse refs/remotes/origin/gone); cd ..

# --- act + assert: D23 opening and creation are separate operations.
o=$(run new nowhere --repo app --json); rc=$?
check "missing name without -c: exit 1" "$rc" "1"
check "missing name without -c: noSuchBranch" "$(echo "$o" | grep -o '"reason":"noSuchBranch"')" '"reason":"noSuchBranch"'
check "missing name: file-origin fetch failed" "$(echo "$o" | grep -o '"status":"failed"')" '"status":"failed"'
nothing_created "missing name" nowhere

o=$(run new -c local-taken --repo app --json); rc=$?
check "-c local branch: exit 1" "$rc" "1"
check "-c local branch: branchAlreadyExists" "$(echo "$o" | grep -o '"reason":"branchAlreadyExists"')" '"reason":"branchAlreadyExists"'
check "-c local branch: no fetch object" "$(echo "$o" | grep -c '"fetch":')" "0"
check "-c local branch: tip unchanged" "$(git -C app rev-parse local-taken)" "$main_head"
no_worktree "-c local branch" local-taken

# File transport cannot answer origin's question. --no-fetch lets its on-disk ref answer instead.
# Plain -c origin-only refusal by live origin is covered by dbg-remote-matrix.sh.
o=$(run new -c remote-only --repo app --json); rc=$?
check "-c origin-only with file transport: exit 1" "$rc" "1"
check "-c origin-only with file transport: originCheckFailed" "$(echo "$o" | grep -o '"reason":"originCheckFailed"')" '"reason":"originCheckFailed"'
check "-c origin-only with file transport: no fetch object" "$(echo "$o" | grep -c '"fetch":')" "0"
nothing_created "-c origin-only with file transport" remote-only
o=$(run new -c remote-only --no-fetch --repo app --json); rc=$?
check "-c origin ref on disk: exit 1" "$rc" "1"
check "-c origin ref on disk: branchAlreadyExists" "$(echo "$o" | grep -o '"reason":"branchAlreadyExists"')" '"reason":"branchAlreadyExists"'
check "-c origin ref on disk: origin detail" "$(echo "$o" | grep -o '"detail":"origin/remote-only"')" '"detail":"origin/remote-only"'
check "-c origin ref on disk: no fetch object" "$(echo "$o" | grep -c '"fetch":')" "0"
nothing_created "-c origin ref on disk" remote-only

o=$(run new zz-usage-start --from-branch feat --repo app); rc=$?
check "--from-branch without -c: exit 64" "$rc" "64"
check "--from-branch without -c: message" "$o" "--from-branch creates a new branch, so it needs -c (--create)"
nothing_created "--from-branch without -c" zz-usage-start
o=$(run new zz-usage-changes --changes-only --from app --repo app); rc=$?
check "--changes-only without -c: exit 64" "$rc" "64"
check "--changes-only without -c: message" "$o" "--changes-only creates a new branch, so it needs -c (--create)"
nothing_created "--changes-only without -c" zz-usage-changes

# D23: new-name formerly created implicitly; now creation is explicit and skips the file-origin probe.
o=$(run new -c new-name --no-fetch --repo app --json); rc=$?
check "new name: exit 0" "$rc" "0"
check "new name: created outcome" "$(echo "$o" | grep -o '"outcome":"created"')" '"outcome":"created"'
check "new name: skipped(noFetchFlag)" "$(echo "$o" | grep -o '"reason":"noFetchFlag"')" '"reason":"noFetchFlag"'
check "new name: branch at main HEAD" "$(git -C app.new-name rev-parse HEAD 2>/dev/null)" "$main_head"
check "new name: as-is copy keeps untracked" "$(cat app.new-name/untracked.txt 2>/dev/null || echo MISSING)" "scratch"
o=$(run new feat --repo app); check "existing behind: fast-forwarded" "$(git -C app rev-parse feat)" "$(git -C app rev-parse origin/feat)"
check "existing behind: line" "$(echo "$o" | tail -1 | grep -c 'existing branch; fast-forwarded to origin/feat')" "1"
check "existing behind: reset leaves out main's untracked" "$([ -d app.feat ] || echo MISSING; [ -d app.feat ] && { [ -e app.feat/untracked.txt ] && echo present || echo absent; })" "absent"
check "existing behind: included ignored kept, mtime kept" "$(stat -f %m app.feat/build/out.o 2>/dev/null)" "$(stat -f %m app/build/out.o)"
check "existing behind: tracked file reset" "$(cat app.feat/tracked.txt)" "v1"
check "existing behind: status clean" "$([ -d app.feat ] && git -C app.feat status --porcelain | wc -l | tr -d ' ' || echo MISSING)" "0"
o=$(run new div --repo app); check "diverged: local kept" "$(git -C app.div rev-parse HEAD)" "$(git -C app rev-parse div)"
check "diverged: note" "$(echo "$o" | tail -1 | grep -c 'kept local div')" "1"
o=$(run new remote-only --repo app); check "origin-only: created at origin tip" "$(git -C app rev-parse remote-only 2>/dev/null)" "$(git -C origin.git rev-parse remote-only)"
check "origin-only: upstream" "$(git -C app rev-parse --abbrev-ref remote-only@{upstream} 2>/dev/null)" "origin/remote-only"
o=$(run new gone --repo app --json); check "fallback (file transport refused, fetch failed): stale ref on disk is used" "$(git -C app rev-parse gone 2>/dev/null)" "$stale"
o=$(run new -c zz-gone2 --no-fetch --from-branch origin/gone --repo app --json); check "--no-fetch: --from-branch of the on-disk ref starts there" "$(git -C app rev-parse zz-gone2 2>/dev/null)" "$stale"
o=$(run new busy --repo app --json); check "checked out elsewhere: refused" "$(echo "$o" | grep -o '"reason":"branchCheckedOut"' | head -1)" '"reason":"branchCheckedOut"'
o=$(run new -c zz-up --no-fetch --from-branch upstream/up-only --repo app); check "second remote start" "$(git -C app rev-parse zz-up 2>/dev/null)" "$(git -C upstream.git rev-parse up-only)"
o=$(run new -c zz-nofork --no-fetch --from-branch origin/feat --no-fork --repo app); check "--no-fork from-branch: head" "$(git -C app.zz-nofork rev-parse HEAD 2>/dev/null)" "$(git -C app rev-parse origin/feat)"
check "--no-fork: no ignored files" "$([ -d app.zz-nofork ] || echo MISSING; [ -d app.zz-nofork ] && { [ -e app.zz-nofork/build ] && echo present || echo absent; })" "absent"
check "--no-fork: line" "$(echo "$o" | tail -1 | grep -c '(checkout')" "1"
o=$(run new -c zz-tracked --tracked-only --repo app); rc=$?
check "--tracked-only: exit 64" "$rc" "64"
# --- review corrections (batches 1-6) through the real binary
o=$(run new feat --repo app); rc=$?
check "re-run at its own sibling: exit 1" "$rc" "1"
check "re-run at its own sibling: branchCheckedOut at app.feat" "$(echo "$o" | grep -c '^refused: branchCheckedOut .*/app\.feat')" "1"
o=$(run new HEAD --repo app --json); rc=$?
check "new HEAD: exit 1" "$rc" "1"
check "new HEAD: invalidBranchName" "$(echo "$o" | grep -o '"reason":"invalidBranchName"' | head -1)" '"reason":"invalidBranchName"'
side=$(git -C app rev-parse feat); [ "$side" != "$main_head" ] || side=MISSETUP
git -C app update-ref 'refs/heads/@' "$side"
o=$(run new -c zz-at --no-fetch --from-branch @ --repo app); check "start from a branch named @: its tip, not HEAD" "$(git -C app rev-parse zz-at 2>/dev/null)" "$side"
git -C app branch -q 'rel/a./b' "$side"
o=$(run new -c zz-dot --no-fetch --from-branch 'rel/a./b' --repo app); check "start from rel/a./b (inner dot-ended component)" "$(git -C app rev-parse zz-dot 2>/dev/null)" "$side"
nbsp=$(printf 'rel/a\302\240b'); git -C app branch -q "$nbsp" "$side"
o=$(run new -c zz-nbsp --no-fetch --from-branch "$nbsp" --repo app); check "start from a name with a no-break space" "$(git -C app rev-parse zz-nbsp 2>/dev/null)" "$side"
mkdir app.HEAD
o=$(run remove HEAD --dry-run --repo app --json)
check "remove HEAD with app.HEAD present: notFound" "$(echo "$o" | grep -q notFound && echo yes || echo no)" "yes"
check "remove HEAD with app.HEAD present: not alreadyRemoved" "$(echo "$o" | grep -q alreadyRemoved && echo yes || echo no)" "no"
# D23 long-form creation; no ref on disk means free when --no-fetch is explicit.
o=$(run new --create zz-long --no-fetch --repo app --json); rc=$?
check "--create long form: exit 0" "$rc" "0"
check "--create long form: created" "$(echo "$o" | grep -o '"outcome":"created"')" '"outcome":"created"'
check "--create long form: source HEAD" "$(git -C app.zz-long rev-parse HEAD 2>/dev/null)" "$main_head"
check "--create long form: fetch skipped" "$(echo "$o" | grep -o '"status":"skipped"')" '"status":"skipped"'
check "--create long form: noFetchFlag" "$(echo "$o" | grep -o '"reason":"noFetchFlag"')" '"reason":"noFetchFlag"'

# D23: an unreachable origin no longer permits implicit creation or -c without --no-fetch.
git -C app remote set-url origin "$WORK/nowhere.git"
o=$(run new -c zz-offline --repo app --json); rc=$?
check "unreachable origin -c: exit 1" "$rc" "1"
check "unreachable origin -c: originCheckFailed" "$(echo "$o" | grep -o '"reason":"originCheckFailed"')" '"reason":"originCheckFailed"'
check "unreachable origin -c: no fetch object" "$(echo "$o" | grep -c '"fetch":')" "0"
nothing_created "unreachable origin -c" zz-offline

o=$(run new -c zz-offline --no-fetch --repo app --json); rc=$?
check "unreachable origin -c --no-fetch: exit 0" "$rc" "0"
check "unreachable origin -c --no-fetch: created" "$(echo "$o" | grep -o '"outcome":"created"')" '"outcome":"created"'
check "unreachable origin -c --no-fetch: source HEAD" "$(git -C app.zz-offline rev-parse HEAD 2>/dev/null)" "$main_head"
check "unreachable origin -c --no-fetch: noFetchFlag" "$(echo "$o" | grep -o '"reason":"noFetchFlag"')" '"reason":"noFetchFlag"'

o=$(run new zz-offline-missing --repo app --json); rc=$?
check "unreachable origin missing name: exit 1" "$rc" "1"
check "unreachable origin missing name: noSuchBranch" "$(echo "$o" | grep -o '"reason":"noSuchBranch"')" '"reason":"noSuchBranch"'
check "unreachable origin missing name: fetch failed" "$(echo "$o" | grep -o '"status":"failed"')" '"status":"failed"'
nothing_created "unreachable origin missing name" zz-offline-missing

# With no origin, -c checks local names only, even though upstream is still configured.
git -C app remote remove origin
o=$(run new -c zz-no-origin --repo app --json); rc=$?
check "no origin -c: exit 0" "$rc" "0"
check "no origin -c: created" "$(echo "$o" | grep -o '"outcome":"created"')" '"outcome":"created"'
check "no origin -c: source HEAD" "$(git -C app.zz-no-origin rev-parse HEAD 2>/dev/null)" "$main_head"
check "no origin -c: fetch skipped" "$(echo "$o" | grep -o '"status":"skipped"')" '"status":"skipped"'
check "no origin -c: noRemote" "$(echo "$o" | grep -o '"reason":"noRemote"')" '"reason":"noRemote"'
o=$(run new -c local-taken --repo app --json); rc=$?
check "no origin -c local branch: exit 1" "$rc" "1"
check "no origin -c local branch: branchAlreadyExists" "$(echo "$o" | grep -o '"reason":"branchAlreadyExists"')" '"reason":"branchAlreadyExists"'
check "no origin -c local branch: no fetch object" "$(echo "$o" | grep -c '"fetch":')" "0"
check "no origin -c local branch: tip unchanged" "$(git -C app rev-parse local-taken)" "$main_head"
no_worktree "no origin -c local branch" local-taken
check "main untouched" "$(git -C app status --porcelain | sort | tr '\n' ' ')" " M tracked.txt ?? untracked.txt "
echo "pass=$pass fail=$fail"
[ "$fail" = 0 ]
