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
repo=""; n=""; q="."; label=""; rm=""; body=""; vis=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) repo="${2##*/}"; shift 2 ;;
    --visibility) vis="$2"; shift 2 ;;
    --jq) q="$2"; shift 2 ;;
    --label) label="$2"; shift 2 ;;
    --remove-label) rm="$2"; shift 2 ;;
    --body) body="$2"; shift 2 ;;
    --owner|--state|--limit|--json) shift 2 ;;
    *) n="$1"; shift ;;
  esac
done
f="$FIX/issues/$repo-$n.json"
# $FIX/slow: a pass (its one search for approved issues) takes that many
# seconds on the fake clock, its start and end appended to $FIX/passes.
if [[ "$cmd $label" == "search issues approved" && -e "$FIX/slow" ]]; then
  t="$(cat "$FIX/clock")"; e="$((t + $(cat "$FIX/slow")))"
  echo "$t $e" >> "$FIX/passes"; echo "$e" > "$FIX/clock"
fi
case "$cmd" in
  # $FIX/private: the org's private repositories, one a line (--visibility public leaves them out).
  "search issues") jq -s --arg l "$label" --arg vis "$vis" --arg priv "$(cat "$FIX/private" 2>/dev/null || true)" \
                     'map(select(.state == "OPEN" and any(.labels[]; .name == $l)) | . + {repository: {name: .repo}})
                      | map(select($vis != "public" or (.repo | IN($priv | split("\n")[]) | not)))' "$FIX"/issues/*.json | jq -r "$q" ;;
  "issue list") jq -s 'map(select(.state == "OPEN" and any(.labels[]; .name == "approved")))' "$FIX/issues/$repo"-*.json | jq -r "$q" ;;
  "issue view") jq -r "$q" "$f" ;;
  "repo list") jq -R '{name: .}' "$FIX/repos" | jq -s . | jq -r "$q" ;;   # $FIX/repos: the org's, one a line
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
# A fake clock (looper#78), for a scenario that writes $FIX/clock: `date +%s`
# reads it and `sleep N` moves it on N seconds, at once. Without it both are
# the real ones.
cat > "$TMP/bin/date" <<'EOF'
#!/usr/bin/env bash
[[ -e "${FIX:-}/clock" && "$*" == +%s ]] || exec /usr/bin/env PATH="${PATH#*:}" date "$@"
cat "$FIX/clock"
EOF
cat > "$TMP/bin/sleep" <<'EOF'
#!/usr/bin/env bash
[[ -e "${FIX:-}/clock" ]] || exec /usr/bin/env PATH="${PATH#*:}" sleep "$@"
[[ "$1" =~ ^[0-9]+$ ]] || { echo "stub sleep: $1" >&2; exit 3; }
echo "$(( $(cat "$FIX/clock") + $1 ))" > "$FIX/clock"
EOF
chmod +x "$TMP/bin/gh" "$TMP/bin/curl" "$TMP/bin/date" "$TMP/bin/sleep"

scenario() { # name: alpha has a ready issue #4
  NAME="$1"; FIX="$TMP/$1"; mkdir -p "$FIX/issues" "$FIX/home"; echo '[]' > "$FIX/jobs.json"
  jq -n '{repo: "alpha", number: 4, state: "OPEN", labels: [{name: "approved"}], body: "Fix it.", createdAt: "2026-10-27T00:00:00Z"}' \
    > "$FIX/issues/alpha-4.json"
}
jobs() { printf '%s\n' "$@" | jq -R 'split(" ") | {name: .[0], status: .[1]}' | jq -s . > "$FIX/jobs.json"; } # "name status"...
run_dispatch() {
  OUT="$(env -u CI_API_V4_URL -u CI_PIPELINE_SOURCE -u LOOPER_TRIGGER_TOKEN ${TRIGGER:+LOOPER_TRIGGER_TOKEN="$TRIGGER"} ${CAPS:+LOOPER_CAPS="$CAPS"} LOOPER_LIB="$ROOT/looper-lib.sh" PATH="$TMP/bin:$PATH" HOME="$FIX/home" FIX="$FIX" GITLAB_TOKEN="${TOKEN-tok}" LOOPER_INTERVAL="${INTERVAL:-180}" \
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

# The issue's own report job (looper#70) created, pending, waiting or running holds the label.
for st in created pending waiting_for_resource running; do
  scenario "orphan-held-$st"
  in_progress
  jobs "looper-alpha-4 $st"
  dispatch run
  [[ "$(labels alpha 4)" == approved,looper:in-progress ]] || fail "labels $(labels alpha 4)"
  [[ ! -s "$FIX/comments" ]] || fail "commented: $(cat "$FIX/comments")"
  pass
done

# Another issue's report, or the manager, does not: one job per issue.
scenario orphan-released-beside-others
in_progress
jobs "looper-alpha-9 running" "looper-alpha-manager running"
dispatch run
[[ "$(labels alpha 4)" == approved ]] || fail "labels $(labels alpha 4)"
started || fail "no pipeline started: $OUT"
pass

# The kicker (looper#70) starts the pipeline for a ready issue with no report
# job of its own while its repository is under its cap (caps.yaml), not at it;
# and for commits queued to land (looper:landing) with no manager job.
scenario kick-under-cap
issue alpha 5 OPEN "Go." approved
jobs "looper-alpha-4 running" "looper-alpha-7 running"
printf 'default: 3\n' > "$FIX/caps.yaml"
CAPS="$FIX/caps.yaml" dispatch run
started || fail "no pipeline started under the cap: $OUT"
grep -q 'alpha#5 is ready' <<<"$OUT" || fail "log: $OUT"
pass

scenario kick-at-cap
issue alpha 5 OPEN "Go." approved
jobs "looper-alpha-4 running" "looper-alpha-7 running" "looper-alpha-8 pending"
printf 'default: 3\n' > "$FIX/caps.yaml"
CAPS="$FIX/caps.yaml" dispatch run
! started || fail "started a pipeline at the cap: $OUT"
# Each pass logs each repository's reports against its cap, the ready issues
# waiting at it and the lands queued: the nightly recap's numbers (looper#72).
grep -q 'capacity: alpha reports=3 cap=3 waiting=5 landing=0$' <<<"$OUT" || fail "capacity: $OUT"
pass

scenario kick-landing
issue alpha 4 OPEN "Done, its land queued." approved looper:landing
dispatch run
started || fail "no pipeline for a queued land without a manager: $OUT"
grep -q 'queued to land and no manager' <<<"$OUT" || fail "log: $OUT"
grep -q 'capacity: alpha reports=0 cap=3 waiting= landing=1$' <<<"$OUT" || fail "capacity: $OUT"
rm "$FIX/started"
jobs "looper-alpha-manager running"
dispatch run
! started || fail "started a pipeline while the manager runs: $OUT"
pass

# The plan (looper#70): a report job per ready issue, in order, up to the
# repository's cap less its active reports (caps.yaml: tacplus 6, the others
# 3), none for an issue whose report is active, each one at a time per issue;
# and the repository's manager, the only job on its main's resource group,
# unless one already waits to start, ahead of its reports (looper#75): the
# runner starts a pool's pending jobs in id order, the plan's order, and a
# manager behind reports it has no VM for left their work unmerged for hours.
scenario plan-reports-up-to-cap
for k in 5 6 7 8; do issue alpha "$k" OPEN "Go." approved; done
for k in 1 2 3 4 5 6 7; do issue tacplus "$k" OPEN "Go." approved; done
jobs "looper-alpha-4 running" "looper-alpha-manager running"
printf '#!/usr/bin/env bash\nexec "%s/repo-looper" "$@"\n' "$ROOT" > "$TMP/bin/repo-looper"; chmod +x "$TMP/bin/repo-looper"
plan_jobs() { PLAN="$(env -u CI_PIPELINE_SOURCE ${CAPS:+LOOPER_CAPS="$CAPS"} LOOPER_LIB="$ROOT/looper-lib.sh" PATH="$TMP/bin:$PATH" HOME="$FIX/home" FIX="$FIX" GITLAB_TOKEN=tok \
  "$ROOT/looper-dispatch" plan 2>"$FIX/err")" || fail "plan failed: $(cat "$FIX/err")"; }
plan_jobs
[[ "$(grep -oE '^looper-alpha-[0-9a-z]+' <<<"$PLAN" | paste -sd' ')" == "looper-alpha-manager looper-alpha-5 looper-alpha-6" ]] \
  || fail "alpha's jobs: $(grep '^looper-' <<<"$PLAN")"
[[ "$(grep -cE '^looper-tacplus-[0-9]+:' <<<"$PLAN")" == 6 ]] || fail "tacplus's reports: $(grep '^looper-' <<<"$PLAN")"
grep -qx 'looper-tacplus-manager:' <<<"$PLAN" || fail "no tacplus manager: $PLAN"
# Its cap (6) above its VMs: the manager is ahead of every report of its repository.
[[ "$(grep -E '^looper-tacplus-' <<<"$PLAN" | head -1)" == 'looper-tacplus-manager:' ]] || fail "tacplus's manager behind its reports: $(grep '^looper-' <<<"$PLAN")"
# No manager is behind any report.
[[ "$(grep -E '^looper-' <<<"$PLAN" | awk '/-manager:$/ {if (r) bad=1; next} {r=1} END {print bad+0}')" == 0 ]] \
  || fail "a manager behind a report: $(grep '^looper-' <<<"$PLAN")"
grep -q 'alpha#7 waits: alpha is at its cap of 3 reports' "$FIX/err" || fail "log: $(cat "$FIX/err")"
group_of() { awk -v j="$1:" '$0 == j {f=1; next} /^[^ ]/ {f=0} f && /^  resource_group:/ {print $2}' <<<"$PLAN"; }
script_of() { awk -v j="$1:" '$0 == j {f=1; next} /^[^ ]/ {f=0} f && /^    - / {sub(/^    - /, ""); print}' <<<"$PLAN"; }
[[ "$(group_of looper-alpha-5)" == looper-alpha-5 ]] || fail "alpha-5's group: $(group_of looper-alpha-5)"
[[ "$(group_of looper-alpha-manager)" == looper-alpha-main ]] || fail "the manager's group: $(group_of looper-alpha-manager)"
[[ "$(script_of looper-alpha-5)" == "repo-looper --repo alpha --issue 5" ]] || fail "alpha-5's script: $(script_of looper-alpha-5)"
[[ "$(script_of looper-alpha-manager)" == "repo-looper --repo alpha --manage" ]] || fail "the manager's script: $(script_of looper-alpha-manager)"
# A manager already waiting to start serves the new reports.
jobs "looper-alpha-4 running" "looper-alpha-manager waiting_for_resource"
plan_jobs
! grep -qx 'looper-alpha-manager:' <<<"$PLAN" || fail "a second manager waits: $PLAN"
# A report that yielded to its pending manager (looper#75) is planned again,
# after it: the manager is not planned twice.
jobs "looper-alpha-4 success" "looper-alpha-manager pending"
plan_jobs
grep -qx 'looper-alpha-4:' <<<"$PLAN" || fail "the yielded report not planned again: $PLAN"
! grep -qx 'looper-alpha-manager:' <<<"$PLAN" || fail "a second manager waits: $PLAN"
jobs "looper-alpha-4 running" "looper-alpha-manager waiting_for_resource"
# A cap from the committed file.
printf 'default: 1\nalpha: 4\n' > "$FIX/caps.yaml"
CAPS="$FIX/caps.yaml" plan_jobs
[[ "$(grep -cE '^looper-alpha-[0-9]+:' <<<"$PLAN")" == 3 ]] || fail "alpha's reports at a cap of 4: $(grep '^looper-' <<<"$PLAN")"
[[ "$(grep -cE '^looper-tacplus-[0-9]+:' <<<"$PLAN")" == 1 ]] || fail "tacplus's at the default 1: $(grep '^looper-' <<<"$PLAN")"
# The committed caps: tacplus 6, the others 3.
[[ "$(LOOPER_CAPS="$ROOT/caps.yaml" bash -c "source '$ROOT/looper-lib.sh'; repo_cap tacplus; repo_cap kernel" | paste -sd' ')" == "6 3" ]] \
  || fail "caps.yaml's caps"
pass

# A queued land alone (looper:landing, no ready issue) plans the manager alone.
scenario plan-manager-for-landing
jq '.labels += [{name: "looper:landing"}]' "$FIX/issues/alpha-4.json" > "$FIX/x" && mv "$FIX/x" "$FIX/issues/alpha-4.json"
PLAN="$(env -u CI_PIPELINE_SOURCE LOOPER_LIB="$ROOT/looper-lib.sh" PATH="$TMP/bin:$PATH" HOME="$FIX/home" FIX="$FIX" GITLAB_TOKEN=tok \
  "$ROOT/looper-dispatch" plan 2>/dev/null)" || fail "plan failed"
[[ "$(grep -E '^looper-' <<<"$PLAN" | paste -sd' ')" == "looper-alpha-manager:" ]] || fail "planned: $(grep '^looper-' <<<"$PLAN")"
pass

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
grep -q 'started the .* (alpha#4 is ready)' <<<"$OUT" || fail "log: $OUT"
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
grep -q 'started the .* (beta#[0-9]* is ready)' <<<"$OUT" || fail "log: $OUT"
pass

scenario priority-busy
issue beta 8 OPEN "High." approved priority:high
jobs "looper-beta-8 running"
dispatch run
grep -q 'started the .* (alpha#[0-9]* is ready)' <<<"$OUT" || fail "log: $OUT"
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
# stretch it, and a pass slower than the interval delays the next, which never
# overlaps it. On a fake clock, since real seconds failed on a loaded runner
# (looper#78), and 20 times over to show it holds.
for i in $(seq 20); do
  scenario loop-slow-pass
  echo 1000 > "$FIX/clock"; echo 2 > "$FIX/slow"
  INTERVAL=3 dispatch run --for 6
  [[ "$(paste -sd' ' "$FIX/passes")" == "1000 1002 1003 1005 1006 1008" ]] \
    || fail "run $i: passes (start end) of 2 seconds every 3 for 6: $(paste -sd' ' "$FIX/passes"): $OUT"
  [[ "$(passes)" -eq 3 ]] || fail "run $i: $(passes) passes: $OUT"
  rm -rf "$FIX"
  scenario loop-slow-pass
  echo 1000 > "$FIX/clock"; echo 4 > "$FIX/slow"
  INTERVAL=3 dispatch run --for 9
  [[ "$(paste -sd' ' "$FIX/passes")" == "1000 1004 1004 1008 1008 1012" ]] \
    || fail "run $i: passes (start end) of 4 seconds every 3 for 9: $(paste -sd' ' "$FIX/passes"): $OUT"
  rm -rf "$FIX"
done
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

# Per-repository runner tags (looper#55): a repository's job takes
# LOOPER_JOB_TAGS_<repo> (`-` as `_`), else LOOPER_JOB_TAGS, else the default;
# so tacplus's jobs go to the 16-CPU pool and every other repository's stay.
scenario plan-tags
issue tacplus 5 OPEN "Go." approved
issue fleet-lab 6 OPEN "Go." approved
tags_of() { awk -v j="looper-$1:" '$0 == j {f=1; next} /^[^ ]/ {f=0} f && /^  tags:/ {sub(/^  tags: /, ""); print}' <<<"$PLAN"; }
plan_with() { PLAN="$(env -u CI_PIPELINE_SOURCE "$@" LOOPER_LIB="$ROOT/looper-lib.sh" PATH="$TMP/bin:$PATH" HOME="$FIX/home" FIX="$FIX" GITLAB_TOKEN=tok \
  "$ROOT/looper-dispatch" plan 2>/dev/null)" || fail "plan failed"; }
plan_with -u LOOPER_JOB_TAGS LOOPER_JOB_TAGS_tacplus="arm64, autoscale-16"
[[ "$(tags_of tacplus-5)" == "[arm64, autoscale-16]" ]] || fail "tacplus: $(tags_of tacplus-5): $PLAN"
[[ "$(tags_of alpha-4)" == "[arm64, autoscale]" ]] || fail "alpha: $(tags_of alpha-4)"
[[ "$(tags_of fleet-lab-6)" == "[arm64, autoscale]" ]] || fail "fleet-lab: $(tags_of fleet-lab-6)"
plan_with LOOPER_JOB_TAGS="arm64, other" LOOPER_JOB_TAGS_fleet_lab="arm64, lab"
[[ "$(tags_of fleet-lab-6)" == "[arm64, lab]" ]] || fail "fleet-lab's override: $(tags_of fleet-lab-6)"
[[ "$(tags_of tacplus-5)" == "[arm64, other]" ]] || fail "tacplus without its override: $(tags_of tacplus-5)"
[[ "$(tags_of alpha-4)" == "[arm64, other]" ]] || fail "alpha: $(tags_of alpha-4)"
pass

# tacplus-dev's pipeline (looper#56): ci/tacplus-dev.gitlab-ci.yml's
# looper-plan runs `looper-dispatch plan` with its job's variables, and plans
# what the hub's inline script (tests/tacplus-dev-plan.inline.sh) planned for
# the same org: on a schedule a scan job per repository, otherwise a job per
# repository with a ready issue, each with its timeout, tags, resource_group,
# retry, artifacts, LOOPER_WORK and the git identity. The fixture's ready
# issues are in the same order both ways (oldest first is alphabetical here;
# the plan puts priority:high first, looper#31).
scenario tacplus-dev-plan
issue beta 2 OPEN $'Blocked.\nBlocked-by: #3' approved
issue beta 3 OPEN "Not approved."
issue gamma 1 OPEN "Held." approved looper:in-progress
issue fleet-lab 8 OPEN "Go." approved
issue tacplus 9 OPEN $'Go.\nTimeout: 7h' approved
printf '%s\n' alpha beta fleet-lab gamma tacplus > "$FIX/repos"
cat > "$TMP/bin/repo-looper" <<EOF
#!/usr/bin/env bash
exec "$ROOT/repo-looper" "\$@"
EOF
chmod +x "$TMP/bin/repo-looper"
# looper-plan's variables in the pipeline file, as KEY=value.
mapfile -t plan_vars < <(awk '/^looper-plan:/ {j=1; next} /^[^ #]/ {j=0} j && /^  [a-z]/ {v=0} j && /^  variables:/ {v=1; next}
  j && v && /^    [A-Za-z_]+: / {k=$1; sub(/:$/, "", k); sub(/^    [A-Za-z_]+: /, ""); gsub(/^"|"$/, ""); print k "=" $0}' "$ROOT/ci/tacplus-dev.gitlab-ci.yml")
printf '%s\n' "${plan_vars[@]}" | grep -qx 'LOOPER_JOB_TAGS_tacplus=arm64, autoscale-16' || fail "looper-plan's variables: ${plan_vars[*]}"
grep -qx '    - looper-dispatch plan > looper-jobs.yml' "$ROOT/ci/tacplus-dev.gitlab-ci.yml" || fail "looper-plan does not run looper-dispatch plan"
CLEAN=(-u CI_API_V4_URL -u CI_PROJECT_ID -u CI_JOB_ID -u LOOPER_RUNNING_COPY -u LOOPER_SELF -u LOOPER_JOB_TAGS -u LOOPER_JOB_IMAGE
       -u GIT_AUTHOR_NAME -u GIT_AUTHOR_EMAIL -u GIT_COMMITTER_NAME -u GIT_COMMITTER_EMAIL)
for source in schedule api; do
  mkdir -p "$FIX/inline-$source"
  (cd "$FIX/inline-$source" && env "${CLEAN[@]}" LOOPER_ORG=tacplus-dev LOOPER_JOB_TAGS_tacplus="arm64, autoscale-16" CI_PIPELINE_SOURCE="$source" \
     LOOPER_LIB="$ROOT/looper-lib.sh" PATH="$TMP/bin:$PATH" HOME="$FIX/home" FIX="$FIX" bash "$ROOT/tests/tacplus-dev-plan.inline.sh" >/dev/null 2>&1) \
    || fail "the inline plan failed ($source)"
  got="$(env "${CLEAN[@]}" "${plan_vars[@]}" CI_PIPELINE_SOURCE="$source" LOOPER_LIB="$ROOT/looper-lib.sh" PATH="$TMP/bin:$PATH" \
           HOME="$FIX/home" FIX="$FIX" GITLAB_TOKEN=tok "$ROOT/looper-dispatch" plan 2>/dev/null)" || fail "plan failed ($source)"
  # The scan is as it was; the rest is a report per issue and a manager per repository (looper#70).
  [[ "$source" != schedule ]] || diff -u "$FIX/inline-$source/looper-jobs.yml" <(printf '%s\n' "$got") >&2 || fail "the plan ($source) is not the inline one's"
done
[[ "$(grep -c '^looper-scan-' "$FIX/inline-schedule/looper-jobs.yml")" == 5 ]] || fail "scheduled: $(cat "$FIX/inline-schedule/looper-jobs.yml")"
[[ "$(grep -E '^looper-' "$FIX/inline-api/looper-jobs.yml" | paste -sd' ')" == "looper-alpha-4: looper-fleet-lab-8: looper-tacplus-9:" ]] \
  || fail "kicked: $(cat "$FIX/inline-api/looper-jobs.yml")"
[[ "$(grep -E '^looper-' <<<"$got" | paste -sd' ')" == "looper-alpha-manager: looper-fleet-lab-manager: looper-tacplus-manager: looper-alpha-4: looper-fleet-lab-8: looper-tacplus-9:" ]] \
  || fail "planned: $(grep -E '^looper-' <<<"$got")"
# Each report's job is the inline one's but for its resource group, its issue's own.
for j in alpha-4 fleet-lab-8 tacplus-9; do
  job_of() { awk -v j="looper-$j:" '$0 == j {f=1; print; next} /^[^ ]/ {f=0} f' "$@"; }
  diff -u <(job_of "$FIX/inline-api/looper-jobs.yml" | sed "s/resource_group: looper-.*/resource_group: looper-$j/") <(printf '%s\n' "$got" | job_of) >&2 \
    || fail "looper-$j is not the inline one's"
done
grep -qx '  tags: \[arm64, autoscale-16\]' <<<"$got" || fail "tacplus's tags: $got"
pass

# The plan when GitLab's jobs cannot be read: every repository with a ready
# issue, as before looper#16, not none.
scenario plan-gitlab-down
rm "$FIX/jobs.json"
PLAN="$(env -u CI_PIPELINE_SOURCE LOOPER_LIB="$ROOT/looper-lib.sh" PATH="$TMP/bin:$PATH" HOME="$FIX/home" FIX="$FIX" GITLAB_TOKEN=tok \
  "$ROOT/looper-dispatch" plan 2>"$FIX/err")" || fail "plan failed: $(cat "$FIX/err")"
grep -qx 'looper-alpha-4:' <<<"$PLAN" || fail "alpha not planned: $PLAN"
grep -q 'could not read' "$FIX/err" || fail "log: $(cat "$FIX/err")"
pass

# Without a git identity in its environment (SeaBeam's instance: project CI
# variables, the child's too), the plan sets none; with no repository the
# schedule plans the one job that says so.
scenario plan-no-identity
: > "$FIX/repos"
PLAN="$(env -u GIT_AUTHOR_NAME -u GIT_AUTHOR_EMAIL -u GIT_COMMITTER_NAME -u GIT_COMMITTER_EMAIL CI_PIPELINE_SOURCE=schedule \
  LOOPER_LIB="$ROOT/looper-lib.sh" PATH="$TMP/bin:$PATH" HOME="$FIX/home" FIX="$FIX" GITLAB_TOKEN=tok "$ROOT/looper-dispatch" plan 2>/dev/null)" \
  || fail "plan failed"
! grep -qE 'GIT_(AUTHOR|COMMITTER)' <<<"$PLAN" || fail "an identity: $PLAN"
[[ "$(grep -c '^[a-z]' <<<"$PLAN")" == 2 ]] && grep -qx 'looper-none:' <<<"$PLAN" || fail "no repository: $PLAN"
rm "$FIX/repos"
! env CI_PIPELINE_SOURCE=schedule LOOPER_LIB="$ROOT/looper-lib.sh" PATH="$TMP/bin:$PATH" HOME="$FIX/home" FIX="$FIX" GITLAB_TOKEN=tok \
  "$ROOT/looper-dispatch" plan >/dev/null 2>&1 || fail "planned a schedule with the org's repositories unread"
pass

# A private repository's issues are no report's (looper#83): main's ruleset
# needs GitHub Team there. Its ready issue starts nothing and is planned for
# no report, unless LOOPER_PRIVATE_REPORTS=1 (Jody's call).
scenario private-skipped
rm "$FIX/issues/alpha-4.json"
issue fleet 2 OPEN "Private." approved
issue beta 3 OPEN "Public." approved
echo fleet > "$FIX/private"
dispatch ready
[[ "$(paste -sd' ' <<<"$OUT")" == "beta 3" ]] || fail "ready: $(paste -sd' ' <<<"$OUT")"
PLAN="$(env -u CI_PIPELINE_SOURCE LOOPER_LIB="$ROOT/looper-lib.sh" PATH="$TMP/bin:$PATH" HOME="$FIX/home" FIX="$FIX" GITLAB_TOKEN=tok \
  "$ROOT/looper-dispatch" plan 2>/dev/null)" || fail "plan failed"
grep -qx 'looper-beta-3:' <<<"$PLAN" && ! grep -q 'looper-fleet' <<<"$PLAN" || fail "plan: $PLAN"
rm "$FIX/issues/beta-3.json"
dispatch run
! started || fail "started a pipeline for a private repository's issue: $OUT"
OUT="$(env LOOPER_PRIVATE_REPORTS=1 LOOPER_LIB="$ROOT/looper-lib.sh" PATH="$TMP/bin:$PATH" HOME="$FIX/home" FIX="$FIX" "$ROOT/looper-dispatch" ready 2>&1)"
[[ "$OUT" == "fleet 2" ]] || fail "with LOOPER_PRIVATE_REPORTS=1: $OUT"
pass

# The apps (looper#83): the kicker and the plan hold the report app's token
# (looper-token, here a stub), never a personal one; each planned job gets
# its id_token and the environment GCP's binding of each app's key names.
printf '%s\n' '#!/usr/bin/env bash' 'case "$1" in' \
  '  configured) [[ -n "${LOOPER_REPORT_APP_ID:-}" ]] ;;' \
  '  start) echo "start $2" >> "$FIX/token"; mkdir -p "$3"; echo 0 ;;' \
  '  *) exit 3 ;;' 'esac' > "$TMP/bin/looper-token-stub"
chmod +x "$TMP/bin/looper-token-stub"
APPS=(LOOPER_TOKEN="$TMP/bin/looper-token-stub" LOOPER_REPORT_APP_ID=7 GCP_WIF_PROVIDER=projects/1/locations/global/workloadIdentityPools/p/providers/r)
scenario apps-plan
issue alpha 6 OPEN "Land it." looper:landing
PLAN="$(env -u CI_PIPELINE_SOURCE -u GH_TOKEN "${APPS[@]}" LOOPER_LIB="$ROOT/looper-lib.sh" PATH="$TMP/bin:$PATH" HOME="$FIX/home" FIX="$FIX" GITLAB_TOKEN=tok \
  "$ROOT/looper-dispatch" plan 2>"$FIX/err")" || fail "plan failed: $(cat "$FIX/err")"
[[ "$(cat "$FIX/token")" == "start report" ]] || fail "the plan's token: $(cat "$FIX/token" 2>/dev/null)"
for j in looper-alpha-4:looper-report looper-alpha-manager:looper-manager; do
  awk -v j="${j%%:*}:" '$0 == j { on = 1; next } /^[a-z]/ { on = 0 } on' <<<"$PLAN" > "$FIX/job"
  grep -qx '      aud: https://iam.googleapis.com/projects/1/locations/global/workloadIdentityPools/p/providers/r' "$FIX/job" &&
    grep -qx '  id_tokens:' "$FIX/job" && grep -qx "  environment: {name: ${j#*:}, action: prepare}" "$FIX/job" || fail "${j%%:*}: $(cat "$FIX/job")"
done
echo alpha > "$FIX/repos"
PLAN="$(env -u GH_TOKEN CI_PIPELINE_SOURCE=schedule "${APPS[@]}" LOOPER_LIB="$ROOT/looper-lib.sh" PATH="$TMP/bin:$PATH" HOME="$FIX/home" FIX="$FIX" GITLAB_TOKEN=tok \
  "$ROOT/looper-dispatch" plan 2>/dev/null)" || fail "the scheduled plan failed"
grep -qx '  environment: {name: looper-scan, action: prepare}' <<<"$PLAN" || fail "scan: $PLAN"
# Without the apps, no id_token and no environment, as before.
PLAN="$(env -u CI_PIPELINE_SOURCE LOOPER_LIB="$ROOT/looper-lib.sh" PATH="$TMP/bin:$PATH" HOME="$FIX/home" FIX="$FIX" GITLAB_TOKEN=tok "$ROOT/looper-dispatch" plan 2>/dev/null)"
! grep -qE 'id_tokens|environment' <<<"$PLAN" || fail "without the apps: $PLAN"
pass

scenario apps-no-pat
for v in GH_TOKEN=ghp_0123456789abcdef0123 GITHUB_TOKEN=x SOMETHING=github_pat_0123456789abcdef; do
  ! OUT="$(env -u GH_TOKEN "${APPS[@]}" "$v" LOOPER_LIB="$ROOT/looper-lib.sh" PATH="$TMP/bin:$PATH" HOME="$FIX/home" FIX="$FIX" GITLAB_TOKEN=tok "$ROOT/looper-dispatch" run 2>&1)" ||
    fail "ran holding ${v%%=*}: $OUT"
  grep -q "this job holds ${v%%=*}" <<<"$OUT" || fail "log: $OUT"
done
! started || fail "started a pipeline holding a personal token"
GH_TOKEN=ghp_0123456789abcdef0123 dispatch run
started || fail "without the apps a GH_TOKEN is as before: $OUT"
pass

# Nothing runs on the Mac any more: there is no launchd install.
scenario no-install
dispatch_fails install
[[ ! -e "$FIX/home/Library" ]] || fail "installed something"
pass

echo "looper-dispatch: all scenarios pass"
