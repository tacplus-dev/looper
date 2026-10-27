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

# The two labels, in a repository that lacks them. Never fatal.
ensure_kind_labels() { # repo
  gh label create "$LABEL_BUG" --repo "$LOOPER_ORG/$1" --color d73a4a \
    --description "The code does not do what it already promises: fixed, and released as a patch" >/dev/null 2>&1 || true
  gh label create "$LABEL_FEATURE" --repo "$LOOPER_ORG/$1" --color a2eeef \
    --description "New behaviour: needs design, approval and a ROADMAP.md entry; ships in a minor" >/dev/null 2>&1 || true
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

# Open approved issues in one repository that no run holds or parked, oldest
# first, as "number" lines.
approved_issues() { # repo
  gh issue list --repo "$LOOPER_ORG/$1" --state open --label "$LABEL_APPROVED" --limit 200 \
    --json number,labels,createdAt --jq "
      [.[] | select(all(.labels[].name; . != \"$LABEL_IN_PROGRESS\" and . != \"$LABEL_STUCK\" and . != \"$LABEL_DECISION\"))]
      | sort_by(.createdAt) | .[].number"
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

# The oldest ready issue in a repository, or nothing.
next_ready() { # repo
  local n
  for n in $(approved_issues "$1"); do
    if ready "$1" "$n"; then echo "$n"; return 0; fi
  done
  return 0
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
