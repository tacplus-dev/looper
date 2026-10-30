#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# looper-dispatch run: it starts the looper pipeline only for a repository with
# a ready issue and no looper job of its own created, pending, waiting for its
# resource_group or running (looper#16). A stub `gh` answers from issue JSON
# files, a stub `curl` (the GitLab API) from the scenario's jobs, filtered by the
# URL's scope[] parameters as GitLab does, and records the pipelines it starts.
# It runs as the kicker, a scheduled job in the GitLab pipeline (looper#24):
# `run --for SECONDS` repeats the pass every LOOPER_INTERVAL.
# Run: tests/looper-dispatch.test.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# Issues: $FIX/issues/<repo>-<n>.json ({number,state,labels:[{name}],body,createdAt}).
# Each call is appended to $FIX/gh. `api graphql` answers the aliased
# `repository(...) { issue(number: N) { state } }` queries from the issue files,
# null (and exit 1, as gh does) for a missing one; $FIX/rate-limited refuses it.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cmd="$1 $2"; shift 2
echo "$cmd" >> "$FIX/gh"
if [[ "$cmd" == "api graphql" ]]; then
  [[ ! -e "$FIX/rate-limited" ]] || { echo '{"errors":[{"type":"RATE_LIMIT","message":"API rate limit already exceeded"}]}'; exit 1; }
  q="${2#query=}"; data='{}'; rc=0
  while read -r a r n; do
    f="$FIX/issues/$r-$n.json"
    if [[ -f "$f" ]]; then data="$(jq --arg a "$a" --slurpfile i "$f" '.[$a] = {issue: {state: $i[0].state}}' <<<"$data")"
    else data="$(jq --arg a "$a" '.[$a] = {issue: null}' <<<"$data")"; rc=1; fi
  done < <(grep -oE '[a-z][a-z0-9_]*: repository\(owner: "[^"]+", name: "[^"]+"\) \{ issue\(number: [0-9]+\)' <<<"$q" \
             | sed -E 's/^([a-z0-9_]+): repository\(owner: "[^"]+", name: "([^"]+)"\) \{ issue\(number: ([0-9]+)\)/\1 \2 \3/')
  jq -c '{data: .}' <<<"$data"; exit "$rc"
fi
repo=""; n=""; q="."; label=""; rm=""; body=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) repo="${2##*/}"; shift 2 ;;
    --jq) q="$2"; shift 2 ;;
    --label) label="$2"; shift 2 ;;
    --remove-label) rm="$2"; shift 2 ;;
    --body) body="$2"; shift 2 ;;
    --owner|--state|--limit|--json) shift 2 ;;
    *) n="$1"; shift ;;
  esac
done
f="$FIX/issues/$repo-$n.json"
[[ "$cmd" != "search issues" || ! -e "$FIX/slow" ]] || sleep 1   # $FIX/slow: a pass takes 2 seconds
case "$cmd" in
  "search issues") jq -s --arg l "$label" 'map(select(.state == "OPEN" and any(.labels[]; .name == $l)) | . + {repository: {name: .repo}})' "$FIX"/issues/*.json | jq -r "$q" ;;
  "issue list") jq -s 'map(select(.state == "OPEN" and any(.labels[]; .name == "approved")))' "$FIX/issues/$repo"-*.json | jq -r "$q" ;;
  "issue view") jq -r "$q" "$f" ;;
  "issue edit") t="$(jq --arg l "$rm" '.labels |= map(select(.name != $l))' "$f")"; printf '%s\n' "$t" > "$f" ;;
  "issue comment") printf '%s#%s %s\n' "$repo" "$n" "$body" >> "$FIX/comments" ;;
  *) echo "stub gh: unexpected $cmd" >&2; exit 3 ;;
esac
EOF
# GitLab's API: GET .../jobs?scope[]=... answers $FIX/jobs.json filtered by the
# URL's scopes (no file: HTTP 500), POST .../pipeline (or .../trigger/pipeline)
# records the pipeline it starts in $FIX/started, with its data (`@-`: stdin).
# With -f a failure exits 22. Each request's auth header, method and URL are
# appended to $FIX/gitlab, its arguments to $FIX/argv.
cat > "$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$FIX/argv"
url=""; auth=""; m=GET; data=""; f=""
while [[ $# -gt 0 ]]; do case "$1" in
  -H) auth="${2%%:*}"; shift 2 ;; -X) m="$2"; shift 2 ;; -d|--data) data="$2"; shift 2 ;; --retry) shift 2 ;;
  http*) url="$1"; shift ;; -*f*) f=1; shift ;; *) shift ;;
esac; done
[[ "$data" != @- ]] || data="$(cat)"
echo "$auth $m $url" >> "$FIX/gitlab"
reply() { # code body
  printf '%s\n' "$2"
  [[ "$1" == 200 || "$1" == 201 || -z "$f" ]] || { echo "curl: (22) The requested URL returned error: $1" >&2; exit 22; }
}
[[ -f "$FIX/jobs.json" ]] || { reply 500 '{"message":"500 Internal Server Error"}'; exit 0; }
case "$m $url" in
  "GET "*/jobs\?*) reply 200 "$(jq --arg s "$(grep -oE 'scope\[\]=[a-z_]+' <<<"$url" | cut -d= -f2 | paste -sd, -)" '[.[] | select(.status | IN($s | split(",")[]))]' "$FIX/jobs.json")" ;;
  "POST "*/pipeline) echo "$url $data" >> "$FIX/started"; reply 201 '{"id": 1}' ;;
  *) reply 404 '{"message":"404 Not found"}' ;;
esac
EOF
chmod +x "$TMP/bin/gh" "$TMP/bin/curl"

scenario() { # name: alpha has a ready issue #4
  NAME="$1"; FIX="$TMP/$1"; mkdir -p "$FIX/issues" "$FIX/home"; echo '[]' > "$FIX/jobs.json"
  jq -n '{repo: "alpha", number: 4, state: "OPEN", labels: [{name: "approved"}], body: "Fix it.", createdAt: "2026-10-27T00:00:00Z"}' \
    > "$FIX/issues/alpha-4.json"
}
jobs() { printf '%s\n' "$@" | jq -R 'split(" ") | {name: .[0], status: .[1]}' | jq -s . > "$FIX/jobs.json"; } # "name status"...
run_dispatch() {
  OUT="$(env -u CI_API_V4_URL -u LOOPER_TRIGGER_TOKEN ${TRIGGER:+LOOPER_TRIGGER_TOKEN="$TRIGGER"} LOOPER_LIB="$ROOT/looper-lib.sh" PATH="$TMP/bin:$PATH" HOME="$FIX/home" FIX="$FIX" GITLAB_TOKEN="${TOKEN-tok}" LOOPER_INTERVAL="${INTERVAL:-180}" \
    "$ROOT/looper-dispatch" "$@" 2>&1)"
}
dispatch() { run_dispatch "$@" || { echo "$OUT"; fail "looper-dispatch exited non-zero"; }; }
dispatch_fails() { ! run_dispatch "$@" || fail "looper-dispatch $* succeeded: $OUT"; }
passes() { grep -c ' GET .*/jobs?' "$FIX/gitlab"; }
issue() { # repo n state body label...: another issue
  local r="$1" n="$2" st="$3" b="$4"; shift 4
  jq -n --arg r "$r" --argjson n "$n" --arg st "$st" --arg b "$b" --arg c "2026-10-2${n: -1}T00:00:00Z" '$ARGS.positional as $l |
    {repo: $r, number: $n, state: $st, labels: [$l[] | {name: .}], body: $b, createdAt: $c}' --args "$@" > "$FIX/issues/$r-$n.json"
}
started() { [[ -s "$FIX/started" ]]; }
fail() { echo "FAIL $NAME: $*" >&2; exit 1; }
pass() { echo "ok $NAME"; }
labels() { jq -r '[.labels[].name] | join(",")' "$FIX/issues/$1-$2.json"; }
in_progress() { jq '.labels += [{name: "looper:in-progress"}]' "$FIX/issues/alpha-4.json" > "$FIX/x" && mv "$FIX/x" "$FIX/issues/alpha-4.json"; }

scenario ready-free
jobs "looper-alpha-3 success" "looper-beta-7 waiting_for_resource"
dispatch run
started || fail "no pipeline started: $OUT"
grep -qx 'https://gitlab.com/api/v4/projects/tacplus-dev%2Flooper/pipeline ref=main' "$FIX/started" || fail "started: $(cat "$FIX/started")"
! grep -qv '^PRIVATE-TOKEN ' "$FIX/gitlab" || fail "a request without GITLAB_TOKEN: $(cat "$FIX/gitlab")"
pass

# With the pipeline's trigger token (LOOPER_TRIGGER_TOKEN, looper#25) it starts
# the pipeline through the trigger, which can do nothing else, and GITLAB_TOKEN
# only reads; the trigger token is on no command line.
scenario ready-trigger
jobs "looper-alpha-3 success"
TRIGGER=glptt-secret dispatch run
grep -qx 'https://gitlab.com/api/v4/projects/tacplus-dev%2Flooper/trigger/pipeline token=glptt-secret&ref=main' "$FIX/started" \
  || fail "started: $(cat "$FIX/started")"
grep -qx ' POST https://gitlab.com/api/v4/projects/tacplus-dev%2Flooper/trigger/pipeline' "$FIX/gitlab" || fail "requests: $(cat "$FIX/gitlab")"
! grep -q '^PRIVATE-TOKEN POST' "$FIX/gitlab" || fail "started with GITLAB_TOKEN: $(cat "$FIX/gitlab")"
! grep -q glptt-secret "$FIX/argv" || fail "the trigger token on the command line: $(cat "$FIX/argv")"
pass

# The kicker has no gh or glab login: without GITLAB_TOKEN it does nothing.
scenario no-token
TOKEN="" dispatch_fails run
grep -q GITLAB_TOKEN <<<"$OUT" || fail "log: $OUT"
[[ ! -e "$FIX/gitlab" ]] || fail "asked GitLab: $(cat "$FIX/gitlab")"
pass

# GitLab unreadable: no job can be told busy or gone, so the pass fails, and
# neither starts a pipeline nor releases an issue.
scenario gitlab-down
in_progress
rm "$FIX/jobs.json"
dispatch_fails run
! started || fail "started a pipeline with GitLab down"
[[ "$(labels alpha 4)" == approved,looper:in-progress ]] || fail "labels $(labels alpha 4)"
pass

for st in created pending waiting_for_resource running; do
  scenario "busy-$st"
  jobs "looper-alpha-4 $st"
  dispatch run
  ! started || fail "started a pipeline while looper-alpha-4 is $st"
  grep -q 'nothing to start' <<<"$OUT" || fail "a pass that starts nothing says nothing: $OUT"
  pass
done

scenario plan-under-way
jobs "looper-plan waiting_for_resource"
dispatch run
! started || fail "started a pipeline while a plan waits"
grep -q 'looper-plan under way' <<<"$OUT" || fail "log: $OUT"
pass

scenario status-busy
jobs "looper-alpha-4 waiting_for_resource"
dispatch status
grep -q "alpha: ready 4 (busy)" <<<"$OUT" || fail "status: $OUT"
pass

# A run killed after it labelled its issue (looper#20) leaves looper:in-progress
# with no job holding it: the pass removes the label, says so on the issue, and
# starts the pipeline, whose job resumes the issue from its checkpoint.
scenario orphan-released
in_progress
jobs "looper-alpha-4 failed" "looper-beta-7 running"
dispatch run
[[ "$(labels alpha 4)" == approved ]] || fail "labels $(labels alpha 4)"
grep -q '^alpha#4 .*no looper job' "$FIX/comments" || fail "comments: $(cat "$FIX/comments" 2>/dev/null)"
started || fail "no pipeline started: $OUT"
grep -q "alpha#4" <<<"$OUT" || fail "log: $OUT"
pass

# A job of the repository created, pending, waiting or running holds the label.
for st in created pending waiting_for_resource running; do
  scenario "orphan-held-$st"
  in_progress
  jobs "looper-alpha-9 $st"
  dispatch run
  [[ "$(labels alpha 4)" == approved,looper:in-progress ]] || fail "labels $(labels alpha 4)"
  [[ ! -s "$FIX/comments" ]] || fail "commented: $(cat "$FIX/comments")"
  pass
done

# Blocked-by: ready only when every issue it names is closed; a missing one
# (or a pull request, which is no issue) holds it as an open one does.
scenario blocked-open
issue alpha 4 OPEN $'Fix it.\nBlocked-by: #5' approved
issue alpha 5 OPEN "The other half."
dispatch run
! started || fail "started a pipeline for a blocked issue"
pass

scenario blocked-closed
issue alpha 4 OPEN $'Fix it.\r\n  blocked-by: tacplus-dev/beta#2\r\nBlocked-by: #5' approved
issue alpha 5 CLOSED "Done."
issue beta 2 CLOSED "Done."
dispatch run
started || fail "no pipeline started: $OUT"
pass

scenario blocked-missing
issue alpha 4 OPEN $'Fix it.\nBlocked-by: #9' approved
dispatch run
! started || fail "started a pipeline for an issue blocked by a missing one"
pass

for held in looper:stuck needs-decision; do
  scenario "held-$held"
  issue alpha 4 OPEN "Fix it." approved "$held"
  dispatch run
  ! started || fail "started a pipeline for an issue labelled $held"
  pass
done

# GitHub refusing (its rate limit, say): no issue can be told ready, the pass
# fails and starts nothing.
scenario rate-limited
issue alpha 4 OPEN $'Fix it.\nBlocked-by: #5' approved
issue alpha 5 CLOSED "Done."
touch "$FIX/rate-limited"
dispatch_fails run
! started || fail "started a pipeline with GitHub refusing"
pass

# A pass reads GitHub for the whole org at once: its cost does not grow with
# the issues (a request per issue and per blocker came to about 270 a pass,
# past GitHub's 5000 an hour at one every 3 minutes; looper#24).
scenario cost
for r in alpha beta gamma; do
  for n in 1 2 3 5 6 7; do issue "$r" "$n" OPEN "Blocked-by: #$((n + 1))" approved; done
done
issue gamma 8 OPEN "Not approved."
dispatch run
[[ "$(wc -l < "$FIX/gh")" -le 4 ]] || fail "$(wc -l < "$FIX/gh") GitHub calls: $(sort "$FIX/gh" | uniq -c)"
grep -q 'started the .* (alpha has a ready issue)' <<<"$OUT" || fail "log: $OUT"
pass

scenario status-oldest
issue alpha 2 OPEN "Older." approved
issue beta 3 OPEN "Blocked-by: #4" approved
issue beta 4 OPEN "Open."
dispatch status
grep -q "^alpha: ready 2\$" <<<"$OUT" || fail "status: $OUT"
! grep -q "^beta" <<<"$OUT" || fail "status: $OUT"
pass

# Priority labels across repositories (looper#31): a repository whose next
# ready issue is priority:high comes before the others, then those whose next
# is unlabelled, then priority:low; oldest first within each. A blocked
# priority:high issue makes nothing urgent. `ready` lists them so (the plan's
# order), `status` too, and a pass names the first free one.
scenario priority-order
rm "$FIX/issues/alpha-4.json"
issue alpha 2 OPEN "Unlabelled, oldest." approved
issue beta 8 OPEN "High." approved priority:high
issue beta 3 OPEN "Older, unlabelled." approved
issue gamma 1 OPEN "Low, oldest of all." approved priority:low
issue delta 9 OPEN "High, newest." approved priority:high
issue eps 5 OPEN "Unlabelled." approved
issue eps 4 OPEN $'High, blocked.\nBlocked-by: #6' approved priority:high
issue eps 6 OPEN "Open."
dispatch ready
[[ "$(paste -sd' ' <<<"$OUT")" == "beta 8 delta 9 alpha 2 eps 5 gamma 1" ]] || fail "ready: $(paste -sd' ' <<<"$OUT")"
[[ ! -e "$FIX/gitlab" ]] || fail "ready asked GitLab: $(cat "$FIX/gitlab")"
dispatch status
[[ "$(grep ': ready' <<<"$OUT" | paste -sd' ')" == "beta: ready 8 delta: ready 9 alpha: ready 2 eps: ready 5 gamma: ready 1" ]] || fail "status: $OUT"
dispatch run
grep -q 'started the .* (beta has a ready issue)' <<<"$OUT" || fail "log: $OUT"
pass

scenario priority-busy
issue beta 8 OPEN "High." approved priority:high
jobs "looper-beta-8 running"
dispatch run
grep -q 'started the .* (alpha has a ready issue)' <<<"$OUT" || fail "log: $OUT"
pass

# The kicker (looper#24): an hourly scheduled job, since gitlab.com schedules
# run at most hourly here, that repeats the pass every LOOPER_INTERVAL for
# --for SECONDS, so a ready issue waits one interval, not one schedule.
scenario loop
INTERVAL=1 dispatch run --for 2
[[ "$(passes)" -ge 2 ]] || fail "$(passes) pass(es): $OUT"
[[ "$(passes)" -le 4 ]] || fail "$(passes) passes in 2 seconds: $OUT"
started || fail "no pipeline started: $OUT"
pass

# The interval is from one pass's start to the next's: a slow pass does not
# stretch it.
scenario loop-slow-pass
touch "$FIX/slow"
INTERVAL=3 dispatch run --for 6
[[ "$(passes)" -ge 3 ]] || fail "$(passes) pass(es) of 2 seconds in 6 seconds, every 3: $OUT"
pass

# A pass that fails (GitLab down) does not end the loop; the job fails at its
# end, so the schedule shows it.
scenario loop-failing-pass
in_progress
rm "$FIX/jobs.json"
INTERVAL=1 dispatch_fails run --for 2
[[ "$(passes)" -ge 2 ]] || fail "$(passes) pass(es): $OUT"
grep -q 'pass failed' <<<"$OUT" || fail "log: $OUT"
! started || fail "started a pipeline with GitLab down"
[[ "$(labels alpha 4)" == approved,looper:in-progress ]] || fail "labels $(labels alpha 4)"
pass

# Nothing runs on the Mac any more: there is no launchd install.
scenario no-install
dispatch_fails install
[[ ! -e "$FIX/home/Library" ]] || fail "installed something"
pass

echo "looper-dispatch: all scenarios pass"
