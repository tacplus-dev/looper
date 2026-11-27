#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# looper-check (looper#249): the rolling check of main and its fixed recovery.
# The scenarios the issue names, each from a fresh origin: green (main-green
# moves, and main unmoved builds nothing), a flake (run again, green, nothing
# reverted), one culprit (bisected, its revert green on the failed group and
# proposed, its issue ready again with the failure), no single culprit and a
# revert that conflicts (one "fix main" issue each, merging closed), a red no
# change caused (red on main-green too: nothing reverted, nothing frozen), a
# build with no verdict (nothing decided); what the merger reads (looper#251):
# the status looper/rolling-check on main's heads, red through the recovery,
# on each new head too, naming the recovery's own branch, and the gate it asks
# of a merge request: a reverted change refused until it comes back as a
# revert of the revert.
# A bare repository is the origin; a stub builder plays the gates (red when
# the tree has a file named broken*; $FIX/outside: red everywhere; a sha in
# $FIX/flaky: red once; $FIX/noverdict: no verdict); a stub gh plays GitHub's
# statuses, pull requests and issues, recording each write in $FIX/calls.
# Run: tests/looper-check.test.sh
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/hermetic.sh"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
mkdir -p "$TMP/bin"

# The stub builder, as looper-vm build is called: --repo --dir --sha --gates --log.
cat > "$TMP/bin/build" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
while (( $# )); do case "$1" in --dir) dir="$2" ;; --sha) sha="$2" ;; --gates) gates="$2" ;; --log) logf="$2" ;; esac; shift 2; done
[[ ! -e "$FIX/noverdict" ]] || { echo "build $sha $gates none" >> "$FIX/builds"; exit 3; }
v=pass
if [[ -e "$FIX/outside" ]] || git -C "$dir" ls-tree --name-only "$sha" | grep -q '^broken'; then v=fail; fi
if grep -qx "$sha" "$FIX/flaky" 2>/dev/null && ! grep -q "^build $sha " "$FIX/builds" 2>/dev/null; then v=fail; fi
echo "build $sha $gates $v" >> "$FIX/builds"
echo "the gates $gates of ${sha:0:7}: $v" > "$logf"
[[ "$v" == pass ]]
EOF
# The stub gh: the calls looper-check and looper-lib.sh make.
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
jqf=""; args=()
while (( $# )); do case "$1" in --jq) jqf="$2"; shift 2 ;; *) args+=("$1"); shift ;; esac; done
set -- "${args[@]}"
out() { if [[ -n "$jqf" ]]; then jq -r "$jqf"; else cat; fi; }
field() { local k="$1" a; shift; for a in "$@"; do [[ "$a" == "$k="* ]] && { echo "${a#*=}"; return; }; done; }
opt() { local k="$1" p=""; shift; for a in "$@"; do [[ "$p" == "$k" ]] && { echo "$a"; return; }; p="$a"; done; }
case "$1 $2" in
  "auth setup-git") exit 0 ;;
  "label list") echo '[]' | out ;;
  "label create") exit 0 ;;
  "api -X")
    path="$4"; [[ "$path" =~ statuses/([0-9a-f]{40})$ ]] || { echo "stub gh: $*" >&2; exit 1; }
    [[ ! -e "$FIX/no-post" ]] || { echo "stub gh: a status refused" >&2; exit 1; }
    n=$(( $(wc -l < "$FIX/statuses" 2>/dev/null || echo 0) + 1 ))
    jq -nc --arg sha "${BASH_REMATCH[1]}" --arg st "$(field state "$@")" --arg c "$(field context "$@")" --arg d "$(field description "$@")" \
      --arg login "${STUB_LOGIN:-looper-check[bot]}" --argjson n "$n" \
      '{sha: $sha, state: $st, context: $c, description: $d, id: $n, updated_at: (now | todate), creator: {login: $login}}' >> "$FIX/statuses"
    echo "status ${BASH_REMATCH[1]:0:7} $(field context "$@") $(field state "$@") $(field description "$@")" >> "$FIX/calls"; echo '{}' ;;
  api\ *)
    path="$2"
    if [[ "$path" =~ commits/([0-9a-f]{40})/statuses ]]; then
      jq -sc --arg s "${BASH_REMATCH[1]}" 'map(select(.sha == $s)) | sort_by(-.id)' "$FIX/statuses"
    elif [[ "$path" =~ commits/([0-9a-f]{40})/pulls ]]; then
      cat "$FIX/pulls-${BASH_REMATCH[1]}" 2>/dev/null || echo '[]'
    else echo "stub gh: $*" >&2; exit 1; fi | out ;;
  "pr list")
    h="$(opt --head "$@")"; grep -h "^pr " "$FIX/calls" 2>/dev/null | awk -v h="$h" '$3 == h { print $2 }' | jq -Rsc 'split("\n") | map(select(. != "") | {number: tonumber})' | out ;;
  "pr create")
    n=$(( 100 + $(grep -c '^pr ' "$FIX/calls" 2>/dev/null || true) ))
    echo "pr $n $(opt --head "$@") base=$(opt --base "$@") label=$(opt --label "$@") title=$(opt --title "$@")" >> "$FIX/calls"
    opt --body "$@" > "$FIX/pr-$n.body"
    echo "https://github.com/tacplus-dev/alpha/pull/$n" ;;
  "issue view")
    f="$FIX/issue-$3.json"; [[ -f "$f" ]] || { echo "no issue $3" >&2; exit 1; }; out < "$f" ;;
  "issue list")
    grep -h '^created ' "$FIX/calls" 2>/dev/null | while read -r _ n labels title; do
      grep -q "^closed $n$" "$FIX/calls" || jq -nc --argjson n "$n" --arg t "$title" --arg l "$labels" '{number: $n, title: $t, labels: ($l | split(",") | map({name: .}))}'
    done | jq -sc '.' | out ;;
  "issue create")
    n=$(( 200 + $(grep -c '^created ' "$FIX/calls" 2>/dev/null || true) ))
    ls=(); p=""; for a in "$@"; do [[ "$p" == --label ]] && ls+=("$a"); p="$a"; done
    l="$(IFS=,; echo "${ls[*]}")"
    echo "created $n $l $(opt --title "$@")" >> "$FIX/calls"; opt --body "$@" > "$FIX/issue-$n.body"
    echo "https://github.com/tacplus-dev/alpha/issues/$n" ;;
  "issue reopen") echo "reopen $3" >> "$FIX/calls" ;;
  "issue edit") echo "edit $3 ${*:6}" >> "$FIX/calls" ;;
  "issue comment") echo "comment $3" >> "$FIX/calls"; opt --body "$@" >> "$FIX/comment-$3" ;;
  *) echo "stub gh: unknown $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$TMP/bin/build" "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"

fail() { echo "FAIL $NAME: $*" >&2; for f in "$FIX/out" "$FIX/calls" "$FIX/builds"; do [[ -f "$f" ]] && { echo "--- $f" >&2; cat "$f" >&2; }; done; exit 1; }
pass() { echo "ok $NAME"; }
has() { grep -qF -- "$2" <<<"$1" || fail "expected \"$2\" in: $1"; }
hasnt() { ! grep -qF -- "$2" <<<"$1" || fail "did not expect \"$2\" in: $1"; }

# A fresh origin with main at one green commit (a gates.yaml whose full is 10
# minutes), and a work clone W to push merges from.
fixture() { # name
  NAME="$1"; FIX="$TMP/$1"; mkdir -p "$FIX"; : > "$FIX/calls"; : > "$FIX/builds"; : > "$FIX/statuses"
  git init -q --bare -b main "$FIX/origin.git"
  W="$FIX/work"; git init -q -b main "$W"
  printf 'full:\n  run: true\n  minutes: 10\n' > "$W/gates.yaml"; echo 0 > "$W/f"
  echo 'build_image: "ghcr.io/x/build@sha256:0"' > "$W/build.lock"
  git -C "$W" add -A; git -C "$W" commit -q -m "the first (#1)"
  git -C "$W" remote add origin "$FIX/origin.git"; git -C "$W" push -q origin main
}
# A commit on main, pushed: the file given created (or removed, -FILE), its subject given.
merge() { # subject file...
  local s="$1" f; shift
  for f in "$@"; do if [[ "$f" == -* ]]; then git -C "$W" rm -q "${f#-}"; else echo "$s" > "$W/$f"; git -C "$W" add "$f"; fi; done
  git -C "$W" commit -q -m "$s"; git -C "$W" push -q origin main
  git -C "$W" rev-parse HEAD
}
check() { # [once|gate ...] [VAR=value...] : looper-check's output in $FIX/out; its exit in RC
  local sub=once; case "${1:-}" in once) shift ;; gate|needed) sub="$1"; shift ;; loop) sub=""; shift ;; esac
  local a=() e=(); while (( $# )); do if [[ "$1" == *=* && "$1" != --* ]]; then e+=("$1"); else a+=("$1"); fi; shift; done
  RC=0
  env FIX="$FIX" LOOPER_CHECK_REMOTE="$FIX/origin.git" LOOPER_CHECK_DIR="$FIX/check" LOOPER_CHECK_BUILD="$TMP/bin/build" \
    LOOPER_CHECK_LOGIN="looper-check[bot]" \
    "${e[@]+"${e[@]}"}" "$ROOT/looper-check" ${sub:+"$sub"} --repo alpha "${a[@]+"${a[@]}"}" > "$FIX/out" 2>&1 || RC=$?
  OUT="$(cat "$FIX/out")"
}
green_ref() { git -C "$FIX/origin.git" rev-parse -q --verify refs/heads/main-green || true; }
main_ref() { git -C "$FIX/origin.git" rev-parse refs/heads/main; }
# The state the check published last, as the merger reads it: "sha7 state description".
state() { jq -sr 'map(select(.context == "looper/rolling-check")) | last | "\(.sha[:7]) \(.state) \(.description)"' "$FIX/statuses"; }
# An issue's JSON as gh issue view reads it.
issue() { # n state [label...]
  local n="$1" st="$2"; shift 2
  jq -nc --arg st "$st" '{state: $st, labels: ($ARGS.positional | map({name: .}))}' --args "$@" > "$FIX/issue-$n.json"
}

# --- green ------------------------------------------------------------------------
# main's head, built on the full gates, green: main-green moves to it, its
# verdict, open, is posted on it; main unmoved, the next pass builds nothing.
fixture green
c0="$(main_ref)"
check once
(( RC == 0 )) || fail "exit $RC"
[[ "$(green_ref)" == "$c0" ]] || fail "main-green is not main's head ${c0:0:7}"
has "$(cat "$FIX/builds")" "build $c0 full pass"
has "$(cat "$FIX/calls")" "status ${c0:0:7} looper/rolling-check pending checking ${c0:0:7}"
has "$(state)" "${c0:0:7} success open: green ${c0:0:7}"
check once
(( $(wc -l < "$FIX/builds") == 1 )) || fail "main unmoved, built again"
has "$OUT" "unmoved"
c1="$(merge "a change (#2)" a)"
check once
[[ "$(green_ref)" == "$c1" ]] || fail "main-green did not move on to ${c1:0:7}"
has "$(state)" "${c1:0:7} success open: green ${c1:0:7}"
pass

# --- a repository that pins no build image ------------------------------------------
# Nothing to build it in: not checked, no status, main-green not made.
fixture unpinned
git -C "$W" rm -q build.lock; git -C "$W" commit -q -m "no pin"; git -C "$W" push -q origin main
check once
(( RC == 0 )) || fail "exit $RC"
has "$OUT" "pins no build image"
[[ ! -s "$FIX/builds" && ! -s "$FIX/statuses" && -z "$(green_ref)" ]] || fail "an unpinned main built or marked"
check needed
(( RC == 1 )) || fail "an unpinned main needed a check: exit $RC: $OUT"
pass

# --- a flake ------------------------------------------------------------------------
# Red once, run again green: main-green moves, nothing reverted, nothing filed.
fixture flake
check once
c1="$(merge "a change (#3)" a)"; echo "$c1" > "$FIX/flaky"
check once
(( RC == 0 )) || fail "exit $RC"
[[ "$(green_ref)" == "$c1" ]] || fail "main-green did not move to the flake's ${c1:0:7}"
(( $(grep -c "^build $c1 full" "$FIX/builds") == 2 )) || fail "not run again exactly once"
has "$(state)" "${c1:0:7} success open: green ${c1:0:7} (a flake in full"
hasnt "$(cat "$FIX/calls")" "pr "
hasnt "$(cat "$FIX/calls")" "created "
has "$(cat "$FIX/check/alpha.flakes")" "${c1:0:7} full"
pass

# --- one culprit ---------------------------------------------------------------------
# Three merges since main-green, the second (a merge commit, its pull request's
# branch looper/alpha-7) red. Bisected to it; its revert on main's head green on
# the failed group: proposed as a pull request (looper:revert), its build
# statuses of the check's; merging closed but for that branch, on main's head
# and on the next head too; issue 7 reopened, approved, with the failure. The
# revert merged, the next check is green and merging reopens. A branch that
# still builds on the reverted merge is refused until it reverts the revert.
fixture culprit
g="$(main_ref)"; check once
m1="$(merge "first (#5)" a)"
git -C "$W" checkout -q -b looper/alpha-7; echo bad > "$W/broken"; git -C "$W" add broken; git -C "$W" commit -q -m "the bad change (7)"
p7="$(git -C "$W" rev-parse HEAD)"
git -C "$W" checkout -q main; git -C "$W" merge -q --no-ff -m "Merge pull request #50 from tacplus-dev/looper/alpha-7" looper/alpha-7
git -C "$W" push -q origin main; m2="$(git -C "$W" rev-parse HEAD)"
echo '[{"number": 50, "head": {"ref": "looper/alpha-7"}}]' > "$FIX/pulls-$m2"
m3="$(merge "third (#6)" b)"
issue 7 CLOSED
check once
(( RC == 1 )) || fail "a red handled exits 1, not $RC"
[[ "$(green_ref)" == "$g" ]] || fail "main-green moved on a red"
has "$(cat "$FIX/calls")" "status ${m3:0:7} looper/rolling-check failure red: full"
has "$(cat "$FIX/builds")" "build $g full pass"            # main-green itself, again: green, so a merge caused it
has "$(cat "$FIX/builds")" "build $m2 full fail"
has "$OUT" "the culprit: ${m2:0:7}"
rb="looper/revert-${m2:0:7}"
r="$(git -C "$FIX/origin.git" rev-parse "refs/heads/$rb")" || fail "no revert branch $rb"
[[ "$(git -C "$FIX/origin.git" rev-parse "$r^")" == "$m3" ]] || fail "the revert is not on main's head"
git -C "$FIX/origin.git" ls-tree --name-only "$r" | grep -q '^broken$' && fail "the revert still has the bad change"
git -C "$FIX/origin.git" log -1 --format=%B "$r" | grep -q "This reverts commit $m2" || fail "the revert does not say what it reverts"
has "$(cat "$FIX/builds")" "build $r full pass"
has "$(cat "$FIX/calls")" "status ${r:0:7} looper/gates success"
has "$(cat "$FIX/calls")" "status ${r:0:7} looper/rolling-check success"
has "$(cat "$FIX/calls")" "pr 100 $rb base=main label=looper:revert"
has "$(state)" "${m3:0:7} failure reverting ${m2:0:7}: allow $rb"
has "$(cat "$FIX/calls")" "reopen 7"
has "$(cat "$FIX/calls")" "edit 7 --add-label approved --remove-label looper:landing --remove-label looper:stuck"
c="$(cat "$FIX/comment-7")"
has "$c" "${m2:0:7}"; has "$c" "the gates full of ${m2:0:7}: fail"; has "$c" "revert of the revert"; has "$c" "#100"
check gate --branch "$rb" --sha "$r"
(( RC == 0 )) || fail "the revert refused by the gate: $OUT"
# Run again, main unmoved: nothing done twice.
check once
(( $(grep -c '^pr ' "$FIX/calls") == 1 )) || fail "the revert proposed twice"
# The revert merged: the new head is closed before it is built, its build
# green, merging reopens.
git -C "$W" fetch -q origin; git -C "$W" merge -q --ff-only "origin/$rb"; git -C "$W" push -q origin main
check once
(( RC == 0 )) || fail "the reverted main not green: $OUT"
[[ "$(green_ref)" == "$r" ]] || fail "main-green not the revert"
has "$(cat "$FIX/calls")" "status ${r:0:7} looper/rolling-check failure reverting ${m2:0:7}: allow $rb"
hasnt "$(cat "$FIX/calls")" "status ${r:0:7} looper/rolling-check pending"
has "$(state)" "${r:0:7} success open: green ${r:0:7}"
# The reverted change's branch, as it was plus a fix, still builds on its reverted commit: refused.
git -C "$W" checkout -q looper/alpha-7; echo fixed > "$W/c"; git -C "$W" add c; git -C "$W" commit -q -m "a fix"; git -C "$W" push -q origin looper/alpha-7
check gate --branch looper/alpha-7 --sha "$(git -C "$W" rev-parse HEAD)"
(( RC == 1 )) || fail "the reverted change merged again unchanged: $OUT"
has "$OUT" "revert of the revert"
# Its work back as a revert of the revert, on main-green: open.
git -C "$W" checkout -q -B looper/alpha-7 "origin/main"; git -C "$W" fetch -q origin; git -C "$W" reset -q --hard origin/main
git -C "$W" revert --no-edit "$r" >/dev/null; git -C "$W" rm -q broken; git -C "$W" commit -q -m "the change, fixed (7)"
git -C "$W" push -q -f origin looper/alpha-7
check gate --branch looper/alpha-7 --sha "$(git -C "$W" rev-parse HEAD)"
(( RC == 0 )) || fail "a revert of the revert refused: $OUT"
pass

# --- no single culprit ------------------------------------------------------------------
# Two merges each red: bisected to the first, whose revert is still red on the
# failed group. No revert: one "fix main" issue (bug, approved, priority:high),
# merging closed but for its branch; a second red files no second issue.
fixture no-culprit
g="$(main_ref)"; check once
m1="$(merge "one (#11)" broken-1)"
m2="$(merge "two (#12)" broken-2)"
check once
(( RC == 1 )) || fail "exit $RC"
has "$OUT" "the culprit: ${m1:0:7}"
hasnt "$(cat "$FIX/calls")" "pr "
has "$(cat "$FIX/calls")" "created 200 bug,approved,priority:high,looper:main-check fix main:"
b="$(cat "$FIX/issue-200.body")"
has "$b" "${m1:0:7}"; has "$b" "${m2:0:7}"; has "$b" "still red with ${m1:0:7}, the first red merge, reverted"
has "$(state)" "${m2:0:7} failure fix-main #200: allow looper/alpha-200"
m3="$(merge "three (#13)" c)"
check once
(( $(grep -c '^created ' "$FIX/calls") == 1 )) || fail "a second fix main issue"
has "$(cat "$FIX/calls")" "comment 200"
[[ "$(green_ref)" == "$g" ]] || fail "main-green moved"
has "$(state)" "${m3:0:7} failure fix-main #200: allow looper/alpha-200"
pass

# --- a revert that conflicts -------------------------------------------------------------
# The culprit's revert does not apply to main's head (a later merge changed its
# lines): no revert, one "fix main" issue.
fixture conflict
check once
m1="$(merge "bad (#21)" broken f)"
m2="$(merge "on top (#22)" f)"
check once
(( RC == 1 )) || fail "exit $RC"
has "$OUT" "the culprit: ${m1:0:7}"
hasnt "$(cat "$FIX/calls")" "pr "
has "$(cat "$FIX/calls")" "fix main:"
has "$(cat "$FIX/issue-200.body")" "does not apply to main"
has "$(state)" "${m2:0:7} failure fix-main #200"
pass

# --- a red no change caused ----------------------------------------------------------------
# Red on main-green too (an image re-pin's findings): nothing reverted, nothing
# frozen; one issue; main-green moves on so the bound does not freeze merging.
fixture outside
g="$(main_ref)"; check once
m1="$(merge "fine (#31)" a)"
: > "$FIX/outside"
check once
(( RC == 1 )) || fail "exit $RC"
has "$(cat "$FIX/builds")" "build $g full fail"
hasnt "$(cat "$FIX/calls")" "pr "
hasnt "$(cat "$FIX/calls")" "fix main:"
has "$(cat "$FIX/calls")" "created 200 bug,approved,priority:high,looper:main-check main is red, no change caused it:"
[[ "$(green_ref)" == "$m1" ]] || fail "main-green did not move on"
has "$(state)" "${m1:0:7} success outside #200"
pass

# --- no verdict ------------------------------------------------------------------------------
# A build with no verdict decides nothing: no status but checking, main-green
# kept, and the next pass builds again.
fixture noverdict
g="$(main_ref)"; check once
m1="$(merge "a change (#41)" a)"
: > "$FIX/noverdict"
check once
(( RC == 2 )) || fail "no verdict exits 2, not $RC"
[[ "$(green_ref)" == "$g" ]] || fail "main-green moved"
hasnt "$(cat "$FIX/calls")" "status ${m1:0:7} looper/rolling-check success"
hasnt "$(cat "$FIX/calls")" "status ${m1:0:7} looper/rolling-check failure"
rm "$FIX/noverdict"
check once
[[ "$(green_ref)" == "$m1" ]] || fail "not built again"
pass

# --- the gate's bound (looper#251: the merger asks it of each clean merge) ------------------
# Closed with no main-green, main-green off main's first-parent line, or no
# state of the check by its login; open while it is green or checking, at most
# 3 merges unchecked and the oldest younger than one gate's age (full's
# minutes in main's gates.yaml); closed at 4, or older; red, open for the
# recovery's own branch alone, past the bound too.
fixture gate-bound
h="$(main_ref)"
check gate --branch looper/alpha-1 --sha "$h"
(( RC == 1 )) || fail "open with no main-green: $OUT"
has "$OUT" "closed: alpha has no main-green: the rolling check is down or has never run"
check once
check gate --branch looper/alpha-1 --sha "$h" --dir "$FIX/merger-clone"
(( RC == 0 )) || fail "closed on a green main: $OUT"
has "$OUT" "open: 0 merge(s) unchecked (at most 4), the check's state: open: green ${h:0:7}"
[[ -d "$FIX/merger-clone/.git" ]] || fail "the gate did not clone into --dir"
check gate --branch looper/alpha-1 --sha "$h" LOOPER_CHECK_LOGIN="tacplus-looper[bot]"
(( RC == 1 )) || fail "a state by another login counted: $OUT"
has "$OUT" "no looper/rolling-check status by tacplus-looper[bot] on main since main-green"
m1="$(merge "one (#71)" a)"; m2="$(merge "two (#72)" b)"; m3="$(merge "three (#73)" c)"
check gate --branch looper/alpha-1 --sha "$h"
(( RC == 0 )) || fail "closed at 3 unchecked: $OUT"
has "$OUT" "open: 3 merge(s) unchecked (at most 4), the check's state: open: green ${h:0:7}"
m4="$(merge "four (#74)" d)"
check gate --branch looper/alpha-1 --sha "$h"
(( RC == 1 )) || fail "open at 4 unchecked: $OUT"
has "$OUT" "closed: 4 merges on main are unchecked (at most 4)"
check gate --branch looper/alpha-1 --sha "$h" LOOPER_CHECK_MAX_UNCHECKED=5
(( RC == 0 )) || fail "LOOPER_CHECK_MAX_UNCHECKED not read: $OUT"
# One gate's age: full's 10 minutes in main's gates.yaml.
pass
fixture gate-age
check once
m1="$(GIT_COMMITTER_DATE="$(date -d '-11 minutes' -R)" merge "old (#75)" a)"
check gate --branch looper/alpha-1 --sha "$m1"
(( RC == 1 )) || fail "open with the oldest unchecked merge 11m old: $OUT"
has "$OUT" "closed: main's oldest unchecked merge, ${m1:0:7}, is 11m old (one gate's age, 10m)"
check gate --branch looper/alpha-1 --sha "$m1" LOOPER_CHECK_MAX_AGE=20
(( RC == 0 )) || fail "LOOPER_CHECK_MAX_AGE not read: $OUT"
# Checking (pending) holds nothing; red holds all but the branch it allows.
pass
fixture gate-red
check once
m1="$(merge "bad (#76)" broken)"
FIX="$FIX" STUB_LOGIN="looper-check[bot]" gh api -X POST "repos/x/alpha/statuses/$m1" -f state=pending -f context=looper/rolling-check -f "description=checking ${m1:0:7}" >/dev/null
check gate --branch looper/alpha-1 --sha "$m1"
(( RC == 0 )) || fail "closed while checking: $OUT"
has "$OUT" "the check's state: checking ${m1:0:7}"
check once
check gate --branch looper/alpha-1 --sha "$(main_ref)"
(( RC == 1 )) || fail "open while red: $OUT"
has "$OUT" "closed: the rolling check is red on ${m1:0:7} (reverting ${m1:0:7}: allow looper/revert-${m1:0:7}): merging reopens with its next green check"
r="$(git -C "$FIX/origin.git" rev-parse "refs/heads/looper/revert-${m1:0:7}")"
check gate --branch "looper/revert-${m1:0:7}" --sha "$r" LOOPER_CHECK_MAX_UNCHECKED=1
(( RC == 0 )) || fail "the recovery's own branch held: $OUT"
has "$OUT" "open: the recovery's own branch, while the check is red (reverting ${m1:0:7}"
# main-green off main's first-parent line: the check is down.
pass
fixture gate-offline
check once
git -C "$W" checkout -q -b side; echo s > "$W/s"; git -C "$W" add s; git -C "$W" commit -q -m "side"
s1="$(git -C "$W" rev-parse HEAD)"; git -C "$W" checkout -q main
git -C "$W" merge -q --no-ff -m "Merge side" side; git -C "$W" push -q origin main
git -C "$W" push -q -f origin "$s1:refs/heads/main-green"
check gate --branch looper/alpha-1 --sha "$s1"
(( RC == 1 )) || fail "open with main-green off main's first-parent line: $OUT"
has "$OUT" "closed: main-green ${s1:0:7} is not on main's first-parent line: the rolling check is down"
pass

# --- a machine only while there is something to check (cloud#111) ----------------------------
# `needed`, the orchestrator's question (the merger's always-on machine, which
# starts the check's): main's head with no verdict of the check yet (none, or
# pending) needs one. `--until-idle`, the check machine's: the check back to
# back, ending once main is unmoved, a verdict GitHub refused posted again first.
fixture idle
check needed
(( RC == 0 )) || fail "main unchecked, not needed: exit $RC: $OUT"
check once
check needed
(( RC == 1 )) || fail "main checked green, still needed: exit $RC: $OUT"
m1="$(merge "a change (#61)" a)"
check needed
(( RC == 0 )) || fail "main moved, not needed: exit $RC: $OUT"
check loop --until-idle LOOPER_CHECK_POLL=0
(( RC == 0 )) || fail "--until-idle: exit $RC: $OUT"
[[ "$(green_ref)" == "$m1" ]] || fail "--until-idle did not check main's head"
has "$OUT" "nothing to check"
check needed
(( RC == 1 )) || fail "checked, still needed: exit $RC: $OUT"
# A verdict GitHub refused: needed still; the idle check posts it again, building nothing.
m2="$(merge "another (#62)" b)"
: > "$FIX/no-post"; check once; rm "$FIX/no-post"
check needed
(( RC == 0 )) || fail "a verdict never posted, not needed: exit $RC"
n="$(wc -l < "$FIX/builds")"
check loop --until-idle LOOPER_CHECK_POLL=0
(( RC == 0 && $(wc -l < "$FIX/builds") == n )) || fail "the idle check built again or failed: exit $RC: $OUT"
has "$(state)" "${m2:0:7} success open: green ${m2:0:7}"
check needed
(( RC == 1 )) || fail "the verdict posted again, still needed: exit $RC"
pass
