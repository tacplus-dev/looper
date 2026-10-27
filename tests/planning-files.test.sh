#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# planning-files-check, the CI check of the four planning files, against a
# scratch repository: it fails on a missing file and on an edited or removed
# HISTORY.md line, passes on an appended one, and only warns on a missing
# ROADMAP.md.
# Run: tests/planning-files.test.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

fail() { echo "FAIL $NAME: $*" >&2; exit 1; }
pass() { echo "ok $NAME"; }
scenario() { # name: a repository with the four files, HISTORY.md with two entries
  NAME="$1"; R="$TMP/$1"; git init -q -b main "$R"; cd "$R"
  for f in ROADMAP STATE PROPOSALS; do echo "# $f" > "$f.md"; done
  printf '# History: x\n\n- 2026-10-01 agent decision one (a)\n- 2026-10-02 looper issue two (#2, abc1234)\n' > HISTORY.md
  git add -A && git commit -q -m base; BASE="$(git rev-parse HEAD)"
}
commit() { git add -A && git commit -q --allow-empty -m change; }
check() { OUT="$("$ROOT/planning-files-check" "$@" 2>&1)"; }
passes() { check "$@" || fail "expected a pass: $OUT"; }
fails() { if check "$@"; then fail "expected a failure: $OUT"; fi; }
has() { grep -qF -- "$1" <<<"$OUT" || fail "expected \"$1\" in: $OUT"; }

scenario appended
echo '- 2026-10-03 looper issue three (#3, def5678)' >> HISTORY.md; commit
passes "$BASE"; has "planning-files-check: ok"
pass

scenario unchanged
echo more >> STATE.md; commit
passes "$BASE"
pass

scenario edited
sed -i 's/decision one/decision 1/' HISTORY.md; commit
fails "$BASE"; has "::error file=HISTORY.md,line=3::"; has "append-only"
pass

scenario removed-line
sed -i '/issue two/d' HISTORY.md; commit
fails "$BASE"; has "HISTORY.md changed other than by lines added at its end"
pass

scenario inserted-line
sed -i '3i - 2026-10-01 agent decision zero (z)' HISTORY.md; commit
fails "$BASE"
pass

scenario removed-file
git rm -q HISTORY.md; commit
fails "$BASE"; has "HISTORY.md is missing"; has "HISTORY.md was removed"
pass

scenario missing-state
git rm -q STATE.md; commit
fails "$BASE"; has "::error file=STATE.md::"
fails; has "STATE.md is missing"
pass

scenario missing-proposals
git rm -q PROPOSALS.md; commit
fails
pass

# Bootstrap: no ROADMAP.md yet passes, with a warning.
scenario no-roadmap
git rm -q ROADMAP.md; commit
passes "$BASE"; has "::warning file=ROADMAP.md::"
pass

# HISTORY.md new since BASE (the repository's first) is all appended.
scenario created
git rm -q HISTORY.md; commit; BASE="$(git rev-parse HEAD)"
printf '# History: x\n\n- 2026-10-03 looper issue three (#3, def5678)\n' > HISTORY.md; commit
passes "$BASE"
pass

# A file without a final newline still takes lines at its end.
scenario no-final-newline
printf '%s' "$(cat HISTORY.md)" > HISTORY.md; commit; BASE="$(git rev-parse HEAD)"
printf '\n- 2026-10-03 looper issue three (#3, def5678)\n' >> HISTORY.md; commit
passes "$BASE"
pass

# No base (a new branch's push: all zeros, or none): only presence is checked.
scenario no-base
sed -i 's/decision one/decision 1/' HISTORY.md; commit
passes 0000000000000000000000000000000000000000
passes
check 1111111111111111111111111111111111111111 || fail "unknown base: $OUT"; has "::warning file=HISTORY.md::"
pass

echo "planning-files-check: all scenarios pass"
