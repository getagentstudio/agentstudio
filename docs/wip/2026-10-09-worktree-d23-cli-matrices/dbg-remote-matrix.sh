#!/bin/bash
# Debug-CLI matrix for D13-D23 against a REAL https origin (GitHub), read-only: no pushes, every
# branch state is built on the local side. Usage: dbg-remote-matrix.sh <cli-binary> <work-dir>
set -u
CLI="$1"; WORK="$2"; URL=https://github.com/ShravanSunder/agent-vm.git
[ -e "$WORK" ] && { echo "work dir exists: $WORK"; exit 2; }
mkdir -p "$WORK"; cd "$WORK" || exit 2
run() { env -u AGENTSTUDIO_PANE_ID -u AGENTSTUDIO_IPC_TOKEN "$CLI" worktree "$@" 2>&1; }
pass=0; fail=0
check() { if [ "$2" = "$3" ]; then pass=$((pass+1)); printf 'ok    %-60s %s\n' "$1" "$2"; else fail=$((fail+1)); printf 'FAIL  %-60s got=[%s] want=[%s]\n' "$1" "$2" "$3"; fi; }
inwt() { [ -d "$1" ] && (cd "$1" && eval "$2") || echo MISSING; }

no_worktree() {
  check "$1: no destination" "$([ -e "app.$2" ] && echo present || echo absent)" "absent"
  check "$1: not registered" "$(git -C app worktree list --porcelain | grep -c "/app\.$2$")" "0"
}
nothing_created() {
  no_worktree "$1" "$2"
  check "$1: no local branch" "$(git -C app show-ref --verify --quiet "refs/heads/$2" && echo present || echo absent)" "absent"
}

# --- arrange: a fresh standalone clone, then local-only branch states
git clone -q "$URL" app || { echo "clone failed"; exit 3; }
cd app
DEF=$(git symbolic-ref --short HEAD)
printf '{"worktree":{"include":["build/"]}}\n' > .agentstudio.config.json
printf 'build/\n.agentstudio.config.json\n' >> .git/info/exclude
mkdir -p build; echo cache > build/out.o; touch -t 202001010000 build/out.o
BEH=feat/tool-vm-configured-cli; DIV=fix/ci-action-event-race; RONLY=design/cli-logging-modernization
UPB=chore/dev-sync-tarballs; BUSY=feat/hermes-0-21-5
git branch -q "$BEH" "origin/$BEH~1"                                      # strictly behind origin
git branch -q "$DIV" "origin/$DIV~1"; git switch -q "$DIV"; echo local > zz-div.txt; git add zz-div.txt; git commit --no-gpg-sign -qm "local only"; git switch -q "$DEF"   # diverged
STALE=$(git rev-parse "origin/$DEF~3"); git update-ref refs/remotes/origin/zz-gone-matrix "$STALE"   # a tracking ref origin never had
git worktree add -q ../app.busy-holder "origin/$BUSY" -b "$BUSY"         # held by another worktree
git remote add upstream "$URL"
echo scratch > untracked.txt; first=$(git ls-files | grep -v '^\.' | head -1); echo dirty >> "$first"
git branch -q local-taken
main_head=$(git rev-parse HEAD); div_tip=$(git rev-parse "$DIV"); cd ..

# --- act + assert: D23 opening and creation are separate operations.
o=$(run new zz-d23-nowhere-matrix --repo app --json); rc=$?
check "missing name without -c: exit 1" "$rc" "1"
check "missing name without -c: noSuchBranch" "$(echo "$o" | grep -o '"reason":"noSuchBranch"')" '"reason":"noSuchBranch"'
check "missing name without -c: notOnRemote" "$(echo "$o" | grep -o '"status":"notOnRemote"')" '"status":"notOnRemote"'
nothing_created "missing name without -c" zz-d23-nowhere-matrix

o=$(run new -c local-taken --repo app --json); rc=$?
check "-c local branch: exit 1" "$rc" "1"
check "-c local branch: branchAlreadyExists" "$(echo "$o" | grep -o '"reason":"branchAlreadyExists"')" '"reason":"branchAlreadyExists"'
check "-c local branch: no fetch object" "$(echo "$o" | grep -c '"fetch":')" "0"
check "-c local branch: tip unchanged" "$(git -C app rev-parse local-taken)" "$main_head"
no_worktree "-c local branch" local-taken

# Remove only the local tracking ref: -c must ask origin, refuse, and fetch nothing.
git -C app update-ref -d "refs/remotes/origin/$RONLY"
o=$(run new -c "$RONLY" --repo app --json); rc=$?
check "-c origin-only branch: exit 1" "$rc" "1"
check "-c origin-only branch: branchAlreadyExists" "$(echo "$o" | grep -o '"reason":"branchAlreadyExists"')" '"reason":"branchAlreadyExists"'
check "-c origin-only branch: origin detail" "$(echo "$o" | grep -o "\"detail\":\"origin/$RONLY\"")" "\"detail\":\"origin/$RONLY\""
check "-c origin-only branch: no fetch object" "$(echo "$o" | grep -c '"fetch":')" "0"
check "-c origin-only branch: tracking ref still absent" "$(git -C app show-ref --verify --quiet "refs/remotes/origin/$RONLY" && echo present || echo absent)" "absent"
check "-c origin-only branch: local branch absent" "$(git -C app show-ref --verify --quiet "refs/heads/$RONLY" && echo present || echo absent)" "absent"
check "-c origin-only branch: no destination" "$([ -e "app.$(echo "$RONLY" | tr '/' '-')" ] && echo present || echo absent)" "absent"

o=$(run new zz-usage-start --from-branch "$BEH" --repo app); rc=$?
check "--from-branch without -c: exit 64" "$rc" "64"
check "--from-branch without -c: message" "$o" "--from-branch creates a new branch, so it needs -c (--create)"
nothing_created "--from-branch without -c" zz-usage-start
o=$(run new zz-usage-changes --changes-only --from app --repo app); rc=$?
check "--changes-only without -c: exit 64" "$rc" "64"
check "--changes-only without -c: message" "$o" "--changes-only creates a new branch, so it needs -c (--create)"
nothing_created "--changes-only without -c" zz-usage-changes

# D23: zz-asis formerly created implicitly; now it requires -c.
o=$(run new -c zz-asis --repo app --json); rc=$?
check "as-is: exit 0" "$rc" "0"
check "as-is: notOnRemote" "$(echo "$o" | grep -o '"status":"notOnRemote"')" '"status":"notOnRemote"'
check "as-is: branch at main HEAD" "$(inwt app.zz-asis 'git rev-parse HEAD')" "$main_head"
check "as-is: keeps main's untracked file" "$(inwt app.zz-asis 'cat untracked.txt')" "scratch"
o=$(run new "$BEH" --repo app)
check "behind: fast-forwarded to origin" "$(git -C app rev-parse "$BEH")" "$(git -C app rev-parse "origin/$BEH")"
check "behind: line says existing + fast-forwarded" "$(echo "$o" | tail -1 | grep -c "existing branch; fast-forwarded to origin/$BEH")" "1"
d=app.$(echo "$BEH" | tr '/' '-')
check "behind: reset left out main's untracked" "$(inwt $d '[ -e untracked.txt ] && echo present || echo absent')" "absent"
check "behind: tracked file has the branch's content" "$(inwt $d "git diff --quiet HEAD -- '$first' && echo clean || echo dirty")" "clean"
check "behind: included ignored kept, mtime kept" "$(inwt $d 'stat -f %m build/out.o')" "$(stat -f %m app/build/out.o)"
check "behind: status clean" "$(inwt $d 'git status --porcelain | grep -v "^!!" | wc -l | tr -d " "')" "0"
o=$(run new "$DIV" --repo app)
check "diverged: worktree at the local tip" "$(inwt app.$(echo "$DIV" | tr "/" "-") "git rev-parse HEAD")" "$div_tip"
check "diverged: local branch not moved" "$(git -C app rev-parse "$DIV")" "$div_tip"
check "diverged: note" "$(echo "$o" | tail -1 | grep -c "kept local $DIV")" "1"
o=$(run new "$RONLY" --repo app)
check "origin-only: created at origin tip" "$(git -C app rev-parse "$RONLY" 2>/dev/null)" "$(git -C app rev-parse "origin/$RONLY")"
check "origin-only: upstream set" "$(git -C app rev-parse --abbrev-ref "$RONLY@{upstream}" 2>/dev/null)" "origin/$RONLY"
# D23: origin's absent answer defeats the stale tracking ref; opening no longer creates.
o=$(run new zz-gone-matrix --repo app --json); rc=$?
check "stale ref, absent on origin: exit 1" "$rc" "1"
check "stale ref, absent on origin: noSuchBranch" "$(echo "$o" | grep -o '"reason":"noSuchBranch"')" '"reason":"noSuchBranch"'
check "stale ref, absent on origin: notOnRemote" "$(echo "$o" | grep -o '"status":"notOnRemote"')" '"status":"notOnRemote"'
nothing_created "stale ref, absent on origin" zz-gone-matrix
# Without querying origin, that same stale ref counts as taken under -c --no-fetch.
o=$(run new -c zz-gone-matrix --no-fetch --repo app --json); rc=$?
check "-c --no-fetch stale ref on disk: exit 1" "$rc" "1"
check "-c --no-fetch stale ref on disk: branchAlreadyExists" "$(echo "$o" | grep -o '"reason":"branchAlreadyExists"')" '"reason":"branchAlreadyExists"'
check "-c --no-fetch stale ref on disk: no fetch object" "$(echo "$o" | grep -c '"fetch":')" "0"
nothing_created "-c --no-fetch stale ref on disk" zz-gone-matrix
# Preserve the original stale-ref creation row with -c: origin says absent, so the stale ref is ignored.
o=$(run new -c zz-gone-matrix --repo app --json); rc=$?
check "-c stale ref, absent on origin: exit 0" "$rc" "0"
check "-c stale ref, absent on origin: created" "$(echo "$o" | grep -o '"outcome":"created"')" '"outcome":"created"'
check "-c stale ref, absent on origin: source HEAD" "$(git -C app.zz-gone-matrix rev-parse HEAD 2>/dev/null)" "$main_head"
check "-c stale ref, absent on origin: sourceHead start" "$(echo "$o" | grep -o '"from":"sourceHead"')" '"from":"sourceHead"'
check "-c stale ref, absent on origin: notOnRemote" "$(echo "$o" | grep -o '"status":"notOnRemote"')" '"status":"notOnRemote"'
o=$(run new -c zz-gone2 --from-branch origin/zz-gone-matrix --repo app --json)
check "from-branch of a stale ref: refused" "$(echo "$o" | grep -o '"reason":"startBranchNotFound"' | head -1)" '"reason":"startBranchNotFound"'
o=$(run new "$BUSY" --repo app --json)
check "held by another worktree: refused" "$(echo "$o" | grep -o '"reason":"branchCheckedOut"' | head -1)" '"reason":"branchCheckedOut"'
o=$(run new -c zz-up --from-branch "upstream/$UPB" --repo app)
check "second remote start" "$(git -C app rev-parse zz-up 2>/dev/null)" "$(git -C app rev-parse "origin/$UPB")"
o=$(run new -c zz-nofork --from-branch "origin/$UPB" --no-fork --repo app)
check "--no-fork from-branch: head" "$(inwt app.zz-nofork 'git rev-parse HEAD')" "$(git -C app rev-parse "origin/$UPB")"
check "--no-fork: no ignored files" "$(inwt app.zz-nofork '[ -e build ] && echo present || echo absent')" "absent"
check "--no-fork: line says checkout" "$(echo "$o" | tail -1 | grep -c '(checkout')" "1"
run new -c zz-tracked --tracked-only --repo app >/dev/null; check "--tracked-only: exit 64" "$?" "64"
# D23: no-fetch with no tracking ref refuses opening, but -c creates at source HEAD.
# This also proves --no-fetch consults disk even when origin really has the name.
NF=$(git -C app for-each-ref --format='%(refname:short)' refs/remotes/origin | sed 's#^origin/##' \
  | grep -vxE "HEAD|origin|$DEF|$BEH|$DIV|$RONLY|$UPB|$BUSY|zz-gone-matrix" | head -1)
git -C app update-ref -d "refs/remotes/origin/$NF"
o=$(run new "$NF" --no-fetch --repo app --json); rc=$?
check "--no-fetch missing disk ref without -c: exit 1" "$rc" "1"
check "--no-fetch missing disk ref without -c: noSuchBranch" "$(echo "$o" | grep -o '"reason":"noSuchBranch"')" '"reason":"noSuchBranch"'
check "--no-fetch missing disk ref without -c: local branch absent" "$(git -C app show-ref --verify --quiet "refs/heads/$NF" && echo present || echo absent)" "absent"
check "--no-fetch missing disk ref without -c: no destination" "$([ -e "app.$(echo "$NF" | tr '/' '-')" ] && echo present || echo absent)" "absent"
o=$(run new -c "$NF" --no-fetch --repo app --json); rc=$?
check "-c --no-fetch missing disk ref: exit 0" "$rc" "0"
check "-c --no-fetch: starts at main HEAD" "$(git -C app rev-parse "$NF" 2>/dev/null)" "$main_head"
# An unrelated origin branch can share HEAD's commit: D23 constrains start identity, not inequality.
check "-c --no-fetch: start is sourceHead" "$(echo "$o" | grep -o '"from":"sourceHead"')" '"from":"sourceHead"'
check "-c --no-fetch: no upstream" "$(echo "$o" | grep -o '"upstream":null')" '"upstream":null'
check "-c --no-fetch: noFetchFlag" "$(echo "$o" | grep -o '"reason":"noFetchFlag"')" '"reason":"noFetchFlag"'
check "--no-fetch: fetch reported skipped" "$(echo "$o" | grep -o '"status":"skipped"' | head -1)" '"status":"skipped"'
check "--no-fetch: nothing fetched (tracking ref still absent)" "$(git -C app rev-parse -q --verify "refs/remotes/origin/$NF" >/dev/null && echo present || echo absent)" "absent"
o=$(run new --create zz-long --repo app --json); rc=$?
check "--create long form: exit 0" "$rc" "0"
check "--create long form: created" "$(echo "$o" | grep -o '"outcome":"created"')" '"outcome":"created"'
check "--create long form: source HEAD" "$(git -C app.zz-long rev-parse HEAD 2>/dev/null)" "$main_head"
check "--create long form: notOnRemote" "$(echo "$o" | grep -o '"status":"notOnRemote"')" '"status":"notOnRemote"'

# D23: unreachable origin refuses -c rather than creating with a fetch-failed note.
git -C app remote set-url origin https://invalid.invalid/none.git
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

# No origin: local names only, even with upstream configured.
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
check "main untouched" "$(git -C app status --porcelain | grep -v '^!!' | sort | tr '\n' ' ')" " M $first ?? untracked.txt "
echo "pass=$pass fail=$fail"
[ "$fail" = 0 ]
