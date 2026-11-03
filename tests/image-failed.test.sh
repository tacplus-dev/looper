#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# image-failed (looper#58), as the image workflow runs it when a run on main
# fails, against a stub gh: with no open issue for it, it opens a `bug` issue
# with the run, the commit and the tail of the failed step's log; with one open,
# it comments on that one and opens none; another open bug is not it; a log it
# cannot read is said, not a failure.
# Run: tests/image-failed.test.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
TITLE="The looper image is not published: the image workflow fails on main"

fail() { echo "FAIL $NAME: $*" >&2; exit 1; }
pass() { echo "ok $NAME"; }
has() { grep -qF -- "$2" <<<"$1" || fail "expected \"$2\" in: $1"; }

# GitHub: the open issues in $TMP/issues.json, the failed step's log in
# $TMP/run.log (none: gh cannot read it); every call in $TMP/gh.log, each
# body in $TMP/body.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<EOF
#!/usr/bin/env bash
echo "gh \$*" >> "$TMP/gh.log"
case "\$1 \$2" in
  "run view") [[ -f "$TMP/run.log" ]] || { echo "no log" >&2; exit 1; }; cat "$TMP/run.log" ;;
  "issue list") cat "$TMP/issues.json" ;;
  "issue create") cat > "$TMP/body"; echo "https://github.com/tacplus-dev/looper/issues/99" ;;
  "issue comment") cat > "$TMP/body" ;;
  *) echo "gh stub: \$*" >&2; exit 1 ;;
esac
EOF
chmod +x "$TMP/bin/gh"
run() {
  : > "$TMP/gh.log"; rm -f "$TMP/body"
  OUT="$(env -i PATH="$TMP/bin:$PATH" GH_TOKEN=ghs_stub GITHUB_REPOSITORY=tacplus-dev/looper \
    GITHUB_SHA=9f6f735aaaabbbbccccddddeeeeffff000011112 GITHUB_RUN_ID=41559787468 GITHUB_SERVER_URL=https://github.com \
    "$ROOT/image-failed" 2>&1)" || fail "image-failed failed: $OUT"
  CALLS="$(cat "$TMP/gh.log")"; BODY="$(cat "$TMP/body" 2>/dev/null || true)"
}
{ for i in $(seq 60); do echo "line $i"; done; echo "FAIL plan: a nightly scans the main branch"; } > "$TMP/run.log"

NAME="none open: a bug issue with the run, the commit and the failed step's log"
echo '[]' > "$TMP/issues.json"
run
has "$CALLS" "gh issue create --repo tacplus-dev/looper --title $TITLE --label bug --body-file -"
has "$BODY" "https://github.com/tacplus-dev/looper/actions/runs/41559787468"
has "$BODY" "9f6f735"
has "$BODY" "FAIL plan: a nightly scans the main branch"
! grep -qx "line 1" <<<"$BODY" || fail "the whole log, not its tail: $BODY"
has "$OUT" "issues/99"
pass

NAME="one open: a comment on it, no new issue"
echo "[{\"number\":61,\"title\":\"$TITLE\"},{\"number\":12,\"title\":\"another bug\"}]" > "$TMP/issues.json"
run
has "$CALLS" "gh issue comment 61 --repo tacplus-dev/looper --body-file -"
! grep -q "issue create" <<<"$CALLS" || fail "opened another: $CALLS"
has "$BODY" "https://github.com/tacplus-dev/looper/actions/runs/41559787468"
has "$BODY" "FAIL plan: a nightly scans the main branch"
pass

NAME="another open bug is not it"
echo '[{"number":12,"title":"another bug"}]' > "$TMP/issues.json"
run
has "$CALLS" "gh issue create"
! grep -q "issue comment" <<<"$CALLS" || fail "commented on another bug: $CALLS"
pass

NAME="a log it cannot read is said, and the issue still opened"
echo '[]' > "$TMP/issues.json"; rm "$TMP/run.log"
run
has "$CALLS" "gh issue create"
has "$BODY" "could not be read"
pass

echo "image-failed: all passed"
