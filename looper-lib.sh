# shellcheck shell=bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# looper-lib.sh: what the dispatcher (on the host) and repo-looper (in the
# container) must agree on, sourced by both so the rules live in one place:
# which labels mean what, and which issues are ready to work.
#
# Every forge call goes through gh (GH_TOKEN, or the host's gh login).

LOOPER_ORG="${LOOPER_ORG:-tacplus-dev}"

# Labels. Only someone with write access to a repository can set a label, so
# `approved` is the gate: an issue nobody with write access approved is never
# worked, whoever opened it and whatever its text says.
LABEL_APPROVED="approved"
LABEL_IN_PROGRESS="looper:in-progress"
LABEL_STUCK="looper:stuck"           # a run ended without finishing, for no known reason; a person looks
LABEL_DECISION="needs-decision"      # the looper needs a decision it may not make

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

# The kind and priority labels, in a repository that lacks them. Never fatal.
ensure_kind_labels() { # repo
  gh label create "$LABEL_BUG" --repo "$LOOPER_ORG/$1" --color d73a4a \
    --description "The code does not do what it already promises: fixed, and released as a patch" >/dev/null 2>&1 || true
  gh label create "$LABEL_FEATURE" --repo "$LOOPER_ORG/$1" --color a2eeef \
    --description "New behaviour: needs design, approval and a ROADMAP.md entry; ships in a minor" >/dev/null 2>&1 || true
  gh label create "$LABEL_PRIORITY_HIGH" --repo "$LOOPER_ORG/$1" --color b60205 \
    --description "The looper takes it before unlabelled ready issues; a running issue is never pre-empted" >/dev/null 2>&1 || true
  gh label create "$LABEL_PRIORITY_LOW" --repo "$LOOPER_ORG/$1" --color c5def5 \
    --description "The looper takes it after every other ready issue" >/dev/null 2>&1 || true
}

# A file of the platform's roadmap repository (ROADMAP.md, items/...), raw.
platform_file() { # path
  gh api "repos/$LOOPER_ORG/roadmap/contents/$1" -H "Accept: application/vnd.github.raw"
}

# The text on stdin links issue <repo>#<n>: `tacplus-dev/<repo>#<n>`,
# `<repo>#<n>` or its URL; with `own` (the repository's own ROADMAP.md), a
# bare `#<n>` too.
links_issue() { # repo n [own]
  local r="${1//./\\.}" n="$2" re
  re="(^|[^A-Za-z0-9_.-])($LOOPER_ORG/)?$r#$n([^0-9]|\$)|github\\.com/$LOOPER_ORG/$r/issues/$n([^0-9]|\$)"
  [[ "${3:-}" == own ]] && re="$re|(^|[^A-Za-z0-9_./-])#$n([^0-9]|\$)"
  grep -qE "$re"
}

log() { printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
die() { log "FATAL $*" >&2; exit 2; }
need() { command -v "$1" >/dev/null 2>&1 || die "required tool not found: $1"; }

# Open approved issues in one repository that no run holds or parked, in
# ISSUE_ORDER (by priority, then oldest first), as "number" lines.
approved_issues() { # repo
  gh issue list --repo "$LOOPER_ORG/$1" --state open --label "$LABEL_APPROVED" --limit 200 \
    --json number,labels,createdAt --jq "
      [.[] | select(all(.labels[].name; . != \"$LABEL_IN_PROGRESS\" and . != \"$LABEL_STUCK\" and . != \"$LABEL_DECISION\"))]
      | sort_by($ISSUE_ORDER) | .[].number"
}

# The issues an issue waits on: lines `Blocked-by: #N` (same repository) or
# `Blocked-by: tacplus-dev/<repo>#N` in its body, printed as "<repo> <N>".
# Fails (non-zero) when the body cannot be read: an unreadable issue is never
# taken for an unblocked one.
blockers() { # repo issue
  local body
  body="$(gh issue view "$2" --repo "$LOOPER_ORG/$1" --json body --jq .body)" || return 1
  printf '%s\n' "$body" | parse_blockers "$1"
}

# The `Blocked-by:` lines of the text on stdin, as "<repo> <N>"; `#N` is in repo.
parse_blockers() { # repo
  grep -oiE '^[[:space:]]*blocked-by:[[:space:]]*([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)?#[0-9]+' \
    | sed -E 's/^[[:space:]]*[Bb][Ll][Oo][Cc][Kk][Ee][Dd]-[Bb][Yy]:[[:space:]]*//' \
    | while IFS= read -r ref; do
        num="${ref##*#}"; slug="${ref%#*}"
        if [[ -z "$slug" ]]; then echo "$1 $num"; else echo "${slug##*/} $num"; fi
      done
  return 0
}

# Ready: approved, not held, and every issue it is blocked by is closed. Any
# forge error along the way means not ready.
ready() { # repo issue
  local list r n state
  list="$(blockers "$1" "$2")" || return 1
  while read -r r n; do
    [[ -z "$r" ]] && continue
    state="$(gh issue view "$n" --repo "$LOOPER_ORG/$r" --json state --jq .state 2>/dev/null)" || return 1
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

# Every repository's next ready issue, as "<repo> <number>" lines: the rule
# of next_ready, read for the whole org at once (the kicker's pass, looper#24),
# one search and one GraphQL query for the blockers' states. next_ready costs a
# request per issue and per blocker: about 270 for the org in 2026-10, past
# GitHub's 5000 an hour at a pass every 3 minutes. A blocker GitHub does not
# resolve to an issue holds its issue. Fails when GitHub cannot be read.
# The lines are in ISSUE_ORDER of those issues: a repository whose next issue
# is priority:high comes first (looper#31), so it is planned first.
ready_by_repo() {
  local all issues r n b64 refs q="" i=0 out states
  all="$(gh search issues --owner "$LOOPER_ORG" --state open --label "$LABEL_APPROVED" --limit 1000 \
           --json repository,number,labels,createdAt,body)" || return 1
  # Not held, in ISSUE_ORDER: "<repo> <number> <body, base64>".
  issues="$(jq -r "[.[] | select(all(.labels[].name; . != \"$LABEL_IN_PROGRESS\" and . != \"$LABEL_STUCK\" and . != \"$LABEL_DECISION\"))]
                   | sort_by($ISSUE_ORDER) | .[] | \"\\(.repository.name) \\(.number) \\(.body // \"\" | @base64)\"" <<<"$all")" || return 1
  # Each issue's blockers: "<repo> <number> <blocker repo> <blocker number>".
  refs="$(while read -r r n b64; do
            [[ -n "$r" ]] || continue
            base64 -d <<<"$b64" | parse_blockers "$r" | sed "s/^/$r $n /"
          done <<<"$issues")"
  # The blockers' states, one aliased GraphQL query: "<repo> <number> <state>".
  while read -r r n; do
    [[ -n "$r" ]] || continue
    q="$q b$i: repository(owner: \"$LOOPER_ORG\", name: \"$r\") { issue(number: $n) { state } }"; i=$((i + 1))
  done < <(awk 'NF { print $3, $4 }' <<<"$refs" | sort -u)
  states=""
  if [[ -n "$q" ]]; then
    # A blocker that is no issue answers null and gh exits 1; no data at all is GitHub refusing.
    out="$(gh api graphql -f query="{$q }" 2>/dev/null)" || true
    jq -e '.data | type == "object"' <<<"$out" >/dev/null 2>&1 || return 1
    states="$(paste -d' ' <(awk 'NF { print $3, $4 }' <<<"$refs" | sort -u) \
                          <(jq -r '.data as $d | range(0; $d | length) | $d["b\(.)"].issue.state // "MISSING"' <<<"$out"))"
  fi
  # Ready: every blocker closed. The first per repository is its next.
  while read -r r n b64; do
    [[ -n "$r" ]] || continue
    if awk -v r="$r" -v n="$n" '$1 == r && $2 == n { print $3, $4 }' <<<"$refs" | {
         while read -r br bn; do grep -qx "$br $bn CLOSED" <<<"$states" || exit 1; done
       }; then echo "$r $n"; fi
  done <<<"$issues" | awk '!seen[$1]++'
}

# A looper job holds its repository while it is created, pending, waiting for
# the repository's resource_group or running (looper#16): the GitLab jobs API's
# scope[] parameters for those states.
LOOPER_JOB_SCOPES="scope[]=created&scope[]=pending&scope[]=waiting_for_resource&scope[]=running"

# A repository is busy while one of the active jobs (names, one per line) is a
# job of its looper: looper-<repo>-<issue>, as the pipeline's plan names them.
# Prints those jobs.
busy() { # repo jobs
  grep -E "^looper-${1//./\\.}-[0-9]+\$" <<<"$2"
}

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
