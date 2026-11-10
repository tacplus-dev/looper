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
  "$LABEL_STUCK|d93f0b|A run ended without finishing, for no known reason; a person looks"
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

# Every call to the network ends (looper#112): a manager that waited on one
# without a bound held its job for hours, saying nothing. Each gh call is
# stopped after LOOPER_NET_TIMEOUT seconds (default 300), and so is each of
# curl's attempts (30 to connect); git gives up on a transfer that moves
# nothing for as long, with its own error ("RPC failed; curl 28 Operation too
# slow"), and never asks for a credential on a terminal: it fails, and says so.
LOOPER_NET_TIMEOUT="${LOOPER_NET_TIMEOUT:-300}"
export GIT_HTTP_LOW_SPEED_LIMIT="${GIT_HTTP_LOW_SPEED_LIMIT:-1}" GIT_HTTP_LOW_SPEED_TIME="${GIT_HTTP_LOW_SPEED_TIME:-$LOOPER_NET_TIMEOUT}" \
  GIT_TERMINAL_PROMPT=0 GCM_INTERACTIVE=never
gh() {
  local rc=0
  timeout -k 10 "$LOOPER_NET_TIMEOUT" gh "$@" || rc=$?
  (( rc != 124 && rc != 137 )) || echo "gh $1${2:+ $2}: no answer within ${LOOPER_NET_TIMEOUT}s; stopped (looper#112)" >&2
  return "$rc"
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
           labels: [.labels[] | {name: .}], createdAt: .created_at,
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
    gitlab)
      local p u roles='{}' l m; p="$(gl_project "$1")"
      issue="$(gl_api GET "$p/issues/$2")" || return 1
      comments="$(gl_all "$p/issues/$2/notes?sort=asc&order_by=created_at" 1000)" || return 1
      for u in $( { jq -r .author.username <<<"$issue"; jq -r '.[] | select(.system | not) | .author.username' <<<"$comments"; } | sort -u); do
        m="$(gl_api GET "$p/members/all?query=$(gl_enc "$u")")" || return 1
        l="$(jq --arg u "$u" '[.[] | select(.username == $u) | .access_level] | max // 0' <<<"$m")"
        roles="$(jq -c --arg u "$u" --argjson l "$l" '.[$u] = (if $l >= 50 then "OWNER" elif $l >= 40 then "MAINTAINER"
          elif $l >= 30 then "DEVELOPER" elif $l >= 20 then "REPORTER" elif $l >= 15 then "PLANNER" elif $l >= 10 then "GUEST" else "NONE" end)' <<<"$roles")"
      done
      jq -c --argjson r "$roles" '{a: .author.username, s: $r[.author.username], t: ("# " + .title + "\n\n" + (.description // ""))}' <<<"$issue"
      jq -c --argjson r "$roles" '.[] | select(.system | not) | {a: .author.username, s: $r[.author.username], t: (.body // "")}' <<<"$comments" ;;
  esac
}

# GitHub: a COLLABORATOR's permission on the repository (admin, maintain,
# write, triage, read). GitLab's roles come with the texts.
forge_permission() { # repo login
  [[ "$LOOPER_FORGE" == github ]] || return 1
  gh api "repos/$LOOPER_ORG/$1/collaborators/$2/permission" --jq .permission
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

# Ready: approved, not held, and every issue it is blocked by is closed. Any
# forge error along the way means not ready.
ready() { # repo issue
  local list r n state
  list="$(blockers "$1" "$2")" || return 1
  while read -r r n; do
    [[ -z "$r" ]] && continue
    state="$(issue_state "$r" "$n" 2>/dev/null)" || return 1
    [[ "$state" == CLOSED ]] || return 1
  done <<<"$list"
  return 0
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
  # Ready: every blocker closed. The first per repository is its next.
  while read -r r n b64; do
    [[ -n "$r" ]] || continue
    if awk -v r="$r" -v n="$n" '$1 == r && $2 == n { print $3, $4 }' <<<"$refs" | {
         while read -r br bn; do grep -qxF "$br $bn CLOSED" <<<"$states" || exit 1; done
       }; then echo "$r $n"; fi
  done <<<"$issues"
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
