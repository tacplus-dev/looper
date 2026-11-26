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
source "$(dirname "${BASH_SOURCE[0]}")/hermetic.sh"   # the test's own environment, not the job's (looper#97, looper#103)
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
# $FIX/http-<cmd, spaces as ->: "<count> [<status>]", GitHub answers that many
# of the command's next calls with that status (default 502), as gh says it (looper#178).
e="$FIX/http-${cmd//[ \/]/-}"
if [[ -f "$e" ]] && read -r c s < "$e" && (( c > 0 )); then
  echo "$((c - 1)) ${s:-502}" > "$e"
  [[ "$cmd" != api\ * ]] || echo '{"message":"Server Error"}'   # gh api prints the body too
  echo "HTTP ${s:-502}: Server Error (https://api.github.com/search/issues?q=label%3Aapproved)" >&2; exit 1
fi
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
# The looper image's attested builds (looper#115): main's commits, newest
# first, from $FIX/main-commits (else two), and an attestation of
# main-<sha7> from $FIX/attested/<sha7>, its digest (no directory: each
# commit's is d...d; no file: not attested). Each verify's arguments go to
# $FIX/attest.
if [[ "$cmd" == "api repos/tacplus-dev/looper/commits?sha=main&per_page=20" ]]; then
  if [[ -f "$FIX/main-commits" ]]; then cat "$FIX/main-commits"; else printf '%s\n' "$(printf 'a%.0s' {1..40})" "$(printf 'b%.0s' {1..40})"; fi
  exit 0
fi
# A GitHub Actions run an issue waits on (looper#171): $FIX/runs/<id>.json, else HTTP 404.
if [[ "$cmd" == api\ repos/*/actions/runs/* ]]; then
  r="$FIX/runs/${cmd##*/}.json"; [[ -f "$r" ]] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
  if [[ "${1:-}" == --jq ]]; then jq -r "$2" "$r"; else cat "$r"; fi; exit 0
fi
# A back-off's reads (looper#181): main's head, $FIX/main-head (else c...c); an
# issue's comments ({created_at, user: {login}, author_association}) and
# events ({event, label: {name}, actor: {login}, created_at}), its file's
# `comments` and `events`, none by default; a collaborator's permission,
# $FIX/permissions/<login>, else HTTP 404.
if [[ "$cmd" == api\ repos/*/branches/main || "$cmd" == api\ repos/*/issues/*/comments* || "$cmd" == api\ repos/*/issues/*/events* || "$cmd" == api\ repos/*/collaborators/*/permission ]]; then
  q="."; while [[ $# -gt 0 ]]; do [[ "$1" != --jq ]] || { q="$2"; shift; }; shift; done
  p="${cmd#api repos/*/}"; p="${p%%\?*}"; r="${p%%/*}"; p="${p#*/}"   # alpha, issues/4/comments
  case "$p" in
    branches/main) jq -n --arg s "$(cat "$FIX/main-head" 2>/dev/null || printf 'c%.0s' {1..40})" '{commit: {sha: $s}}' ;;
    collaborators/*) l="${p#collaborators/}"; l="$FIX/permissions/${l%/permission}"
                     [[ -f "$l" ]] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }; jq -n --arg p "$(cat "$l")" '{permission: $p}' ;;
    *) k="$(cut -d/ -f2 <<<"$p")"; jq "[.${p##*/}[]?]" "$FIX/issues/$r-$k.json" ;;
  esac | jq -r "$q"; exit 0
fi
# A push's files (looper#213): `api repos/<org>/<repo>/compare/<base>...<head>`
# answers $FIX/changed, one path a line (renamed: "<new> <old>"); no file, HTTP 404.
if [[ "$cmd" == api\ repos/*/compare/* ]]; then
  echo "$cmd" >> "$FIX/compares"
  [[ -f "$FIX/changed" ]] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
  q="."; while [[ $# -gt 0 ]]; do [[ "$1" != --jq ]] || { q="$2"; shift; }; shift; done
  jq -R 'split(" ") | {filename: .[0]} + (if .[1] then {status: "renamed", previous_filename: .[1]} else {} end)' "$FIX/changed" \
    | jq -s '{files: .}' | jq -r "$q"; exit 0
fi
if [[ "$cmd" == "attestation verify" ]]; then
  echo "$*" >> "$FIX/attest"
  t="${1##*:main-}"
  if [[ ! -d "$FIX/attested" ]]; then d="$(printf 'd%.0s' {1..64})"
  elif [[ -f "$FIX/attested/$t" ]]; then d="$(cat "$FIX/attested/$t")"
  else echo "Error: no attestations found for $1" >&2; exit 1; fi
  jq -n --arg d "$d" '[{verificationResult: {statement: {subject: [{name: "ghcr.io/tacplus-dev/looper", digest: {sha256: $d}}]}}}]'
  exit 0
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
  # A file of a repository's main (looper#90): $FIX/contents/<repo>-<path>, else HTTP 404.
  api\ repos/*/contents/*)
    p="${cmd#api repos/*/}"; f="$FIX/contents/${p%%/*}-${p#*/contents/}"
    [[ -f "$f" ]] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }; echo '{"type":"file"}'; exit 0 ;;
  # $FIX/private: the org's private repositories, one a line (--visibility public leaves them out).
  # GitHub's search index lags (looper#175): $FIX/search/<repo>-<n>.json is the
  # issue as the search still has it, where the issue itself has changed.
  "search issues") seen=(); for f in "$FIX"/issues/*.json; do s="$FIX/search/${f##*/}"; [[ -f "$s" ]] && seen+=("$s") || seen+=("$f"); done
                   jq -s --arg l "$label" --arg vis "$vis" --arg priv "$(cat "$FIX/private" 2>/dev/null || true)" \
                     'map(select(.state == "OPEN" and any(.labels[]; .name == $l)) | . + {repository: {name: .repo}})
                      | map(select($vis != "public" or (.repo | IN($priv | split("\n")[]) | not)))' "${seen[@]}" | jq -r "$q" ;;
  # A repository's open issues with the label (approved when none asked); one with no issue yet lists none.
  "issue list") shopt -s nullglob; files=("$FIX/issues/$repo"-*.json); shopt -u nullglob
    jq -s --arg l "${label:-approved}" 'map(select(.state == "OPEN" and any(.labels[]; .name == $l)))' "${files[@]+"${files[@]}"}" < /dev/null | jq -r "$q" ;;
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
# A GitLab pipeline an issue waits on (looper#171): $FIX/pipelines/<id>.json, else HTTP 404.
case "$m $url" in
  "GET https://gitlab.com/api/v4/projects/"*/pipelines/*)
    if [[ -f "$FIX/pipelines/${url##*/}.json" ]]; then reply 200 "$(cat "$FIX/pipelines/${url##*/}.json")"; else reply 404 '{"message":"404 Not found"}'; fi; exit 0 ;;
esac
# Compute (looper#241): a project's looper VM group, $FIX/vm-<repo> its target size (no file: 404).
case "$m $url" in
  "GET https://compute.googleapis.com/"*/instanceGroupManagers/looper-vm-*)
    r="${url##*/looper-vm-}"; if [[ -f "$FIX/vm-$r" ]]; then reply 200 "{\"targetSize\": $(cat "$FIX/vm-$r")}"; else reply 404 '{"error":{"code":404}}'; fi; exit 0 ;;
  "POST https://compute.googleapis.com/"*/instanceGroupManagers/looper-vm-*/resize\?size=1)
    r="${url##*/looper-vm-}"; r="${r%%/*}"; echo "resize $r 1" >> "$FIX/vm-calls"; echo 1 > "$FIX/vm-$r"; reply 200 '{"status":"DONE"}'; exit 0 ;;
esac
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
# looper-ruleset check (looper#233), a stub: $FIX/ruleset-<repo> is what the
# check prints for that repository, and it fails; no file, "<repo> ok". Each
# call's arguments go to $FIX/ruleset.
cat > "$TMP/bin/looper-ruleset" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$FIX/ruleset"
[[ "$1" == check ]] || exit 3
shift; rc=0
for r in "$@"; do if [[ -f "$FIX/ruleset-$r" ]]; then cat "$FIX/ruleset-$r"; rc=1; else echo "$r ok"; fi; done
(( rc == 0 )) || echo "[2026-11-24T00:00:00Z] main is not the manager's alone in: $* (looper-ruleset apply)" >&2
exit "$rc"
EOF
export LOOPER_RULESET="$TMP/bin/looper-ruleset"
chmod +x "$TMP/bin/gh" "$TMP/bin/curl" "$TMP/bin/date" "$TMP/bin/sleep" "$TMP/bin/looper-ruleset"

scenario() { # name: alpha has a ready issue #4
  NAME="$1"; FIX="$TMP/$1"; mkdir -p "$FIX/issues" "$FIX/home"; echo '[]' > "$FIX/jobs.json"
  jq -n '{repo: "alpha", number: 4, state: "OPEN", labels: [{name: "approved"}], body: "Fix it.", createdAt: "2026-10-27T00:00:00Z"}' \
    > "$FIX/issues/alpha-4.json"
}
jobs() { printf '%s\n' "$@" | jq -R 'split(" ") | {name: .[0], status: .[1]}' | jq -s . > "$FIX/jobs.json"; } # "name status"...
# "name status id"...: jobs with their ids (looper#104).
id_jobs() { printf '%s\n' "$@" | jq -R 'split(" ") | {name: .[0], status: .[1], id: (.[2] | tonumber)}' | jq -s . > "$FIX/jobs.json"; }
run_dispatch() {
  OUT="$(env -u CI_API_V4_URL -u CI_PIPELINE_SOURCE -u CI_JOB_ID -u CI_JOB_NAME -u LOOPER_TRIGGER_TOKEN ${JOB_ID:+CI_JOB_ID="$JOB_ID" CI_JOB_NAME=looper-kick} ${TRIGGER:+LOOPER_TRIGGER_TOKEN="$TRIGGER"} ${CAPS:+LOOPER_CAPS="$CAPS"} LOOPER_LIB="$ROOT/looper-lib.sh" PATH="$TMP/bin:$PATH" HOME="$FIX/home" FIX="$FIX" GITLAB_TOKEN="${TOKEN-tok}" LOOPER_INTERVAL="${INTERVAL:-180}" \
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
# job of its own, however many reports its repository has (no per-repository
# cap, looper#107: "loopers are never blocked"); and for commits queued to land
# (looper:landing) with no manager job.
scenario kick-no-cap
issue alpha 5 OPEN "Go." approved
jobs "looper-alpha-4 running" "looper-alpha-7 running" "looper-alpha-8 pending"
printf 'default: 1\n' > "$FIX/caps.yaml"
CAPS="$FIX/caps.yaml" dispatch run
started || fail "no pipeline started beside 3 reports: $OUT"
grep -q 'alpha#5 is ready' <<<"$OUT" || fail "log: $OUT"
# Each pass logs each repository's reports, how many of them run (the rest
# pending for a VM, looper#92), the ready issues with no report yet and the
# lands queued: the nightly recap's numbers (looper#72, looper#107).
grep -q 'capacity: alpha reports=3 running=2 waiting=5 landing=0$' <<<"$OUT" || fail "capacity: $OUT"
pass

scenario kick-landing
issue alpha 4 OPEN "Done, its land queued." approved looper:landing
dispatch run
started || fail "no pipeline for a queued land without a manager: $OUT"
grep -q 'queued to land and no manager' <<<"$OUT" || fail "log: $OUT"
grep -q 'capacity: alpha reports=0 running=0 waiting= landing=1$' <<<"$OUT" || fail "capacity: $OUT"
rm "$FIX/started"
jobs "looper-alpha-manager running"
dispatch run
! started || fail "started a pipeline while the manager runs: $OUT"
pass

# The looper's hold (looper#157): a run every model refused by the account's
# usage limit records the reset time on the hub's hold issue (looper:hold, its
# body's marker; tests/repo-looper.test.sh: limit-hold). Until then a kick
# starts nothing, a ready issue or a queued land notwithstanding, and says so
# in one line; the first kick after it starts the issue again. The plan honours
# it too: one job that says so, no report and no manager.
hold_issue() { # until: the hub's hold issue, as repo-looper leaves it
  jq -n --argjson u "$1" '{repo: "looper", number: 9, state: "OPEN", labels: [{name: "looper:hold"}], createdAt: "2026-11-14T10:07:00Z",
    body: "The looper'"'"'s hold.\n\n<!-- looper-hold until=\($u) -->"}' > "$FIX/issues/looper-9.json"
}
plan_held() { PLAN="$(env -u CI_PIPELINE_SOURCE LOOPER_LIB="$ROOT/looper-lib.sh" PATH="$TMP/bin:$PATH" HOME="$FIX/home" FIX="$FIX" GITLAB_TOKEN=tok \
  "$ROOT/looper-dispatch" plan 2>"$FIX/err")" || fail "plan failed: $(cat "$FIX/err")"; }
scenario hold
issue alpha 5 OPEN "Done, its land queued." approved looper:landing
RESET="$(date -u -d 2026-11-15T03:00:00Z +%s)"
echo "$(( RESET - 75600 ))" > "$FIX/clock"   # 2026-11-14T06:00:00Z
hold_issue "$RESET"
dispatch run
! started || fail "started a pipeline during the hold: $OUT"
grep -q "held: the account's usage limit is reached; the looper holds until 2026-11-15T03:00:00Z (https://github.com/tacplus-dev/looper/issues/9): no report and no manager starts before then" <<<"$OUT" \
  || fail "log: $OUT"
[[ "$(grep -c 'held:' <<<"$OUT")" == 1 ]] || fail "more than one line: $OUT"
[[ ! -s "$FIX/comments" ]] || fail "commented: $(cat "$FIX/comments")"
plan_held
! grep -qE '^looper-alpha-' <<<"$PLAN" || fail "planned during the hold: $PLAN"
grep -q 'the looper holds until 2026-11-15T03:00:00Z' <<<"$PLAN" || fail "the plan's job: $PLAN"
grep -q 'holds until 2026-11-15T03:00:00Z' "$FIX/err" || fail "the plan's log: $(cat "$FIX/err")"
# Still held a minute before the reset; the first kick at it starts the pipeline for alpha#4.
echo "$(( RESET - 60 ))" > "$FIX/clock"; dispatch run
! started || fail "started a pipeline a minute before the reset: $OUT"
echo "$RESET" > "$FIX/clock"; dispatch run
started || fail "no pipeline after the reset: $OUT"
grep -q 'alpha#4 is ready' <<<"$OUT" || fail "log: $OUT"
! grep -q 'held:' <<<"$OUT" || fail "held after the reset: $OUT"
plan_held
grep -q '^looper-alpha-4:' <<<"$PLAN" && grep -q '^looper-alpha-manager:' <<<"$PLAN" || fail "not planned after the reset: $PLAN"
# A hold issue with no marker, or none at all, holds nothing.
echo "$(( RESET - 75600 ))" > "$FIX/clock"; rm "$FIX/started"
jq '.body = "No marker."' "$FIX/issues/looper-9.json" > "$FIX/x" && mv "$FIX/x" "$FIX/issues/looper-9.json"
dispatch run; started || fail "a hold issue without a marker held: $OUT"
rm "$FIX/started" "$FIX/issues/looper-9.json"
dispatch run; started || fail "no hold issue held: $OUT"
pass

# The plan (looper#70): a report job per ready issue, in order, every one of
# them (no per-repository cap, looper#107), none for an issue whose report is
# active, each one at a time per issue;
# and the repository's manager, the only job on its main's resource group,
# unless one already waits to start, ahead of its reports (looper#75): the
# runner starts a pool's pending jobs in id order, the plan's order, and a
# manager behind reports it has no VM for left their work unmerged for hours.
scenario plan-a-report-per-ready-issue
for k in 5 6 7 8; do issue alpha "$k" OPEN "Go." approved; done
for k in 1 2 3 4 5 6 7 8 9 10; do issue tacplus "$k" OPEN "Go." approved; done
jobs "looper-alpha-4 running" "looper-alpha-manager running"
printf '#!/usr/bin/env bash\nexec "%s/repo-looper" "$@"\n' "$ROOT" > "$TMP/bin/repo-looper"; chmod +x "$TMP/bin/repo-looper"
plan_jobs() { PLAN="$(env -u CI_PIPELINE_SOURCE ${CAPS:+LOOPER_CAPS="$CAPS"} LOOPER_LIB="$ROOT/looper-lib.sh" PATH="$TMP/bin:$PATH" HOME="$FIX/home" FIX="$FIX" GITLAB_TOKEN=tok \
  "$ROOT/looper-dispatch" plan 2>"$FIX/err")" || fail "plan failed: $(cat "$FIX/err")"; }
plan_jobs
[[ "$(grep -oE '^looper-alpha-[0-9a-z]+' <<<"$PLAN" | paste -sd' ')" == "looper-alpha-manager looper-alpha-5 looper-alpha-6 looper-alpha-7 looper-alpha-8" ]] \
  || fail "alpha's jobs: $(grep '^looper-' <<<"$PLAN")"
# Ten ready issues in one repository plan ten reports.
[[ "$(grep -oE '^looper-tacplus-[0-9]+' <<<"$PLAN" | sort -V | paste -sd' ')" == "$(printf 'looper-tacplus-%s\n' {1..10} | paste -sd' ')" ]] \
  || fail "tacplus's reports: $(grep '^looper-' <<<"$PLAN")"
grep -qx 'looper-tacplus-manager:' <<<"$PLAN" || fail "no tacplus manager: $PLAN"
# Its reports above its VMs: the manager is ahead of every report of its repository.
[[ "$(grep -E '^looper-tacplus-' <<<"$PLAN" | head -1)" == 'looper-tacplus-manager:' ]] || fail "tacplus's manager behind its reports: $(grep '^looper-' <<<"$PLAN")"
# No manager is behind any report.
[[ "$(grep -E '^looper-' <<<"$PLAN" | awk '/-manager:$/ {if (r) bad=1; next} {r=1} END {print bad+0}')" == 0 ]] \
  || fail "a manager behind a report: $(grep '^looper-' <<<"$PLAN")"
! grep -q 'waits' "$FIX/err" || fail "a ready issue waits: $(cat "$FIX/err")"
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
# No caps file is read, nor shipped (looper#107): a stale one caps nothing.
printf 'default: 1\nalpha: 1\n' > "$FIX/caps.yaml"
CAPS="$FIX/caps.yaml" plan_jobs
[[ "$(grep -cE '^looper-alpha-[0-9]+:' <<<"$PLAN")" == 4 && "$(grep -cE '^looper-tacplus-[0-9]+:' <<<"$PLAN")" == 10 ]] \
  || fail "a caps file capped the plan: $(grep '^looper-' <<<"$PLAN")"
[[ ! -e "$ROOT/caps.yaml" ]] || fail "caps.yaml is still in the repository"
pass

# A queued land alone (looper:landing, no ready issue) plans the manager alone.
scenario plan-manager-for-landing
jq '.labels += [{name: "looper:landing"}]' "$FIX/issues/alpha-4.json" > "$FIX/x" && mv "$FIX/x" "$FIX/issues/alpha-4.json"
PLAN="$(env -u CI_PIPELINE_SOURCE LOOPER_LIB="$ROOT/looper-lib.sh" PATH="$TMP/bin:$PATH" HOME="$FIX/home" FIX="$FIX" GITLAB_TOKEN=tok \
  "$ROOT/looper-dispatch" plan 2>/dev/null)" || fail "plan failed"
[[ "$(grep -E '^looper-' <<<"$PLAN" | paste -sd' ')" == "looper-alpha-manager:" ]] || fail "planned: $(grep '^looper-' <<<"$PLAN")"
pass

# Only the newest kicker runs (looper#104): three kicks queued (one waiting
# for a runner, two for the kicker resource_group behind it), and each but the
# newest stops before its first pass, saying which one it leaves to run; the
# newest makes its passes. Kicks that had waited all morning used to run their
# hours back to back, each finding the plan under way.
scenario kick-newest-only
echo 1000 > "$FIX/clock"
id_jobs "looper-kick pending 101" "looper-kick waiting_for_resource 102" "looper-kick waiting_for_resource 103"
for id in 101 102; do
  JOB_ID=$id INTERVAL=180 dispatch run --for 360
  grep -q "a newer kick (job 103) is queued; this one stops" <<<"$OUT" || fail "kick $id: $OUT"
  ! started || fail "kick $id made a pass: $OUT"
  ! grep -q 'search issues' "$FIX/gh" 2>/dev/null || fail "kick $id read the issues: $(cat "$FIX/gh")"
done
JOB_ID=103 INTERVAL=180 dispatch run --for 360
started || fail "the newest kick made no pass: $OUT"
[[ "$(grep -c 'search issues' "$FIX/gh")" -ge 3 ]] || fail "the newest kick's passes: $(cat "$FIX/gh"): $OUT"
! grep -q 'a newer kick' <<<"$OUT" || fail "the newest kick stopped: $OUT"
# A running kick stops at its next pass once a newer one is queued.
rm -f "$FIX/started" "$FIX/gh"
id_jobs "looper-kick running 103" "looper-kick created 104"
JOB_ID=103 INTERVAL=180 dispatch run --for 360
grep -q "a newer kick (job 104) is queued" <<<"$OUT" && ! started || fail "the older kick ran on: $OUT"
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

# Waiting-on (looper#171): an issue whose last run ended waiting on another
# run's result is ready once that run has finished (a GitLab pipeline, a
# GitHub Actions run), or LOOPER_WAIT_MAX after its since when it cannot be
# read; while it runs, nothing starts for it.
now_iso() { date -u -d "@$(( $(date +%s) - ${1:-0} ))" +%FT%TZ; } # seconds ago
PIPE=https://gitlab.com/tacplus-dev/fleet/-/pipelines/77
scenario waiting-pipeline-running
mkdir -p "$FIX/pipelines"; echo '{"id": 77, "status": "running"}' > "$FIX/pipelines/77.json"
issue alpha 4 OPEN $'Fix it.\nWaiting-on: '"$PIPE (since $(now_iso))" approved
dispatch run
! started || fail "started a pipeline for an issue waiting on a running pipeline"
# Read with GITLAB_TOKEN, its header from a file descriptor, never on the command line.
grep -q '^@/dev/fd/[0-9]* GET https://gitlab.com/api/v4/projects/tacplus-dev%2Ffleet/pipelines/77$' "$FIX/gitlab" || fail "the pipeline not read with a header from a file: $(cat "$FIX/gitlab")"
! grep pipelines/77 "$FIX/argv" | grep -q tok || fail "GITLAB_TOKEN on a command line: $(cat "$FIX/argv")"
pass

scenario waiting-pipeline-finished
mkdir -p "$FIX/pipelines"; echo '{"id": 77, "status": "success"}' > "$FIX/pipelines/77.json"
issue alpha 4 OPEN $'Fix it.\nWaiting-on: '"$PIPE (since $(now_iso))" approved
dispatch run
started || fail "no pipeline started once the run it waits on finished: $OUT"
pass

scenario waiting-github-run
mkdir -p "$FIX/runs"; echo '{"id": 43907923763, "status": "in_progress", "conclusion": null}' > "$FIX/runs/43907923763.json"
issue alpha 4 OPEN $'Fix it.\n  waiting-on: <https://github.com/tacplus-dev/looper/actions/runs/43907923763>'" (since $(now_iso))" approved
dispatch run
! started || fail "started a pipeline for an issue waiting on a workflow run in progress"
echo '{"id": 43907923763, "status": "completed", "conclusion": "failure"}' > "$FIX/runs/43907923763.json"
dispatch run
started || fail "no pipeline started once the workflow run completed: $OUT"
pass

# A run that cannot be read holds its issue LOOPER_WAIT_MAX (6h) from its since, no longer.
scenario waiting-unreadable
issue alpha 4 OPEN $'Fix it.\nWaiting-on: '"$PIPE (since $(now_iso 3600))" approved
dispatch run
! started || fail "started a pipeline an hour into a wait on a run it cannot read"
issue alpha 4 OPEN $'Fix it.\nWaiting-on: '"$PIPE (since $(now_iso 21700))" approved
dispatch run
started || fail "an unreadable wait held its issue past LOOPER_WAIT_MAX: $OUT"
pass

# Backing off (looper#181): on 2026-11-17 kernel#66 and llmproxy#63 waited on
# Debian, and every run found nothing to do; the kicker started the next
# minutes later, ~20 runs of kernel#66 in a day. An issue whose body has a
# `Backed-off:` line is not started until its until passes or something
# changes after its since: a member's comment (not a bot's, not a stranger's,
# not one from before), a label added or removed (not looper:in-progress), a
# push to its repository's main that changes more than its planning files, or
# a path its line names (looper#213), a Blocked-by issue closing.
C40="$(printf 'c%.0s' {1..40})"
backed() { # until (seconds ahead) since (seconds ago) [extra body line] [paths]: alpha#4 backed off
  issue alpha 4 OPEN "Waiting on Debian's fix.${3:+
$3}
Backed-off: until $(now_iso "-$1") (since $(now_iso "$2"), main $C40${4:+, paths $4})" approved
}
said() { # login association seconds-ago: a comment on alpha#4
  jq --arg l "$1" --arg a "$2" --arg t "$(now_iso "$3")" '.comments += [{user: {login: $l}, author_association: $a, created_at: $t, body: "x"}]' \
    "$FIX/issues/alpha-4.json" > "$FIX/x" && mv "$FIX/x" "$FIX/issues/alpha-4.json"
}
labelled() { # event label seconds-ago: a label event on alpha#4
  jq --arg e "$1" --arg l "$2" --arg t "$(now_iso "$3")" '.events += [{event: $e, label: {name: $l}, actor: {login: "jody"}, created_at: $t}]' \
    "$FIX/issues/alpha-4.json" > "$FIX/x" && mv "$FIX/x" "$FIX/issues/alpha-4.json"
}
scenario backed-off-comment
backed 86000 600
dispatch run
! started || fail "started a pipeline for a backed-off issue: $OUT"
said tacplus-looper[bot] NONE 60; said stranger NONE 60; said jody MEMBER 900
dispatch run
! started || fail "a bot's, a stranger's or an older comment restarted a backed-off issue: $OUT"
mkdir -p "$FIX/permissions"; echo read > "$FIX/permissions/reader"; said reader COLLABORATOR 60
dispatch run
! started || fail "a read-only collaborator's comment restarted a backed-off issue: $OUT"
said jody MEMBER 60
dispatch run
started || fail "a member's comment did not restart a backed-off issue: $OUT"
pass

scenario backed-off-writer
backed 86000 600
mkdir -p "$FIX/permissions"; echo write > "$FIX/permissions/owner"; said owner NONE 60   # an org owner whose membership is private
dispatch run
started || fail "a writer's comment did not restart a backed-off issue: $OUT"
pass

# A push of the planning files alone (the manager's HISTORY.md, STATE.md and
# PROPOSALS.md after a merge) wakes nobody: on 2026-11-21 such pushes started
# looper#189 14 times and cloud#85 10, each run finding nothing to change
# (looper#213). One that changes anything else does; one the forge cannot
# compare changes nothing.
scenario backed-off-push-planning
backed 86000 600
dispatch run
! started || fail "started a pipeline for a backed-off issue: $OUT"
printf 'd%.0s' {1..40} > "$FIX/main-head"
dispatch run
! started || fail "a push the forge cannot compare restarted a backed-off issue: $OUT"
printf '%s\n' HISTORY.md STATE.md PROPOSALS.md > "$FIX/changed"
dispatch run
! started || fail "a push of the planning files alone restarted a backed-off issue: $OUT"
grep -qF "compare/$C40...$(printf 'd%.0s' {1..40})" "$FIX/compares" || fail "the push was not compared from the back-off's main to main's head: $(cat "$FIX/compares")"
pass

scenario backed-off-push-code
backed 86000 600
printf 'd%.0s' {1..40} > "$FIX/main-head"
printf '%s\n' HISTORY.md docs/STATE.md > "$FIX/changed"
dispatch run
started || fail "a push changing a file outside the planning files did not restart a backed-off issue: $OUT"
pass

# A run that names the paths it waits on (--wait-until --path, looper#213) is
# woken by a push to those alone: a file in a directory it names too, not a
# file whose name only begins with one.
scenario backed-off-push-paths
backed 86000 600 "" "Dockerfile ci"
printf 'd%.0s' {1..40} > "$FIX/main-head"
printf '%s\n' looper-lib.sh Dockerfile.old cix/a.yml STATE.md > "$FIX/changed"
dispatch run
! started || fail "a push to none of the paths its Backed-off line names restarted a backed-off issue: $OUT"
echo "ci/build.yml" >> "$FIX/changed"
dispatch run
started || fail "a push to a path its Backed-off line names did not restart a backed-off issue: $OUT"
rm -f "$FIX/started"; backed 86000 600 "" "Dockerfile ci"
printf '%s\n' "lib/new.sh Dockerfile" > "$FIX/changed"
dispatch run
started || fail "a push renaming a path its Backed-off line names did not restart a backed-off issue: $OUT"
pass

scenario backed-off-label
backed 86000 600
labelled labeled looper:in-progress 60; labelled unlabeled looper:in-progress 50; labelled labeled bug 900
dispatch run
! started || fail "looper:in-progress, or a label before its since, restarted a backed-off issue: $OUT"
labelled labeled priority:high 30
dispatch run
started || fail "a label added did not restart a backed-off issue: $OUT"
pass

scenario backed-off-blocker
backed 86000 600 "Blocked-by: #9"
issue alpha 9 CLOSED "Debian's fix." bug
jq --arg t "$(now_iso 900)" '.closedAt = $t' "$FIX/issues/alpha-9.json" > "$FIX/x" && mv "$FIX/x" "$FIX/issues/alpha-9.json"
dispatch run
! started || fail "a blocker closed before its since restarted a backed-off issue: $OUT"
jq --arg t "$(now_iso 60)" '.closedAt = $t' "$FIX/issues/alpha-9.json" > "$FIX/x" && mv "$FIX/x" "$FIX/issues/alpha-9.json"
dispatch run
started || fail "its blocker closing did not restart a backed-off issue: $OUT"
pass

scenario backed-off-until
backed -10 86400
dispatch run
started || fail "a back-off past its until still held its issue: $OUT"
pass

for held in looper:stuck needs-decision; do
  scenario "held-$held"
  issue alpha 4 OPEN "Fix it." approved "$held"
  dispatch run
  ! started || fail "started a pipeline for an issue labelled $held"
  pass
done

# GitHub's search lags the issue itself (looper#175): on 2026-11-17 the kicker
# started the pipeline for looper#174 every 3 minutes for 40 minutes, the search
# still listing it ready (its Waiting-on not in its body there yet, then its
# looper:landing not in its labels), and each report job found it "no longer
# ready" in 27 s, with no report job of it active for the next pass to see.
# Before it starts the pipeline for an issue, the pass reads that issue itself:
# one the search lists ready that is not starts nothing, and the next ready one
# does; and a report job of it active still starts nothing. The plan plans no
# report job for it either.
stale() { mkdir -p "$FIX/search"; cp "$FIX/issues/$1-$2.json" "$FIX/search/"; } # repo n: the search keeps the issue as it is now
scenario stale-landing
stale alpha 4
issue alpha 4 OPEN "Fix it." approved looper:landing
dispatch run
! started || fail "started a pipeline for an issue the search lists ready but that is looper:landing: $OUT"
grep -q 'alpha#4 is not ready, read itself (the search lags, looper#175)' <<<"$OUT" || fail "log: $OUT"
grep -q 'nothing to start' <<<"$OUT" || fail "log: $OUT"
pass

scenario stale-waiting
mkdir -p "$FIX/pipelines"; echo '{"id": 77, "status": "running"}' > "$FIX/pipelines/77.json"
stale alpha 4
issue alpha 4 OPEN $'Fix it.\nWaiting-on: '"$PIPE (since $(now_iso))" approved
dispatch run
! started || fail "started a pipeline for an issue whose own body waits on a running pipeline: $OUT"
pass

scenario stale-next
stale alpha 4
issue alpha 4 OPEN "Fix it." approved looper:in-progress
issue beta 2 OPEN "Go." approved
dispatch run
grep -q 'started the .* (beta#2 is ready)' <<<"$OUT" || fail "log: $OUT"
pass

scenario stale-running
stale alpha 4
issue alpha 4 OPEN "Fix it." approved looper:in-progress
jobs "looper-alpha-4 running"
dispatch run
! started || fail "started a pipeline while looper-alpha-4 runs: $OUT"
pass

scenario plan-stale
stale alpha 4
issue alpha 4 OPEN "Fix it." approved looper:landing
issue beta 2 OPEN "Go." approved
PLAN="$(env -u CI_PIPELINE_SOURCE LOOPER_LIB="$ROOT/looper-lib.sh" PATH="$TMP/bin:$PATH" HOME="$FIX/home" FIX="$FIX" GITLAB_TOKEN=tok \
  "$ROOT/looper-dispatch" plan 2>"$FIX/err")" || fail "plan failed: $(cat "$FIX/err")"
! grep -qx 'looper-alpha-4:' <<<"$PLAN" || fail "planned a report for an issue that is not ready, read itself: $PLAN"
grep -qx 'looper-beta-2:' <<<"$PLAN" || fail "beta#2 not planned: $PLAN"
grep -q 'alpha#4 is not ready, read itself (the search lags, looper#175); not planned' "$FIX/err" || fail "log: $(cat "$FIX/err")"
pass

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
# past GitHub's 5000 an hour at one every 3 minutes; looper#24): the orphans'
# search, the hold (one list of the hub's, looper#157), the ready issues'
# search and their blockers' states, the lands' search, and the issue it starts
# the pipeline for, read itself (looper#175).
scenario cost
for r in alpha beta gamma; do
  for n in 1 2 3 5 6 7; do issue "$r" "$n" OPEN "Blocked-by: #$((n + 1))" approved; done
done
issue gamma 8 OPEN "Not approved."
dispatch run
[[ "$(wc -l < "$FIX/gh")" -le 6 ]] || fail "$(wc -l < "$FIX/gh") GitHub calls: $(sort "$FIX/gh" | uniq -c)"
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

# A pass that fails (GitLab down) does not end the loop; when every one fails
# the job fails at its end, so the schedule shows it.
scenario loop-failing-pass
in_progress
rm "$FIX/jobs.json"
INTERVAL=1 dispatch_fails run --for 2
[[ "$(passes)" -ge 2 ]] || fail "$(passes) pass(es): $OUT"
grep -q 'pass failed' <<<"$OUT" || fail "log: $OUT"
! started || fail "started a pipeline with GitLab down"
[[ "$(labels alpha 4)" == approved,looper:in-progress ]] || fail "labels $(labels alpha 4)"
pass

# GitHub's 5xx and 429 pass (looper#178: the search's HTTP 502 failed the
# kick, 2026-11-16 and 17): a read is tried again, 3 tries in all, 2 then 4
# seconds apart (the fake clock), and says so; any other error, and a third
# 5xx, fail it at once.
scenario github-502-once
echo 1000 > "$FIX/clock"; echo 1 > "$FIX/http-search-issues"
dispatch run
started || fail "no pipeline started after one 502: $OUT"
grep -q 'gh search issues: HTTP 502; tried again in 2s (looper#178)' <<<"$OUT" || fail "log: $OUT"
[[ "$(cat "$FIX/clock")" == 1002 ]] || fail "waited until $(cat "$FIX/clock")"
pass

scenario github-429-twice
echo 1000 > "$FIX/clock"; echo "2 429" > "$FIX/http-search-issues"
dispatch run
started || fail "no pipeline started after two 429s: $OUT"
[[ "$(cat "$FIX/clock")" == 1006 ]] || fail "waited until $(cat "$FIX/clock")"
pass

scenario github-502-thrice
echo 1000 > "$FIX/clock"; echo 3 > "$FIX/http-search-issues"
dispatch_fails run
[[ "$(grep -cx 'search issues' "$FIX/gh")" -eq 3 ]] || fail "$(grep -cx 'search issues' "$FIX/gh") searches: $OUT"
grep -q 'HTTP 502: Server Error' <<<"$OUT" || fail "log: $OUT"
! started || fail "started a pipeline with the search failing"
pass

scenario github-404
echo 1000 > "$FIX/clock"; echo "1 404" > "$FIX/http-search-issues"
dispatch_fails run
[[ "$(grep -cx 'search issues' "$FIX/gh")" -eq 1 ]] || fail "a 404 tried again: $(cat "$FIX/gh")"
pass

# Only reads: a write that GitHub answers with a 502 may still have been made
# (a comment posted twice), so it is never tried again; a GraphQL query is a
# read, a mutation is not.
lib() { env PATH="$TMP/bin:$PATH" FIX="$FIX" bash -c "set -euo pipefail; source '$ROOT/looper-lib.sh'; $1" 2>&1; } # a looper-lib.sh snippet
scenario github-502-writes
echo 1000 > "$FIX/clock"
echo 1 > "$FIX/http-issue-edit"; echo 1 > "$FIX/http-issue-comment"; echo 1 > "$FIX/http-api-repos-tacplus-dev-alpha-issues-4-comments"
! OUT="$(lib "gh issue edit 4 --repo tacplus-dev/alpha --remove-label approved")" || fail "the edit succeeded: $OUT"
! OUT="$(lib "gh issue comment 4 --repo tacplus-dev/alpha --body hi")" || fail "the comment succeeded: $OUT"
! OUT="$(lib "gh api repos/tacplus-dev/alpha/issues/4/comments -f body=hi")" || fail "the POST succeeded: $OUT"
[[ "$(wc -l < "$FIX/gh")" -eq 3 ]] || fail "a write tried again: $(cat "$FIX/gh")"
[[ "$(cat "$FIX/clock")" == 1000 ]] || fail "waited until $(cat "$FIX/clock")"
echo 1 > "$FIX/http-api-graphql"
! OUT="$(lib "gh api graphql -f query='mutation { pinIssue(input: {issueId: \"x\"}) { issue { number } } }'")" || fail "the mutation succeeded: $OUT"
[[ "$(grep -cx 'api graphql' "$FIX/gh")" -eq 1 ]] || fail "a mutation tried again: $(cat "$FIX/gh")"
echo 1 > "$FIX/http-api-graphql"
OUT="$(lib "gh api graphql -f query='{ a0: repository(owner: \"tacplus-dev\", name: \"alpha\") { issue(number: 4) { state } } }'")" || fail "the query failed: $OUT"
[[ "$(grep -cx 'api graphql' "$FIX/gh")" -eq 3 ]] || fail "the query not tried again: $(cat "$FIX/gh")"
grep -q '"OPEN"' <<<"$OUT" || fail "query: $OUT"
! grep -q 'Server Error' <<<"$OUT" || fail "the failed try's output kept: $OUT"
pass

# A pass that fails mid-job is logged and skipped: the job fails only if every
# pass did (looper#178).
scenario loop-one-failing-pass
echo 1000 > "$FIX/clock"; echo 3 > "$FIX/http-search-issues"
INTERVAL=3 dispatch run --for 6
[[ "$(grep -c 'pass failed' <<<"$OUT")" -eq 1 ]] || fail "log: $OUT"
started || fail "no pipeline started: $OUT"
pass

# Per-repository runner tags (looper#55): a repository's report takes
# LOOPER_JOB_TAGS_<repo> (`-` as `_`), else LOOPER_JOB_TAGS, else the default;
# so tacplus's reports go to the 16-CPU pool and every other repository's stay.
# Its manager and its scan (looper#91) take LOOPER_MANAGER_TAGS_<repo> and
# LOOPER_SCAN_TAGS_<repo>, else LOOPER_JOB_TAGS, else the default, never the
# reports' override: they no longer wait for that pool's VM behind a report.
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
plan_with -u LOOPER_JOB_TAGS LOOPER_JOB_TAGS_tacplus="arm64, autoscale-16"
[[ "$(tags_of tacplus-manager)" == "[arm64, autoscale]" ]] || fail "tacplus's manager: $(tags_of tacplus-manager): $PLAN"
plan_with LOOPER_JOB_TAGS="arm64, other" LOOPER_JOB_TAGS_tacplus="arm64, autoscale-16" LOOPER_MANAGER_TAGS_fleet_lab="arm64, lab"
[[ "$(tags_of tacplus-manager)" == "[arm64, other]" ]] || fail "tacplus's manager: $(tags_of tacplus-manager)"
[[ "$(tags_of fleet-lab-manager)" == "[arm64, lab]" ]] || fail "fleet-lab's manager: $(tags_of fleet-lab-manager)"
[[ "$(tags_of fleet-lab-6)" == "[arm64, other]" ]] || fail "fleet-lab's report took its manager's tags: $(tags_of fleet-lab-6)"
printf '%s\n' alpha fleet-lab tacplus > "$FIX/repos"
plan_with -u LOOPER_JOB_TAGS LOOPER_JOB_TAGS_tacplus="arm64, autoscale-16" LOOPER_SCAN_TAGS_fleet_lab="arm64, lab" CI_PIPELINE_SOURCE=schedule
[[ "$(tags_of scan-tacplus)" == "[arm64, autoscale]" ]] || fail "tacplus's scan: $(tags_of scan-tacplus): $PLAN"
[[ "$(tags_of scan-fleet-lab)" == "[arm64, lab]" ]] || fail "fleet-lab's scan: $(tags_of scan-fleet-lab): $PLAN"
[[ "$(tags_of scan-alpha)" == "[arm64, autoscale]" ]] || fail "alpha's scan: $(tags_of scan-alpha)"
# The plan's log names each job's tags and resource group: the recap counts a
# report queued behind a scan as held by it only when they share one (looper#92).
PLANLOG="$(env -u CI_PIPELINE_SOURCE -u LOOPER_JOB_TAGS LOOPER_JOB_TAGS_tacplus="arm64, autoscale-16" LOOPER_LIB="$ROOT/looper-lib.sh" PATH="$TMP/bin:$PATH" HOME="$FIX/home" FIX="$FIX" GITLAB_TOKEN=tok \
  "$ROOT/looper-dispatch" plan 2>&1 >/dev/null)" || fail "plan failed"
grep -qF 'planned looper-tacplus-5 (5h, tags arm64, autoscale-16, resource_group looper-tacplus-5)' <<<"$PLANLOG" || fail "the plan's log: $PLANLOG"
grep -qF 'planned looper-tacplus-manager (' <<<"$PLANLOG" && grep -qF ', resource_group looper-tacplus-main)' <<<"$PLANLOG" || fail "the plan's log: $PLANLOG"
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
  # The scans no longer take the reports' tags (looper#91): the inline plan's without tacplus's override.
  inline_tags=(-u LOOPER_JOB_TAGS_tacplus); [[ "$source" == schedule ]] || inline_tags+=(LOOPER_JOB_TAGS_tacplus="arm64, autoscale-16")
  (cd "$FIX/inline-$source" && env "${CLEAN[@]}" "${inline_tags[@]}" LOOPER_ORG=tacplus-dev CI_PIPELINE_SOURCE="$source" \
     LOOPER_LIB="$ROOT/looper-lib.sh" PATH="$TMP/bin:$PATH" HOME="$FIX/home" FIX="$FIX" bash "$ROOT/tests/tacplus-dev-plan.inline.sh" >/dev/null 2>&1) \
    || fail "the inline plan failed ($source)"
  got="$(env "${CLEAN[@]}" "${plan_vars[@]}" CI_PIPELINE_SOURCE="$source" LOOPER_LIB="$ROOT/looper-lib.sh" PATH="$TMP/bin:$PATH" \
           HOME="$FIX/home" FIX="$FIX" GITLAB_TOKEN=tok "$ROOT/looper-dispatch" plan 2>/dev/null)" || fail "plan failed ($source)"
  # The scan is as it was; the rest is a report per issue and a manager per repository (looper#70).
  # The jobs' image by digest (looper#115), where the inline plan named the tag.
  sed -i "s|image: ghcr.io/tacplus-dev/looper:main\$|image: ghcr.io/tacplus-dev/looper@sha256:$(printf 'd%.0s' {1..64})|" "$FIX/inline-$source/looper-jobs.yml"
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

# The image the plan's jobs run (looper#115): ghcr.io/tacplus-dev/looper by
# digest, never a tag, the attested build of main's newest commit that has one
# (gh attestation verify: built from that commit of main by main's image.yml);
# none attested in main's last 20 commits fails the plan. LOOPER_JOB_IMAGE, by
# digest alone, instead. And each CI file of ci/ names the looper image by digest.
scenario plan-image
plan_image() { PLAN="$(env -u CI_PIPELINE_SOURCE -u LOOPER_JOB_IMAGE LOOPER_LIB="$ROOT/looper-lib.sh" PATH="$TMP/bin:$PATH" HOME="$FIX/home" \
  FIX="$FIX" GITLAB_TOKEN=tok "$@" "$ROOT/looper-dispatch" plan 2>"$FIX/err")"; }
A="$(printf 'a%.0s' {1..40})"; B="$(printf 'b%.0s' {1..40})"; D="$(printf 'd%.0s' {1..64})"; E="$(printf 'e%.0s' {1..64})"
plan_image || fail "plan failed: $(cat "$FIX/err")"
[[ "$(grep -c '^  image: ' <<<"$PLAN")" == "$(grep -c '^looper-' <<<"$PLAN")" && "$(grep '^  image: ' <<<"$PLAN" | sort -u)" == "  image: ghcr.io/tacplus-dev/looper@sha256:$D" ]] ||
  fail "images: $(grep image: <<<"$PLAN")"
[[ "$(head -1 "$FIX/attest")" == "oci://ghcr.io/tacplus-dev/looper:main-${A::7} --repo tacplus-dev/looper --source-ref refs/heads/main --source-digest $A --cert-identity https://github.com/tacplus-dev/looper/.github/workflows/image.yml@refs/heads/main --deny-self-hosted-runners --format json" ]] ||
  fail "verify: $(cat "$FIX/attest")"
# main's head not built yet: the newest that is, said.
mkdir -p "$FIX/attested"; echo "$E" > "$FIX/attested/${B::7}"
plan_image || fail "plan failed: $(cat "$FIX/err")"
[[ "$(grep '^  image: ' <<<"$PLAN" | sort -u)" == "  image: ghcr.io/tacplus-dev/looper@sha256:$E" ]] || fail "images: $(grep image: <<<"$PLAN")"
grep -qF "main's head ${A::7} has no attested image yet: the jobs run ${B::7}'s, ghcr.io/tacplus-dev/looper@sha256:$E" "$FIX/err" || fail "log: $(cat "$FIX/err")"
rm "$FIX/attested/${B::7}"
! plan_image || fail "planned with no attested image: $PLAN"
grep -qF "no attested build of tacplus-dev/looper's main in its last 20 commits (looper#115): main's image.yml attests each build it pushes; no plan, never the image by a tag" "$FIX/err" || fail "log: $(cat "$FIX/err")"
: > "$FIX/attest"
plan_image LOOPER_JOB_IMAGE="ghcr.io/tacplus-dev/looper@sha256:$E" || fail "plan failed: $(cat "$FIX/err")"
[[ "$(grep '^  image: ' <<<"$PLAN" | sort -u)" == "  image: ghcr.io/tacplus-dev/looper@sha256:$E" && ! -s "$FIX/attest" ]] || fail "LOOPER_JOB_IMAGE: $PLAN"
! plan_image LOOPER_JOB_IMAGE=ghcr.io/tacplus-dev/looper:main || fail "planned with a tag: $PLAN"
grep -qF "LOOPER_JOB_IMAGE ghcr.io/tacplus-dev/looper:main is no image by digest" "$FIX/err" || fail "log: $(cat "$FIX/err")"
for f in "$ROOT"/ci/*.yml; do
  ! grep -nE 'ghcr\.io/tacplus-dev/looper(:[^@[:space:]]*)?([[:space:]]|$)' "$f" | grep -v '^[0-9]*:#' || fail "$f names the looper image by tag"
  ! grep -nE '^[[:space:]]*image: .*ghcr\.io/tacplus-dev/looper' "$f" | grep -vE "@sha256:[0-9a-f]{64}\"?\$" || fail "$f: an image not by digest"
done
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
  '  gcp-token) [[ ! -e "$FIX/no-gcp" ]] && echo gcp-tok ;;' \
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

# Main's ruleset before a report (looper#233): with the apps a report holds
# the report app's token, which only main's ruleset keeps off main, so the
# kicker starts no pipeline, and the plan plans no report, for a public
# repository whose `looper-ruleset check` fails (missing, differing, or a
# check that cannot run), and says why, naming the hub's command; the
# repository's manager is still planned, and another repository's report
# still starts. Without the apps nothing is checked.
scenario apps-ruleset
echo "alpha missing" > "$FIX/ruleset-alpha"
APPS_RUN=(env -u CI_PIPELINE_SOURCE -u GH_TOKEN "${APPS[@]}" LOOPER_LIB="$ROOT/looper-lib.sh" PATH="$TMP/bin:$PATH" HOME="$FIX/home" FIX="$FIX" GITLAB_TOKEN=tok)
OUT="$("${APPS_RUN[@]}" "$ROOT/looper-dispatch" run 2>&1)" || fail "run failed: $OUT"
! started || fail "started a pipeline for a repository with no ruleset: $OUT"
grep -qF "alpha#4 is not started: alpha's main fails looper-ruleset check (alpha missing): a report's token could write it past the gates; the hub runs looper-ruleset apply alpha (looper#233)" <<<"$OUT" || fail "log: $OUT"
[[ "$(cat "$FIX/ruleset")" == "check alpha" ]] || fail "checks: $(cat "$FIX/ruleset")"
issue alpha 6 OPEN "Land it." looper:landing
PLAN="$("${APPS_RUN[@]}" "$ROOT/looper-dispatch" plan 2>"$FIX/err")" || fail "plan failed: $(cat "$FIX/err")"
! grep -qx 'looper-alpha-4:' <<<"$PLAN" || fail "planned a report for a repository with no ruleset: $PLAN"
grep -qx 'looper-alpha-manager:' <<<"$PLAN" || fail "alpha's manager not planned: $(grep '^looper-' <<<"$PLAN")"
grep -qF "alpha#4 is not planned: alpha's main fails looper-ruleset check (alpha missing)" "$FIX/err" || fail "plan log: $(cat "$FIX/err")"
# Another repository's report starts; two of alpha's ready issues, one check a pass.
issue alpha 5 OPEN "Fix it too." approved
issue beta 9 OPEN "Fix it." approved
: > "$FIX/ruleset"
OUT="$("${APPS_RUN[@]}" "$ROOT/looper-dispatch" run 2>&1)" || fail "run failed: $OUT"
started || fail "beta's report not started: $OUT"
grep -q 'started the tacplus-dev/looper pipeline (beta#9 is ready)' <<<"$OUT" || fail "log: $OUT"
[[ "$(cat "$FIX/ruleset")" == $'check alpha\ncheck beta' ]] || fail "checks: $(cat "$FIX/ruleset")"
PLAN="$("${APPS_RUN[@]}" "$ROOT/looper-dispatch" plan 2>"$FIX/err")" || fail "plan failed: $(cat "$FIX/err")"
grep -qx 'looper-beta-9:' <<<"$PLAN" && ! grep -qE '^looper-alpha-[0-9]+:' <<<"$PLAN" || fail "plan: $(grep '^looper-' <<<"$PLAN")"
# A check that cannot run (GitHub down, say) refuses too: never a report on a main it could not read.
rm "$FIX/started" "$FIX/ruleset-alpha" "$FIX/issues/beta-9.json" "$FIX/issues/alpha-6.json"
printf '#!/usr/bin/env bash\necho "[t] FATAL tacplus-dev/alpha: could not list its rulesets" >&2; exit 2\n' > "$FIX/ruleset-fails"; chmod +x "$FIX/ruleset-fails"
OUT="$("${APPS_RUN[@]}" LOOPER_RULESET="$FIX/ruleset-fails" "$ROOT/looper-dispatch" run 2>&1)" || fail "run failed: $OUT"
! started || fail "started with a check that could not run: $OUT"
grep -qE "alpha#[45] is not started: alpha's main could not be checked \(looper-ruleset check: \[t\] FATAL tacplus-dev/alpha: could not list its rulesets\)" <<<"$OUT" || fail "log: $OUT"
# Without the apps: no check.
echo "alpha missing" > "$FIX/ruleset-alpha"; : > "$FIX/ruleset"
dispatch run
started || fail "without the apps, not started: $OUT"
[[ ! -s "$FIX/ruleset" ]] || fail "checked without the apps: $(cat "$FIX/ruleset")"
pass

# The manager split in two (looper#90): with the apps, a repository whose
# gates do not run as build jobs gets two jobs for its batch, ahead of its
# reports: looper-<repo>-verdict (looper-report: the gates, staging) and
# looper-<repo>-manager (looper-manager: main), which needs the verdict's
# artifacts; both on main's resource group. A pinned repository, when the
# project has the build trigger, keeps the one manager (looper#71). A pair
# already active is not planned again: the kicker starts the next batch.
scenario apps-plan-split
issue alpha 6 OPEN "Land it." looper:landing
issue beta 2 OPEN "Land it." looper:landing
split_plan() { PLAN="$(env -u CI_PIPELINE_SOURCE -u GH_TOKEN "${APPS[@]}" "$@" LOOPER_LIB="$ROOT/looper-lib.sh" PATH="$TMP/bin:$PATH" HOME="$FIX/home" FIX="$FIX" GITLAB_TOKEN=tok \
  "$ROOT/looper-dispatch" plan 2>"$FIX/err")" || fail "plan failed: $(cat "$FIX/err")"; }
job_of() { awk -v j="$1:" '$0 == j { on = 1; next } /^[a-z]/ { on = 0 } on' <<<"$PLAN"; }
split_plan
[[ "$(grep -oE '^looper-alpha-[0-9a-z]+' <<<"$PLAN" | paste -sd' ')" == "looper-alpha-verdict looper-alpha-manager looper-alpha-4" ]] \
  || fail "alpha's jobs: $(grep '^looper-' <<<"$PLAN")"
v="$(job_of looper-alpha-verdict)"; m="$(job_of looper-alpha-manager)"
grep -qx '  environment: {name: looper-report, action: prepare}' <<<"$v" || fail "the verdict's environment: $v"
grep -qx '    - repo-looper --repo alpha --verdict looper-verdict' <<<"$v" || fail "the verdict's script: $v"
grep -qx '    paths: \[looper-runs/, looper-verdict/\]' <<<"$v" || fail "the verdict's artifacts: $v"
grep -qx '  resource_group: looper-alpha-main' <<<"$v" || fail "the verdict's group: $v"
grep -qx '  environment: {name: looper-manager, action: prepare}' <<<"$m" || fail "the manager's environment: $m"
grep -qx '    - repo-looper --repo alpha --merge looper-verdict' <<<"$m" || fail "the manager's script: $m"
grep -qx '  needs: \[{job: looper-alpha-verdict, artifacts: true}\]' <<<"$m" || fail "the manager's needs: $m"
grep -qx '  resource_group: looper-alpha-main' <<<"$m" || fail "the manager's group: $m"
grep -qx 'looper-beta-verdict:' <<<"$PLAN" && grep -qx 'looper-beta-manager:' <<<"$PLAN" || fail "beta: $(grep '^looper-' <<<"$PLAN")"
# A pinned repository with the build trigger: its one manager, as before.
mkdir -p "$FIX/contents"; echo "build: x" > "$FIX/contents/alpha-build.lock"
split_plan BUILD_TRIGGER_TOKEN=glptt-x
grep -qx 'looper-alpha-verdict:' <<<"$PLAN" && fail "a pinned repository split: $(grep '^looper-' <<<"$PLAN")"
grep -qx '    - repo-looper --repo alpha --manage' <<<"$(job_of looper-alpha-manager)" || fail "alpha's manager: $(job_of looper-alpha-manager)"
grep -qx 'looper-beta-verdict:' <<<"$PLAN" || fail "beta, unpinned, not split: $(grep '^looper-' <<<"$PLAN")"
# Pinned, but no trigger: its gates would run in a job, so split.
split_plan
grep -qx 'looper-alpha-verdict:' <<<"$PLAN" || fail "pinned without the trigger, not split: $(grep '^looper-' <<<"$PLAN")"
# A batch under way, its verdict running or its manager waiting: no second pair.
for j in "looper-alpha-verdict running" "looper-alpha-manager created"; do
  jobs "$j"; split_plan
  ! grep -qE '^looper-alpha-(verdict|manager):' <<<"$PLAN" || fail "a second batch beside $j: $(grep '^looper-' <<<"$PLAN")"
  grep -qx 'looper-alpha-4:' <<<"$PLAN" || fail "no report beside $j"
done
pass

# The in-cluster runners (looper#84; tacplus-dev/roadmap decisions/only-vms-are-k8s-nodes-2026-11-04.md): a
# repository whose gates are build jobs (its main pinned, the project holding the trigger and the apps: none of
# its jobs runs Docker) has its reports and manager on the control runner, `arm64, control`, each pod with its
# kind's requests and limits (GitLab's KUBERNETES_* variables, within that runner's ceilings); its per-repository
# tag override is not read, so a repository moves the day its pin lands, with nothing changed here. A job that
# would hold looper-docker stays on the VM runners' tags: an unpinned repository's reports, verdict, manager and
# scan (its model runs the gates on main; a pinned one's reads the nightly build's, looper#73). A control job's retry: is as before: it resumes from its
# checkpoint. The plan's one job with nothing to plan takes the control tags once the project has the trigger.
scenario plan-control
issue tacplus 5 OPEN "Go." approved
issue alpha 6 OPEN "Land it." looper:landing
mkdir -p "$FIX/contents"; echo "build: x" > "$FIX/contents/alpha-build.lock"
control_plan() { PLAN="$(env -u CI_PIPELINE_SOURCE -u GH_TOKEN -u LOOPER_JOB_TAGS -u BUILD_TRIGGER_TOKEN "${APPS[@]}" LOOPER_JOB_TAGS_tacplus="arm64, autoscale-16" "$@" \
  LOOPER_LIB="$ROOT/looper-lib.sh" PATH="$TMP/bin:$PATH" HOME="$FIX/home" FIX="$FIX" GITLAB_TOKEN=tok "$ROOT/looper-dispatch" plan 2>"$FIX/err")" || fail "plan failed: $(cat "$FIX/err")"
  sed -n 's/^  tags: \[\(.*\)\]$/\1/p' <<<"$PLAN" >> "$FIX/plan-tags"; }
vars_of() { awk -v j="$1:" '$0 == j {f=1; next} /^[^ ]/ {f=0} f && /^  variables:/ {v=1; next} f && /^  [a-z]/ {v=0} f && v {sub(/^    /, ""); print}' <<<"$PLAN" | paste -sd' '; }
control_plan BUILD_TRIGGER_TOKEN=glptt-x
[[ "$(tags_of alpha-4)" == "[arm64, control]" ]] || fail "alpha's report: $(tags_of alpha-4): $PLAN"
[[ "$(vars_of looper-alpha-4)" == 'LOOPER_RUNS: $CI_PROJECT_DIR/looper-runs KUBERNETES_CPU_REQUEST: 150m KUBERNETES_MEMORY_REQUEST: 512Mi KUBERNETES_CPU_LIMIT: 1500m KUBERNETES_MEMORY_LIMIT: 4Gi' ]] \
  || fail "alpha's report's requests: $(vars_of looper-alpha-4)"
[[ "$(tags_of alpha-manager)" == "[arm64, control]" ]] || fail "alpha's manager: $(tags_of alpha-manager)"
[[ "$(vars_of looper-alpha-manager)" == 'LOOPER_RUNS: $CI_PROJECT_DIR/looper-runs KUBERNETES_CPU_REQUEST: 250m KUBERNETES_MEMORY_REQUEST: 256Mi KUBERNETES_CPU_LIMIT: 1 KUBERNETES_MEMORY_LIMIT: 2Gi' ]] \
  || fail "alpha's manager's requests: $(vars_of looper-alpha-manager)"
grep -qx '    - repo-looper --repo alpha --manage' <<<"$(job_of looper-alpha-manager)" || fail "alpha's manager: $(job_of looper-alpha-manager)"
# tacplus, unpinned: its reports on their VM override, its split batch's jobs as before (the verdict runs its
# gates, on the reports' pool), no requests.
[[ "$(tags_of tacplus-5)" == "[arm64, autoscale-16]" ]] || fail "tacplus's report: $(tags_of tacplus-5)"
[[ "$(tags_of tacplus-verdict)" == "[arm64, autoscale-16]" && "$(tags_of tacplus-manager)" == "[arm64, autoscale-16]" ]] || fail "tacplus's batch: $(tags_of tacplus-verdict) $(tags_of tacplus-manager)"
! grep -q KUBERNETES_ <<<"$(job_of looper-tacplus-5)$(job_of looper-tacplus-verdict)$(job_of looper-tacplus-manager)" || fail "requests on a VM job: $PLAN"
# A control job's retry is a control job's: it resumes from its checkpoint; no job asks for a VM tag it is not given.
grep -qx '    when: \[runner_system_failure, scheduler_failure, unknown_failure\]' <<<"$(job_of looper-alpha-4)" || fail "alpha's retry: $(job_of looper-alpha-4)"
! grep -q stuck_or_timeout <<<"$PLAN" || fail "a control job retried on its own timeout: $PLAN"
grep -qF 'planned looper-alpha-4 (5h, tags arm64, control, resource_group looper-alpha-4)' "$FIX/err" || fail "the plan's log: $(cat "$FIX/err")"
# tacplus pinned: its jobs move, its override unread, nothing else changed.
echo "tacplus: x" > "$FIX/contents/tacplus-tacplus.lock"
control_plan BUILD_TRIGGER_TOKEN=glptt-x
[[ "$(tags_of tacplus-5)" == "[arm64, control]" && "$(tags_of tacplus-manager)" == "[arm64, control]" ]] || fail "tacplus pinned: $(tags_of tacplus-5) $(tags_of tacplus-manager)"
! grep -q 'looper-tacplus-verdict:' <<<"$PLAN" || fail "tacplus pinned, still split: $(grep '^looper-' <<<"$PLAN")"
rm "$FIX/contents/tacplus-tacplus.lock"
# The control tags and a kind's requests are the instance's to set.
control_plan BUILD_TRIGGER_TOKEN=glptt-x LOOPER_CONTROL_TAGS="arm64, ctl" LOOPER_REQUESTS_report="1 2Gi 1500m 4Gi"
[[ "$(tags_of alpha-4)" == "[arm64, ctl]" && "$(tags_of alpha-manager)" == "[arm64, ctl]" ]] || fail "LOOPER_CONTROL_TAGS: $(tags_of alpha-4)"
[[ "$(vars_of looper-alpha-4)" == *'KUBERNETES_CPU_REQUEST: 1 KUBERNETES_MEMORY_REQUEST: 2Gi KUBERNETES_CPU_LIMIT: 1500m KUBERNETES_MEMORY_LIMIT: 4Gi' ]] || fail "LOOPER_REQUESTS_report: $(vars_of looper-alpha-4)"
# Without the trigger a pinned repository's jobs hold looper-docker (looper#71): the VM tags, no requests.
control_plan
[[ "$(tags_of alpha-4)" == "[arm64, autoscale]" && "$(tags_of alpha-manager)" == "[arm64, autoscale]" ]] || fail "without the trigger: $(tags_of alpha-4) $(tags_of alpha-manager)"
! grep -q KUBERNETES_ <<<"$PLAN" || fail "requests without the trigger: $PLAN"
# A pinned repository's scan reads the nightly build's gates and holds no looper-docker (looper#73): on the
# control runner, with a model's requests (a report's), its override unread; an unpinned one's stays on the VM tags.
printf '%s\n' alpha tacplus > "$FIX/repos"
control_plan BUILD_TRIGGER_TOKEN=glptt-x CI_PIPELINE_SOURCE=schedule LOOPER_SCAN_TAGS_alpha="arm64, lab"
[[ "$(tags_of scan-alpha)" == "[arm64, control]" ]] || fail "alpha's scan: $(tags_of scan-alpha): $PLAN"
[[ "$(vars_of looper-scan-alpha)" == *'KUBERNETES_CPU_REQUEST: 150m KUBERNETES_MEMORY_REQUEST: 512Mi KUBERNETES_CPU_LIMIT: 1500m KUBERNETES_MEMORY_LIMIT: 4Gi' ]] \
  || fail "alpha's scan's requests: $(vars_of looper-scan-alpha)"
[[ "$(tags_of scan-tacplus)" == "[arm64, autoscale]" ]] || fail "tacplus's scan: $(tags_of scan-tacplus)"
! grep -q KUBERNETES_ <<<"$(job_of looper-scan-tacplus)" || fail "requests on a VM scan: $(job_of looper-scan-tacplus)"
control_plan BUILD_TRIGGER_TOKEN=glptt-x CI_PIPELINE_SOURCE=schedule LOOPER_REQUESTS_scan="1 2Gi 1500m 4Gi"
[[ "$(vars_of looper-scan-alpha)" == *'KUBERNETES_CPU_REQUEST: 1 KUBERNETES_MEMORY_REQUEST: 2Gi KUBERNETES_CPU_LIMIT: 1500m KUBERNETES_MEMORY_LIMIT: 4Gi' ]] \
  || fail "LOOPER_REQUESTS_scan: $(vars_of looper-scan-alpha)"
control_plan CI_PIPELINE_SOURCE=schedule
[[ "$(tags_of scan-alpha)" == "[arm64, autoscale]" ]] || fail "alpha's scan without the trigger: $(tags_of scan-alpha)"
# Nothing to plan: the one job that says so runs on the control runner with the trigger, else on the VM tags.
rm "$FIX/issues/tacplus-5.json" "$FIX/issues/alpha-6.json"; jobs "looper-alpha-4 running"
control_plan BUILD_TRIGGER_TOKEN=glptt-x
[[ "$(tags_of none)" == "[arm64, control]" ]] || fail "looper-none: $(tags_of none): $PLAN"
control_plan
[[ "$(tags_of none)" == "[arm64, autoscale]" ]] || fail "looper-none without the trigger: $(tags_of none)"
# The kicker and the plan never share a runner with what the plan starts (looper#222): GitLab gives a job to any
# runner holding all its tags, so neither the kick jobs' tag set nor any planned job's (a report, manager, scan,
# verdict or looper-none, each placement above) holds the other: a full control runner never holds a kick back.
kick="$(sed -n '/^\.kick:$/,/^[^ ]/s/^  tags: \[\(.*\)\]$/\1/p' "$ROOT/ci/tacplus-dev.gitlab-ci.yml")"
[[ -n "$kick" ]] || fail "no .kick tags in ci/tacplus-dev.gitlab-ci.yml"
holds() { local t; for t in ${2//,/ }; do [[ " ${1//,/ } " == *" $t "* ]] || return 1; done; }   # set $1 holds every tag of $2
[[ -s "$FIX/plan-tags" ]] || fail "no planned job's tags"
while read -r t; do
  ! holds "$t" "$kick" && ! holds "$kick" "$t" || fail "the kick jobs' tags [$kick] and a planned job's [$t] share a runner"
done < <(sort -u "$FIX/plan-tags")
pass

# The control jobs of tacplus-dev's own pipeline file (looper#84): the hub's probes on the control runner, the
# kicker and the plan on the kick runner (looper#222; tacplus-dev/cluster#39), each with the control kind's requests,
# and no job of the file on a VM runner's tag (autoscale, autoscale-16, gce): only tacplus's per-repository override
# names one, for its reports until its pin lands.
scenario ci-control
f="$ROOT/ci/tacplus-dev.gitlab-ci.yml"
for j in looper-ruleset-probe looper-token-diagnose; do
  awk -v j="$j:" '$0 == j {f=1; next} /^[^ ]/ {f=0} f' "$f" | grep -qx '  extends: \[.looper-identity, .control\]' || fail "$j is not a control job"
done
for j in looper-plan looper-kick; do
  awk -v j="$j:" '$0 == j {f=1; next} /^[^ ]/ {f=0} f' "$f" | grep -qx '  extends: \[.looper-identity, .kick\]' || fail "$j is not a kick job"
done
awk '$0 == ".control:" {f=1; next} /^[^ ]/ {f=0} f' "$f" > "$FIX/control"
grep -qx '  tags: \[arm64, control\]' "$FIX/control" || fail ".control's tags: $(cat "$FIX/control")"
for v in 'KUBERNETES_CPU_REQUEST: 50m' 'KUBERNETES_MEMORY_REQUEST: 256Mi' 'KUBERNETES_CPU_LIMIT: 1' 'KUBERNETES_MEMORY_LIMIT: 1Gi'; do
  grep -qx "    $v" "$FIX/control" || fail ".control's requests lack $v: $(cat "$FIX/control")"
done
# .kick is .control (its requests, the kick runner's defaults, and its retry) on the kick runner's tags.
[[ "$(awk '$0 == ".kick:" {f=1; next} /^[^ ]/ {f=0} f' "$f")" == $'  extends: .control\n  tags: [arm64, kick]' ]] \
  || fail ".kick: $(awk '$0 == ".kick:" {f=1; next} /^[^ ]/ {f=0} f' "$f")"
! grep -nE '^\s*tags:.*(autoscale|gce)' "$f" || fail "a job of $f asks for a VM runner's tag"
[[ "$(grep -cE 'autoscale|gce' "$f")" == "$(grep -cE '^\s*LOOPER_JOB_TAGS_tacplus: |^\s*#.*(autoscale|gce)' "$f")" ]] || fail "a VM runner's tag outside tacplus's override and the comments: $(grep -nE 'autoscale|gce' "$f")"
pass

scenario apps-no-pat
# Fake personal tokens, built at run time: no literal for the secret scan (looper#117).
FAKE=0123456789abcdef
for v in "GH_TOKEN=ghp_${FAKE}0123" GITHUB_TOKEN=x "SOMETHING=github_pat_$FAKE"; do
  ! OUT="$(env -u GH_TOKEN "${APPS[@]}" "$v" LOOPER_LIB="$ROOT/looper-lib.sh" PATH="$TMP/bin:$PATH" HOME="$FIX/home" FIX="$FIX" GITLAB_TOKEN=tok "$ROOT/looper-dispatch" run 2>&1)" ||
    fail "ran holding ${v%%=*}: $OUT"
  grep -q "this job holds ${v%%=*}" <<<"$OUT" || fail "log: $OUT"
done
! started || fail "started a pipeline holding a personal token"
GH_TOKEN="ghp_${FAKE}0123" dispatch run
started || fail "without the apps a GH_TOKEN is as before: $OUT"
pass

# Nothing runs on the Mac any more: there is no launchd install.
scenario no-install
dispatch_fails install
[[ ! -e "$FIX/home/Library" ]] || fail "installed something"
pass

# A project on its own looper VM (looper#241): its ready issue starts its VM
# (its group sized 0 -> 1), and neither the kicker nor the plan gives it a
# report job here; its lands still get their manager. A VM that cannot be read
# or started never stalls the repository: its reports run here, as before.
VMENV=(LOOPER_VM_REPOS=alpha LOOPER_TOKEN="$TMP/bin/looper-token-stub" LOOPER_REPORT_APP_ID=7 GCP_WIF_PROVIDER=projects/1/locations/global/workloadIdentityPools/p/providers/r)
vm_plan() { env -u CI_PIPELINE_SOURCE -u GH_TOKEN "${VMENV[@]}" "$@" LOOPER_LIB="$ROOT/looper-lib.sh" PATH="$TMP/bin:$PATH" HOME="$FIX/home" FIX="$FIX" GITLAB_TOKEN=tok \
  "$ROOT/looper-dispatch" plan 2>"$FIX/err"; }
scenario vm-kick
echo 0 > "$FIX/vm-alpha"
OUT="$(env -u CI_API_V4_URL -u CI_PIPELINE_SOURCE -u GH_TOKEN "${VMENV[@]}" LOOPER_LIB="$ROOT/looper-lib.sh" PATH="$TMP/bin:$PATH" HOME="$FIX/home" FIX="$FIX" GITLAB_TOKEN=tok \
  "$ROOT/looper-dispatch" run 2>&1)" || fail "the kick failed: $OUT"
[[ "$(cat "$FIX/vm-calls" 2>/dev/null)" == "resize alpha 1" ]] || fail "the VM was not started: $(cat "$FIX/vm-calls" 2>/dev/null) $OUT"
[[ ! -s "$FIX/started" ]] || fail "a pipeline was started for a VM project: $(cat "$FIX/started")"
grep -qF "alpha's looper VM is up or started" <<<"$OUT" || fail "the log: $OUT"
pass
# The VM's own reports hold looper:in-progress with no job here: the kicker
# leaves the label (the VM resumes the issue itself).
scenario vm-orphan-kept
in_progress
echo 1 > "$FIX/vm-alpha"
OUT="$(env -u CI_API_V4_URL -u CI_PIPELINE_SOURCE -u GH_TOKEN "${VMENV[@]}" LOOPER_LIB="$ROOT/looper-lib.sh" PATH="$TMP/bin:$PATH" HOME="$FIX/home" FIX="$FIX" GITLAB_TOKEN=tok \
  "$ROOT/looper-dispatch" run 2>&1)" || fail "the kick failed: $OUT"
[[ "$(labels alpha 4)" == approved,looper:in-progress ]] || fail "the VM's label was removed: $(labels alpha 4) $OUT"
[[ ! -s "$FIX/comments" ]] || fail "commented: $(cat "$FIX/comments")"
pass
# Its VM off, nothing holds the issue: released, so it is ready and the VM is
# started for it. A group that cannot be read releases nothing.
scenario vm-orphan-vm-off
in_progress
echo 0 > "$FIX/vm-alpha"
OUT="$(env -u CI_API_V4_URL -u CI_PIPELINE_SOURCE -u GH_TOKEN "${VMENV[@]}" LOOPER_LIB="$ROOT/looper-lib.sh" PATH="$TMP/bin:$PATH" HOME="$FIX/home" FIX="$FIX" GITLAB_TOKEN=tok \
  "$ROOT/looper-dispatch" run 2>&1)" || fail "the kick failed: $OUT"
[[ "$(labels alpha 4)" == approved ]] || fail "the label stayed with the VM off: $(labels alpha 4) $OUT"
grep -q '^alpha#4 .*its looper VM (looper-vm-alpha) is off' "$FIX/comments" || fail "comments: $(cat "$FIX/comments" 2>/dev/null)"
[[ "$(cat "$FIX/vm-calls" 2>/dev/null)" == "resize alpha 1" ]] || fail "the VM was not started for it: $(cat "$FIX/vm-calls" 2>/dev/null) $OUT"
pass
scenario vm-orphan-vm-unread
in_progress
OUT="$(env -u CI_API_V4_URL -u CI_PIPELINE_SOURCE -u GH_TOKEN "${VMENV[@]}" LOOPER_LIB="$ROOT/looper-lib.sh" PATH="$TMP/bin:$PATH" HOME="$FIX/home" FIX="$FIX" GITLAB_TOKEN=tok \
  "$ROOT/looper-dispatch" run 2>&1)" || fail "the kick failed: $OUT"
[[ "$(labels alpha 4)" == approved,looper:in-progress ]] || fail "released with its group unread: $(labels alpha 4) $OUT"
pass
# An org's shared VM (decision point 12): `*=shared` takes every repository not
# named on its own, so alpha's ready issue starts looper-vm-shared, and a
# repository named on its own (alpha=solo) keeps its own group.
scenario vm-shared
echo 0 > "$FIX/vm-shared"
OUT="$(env -u CI_API_V4_URL -u CI_PIPELINE_SOURCE -u GH_TOKEN "${VMENV[@]}" LOOPER_VM_REPOS='beta *=shared' LOOPER_LIB="$ROOT/looper-lib.sh" PATH="$TMP/bin:$PATH" HOME="$FIX/home" FIX="$FIX" GITLAB_TOKEN=tok \
  "$ROOT/looper-dispatch" run 2>&1)" || fail "the kick failed: $OUT"
[[ "$(cat "$FIX/vm-calls" 2>/dev/null)" == "resize shared 1" ]] || fail "the shared VM was not started: $(cat "$FIX/vm-calls" 2>/dev/null) $OUT"
[[ ! -s "$FIX/started" ]] || fail "a pipeline was started for a shared-VM project: $(cat "$FIX/started")"
grep -qF "alpha's looper VM is up or started (looper-vm-shared)" <<<"$OUT" || fail "the log: $OUT"
pass
scenario vm-own-over-shared
echo 0 > "$FIX/vm-solo"; echo 0 > "$FIX/vm-shared"
OUT="$(env -u CI_API_V4_URL -u CI_PIPELINE_SOURCE -u GH_TOKEN "${VMENV[@]}" LOOPER_VM_REPOS='*=shared alpha=solo' LOOPER_LIB="$ROOT/looper-lib.sh" PATH="$TMP/bin:$PATH" HOME="$FIX/home" FIX="$FIX" GITLAB_TOKEN=tok \
  "$ROOT/looper-dispatch" run 2>&1)" || fail "the kick failed: $OUT"
[[ "$(cat "$FIX/vm-calls" 2>/dev/null)" == "resize solo 1" ]] || fail "alpha's own VM was not the one started: $(cat "$FIX/vm-calls" 2>/dev/null) $OUT"
pass
scenario vm-plan
echo 1 > "$FIX/vm-alpha"
issue alpha 6 OPEN "Land it." looper:landing
PLAN="$(vm_plan)" || fail "plan failed: $(cat "$FIX/err")"
grep -q '^looper-alpha-4:' <<<"$PLAN" && fail "a report job was planned for a VM project: $PLAN"
grep -q '^looper-alpha-manager:' <<<"$PLAN" || fail "the VM project's lands got no manager: $PLAN"
[[ ! -s "$FIX/vm-calls" ]] || fail "a running VM was resized: $(cat "$FIX/vm-calls")"
pass
scenario vm-fallback
PLAN="$(vm_plan)" || fail "plan failed: $(cat "$FIX/err")"
grep -q '^looper-alpha-4:' <<<"$PLAN" || fail "no VM group, and no report planned: $PLAN"
grep -qF "alpha's looper VM did not start" "$FIX/err" || fail "the fallback is not logged: $(cat "$FIX/err")"
touch "$FIX/no-gcp"; echo 0 > "$FIX/vm-alpha"
PLAN="$(vm_plan)" || fail "plan failed: $(cat "$FIX/err")"
grep -q '^looper-alpha-4:' <<<"$PLAN" && grep -qF 'no Google access token' "$FIX/err" || fail "no token, and no fallback: $PLAN $(cat "$FIX/err")"
pass

echo "looper-dispatch: all scenarios pass"
