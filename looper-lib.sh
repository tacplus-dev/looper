# shellcheck shell=bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# looper-lib.sh: what the dispatcher (on the host) and repo-looper (in the
# container) must agree on, sourced by both so the rules live in one place:
# which labels mean what, and which issues are ready to work.
#
# Every forge call goes through the forge_* functions below (looper#29).

# The deployment (looper#29): one looper, two homes. LOOPER_FORGE is where its
# code and issues live: github (tacplus-dev's: every call through gh, with
# GH_TOKEN) or gitlab (SeaBeam's: the GitLab API through curl at
# LOOPER_FORGE_URL, default https://gitlab.com, with LOOPER_FORGE_TOKEN).
# LOOPER_ORG is the GitHub organization or the GitLab group; a repository is
# its path under it (`kernel`; on GitLab a subgroup's project too,
# `tools/looper`). LOOPER_ROADMAP_REPO (default roadmap) is the org's platform
# roadmap repository. The rules above the forge (labels, order, Blocked-by)
# are the same on both, and an instance reads and writes its own org alone.
LOOPER_FORGE="${LOOPER_FORGE:-github}"
LOOPER_ORG="${LOOPER_ORG:-tacplus-dev}"
LOOPER_FORGE_URL="${LOOPER_FORGE_URL:-https://gitlab.com}"
LOOPER_ROADMAP_REPO="${LOOPER_ROADMAP_REPO:-roadmap}"

# Labels. Only someone with write access to a repository can set a label, so
# `approved` is the gate: an issue nobody with write access approved is never
# worked, whoever opened it and whatever its text says.
LABEL_APPROVED="approved"
LABEL_IN_PROGRESS="looper:in-progress"
LABEL_STUCK="looper:stuck"           # a run ended without finishing, for no known reason; a person looks
LABEL_DECISION="needs-decision"      # the looper needs a decision it may not make
# A report's commits queued with its repository's manager (looper#70): not
# ready, so no other report takes the issue, until the manager's verdict.
LABEL_LANDING="looper:landing"
# A report whose token may push a change under .github/workflows/ (looper#115):
# only someone with write access sets it, and looper-token reads who did.
LABEL_WORKFLOWS="looper:workflows"
# A report on the high model, LOOPER_MODEL_HIGH (looper#162; repo-looper's
# choose_model): only someone with write access sets it, and the looper reads
# who did; it never sets it itself. priority:high only orders the queues.
LABEL_MODEL_HIGH="model:high"
# The looper's hold (looper#157): the one issue of the hub repository that
# records the account's usage limit, read by the kicker (hold_until, below).
LABEL_HOLD="looper:hold"

# Every issue is a bug or a feature (tacplus-dev/roadmap
# decisions/issue-flow-2026-10-27.md, looper#14). A bug is fixed and ships as a
# patch on every supported release line. A feature needs design, Jody's
# approval and a ROADMAP.md entry before it is built, and ships in a minor.
LABEL_BUG="bug"
LABEL_FEATURE="feature"
ISSUE_FLOW="tacplus-dev/roadmap decisions/issue-flow-2026-10-27.md"

# Priority (looper#31): what starts next, never what is stopped. Ready issues
# are taken priority:high first, then unlabelled, then priority:low, oldest
# first within each; ISSUE_ORDER is that order as a jq sort_by key, for issues
# with labels and createdAt.
LABEL_PRIORITY_HIGH="priority:high"
LABEL_PRIORITY_LOW="priority:low"
ISSUE_ORDER="[(if any(.labels[]; .name == \"$LABEL_PRIORITY_HIGH\") then 0
                elif any(.labels[]; .name == \"$LABEL_PRIORITY_LOW\") then 2 else 1 end), .createdAt]"

# Every label the looper sets or reads, "name|colour|description" (looper#80):
# none is assumed to exist.
LOOPER_LABELS=(
  "$LABEL_APPROVED|0e8a16|Someone with write access approved it: the looper works it"
  "$LABEL_IN_PROGRESS|fbca04|A looper holds it"
  "$LABEL_LANDING|fbca04|Its commits are queued with the manager, which merges them and gives its verdict here"
  "$LABEL_WORKFLOWS|5319e7|Its report's token may push a change under .github/workflows/ (set by someone with write access)"
  "$LABEL_MODEL_HIGH|5319e7|Its report runs on the high model, LOOPER_MODEL_HIGH (set by someone with write access)"
  "$LABEL_STUCK|d93f0b|A run ended without finishing, for no known reason; a person looks"
  "$LABEL_HOLD|ededed|The looper's hold: the account's usage limit is reached, and nothing starts until the reset its body names"
  "$LABEL_DECISION|5319e7|The looper needs a decision it may not make"
  "$LABEL_BUG|d73a4a|The code does not do what it already promises: fixed, and released as a patch"
  "$LABEL_FEATURE|a2eeef|New behaviour: needs design, approval and a ROADMAP.md entry; ships in a minor"
  "$LABEL_PRIORITY_HIGH|b60205|The looper takes it before unlabelled ready issues; a running issue is never pre-empted"
  "$LABEL_PRIORITY_LOW|c5def5|The looper takes it after every other ready issue"
)

# The looper's labels a repository lacks, created (looper#80): once per
# repository in a process, or again with `again` (a label edit that failed).
# A label the forge does not list is created, never assumed; one there is
# left as it is. Never fatal.
LABELS_ENSURED=" "
ensure_labels() { # repo [again]
  local have e name color desc
  [[ "${2:-}" == again || "$LABELS_ENSURED" != *" $1 "* ]] || return 0
  have="$(forge_labels "$1" 2>/dev/null)" || have=""
  for e in "${LOOPER_LABELS[@]}"; do
    IFS='|' read -r name color desc <<<"$e"
    grep -qxF -- "$name" <<<"$have" || forge_label_create "$1" "$name" "$color" "$desc" >/dev/null 2>&1 || true
  done
  [[ "$LABELS_ENSURED" == *" $1 "* ]] || LABELS_ENSURED+="$1 "
}

# A file of the platform's roadmap repository (ROADMAP.md, items/...), raw.
platform_file() { # path
  forge_file "$LOOPER_ROADMAP_REPO" "$1"
}

# The text on stdin links issue <repo>#<n>: `<org>/<repo>#<n>`, `<repo>#<n>`
# or its URL on the forge; with `own` (the repository's own ROADMAP.md), a
# bare `#<n>` too.
links_issue() { # repo n [own]
  local r="${1//./\\.}" n="$2" re url
  url="$(forge_web "$1" issue "$n")"; url="${url#*://}"; url="${url//./\\.}"
  re="(^|[^A-Za-z0-9_.-])($LOOPER_ORG/)?$r#$n([^0-9]|\$)|$url([^0-9]|\$)"
  [[ "${3:-}" == own ]] && re="$re|(^|[^A-Za-z0-9_./-])#$n([^0-9]|\$)"
  grep -qE "$re"
}

# Prompt provenance (looper#40): text a tool quotes into an issue from outside
# tacplus-dev sits between `<!-- looper:source-text from=<source> -->` and this
# line, so repo-looper gives it to the model as data, whoever filed the issue.
# The tool that quotes it keeps `<` and `>` out of the quoted text, so it cannot
# end the section early.
SOURCE_TEXT_END="<!-- /looper:source-text -->"

log() { printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
die() { log "FATAL $*" >&2; exit 2; }
need() { command -v "$1" >/dev/null 2>&1 || die "required tool not found: $1"; }

# A control pod's use against its requests (looper#165), for the nightly
# recap: the CPU its cgroup (v2, LOOPER_CGROUP) used from pod_use_mark to
# pod_use_log, as a mean in millicores, and its memory's peak (memory.current
# where there is no memory.peak), beside the KUBERNETES_* requests the plan
# gave the job. Nothing for a job with no request (a VM's) or no cgroup.
LOOPER_CGROUP="${LOOPER_CGROUP:-/sys/fs/cgroup}"
POD_USE_MARK=""
cgroup_cpu_usec() { awk '$1 == "usage_usec" { print $2 }' "$LOOPER_CGROUP/cpu.stat" 2>/dev/null || true; }
pod_use_clock() { echo "$SECONDS"; } # the seconds it measures in, a function a test fakes
pod_use_mark() { local u; u="$(cgroup_cpu_usec)"; [[ -z "$u" ]] || POD_USE_MARK="$u $(pod_use_clock)"; }
pod_use_log() {
  [[ -n "$POD_USE_MARK" && -n "${KUBERNETES_CPU_REQUEST:-}" ]] || return 0
  local u0 s0 u s mem f
  read -r u0 s0 <<<"$POD_USE_MARK"; u="$(cgroup_cpu_usec)"
  [[ "$u" =~ ^[0-9]+$ ]] || return 0
  s=$(( $(pod_use_clock) - s0 )); (( s > 0 )) || s=1
  for f in memory.peak memory.current; do
    mem="$(cat "$LOOPER_CGROUP/$f" 2>/dev/null)" || mem=""; [[ ! "$mem" =~ ^[0-9]+$ ]] || break
  done
  log "pod use at the end: cpu $(( (u - u0) / s / 1000 ))m mean over $s s, memory $([[ "$mem" =~ ^[0-9]+$ ]] && echo "$(( mem / 1048576 ))Mi" || echo ?) peak;" \
    "requested cpu $KUBERNETES_CPU_REQUEST, memory ${KUBERNETES_MEMORY_REQUEST:-?}"
}

# Every call to the network ends (looper#112): a manager that waited on one
# without a bound held its job for hours, saying nothing. Each gh call is
# stopped after LOOPER_NET_TIMEOUT seconds (default 300), and so is each of
# curl's attempts (30 to connect); git gives up on a transfer that moves
# nothing for as long, with its own error ("RPC failed; curl 28 Operation too
# slow"), and never asks for a credential on a terminal: it fails, and says so.
LOOPER_NET_TIMEOUT="${LOOPER_NET_TIMEOUT:-300}"
export GIT_HTTP_LOW_SPEED_LIMIT="${GIT_HTTP_LOW_SPEED_LIMIT:-1}" GIT_HTTP_LOW_SPEED_TIME="${GIT_HTTP_LOW_SPEED_TIME:-$LOOPER_NET_TIMEOUT}" \
  GIT_TERMINAL_PROMPT=0 GCM_INTERACTIVE=never
# A read GitHub answers with a 5xx or a 429 is tried again, 3 tries in all, 2
# then 4 seconds apart (looper#178: one search's HTTP 502 failed the kick); a
# write never is, since one GitHub failed may still have been made.
gh() {
  local rc try=1 out err
  gh_read "$@" || { gh_once "$@"; return; }
  out="$(mktemp)"; err="$(mktemp)"
  while :; do
    rc=0; gh_once "$@" > "$out" 2> "$err" || rc=$?
    (( rc != 0 && try < 3 )) && grep -qE 'HTTP (5[0-9][0-9]|429)' "$err" || break
    echo "gh $1${2:+ $2}: $(grep -oE 'HTTP (5[0-9][0-9]|429)' "$err" | head -1); tried again in $((2 * try))s (looper#178)" >&2
    sleep $((2 * try)); try=$((try + 1))
  done
  cat "$out"; cat "$err" >&2; rm -f "$out" "$err"
  return "$rc"
}
gh_once() {
  local rc=0
  timeout -k 10 "$LOOPER_NET_TIMEOUT" gh "$@" || rc=$?
  (( rc != 124 && rc != 137 )) || echo "gh $1${2:+ $2}: no answer within ${LOOPER_NET_TIMEOUT}s; stopped (looper#112)" >&2
  return "$rc"
}
# A gh call that changes nothing: a search, a view, a list, an attestation's
# verify, and an api GET or GraphQL query (no method but GET, no field but the
# query, and that no mutation).
gh_read() {
  case "$1 ${2:-}" in
    search\ *|issue\ view|issue\ list|pr\ view|pr\ list|repo\ view|repo\ list|run\ view|run\ list|release\ view|release\ list|attestation\ verify) return 0 ;;
    api\ *) ;;
    *) return 1 ;;
  esac
  local graphql="" a; shift
  for a in "$@"; do
    case "$a" in
      graphql) graphql=1 ;;
      -X|--method|-XPOST|-XPUT|-XPATCH|-XDELETE|--method=*|--input|--input=*|-F|--field|--field=*) return 1 ;;
      query=*) [[ -n "$graphql" && ! "$a" =~ ^query=[[:space:]]*mutation ]] || return 1 ;;
      -f|--raw-field|-f*|--raw-field=*) [[ -n "$graphql" ]] || return 1 ;;
    esac
  done
}
curl() { command curl --connect-timeout 30 --max-time "$LOOPER_NET_TIMEOUT" "$@"; }

# --- the forge (looper#29) ----------------------------------------------------
#
# What the looper asks of a forge, as gh answers it: issues as JSON objects
# {number, title, state (OPEN or CLOSED), labels: [{name}], body, createdAt}
# (and repository: {name}, the path under LOOPER_ORG, from a search), each jq
# filter applied to that shape on both forges. github calls gh as before;
# gitlab calls the GitLab API (v4) with LOOPER_FORGE_TOKEN, sent from a file
# descriptor, never on a command line, and gives its issues that same shape.

forge_need() {
  case "$LOOPER_FORGE" in
    github) need gh ;;
    gitlab) need curl ;;
    *) die "LOOPER_FORGE is github or gitlab, not $LOOPER_FORGE" ;;
  esac
  need jq
}

# GitLab: the URL-encoded form of a path or value.
gl_enc() { jq -rn --arg s "$1" '$s | @uri'; } # text
# GitLab: a project's API path.
gl_project() { echo "projects/$(gl_enc "$LOOPER_ORG/$1")"; } # repo
# GitLab: a call (method, path under /api/v4, curl's other arguments); its
# body on stdout. Fails on any HTTP error.
gl_api() { # method path [curl args...]
  local m="$1" p="$2"; shift 2
  [[ -n "${LOOPER_FORGE_TOKEN:-}" ]] || { echo "no LOOPER_FORGE_TOKEN: a GitLab token with api scope on $LOOPER_ORG" >&2; return 1; }
  curl -fsS --retry 2 -X "$m" -H @<(printf 'PRIVATE-TOKEN: %s\n' "$LOOPER_FORGE_TOKEN") "$@" "$LOOPER_FORGE_URL/api/v4/$p"
}
# GitLab: every page of a list (up to max items), as one JSON array.
gl_all() { # path?query max
  local p="$1" max="$2" page=1 t got n=0
  t="$(mktemp)"
  while (( n < max )); do
    got="$(gl_api GET "$p&per_page=100&page=$page")" || { rm -f "$t"; return 1; }
    printf '%s\n' "$got" >> "$t"
    n=$(( n + $(jq length <<<"$got") )); page=$(( page + 1 ))
    (( $(jq length <<<"$got") == 100 )) || break
  done
  jq -s --argjson max "$max" 'add // [] | .[:$max]' "$t"; rm -f "$t"
}
# GitLab: an issue in gh's shape; its repository from its reference
# (`seabeam/tools/looper#5`: tools/looper).
GL_ISSUE='{number: .iid, title, body: (.description // ""), state: (if .state == "opened" then "OPEN" else "CLOSED" end),
           labels: [.labels[] | {name: .}], createdAt: .created_at, closedAt: .closed_at,
           repository: {name: (.references.full // "" | sub("#[0-9]+$"; "") | ltrimstr($org + "/"))}}'
gl_issues() { jq --arg org "$LOOPER_ORG" "if type == \"array\" then map($GL_ISSUE) else $GL_ISSUE end"; }

# One issue: the fields gh is asked for (github), the jq filter on its shape.
forge_issue_view() { # repo n fields jq
  case "$LOOPER_FORGE" in
    github) gh issue view "$2" --repo "$LOOPER_ORG/$1" --json "$3" --jq "$4" ;;
    gitlab) local i; i="$(gl_api GET "$(gl_project "$1")/issues/$2")" || return 1
            gl_issues <<<"$i" | jq -r "$4" ;;
  esac
}

# A repository's issues, newest first: state open or all, at most limit, with
# every label given.
forge_issue_list() { # repo state limit fields jq [label...]
  local r="$1" st="$2" lim="$3" f="$4" q="$5" l a=() ls=""; shift 5
  case "$LOOPER_FORGE" in
    github) for l in "$@"; do a+=(--label "$l"); done
            gh issue list --repo "$LOOPER_ORG/$r" --state "$st" "${a[@]+"${a[@]}"}" --limit "$lim" --json "$f" --jq "$q" ;;
    gitlab) for l in "$@"; do ls+="${ls:+,}$l"; done
            [[ "$st" == open ]] && st=opened
            local i; i="$(gl_all "$(gl_project "$r")/issues?state=$st&order_by=created_at&sort=desc${ls:+&labels=$(gl_enc "$ls")}" "$lim")" || return 1
            gl_issues <<<"$i" | jq -r "$q" ;;
  esac
}

# The org's open issues with a label, every repository's (repository.name is
# the path under LOOPER_ORG); the jq filter optional.
forge_search_issues() { # label limit fields [jq [public]]
  case "$LOOPER_FORGE" in
    github) local q=(); [[ -z "${4:-}" ]] || q=(--jq "$4")
            [[ "${5:-}" != public ]] || q+=(--visibility public)
            gh search issues --owner "$LOOPER_ORG" --state open --label "$1" --limit "$2" --json "$3" "${q[@]+"${q[@]}"}" ;;
    gitlab) local i; i="$(gl_all "groups/$(gl_enc "$LOOPER_ORG")/issues?state=opened&labels=$(gl_enc "$1")" "$2")" || return 1
            gl_issues <<<"$i" | jq -r "${4:-.}" ;;
  esac
}

# The org's repositories that are not archived, one name (the path under
# LOOPER_ORG) a line: what the nightly scan reads (looper#56).
forge_repos() {
  case "$LOOPER_FORGE" in
    github) gh repo list "$LOOPER_ORG" --no-archived --limit 200 --json name --jq '.[].name' ;;
    gitlab) local p; p="$(gl_all "groups/$(gl_enc "$LOOPER_ORG")/projects?include_subgroups=true&archived=false" 200)" || return 1
            jq -r --arg org "$LOOPER_ORG" '.[].path_with_namespace | ltrimstr($org + "/")' <<<"$p" ;;
  esac
}

# Labels and body, as gh issue edit takes them: --add-label L, --remove-label L, --body B.
# An edit of labels that fails is retried once the repository's labels are
# ensured (looper#80): gh refuses one that names a label the repository
# lacks, adding it or removing it.
forge_issue_edit() { # repo n [--add-label L]... [--remove-label L]... [--body B]
  local err rc=0
  [[ " $* " == *" --add-label "* || " $* " == *" --remove-label "* ]] || { forge_issue_edit_once "$@"; return; }
  err="$(mktemp)"
  forge_issue_edit_once "$@" 2> "$err" || rc=$?
  if (( rc != 0 )); then
    ensure_labels "$1" again
    rc=0; forge_issue_edit_once "$@" 2> "$err" || rc=$?
  fi
  cat "$err" >&2; rm -f "$err"
  return "$rc"
}
forge_issue_edit_once() { # repo n [--add-label L]... [--remove-label L]... [--body B]
  local r="$1" n="$2"; shift 2
  case "$LOOPER_FORGE" in
    github) gh issue edit "$n" --repo "$LOOPER_ORG/$r" "$@" ;;
    gitlab)
      local add="" rm="" d=()
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --add-label) add+="${add:+,}$2" ;;
          --remove-label) rm+="${rm:+,}$2" ;;
          --body) d+=(--data-urlencode "description=$2") ;;
          *) echo "forge_issue_edit: unknown $1" >&2; return 2 ;;
        esac; shift 2
      done
      [[ -z "$add" ]] || d+=(--data-urlencode "add_labels=$add")
      [[ -z "$rm" ]] || d+=(--data-urlencode "remove_labels=$rm")
      gl_api PUT "$(gl_project "$r")/issues/$n" "${d[@]}" >/dev/null ;;
  esac
}

forge_issue_comment() { # repo n body
  case "$LOOPER_FORGE" in
    github) gh issue comment "$2" --repo "$LOOPER_ORG/$1" --body "$3" ;;
    gitlab) gl_api POST "$(gl_project "$1")/issues/$2/notes" --data-urlencode "body=$3" >/dev/null ;;
  esac
}

# A new issue, with its labels; prints its number.
forge_issue_create() { # repo title body [label...]
  local r="$1" t="$2" b="$3" l a=() url i; shift 3
  case "$LOOPER_FORGE" in
    github) for l in "$@"; do a+=(--label "$l"); done
            url="$(gh issue create --repo "$LOOPER_ORG/$r" --title "$t" --body "$b" "${a[@]+"${a[@]}"}")" || return 1
            [[ "${url##*/}" =~ ^[0-9]+$ ]] || return 1
            echo "${url##*/}" ;;
    gitlab) for l in "$@"; do a+=(--data-urlencode "labels=$l"); done
            i="$(gl_api POST "$(gl_project "$r")/issues" --data-urlencode "title=$t" --data-urlencode "description=$b" "${a[@]+"${a[@]}"}")" || return 1
            jq -er '.iid' <<<"$i" ;;
  esac
}

# Pins an issue to its repository's issues page (GitHub: at most three a
# repository; GitLab has no pins, so nothing to do). Fails when it cannot.
forge_pin_issue() { # repo n
  local id
  case "$LOOPER_FORGE" in
    github) id="$(gh issue view "$2" --repo "$LOOPER_ORG/$1" --json id --jq .id)" && [[ -n "$id" ]] || return 1
            gh api graphql -f query='mutation($id: ID!) { pinIssue(input: {issueId: $id}) { issue { number } } }' -f id="$id" >/dev/null ;;
    gitlab) return 0 ;;
  esac
}

# How many comments an issue has: the ones people and the looper wrote, not
# GitLab's system notes (a label added, the issue closed).
forge_issue_comment_count() { # repo n
  case "$LOOPER_FORGE" in
    github) gh api "repos/$LOOPER_ORG/$1/issues/$2" --jq .comments ;;
    gitlab) local i; i="$(gl_api GET "$(gl_project "$1")/issues/$2")" || return 1
            jq -r .user_notes_count <<<"$i" ;;
  esac
}

# An issue's comment bodies, oldest first, each a JSON string on a line of its
# own (on GitLab, the notes a person or the looper wrote).
forge_issue_comments() { # repo n
  case "$LOOPER_FORGE" in
    github) gh api "repos/$LOOPER_ORG/$1/issues/$2/comments" --paginate --jq '.[] | .body | tojson' ;;
    gitlab) gl_all "$(gl_project "$1")/issues/$2/notes?sort=asc&order_by=created_at" 1000 | jq -c '.[] | select(.system | not) | .body' ;;
  esac
}

# When an issue's comments were made, oldest first, an epoch a line (on
# GitLab, the notes a person or the looper wrote).
forge_issue_comments_times() { # repo n
  case "$LOOPER_FORGE" in
    github) gh api "repos/$LOOPER_ORG/$1/issues/$2/comments" --paginate --jq '.[] | .created_at // empty | sub("\\.[0-9]+"; "") | fromdate' ;;
    gitlab) gl_all "$(gl_project "$1")/issues/$2/notes?sort=asc&order_by=created_at" 1000 \
              | jq -r '.[] | select(.system | not) | .created_at // empty | sub("\\.[0-9]+"; "") | fromdate' ;;
  esac
}

# A repository's labels, a name a line (on GitLab, its groups' too).
forge_labels() { # repo
  case "$LOOPER_FORGE" in
    github) gh label list --repo "$LOOPER_ORG/$1" --limit 1000 --json name --jq '.[].name' ;;
    gitlab) local l; l="$(gl_all "$(gl_project "$1")/labels?include_ancestor_groups=true" 1000)" || return 1
            jq -r '.[].name' <<<"$l" ;;
  esac
}

forge_label_create() { # repo name color(hex, no #) description
  case "$LOOPER_FORGE" in
    github) gh label create "$2" --repo "$LOOPER_ORG/$1" --color "$3" --description "$4" ;;
    gitlab) gl_api POST "$(gl_project "$1")/labels" --data-urlencode "name=$2" --data-urlencode "color=#$3" \
              --data-urlencode "description=$4" >/dev/null ;;
  esac
}

# An issue's texts for a prompt (looper#40), oldest first, one JSON object a
# line: {a: author, s: association, t: text}, the title and body first, then
# each comment (on GitLab, each note a person wrote). The association is
# GitHub's author_association; on GitLab, the author's role in the project
# (OWNER, MAINTAINER, DEVELOPER, REPORTER, PLANNER, GUEST, or NONE).
forge_issue_texts() { # repo n
  local issue comments
  case "$LOOPER_FORGE" in
    github)
      issue="$(gh api "repos/$LOOPER_ORG/$1/issues/$2")" || return 1
      comments="$(gh api "repos/$LOOPER_ORG/$1/issues/$2/comments" --paginate)" || return 1
      jq -c '{a: .user.login, s: .author_association, t: ("# " + .title + "\n\n" + (.body // ""))}' <<<"$issue"
      jq -c '.[] | {a: .user.login, s: .author_association, t: (.body // "")}' <<<"$comments" ;;
    gitlab) gl_texts "$1" issues "$2" ;;
  esac
}

# A pull request's texts (looper#219), as forge_issue_texts': its title and
# body first, then each comment, review and review comment, oldest first (on
# GitLab, a merge request's, and each note a person wrote).
forge_pr_texts() { # repo n
  local pr comments reviews notes
  case "$LOOPER_FORGE" in
    github)
      pr="$(gh api "repos/$LOOPER_ORG/$1/pulls/$2")" || return 1
      comments="$(gh api "repos/$LOOPER_ORG/$1/issues/$2/comments" --paginate)" || return 1
      reviews="$(gh api "repos/$LOOPER_ORG/$1/pulls/$2/reviews" --paginate)" || return 1
      notes="$(gh api "repos/$LOOPER_ORG/$1/pulls/$2/comments" --paginate)" || return 1
      jq -c '{a: .user.login, s: .author_association, t: ("# " + .title + "\n\n" + (.body // ""))}' <<<"$pr"
      { jq -c '.[] | {at: .created_at, a: .user.login, s: .author_association, t: (.body // "")}' <<<"$comments"
        jq -c '.[] | select((.body // "") != "") | {at: .submitted_at, a: .user.login, s: .author_association, t: ("Review (" + .state + "):\n\n" + .body)}' <<<"$reviews"
        jq -c '.[] | {at: .created_at, a: .user.login, s: .author_association, t: ("On " + .path + ":\n\n" + (.body // ""))}' <<<"$notes"
      } | jq -sc 'sort_by(.at) | .[] | del(.at)' ;;
    gitlab) gl_texts "$1" merge_requests "$2" ;;
  esac
}

# A GitLab issue's or merge request's texts, each author's role in the project.
gl_texts() { # repo issues|merge_requests n
  local p u roles='{}' l m item notes; p="$(gl_project "$1")"
  item="$(gl_api GET "$p/$2/$3")" || return 1
  notes="$(gl_all "$p/$2/$3/notes?sort=asc&order_by=created_at" 1000)" || return 1
  for u in $( { jq -r .author.username <<<"$item"; jq -r '.[] | select(.system | not) | .author.username' <<<"$notes"; } | sort -u); do
    m="$(gl_api GET "$p/members/all?query=$(gl_enc "$u")")" || return 1
    l="$(jq --arg u "$u" '[.[] | select(.username == $u) | .access_level] | max // 0' <<<"$m")"
    roles="$(jq -c --arg u "$u" --argjson l "$l" '.[$u] = (if $l >= 50 then "OWNER" elif $l >= 40 then "MAINTAINER"
      elif $l >= 30 then "DEVELOPER" elif $l >= 20 then "REPORTER" elif $l >= 15 then "PLANNER" elif $l >= 10 then "GUEST" else "NONE" end)' <<<"$roles")"
  done
  jq -c --argjson r "$roles" '{a: .author.username, s: $r[.author.username], t: ("# " + .title + "\n\n" + (.description // ""))}' <<<"$item"
  jq -c --argjson r "$roles" '.[] | select(.system | not) | {a: .author.username, s: $r[.author.username], t: (.body // "")}' <<<"$notes"
}

# GitHub: a COLLABORATOR's permission on the repository (admin, maintain,
# write, triage, read). GitLab's roles come with the texts.
forge_permission() { # repo login
  [[ "$LOOPER_FORGE" == github ]] || return 1
  gh api "repos/$LOOPER_ORG/$1/collaborators/$2/permission" --jq .permission
}

# Whether a login may push to the repository: GitHub's write permission and up,
# GitLab's Developer role and up. A lookup that fails says no.
forge_writer() { # repo login
  case "$LOOPER_FORGE" in
    github) case "$(forge_permission "$1" "$2" 2>/dev/null)" in admin|maintain|write) return 0 ;; *) return 1 ;; esac ;;
    gitlab) local m; m="$(gl_api GET "$(gl_project "$1")/members/all?query=$(gl_enc "$2")")" || return 1
            jq -e --arg u "$2" '[.[] | select(.username == $u) | .access_level] | max // 0 | . >= 30' <<<"$m" >/dev/null ;;
  esac
}

# Who last added a label to an issue: their login, else nothing.
forge_label_adder() { # repo n label
  case "$LOOPER_FORGE" in
    github) gh api "repos/$LOOPER_ORG/$1/issues/$2/events" --paginate \
              --jq ".[] | select(.event == \"labeled\" and .label.name == $(jq -n --arg l "$3" '$l')) | .actor.login" | tail -n 1 ;;
    gitlab) local e; e="$(gl_all "$(gl_project "$1")/issues/$2/resource_label_events?sort=asc" 1000)" || return 1
            jq -r --arg l "$3" '[.[] | select(.action == "add" and .label.name == $l) | .user.username] | last // empty' <<<"$e" ;;
  esac
}

# The states of issues given as "<repo> <n>" lines (each once), as
# "<repo> <n> <OPEN|CLOSED|MISSING>" lines in the same order: MISSING for a
# reference the forge does not resolve to an issue of LOOPER_ORG. Fails when
# the forge cannot be read. GitHub: one aliased GraphQL query.
forge_issue_states() { # (stdin)
  local refs r n q="" i=0 out code t
  refs="$(cat)"; [[ -n "$refs" ]] || return 0
  case "$LOOPER_FORGE" in
    github)
      # A path with a slash is no repository of the org (another org's): never asked.
      while read -r r n; do
        [[ "$r" != */* ]] || continue
        q="$q b$i: repository(owner: \"$LOOPER_ORG\", name: \"$r\") { issue(number: $n) { state } }"; i=$((i + 1))
      done <<<"$refs"
      out='{"data": {}}'
      # A blocker that is no issue answers null and gh exits 1; no data at all is GitHub refusing.
      [[ -z "$q" ]] || out="$(gh api graphql -f query="{$q }" 2>/dev/null)" || true
      jq -e '.data | type == "object"' <<<"$out" >/dev/null 2>&1 || return 1
      i=0
      while read -r r n; do
        if [[ "$r" == */* ]]; then echo "$r $n MISSING"
        else echo "$r $n $(jq -r --arg b "b$i" '.data[$b].issue.state // "MISSING"' <<<"$out")"; i=$((i + 1)); fi
      done <<<"$refs" ;;
    gitlab)
      [[ -n "${LOOPER_FORGE_TOKEN:-}" ]] || return 1
      t="$(mktemp)"
      while read -r r n; do
        code="$(curl -sS --retry 2 -o "$t" -w '%{http_code}' -H @<(printf 'PRIVATE-TOKEN: %s\n' "$LOOPER_FORGE_TOKEN") \
                  "$LOOPER_FORGE_URL/api/v4/$(gl_project "$r")/issues/$n")" || code=""
        case "$code" in
          200) echo "$r $n $(gl_issues < "$t" | jq -r .state)" ;;
          404) echo "$r $n MISSING" ;;
          *) rm -f "$t"; return 1 ;;
        esac
      done <<<"$refs"
      rm -f "$t" ;;
  esac
}

# A file of a repository's default branch, raw.
forge_file() { # repo path
  case "$LOOPER_FORGE" in
    github) gh api "repos/$LOOPER_ORG/$1/contents/$2" -H "Accept: application/vnd.github.raw" ;;
    gitlab) gl_api GET "$(gl_project "$1")/repository/files/$(gl_enc "$2")/raw?ref=HEAD" ;;
  esac
}

# Git's credentials for the forge, for this user: gh's, or on GitLab a helper
# for LOOPER_FORGE_URL alone that answers from $LOOPER_FORGE_TOKEN when git
# asks (the token in no file), every other helper for it dropped.
forge_setup_git() {
  case "$LOOPER_FORGE" in
    github) gh auth setup-git >/dev/null 2>&1 || true ;;
    gitlab)
      # shellcheck disable=SC2016  # expanded by git's shell when it asks, not here
      git config --global --replace-all "credential.$LOOPER_FORGE_URL.helper" '' &&
      git config --global --add "credential.$LOOPER_FORGE_URL.helper" \
        '!f() { test "$1" = get || exit 0; test -n "$LOOPER_FORGE_TOKEN" || exit 0; echo username=oauth2; echo "password=$LOOPER_FORGE_TOKEN"; }; f' ;;
  esac
}

forge_clone() { # repo dir
  case "$LOOPER_FORGE" in
    github) gh repo clone "$LOOPER_ORG/$1" "$2" -- --quiet ;;
    gitlab) git clone -q "$LOOPER_FORGE_URL/$LOOPER_ORG/$1.git" "$2" ;;
  esac
}

# A page of a repository on the forge: the repository, an issue, a branch's
# tree or a release.
forge_web() { # repo [issue N | tree BRANCH | release TAG]
  local base
  case "$LOOPER_FORGE" in
    github) base="https://github.com/$LOOPER_ORG/$1"
            case "${2:-}" in issue) echo "$base/issues/$3" ;; tree) echo "$base/tree/$3" ;; release) echo "$base/releases/tag/$3" ;; *) echo "$base" ;; esac ;;
    gitlab) base="$LOOPER_FORGE_URL/$LOOPER_ORG/$1"
            case "${2:-}" in issue) echo "$base/-/issues/$3" ;; tree) echo "$base/-/tree/$3" ;; release) echo "$base/-/releases/$3" ;; *) echo "$base" ;; esac ;;
  esac
}

# A command line for a prompt, the model's way to the forge: gh, or glab
# (with GITLAB_TOKEN and GITLAB_HOST, which repo-looper gives it on GitLab).
forge_cmd() { # view|close|label|list repo [n] [label] | file repo path | repos
  local R="$LOOPER_ORG/${2:-}"
  case "$LOOPER_FORGE:$1" in
    github:view) echo "gh issue view $3 --repo $R --comments" ;;
    github:close) echo "gh issue close $3 --repo $R" ;;
    github:label) echo "gh issue edit $3 --repo $R --add-label $4" ;;
    github:list) echo "gh issue list --repo $R" ;;
    github:file) echo "gh api repos/$R/contents/$3 -H 'Accept: application/vnd.github.raw'" ;;
    github:repos) echo "gh repo list $LOOPER_ORG --no-archived --limit 200" ;;
    gitlab:view) echo "glab issue view $3 --repo $R --comments" ;;
    gitlab:close) echo "glab issue close $3 --repo $R" ;;
    gitlab:label) echo "glab issue update $3 --repo $R --label $4" ;;
    gitlab:list) echo "glab issue list --repo $R" ;;
    gitlab:file) echo "glab api 'projects/$(gl_enc "$R")/repository/files/$(gl_enc "$3")/raw?ref=HEAD'" ;;
    gitlab:repos) echo "glab api 'groups/$(gl_enc "$LOOPER_ORG")/projects?include_subgroups=true&archived=false&per_page=100'" ;;
  esac
}

# --- the issues -----------------------------------------------------------------

# Open approved issues in one repository that no run holds or parked, in
# ISSUE_ORDER (by priority, then oldest first), as "number" lines.
approved_issues() { # repo
  forge_issue_list "$1" open 200 number,labels,createdAt "
      [.[] | select(all(.labels[].name; . != \"$LABEL_IN_PROGRESS\" and . != \"$LABEL_STUCK\" and . != \"$LABEL_DECISION\" and . != \"$LABEL_LANDING\"))]
      | sort_by($ISSUE_ORDER) | .[].number" "$LABEL_APPROVED"
}

# The issues an issue waits on: lines `Blocked-by: #N` (same repository),
# `Blocked-by: <org>/<repo>#N` (on GitLab `seabeam/<path>#N`, subgroups
# included) or the issue's URL in its body, printed as "<repo> <N>"
# (parse_blockers). Fails (non-zero) when the body cannot be read: an
# unreadable issue is never taken for an unblocked one.
blockers() { # repo issue
  local body
  body="$(forge_issue_view "$1" "$2" body .body)" || return 1
  printf '%s\n' "$body" | parse_blockers "$1"
}

# The `Blocked-by:` lines of the text on stdin, as "<repo> <N>"; `#N` is in
# repo, `<org>/<path>#N` in path. A reference outside LOOPER_ORG keeps its
# whole path, which names no repository of the org, so it never resolves and
# holds its issue: an instance reads no other org (looper#29). An issue's URL
# (`https://github.com/<org>/<repo>/issues/N`, on GitLab
# `<LOOPER_FORGE_URL>/<path>/-/issues/N`, in <> or not) reads as
# `<org>/<repo>#N`; one on another host keeps its host, so it never resolves
# either (looper#87). A line it cannot read at all is `?/unreadable 0`, no
# issue of any org, so it holds its issue too: never taken for no blocker.
parse_blockers() { # repo
  local host ref num slug
  case "$LOOPER_FORGE" in github) host=github.com ;; *) host="${LOOPER_FORGE_URL#*://}"; host="${host%/}" ;; esac
  grep -iE '^[[:space:]]*blocked-by:' \
    | sed -E 's/^[[:space:]]*[Bb][Ll][Oo][Cc][Kk][Ee][Dd]-[Bb][Yy]:[[:space:]]*//' \
    | while IFS= read -r ref; do
        if [[ "$ref" =~ ^(([A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)+)?)#([0-9]+) ]]; then
          slug="${BASH_REMATCH[1]}"; num="${BASH_REMATCH[4]}"
        elif [[ "$ref" =~ ^\<?https?://([A-Za-z0-9_.:-]+(/[A-Za-z0-9_.-]+)+)(/-)?/issues/([0-9]+) ]]; then
          slug="${BASH_REMATCH[1]%/-}"; num="${BASH_REMATCH[4]}"   # the longest path takes GitLab's /-
          if [[ "${slug,,}" == "${host,,}/"* ]]; then slug="${slug#*/}"; fi
        else echo "?/unreadable 0"; continue; fi
        if [[ -z "$slug" ]]; then echo "$1 $num"
        elif [[ "$slug" == "$LOOPER_ORG/"* ]]; then echo "${slug#"$LOOPER_ORG/"} $num"
        else echo "$slug $num"; fi
      done
  return 0
}

# An issue's state (OPEN, CLOSED), or a failure when it cannot be read.
issue_state() { # repo n
  [[ "$1" == */* && "$LOOPER_FORGE" == github ]] && return 1   # no GitHub repository: not one of the org's
  forge_issue_view "$1" "$2" state .state
}

# Ready: approved, not held, every issue it is blocked by closed, every run
# it waits on finished (waits_over, looper#171), and not backed off
# (backoff_over, looper#181). Any forge error along the way means not ready.
ready() { # repo issue
  local body
  body="$(forge_issue_view "$1" "$2" body .body)" || return 1
  ready_body "$1" "$body" "$2"
}
ready_body() { # repo body issue
  local body="$2" list r n state
  list="$(printf '%s\n' "$body" | parse_blockers "$1")" || return 1
  while read -r r n; do
    [[ -z "$r" ]] && continue
    state="$(issue_state "$r" "$n" 2>/dev/null)" || return 1
    [[ "$state" == CLOSED ]] || return 1
  done <<<"$list"
  printf '%s\n' "$body" | waits_over || return 1
  backoff_over "$1" "$3" "$body" >/dev/null
}

# Ready as the issue itself says, read alone, not as GitHub's search has it
# (looper#175): open, approved, not held, and ready (above). The search's
# index lags an issue's labels and body by minutes and more: on 2026-11-17 the
# kicker started the pipeline for looper#174 every 3 minutes for 40 minutes,
# the search still listing it ready, each report job finding it no longer
# ready in 27 s. The kicker and the plan read an issue so before they start or
# plan its report: a request for it, and one per blocker.
ready_itself() { # repo issue
  local i
  i="$(forge_issue_view "$1" "$2" state,labels,body '.')" || return 1
  jq -e --arg a "$LABEL_APPROVED" --arg p "$LABEL_IN_PROGRESS" --arg s "$LABEL_STUCK" --arg d "$LABEL_DECISION" --arg l "$LABEL_LANDING" \
    '(.state | ascii_upcase) == "OPEN" and any(.labels[]; .name == $a) and all(.labels[].name; IN($p, $s, $d, $l) | not)' <<<"$i" >/dev/null || return 1
  ready_body "$1" "$(jq -r '.body // ""' <<<"$i")" "$2"
}

# --- the runs an issue waits on (looper#171) ------------------------------------
#
# A report whose work waits on another run's result (a GitLab pipeline or
# job, a GitHub Actions run) does not wait in its model: on 2026-11-16 two runs
# that did ("Now I wait for image run ...") went idle and were looper:stuck,
# their work done. Its model asks `repo-looper --wait-on <url>`, which
# checkpoints "waiting on <url>" and writes `Waiting-on: <url>` to its outcome,
# and ends; the looper puts the line in the issue's body, with when it began
# (`Waiting-on: <url> (since <ISO time>)`), and the issue is not ready until
# that run has finished, or LOOPER_WAIT_MAX seconds (default 6h) after its
# since: a run that cannot be read, or never ends, holds it no longer. A line
# with no since (a person's) holds only while its run is read as not finished.
# The next run of the issue takes the lines out.
LOOPER_WAIT_MAX="${LOOPER_WAIT_MAX:-21600}"

# A run's URL as "<kind> <host> <path> <id>": github (an Actions run,
# github.com/<owner>/<repo>/actions/runs/<id>, a job or attempt under it too),
# pipeline or job (GitLab's, <host>/<path>/-/pipelines/<id> or /-/jobs/<id>,
# on gitlab.com or LOOPER_FORGE_URL's host). Fails on any other: the looper
# reads no other host.
run_ref() { # url
  local u="${1#<}" gl="${LOOPER_FORGE_URL#*://}"; u="${u%>}"; gl="${gl%/}"
  if [[ "$u" =~ ^https://github\.com/([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)/actions/runs/([0-9]+)(/.*)?$ ]]; then
    echo "github github.com ${BASH_REMATCH[1]} ${BASH_REMATCH[2]}"
  elif [[ "$u" =~ ^https://([A-Za-z0-9_.:-]+)/([A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)+)/-/(pipelines|jobs)/([0-9]+)([/?#].*)?$ ]] \
       && [[ "${BASH_REMATCH[1],,}" == gitlab.com || "${BASH_REMATCH[1],,}" == "${gl,,}" ]]; then
    echo "${BASH_REMATCH[4]%s} ${BASH_REMATCH[1],,} ${BASH_REMATCH[2]} ${BASH_REMATCH[5]}"
  else return 1; fi
}

# A run's state: `done <status>` once it has finished (GitHub's completed;
# GitLab's success, failed, canceled, skipped or manual: waiting on a person),
# `waiting <status>` while not. Fails when it cannot be read. GitLab is read
# with LOOPER_FORGE_TOKEN on the forge's own host, GITLAB_TOKEN on gitlab.com
# (from a file descriptor, never a command line), else anonymously.
run_state() { # url
  local ref kind host path id s tok="" gl="${LOOPER_FORGE_URL#*://}"; gl="${gl%/}"
  ref="$(run_ref "$1")" || return 1
  read -r kind host path id <<<"$ref"
  case "$kind" in
    github)
      s="$(gh api "repos/$path/actions/runs/$id" --jq '"\(.status) \(.conclusion // "")"')" || return 1
      if [[ "$s" == completed* ]]; then echo "done ${s% }"; else echo "waiting ${s% }"; fi ;;
    *)
      if [[ "$LOOPER_FORGE" == gitlab && "$host" == "${gl,,}" ]]; then tok="${LOOPER_FORGE_TOKEN:-}"
      elif [[ "$host" == gitlab.com ]]; then tok="${GITLAB_TOKEN:-}"; fi
      if [[ -n "$tok" ]]; then s="$(curl -fsS --retry 2 -H @<(printf 'PRIVATE-TOKEN: %s\n' "$tok") "https://$host/api/v4/projects/$(gl_enc "$path")/${kind}s/$id")"
      else s="$(curl -fsS --retry 2 "https://$host/api/v4/projects/$(gl_enc "$path")/${kind}s/$id")"; fi || return 1
      s="$(jq -er '.status | strings' <<<"$s")" || return 1
      case "$s" in success|failed|canceled|skipped|manual) echo "done $s" ;; *) echo "waiting $s" ;; esac ;;
  esac
}

# The `Waiting-on:` lines of the text on stdin, as "<url> [<since, epoch>]".
parse_waits() {
  local l url since
  grep -iE '^[[:space:]]*waiting-on:' | while IFS= read -r l; do
    l="$(sed -E 's/^[[:space:]]*[Ww][Aa][Ii][Tt][Ii][Nn][Gg]-[Oo][Nn]:[[:space:]]*//' <<<"$l")"
    url="${l%%[[:space:]]*}"; [[ -n "$url" ]] || continue
    since=""
    if [[ "$l" =~ \(since\ ([0-9T:Z.+-]+)\) ]]; then since="$(date -u -d "${BASH_REMATCH[1]}" +%s 2>/dev/null)" || since=""; fi
    echo "$url${since:+ $since}"
  done
  return 0
}

# The waits of the text on stdin (an issue's body) are over: each run it
# waits on has finished, or LOOPER_WAIT_MAX has passed since its line's since.
# Fails while one is waited on.
waits_over() {
  local url since s now; now="$(date +%s)"
  while read -r url since; do
    [[ -n "$url" ]] || continue
    if [[ -n "$since" ]] && (( now >= since + LOOPER_WAIT_MAX )); then continue; fi
    if s="$(run_state "$url" 2>/dev/null)"; then [[ "$s" == done* ]] || return 1
    else [[ -z "$since" ]] || return 1; fi
  done < <(parse_waits)
  return 0
}

# --- backing off (looper#181) ---------------------------------------------------
#
# An approved issue whose run finds nothing to do (kernel#66, llmproxy#63 on
# 2026-11-17: each waiting on Debian to ship a fix, ~20 and >10 runs in a
# day, each a model run for nothing) is not started again every pass. A
# resumed run that ends with nothing landed or queued and its checkout's work
# what it was when it started backs off: the looper puts `Backed-off: until
# <ISO time> (since <ISO time>, main <sha>)` in the issue's body, until a day
# later (LOOPER_BACKOFF_MAX seconds); a run that asks `repo-looper --wait-until
# <date>` (an external wait) backs off until that date. The issue is not ready
# until then, or until something changes after its since: a comment by a
# member (an OWNER or MEMBER, or anyone with write access; no bot), a label
# added or removed (but looper:in-progress), a push to its repository's main
# (main is no longer that sha) that changes a file outside the planning files
# (looper#213: the manager's own HISTORY.md, STATE.md and PROPOSALS.md pushes
# after each merge woke looper#189 14 times on 2026-11-21, each run finding
# nothing), or, when the line names paths (`, paths Dockerfile ci`: a
# --wait-until run's --path), one of those; or one of its Blocked-by issues
# closing. The next run takes the line out, and its prompt says what changed.
LOOPER_BACKOFF_MAX="${LOOPER_BACKOFF_MAX:-86400}"
# The files a push of these alone wakes no backed-off issue (looper#213).
BACKOFF_QUIET_FILES="HISTORY.md STATE.md PROPOSALS.md"

# The text on stdin's (an issue's body) first `Backed-off:` line, as "<until,
# epoch> <since, epoch> <main sha>[ <path>...]"; nothing when it has none or
# one it cannot read (which holds nothing).
parse_backoff() {
  local l u s m
  l="$(grep -iE '^[[:space:]]*backed-off:' | head -n 1)" || true
  [[ "$l" =~ until\ ([0-9T:Z.+-]+)\ \(since\ ([0-9T:Z.+-]+),\ main\ ([0-9a-f]{7,40})(,\ paths\ ([^\)]*))?\) ]] || return 0
  u="$(date -u -d "${BASH_REMATCH[1]}" +%s 2>/dev/null)" && s="$(date -u -d "${BASH_REMATCH[2]}" +%s 2>/dev/null)" || return 0
  m="${BASH_REMATCH[3]}"
  echo "$u $s $m${BASH_REMATCH[5]:+ ${BASH_REMATCH[5]}}"
}

# The files a push to a repository's main changed, from one sha to another,
# one a line (a renamed file's old path too). Fails when they cannot be read.
forge_changed_files() { # repo base head
  case "$LOOPER_FORGE" in
    github) gh api "repos/$LOOPER_ORG/$1/compare/$2...$3" --paginate --jq '.files[]? | .filename, (.previous_filename // empty)' ;;
    gitlab) local c; c="$(gl_api GET "$(gl_project "$1")/repository/compare?from=$(gl_enc "$2")&to=$(gl_enc "$3")")" || return 1
            jq -r '[.diffs[]? | .new_path, .old_path] | unique[]' <<<"$c" ;;
  esac
}

# The changed files on stdin that wake a backed-off issue (looper#213), one a
# line: with paths named, those and any file under them; else any but the
# planning files at the repository's root.
backoff_waking() { # [path...]
  local f p
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    if (( $# )); then
      for p in "$@"; do
        p="${p#./}"; p="${p%/}"
        if [[ "$f" == "$p" || "$f" == "$p"/* ]]; then echo "$f"; break; fi
      done
    elif [[ " $BACKOFF_QUIET_FILES " != *" $f "* ]]; then echo "$f"; fi
  done | awk '!seen[$0]++'
  return 0
}

# A login directs as a member does (looper#40): an OWNER or MEMBER, or anyone
# with write access (an org owner GitHub calls CONTRIBUTOR or NONE); never a
# bot. GitLab: a role that may push.
forge_member() { # repo login association
  [[ "$2" != *"[bot]" && -n "$2" ]] || return 1
  [[ "$LOOPER_FORGE" != github ]] || case "$3" in OWNER|MEMBER) return 0 ;; esac
  forge_writer "$1" "$2"
}

# The head of a repository's main. Fails when it cannot be read.
forge_main_head() { # repo
  case "$LOOPER_FORGE" in
    github) gh api "repos/$LOOPER_ORG/$1/branches/main" --jq .commit.sha ;;
    gitlab) local b; b="$(gl_api GET "$(gl_project "$1")/repository/branches/main")" || return 1
            jq -er .commit.id <<<"$b" ;;
  esac
}

# The comments on an issue created after an epoch, as "<login> <association>"
# lines (on GitLab, the notes a person wrote, association NONE: forge_member
# reads the role). Fails when they cannot be read.
forge_comments_after() { # repo n epoch
  case "$LOOPER_FORGE" in
    github) gh api "repos/$LOOPER_ORG/$1/issues/$2/comments?since=$(date -u -d "@$3" +%FT%TZ)" --paginate \
              --jq ".[] | select((.created_at // \"\") != \"\") | select((.created_at | sub(\"\\\\.[0-9]+\"; \"\") | fromdate) > $3) | \"\\(.user.login) \\(.author_association)\"" ;;
    gitlab) local c; c="$(gl_all "$(gl_project "$1")/issues/$2/notes?sort=asc&order_by=created_at" 1000)" || return 1
            jq -r --argjson t "$3" '.[] | select((.system | not) and (.created_at // "") != "") | select((.created_at | sub("\\.[0-9]+"; "") | fromdate) > $t) | "\(.author.username) NONE"' <<<"$c" ;;
  esac
}

# The labels added to or removed from an issue after an epoch, as
# "<added|removed> <label> <login>" lines. Fails when they cannot be read.
forge_label_events_after() { # repo n epoch
  case "$LOOPER_FORGE" in
    github) gh api "repos/$LOOPER_ORG/$1/issues/$2/events" --paginate \
              --jq ".[] | select((.event == \"labeled\" or .event == \"unlabeled\") and (.created_at // \"\") != \"\") | select((.created_at | sub(\"\\\\.[0-9]+\"; \"\") | fromdate) > $3)
                    | \"\\(if .event == \"labeled\" then \"added\" else \"removed\" end) \\(.label.name) \\(.actor.login // \"\")\"" ;;
    gitlab) local e; e="$(gl_all "$(gl_project "$1")/issues/$2/resource_label_events?sort=asc" 1000)" || return 1
            jq -r --argjson t "$3" '.[] | select((.created_at // "") != "") | select((.created_at | sub("\\.[0-9]+"; "") | fromdate) > $t)
                    | "\(if .action == "add" then "added" else "removed" end) \(.label.name) \(.user.username // "")"' <<<"$e" ;;
  esac
}

# The back-off of an issue (its body's `Backed-off:` line) is over: it has
# none, its until has passed, or something changed after its since. Prints
# what ended it (nothing for no line); fails while it holds. What cannot be
# read changed nothing: the issue waits for its until at most.
backoff_over() { # repo n body
  local b u s m h c l a ev lb who r k st at w paths=()
  b="$(parse_backoff <<<"$3")"; [[ -n "$b" ]] || return 0
  read -r u s m b <<<"$b"; read -ra paths <<<"$b"
  if (( $(date +%s) >= u )); then echo "its back-off ended ($(hold_iso "$u"))"; return 0; fi
  if h="$(forge_main_head "$1" 2>/dev/null)" && [[ "$h" =~ ^[0-9a-f]{7,40}$ && "$h" != "$m"* ]] \
     && c="$(forge_changed_files "$1" "$m" "$h" 2>/dev/null)" && w="$(backoff_waking "${paths[@]}" <<<"$c")" && [[ -n "$w" ]]; then
    (( $(wc -l <<<"$w") <= 3 )) || w="$(head -n 3 <<<"$w"; echo ...)"
    echo "a push to main of $1 (${m::7}..${h::7}, changing $(paste -sd, - <<<"$w" | sed 's/,/, /g'))"; return 0
  fi
  if c="$(forge_comments_after "$1" "$2" "$s" 2>/dev/null)"; then
    while read -r l a; do
      [[ -n "$l" ]] || continue
      if forge_member "$1" "$l" "$a" 2>/dev/null; then echo "a comment by $l"; return 0; fi
    done <<<"$c"
  fi
  if c="$(forge_label_events_after "$1" "$2" "$s" 2>/dev/null)"; then
    while read -r ev lb who; do
      [[ -n "$ev" && "$lb" != "$LABEL_IN_PROGRESS" ]] || continue
      echo "the label $lb $ev${who:+ by $who}"; return 0
    done <<<"$c"
  fi
  while read -r r k; do
    [[ -n "$r" ]] || continue
    [[ "$r" == */* && "$LOOPER_FORGE" == github ]] && continue   # no repository of the org's
    st="$(forge_issue_view "$r" "$k" state,closedAt '"\(.state) \(.closedAt // "")"' 2>/dev/null)" || continue
    [[ "$st" == CLOSED\ ?* ]] || continue
    at="$(date -u -d "${st#CLOSED }" +%s 2>/dev/null)" || continue
    if (( at > s )); then
      if [[ "$r" == "$1" ]]; then echo "#$k closed"; else echo "$LOOPER_ORG/$r#$k closed"; fi
      return 0
    fi
  done < <(parse_blockers "$1" <<<"$3")
  return 1
}

# The first ready issue in a repository (ISSUE_ORDER), or nothing.
next_ready() { # repo
  local n
  for n in $(approved_issues "$1"); do
    if ready "$1" "$n"; then echo "$n"; return 0; fi
  done
  return 0
}

# Every repository's ready issues, as "<repo> <number>" lines: the rule
# of next_ready, read for the whole org at once (the kicker's pass, looper#24),
# one search and one query for the blockers' states (forge_issue_states).
# next_ready costs a request per issue and per blocker: about 270 for the org
# in 2026-10, past GitHub's 5000 an hour at a pass every 3 minutes. A blocker
# the forge does not resolve to an issue holds its issue. Fails when the forge
# cannot be read. The lines are in ISSUE_ORDER of those issues: a repository
# whose next issue is priority:high comes first (looper#31), so it is planned
# first. ready_by_repo is each repository's first.
ready_by_repo() { ready_all_by_repo | awk '!seen[$1]++'; }
# A private repository's issues are no report's (looper#83): a ruleset on its
# main needs GitHub Team, so nothing there keeps a report's push off main
# (the hub's call, 2026-11-04, until Jody decides otherwise:
# LOOPER_PRIVATE_REPORTS=1 lists them again). On GitHub, the search's own
# filter, no request more.
ready_all_by_repo() {
  local all issues r n b64 refs states vis=public
  [[ "${LOOPER_PRIVATE_REPORTS:-}" != 1 ]] || vis=""
  all="$(forge_search_issues "$LABEL_APPROVED" 1000 repository,number,labels,createdAt,body "" "$vis")" || return 1
  # Not held, in ISSUE_ORDER: "<repo> <number> <body, base64>".
  issues="$(jq -r "[.[] | select(all(.labels[].name; . != \"$LABEL_IN_PROGRESS\" and . != \"$LABEL_STUCK\" and . != \"$LABEL_DECISION\" and . != \"$LABEL_LANDING\"))]
                   | sort_by($ISSUE_ORDER) | .[] | \"\\(.repository.name) \\(.number) \\(.body // \"\" | @base64)\"" <<<"$all")" || return 1
  # Each issue's blockers: "<repo> <number> <blocker repo> <blocker number>".
  refs="$(while read -r r n b64; do
            [[ -n "$r" ]] || continue
            base64 -d <<<"$b64" | parse_blockers "$r" | sed "s|^|$r $n |"
          done <<<"$issues")"
  # The blockers' states: "<repo> <number> <state>".
  states="$(awk 'NF { print $3, $4 }' <<<"$refs" | sort -u | forge_issue_states)" || return 1
  # Ready: every blocker closed, every run it waits on finished (looper#171),
  # and not backed off (looper#181). The first per repository is its next.
  while read -r r n b64; do
    [[ -n "$r" ]] || continue
    if awk -v r="$r" -v n="$n" '$1 == r && $2 == n { print $3, $4 }' <<<"$refs" | {
         while read -r br bn; do grep -qxF "$br $bn CLOSED" <<<"$states" || exit 1; done
       } && base64 -d <<<"$b64" | waits_over && backoff_over "$r" "$n" "$(base64 -d <<<"$b64")" >/dev/null; then echo "$r $n"; fi
  done <<<"$issues"
}

# --- the hold (looper#157) ------------------------------------------------------
#
# The account's usage limit (`You've hit your weekly limit · resets 3am
# (UTC)`, 2026-11-14: 19 issues looper:stuck, nothing run for 17 hours) is no
# issue's fault. A run that every model it may fall back to refuses so ends as
# a hold: its issue untouched (no looper:stuck, no comment), and the reset
# time the refusal names recorded on one issue of the hub repository
# (LOOPER_HOLD_REPO, default looper), labelled looper:hold and pinned: its
# body's marker `<!-- looper-hold until=<epoch> -->`, and one comment per hold
# time, not one per issue. The kicker and the plan read the marker and start
# no report and no manager until then; after it, work resumes with no person
# involved. A refusal naming no reset the looper can read holds
# LOOPER_HOLD_DEFAULT seconds (3600).
LOOPER_HOLD_REPO="${LOOPER_HOLD_REPO:-looper}"
HOLD_DEFAULT="${LOOPER_HOLD_DEFAULT:-3600}"
HOLD_MARK="<!-- looper-hold until="

hold_iso() { date -u -d "@$1" +%FT%TZ; } # epoch

# The hub's hold issue, "<number> <until>" (0 with no marker), the newest when
# there are several; nothing when there is none. Fails when the forge cannot
# be read.
hold_issue() {
  forge_issue_list "$LOOPER_HOLD_REPO" open 20 number,body \
    '[.[] | "\(.number) \([.body // "" | match("<!-- looper-hold until=([0-9]+) -->"; "g") | .captures[0].string | tonumber] | max // 0)"] | first // empty' "$LABEL_HOLD"
}

# The hold in force: "<until> <number>" while the hold issue names a reset
# still ahead, nothing otherwise. Fails when the forge cannot be read.
hold_until() {
  local h n u; h="$(hold_issue)" || return 1
  [[ -n "$h" ]] || return 0
  read -r n u <<<"$h"
  (( u > $(date +%s) )) || return 0
  echo "$u $n"
}

# The reset time a refusal names, as an epoch: `resets 3am (UTC)`, `resets
# 3:30pm (America/New_York)`, `resets Nov 20 at 3am (UTC)`; a time of day
# alone is the next such time in that zone (UTC when it names none). When it
# names none the looper can read, one past, or one more than
# LOOPER_HOLD_MAX_DAYS (10) ahead, prints now + HOLD_DEFAULT and fails.
hold_reset_time() { # refusal-text [now]
  local now="${2:-$(date +%s)}" when zone="UTC" day t=""
  if [[ "$1" =~ [Rr]esets[[:space:]]+([^()]*[^()[:space:]])[[:space:]]*(\(([A-Za-z0-9_/+-]+)\))? ]]; then
    when="${BASH_REMATCH[1]}"; [[ -z "${BASH_REMATCH[3]}" ]] || zone="${BASH_REMATCH[3]}"
    when="$(sed -E 's/ ·.*//; s/\b(at|on)\b/ /g; s/,/ /g; s/[[:space:]]+/ /g; s/^ | $//g' <<<"$when")"
    if [[ "$when" =~ ^[0-9]{1,2}(:[0-9]{2})?\ ?([AaPp][Mm])?$ ]]; then
      # A time of day: today's in the zone when still ahead, else tomorrow's.
      day="$(TZ="$zone" date -d "@$now" +%F 2>/dev/null)" || day=""
      t="$(TZ="$zone" date -d "$day $when" +%s 2>/dev/null)" || t=""
      if [[ "$t" =~ ^[0-9]+$ ]] && (( t <= now )); then
        day="$(TZ="$zone" date -d "$day +1 day" +%F 2>/dev/null)" || day=""
        t="$(TZ="$zone" date -d "$day $when" +%s 2>/dev/null)" || t=""
      fi
    else
      t="$(TZ="$zone" date -d "$when" +%s 2>/dev/null)" || t=""
    fi
  fi
  if [[ "$t" =~ ^[0-9]+$ ]] && (( t > now && t <= now + ${LOOPER_HOLD_MAX_DAYS:-10} * 86400 )); then echo "$t"; return 0; fi
  echo $(( now + HOLD_DEFAULT )); return 1
}

# Records a hold until an epoch, with why (which run, which model, the
# refusal), on the hub's hold issue: made, labelled and pinned when there is
# none; its marker moved when the time is later than the one it holds; one
# comment per hold time, none when the hold already reaches that time. Sets
# HOLD_PAGE, the issue's web page. Fails when the forge cannot be read or
# written.
hold_record() { # until why
  local until="$1" why="$2" h n u body iso; iso="$(hold_iso "$until")"
  HOLD_PAGE=""
  h="$(hold_issue)" || return 1
  if [[ -n "$h" ]]; then
    read -r n u <<<"$h"
    HOLD_PAGE="$(forge_web "$LOOPER_HOLD_REPO" issue "$n")"
    if (( u >= until )); then
      log "the hold until $(hold_iso "$u") stands ($LOOPER_ORG/$LOOPER_HOLD_REPO#$n): nothing to record"; return 0
    fi
    body="$(forge_issue_view "$LOOPER_HOLD_REPO" "$n" body .body)" || return 1
    body="$(grep -vF "$HOLD_MARK" <<<"$body")"; body="${body%"${body##*[![:space:]]}"}"
    forge_issue_edit "$LOOPER_HOLD_REPO" "$n" --body "$body

$HOLD_MARK$until -->" >/dev/null || return 1
  else
    ensure_labels "$LOOPER_HOLD_REPO"
    n="$(forge_issue_create "$LOOPER_HOLD_REPO" "The looper's hold: the account's usage limit" "$(hold_body "$until")" "$LABEL_HOLD")" || return 1
    HOLD_PAGE="$(forge_web "$LOOPER_HOLD_REPO" issue "$n")"
    forge_pin_issue "$LOOPER_HOLD_REPO" "$n" || log "could not pin $LOOPER_ORG/$LOOPER_HOLD_REPO#$n, the hold issue"
  fi
  forge_issue_comment "$LOOPER_HOLD_REPO" "$n" "$why The looper holds until $iso: the kicker starts no report and no manager before then, and the issues whose runs this limit ended keep their labels (no \`$LABEL_STUCK\`, no comment). Work resumes by itself after that time." >/dev/null || return 1
  log "the hold until $iso recorded on $LOOPER_ORG/$LOOPER_HOLD_REPO#$n"
}
hold_body() { # until
  cat <<B
The looper's hold (tacplus-dev/looper#157). A run whose model answers with the account's usage limit (\`You've hit your weekly limit · resets 3am (UTC)\`), on every model it may fall back to, ends as a hold: its issue keeps its labels and gets no comment, the reset time the refusal names is recorded here (the marker below, and a comment per hold), and the kicker starts no report and no manager until then. After the reset, work resumes with no person involved.

Nothing to do here: this issue stays open as the hold's place. Closing it only makes the next hold open another.

$HOLD_MARK$1 -->
B
}

# A looper job holds its repository while it is created, pending, waiting for
# the repository's resource_group or running (looper#16): the GitLab jobs API's
# scope[] parameters for those states.
LOOPER_JOB_SCOPES="scope[]=created&scope[]=pending&scope[]=waiting_for_resource&scope[]=running"

# A repository is busy while one of the active jobs (names, one per line) is a
# job of its looper: a report, looper-<repo>-<issue>, as the pipeline's plan
# names them (looper#70: one job per issue). Prints those jobs; with an issue,
# that issue's alone.
busy() { # repo jobs [issue]
  grep -E "^looper-${1//./\\.}-${3:-[0-9]+}\$" <<<"$2"
}

# The manager's job of a repository (looper#70), which alone merges to its main.
manager_job() { echo "looper-$1-manager"; } # repo

# GitHub credentials for a container that clones from GitHub (the tacplus
# compiler resolving `depends` through the private tacplus-dev/registry,
# looper#11): `docker run "${DOCKER_GITHUB_CREDS[@]}" ...`. Git in the
# container gets, from its environment alone, a credential helper for
# https://github.com and no other host, which answers from $GH_TOKEN (else
# $GITHUB_TOKEN) when git asks; the empty value first drops every other helper
# for github.com, so none stores the token. The token itself is only inherited
# (`-e GH_TOKEN`): it is on no command line, in no file and in no image.
# shellcheck disable=SC2016  # expanded by git's shell in the container, not here
DOCKER_GITHUB_CREDS=(
  -e GH_TOKEN -e GITHUB_TOKEN
  -e GIT_CONFIG_COUNT=2
  -e GIT_CONFIG_KEY_0=credential.https://github.com.helper -e GIT_CONFIG_VALUE_0=
  -e GIT_CONFIG_KEY_1=credential.https://github.com.helper
  -e 'GIT_CONFIG_VALUE_1=!f() { test "$1" = get || exit 0; t="${GH_TOKEN:-$GITHUB_TOKEN}"; test -n "$t" || exit 0; echo username=x-access-token; echo "password=$t"; }; f'
)
