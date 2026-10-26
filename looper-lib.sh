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
LABEL_STUCK="looper:stuck"           # a run ended without finishing; a person looks
LABEL_DECISION="needs-decision"      # the looper needs a decision it may not make

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
blockers() { # repo issue
  gh issue view "$2" --repo "$LOOPER_ORG/$1" --json body --jq .body \
    | grep -oiE '^[[:space:]]*blocked-by:[[:space:]]*([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)?#[0-9]+' \
    | sed -E 's/^[[:space:]]*[Bb][Ll][Oo][Cc][Kk][Ee][Dd]-[Bb][Yy]:[[:space:]]*//' \
    | while IFS= read -r ref; do
        num="${ref##*#}"; path="${ref%#*}"
        if [[ -z "$path" ]]; then echo "$1 $num"; else echo "${path##*/} $num"; fi
      done
}

# Ready: approved, not held, and every issue it is blocked by is closed.
ready() { # repo issue
  local r n state
  while read -r r n; do
    [[ -z "$r" ]] && continue
    state="$(gh issue view "$n" --repo "$LOOPER_ORG/$r" --json state --jq .state 2>/dev/null || echo UNKNOWN)"
    [[ "$state" == CLOSED ]] || return 1
  done < <(blockers "$1" "$2")
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
