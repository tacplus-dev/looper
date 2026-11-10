#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# The forge layer (looper#29): the same scenarios on both backends, github
# (a stub `gh`) and gitlab (a stub `curl` that answers as GitLab's API v4),
# over one store of issues: listing the ready issues (one repository and the
# whole org, in priority order), Blocked-by within and across repositories
# (GitLab subgroups too) and to another org (held, never read), labels,
# comments and body edits, the issues' texts with their authors' standing,
# clone and push over HTTPS (tests/git-server.py as github.com and
# gitlab.com), and looper-dispatch's ready, plan and orphan release.
# Run: tests/forge.test.sh
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/hermetic.sh"   # the test's own environment, not the job's (looper#97, looper#103)
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; SRVPID=""
trap '[[ -z "$SRVPID" ]] || kill "$SRVPID" 2>/dev/null; rm -rf "$TMP"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
# A fake token, built at run time so that no literal in the tree looks like one
# to the build's secret scan (looper#117).
TOKEN="glpat-$(printf forgetest%s token0123456789)"

# The store: $FIX/issues/<repo, / as __>-<n>.json, gh's shape plus `repo` (the
# path under the org), `author` and `comments` ([{author, body, system}]).
# Writes go to the store; every call is appended to $FIX/calls, as
# "gh <args>" or "<METHOD> <path>". $FIX/members.json maps GitLab logins to
# their access level in every project; $FIX/permissions.json GitHub
# collaborators' permissions. GitHub associations: an issue's or comment's
# `association`, default MEMBER. A repository's labels: $FIX/labels/<repo, /
# as __>, a name a line (an issue's labels are its repository's): GitHub
# refuses an edit that names a label the repository lacks, as gh does
# (looper#80), and a label created twice; GitLab creates the labels an edit
# adds, as its API does. Each label created is appended to
# $FIX/labels-created as "<repo> <label>".
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "gh $*" >> "$FIX/calls"
file() { echo "$FIX/issues/${1//\//__}-$2.json"; } # repo n
cmd="$1 $2"; shift 2
case "$cmd" in
  "auth setup-git")
    # As gh does: a credential helper for github.com that answers from GH_TOKEN.
    git config --global --replace-all credential.https://github.com.helper ''
    git config --global --add credential.https://github.com.helper '!f() { test "$1" = get || exit 0; echo username=x-access-token; echo "password=$GH_TOKEN"; }; f'
    exit 0 ;;
  "repo clone") git clone -q "https://github.com/$1.git" "$2"; exit 0 ;;
  "api graphql")
    q="${2#query=}"; data='{}'; rc=0
    while read -r a o r n; do
      f="$(file "$r" "$n")"
      if [[ "$o" == "$ORG" && -f "$f" ]]; then data="$(jq --arg a "$a" --slurpfile i "$f" '.[$a] = {issue: {state: $i[0].state}}' <<<"$data")"
      else data="$(jq --arg a "$a" '.[$a] = null' <<<"$data")"; rc=1; fi
    done < <(grep -oE '[a-z][a-z0-9_]*: repository\(owner: "[^"]+", name: "[^"]+"\) \{ issue\(number: [0-9]+\)' <<<"$q" \
               | sed -E 's/^([a-z0-9_]+): repository\(owner: "([^"]+)", name: "([^"]+)"\) \{ issue\(number: ([0-9]+)\)/\1 \2 \3 \4/')
    jq -c '{data: .}' <<<"$data"; exit "$rc" ;;
esac
repo=""; n=""; q="."; add=(); rm=(); body=""; has_body=""; labels=(); state=open; limit=30; owner=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) [[ "${2%%/*}" == "$ORG" ]] || { echo "stub gh: not $ORG: $2" >&2; exit 1; }; repo="${2#*/}"; shift 2 ;;
    --owner) owner="$2"; shift 2 ;;
    --jq) q="$2"; shift 2 ;;
    --add-label) add+=("$2"); shift 2 ;;
    --remove-label) rm+=("$2"); shift 2 ;;
    --body) body="$2"; has_body=1; shift 2 ;;
    --label) labels+=("$2"); shift 2 ;;
    --state) state="$2"; shift 2 ;;
    --limit) limit="$2"; shift 2 ;;
    --json|--color|--description|-H) shift 2 ;;
    --paginate|--no-archived) shift ;;
    *) n="$1"; shift ;;
  esac
done
f="$(file "$repo" "$n")"
all() { jq -s --arg s "$state" '[.[] | select(($s == "all" or .state == ($s | ascii_upcase)) and ([.labels[].name] | contains($ARGS.positional)))] | sort_by(-.number)' \
          "$FIX"/issues/*.json --args "${labels[@]+"${labels[@]}"}"; }
case "$cmd" in
  api\ repos/*/contents/*)
    p="${cmd#api repos/}"; [[ "${p%%/*}" == "$ORG" ]] || exit 1; p="${p#*/}"
    t="$FIX/files/${p%%/contents/*}/${p#*/contents/}"; [[ -f "$t" ]] || { echo "stub gh: HTTP 404" >&2; exit 1; }; cat "$t" ;;
  api\ repos/*/collaborators/*/permission)
    l="${cmd%/permission}"; l="${l##*/}"
    jq -e --arg l "$l" 'has($l)' "$FIX/permissions.json" >/dev/null || { echo "stub gh: HTTP 404" >&2; exit 1; }
    jq --arg l "$l" '{permission: .[$l]}' "$FIX/permissions.json" | jq -r "$q" ;;
  api\ repos/*/issues/*)
    p="${cmd#api repos/}"; [[ "${p%%/*}" == "$ORG" ]] || exit 1; p="${p#*/}"
    f="$(file "${p%%/*}" "$(cut -d/ -f3 <<<"$p")")"; [[ -f "$f" ]] || { echo "stub gh: HTTP 404" >&2; exit 1; }
    if [[ "$p" == */comments ]]; then jq '[.comments[] | {body, user: {login: .author}, author_association: (.association // "MEMBER")}]' "$f"
    else jq '{number, title, body, comments: ([.comments[]? | select(.system | not)] | length), user: {login: (.author // "jody")}, author_association: (.association // "MEMBER")}' "$f"; fi | jq -r "$q" ;;
  "label list") jq -R '{name: .}' "$FIX/labels/${repo//\//__}" 2>/dev/null | jq -s . | jq -r "$q" ;;
  "label create")
    ! grep -qxF -- "$n" "$FIX/labels/${repo//\//__}" 2>/dev/null || { echo "label with name \"$n\" already exists; use \`--force\` to update its color and description" >&2; exit 1; }
    echo "$n" >> "$FIX/labels/${repo//\//__}"; echo "$repo $n" >> "$FIX/labels-created" ;;
  "repo list") [[ "$n" == "$ORG" ]] || exit 1; jq -R '{name: .}' "$FIX/repos" | jq -s . | jq -r "$q" ;;
  "search issues")
    [[ "$owner" == "$ORG" ]] || exit 1
    all | jq --argjson l "$limit" '.[:$l] | map(. + {repository: {name: .repo}})' | jq -r "$q" ;;
  "issue list") all | jq --arg r "$repo" --argjson l "$limit" '[.[] | select(.repo == $r)][:$l]' | jq -r "$q" ;;
  "issue view") [[ -f "$f" ]] || { echo "stub gh: no issue $repo#$n" >&2; exit 1; }; jq -r "$q" "$f" ;;
  "issue edit")
    for l in "${add[@]+"${add[@]}"}" "${rm[@]+"${rm[@]}"}"; do
      grep -qxF -- "$l" "$FIX/labels/${repo//\//__}" 2>/dev/null || { echo "failed to update https://github.com/$ORG/$repo/issues/$n: '$l' not found" >&2; exit 1; }
    done
    t="$(cat "$f")"
    for l in "${add[@]+"${add[@]}"}"; do t="$(jq --arg l "$l" '.labels |= (. + [{name: $l}] | unique)' <<<"$t")"; done
    for l in "${rm[@]+"${rm[@]}"}"; do t="$(jq --arg l "$l" '.labels |= map(select(.name != $l))' <<<"$t")"; done
    [[ -n "$has_body" ]] && t="$(jq --arg b "$body" '.body = $b' <<<"$t")"
    printf '%s\n' "$t" > "$f" ;;
  "issue comment") t="$(jq --arg b "$body" '.comments += [{author: "looper", body: $b}]' "$f")"; printf '%s\n' "$t" > "$f" ;;
  *) echo "stub gh: unexpected $cmd" >&2; exit 3 ;;
esac
EOF
# GitLab's API v4 at https://gitlab.com/api/v4, from the store: a request
# whose PRIVATE-TOKEN header (from a file, -H @file) is not $TOKEN gets 401;
# each request's argv is appended to $FIX/argv. The jobs API of the pipeline's
# project answers $FIX/jobs.json filtered by its scope[] parameters. Other
# URLs (git-server.py's) are the real curl's.
cat > "$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
echo "$*" >> "$FIX/argv"
m=GET; url=""; tok=""; out=""; w=""; f=""; data=()
while [[ $# -gt 0 ]]; do case "$1" in
  -X) m="$2"; shift 2 ;;
  -H) h="$2"; [[ "$h" == @* ]] && h="$(cat "${h#@}")"; [[ "$h" == "PRIVATE-TOKEN: "* ]] && tok="${h#PRIVATE-TOKEN: }"; shift 2 ;;
  --data-urlencode|-d|--data) data+=("$2"); shift 2 ;;
  -o) out="$2"; shift 2 ;; -w) w="$2"; shift 2 ;; --retry) shift 2 ;;
  http*) url="$1"; shift ;; -*f*) f=1; shift ;; *) shift ;;
esac; done
dec() { local s="${1//+/ }"; printf '%b' "${s//%/\\x}"; }
reply() { # code body; with -f, an error's body is not written, as curl does
  [[ "$1" == 20? || -z "$f" ]] || { echo "curl: (22) The requested URL returned error: $1" >&2; exit 22; }
  if [[ -n "$out" ]]; then printf '%s\n' "$2" > "$out"; else printf '%s\n' "$2"; fi
  [[ -z "$w" ]] || printf '%s' "$1"
  exit 0
}
[[ "$url" == https://gitlab.com/api/v4/* ]] || { echo "stub curl: unexpected $url" >&2; exit 7; }
p="${url#https://gitlab.com/api/v4/}"; qs=""; [[ "$p" == *\?* ]] && { qs="${p#*\?}"; p="${p%%\?*}"; }
echo "$m $(dec "$p")${qs:+?$(dec "$qs")}" >> "$FIX/calls"
param() { local kv; for kv in ${qs//&/ }; do [[ "${kv%%=*}" == "$1" ]] && { dec "${kv#*=}"; return 0; }; done; return 1; }
datum() { local kv; for kv in "${data[@]+"${data[@]}"}"; do [[ "${kv%%=*}" == "$1" ]] && { printf '%s' "${kv#*=}"; return 0; }; done; return 1; }
if [[ "$p" == "projects/$(jq -rn --arg s "$PIPELINE" '$s | @uri')/jobs" ]]; then
  [[ "$tok" == "$GITLAB_TOKEN" ]] || reply 401 '{"message":"401 Unauthorized"}'
  reply 200 "$(jq --arg s "$(grep -oE 'scope\[\]=[a-z_]+' <<<"$(dec "$qs")" | cut -d= -f2 | paste -sd, -)" '[.[] | select(.status | IN($s | split(",")[]))]' "$FIX/jobs.json")"
fi
[[ "$tok" == "$TOKEN" ]] || reply 401 '{"message":"401 Unauthorized"}'
[[ "$(param page || echo 1)" == 1 ]] || reply 200 '[]'
GL='{iid: .number, title, description: .body, state: (if .state == "OPEN" then "opened" else "closed" end),
     labels: [.labels[].name], created_at: .createdAt, author: {username: (.author // "jody")},
     user_notes_count: ([.comments[]? | select(.system | not)] | length),
     references: {full: ($org + "/" + .repo + "#" + (.number | tostring))}}'
list() { # repo or "" (the group): state, labels from the query
  local st labels; st="$(param state || echo all)"; labels="$(param labels || true)"
  jq -s --arg org "$ORG" --arg r "$1" --arg st "$st" --arg l "$labels" "
    [.[] | select(\$r == \"\" or .repo == \$r)
         | select(\$st == \"all\" or (\$st == \"opened\") == (.state == \"OPEN\"))
         | select([.labels[].name] | contains(\$l | split(\",\") | map(select(. != \"\"))))]
    | sort_by(-.number) | map($GL)" "$FIX"/issues/*.json
}
path="$(dec "$p")"
case "$m $path" in
  "GET groups/$ORG/issues") reply 200 "$(list "")" ;;
  "GET groups/$ORG/projects") reply 200 "$(jq -R --arg org "$ORG" '{path_with_namespace: ($org + "/" + .)}' "$FIX/repos" | jq -s .)" ;;
  "GET projects/$ORG/"*) ;; "PUT projects/$ORG/"*) ;; "POST projects/$ORG/"*) ;;
  *) reply 404 '{"message":"404 Not found"}' ;;
esac
rest="${path#projects/"$ORG"/}"
case "$rest" in
  */repository/files/*/raw) t="$FIX/files/${rest%%/repository/files/*}/${rest#*/repository/files/}"; t="${t%/raw}"
    [[ -f "$t" ]] || reply 404 '{"message":"404 File Not Found"}'; reply 200 "$(cat "$t")" ;;
  */members/all) u="$(param query)"
    reply 200 "$(jq --arg u "$u" '[to_entries[] | select(.key | contains($u)) | {username: .key, access_level: .value}]' "$FIX/members.json")" ;;
  */labels) lf="$FIX/labels/$(sed 's#/#__#g' <<<"${rest%/labels}")"
    [[ "$m" != GET ]] || reply 200 "$(jq -R '{name: .}' "$lf" 2>/dev/null | jq -s .)"
    [[ "$m" == POST ]] || reply 404 '{}'
    ! grep -qxF -- "$(datum name)" "$lf" 2>/dev/null || reply 409 '{"message":"Label already exists"}'
    datum name >> "$lf"; echo >> "$lf"; echo "${rest%/labels} $(datum name)" >> "$FIX/labels-created"; reply 201 '{}' ;;
  */issues) reply 200 "$(list "${rest%/issues}")" ;;
esac
repo="$(sed -E 's#/issues/[0-9]+(/notes)?$##' <<<"$rest")"; n="$(grep -oE '/issues/[0-9]+' <<<"$rest" | tr -dc 0-9)"
file="$FIX/issues/${repo//\//__}-$n.json"
[[ -n "$n" && -f "$file" ]] || reply 404 '{"message":"404 Issue Not Found"}'
case "$m $rest" in
  "GET "*/notes) reply 200 "$(jq '[.comments[] | {body, system: (.system // false), author: {username: .author}}]' "$file")" ;;
  "POST "*/notes) t="$(jq --arg b "$(datum body)" '.comments += [{author: "looper", body: $b}]' "$file")"; printf '%s\n' "$t" > "$file"; reply 201 '{}' ;;
  "GET "*) reply 200 "$(jq --arg org "$ORG" "$GL" "$file")" ;;
  "PUT "*)
    t="$(cat "$file")"
    # GitLab creates a label an edit adds that the project lacks.
    if a="$(datum add_labels)"; then tr , '\n' <<<"$a" | while IFS= read -r l; do grep -qxF -- "$l" "$FIX/labels/${repo//\//__}" 2>/dev/null || echo "$l" >> "$FIX/labels/${repo//\//__}"; done; fi
    if a="$(datum add_labels)"; then t="$(jq --arg l "$a" '.labels |= (. + ($l | split(",") | map({name: .})) | unique)' <<<"$t")"; fi
    if r="$(datum remove_labels)"; then t="$(jq --arg l "$r" '.labels |= map(select(.name | IN($l | split(",")[]) | not))' <<<"$t")"; fi
    if d="$(datum description)"; then t="$(jq --arg b "$d" '.body = $b' <<<"$t")"; fi
    printf '%s\n' "$t" > "$file"; reply 200 "$(jq --arg org "$ORG" "$GL" <<<"$t")" ;;
esac
reply 404 '{"message":"404 Not found"}'
EOF
chmod +x "$TMP/bin/gh" "$TMP/bin/curl"

# --- the stub git server: github.com and gitlab.com -----------------------------
SRV="$TMP/srv"; mkdir -p "$SRV/repos"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=stub -keyout "$SRV/key.pem" -out "$SRV/cert.pem" \
  -addext "subjectAltName=DNS:github.com,DNS:gitlab.com" 2>/dev/null
: > "$SRV/log"
seed="$TMP/seed"; git init -q -b main "$seed"; echo hello > "$seed/README.md"
git -C "$seed" add -A; git -C "$seed" commit -qm init
git clone -q --bare "$seed" "$SRV/repos/github.com/tacplus-dev/alpha.git"
git clone -q --bare "$seed" "$SRV/repos/gitlab.com/seabeam/tools/looper.git"
python3 -I "$ROOT/tests/git-server.py" "$SRV/repos" "$SRV/cert.pem" "$SRV/key.pem" "$SRV/log" > "$SRV/port" &
SRVPID=$!
for _ in $(seq 50); do [[ -s "$SRV/port" ]] && break; sleep 0.1; done
PORT="$(cat "$SRV/port")"; [[ -n "$PORT" ]] || { echo "FAIL: stub git server did not start" >&2; exit 1; }

# --- scenarios -------------------------------------------------------------------
fail() { echo "FAIL $NAME ($FORGE): $*" >&2; exit 1; }
pass() { echo "ok $NAME ($FORGE)"; }

# A scenario on one forge: tacplus-dev's repositories alpha and beta on
# GitHub; seabeam's alpha, beta and tools/looper (a subgroup's) on GitLab.
scenario() { # name forge
  NAME="$1"; FORGE="$2"; FIX="$TMP/$1-$2"; mkdir -p "$FIX/issues" "$FIX/home" "$FIX/files" "$FIX/labels"
  if [[ "$FORGE" == github ]]; then ORG=tacplus-dev; SUB=""; else ORG=seabeam; SUB=tools/looper; fi
  echo '{}' > "$FIX/members.json"; echo '{}' > "$FIX/permissions.json"; echo '[]' > "$FIX/jobs.json"
  : > "$FIX/calls"; : > "$FIX/argv"
}
issue() { # repo n state body label...
  local r="$1" n="$2" st="$3" b="$4"; shift 4
  jq -n --arg r "$r" --argjson n "$n" --arg st "$st" --arg b "$b" --arg c "2026-10-$(printf %02d "$n")T00:00:00Z" '$ARGS.positional as $l |
    {repo: $r, number: $n, title: "Issue \($n)", state: $st, labels: [$l[] | {name: .}], body: $b, createdAt: $c, comments: []}' \
    --args "$@" > "$FIX/issues/${r//\//__}-$n.json"
  for l in "$@"; do grep -qxF -- "$l" "$FIX/labels/${r//\//__}" 2>/dev/null || echo "$l" >> "$FIX/labels/${r//\//__}"; done
}
store() { jq -r "$3" "$FIX/issues/${1//\//__}-$2.json"; } # repo n jq
# Runs a bash snippet with looper-lib.sh sourced, as this scenario's forge.
lib() { # snippet
  env -u GITLAB_TOKEN -u GH_TOKEN -u LOOPER_ROADMAP_REPO -u LOOPER_FORGE_URL PATH="$TMP/bin:$PATH" HOME="$FIX/home" FIX="$FIX" ORG="$ORG" PIPELINE="$ORG/tools/looper" \
    LOOPER_FORGE="$FORGE" LOOPER_ORG="$ORG" LOOPER_FORGE_TOKEN="$TOKEN" GH_TOKEN="$TOKEN" TOKEN="$TOKEN" \
    HTTPS_PROXY="http://127.0.0.1:$PORT" GIT_SSL_CAINFO="$SRV/cert.pem" \
    bash -c "set -euo pipefail; source '$ROOT/looper-lib.sh'; $1"
}
dispatch() { # args...
  env -u LOOPER_RUNNING_COPY -u LOOPER_SELF -u LOOPER_ROADMAP_REPO -u LOOPER_FORGE_URL -u CI_PROJECT_ID -u CI_JOB_ID \
    PATH="$TMP/bin:$PATH" HOME="$FIX/home" FIX="$FIX" ORG="$ORG" PIPELINE="$ORG/tools/looper" TOKEN="$TOKEN" CI_PIPELINE_SOURCE="${SOURCE:-}" \
    LOOPER_FORGE="$FORGE" LOOPER_ORG="$ORG" LOOPER_FORGE_TOKEN="$TOKEN" GH_TOKEN="$TOKEN" GITLAB_TOKEN=pipeline-token \
    LOOPER_PIPELINE="$ORG/tools/looper" LOOPER_LIB="$ROOT/looper-lib.sh" CI_API_V4_URL=https://gitlab.com/api/v4 \
    "$ROOT/looper-dispatch" "$@"
}
no_token_in_argv() { ! grep -qF "$TOKEN" "$FIX/argv" || fail "the token on a command line: $(grep -F "$TOKEN" "$FIX/argv" | head -n 1)"; }

for FORGE in github gitlab; do
  # Ready issues: approved, not held, every blocker closed; priority:high first, then oldest.
  scenario ready "$FORGE"
  issue alpha 1 OPEN "Plain." approved
  issue alpha 2 OPEN "Blocked-by: #3" approved
  issue alpha 3 OPEN "Open still."
  issue alpha 4 OPEN "Blocked-by: $ORG/beta#5" approved
  issue beta 5 CLOSED "Done."
  issue alpha 6 OPEN "Blocked-by: other-org/alpha#1" approved          # another org: never read, holds
  issue alpha 7 OPEN "Held." approved looper:in-progress
  issue alpha 8 OPEN "Urgent." approved priority:high
  issue alpha 9 OPEN "Blocked-by: $ORG/beta#99" approved                 # no such issue: holds
  issue beta 10 OPEN "Blocked-by: $ORG/alpha#3" approved
  issue beta 11 OPEN "Low." approved priority:low
  [[ "$(lib 'approved_issues alpha' | paste -sd' ')" == "8 1 2 4 6 9" ]] || fail "approved_issues: $(lib 'approved_issues alpha' | paste -sd' ')"
  for n in 1 4 8; do lib "ready alpha $n" || fail "alpha#$n not ready"; done
  for n in 2 6 9; do ! lib "ready alpha $n" || fail "alpha#$n ready"; done
  [[ "$(lib 'next_ready alpha')" == 8 ]] || fail "next_ready: $(lib 'next_ready alpha')"
  got="$(lib ready_by_repo | paste -sd,)"; [[ "$got" == "alpha 8,beta 11" ]] || fail "ready_by_repo: $got"
  # Never another org: on GitHub not asked at all, on GitLab only as a path inside the group (none there).
  ! grep -qE "(repos|projects|groups)/other-org|owner: \\\\?\"other-org|--repo other-org|name: \\\\?\"other-org" "$FIX/calls" || fail "read another org: $(grep other-org "$FIX/calls")"
  [[ "$FORGE" == gitlab ]] || ! grep -q other-org "$FIX/calls" || fail "asked GitHub for another org's issue: $(grep other-org "$FIX/calls")"
  [[ "$(dispatch ready 2>/dev/null | paste -sd,)" == "alpha 8,beta 11" ]] || fail "looper-dispatch ready"
  no_token_in_argv
  pass

  # Blocked-by within and across repositories and forges' refs: what parse_blockers resolves, what holds.
  scenario blocked-by "$FORGE"
  got="$(printf 'Blocked-by: #3\nblocked-by: %s/beta#5\nBlocked-by: other-org/beta#6\nnot Blocked-by: #7\n' "$ORG" | lib 'parse_blockers alpha' | paste -sd,)"
  [[ "$got" == "alpha 3,beta 5,other-org/beta 6" ]] || fail "parse_blockers: $got"
  if [[ "$FORGE" == gitlab ]]; then
    # A subgroup's project: seabeam/<path>#N.
    issue "$SUB" 12 CLOSED "Done."
    issue "$SUB" 13 OPEN "Not yet."
    issue alpha 14 OPEN "Blocked-by: seabeam/tools/looper#12" approved
    issue alpha 15 OPEN "Blocked-by: seabeam/tools/looper#13" approved
    issue "$SUB" 16 OPEN "Blocked-by: #13" approved
    issue "$SUB" 17 OPEN "Blocked-by: seabeam/alpha#15" approved
    [[ "$(printf 'Blocked-by: seabeam/tools/looper#12\n' | lib 'parse_blockers alpha')" == "tools/looper 12" ]] || fail "subgroup ref"
    lib 'ready alpha 14' || fail "alpha#14 (its blocker in a subgroup closed) not ready"
    ! lib 'ready alpha 15' || fail "alpha#15 ready"
    ! lib 'ready tools/looper 16' || fail "tools/looper#16 ready"
    got="$(lib ready_by_repo | paste -sd,)"; [[ "$got" == "alpha 14" ]] || fail "ready_by_repo: $got"
    grep -qx 'GET projects/seabeam/tools/looper/issues/12' "$FIX/calls" || fail "the subgroup's issue not read: $(cat "$FIX/calls")"
  else
    issue alpha 14 OPEN "Blocked-by: tacplus-dev/beta#12" approved
    issue beta 12 CLOSED "Done."
    lib 'ready alpha 14' || fail "alpha#14 not ready"
    got="$(lib ready_by_repo | paste -sd,)"; [[ "$got" == "alpha 14" ]] || fail "ready_by_repo: $got"
  fi
  got="$(printf 'alpha 1\nbeta 404\n' | { issue alpha 1 OPEN x; lib forge_issue_states; } | paste -sd,)"
  [[ "$got" == "alpha 1 OPEN,beta 404 MISSING" ]] || fail "forge_issue_states: $got"
  pass

  scenario blocked-by-url "$FORGE"
  # An issue's URL on this forge reads as <org>/<repo>#N (looper#87): GitHub's
  # /issues/N, GitLab's /-/issues/N; one on another host or another org never
  # resolves, so it holds. A Blocked-by line it cannot read holds its issue too.
  if [[ "$FORGE" == github ]]; then WEB=https://github.com; OTHER=https://gitlab.com; I=issues
  else WEB=https://gitlab.com; OTHER=https://github.com; I=-/issues; fi
  got="$(printf 'Blocked-by: %s/%s/beta/%s/5\nBlocked-by: <%s/%s/alpha/%s/3>.\nBlocked-by: %s/other-org/beta/%s/6\nBlocked-by: %s/%s/beta/%s/7\n' \
           "$WEB" "$ORG" "$I" "$WEB" "$ORG" "$I" "$WEB" "$I" "$OTHER" "$ORG" "$I" | lib 'parse_blockers alpha' | paste -sd,)"
  [[ "$got" == "beta 5,alpha 3,other-org/beta 6,${OTHER#https://}/$ORG/beta 7" ]] || fail "parse_blockers on URLs: $got"
  got="$(printf 'Blocked-by: the other half\nBlocked-by: %s/%s/beta/pull/5\nBlocked-by:\n' "$WEB" "$ORG" | lib 'parse_blockers alpha' | paste -sd,)"
  [[ "$got" == "?/unreadable 0,?/unreadable 0,?/unreadable 0" ]] || fail "parse_blockers on unreadable lines: $got"
  issue alpha 20 OPEN "Open still."
  issue alpha 21 CLOSED "Done."
  issue alpha 22 OPEN "Blocked-by: $WEB/$ORG/alpha/$I/20" approved
  issue alpha 23 OPEN "Blocked-by: $WEB/$ORG/alpha/$I/21" approved
  issue alpha 24 OPEN "Blocked-by: $OTHER/$ORG/alpha/$I/21" approved
  issue alpha 25 OPEN "Blocked-by: alpha 21, when it lands" approved
  ! lib 'ready alpha 22' || fail "alpha#22 (its blocker, by URL, open) ready"
  lib 'ready alpha 23' || fail "alpha#23 (its blocker, by URL, closed) not ready"
  ! lib 'ready alpha 24' || fail "alpha#24 (its blocker on another host) ready"
  ! lib 'ready alpha 25' || fail "alpha#25 (its Blocked-by unreadable) ready"
  got="$(lib ready_all_by_repo | paste -sd,)"; [[ "$got" == "alpha 23" ]] || fail "ready_all_by_repo with URLs: $got"
  pass

  # Labels, comments and body edits, and the looper's labels (looper#80): the
  # repository starts with `approved` alone, so the first edit names labels it
  # lacks; they are created and the edit retried.
  scenario labels-comments "$FORGE"
  issue alpha 1 OPEN "Body." approved
  lib 'forge_issue_edit alpha 1 --add-label looper:in-progress --add-label bug' || fail "edit add"
  if [[ "$FORGE" == github ]]; then
    want="alpha bug,alpha feature,alpha looper:in-progress,alpha looper:landing,alpha looper:stuck,alpha needs-decision,alpha priority:high,alpha priority:low"
    [[ "$(sort "$FIX/labels-created" | paste -sd,)" == "$want" ]] || fail "labels created: $(cat "$FIX/labels-created")"
  fi
  [[ "$(store alpha 1 '[.labels[].name] | sort | join(",")')" == "approved,bug,looper:in-progress" ]] || fail "labels: $(store alpha 1 '[.labels[].name] | join(",")')"
  lib 'forge_issue_edit alpha 1 --remove-label looper:in-progress --add-label looper:stuck' || fail "edit swap"
  [[ "$(store alpha 1 '[.labels[].name] | sort | join(",")')" == "approved,bug,looper:stuck" ]] || fail "labels: $(store alpha 1 '[.labels[].name] | join(",")')"
  lib 'forge_issue_edit alpha 1 --body "Body.

Blocked-by: #2"' || fail "edit body"
  [[ "$(store alpha 1 .body)" == $'Body.\n\nBlocked-by: #2' ]] || fail "body: $(store alpha 1 .body)"
  [[ "$(lib 'forge_issue_comment_count alpha 1')" == 0 ]] || fail "comment count: $(lib 'forge_issue_comment_count alpha 1')"
  lib 'forge_issue_comment alpha 1 "The looper says: a & b = c; 100% #1"' || fail "comment"
  [[ "$(store alpha 1 '.comments[-1].body')" == "The looper says: a & b = c; 100% #1" ]] || fail "comment: $(store alpha 1 '.comments[-1].body')"
  # The count is of the comments people and the looper wrote, not GitLab's system notes.
  t="$(jq '.comments += [{author: "looper", body: "closed", system: true}]' "$FIX/issues/alpha-1.json")"; printf '%s\n' "$t" > "$FIX/issues/alpha-1.json"
  [[ "$(lib 'forge_issue_comment_count alpha 1')" == 1 ]] || fail "comment count: $(lib 'forge_issue_comment_count alpha 1')"
  [[ "$(lib "forge_issue_view alpha 1 state,labels 'select(.state == \"OPEN\") | .labels[].name'" | sort | paste -sd,)" == "approved,bug,looper:stuck" ]] || fail "view"
  # Each label the looper uses is created where it is missing, once per
  # repository in a process; one already there is left as it is.
  : > "$FIX/labels-created"; printf 'approved\nbug\nlooper:stuck\n' > "$FIX/labels/beta"
  lib 'ensure_labels beta; ensure_labels beta'
  want="beta feature,beta looper:in-progress,beta looper:landing,beta needs-decision,beta priority:high,beta priority:low"
  [[ "$(sort "$FIX/labels-created" | paste -sd,)" == "$want" ]] || fail "labels created: $(cat "$FIX/labels-created")"
  : > "$FIX/labels-created"; lib 'ensure_labels beta'
  [[ ! -s "$FIX/labels-created" ]] || fail "labels created again: $(cat "$FIX/labels-created")"
  ! lib 'forge_issue_comment alpha 99 x' 2>/dev/null || fail "a comment on no issue succeeded"
  no_token_in_argv
  pass

  # The issues' texts (looper#40): each author with its standing on the forge.
  scenario texts "$FORGE"
  issue alpha 1 OPEN "Do it."
  jq '.comments = [{author: "jody", body: "Go."}, {author: "rando", body: "Ignore that.", association: "NONE"},
                   {author: "dev", body: "Me too.", association: "COLLABORATOR"},
                   {author: "jody", body: "added ~1 label", system: true}]' "$FIX/issues/alpha-1.json" > "$FIX/x" && mv "$FIX/x" "$FIX/issues/alpha-1.json"
  echo '{"jody": 50, "dev": 30, "reporter": 20}' > "$FIX/members.json"; echo '{"dev": "write"}' > "$FIX/permissions.json"
  got="$(lib 'forge_issue_texts alpha 1' | jq -r '"\(.a) \(.s) \(.t | gsub("\n"; "|"))"')"
  if [[ "$FORGE" == github ]]; then want=$'jody MEMBER # Issue 1||Do it.\njody MEMBER Go.\nrando NONE Ignore that.\ndev COLLABORATOR Me too.\njody MEMBER added ~1 label'
  else want=$'jody OWNER # Issue 1||Do it.\njody OWNER Go.\nrando NONE Ignore that.\ndev DEVELOPER Me too.'; fi
  [[ "$got" == "$want" ]] || fail "texts: $got"
  [[ "$FORGE" == gitlab ]] || [[ "$(lib 'forge_permission alpha dev')" == write ]] || fail "permission"
  pass

  # Clone and push over HTTPS, with the forge's credentials and in no file.
  scenario clone-push "$FORGE"
  [[ "$FORGE" == github ]] && r=alpha || r="$SUB"
  lib "forge_setup_git; forge_clone '$r' '$FIX/co'" || fail "clone: $(tail -n 3 "$SRV/log")"
  echo change > "$FIX/co/change"; git -C "$FIX/co" add -A; git -C "$FIX/co" commit -qm change
  lib "git -C '$FIX/co' push -q origin HEAD:main" || fail "push: $(tail -n 3 "$SRV/log")"
  host=github.com; [[ "$FORGE" == gitlab ]] && host=gitlab.com
  [[ "$(git --git-dir="$SRV/repos/$host/$ORG/$r.git" log -1 --format=%s main)" == change ]] || fail "not pushed"
  grep -q "^$host [^ ]*:$TOKEN" "$SRV/log" || fail "no credential sent to $host: $(cat "$SRV/log")"
  ! grep -rqF "$TOKEN" "$FIX/home" "$FIX/co/.git" || fail "the token in a file: $(grep -rlF "$TOKEN" "$FIX/home" "$FIX/co/.git")"
  [[ "$(git -C "$FIX/co" remote get-url origin)" == "https://$host/$ORG/$r.git" ]] || fail "origin: $(git -C "$FIX/co" remote get-url origin)"
  pass

  # The platform's files, the web pages and links, the model's commands.
  scenario files-links "$FORGE"
  mkdir -p "$FIX/files/roadmap/templates/repo"; echo "# Roadmap: see alpha#3" > "$FIX/files/roadmap/ROADMAP.md"
  echo "# State: <repo>" > "$FIX/files/roadmap/templates/repo/STATE.md"
  [[ "$(lib 'platform_file ROADMAP.md')" == "# Roadmap: see alpha#3" ]] || fail "platform_file"
  [[ "$(lib 'forge_file roadmap templates/repo/STATE.md')" == "# State: <repo>" ]] || fail "forge_file"
  ! lib 'platform_file NONE.md' 2>/dev/null || fail "a missing file read"
  lib "echo 'see $ORG/alpha#3' | links_issue alpha 3" || fail "links_issue by reference"
  url="$(lib 'forge_web alpha issue 3')"
  if [[ "$FORGE" == github ]]; then [[ "$url" == https://github.com/tacplus-dev/alpha/issues/3 ]] || fail "url: $url"
  else [[ "$url" == https://gitlab.com/seabeam/alpha/-/issues/3 ]] || fail "url: $url"; fi
  lib "echo 'see $url.' | links_issue alpha 3" || fail "links_issue by URL"
  ! lib "echo 'see $url' | links_issue alpha 30" || fail "links_issue: #30 linked by #3's URL"
  [[ "$(lib 'forge_web alpha tree looper/alpha-3')" == */alpha/*tree/looper/alpha-3 ]] || fail "tree url"
  cmd="$(lib 'forge_cmd close alpha 3')"
  if [[ "$FORGE" == github ]]; then [[ "$cmd" == "gh issue close 3 --repo tacplus-dev/alpha" ]] || fail "cmd: $cmd"
  else [[ "$cmd" == "glab issue close 3 --repo seabeam/alpha" ]] || fail "cmd: $cmd"; fi
  pass

  # looper-dispatch: the plan (a report per ready issue with none active, and its manager ahead of the reports, looper#70, looper#75) and the orphan release.
  scenario dispatch "$FORGE"
  issue alpha 1 OPEN "Go." approved
  issue beta 2 OPEN "Go." approved
  issue beta 3 OPEN "Held by a run that is gone." approved looper:in-progress
  jq -n '[{name: "looper-alpha-9", status: "running"}]' > "$FIX/jobs.json"
  out="$(dispatch plan 2>"$FIX/plan.err")" || fail "plan: $(cat "$FIX/plan.err")"
  # The schedule's plan (looper#56): a scan of each of the org's repositories, subgroups' too.
  printf '%s\n' alpha beta ${SUB:+"$SUB"} > "$FIX/repos"
  [[ "$(lib forge_repos | paste -sd' ')" == "alpha beta${SUB:+ $SUB}" ]] || fail "forge_repos: $(lib forge_repos | paste -sd' ')"
  scans="$(SOURCE=schedule dispatch plan 2>"$FIX/plan.err")" || fail "scheduled plan: $(cat "$FIX/plan.err")"
  [[ "$(grep -E '^looper-' <<<"$scans" | paste -sd' ')" == "looper-scan-alpha: looper-scan-beta:${SUB:+ looper-scan-$SUB:}" ]] || fail "scans: $scans"
  grep -qx '    - repo-looper --repo beta --scan' <<<"$scans" || fail "beta's scan: $scans"
  # alpha#9's report does not hold alpha#1: one job per issue.
  [[ "$(grep -E '^looper-' <<<"$out" | paste -sd' ')" == "looper-alpha-manager: looper-beta-manager: looper-alpha-1: looper-beta-2:" ]] || fail "planned: $out"
  grep -qx '    - repo-looper --repo beta --issue 2' <<<"$out" || fail "beta's script: $out"
  grep -qx '  resource_group: looper-beta-2' <<<"$out" || fail "beta's resource_group: $out"
  grep -qx '  resource_group: looper-beta-main' <<<"$out" || fail "beta's manager's resource_group: $out"
  grep -qE '^  timeout: [0-9]+h$' <<<"$out" || fail "no timeout: $out"
  dispatch run >/dev/null 2>&1 || true   # starts nothing it can (no trigger stubbed), but releases beta#3 first
  [[ "$(store beta 3 '[.labels[].name] | join(",")')" == approved ]] || fail "beta#3 still held: $(store beta 3 '[.labels[].name] | join(",")')"
  [[ "$(store beta 3 '.comments | length')" == 1 ]] || fail "beta#3 not told"
  no_token_in_argv
  pass
done

# One SeaBeam issue worked end to end (gitlab, a subgroup's project): taken
# (looper:in-progress), the model closes it, the label goes and HISTORY.md's
# line is queued on the issue's branch and pushed to gitlab.com by the
# manager, through the forge's credentials. The model runs
# as the job's user (LOOPER_MODEL_USERS=0), to read this test's files: the
# models' own users are repo-looper.test.sh's (looper#68).
scenario end-to-end gitlab
issue "$SUB" 21 OPEN "Fix the thing." approved bug
echo '{"jody": 50}' > "$FIX/members.json"
cat > "$TMP/bin/claude" <<'EOF'
#!/usr/bin/env bash
prompt="$(cat)"; printf '%s\n' "$prompt" > "$FIX/prompt"
f="$FIX/issues/tools__looper-21.json"
jq '.labels' "$f" > "$FIX/labels-during"
t="$(jq '.state = "CLOSED"' "$f")"; printf '%s\n' "$t" > "$f"
EOF
chmod +x "$TMP/bin/claude"
E2E=(env -u GITLAB_TOKEN -u LOOPER_RUNNING_COPY -u LOOPER_SELF -u LOOPER_RUN -u LOOPER_CHILD_MEMORY \
  -u LOOPER_RUNS -u LOOPER_TIMEOUT -u LOOPER_GATES -u CI_API_V4_URL -u CI_PROJECT_ID -u CI_JOB_ID -u CI_JOB_URL -u CI_PROJECT_DIR \
  -u CI_JOB_TIMEOUT -u CI_JOB_STARTED_AT -u LOOPER_ROADMAP_REPO -u LOOPER_FORGE_URL \
  PATH="$TMP/bin:$PATH" HOME="$FIX/home" FIX="$FIX" ORG=seabeam PIPELINE=seabeam/tools/looper TOKEN="$TOKEN" \
  LOOPER_FORGE=gitlab LOOPER_ORG=seabeam LOOPER_FORGE_TOKEN="$TOKEN" LOOPER_LIB="$ROOT/looper-lib.sh" LOOPER_WORK="$FIX/work" \
  LOOPER_MODEL_USERS=0 LOOPER_WATCH_INTERVAL=1 LOOPER_DONE_GRACE=1 HTTPS_PROXY="http://127.0.0.1:$PORT" GIT_SSL_CAINFO="$SRV/cert.pem")
"${E2E[@]}" "$ROOT/repo-looper" --repo tools/looper --issue 21 > "$FIX/out" 2>&1 || fail "repo-looper: $(tail -n 20 "$FIX/out")"
# Its HISTORY.md line is queued for the manager (looper#70), which adds it.
"${E2E[@]}" LOOPER_MANAGER_POLL=1 LOOPER_MANAGER_LINGER=0 "$ROOT/repo-looper" --repo tools/looper --manage >> "$FIX/out" 2>&1 || fail "the manager: $(tail -n 20 "$FIX/out")"
grep -q 'looper:in-progress' "$FIX/labels-during" || fail "not taken: $(cat "$FIX/labels-during")"
[[ "$(store "$SUB" 21 '[.labels[].name] | join(",")')" == approved,bug ]] || fail "labels after: $(store "$SUB" 21 '[.labels[].name] | join(",")')"
grep -qF 'glab issue close 21 --repo seabeam/tools/looper' "$FIX/prompt" || fail "the prompt's close: $(grep -n close "$FIX/prompt")"
grep -qF 'author=jody association=OWNER role=direction' "$FIX/prompt" || fail "the prompt's provenance"
! grep -qE '\bgh (issue|api)' "$FIX/prompt" || fail "gh in a GitLab prompt: $(grep -nE '\bgh (issue|api)' "$FIX/prompt")"
git --git-dir="$SRV/repos/gitlab.com/seabeam/tools/looper.git" show main:HISTORY.md | grep -q 'looper issue Issue 21 (#21)' \
  || fail "no HISTORY.md line on main: $(tail -n 20 "$FIX/out")"
pass

# The model's environment on GitLab: glab's GITLAB_TOKEN is the forge's token, never the job's.
NAME=model-env; FORGE=gitlab
got="$(env LOOPER_FORGE=gitlab LOOPER_FORGE_TOKEN="$TOKEN" GITLAB_TOKEN=job-token CI_JOB_TOKEN=x bash -c '
  set -euo pipefail; source "'"$ROOT"'/looper-lib.sh"
  eval "$(sed -n "/^MODEL_WITHHELD=/,/^}/p; /^model_forge_env()/,/^}/p" "'"$ROOT"'/repo-looper")"
  mapfile -t w < <(model_env); ( model_forge_env; env "${w[@]}" | grep -E "^(GITLAB_TOKEN|GITLAB_HOST|CI_JOB_TOKEN)=" | sort )')"
[[ "$got" == $'GITLAB_HOST=https://gitlab.com\nGITLAB_TOKEN='"$TOKEN" ]] || fail "model env: $got"
pass

echo "forge: all scenarios pass"
