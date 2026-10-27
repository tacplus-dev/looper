#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# repo-looper's outcome handling (what it does to an issue after the run ends),
# its checkpoints of work in progress, resuming from them, and the time limit.
# A stub `gh` keeps issues as JSON files, a stub `claude` runs the scenario's
# script in the checkout, and origin is a local bare repository.
# Run: tests/repo-looper.test.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

# Issues: $FIX/issues/<repo>-<n>.json ({number,state,labels:[{name}],body,createdAt}).
# Comments are appended to the issue's `comments` and to $FIX/comments as "<repo>#<n> <body>".
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cmd="$1 $2"; shift 2
case "$cmd" in
  "auth setup-git") exit 0 ;;
  "repo clone") git clone -q "$FIX/origin.git" "$2"; exit 0 ;;
esac
n=""; repo=""; q="."; add=(); rm=(); body=""; has_body=""; label=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) repo="${2##*/}"; shift 2 ;;
    --jq) q="$2"; shift 2 ;;
    --add-label) add+=("$2"); shift 2 ;;
    --remove-label) rm+=("$2"); shift 2 ;;
    --body) body="$2"; has_body=1; shift 2 ;;
    --label) label="$2"; shift 2 ;;
    --json|--state|--limit) shift 2 ;;
    *) n="$1"; shift ;;
  esac
done
f="$FIX/issues/$repo-$n.json"
case "$cmd" in
  "issue list")
    jq -s --arg l "$label" '[.[] | select(.state == "OPEN" and any(.labels[].name; . == $l))]' \
      "$FIX/issues/$repo"-*.json | jq -r "$q" ;;
  "issue view") [[ -f "$f" ]] || { echo "stub gh: no issue $repo#$n" >&2; exit 1; }; jq -r "$q" "$f" ;;
  "issue edit")
    t="$(cat "$f")"
    for l in "${add[@]+"${add[@]}"}"; do t="$(jq --arg l "$l" '.labels |= (. + [{name: $l}] | unique)' <<<"$t")"; done
    for l in "${rm[@]+"${rm[@]}"}"; do t="$(jq --arg l "$l" '.labels |= map(select(.name != $l))' <<<"$t")"; done
    [[ -n "$has_body" ]] && t="$(jq --arg b "$body" '.body = $b' <<<"$t")"
    printf '%s\n' "$t" > "$f" ;;
  "issue comment")
    t="$(jq --arg b "$body" '.comments += [{body: $b}]' "$f")"; printf '%s\n' "$t" > "$f"
    printf '%s#%s %s\n' "$repo" "$n" "$body" >> "$FIX/comments" ;;
  *) echo "stub gh: unexpected $cmd" >&2; exit 3 ;;
esac
EOF
# The prompt names the run's outcome file; the scenario's script gets it as $OUTCOME.
cat > "$TMP/bin/claude" <<'EOF'
#!/usr/bin/env bash
prompt="$(cat)"
OUTCOME="$(grep -oE '/[^ `]*/outcome' <<<"$prompt" | head -1)" bash "$FIX/claude.sh"
EOF
chmod +x "$TMP/bin/gh" "$TMP/bin/claude"

issue() { # repo n state labels(csv) body
  jq -n --argjson n "$2" --arg s "$3" --arg l "$4" --arg b "$5" \
    '{number: $n, state: $s, labels: ($l | split(",") | map(select(. != "")) | map({name: .})), body: $b, comments: [], createdAt: "2026-10-27T00:00:00Z"}' \
    > "$FIX/issues/$1-$2.json"
}
scenario() { # name: a fresh origin with one commit and an approved issue alpha#4
  NAME="$1"; FIX="$TMP/$1"; mkdir -p "$FIX/issues"; : > "$FIX/comments"; : > "$FIX/claude.sh"
  git init -q --bare -b main "$FIX/origin.git"
  git clone -q "$FIX/origin.git" "$FIX/seed" 2>/dev/null
  git -C "$FIX/seed" commit -q --allow-empty -m init && git -C "$FIX/seed" push -q origin main
  issue alpha 4 OPEN approved "Fix it."
}
push_fix() { # a claude.sh line: commit and push a fix
  echo 'git commit -q --allow-empty -m fix && git push -q origin main' >> "$FIX/claude.sh"
}
looper() { # [VAR=value...] -- repo-looper args
  local vars=(); while [[ "$1" != -- ]]; do vars+=("$1"); shift; done; shift
  env -u LOOPER_RUNNING_COPY -u LOOPER_SELF -u LOOPER_RUN -u LOOPER_TIMEOUT -u LOOPER_STOP_EARLY -u LOOPER_CHECKPOINT_INTERVAL \
      PATH="$TMP/bin:$PATH" FIX="$FIX" ROOT="$ROOT" LOOPER_LIB="$ROOT/looper-lib.sh" LOOPER_WORK="$FIX/work" \
      LOOPER_RUNS="$FIX/project/looper-runs" CI_PROJECT_DIR="$FIX/project" CI_JOB_URL=https://gl.test/jobs/77 \
      "${vars[@]+"${vars[@]}"}" "$ROOT/repo-looper" "$@"
}
run() { # [VAR=value...]: work alpha#4
  OUT="$(looper "$@" -- --repo alpha --issue 4 2>&1)" || { echo "$OUT"; fail "repo-looper exited non-zero"; }
}
# A claude.sh line: checkpoint the step, as the prompt tells the model to.
step() { echo "\"\$ROOT/repo-looper\" --repo alpha --issue 4 --checkpoint \"$1\"" >> "$FIX/claude.sh"; }
origin() { git -C "$FIX/origin.git" "$@"; }
branch() { origin rev-parse -q --verify refs/heads/looper/alpha-4 >/dev/null; }
main_unchanged() { [[ "$(origin rev-parse main)" == "$(git -C "$FIX/seed" rev-parse HEAD)" ]] || fail "main moved: $(origin log --oneline main)"; }
fail() { echo "FAIL $NAME: $*" >&2; cat "$FIX/comments" >&2; exit 1; }
labels() { jq -r '[.labels[].name] | join(",")' "$FIX/issues/$1-$2.json"; }
body() { jq -r .body "$FIX/issues/$1-$2.json"; }
has() { grep -qF -- "$2" <<<"$1" || fail "expected \"$2\" in: $1"; }
lacks() { ! grep -qF -- "$2" <<<"$1" || fail "unexpected \"$2\" in: $1"; }
pass() { echo "ok $NAME"; }

scenario pushed-gates-blocked
push_fix; echo 'echo "Blocked-by: tacplus-dev/tacplus#9" > "$OUTCOME"' >> "$FIX/claude.sh"
issue tacplus 9 OPEN "" "A compiler floor."
run
[[ "$(labels alpha 4)" == approved ]] || fail "labels $(labels alpha 4)"
has "$(body alpha 4)" "Blocked-by: tacplus-dev/tacplus#9"
has "$(body alpha 4)" "Fix it."
has "$(cat "$FIX/comments")" "https://gl.test/jobs/77"
lacks "$(cat "$FIX/comments")" "looper host"
pass

scenario pushed-gates-blocked-same-repo
push_fix; echo 'echo "Blocked-by: #3" > "$OUTCOME"' >> "$FIX/claude.sh"
issue alpha 3 OPEN "" "First."
run
[[ "$(labels alpha 4)" == approved ]] || fail "labels $(labels alpha 4)"
has "$(body alpha 4)" "Blocked-by: #3"
pass

scenario keeps-other-blockers
push_fix; echo 'echo "Blocked-by: #3" > "$OUTCOME"' >> "$FIX/claude.sh"
issue alpha 3 OPEN "" "First."
issue alpha 4 OPEN approved "Fix it.
Blocked-by: tacplus-dev/beta#1"
issue beta 1 CLOSED "" "Done."
run
[[ "$(labels alpha 4)" == approved ]] || fail "labels $(labels alpha 4)"
has "$(body alpha 4)" "Blocked-by: tacplus-dev/beta#1"
[[ "$(grep -c 'Blocked-by: #3' <<<"$(body alpha 4)")" == 1 ]] || fail "body $(body alpha 4)"
pass

scenario blocked-but-nothing-pushed
echo 'echo "Blocked-by: tacplus-dev/tacplus#9" > "$OUTCOME"' >> "$FIX/claude.sh"
issue tacplus 9 OPEN "" "A compiler floor."
run
[[ "$(labels alpha 4)" == "approved,looper:stuck" ]] || fail "labels $(labels alpha 4)"
lacks "$(body alpha 4)" "Blocked-by"
pass

scenario blocked-by-closed-issue
push_fix; echo 'echo "Blocked-by: tacplus-dev/tacplus#9" > "$OUTCOME"' >> "$FIX/claude.sh"
issue tacplus 9 CLOSED "" "A compiler floor."
run
[[ "$(labels alpha 4)" == "approved,looper:stuck" ]] || fail "labels $(labels alpha 4)"
lacks "$(body alpha 4)" "Blocked-by"
pass

scenario ended-unknown
push_fix
run
[[ "$(labels alpha 4)" == "approved,looper:stuck" ]] || fail "labels $(labels alpha 4)"
c="$(cat "$FIX/comments")"
has "$c" "https://gl.test/jobs/77"
has "$c" "looper-runs/"
lacks "$c" "looper host"
ls "$FIX"/project/looper-runs/*-issue-4/prompt.md "$FIX"/project/looper-runs/*-issue-4/claude.log >/dev/null \
  || fail "no run record under LOOPER_RUNS"
pass

scenario closed
push_fix; echo 'gh issue edit 4 --repo tacplus-dev/alpha --add-label closed-by-test' >> "$FIX/claude.sh"
echo 'jq ".state = \"CLOSED\"" "$FIX/issues/alpha-4.json" > "$FIX/x" && mv "$FIX/x" "$FIX/issues/alpha-4.json"' >> "$FIX/claude.sh"
run
[[ "$(labels alpha 4)" == "approved,closed-by-test" ]] || fail "labels $(labels alpha 4)"
[[ ! -s "$FIX/comments" ]] || fail "unexpected comment"
pass

# Checkpoint: the model's step pushes everything in the checkout, committed or
# not, to looper/alpha-4, never to main, and leaves the checkout as it was.
scenario checkpoint-step
echo 'git commit -q --allow-empty -m "local, not pushed" && echo one > a.txt' >> "$FIX/claude.sh"
step "a.txt written; left: b.txt"
echo 'git -C "$FIX/origin.git" log -1 --format=%B looper/alpha-4 > "$FIX/seen"' >> "$FIX/claude.sh"
echo 'git -C "$FIX/origin.git" ls-tree -r --name-only looper/alpha-4 >> "$FIX/seen"' >> "$FIX/claude.sh"
echo '{ git status --porcelain; git rev-parse --abbrev-ref HEAD; git log -1 --format=%s; } > "$FIX/checkout"' >> "$FIX/claude.sh"
run
has "$(cat "$FIX/seen")" "a.txt written; left: b.txt"
has "$(cat "$FIX/seen")" "a.txt"
[[ "$(cat "$FIX/checkout")" == $'?? a.txt\nmain\nlocal, not pushed' ]] || fail "checkout: $(cat "$FIX/checkout")"
has "$(cat "$FIX"/project/looper-runs/*-issue-4/prompt.md)" "--checkpoint"
main_unchanged
pass

scenario checkpoint-hourly
echo 'echo x > b.txt; sleep 3; git -C "$FIX/origin.git" log -1 --format=%B looper/alpha-4 > "$FIX/seen" 2>&1' >> "$FIX/claude.sh"
run LOOPER_CHECKPOINT_INTERVAL=1
has "$(cat "$FIX/seen")" "hourly"
main_unchanged
pass

# Nothing to keep (the fix is on main) pushes no branch.
scenario checkpoint-nothing
push_fix
run LOOPER_CHECKPOINT_INTERVAL=1
! branch || fail "a branch with nothing in it"
pass

# The time limit: the model is stopped LOOPER_STOP_EARLY seconds before it, its
# work is checkpointed, and the issue says what is done and what is left and
# stays approved, not stuck, for the next run to resume.
scenario timeout-outcome
echo 'echo y > c.txt' >> "$FIX/claude.sh"
step "c.txt written; left: the tests"
echo 'echo z > d.txt; sleep 30' >> "$FIX/claude.sh"
start=$SECONDS
run LOOPER_TIMEOUT=6 LOOPER_STOP_EARLY=3
(( SECONDS - start < 20 )) || fail "the model was not stopped"
[[ "$(labels alpha 4)" == approved ]] || fail "labels $(labels alpha 4)"
c="$(cat "$FIX/comments")"
has "$c" "time limit"
has "$c" "c.txt written; left: the tests"
has "$c" "https://github.com/tacplus-dev/alpha/tree/looper/alpha-4"
has "$c" "https://gl.test/jobs/77"
lacks "$c" "looper:stuck"
[[ "$(origin ls-tree -r --name-only looper/alpha-4 | tr '\n' ' ')" == "c.txt d.txt " ]] || fail "branch: $(origin ls-tree -r --name-only looper/alpha-4)"
main_unchanged
pass

# Timeout: <hours>h in the body sets the run's limit (at most 10h); the job's is an hour more.
scenario timeout-per-issue
[[ "$(looper -- --repo alpha --job-timeout 4)" == 5h ]] || fail "default job timeout"
issue alpha 4 OPEN approved "Fix it.
Timeout: 6h"
[[ "$(looper -- --repo alpha --job-timeout 4)" == 7h ]] || fail "job timeout for 6h"
push_fix
run
has "$(cat "$FIX"/project/looper-runs/*-issue-4/prompt.md)" "Your time limit is 6h"
issue alpha 4 OPEN approved "Timeout: 12h"
[[ "$(looper -- --repo alpha --job-timeout 4)" == 11h ]] || fail "job timeout for 12h"
issue alpha 4 OPEN approved "Timeout: 2h"
[[ "$(looper -- --repo alpha --job-timeout 4)" == 3h ]] || fail "job timeout for 2h"
pass

# Resume: the branch, rebased on main, is the run's uncommitted work on main;
# the prompt has its last checkpoint message and the issue's last comment. The
# branch is deleted once the work lands.
scenario resume
git -C "$FIX/seed" checkout -q -b looper/alpha-4
echo wip > "$FIX/seed/wip.txt"; git -C "$FIX/seed" add wip.txt
git -C "$FIX/seed" commit -q -m "looper: work in progress on #4" -m "wip.txt started; left: finish it"
git -C "$FIX/seed" push -q origin looper/alpha-4
git -C "$FIX/seed" checkout -q main; echo later > "$FIX/seed/later.txt"; git -C "$FIX/seed" add later.txt
git -C "$FIX/seed" commit -q -m later && git -C "$FIX/seed" push -q origin main
jq '.comments = [{body: "Ran out of time."}]' "$FIX/issues/alpha-4.json" > "$FIX/x" && mv "$FIX/x" "$FIX/issues/alpha-4.json"
echo '{ git rev-parse --abbrev-ref HEAD; [[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] && echo at-main; git status --porcelain; cat wip.txt later.txt; } > "$FIX/checkout"' >> "$FIX/claude.sh"
echo 'git add -A && git commit -q -m fix && git push -q origin main' >> "$FIX/claude.sh"
echo 'jq ".state = \"CLOSED\"" "$FIX/issues/alpha-4.json" > "$FIX/x" && mv "$FIX/x" "$FIX/issues/alpha-4.json"' >> "$FIX/claude.sh"
run
[[ "$(cat "$FIX/checkout")" == $'main\nat-main\n?? wip.txt\nwip\nlater' ]] || fail "checkout: $(cat "$FIX/checkout")"
p="$(cat "$FIX"/project/looper-runs/*-issue-4/prompt.md)"
has "$p" "looper/alpha-4"
has "$p" "wip.txt started; left: finish it"
has "$p" "Ran out of time."
! branch || fail "branch not deleted after the work landed"
[[ "$(origin show main:wip.txt)" == wip ]] || fail "work not on main"
pass

# A branch that does not rebase on main: the run starts from main and is told.
scenario resume-conflict
echo base > "$FIX/seed/f"; git -C "$FIX/seed" add f; git -C "$FIX/seed" commit -q -m f; git -C "$FIX/seed" push -q origin main
git -C "$FIX/seed" checkout -q -b looper/alpha-4; echo ours > "$FIX/seed/f"; git -C "$FIX/seed" commit -qam wip
git -C "$FIX/seed" push -q origin looper/alpha-4
git -C "$FIX/seed" checkout -q main; echo theirs > "$FIX/seed/f"; git -C "$FIX/seed" commit -qam theirs; git -C "$FIX/seed" push -q origin main
echo '{ git status --porcelain; cat f; } > "$FIX/checkout"' >> "$FIX/claude.sh"
run
[[ "$(cat "$FIX/checkout")" == theirs ]] || fail "checkout: $(cat "$FIX/checkout")"
has "$(cat "$FIX"/project/looper-runs/*-issue-4/prompt.md)" "does not rebase"
branch || fail "branch lost"
pass

echo "repo-looper: all scenarios pass"
