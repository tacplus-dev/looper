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

# Issues: $FIX/issues/<repo>-<n>.json ({number,title,state,labels:[{name}],body,createdAt}).
# Comments are appended to the issue's `comments` and to $FIX/comments as "<repo>#<n> <body>".
# `gh api .../templates/repo/<file>` answers from $FIX/templates/<file>, and
# `gh api .../roadmap/contents/ROADMAP.md` from $FIX/platform/ROADMAP.md, else 404.
# `gh label create` is recorded in $FIX/labels-created as "<repo> <label>".
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cmd="$1 $2"; shift 2
case "$cmd" in
  "auth setup-git") exit 0 ;;
  "repo clone") git clone -q "$FIX/origin.git" "$2"; exit 0 ;;
  api\ */templates/repo/*) t="$FIX/templates/${cmd##*/}"; [[ -f "$t" ]] || { echo "stub gh: HTTP 404" >&2; exit 1; }; cat "$t"; exit 0 ;;
  "api repos/tacplus-dev/roadmap/contents/ROADMAP.md") [[ -f "$FIX/platform/ROADMAP.md" ]] || { echo "stub gh: HTTP 404" >&2; exit 1; }; cat "$FIX/platform/ROADMAP.md"; exit 0 ;;
esac
n=""; repo=""; q="."; add=(); rm=(); body=""; has_body=""; labels=(); state=open; title=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) repo="${2##*/}"; shift 2 ;;
    --jq) q="$2"; shift 2 ;;
    --add-label) add+=("$2"); shift 2 ;;
    --remove-label) rm+=("$2"); shift 2 ;;
    --body) body="$2"; has_body=1; shift 2 ;;
    --label) IFS=, read -ra l <<<"$2"; labels+=("${l[@]}"); shift 2 ;;
    --state) state="$2"; shift 2 ;;
    --title) title="$2"; shift 2 ;;
    --json|--limit|--color|--description) shift 2 ;;
    *) n="$1"; shift ;;
  esac
done
f="$FIX/issues/$repo-$n.json"
case "$cmd" in
  "label create") echo "$repo $n" >> "$FIX/labels-created" ;;
  "issue list")
    jq -s --arg s "$state" '[.[] | select(($s == "all" or .state == ($s | ascii_upcase)) and ([.labels[].name] | contains($ARGS.positional)))] | sort_by(-.number)' \
      "$FIX/issues/$repo"-*.json --args "${labels[@]+"${labels[@]}"}" | jq -r "$q" ;;
  "issue create")
    n="$(( $(jq -s 'map(.number) | max // 0' "$FIX/issues/$repo"-*.json) + 1 ))"
    jq -n --argjson n "$n" --arg t "$title" --arg b "$body" \
      '{number: $n, title: $t, state: "OPEN", labels: ($ARGS.positional | map({name: .})), body: $b, comments: [], createdAt: "2026-10-28T00:00:00Z"}' \
      --args "${labels[@]+"${labels[@]}"}" > "$FIX/issues/$repo-$n.json"
    echo "https://github.com/tacplus-dev/$repo/issues/$n" ;;
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
# The scenario's script for the prompt's role: $FIX/claude.sh works the issue,
# classify.sh classifies it, propose.sh proposes a design, scan.sh is the
# nightly scan, plan.sh the parent's plan (none: the model does nothing). Each prompt's first line is
# appended to $FIX/prompts. The prompt names the run's outcome file; the
# script gets it as $OUTCOME, the issue it works as $ISSUE, and the plan's
# areas file as $AREAS.
cat > "$TMP/bin/claude" <<'EOF'
#!/usr/bin/env bash
prompt="$(cat)"; first="$(head -n 1 <<<"$prompt")"
printf '%s\n' "$first" >> "$FIX/prompts"
case "$first" in
  *classifying*) s=classify.sh ;; *"proposing a design"*) s=propose.sh ;; *scanner*) s=scan.sh ;; *"parent looper"*) s=plan.sh ;; *) s=claude.sh ;;
esac
[[ -f "$FIX/$s" ]] || exit 0
ISSUE="$(grep -oE 'issue #[0-9]+' <<<"$first" | head -1 | tr -dc 0-9)" AREAS="$(grep -oE '/[^ `]*/areas' <<<"$prompt" | head -1)" \
OUTCOME="$(grep -oE '/[^ `]*/outcome' <<<"$prompt" | head -1)" bash "$FIX/$s"
EOF
# GitLab's jobs API: $FIX/jobs.json ([{name,status,id}]) filtered by the URL's
# scope[] parameters, as GitLab does; one job by its id (/projects/:id/jobs/:id),
# or this job, CI_JOB_ID, for its own token (/job). $FIX/revoked refuses the
# job's token (HTTP 401), as GitLab does once the job ended; no file answers
# HTTP 500. With -f a failure exits 22; -w prints the HTTP status. Each
# request's auth header and URL are appended to $FIX/gitlab.
cat > "$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
url=""; auth=""; out=""; w=""; f=""
while [[ $# -gt 0 ]]; do case "$1" in
  -H) auth="${2%%:*}"; shift 2 ;; -o) out="$2"; shift 2 ;; -w) w="$2"; shift 2 ;; --retry) shift 2 ;;
  http*) url="$1"; shift ;; -*f*) f=1; shift ;; *) shift ;;
esac; done
echo "$auth $url" >> "$FIX/gitlab"
reply() { # code body
  if [[ -n "$out" ]]; then printf '%s\n' "$2" > "$out"; else printf '%s\n' "$2"; fi
  [[ "$1" == 200 || -z "$f" ]] || { echo "curl: (22) The requested URL returned error: $1" >&2; exit 22; }
  [[ -z "$w" ]] || printf '%s' "$1"
}
if [[ "$auth" == JOB-TOKEN && -e "$FIX/revoked" ]]; then reply 401 '{"message":"401 Unauthorized"}'; exit 0; fi
[[ -f "$FIX/jobs.json" ]] || { reply 500 '{"message":"500 Internal Server Error"}'; exit 0; }
case "$url" in
  */jobs\?*) reply 200 "$(jq --arg s "$(grep -oE 'scope\[\]=[a-z_]+' <<<"$url" | cut -d= -f2 | paste -sd, -)" '[.[] | select(.status | IN($s | split(",")[]))]' "$FIX/jobs.json")" ;;
  */jobs/*|*/job)
    id="${url##*/jobs/}"; [[ "$url" == */job ]] && id="${CI_JOB_ID:-}"
    j="$(jq --arg id "$id" '.[] | select((.id | tostring) == $id)' "$FIX/jobs.json")"
    if [[ -n "$j" ]]; then reply 200 "$j"; else reply 404 '{"message":"404 Not found"}'; fi ;;
  *) reply 404 '{"message":"404 Not found"}' ;;
esac
EOF
chmod +x "$TMP/bin/gh" "$TMP/bin/claude" "$TMP/bin/curl"

issue() { # repo n state labels(csv) body
  jq -n --argjson n "$2" --arg s "$3" --arg l "$4" --arg b "$5" \
    '{number: $n, title: "Issue \($n)", state: $s, labels: ($l | split(",") | map(select(. != "")) | map({name: .})), body: $b, comments: [], createdAt: "2026-10-27T00:00:00Z"}' \
    > "$FIX/issues/$1-$2.json"
}
scenario() { # name: a fresh origin with one commit and an approved issue alpha#4
  NAME="$1"; FIX="$TMP/$1"; mkdir -p "$FIX/issues"; : > "$FIX/comments"; : > "$FIX/claude.sh"; : > "$FIX/prompts"
  git init -q --bare -b main "$FIX/origin.git"
  git clone -q "$FIX/origin.git" "$FIX/seed" 2>/dev/null
  git -C "$FIX/seed" commit -q --allow-empty -m init && git -C "$FIX/seed" push -q origin main
  issue alpha 4 OPEN approved,bug "Fix it."
}
LAND='"$ROOT/repo-looper" --repo alpha --issue "$ISSUE" --land --gates true'   # a claude.sh command: land the commits (looper#32)
push_fix() { # a claude.sh line: commit and land a fix
  echo "git commit -q --allow-empty -m fix && $LAND" >> "$FIX/claude.sh"
}
looper() { # [VAR=value...] -- repo-looper args
  local vars=(); while [[ "$1" != -- ]]; do vars+=("$1"); shift; done; shift
  env -u LOOPER_RUNNING_COPY -u LOOPER_SELF -u LOOPER_RUN -u LOOPER_TIMEOUT -u LOOPER_STOP_EARLY -u LOOPER_CHECKPOINT_INTERVAL \
      -u LOOPER_IDLE_MINUTES -u LOOPER_DONE_GRACE -u LOOPER_WATCH_INTERVAL \
      -u CI_API_V4_URL -u CI_PROJECT_ID -u CI_JOB_TOKEN -u GITLAB_TOKEN -u CI_JOB_TIMEOUT -u CI_JOB_STARTED_AT \
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
[[ "$(labels alpha 4)" == approved,bug ]] || fail "labels $(labels alpha 4)"
has "$(body alpha 4)" "Blocked-by: tacplus-dev/tacplus#9"
has "$(body alpha 4)" "Fix it."
has "$(cat "$FIX/comments")" "https://gl.test/jobs/77"
lacks "$(cat "$FIX/comments")" "looper host"
pass

scenario pushed-gates-blocked-same-repo
push_fix; echo 'echo "Blocked-by: #3" > "$OUTCOME"' >> "$FIX/claude.sh"
issue alpha 3 OPEN "" "First."
run
[[ "$(labels alpha 4)" == approved,bug ]] || fail "labels $(labels alpha 4)"
has "$(body alpha 4)" "Blocked-by: #3"
pass

scenario keeps-other-blockers
push_fix; echo 'echo "Blocked-by: #3" > "$OUTCOME"' >> "$FIX/claude.sh"
issue alpha 3 OPEN "" "First."
issue alpha 4 OPEN approved,bug "Fix it.
Blocked-by: tacplus-dev/beta#1"
issue beta 1 CLOSED "" "Done."
run
[[ "$(labels alpha 4)" == approved,bug ]] || fail "labels $(labels alpha 4)"
has "$(body alpha 4)" "Blocked-by: tacplus-dev/beta#1"
[[ "$(grep -c 'Blocked-by: #3' <<<"$(body alpha 4)")" == 1 ]] || fail "body $(body alpha 4)"
pass

# A run that rightly changes nothing because the issue waits on another one
# (looper#22): the same outcome, no push, and the issue is blocked, not stuck.
scenario blocked-nothing-pushed
echo 'echo "Blocked-by: tacplus-dev/tacplus#9" > "$OUTCOME"' >> "$FIX/claude.sh"
issue tacplus 9 OPEN "" "A compiler floor."
run
main_unchanged
[[ "$(labels alpha 4)" == approved,bug ]] || fail "labels $(labels alpha 4)"
has "$(body alpha 4)" "Blocked-by: tacplus-dev/tacplus#9"
has "$(body alpha 4)" "Fix it."
has "$(cat "$FIX/comments")" "Nothing was pushed"
has "$(cat "$FIX/comments")" "https://gl.test/jobs/77"
lacks "$(cat "$FIX/comments")" "Marked looper:stuck"
pass

scenario blocked-nothing-pushed-two-blockers
printf '%s\n' 'printf "Blocked-by: #3\nBlocked-by: tacplus-dev/tacplus#9\n" > "$OUTCOME"' >> "$FIX/claude.sh"
issue alpha 3 OPEN "" "Part 1."
issue tacplus 9 OPEN "" "Part 2."
run
main_unchanged
[[ "$(labels alpha 4)" == approved,bug ]] || fail "labels $(labels alpha 4)"
has "$(body alpha 4)" "Blocked-by: #3"
has "$(body alpha 4)" "Blocked-by: tacplus-dev/tacplus#9"
has "$(cat "$FIX/comments")" "Blocked-by: #3"
has "$(cat "$FIX/comments")" "Blocked-by: tacplus-dev/tacplus#9"
pass

scenario blocked-nothing-pushed-by-closed-issue
echo 'echo "Blocked-by: tacplus-dev/tacplus#9" > "$OUTCOME"' >> "$FIX/claude.sh"
issue tacplus 9 CLOSED "" "A compiler floor."
run
[[ "$(labels alpha 4)" == "approved,bug,looper:stuck" ]] || fail "labels $(labels alpha 4)"
lacks "$(body alpha 4)" "Blocked-by"
pass

scenario blocked-nothing-pushed-by-itself
echo 'echo "Blocked-by: #4" > "$OUTCOME"' >> "$FIX/claude.sh"
run
[[ "$(labels alpha 4)" == "approved,bug,looper:stuck" ]] || fail "labels $(labels alpha 4)"
lacks "$(body alpha 4)" "Blocked-by"
pass

scenario blocked-by-missing-issue
echo 'echo "Blocked-by: tacplus-dev/tacplus#9" > "$OUTCOME"' >> "$FIX/claude.sh"
run
[[ "$(labels alpha 4)" == "approved,bug,looper:stuck" ]] || fail "labels $(labels alpha 4)"
lacks "$(body alpha 4)" "Blocked-by"
pass

# One bad blocker among good ones rejects the outcome: none of it is added.
scenario blocked-one-closed-of-two
printf '%s\n' 'printf "Blocked-by: #3\nBlocked-by: tacplus-dev/tacplus#9\n" > "$OUTCOME"' >> "$FIX/claude.sh"
issue alpha 3 OPEN "" "Part 1."
issue tacplus 9 CLOSED "" "Part 2."
run
[[ "$(labels alpha 4)" == "approved,bug,looper:stuck" ]] || fail "labels $(labels alpha 4)"
lacks "$(body alpha 4)" "Blocked-by"
pass

scenario blocked-by-closed-issue
push_fix; echo 'echo "Blocked-by: tacplus-dev/tacplus#9" > "$OUTCOME"' >> "$FIX/claude.sh"
issue tacplus 9 CLOSED "" "A compiler floor."
run
[[ "$(labels alpha 4)" == "approved,bug,looper:stuck" ]] || fail "labels $(labels alpha 4)"
lacks "$(body alpha 4)" "Blocked-by"
pass

scenario ended-unknown
run
[[ "$(labels alpha 4)" == "approved,bug,looper:stuck" ]] || fail "labels $(labels alpha 4)"
c="$(cat "$FIX/comments")"
has "$c" "https://gl.test/jobs/77"
has "$c" "looper-runs/"
lacks "$c" "looper host"
ls "$FIX"/project/looper-runs/*-issue-4/prompt.md "$FIX"/project/looper-runs/*-issue-4/claude.log >/dev/null \
  || fail "no run record under LOOPER_RUNS"
pass

# A run that ends early with progress (looper#34): a checkpointed step, or a
# fix landed, is resumable, not for a person. The same step again, with nothing
# landed, is no progress: that one is stuck.
scenario ended-resumable
echo 'echo x > a.txt' >> "$FIX/claude.sh"
step "a.txt written; left: the tests"
run
[[ "$(labels alpha 4)" == approved,bug ]] || fail "labels $(labels alpha 4)"
c="$(cat "$FIX/comments")"
has "$c" "a.txt written; left: the tests"; has "$c" "the next run resumes"
lacks "$c" "looper:stuck"
has "$OUT" "#4: ended"
branch || fail "no branch to resume from"
: > "$FIX/comments"
run
[[ "$(labels alpha 4)" == "approved,bug,looper:stuck" ]] || fail "no progress, yet labels $(labels alpha 4)"
has "$(cat "$FIX/comments")" "no progress"
pass

scenario ended-landed
push_fix
run
[[ "$(labels alpha 4)" == approved,bug ]] || fail "labels $(labels alpha 4)"
has "$(cat "$FIX/comments")" "the next run resumes"
lacks "$(cat "$FIX/comments")" "looper:stuck"
pass

scenario closed
push_fix; echo 'gh issue edit 4 --repo tacplus-dev/alpha --add-label closed-by-test' >> "$FIX/claude.sh"
echo 'jq ".state = \"CLOSED\"" "$FIX/issues/alpha-4.json" > "$FIX/x" && mv "$FIX/x" "$FIX/issues/alpha-4.json"' >> "$FIX/claude.sh"
run
[[ "$(labels alpha 4)" == "approved,bug,closed-by-test" ]] || fail "labels $(labels alpha 4)"
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
[[ "$(cat "$FIX/checkout")" == $'?? a.txt\nlooper/alpha-4\nlocal, not pushed' ]] || fail "checkout: $(cat "$FIX/checkout")"
has "$(cat "$FIX"/project/looper-runs/*-issue-4/prompt.md)" "--checkpoint"
main_unchanged
pass

scenario checkpoint-hourly
echo 'echo x > b.txt; sleep 3; git -C "$FIX/origin.git" log -1 --format=%B looper/alpha-4 > "$FIX/seen" 2>&1' >> "$FIX/claude.sh"
run LOOPER_CHECKPOINT_INTERVAL=1
has "$(cat "$FIX/seen")" "hourly"
main_unchanged
pass

# No work to keep (the fix is on main): the branch holds only the run's record.
scenario checkpoint-nothing
push_fix
run LOOPER_CHECKPOINT_INTERVAL=1
[[ "$(origin ls-tree -r --name-only looper/alpha-4 | tr '\n' ' ')" == ".looper/claude.log .looper/prompt.md " ]] \
  || fail "branch: $(origin ls-tree -r --name-only looper/alpha-4)"
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
[[ "$(labels alpha 4)" == approved,bug ]] || fail "labels $(labels alpha 4)"
c="$(cat "$FIX/comments")"
has "$c" "time limit"
has "$c" "c.txt written; left: the tests"
has "$c" "https://github.com/tacplus-dev/alpha/tree/looper/alpha-4"
has "$c" "https://gl.test/jobs/77"
lacks "$c" "looper:stuck"
[[ "$(origin ls-tree -r --name-only looper/alpha-4 | tr '\n' ' ')" == ".looper/claude.log .looper/prompt.md c.txt d.txt " ]] || fail "branch: $(origin ls-tree -r --name-only looper/alpha-4)"
main_unchanged
pass

# Timeout: <hours>h in the body sets the run's limit (at most 10h). The job's
# is sized for the plan (looper#33): the longest limit of its issue and the
# ready issues that could run beside it, plus the plan's 20 minutes and an
# hour, rounded up, at most 11h.
scenario timeout-per-issue
[[ "$(looper -- --repo alpha --job-timeout 4)" == 6h ]] || fail "default job timeout"
issue alpha 4 OPEN approved,bug "Fix it.
Timeout: 6h"
[[ "$(looper -- --repo alpha --job-timeout 4)" == 8h ]] || fail "job timeout for 6h"
push_fix
run
has "$(cat "$FIX"/project/looper-runs/*-issue-4/prompt.md)" "Your time limit is 6h"
issue alpha 4 OPEN approved,bug "Timeout: 12h"
[[ "$(looper -- --repo alpha --job-timeout 4)" == 11h ]] || fail "job timeout for 12h"
issue alpha 4 OPEN approved,bug "Timeout: 2h"
[[ "$(looper -- --repo alpha --job-timeout 4)" == 4h ]] || fail "job timeout for 2h"
# A ready issue that could run beside it sizes the job too; a blocked one does not.
issue alpha 5 OPEN approved,bug "Timeout: 7h"
[[ "$(looper -- --repo alpha --job-timeout 4)" == 9h ]] || fail "job timeout for a 7h issue beside it"
issue alpha 5 OPEN approved,bug "Timeout: 7h
Blocked-by: #9"; issue alpha 9 OPEN bug "Later."
[[ "$(looper -- --repo alpha --job-timeout 4)" == 4h ]] || fail "job timeout with a blocked issue"
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
echo "git add -A && git commit -q -m fix && $LAND" >> "$FIX/claude.sh"
echo 'jq ".state = \"CLOSED\"" "$FIX/issues/alpha-4.json" > "$FIX/x" && mv "$FIX/x" "$FIX/issues/alpha-4.json"' >> "$FIX/claude.sh"
run
[[ "$(cat "$FIX/checkout")" == $'looper/alpha-4\nat-main\n?? wip.txt\nwip\nlater' ]] || fail "checkout: $(cat "$FIX/checkout")"
p="$(cat "$FIX"/project/looper-runs/*-issue-4/prompt.md)"
has "$p" "looper/alpha-4"
has "$p" "wip.txt started; left: finish it"
has "$p" "Ran out of time."
! branch || fail "branch not deleted after the work landed"
[[ "$(origin show main:wip.txt)" == wip ]] || fail "work not on main"
pass

# A branch that does not rebase on main but merges cleanly (a change it makes
# and undoes conflicts commit by commit, not in sum): main merged into it is the
# run's uncommitted work on main, and the prompt says so.
scenario resume-merge
echo base > "$FIX/seed/f"; git -C "$FIX/seed" add f; git -C "$FIX/seed" commit -q -m f; git -C "$FIX/seed" push -q origin main
git -C "$FIX/seed" checkout -q -b looper/alpha-4; echo ours > "$FIX/seed/f"; git -C "$FIX/seed" commit -qam try
echo base > "$FIX/seed/f"; echo wip > "$FIX/seed/wip.txt"; git -C "$FIX/seed" add -A; git -C "$FIX/seed" commit -qm wip
git -C "$FIX/seed" push -q origin looper/alpha-4
git -C "$FIX/seed" checkout -q main; echo theirs > "$FIX/seed/f"; git -C "$FIX/seed" commit -qam theirs; git -C "$FIX/seed" push -q origin main
echo '{ git rev-parse --abbrev-ref HEAD; [[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] && echo at-main; git status --porcelain; cat f wip.txt; } > "$FIX/checkout"' >> "$FIX/claude.sh"
run
[[ "$(cat "$FIX/checkout")" == $'looper/alpha-4\nat-main\n?? wip.txt\ntheirs\nwip' ]] || fail "checkout: $(cat "$FIX/checkout")"
p="$(cat "$FIX"/project/looper-runs/*-issue-4/prompt.md)"
has "$p" "with main merged into it"
lacks "$p" "Bring that work over by hand"
has "$OUT" "resuming #4 from looper/alpha-4 (merged with main)"
branch || fail "branch lost"
pass

# A branch whose merge with main conflicts: the run starts from the branch with
# main merged in, the conflicts marked in the files, as uncommitted work on
# main; the prompt names the conflicting paths to resolve first.
scenario resume-conflict
echo base > "$FIX/seed/f"; echo base > "$FIX/seed/g"; git -C "$FIX/seed" add f g; git -C "$FIX/seed" commit -q -m f; git -C "$FIX/seed" push -q origin main
git -C "$FIX/seed" checkout -q -b looper/alpha-4; echo ours > "$FIX/seed/f"; echo wip > "$FIX/seed/wip.txt"; git -C "$FIX/seed" add -A; git -C "$FIX/seed" commit -qm wip
git -C "$FIX/seed" push -q origin looper/alpha-4
git -C "$FIX/seed" checkout -q main; echo theirs > "$FIX/seed/f"; echo later > "$FIX/seed/g"; git -C "$FIX/seed" commit -qam theirs; git -C "$FIX/seed" push -q origin main
echo '{ git rev-parse --abbrev-ref HEAD; [[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] && echo at-main; git status --porcelain; cat g wip.txt; } > "$FIX/checkout"; cp f "$FIX/f"' >> "$FIX/claude.sh"
run
[[ "$(cat "$FIX/checkout")" == $'looper/alpha-4\nat-main\n M f\n?? wip.txt\nlater\nwip' ]] || fail "checkout: $(cat "$FIX/checkout")"
f="$(cat "$FIX/f")"; has "$f" "<<<<<<<"; has "$f" "ours"; has "$f" "theirs"; has "$f" ">>>>>>>"
p="$(cat "$FIX"/project/looper-runs/*-issue-4/prompt.md)"
has "$p" "conflicts with main"
has "$p" "- \`f\`"
lacks "$p" "Bring that work over by hand"
has "$OUT" "resuming #4 from looper/alpha-4 (merged with main, conflicts in: f)"
branch || fail "branch lost"
pass

# The record (prompt.md, the claude.log tail) rides on every checkpoint, under
# .looper/, with known secrets redacted; a resumed run does not get it back as work.
scenario record
echo 'echo "token ghp_abcdefghijklmnopqrstuvwxyz0123456789 and $GH_TOKEN"; echo x > a.txt; sleep 1' >> "$FIX/claude.sh"
step "a.txt written"
run GH_TOKEN=s3cr3t-value-for-test
r="$(origin show looper/alpha-4:.looper/claude.log)"
has "$r" "token [redacted] and [redacted]"
lacks "$r" "s3cr3t-value-for-test"
has "$(origin show looper/alpha-4:.looper/prompt.md)" "working issue #4"
: > "$FIX/claude.sh"; echo 'ls -A > "$FIX/checkout"' >> "$FIX/claude.sh"
issue alpha 4 OPEN approved,bug "Fix it."
run
[[ "$(tr '\n' ' ' < "$FIX/checkout")" == ".git a.txt " ]] || fail "checkout: $(cat "$FIX/checkout")"
pass

# A run killed outright (the job cancelled: no trap, no artifacts) still leaves
# its log tail on the branch, from its last checkpoint.
kill_tree() { local c; for c in $(pgrep -P "$1"); do kill_tree "$c"; done; kill -KILL "$1" 2>/dev/null || true; }
scenario cancelled
echo 'echo "the log so far"; echo x > a.txt; sleep 1' >> "$FIX/claude.sh"
step "a.txt written"
echo 'sleep 60' >> "$FIX/claude.sh"
looper -- --repo alpha --issue 4 > "$FIX/out" 2>&1 & pid=$!
for _ in $(seq 40); do branch && break; sleep 0.5; done
kill_tree "$pid"; wait "$pid" 2>/dev/null || true
branch || fail "no checkpoint before the cancel"
has "$(origin show looper/alpha-4:.looper/claude.log)" "the log so far"
pass

# Idle: no output and no change in the checkout for LOOPER_IDLE_MINUTES stops
# the model; its work is checkpointed and the issue says so, with the log tail.
scenario idle
echo 'echo "last words"; echo x > e.txt; sleep 60' >> "$FIX/claude.sh"
start=$SECONDS
run LOOPER_IDLE_MINUTES=0.05 LOOPER_WATCH_INTERVAL=1
(( SECONDS - start < 20 )) || fail "the idle model was not stopped"
[[ "$(labels alpha 4)" == "approved,bug,looper:stuck" ]] || fail "labels $(labels alpha 4)"
c="$(cat "$FIX/comments")"
has "$c" "went idle"
has "$c" "last words"
has "$c" "https://github.com/tacplus-dev/alpha/tree/looper/alpha-4"
has "$(origin ls-tree -r --name-only looper/alpha-4)" "e.txt"
pass

# Output or changes in the checkout are not idle, however long the run.
scenario busy
echo 'for i in 1 2 3 4 5; do echo tick; sleep 1; done; for i in 1 2 3 4 5; do date +%N > f.txt; sleep 1; done' >> "$FIX/claude.sh"
push_fix
echo 'jq ".state = \"CLOSED\"" "$FIX/issues/alpha-4.json" > "$FIX/x" && mv "$FIX/x" "$FIX/issues/alpha-4.json"' >> "$FIX/claude.sh"
run LOOPER_IDLE_MINUTES=0.05 LOOPER_WATCH_INTERVAL=1
[[ ! -s "$FIX/comments" ]] || fail "unexpected comment"
[[ "$(labels alpha 4)" == approved,bug ]] || fail "labels $(labels alpha 4)"
pass

# Done means done: once the run closed its issue, the model gets
# LOOPER_DONE_GRACE seconds to exit, then it is stopped.
scenario done-closed
push_fix
echo 'jq ".state = \"CLOSED\"" "$FIX/issues/alpha-4.json" > "$FIX/x" && mv "$FIX/x" "$FIX/issues/alpha-4.json"' >> "$FIX/claude.sh"
echo 'while :; do echo still here; sleep 1; done' >> "$FIX/claude.sh"
start=$SECONDS
run LOOPER_DONE_GRACE=2 LOOPER_WATCH_INTERVAL=1
(( SECONDS - start < 20 )) || fail "the finished run was not ended"
[[ ! -s "$FIX/comments" ]] || fail "unexpected comment"
[[ "$(labels alpha 4)" == approved,bug ]] || fail "labels $(labels alpha 4)"
has "$OUT" "done"
has "$(cat "$FIX"/project/looper-runs/*-issue-4/prompt.md)" "ends your run"
pass

# Likewise once the fix is pushed and the run wrote its Blocked-by outcome.
scenario done-blocked
push_fix; echo 'echo "Blocked-by: #3" > "$OUTCOME"' >> "$FIX/claude.sh"
issue alpha 3 OPEN "" "First."
echo 'while :; do echo still here; sleep 1; done' >> "$FIX/claude.sh"
start=$SECONDS
run LOOPER_DONE_GRACE=2 LOOPER_WATCH_INTERVAL=1
(( SECONDS - start < 20 )) || fail "the finished run was not ended"
[[ "$(labels alpha 4)" == approved,bug ]] || fail "labels $(labels alpha 4)"
has "$(body alpha 4)" "Blocked-by: #3"
pass

# And once a run that pushes nothing wrote its Blocked-by outcome (looper#22).
scenario done-blocked-nothing-pushed
echo 'echo "Blocked-by: #3" > "$OUTCOME"' >> "$FIX/claude.sh"
issue alpha 3 OPEN "" "First."
echo 'while :; do echo still here; sleep 1; done' >> "$FIX/claude.sh"
start=$SECONDS
run LOOPER_DONE_GRACE=2 LOOPER_WATCH_INTERVAL=1
(( SECONDS - start < 20 )) || fail "the finished run was not ended"
[[ "$(labels alpha 4)" == approved,bug ]] || fail "labels $(labels alpha 4)"
has "$(body alpha 4)" "Blocked-by: #3"
pass

# The planning files (tacplus-dev/roadmap decisions/repo-roadmap-files-2026-10-27.md, looper#13).
templates() { # the four templates, as tacplus-dev/roadmap templates/repo/ has them
  mkdir -p "$FIX/templates"
  local f; for f in ROADMAP STATE PROPOSALS HISTORY; do printf '# %s: <repo>\n\nTemplate text.\n' "$f" > "$FIX/templates/$f.md"; done
}
close_it() { echo 'jq ".state = \"CLOSED\"" "$FIX/issues/alpha-4.json" > "$FIX/x" && mv "$FIX/x" "$FIX/issues/alpha-4.json"' >> "$FIX/claude.sh"; }
history() { origin show main:HISTORY.md; }
today="$(date -u +%F)"

# A missing planning file is created from the template on main before the model
# runs, never ROADMAP.md; a closed issue appends exactly one well-formed line.
scenario history-closed
templates
echo '{ ls; cat STATE.md; } > "$FIX/checkout"' >> "$FIX/claude.sh"
echo "git commit -q --allow-empty -m fix && $LAND"' && git rev-parse --short HEAD > "$FIX/fix"' >> "$FIX/claude.sh"
close_it
run
c="$(cat "$FIX/checkout")"
has "$c" "HISTORY.md"; has "$c" "PROPOSALS.md"; has "$c" "STATE.md"; lacks "$c" "ROADMAP.md"
has "$c" "# STATE: alpha"
! origin cat-file -e main:ROADMAP.md 2>/dev/null || fail "ROADMAP.md created"
[[ "$(origin show main:PROPOSALS.md)" == "$(sed 's/<repo>/alpha/' "$FIX/templates/PROPOSALS.md")" ]] || fail "PROPOSALS.md: $(origin show main:PROPOSALS.md)"
h="$(history)"
[[ "$h" == "$(sed 's/<repo>/alpha/' "$FIX/templates/HISTORY.md")"$'\n'"- $today looper issue Issue 4 (#4, $(cat "$FIX/fix"))" ]] || fail "HISTORY.md: $h"
[[ "$(grep -c '^- ' <<<"$h")" == 1 ]] || fail "HISTORY.md: $h"
p="$(cat "$FIX"/project/looper-runs/*-issue-4/prompt.md)"
has "$p" "Never edit ROADMAP.md"; has "$p" "STATE.md"; has "$p" "PROPOSALS.md"
[[ "$(labels alpha 4)" == approved,bug ]] || fail "labels $(labels alpha 4)"
pass

# Files already there are left alone, and the line goes at the end; a run that
# does not close its issue adds none.
scenario history-existing
templates
printf '# History: alpha\n\n- 2026-10-01 agent decision first (x)\n' > "$FIX/seed/HISTORY.md"
echo 'my state' > "$FIX/seed/STATE.md"; echo 'my proposals' > "$FIX/seed/PROPOSALS.md"
git -C "$FIX/seed" add -A && git -C "$FIX/seed" commit -q -m files && git -C "$FIX/seed" push -q origin main
seeded="$(origin rev-parse main)"
push_fix
run
[[ "$(labels alpha 4)" == approved,bug ]] || fail "labels $(labels alpha 4)"
[[ "$(origin rev-parse main~1)" == "$seeded" ]] || fail "main: $(origin log --oneline main)"
[[ "$(history)" == $'# History: alpha\n\n- 2026-10-01 agent decision first (x)' ]] || fail "HISTORY.md: $(history)"
push_fix; close_it; issue alpha 4 OPEN approved,bug "Fix it."
run
[[ "$(history)" == $'# History: alpha\n\n- 2026-10-01 agent decision first (x)\n'"- $today looper issue Issue 4 (#4, $(origin rev-parse --short main~1))" ]] \
  || fail "HISTORY.md: $(history)"
[[ "$(origin show main:STATE.md)" == "my state" ]] || fail "STATE.md overwritten"
pass

# A release made by the run (a new vX.Y.Z tag) gets its line too.
scenario history-release
templates
push_fix; echo 'git tag v1.2.3 && git push -q origin v1.2.3' >> "$FIX/claude.sh"; close_it
run
h="$(history)"
has "$h" "- $today looper issue Issue 4 (#4, "
[[ "$(tail -n 1 <<<"$h")" == "- $today looper release v1.2.3 (https://github.com/tacplus-dev/alpha/releases/tag/v1.2.3)" ]] || fail "HISTORY.md: $h"
pass

# ROADMAP.md is Jody's: a push of a commit that touches it is refused, whichever
# way it is pushed; the work is still kept on the issue's branch.
scenario roadmap-refused
templates
echo 'Jody wrote this.' > "$FIX/seed/ROADMAP.md"; git -C "$FIX/seed" add -A; git -C "$FIX/seed" commit -q -m roadmap; git -C "$FIX/seed" push -q origin main
echo 'echo "looper wrote this" >> ROADMAP.md && git commit -qam "roadmap edit"' >> "$FIX/claude.sh"
echo "$LAND"' > /dev/null 2> "$FIX/refused" && echo pushed >> "$FIX/refused"' >> "$FIX/claude.sh"
echo 'git push -q origin HEAD:main 2>> "$FIX/refused" && echo pushed >> "$FIX/refused"' >> "$FIX/claude.sh"
echo 'git push -q origin HEAD:refs/heads/other 2>> "$FIX/refused" && echo pushed >> "$FIX/refused"' >> "$FIX/claude.sh"
run
r="$(cat "$FIX/refused")"
lacks "$r" "pushed"
has "$r" "ROADMAP.md"
[[ "$(origin show main:ROADMAP.md)" == "Jody wrote this." ]] || fail "ROADMAP.md changed on main"
! origin rev-parse -q --verify refs/heads/other >/dev/null || fail "pushed to other"
has "$(origin show looper/alpha-4:ROADMAP.md)" "looper wrote this"
pass

# A commit on main that touches ROADMAP.md (an agent's, at Jody's request) does
# not stop the looper pushing its own work on top of it.
scenario roadmap-others
templates
echo 'git commit -q --allow-empty -m fix' >> "$FIX/claude.sh"
echo 'git -C "$FIX/seed" pull -q origin main && echo "agent" > "$FIX/seed/ROADMAP.md" && git -C "$FIX/seed" add -A && git -C "$FIX/seed" commit -q -m roadmap && git -C "$FIX/seed" push -q origin main' >> "$FIX/claude.sh"
echo "$LAND" >> "$FIX/claude.sh"
close_it
run
[[ "$(origin log -1 --skip 1 --format=%s main)" == fix ]] || fail "main: $(origin log --oneline main)"
pass

# The issue flow (tacplus-dev/roadmap decisions/issue-flow-2026-10-27.md,
# looper#14): every issue is a bug or a feature.
platform() { mkdir -p "$FIX/platform"; printf '# Roadmap: tacplus-dev (platform)\n\n%s\n' "$1" > "$FIX/platform/ROADMAP.md"; }
roadmap() { printf '# Roadmap: alpha\n\n%s\n' "$1" > "$FIX/seed/ROADMAP.md"; git -C "$FIX/seed" add -A; git -C "$FIX/seed" commit -q -m roadmap; git -C "$FIX/seed" push -q origin main; }
prompts() { tr '\n' '|' < "$FIX/prompts"; }

# A feature that no ROADMAP.md links is not built: the model only proposes a
# design (on the issue and in PROPOSALS.md), and the issue waits on a decision.
# Another repository's #4 is not this one's.
scenario feature-not-on-roadmap
templates
issue alpha 4 OPEN approved,feature "Add a thing."
roadmap "- Other (tacplus-dev/beta#4)"
platform "- Elsewhere (tacplus-dev/beta#4, alpha#40)"
push_fix; close_it
cat > "$FIX/propose.sh" <<'EOS'
gh issue comment 4 --repo tacplus-dev/alpha --body "Design: do it this way."
echo "- **A thing** (#4)" >> PROPOSALS.md && git commit -qam "PROPOSALS.md: #4" && "$ROOT/repo-looper" --repo alpha --issue 4 --land --gates true
EOS
run
p="$(prompts)"; has "$p" "proposing a design for issue #4"; lacks "$p" "working issue"
[[ "$(labels alpha 4)" == "approved,feature,needs-decision" ]] || fail "labels $(labels alpha 4)"
[[ "$(jq -r .state "$FIX/issues/alpha-4.json")" == OPEN ]] || fail "closed"
c="$(cat "$FIX/comments")"; has "$c" "Design: do it this way."; has "$c" "is not built"; has "$c" "ROADMAP.md"
[[ "$(origin log -1 --format=%s main)" == "PROPOSALS.md: #4" ]] || fail "main: $(origin log --oneline main)"
has "$(origin show main:PROPOSALS.md)" "A thing"
lacks "$(origin show main:HISTORY.md)" "looper issue"
pp="$(cat "$FIX"/project/looper-runs/*-issue-4/prompt.md)"
has "$pp" "Do not build it"; has "$pp" "PROPOSALS.md"
pass

# A feature linked from the repository's ROADMAP.md, or from the platform's, is built, on main only.
scenario feature-on-roadmap
templates
issue alpha 4 OPEN approved,feature "Add a thing."
roadmap "- A thing (#4)"
platform "- Nothing here"
push_fix; close_it
run
p="$(prompts)"; has "$p" "working issue #4"; lacks "$p" "proposing"
[[ "$(labels alpha 4)" == "approved,feature" ]] || fail "labels $(labels alpha 4)"
pp="$(cat "$FIX"/project/looper-runs/*-issue-4/prompt.md)"
has "$pp" "is a feature"; has "$pp" "no patch release"; lacks "$pp" "backported"
pass

scenario feature-on-platform-roadmap
templates
issue alpha 4 OPEN approved,feature "Add a thing."
platform "- A thing across repositories (tacplus-dev/alpha#4)"
push_fix; close_it
run
has "$(prompts)" "working issue #4"
pass

# The platform's roadmap cannot be read: the feature is neither built nor proposed.
scenario feature-roadmap-unreadable
issue alpha 4 OPEN approved,feature "Add a thing."
push_fix
run
[[ ! -s "$FIX/prompts" ]] || fail "the model ran: $(prompts)"
[[ "$(labels alpha 4)" == "approved,feature,looper:stuck" ]] || fail "labels $(labels alpha 4)"
has "$(cat "$FIX/comments")" "could not read"
main_unchanged
pass

# An unlabelled issue is classified first (a comment and the label), then
# worked by the rule for its kind.
scenario classify-bug
templates
issue alpha 4 OPEN approved "Fix it."
cat > "$FIX/classify.sh" <<'EOS'
gh issue comment 4 --repo tacplus-dev/alpha --body "Classified as bug: it is broken."
gh issue edit 4 --repo tacplus-dev/alpha --add-label bug
EOS
push_fix; close_it
run
[[ "$(prompts)" == "You are the looper of tacplus-dev/alpha, classifying issue #4 before it is worked.|You are the looper of tacplus-dev/alpha, working issue #4. Your working directory is a worktree of this|" ]] || fail "prompts: $(prompts)"
[[ "$(labels alpha 4)" == "approved,bug" ]] || fail "labels $(labels alpha 4)"
has "$(cat "$FIX/comments")" "Classified as bug"
has "$(cat "$FIX"/project/looper-runs/*-issue-4/classify/prompt.md)" "decisions/issue-flow-2026-10-27.md"
pass

scenario classify-feature
issue alpha 4 OPEN approved "Add a thing."
platform "- Nothing here"
echo 'gh issue edit 4 --repo tacplus-dev/alpha --add-label feature' > "$FIX/classify.sh"
push_fix
run
p="$(prompts)"; has "$p" "classifying issue #4"; has "$p" "proposing a design for issue #4"; lacks "$p" "working issue"
[[ "$(labels alpha 4)" == "approved,feature,needs-decision" ]] || fail "labels $(labels alpha 4)"
main_unchanged
pass

# Left unclassified: a person decides.
scenario classify-none
issue alpha 4 OPEN approved "Something."
push_fix
run
[[ "$(prompts)" == *classifying* && "$(prompts)" != *working* ]] || fail "prompts: $(prompts)"
[[ "$(labels alpha 4)" == "approved,needs-decision" ]] || fail "labels $(labels alpha 4)"
has "$(cat "$FIX/comments")" "\`bug\` or \`feature\`"
main_unchanged
pass

# A bug is fixed and its patch released: the prompt names the next patch of
# main's newest release, and the release gets its HISTORY.md line. The labels
# exist in the repository.
scenario bug-patch-release
templates
git -C "$FIX/seed" tag v1.2.3 && git -C "$FIX/seed" push -q origin v1.2.3
git -C "$FIX/seed" commit -q --allow-empty -m later && git -C "$FIX/seed" push -q origin main
push_fix; echo 'git tag v1.2.4 && git push -q origin v1.2.4' >> "$FIX/claude.sh"; close_it
run
pp="$(cat "$FIX"/project/looper-runs/*-issue-4/prompt.md)"
has "$pp" "is a bug"; has "$pp" "tag \`v1.2.4\`"; has "$pp" "newest release on main is \`v1.2.3\`"; has "$pp" "backported"
has "$(history)" "looper release v1.2.4 (https://github.com/tacplus-dev/alpha/releases/tag/v1.2.4)"
has "$(history)" "looper issue Issue 4 (#4, "
lc="$(cat "$FIX/labels-created")"; has "$lc" "alpha bug"; has "$lc" "alpha feature"
has "$lc" "alpha priority:high"; has "$lc" "alpha priority:low"
pass

scenario bug-no-release
templates
push_fix; close_it
run
has "$(cat "$FIX"/project/looper-runs/*-issue-4/prompt.md)" "no release on main yet"
pass

# The nightly scan files its findings as bugs and never approves a feature
# (only issues it filed: an older approved feature is left alone). Its prompt
# consults the roadmaps before filing, and sends ideas to PROPOSALS.md.
scenario scan
templates
issue alpha 4 OPEN approved,feature "Jody's."
cat > "$FIX/scan.sh" <<'EOS'
gh issue create --repo tacplus-dev/alpha --title "Bump x" --body "x 1.2 has CVE-1" --label approved
gh issue create --repo tacplus-dev/alpha --title "Gate fails" --body "y" --label bug --label approved
gh issue create --repo tacplus-dev/alpha --title "Pin is stale" --body "z" --label bug,needs-decision
gh issue create --repo tacplus-dev/alpha --title "New idea" --body "w" --label feature,approved
EOS
OUT="$(looper -- --repo alpha --scan 2>&1)" || { echo "$OUT"; fail "scan exited non-zero"; }
[[ "$(labels alpha 5)" == "approved,bug" ]] || fail "#5 labels $(labels alpha 5)"
[[ "$(labels alpha 6)" == "bug,approved" ]] || fail "#6 labels $(labels alpha 6)"
[[ "$(labels alpha 7)" == "bug,needs-decision" ]] || fail "#7 labels $(labels alpha 7)"
[[ "$(labels alpha 8)" == "feature" ]] || fail "#8 labels $(labels alpha 8)"
[[ "$(labels alpha 4)" == "approved,feature" ]] || fail "#4 labels $(labels alpha 4)"
has "$(cat "$FIX/comments")" "alpha#8 "
lacks "$(cat "$FIX/comments")" "alpha#4 "
pp="$(cat "$FIX"/project/looper-runs/*-scan/prompt.md)"
has "$pp" "labelled \`bug\`"; has "$pp" "prioritized"; has "$pp" "PROPOSALS.md"; has "$pp" "never \`approved\`"
pass

# Every prompt that may open an issue consults the roadmaps first.
scenario prompt-roadmap-first
push_fix
run
has "$(cat "$FIX"/project/looper-runs/*-issue-4/prompt.md)" "prioritized"
pass

# The plan (`--list` in a GitLab job, looper#16): a repository whose looper job
# is already created, pending, waiting for its resource_group or running in the
# project is not planned again, and the plan's log says so; stdout, the issue
# the plan takes, stays empty. Another repository's job, a finished job, or a
# job of a repository whose name only starts the same, does not hold it.
GL=(CI_API_V4_URL=https://gl.test/api/v4 CI_PROJECT_ID=42 GITLAB_TOKEN=t)
list() { # [VAR=value...]: alpha's ready issues; stdout in OUT, stderr in ERR
  OUT="$(looper "$@" -- --repo alpha --list 2>"$FIX/err")" || { cat "$FIX/err"; fail "--list exited non-zero"; }
  ERR="$(cat "$FIX/err")"
}
jobs() { printf '%s\n' "$@" | jq -R 'split(" ") | {name: .[0], status: .[1], id: (.[2] // "0" | tonumber)}' | jq -s . > "$FIX/jobs.json"; } # "name status [id]"...

for st in created pending waiting_for_resource running; do
  scenario "plan-busy-$st"
  jobs "looper-alpha-3 $st" "looper-beta-7 running"
  list "${GL[@]}"
  [[ -z "$OUT" ]] || fail "planned: $OUT"
  has "$ERR" "alpha already has a looper job"; has "$ERR" "looper-alpha-3"
  pass
done

scenario plan-free
jobs "looper-alpha-3 success" "looper-alpha-2 canceled" "looper-alpha-beta-5 running" "looper-beta-7 waiting_for_resource" "looper-plan running"
list "${GL[@]}"
[[ "$OUT" == 4 ]] || fail "planned: $OUT"
lacks "$ERR" "already has"
has "$(cat "$FIX/gitlab")" "PRIVATE-TOKEN https://gl.test/api/v4/projects/42/jobs?"
pass

# Without GITLAB_TOKEN the job's own token reads the project's jobs.
scenario plan-job-token
jobs "looper-alpha-3 waiting_for_resource"
list CI_API_V4_URL=https://gl.test/api/v4 CI_PROJECT_ID=42 CI_JOB_TOKEN=j
[[ -z "$OUT" ]] || fail "planned: $OUT"
has "$(cat "$FIX/gitlab")" "JOB-TOKEN https://gl.test/api/v4/projects/42/jobs?"
pass

# GitLab unreadable: planned as before, and the log says why.
scenario plan-gitlab-down
list "${GL[@]}"
[[ "$OUT" == 4 ]] || fail "planned: $OUT"
has "$ERR" "could not read"
pass

# Outside a GitLab job, --list asks nothing of GitLab.
scenario list-outside-ci
jobs "looper-alpha-3 running"
list
[[ "$OUT" == 4 ]] || fail "listed: $OUT"
[[ ! -e "$FIX/gitlab" ]] || fail "asked GitLab: $(cat "$FIX/gitlab")"
pass

# Priority labels (looper#31): ready issues are ordered priority:high, then
# unlabelled, then priority:low, oldest first within each; a blocked or held
# issue is skipped whatever its priority.
created() { jq --arg c "$3" '.createdAt = $c' "$FIX/issues/$1-$2.json" > "$FIX/x" && mv "$FIX/x" "$FIX/issues/$1-$2.json"; }
scenario list-priority
issue alpha 4 OPEN approved,bug "Fix it."; created alpha 4 2026-10-24T00:00:00Z
issue alpha 5 OPEN approved,bug,priority:low "Low, oldest."; created alpha 5 2026-10-20T00:00:00Z
issue alpha 6 OPEN approved,bug,priority:high "High, newer."; created alpha 6 2026-10-29T00:00:00Z
issue alpha 7 OPEN approved,bug,priority:high "High, older."; created alpha 7 2026-10-28T00:00:00Z
issue alpha 8 OPEN approved,bug "Unlabelled, oldest."; created alpha 8 2026-10-21T00:00:00Z
issue alpha 9 OPEN approved,bug,priority:low "Low, newer."; created alpha 9 2026-10-25T00:00:00Z
issue alpha 10 OPEN approved,bug,priority:high $'High, blocked.\nBlocked-by: #11'; created alpha 10 2026-10-01T00:00:00Z
issue alpha 11 OPEN bug "Open."
issue alpha 12 OPEN approved,bug,priority:high,needs-decision "High, held."; created alpha 12 2026-10-01T00:00:00Z
list
[[ "$(paste -sd' ' <<<"$OUT")" == "7 6 8 4 5 9" ]] || fail "listed: $(paste -sd' ' <<<"$OUT")"
pass

# A job takes the highest-priority ready issue first, not the oldest; the parent
# goes on with the others (looper#32).
scenario run-takes-priority
issue alpha 4 OPEN approved,bug,looper:in-progress "Fix it."
issue alpha 5 OPEN approved,bug "Older."; created alpha 5 2026-10-20T00:00:00Z
issue alpha 6 OPEN approved,bug,priority:high "Urgent."; created alpha 6 2026-10-29T00:00:00Z
push_fix
run
[[ "$(grep -m 1 'working issue' "$FIX/prompts")" == *"working issue #6."* ]] || fail "prompts: $(prompts)"
has "$(prompts)" "working issue #5."
pass

# A planned job whose issue another run took or finished meanwhile works the
# repository's oldest ready issue at run time instead.
scenario run-takes-oldest-ready
issue alpha 4 OPEN approved,bug,looper:in-progress "Fix it."
issue alpha 5 OPEN approved,bug "Fix that."
issue alpha 6 OPEN approved,bug "And this."
jq '.createdAt = "2026-10-26T00:00:00Z"' "$FIX/issues/alpha-6.json" > "$FIX/x" && mv "$FIX/x" "$FIX/issues/alpha-6.json"
push_fix
run
has "$(prompts)" "working issue #6."; lacks "$(prompts)" "issue #4"
has "$OUT" "#4 is no longer ready; working #6"
pass

scenario run-nothing-ready
issue alpha 4 OPEN approved,bug,looper:in-progress "Fix it."
push_fix
run
[[ -z "$(prompts)" ]] || fail "prompts: $(prompts)"
has "$OUT" "nothing to do"
main_unchanged
pass

# A run killed after it labelled its issue (its runner gone, looper#20) leaves
# looper:in-progress behind. GitLab's retry, the job for that issue, takes it as
# a resume from its checkpoint when no other looper job of the repository is
# active (its own does not count), and the label goes when the run ends.
scenario killed-run-resumed
echo 'echo x > a.txt; sleep 1' >> "$FIX/claude.sh"
step "a.txt written; left: close it"
echo 'sleep 60' >> "$FIX/claude.sh"
looper -- --repo alpha --issue 4 > "$FIX/out" 2>&1 & pid=$!
for _ in $(seq 40); do branch && break; sleep 0.5; done
kill_tree "$pid"; wait "$pid" 2>/dev/null || true
branch || fail "no checkpoint before the kill"
[[ "$(labels alpha 4)" == "approved,bug,looper:in-progress" ]] || fail "labels after the kill: $(labels alpha 4)"
: > "$FIX/prompts"
cat > "$FIX/claude.sh" <<'EOS'
cat a.txt > "$FIX/checkout"
git add -A && git commit -q -m fix && "$ROOT/repo-looper" --repo alpha --issue 4 --land --gates true
jq '.state = "CLOSED"' "$FIX/issues/alpha-4.json" > "$FIX/x" && mv "$FIX/x" "$FIX/issues/alpha-4.json"
EOS
jobs "looper-alpha-4 failed 77" "looper-alpha-4 running 78" "looper-beta-7 running 79"
run "${GL[@]}" CI_JOB_ID=78
has "$(prompts)" "working issue #4."
has "$OUT" "resuming #4 from looper/alpha-4"
[[ "$(cat "$FIX/checkout")" == x ]] || fail "not resumed from the checkpoint: $(cat "$FIX/checkout")"
has "$(cat "$FIX"/project/looper-runs/*-issue-4/prompt.md)" "a.txt written; left: close it"
[[ "$(labels alpha 4)" == approved,bug ]] || fail "labels $(labels alpha 4)"
[[ "$(origin show main:a.txt)" == x ]] || fail "work not on main"
pass

# An issue whose run is really going is never taken twice: another active
# looper job of the repository holds it, and so does GitLab being unreadable.
for st in created pending waiting_for_resource running; do
  scenario "in-progress-held-$st"
  issue alpha 4 OPEN approved,bug,looper:in-progress "Fix it."
  push_fix
  jobs "looper-alpha-4 $st 77" "looper-alpha-4 running 78"
  run "${GL[@]}" CI_JOB_ID=78
  [[ -z "$(prompts)" ]] || fail "taken twice: $(prompts)"
  has "$OUT" "nothing to do"
  [[ "$(labels alpha 4)" == "approved,bug,looper:in-progress" ]] || fail "labels $(labels alpha 4)"
  main_unchanged
  pass
done

scenario in-progress-gitlab-down
issue alpha 4 OPEN approved,bug,looper:in-progress "Fix it."
push_fix
run "${GL[@]}" CI_JOB_ID=78
[[ -z "$(prompts)" ]] || fail "taken: $(prompts)"
[[ "$(labels alpha 4)" == "approved,bug,looper:in-progress" ]] || fail "labels $(labels alpha 4)"
pass

# Held for a person (stuck, needs-decision) or outside a GitLab job: not resumed.
for l in looper:stuck needs-decision; do
  scenario "in-progress-and-$l"
  issue alpha 4 OPEN "approved,bug,looper:in-progress,$l" "Fix it."
  push_fix
  jobs "looper-alpha-4 running 78"
  run "${GL[@]}" CI_JOB_ID=78
  [[ -z "$(prompts)" ]] || fail "taken: $(prompts)"
  pass
done

scenario in-progress-outside-ci
issue alpha 4 OPEN approved,bug,looper:in-progress "Fix it."
push_fix
run
[[ -z "$(prompts)" ]] || fail "taken: $(prompts)"
pass

# A run whose job GitLab no longer runs (looper#21): GitLab can mark a job
# failed (runner_system_failure) while its container keeps working on the VM,
# and retry it. The run polls its own job every LOOPER_JOB_POLL seconds; once
# GitLab reports it anything but running, the run checkpoints and stops: nothing
# more on main, no comment, and the label left to the retry, which resumes from
# that checkpoint.
orphan() { # claude.sh: work, checkpoint a step, more work, then $1 (GitLab ends the job), then push and comment
  cat > "$FIX/claude.sh" <<EOS
echo x > a.txt
"\$ROOT/repo-looper" --repo alpha --issue 4 --checkpoint "a.txt written; left: b.txt, close it"
echo y > b.txt; sleep 2
$1
sleep 30
git add -A && git commit -q -m "the orphan's fix" && "\$ROOT/repo-looper" --repo alpha --issue 4 --land --gates true
gh issue comment 4 --repo tacplus-dev/alpha --body "the orphan's comment"
EOS
}
fail_job() { echo "jq 'map(if .id == $1 then .status = \"failed\" else . end)' \"\$FIX/jobs.json\" > \"\$FIX/x\" && mv \"\$FIX/x\" \"\$FIX/jobs.json\""; } # job id
orphan_stopped() { # elapsed seconds
  (( $1 < 20 )) || fail "the orphaned run was not stopped"
  has "$OUT" "GitLab no longer runs this job"
  main_unchanged
  [[ ! -s "$FIX/comments" ]] || fail "commented"
  [[ "$(labels alpha 4)" == "approved,bug,looper:in-progress" ]] || fail "labels $(labels alpha 4)"
  [[ "$(origin ls-tree -r --name-only looper/alpha-4 | tr '\n' ' ')" == ".looper/claude.log .looper/prompt.md a.txt b.txt " ]] \
    || fail "branch: $(origin ls-tree -r --name-only looper/alpha-4)"
}
POLL=(LOOPER_JOB_POLL=1 LOOPER_WATCH_INTERVAL=1)

scenario job-gone
jobs "looper-alpha-4 running 77"
orphan "$(fail_job 77)"
start=$SECONDS
run "${GL[@]}" CI_JOB_ID=77 "${POLL[@]}"
orphan_stopped "$(( SECONDS - start ))"
has "$(cat "$FIX/gitlab")" "PRIVATE-TOKEN https://gl.test/api/v4/projects/42/jobs/77"
: > "$FIX/prompts"
cat > "$FIX/claude.sh" <<'EOS'
cat a.txt b.txt > "$FIX/checkout"
git add -A && git commit -q -m fix && "$ROOT/repo-looper" --repo alpha --issue 4 --land --gates true
jq '.state = "CLOSED"' "$FIX/issues/alpha-4.json" > "$FIX/x" && mv "$FIX/x" "$FIX/issues/alpha-4.json"
EOS
jobs "looper-alpha-4 failed 77" "looper-alpha-4 running 78"
run "${GL[@]}" CI_JOB_ID=78 "${POLL[@]}"
has "$(prompts)" "working issue #4."
has "$OUT" "resuming #4 from looper/alpha-4"
[[ "$(cat "$FIX/checkout")" == $'x\ny' ]] || fail "not resumed from the checkpoint: $(cat "$FIX/checkout")"
has "$(cat "$FIX"/project/looper-runs/*-issue-4/prompt.md)" "a.txt written; left: b.txt, close it"
[[ "$(labels alpha 4)" == approved,bug ]] || fail "labels $(labels alpha 4)"
[[ "$(origin show main:b.txt)" == y ]] || fail "work not on main"
pass

# With only the job's own token, GitLab refusing it after it was accepted is the
# job's end too: GitLab revokes a job's token when the job stops running.
scenario job-gone-job-token
jobs "looper-alpha-4 running 77"
orphan 'touch "$FIX/revoked"'
start=$SECONDS
run CI_API_V4_URL=https://gl.test/api/v4 CI_PROJECT_ID=42 CI_JOB_TOKEN=j CI_JOB_ID=77 "${POLL[@]}"
orphan_stopped "$(( SECONDS - start ))"
has "$(cat "$FIX/gitlab")" "JOB-TOKEN https://gl.test/api/v4/job"
pass

# A run whose job is still running is never stopped, however often it polls;
# nor is one that cannot read GitLab (down, or its token never accepted), nor
# one outside a GitLab job, which asks GitLab nothing.
working() { # claude.sh: work a while, then push and close
  echo 'for i in 1 2 3 4 5; do echo tick; sleep 1; done' >> "$FIX/claude.sh"
  push_fix; close_it
}
not_stopped() {
  lacks "$OUT" "no longer runs"
  [[ ! -s "$FIX/comments" ]] || fail "unexpected comment"
  [[ "$(labels alpha 4)" == approved,bug ]] || fail "labels $(labels alpha 4)"
  [[ "$(jq -r .state "$FIX/issues/alpha-4.json")" == CLOSED ]] || fail "not closed"
}
scenario job-running
jobs "looper-alpha-4 running 77"
working
run "${GL[@]}" CI_JOB_ID=77 "${POLL[@]}"
not_stopped
(( $(grep -c '/projects/42/jobs/77$' "$FIX/gitlab") >= 2 )) || fail "polled: $(cat "$FIX/gitlab")"
pass

scenario job-gitlab-down
working
run "${GL[@]}" CI_JOB_ID=77 "${POLL[@]}"
not_stopped
grep -q '/jobs/77$' "$FIX/gitlab" || fail "not polled"
pass

scenario job-token-never-accepted
jobs "looper-alpha-4 running 77"; touch "$FIX/revoked"
working
run CI_API_V4_URL=https://gl.test/api/v4 CI_PROJECT_ID=42 CI_JOB_TOKEN=j CI_JOB_ID=77 "${POLL[@]}"
not_stopped
pass

scenario job-outside-ci
working
run CI_JOB_ID=77 "${POLL[@]}"
not_stopped
[[ ! -e "$FIX/gitlab" ]] || fail "asked GitLab: $(cat "$FIX/gitlab")"
pass

# --- the parent and its children (looper#32) -------------------------------------
# The job's repo-looper is the parent: it plans which ready issues run together
# (the model's areas, the runner's capacity), runs each as a child in its own
# worktree and branch, and the children land one at a time through --land.
ROOM=(LOOPER_CHILD_CPUS=0.01 LOOPER_CHILD_MEMORY_GB=0.01)   # room for several children on any test host
drain() { # [VAR=value...]: the parent over alpha's ready issues
  OUT="$(looper "$@" -- --repo alpha 2>&1)" || { echo "$OUT"; fail "repo-looper exited non-zero"; }
}
areas() { # the plan's model writes these lines as its areas
  printf '%s\n' "$@" > "$FIX/areas.txt"; echo 'cp "$FIX/areas.txt" "$AREAS"' > "$FIX/plan.sh"
}
landed() { origin show "main:$1" 2>/dev/null; } # a file on main
closed() { [[ "$(jq -r .state "$FIX/issues/alpha-$1.json")" == CLOSED ]] || fail "#$1 not closed: $(labels alpha "$1")"; }

# Two independent issues run at the same time, each in its own worktree on its
# own branch, and both land; the plan is in the job's log, its record, and on
# each issue.
scenario parallel-independent
issue alpha 5 OPEN approved,bug "Fix that."; created alpha 5 2026-10-27T00:00:01Z
areas "touches 4 a.txt" "touches 5 src/b/"
cat > "$FIX/claude.sh" <<'EOS'
touch "$FIX/running-$ISSUE"
for i in $(seq 150); do ls "$FIX"/running-* | grep -qv "running-$ISSUE\$" && { echo together > "$FIX/together-$ISSUE"; break; }; sleep 0.1; done
{ pwd; git rev-parse --abbrev-ref HEAD; } > "$FIX/where-$ISSUE"
echo "$ISSUE" > "file-$ISSUE.txt" && git add -A && git commit -qm "fix $ISSUE" && "$ROOT/repo-looper" --repo alpha --issue "$ISSUE" --land --gates true
jq ".state = \"CLOSED\"" "$FIX/issues/alpha-$ISSUE.json" > "$FIX/x-$ISSUE" && mv "$FIX/x-$ISSUE" "$FIX/issues/alpha-$ISSUE.json"
EOS
drain "${ROOM[@]}"
[[ -e "$FIX/together-4" && -e "$FIX/together-5" ]] || fail "not run at the same time: $OUT"
[[ "$(cat "$FIX/where-4")" == "$FIX/work/alpha/worktrees/4"$'\nlooper/alpha-4' ]] || fail "#4 ran in: $(cat "$FIX/where-4")"
[[ "$(cat "$FIX/where-5")" == "$FIX/work/alpha/worktrees/5"$'\nlooper/alpha-5' ]] || fail "#5 ran in: $(cat "$FIX/where-5")"
[[ "$(landed file-4.txt)" == 4 && "$(landed file-5.txt)" == 5 ]] || fail "main: $(origin log --oneline main)"
closed 4; closed 5
[[ "$(labels alpha 4)" == approved,bug && "$(labels alpha 5)" == approved,bug ]] || fail "labels $(labels alpha 4) / $(labels alpha 5)"
has "$OUT" "plan: #4 starts"; has "$OUT" "plan: #5 starts"; has "$OUT" "[#4] "; has "$OUT" "#5: closed"
has "$(cat "$FIX"/project/looper-runs/*-plan/plan.md)" "#5 starts"
has "$(cat "$FIX"/project/looper-runs/*-plan/prompt.md)" "touches <n> <path>"
c="$(cat "$FIX/comments")"; has "$c" "alpha#4 The looper of alpha starts this issue alongside #5"; has "$c" "alpha#5 The looper of alpha starts this issue alongside #4"
has "$c" "- #4 starts"; has "$c" "looper-runs/"
h="$(history)"; has "$h" "looper issue Issue 4 (#4, "; has "$h" "looper issue Issue 5 (#5, "
pass

# Two issues that touch the same file never run at the same time: the second
# waits, says why, and starts when the first ends.
scenario parallel-same-file
issue alpha 5 OPEN approved,bug "Fix that."; created alpha 5 2026-10-27T00:00:01Z
areas "touches 4 shared.txt docs" "touches 5 ./shared.txt"
cat > "$FIX/claude.sh" <<'EOS'
ls "$FIX"/running-* >/dev/null 2>&1 && echo "overlap at #$ISSUE" >> "$FIX/overlap"
touch "$FIX/running-$ISSUE"; sleep 2
echo "$ISSUE" >> shared.txt && git add -A && git commit -qm "fix $ISSUE" && "$ROOT/repo-looper" --repo alpha --issue "$ISSUE" --land --gates true
rm -f "$FIX/running-$ISSUE"
jq ".state = \"CLOSED\"" "$FIX/issues/alpha-$ISSUE.json" > "$FIX/x-$ISSUE" && mv "$FIX/x-$ISSUE" "$FIX/issues/alpha-$ISSUE.json"
EOS
drain "${ROOM[@]}"
[[ ! -e "$FIX/overlap" ]] || fail "$(cat "$FIX/overlap")"
[[ "$(landed shared.txt)" == $'4\n5' ]] || fail "shared.txt: $(landed shared.txt)"
closed 4; closed 5
has "$OUT" "plan: #4 starts"; has "$OUT" "plan: #5 waits: both touch shared.txt (#4, starting)"
has "$(cat "$FIX/comments")" "alpha#5 The looper of alpha holds this issue back for now: both touch shared.txt (#4, starting)"
pass

# The same for a contract both change, a conflict the plan names, an issue
# whose areas it does not tell, and a runner with room for one.
scenario parallel-held-back
issue alpha 5 OPEN approved,bug "Fix that."; created alpha 5 2026-10-27T00:00:01Z
echo 'echo "$ISSUE" > "f-$ISSUE.txt" && git add -A && git commit -qm "fix $ISSUE" && "$ROOT/repo-looper" --repo alpha --issue "$ISSUE" --land --gates true' > "$FIX/claude.sh"
areas "touches 4 a.go" "contract 4 the alpha CLI" "touches 5 b.go" "contract 5 the alpha CLI"
drain "${ROOM[@]}"
has "$OUT" "plan: #5 waits: both change the alpha CLI (#4, starting)"
issue alpha 4 OPEN approved,bug "Fix it."; issue alpha 5 OPEN approved,bug "Fix that."; created alpha 5 2026-10-27T00:00:01Z; created alpha 5 2026-10-27T00:00:01Z
areas "touches 4 a.go" "touches 5 b.go" "conflict #5 #4 both need the one test database"
drain "${ROOM[@]}"
has "$OUT" "plan: #5 waits: the plan: both need the one test database (#4, starting)"
issue alpha 4 OPEN approved,bug "Fix it."; issue alpha 5 OPEN approved,bug "Fix that."; created alpha 5 2026-10-27T00:00:01Z; created alpha 5 2026-10-27T00:00:01Z
areas "touches 4 a.go"
drain "${ROOM[@]}"
has "$OUT" "plan: #5 waits: the plan does not tell what #5 touches (#4, starting)"
issue alpha 4 OPEN approved,bug "Fix it."; issue alpha 5 OPEN approved,bug "Fix that."; created alpha 5 2026-10-27T00:00:01Z; created alpha 5 2026-10-27T00:00:01Z
areas "touches 4 a.go" "touches 5 b.go"
drain LOOPER_CHILD_CPUS=0.01 LOOPER_CHILD_MEMORY_GB=0.01 LOOPER_MAX_CHILDREN=1
has "$OUT" "plan: #5 waits: no free slot (capacity 1: "
has "$OUT" "ceiling 1)"
[[ "$(landed f-4.txt)" == 4 && "$(landed f-5.txt)" == 5 ]] || fail "main: $(origin log --oneline main)"
pass

# A landing that conflicts with what another child landed meanwhile lands
# nothing and names the paths; the child rebases, resolves and lands again.
scenario landing-conflict
issue alpha 5 OPEN approved,bug "Fix that."; created alpha 5 2026-10-27T00:00:01Z
areas "touches 4 a.txt" "touches 5 b.txt"
cat > "$FIX/claude.sh" <<'EOS'
echo "line $ISSUE" > shared.txt && git add -A && git commit -qm "fix $ISSUE"
if [ "$ISSUE" = 5 ]; then for i in $(seq 150); do git -C "$FIX/origin.git" cat-file -e main:shared.txt 2>/dev/null && break; sleep 0.1; done; fi
if ! "$ROOT/repo-looper" --repo alpha --issue "$ISSUE" --land --gates true 2> "$FIX/land-$ISSUE"; then
  git fetch -q origin
  if ! git rebase -q origin/main >/dev/null 2>&1; then
    printf 'line 4\nline 5\n' > shared.txt && git add shared.txt && GIT_EDITOR=true git rebase --continue >/dev/null
  fi
  "$ROOT/repo-looper" --repo alpha --issue "$ISSUE" --land --gates true
fi
jq ".state = \"CLOSED\"" "$FIX/issues/alpha-$ISSUE.json" > "$FIX/x-$ISSUE" && mv "$FIX/x-$ISSUE" "$FIX/issues/alpha-$ISSUE.json"
EOS
drain "${ROOM[@]}"
has "$(cat "$FIX/land-5")" "nothing landed: rebasing looper/alpha-5 onto main conflicts in: shared.txt"
[[ "$(landed shared.txt)" == $'line 4\nline 5' ]] || fail "shared.txt: $(landed shared.txt)"
closed 4; closed 5
pass

# Main moving while the gates run (a push rejected): rebased again, the gates
# run again, then it lands on top.
scenario landing-push-rejected
cat > "$FIX/claude.sh" <<'EOS'
echo x > x.txt && git add -A && git commit -qm fix
"$ROOT/repo-looper" --repo alpha --issue 4 --land \
  --gates '[ -e "$FIX/moved" ] || { touch "$FIX/moved"; git -C "$FIX/seed" commit -q --allow-empty -m meanwhile && git -C "$FIX/seed" push -q origin main; }' > "$FIX/land" 2>&1
EOS
close_it
run
has "$(cat "$FIX/land")" "rejected"; has "$(cat "$FIX/land")" "landed on main"
[[ "$(origin log --format=%s main | grep -v '^HISTORY.md' | head -n 2 | paste -sd' ' -)" == "fix meanwhile" ]] || fail "main: $(origin log --oneline main)"
pass

# Broken work never lands: gates that fail, or that change a tracked file, land
# nothing; nor does a change that is not committed. A push to main from a
# child's worktree other than through --land is refused.
scenario landing-refused
cat > "$FIX/claude.sh" <<'EOS'
echo x > x.txt && git add -A && git commit -qm fix
L=("$ROOT/repo-looper" --repo alpha --issue 4 --land)
"${L[@]}" --gates 'echo broken; exit 3' > /dev/null 2>> "$FIX/land" && echo LANDED >> "$FIX/land"
"${L[@]}" --gates 'echo changed >> x.txt' > /dev/null 2>> "$FIX/land" && echo LANDED >> "$FIX/land"
git checkout -q -- x.txt; echo y > y.txt; git add y.txt
"${L[@]}" --gates true > /dev/null 2>> "$FIX/land" && echo LANDED >> "$FIX/land"
git reset -q; rm y.txt
git push -q origin HEAD:main 2>> "$FIX/land" && echo LANDED >> "$FIX/land"
EOS
run
l="$(cat "$FIX/land")"
lacks "$l" "LANDED"
has "$l" "the gates failed (exit 3)"; has "$l" "broken"
has "$l" "the gates changed tracked files (x.txt)"
has "$l" "uncommitted changes"
has "$l" "land it with repo-looper --land"
main_unchanged
pass

# A child's time limit is its own: one that reaches it does not stop the
# others, and the parent goes on planning (#6 ends, #5 takes its slot and
# outlives #4).
scenario child-timeout
issue alpha 5 OPEN approved,bug "Fix that."; created alpha 5 2026-10-27T00:00:02Z
issue alpha 6 OPEN approved,bug "And this."; created alpha 6 2026-10-27T00:00:01Z
areas "touches 4 a" "touches 5 b" "touches 6 c"
cat > "$FIX/claude.sh" <<'EOS'
case "$ISSUE" in
  4) sleep 60 ;;
  6) sleep 4 ;;
  5) for i in $(seq 150); do grep -q "^alpha#4 The run reached its time limit" "$FIX/comments" && break; sleep 0.1; done
     grep -c "^alpha#4 The run reached its time limit" "$FIX/comments" > "$FIX/saw" ;;
esac
[ "$ISSUE" = 4 ] && exit 0
git commit -q --allow-empty -m "fix $ISSUE" && "$ROOT/repo-looper" --repo alpha --issue "$ISSUE" --land --gates true
jq ".state = \"CLOSED\"" "$FIX/issues/alpha-$ISSUE.json" > "$FIX/x-$ISSUE" && mv "$FIX/x-$ISSUE" "$FIX/issues/alpha-$ISSUE.json"
EOS
drain LOOPER_CHILD_CPUS=0.01 LOOPER_CHILD_MEMORY_GB=0.01 LOOPER_MAX_CHILDREN=2 LOOPER_TIMEOUT=14 LOOPER_STOP_EARLY=2
has "$OUT" "plan: #4 starts"; has "$OUT" "plan: #6 starts"; has "$OUT" "plan: #5 waits: no free slot"
has "$OUT" "#4: timeout"; has "$OUT" "#6: closed"; has "$OUT" "#5: closed"
[[ "$(cat "$FIX/saw")" == 1 ]] || fail "#5 did not outlive #4's time limit: $OUT"
closed 5; closed 6
[[ "$(labels alpha 4)" == approved,bug ]] || fail "labels $(labels alpha 4)"
pass

# The parent owns a child's land (looper#34): --land queues it with the
# parent, which lands one at a time. A child whose limit fires while its land
# is running (#4) or still queued behind another (#5) is not stuck: the parent
# still lands its commits after it, says so on the issue, and the issue stays
# approved for the next run to comment and close.
scenario land-after-limit
issue alpha 5 OPEN approved,bug "Fix that."; created alpha 5 2026-10-27T00:00:01Z
areas "touches 4 a.txt" "touches 5 b.txt"
cat > "$FIX/claude.sh" <<'EOS'
echo "$ISSUE" > "f-$ISSUE.txt" && git add -A && git commit -qm "fix $ISSUE"
"$ROOT/repo-looper" --repo alpha --issue "$ISSUE" --checkpoint "fixed; left: land, comment, close"
"$ROOT/repo-looper" --repo alpha --issue "$ISSUE" --land --gates 'sleep 4' > "$FIX/land-$ISSUE" 2>&1
touch "$FIX/saw-$ISSUE"
EOS
drain "${ROOM[@]}" LOOPER_TIMEOUT=6 LOOPER_STOP_EARLY=3
[[ ! -e "$FIX/saw-4" && ! -e "$FIX/saw-5" ]] || fail "a model outlived its limit: $OUT"
[[ "$(landed f-4.txt)" == 4 && "$(landed f-5.txt)" == 5 ]] || fail "not landed: $(origin log --oneline main); $OUT"
has "$OUT" "#4: land-pending"; has "$OUT" "#5: land-pending"
for i in 4 5; do [[ "$(labels alpha $i)" == approved,bug ]] || fail "labels of #$i: $(labels alpha $i)"; done
c="$(cat "$FIX/comments")"
has "$c" "alpha#4 The looper landed this issue's commits on main"; has "$c" "alpha#5 The looper landed this issue's commits on main"
lacks "$c" "looper:stuck"
has "$(cat "$FIX/land-5")" "queued"
# The branch is main and the record: the next run resumes to an empty change.
[[ "$(origin rev-parse looper/alpha-4^)" == "$(origin log --format=%H -1 --grep='^fix 4$' main)" ]] || fail "branch: $(origin log --oneline -2 looper/alpha-4)"
pass

# A model waiting on its land is not idle, however long the land's gates run.
scenario land-wait-not-idle
echo "git commit -q --allow-empty -m fix && \"\$ROOT/repo-looper\" --repo alpha --issue 4 --land --gates 'sleep 6'" >> "$FIX/claude.sh"
close_it
run LOOPER_IDLE_MINUTES=0.05 LOOPER_WATCH_INTERVAL=1
closed 4
[[ "$(labels alpha 4)" == approved,bug ]] || fail "labels $(labels alpha 4)"
[[ ! -s "$FIX/comments" ]] || fail "unexpected comment"
pass

# In a GitLab job no other child starts that would outlast the job, less the
# hour it keeps for itself, counted from the job's start: its own issue always
# does (the job was sized for it). With the default limits, the job the plan
# sizes (--job-timeout) runs two independent issues together (looper#33).
scenario parallel-job-time
issue alpha 5 OPEN approved,bug "Fix that."; created alpha 5 2026-10-27T00:00:01Z
areas "touches 4 a" "touches 5 b"
echo "git commit -q --allow-empty -m \"fix \$ISSUE\" && $LAND" >> "$FIX/claude.sh"
t="$(looper -- --repo alpha --job-timeout 4)"
[[ "$t" == 6h ]] || fail "job timeout $t"
drain "${ROOM[@]}" CI_JOB_TIMEOUT=$(( ${t%h} * 3600 )) CI_JOB_STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
has "$OUT" "plan: #4 starts"; has "$OUT" "plan: #5 starts"
# One whose limit does not fit the job's remaining time still waits: a longer
# limit, or a job that started earlier.
issue alpha 4 OPEN approved,bug "Fix it."
issue alpha 5 OPEN approved,bug "Timeout: 6h"; created alpha 5 2026-10-27T00:00:01Z
drain "${ROOM[@]}" CI_JOB_TIMEOUT=21600
has "$OUT" "plan: #4 starts"; has "$OUT" "plan: #5 waits: its limit (6h) would outlast this job"
for i in 4 5; do issue alpha "$i" OPEN approved,bug "Fix it."; done
created alpha 5 2026-10-27T00:00:01Z
drain "${ROOM[@]}" CI_JOB_TIMEOUT=21600 CI_JOB_STARTED_AT="$(date -u -d '-2 hours' +%Y-%m-%dT%H:%M:%SZ)"
has "$OUT" "plan: #4 starts"; has "$OUT" "plan: #5 waits: its limit (4h) would outlast this job"
pass

# --- the think job (looper#28): no identity, nothing written, the outcome --------
# GitHub refuses a push with the read-only token: here, pushes go nowhere.
think() { # [VAR=value...]: think about alpha#4 into $FIX/think
  OUT="$(looper GH_TOKEN= GITHUB_TOKEN= GITLAB_TOKEN= LOOPER_READER_TOKEN=ghs_read LOOPER_GATES=true \
           GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0="url.$FIX/nowhere.git.pushInsteadOf" GIT_CONFIG_VALUE_0="$FIX/origin.git" \
           "$@" -- --repo alpha --issue 4 --think "$FIX/think" 2>&1)" || { echo "$OUT"; fail "repo-looper --think exited non-zero"; }
}
outcome() { cat "$FIX/think/outcome"; }
untouched() { # nothing written to GitHub: no branch, main, the issue as it was
  main_unchanged
  [[ -z "$(origin for-each-ref refs/heads/looper)" ]] || fail "pushed a branch"
  [[ ! -s "$FIX/comments" ]] || fail "commented"
  [[ "$(labels alpha 4)" == "$1" ]] || fail "labels $(labels alpha 4)"
}
says() { # what the model writes: a change, its comment and its outcome
  printf '%s\n' "$@" >> "$FIX/claude.sh"
}
# The patch on base gives the tree, as the commit job checks.
patch_gives_tree() {
  local wt; wt="$(mktemp -d)"; git clone -q "$FIX/origin.git" "$wt"
  [[ "$(git -C "$wt" rev-parse HEAD)" == "$(cat "$FIX/think/base")" ]] || fail "base is not main"
  git -C "$wt" apply --index --binary "$FIX/think/patch" || fail "the patch does not apply"
  [[ "$(git -C "$wt" write-tree)" == "$(cat "$FIX/think/tree")" ]] || fail "the patch does not give the tree"
  rm -rf "$wt"
}

scenario think-pr
says 'echo fixed > fix.txt' 'echo "Fixed; gates pass." > "$(dirname "$OUTCOME")/comment.md"' 'printf "type: pr\ntitle: Fix the thing\n" > "$OUTCOME"'
think
[[ "$(outcome)" == $'type: pr\ntitle: Fix the thing' ]] || fail "outcome: $(outcome)"
has "$(cat "$FIX/think/comment.md")" "Fixed; gates pass."
has "$(cat "$FIX/think/patch")" "+fixed"
has "$(cat "$FIX/think/patch")" "looper issue Issue 4 (#4, alpha-looper[bot] pull request)"
patch_gives_tree
untouched approved,bug
has "$(cat "$FIX/prompts")" "working issue #4"
has "$(cat "$FIX"/project/looper-runs/*/prompt.md)" "Your GitHub token is read-only"
pass

scenario think-holds-identity
for c in GH_TOKEN=ghp_x GCP_ID_TOKEN=eyJ.x.y GITLAB_TOKEN=x SOME=github_pat_x BUILD_TRIGGER_TOKEN=x; do
  if looper LOOPER_READER_TOKEN=ghs_read GH_TOKEN= GITHUB_TOKEN= GITLAB_TOKEN= "$c" -- --repo alpha --issue 4 --think "$FIX/think" > "$FIX/out" 2>&1; then
    fail "thought beside $c"
  fi
  has "$(cat "$FIX/out")" "the think job holds an identity"
done
if looper GH_TOKEN= GITHUB_TOKEN= GITLAB_TOKEN= -- --repo alpha --issue 4 --think "$FIX/think" > "$FIX/out" 2>&1; then fail "thought with no reader token"; fi
[[ ! -s "$FIX/prompts" ]] || fail "the model ran"
untouched approved,bug
pass

scenario think-token-can-push
says 'printf "type: pr\n" > "$OUTCOME"'
OUT="$(looper GH_TOKEN= GITHUB_TOKEN= GITLAB_TOKEN= LOOPER_READER_TOKEN=ghs_read -- --repo alpha --issue 4 --think "$FIX/think" 2>&1)" || fail "exited non-zero"
[[ "$(outcome)" == "type: stuck" ]] || fail "outcome: $(outcome)"
has "$(cat "$FIX/think/comment.md")" "can push"
[[ ! -s "$FIX/prompts" ]] || fail "the model ran"
pass

scenario think-gates-fail
says 'echo broken > fix.txt' 'printf "type: pr\n" > "$OUTCOME"'
think LOOPER_GATES='echo "a gate fails"; exit 3'
[[ "$(outcome)" == "type: stuck" ]] || fail "outcome: $(outcome)"
has "$(cat "$FIX/think/comment.md")" "a gate fails"
has "$(cat "$FIX/think/patch")" "+broken"
untouched approved,bug
pass

scenario think-gates-change-the-tree
says 'echo fixed > fix.txt' 'printf "type: pr\n" > "$OUTCOME"'
think LOOPER_GATES='echo out > build-output.txt'
[[ "$(outcome)" == "type: stuck" ]] || fail "outcome: $(outcome)"
has "$(cat "$FIX/think/comment.md")" "not the tested tree"
pass

scenario think-roadmap
says 'echo mine > ROADMAP.md' 'printf "type: pr\n" > "$OUTCOME"'
think
[[ "$(outcome)" == "type: stuck" ]] || fail "outcome: $(outcome)"
has "$(cat "$FIX/think/comment.md")" "ROADMAP.md"
pass

scenario think-question
says 'echo "Which one?" > "$(dirname "$OUTCOME")/comment.md"' 'printf "type: question\n" > "$OUTCOME"'
think
[[ "$(outcome)" == "type: question" ]] || fail "outcome: $(outcome)"
untouched approved,bug
pass

scenario think-blocked
issue tacplus 9 OPEN "" "A compiler floor."
issue alpha 3 CLOSED "" "Done."
says 'printf "type: blocked\nBlocked-by: tacplus-dev/tacplus#9\nBlocked-by: tacplus-dev/tacplus#9\n" > "$OUTCOME"'
think
[[ "$(outcome)" == $'type: blocked\nBlocked-by: tacplus-dev/tacplus#9' ]] || fail "outcome: $(outcome)"
: > "$FIX/claude.sh"; says 'printf "type: blocked\nBlocked-by: #3\n" > "$OUTCOME"'
think
[[ "$(outcome)" == "type: stuck" ]] || fail "a closed blocker: $(outcome)"
untouched approved,bug
pass

scenario think-feature-off-roadmap
issue alpha 4 OPEN approved,feature "Build it."
mkdir -p "$FIX/platform"; echo "# Roadmap" > "$FIX/platform/ROADMAP.md"
think
[[ "$(outcome)" == "type: question" ]] || fail "outcome: $(outcome)"
has "$(cat "$FIX/think/comment.md")" "no ROADMAP.md links"
[[ ! -s "$FIX/prompts" ]] || fail "the model ran"
pass

scenario think-time-limit
says 'echo half > half.txt' '"$ROOT/repo-looper" --repo alpha --issue 4 --checkpoint "half done; the rest left"' 'sleep 30'
think LOOPER_TIMEOUT=6 LOOPER_STOP_EARLY=3
[[ "$(outcome)" == "type: timeout" ]] || fail "outcome: $(outcome)"
has "$(cat "$FIX/think/comment.md")" "half done; the rest left"
has "$(cat "$FIX/think/patch")" "+half"
untouched approved,bug
pass

scenario think-no-outcome
says 'echo half > half.txt'
think
[[ "$(outcome)" == "type: stuck" ]] || fail "outcome: $(outcome)"
has "$(cat "$FIX/think/patch")" "+half"
patch_gives_tree
pass

echo "repo-looper: all scenarios pass"
