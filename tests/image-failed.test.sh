#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# image-failed (looper#58), as the image workflow runs it when a run on main
# fails, against a stub gh: with no open issue for it, it opens a `bug` issue
# with the run, the commit and the tail of the failed step's log; with one open,
# it comments on that one and opens none; another open bug is not it; a log it
# cannot read is said, not a failure. The log is the failed job's, by the jobs
# API (looper#154): the report job runs inside the run it reports, which
# `gh run view --log-failed` refuses while the run is in progress; the failed
# step's lines alone, up to the error that failed it, timestamps and colours
# stripped.
# Run: tests/image-failed.test.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
TITLE="The looper image is not published: the image workflow fails on main"

fail() { echo "FAIL $NAME: $*" >&2; exit 1; }
pass() { echo "ok $NAME"; }
has() { grep -qF -- "$2" <<<"$1" || fail "expected \"$2\" in: $1"; }
lacks() { ! grep -qF -- "$2" <<<"$1" || fail "unexpected \"$2\" in: $1"; }

# GitHub: the open issues in $TMP/issues.json, the run's jobs in $TMP/jobs.json
# (none: gh cannot list them), each job's log in $TMP/job-<id>.log (none: gh
# cannot read it); every call in $TMP/gh.log, each body in $TMP/body.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<EOF
#!/usr/bin/env bash
echo "gh \$*" >> "$TMP/gh.log"
case "\$1 \$2" in
  "api repos/tacplus-dev/looper/actions/runs/41559787468/jobs")
    [[ "\$3" == --jq ]] || { echo "gh stub: no --jq: \$*" >&2; exit 1; }
    [[ -f "$TMP/jobs.json" ]] || { echo "HTTP 404" >&2; exit 1; }; jq -r "\$4" "$TMP/jobs.json" ;;
  "api repos/tacplus-dev/looper/actions/jobs/"*/logs)
    [[ "\$3" == --allow-escape-sequences ]] || { echo "gh stub: the log holds colours: \$*" >&2; exit 1; }
    id="\${2#repos/tacplus-dev/looper/actions/jobs/}"; id="\${id%/logs}"
    [[ -f "$TMP/job-\$id.log" ]] || { echo "HTTP 404" >&2; exit 1; }; cat "$TMP/job-\$id.log" ;;
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
# The run's jobs as the API lists them: the image job failed at its Test step,
# the report job (this one) is in progress. The image job's log as the API
# serves it: every line stamped, a step from its ##[group]Run line, the error
# that failed it, then the post steps.
cat > "$TMP/jobs.json" <<'EOF'
{"total_count": 2, "jobs": [
  {"id": 132391203317, "name": "image", "status": "completed", "conclusion": "failure", "steps": [
    {"name": "Set up job", "status": "completed", "conclusion": "success", "number": 1},
    {"name": "Only main", "status": "completed", "conclusion": "success", "number": 3},
    {"name": "Test", "status": "completed", "conclusion": "failure", "number": 4},
    {"name": "Log in to ghcr", "status": "completed", "conclusion": "skipped", "number": 5},
    {"name": "Complete job", "status": "completed", "conclusion": "success", "number": 9}]},
  {"id": 132395769913, "name": "report", "status": "in_progress", "conclusion": null, "steps": []}
]}
EOF
job_log() { # the image job's log, its Test step $1 lines long before its FAIL, with or without the error line
  { printf '2026-11-14T08:32:38.7729725Z ##[group]Runner Image Provisioner\n2026-11-14T08:32:38.7731499Z Version: 20261103.629\n'
    printf '2026-11-14T08:32:41.0381854Z ##[group]Run set -eu\n2026-11-14T08:32:41.0382000Z only main: ok\n'
    printf '2026-11-14T08:32:41.2555392Z ##[group]Run command -v just >/dev/null || sudo apt-get install -y -q just\n'
    printf '2026-11-14T08:32:41.2557617Z \033[36;1mcommand -v just >/dev/null || sudo apt-get install -y -q just\033[0m\n'
    for i in $(seq "$1"); do printf '2026-11-14T08:33:%02d.0000000Z line %d\n' "$((i % 60))" "$i"; done
    printf '2026-11-14T08:51:43.2041943Z \033[31mFAIL plan: a nightly scans the main branch\033[0m\n'
    [[ "${2:-}" == no-error ]] || printf '2026-11-14T08:51:43.2916977Z ##[error]Process completed with exit code 1.\n'
    printf '2026-11-14T08:51:43.3118321Z Post job cleanup.\n2026-11-14T08:51:43.5142353Z Cleaning up orphan processes\n'
  } > "$TMP/job-132391203317.log"
}
job_log 60

NAME="none open: a bug issue with the run, the commit and the failed step's log"
echo '[]' > "$TMP/issues.json"
run
has "$CALLS" "gh issue create --repo tacplus-dev/looper --title $TITLE --label bug --body-file -"
has "$BODY" "https://github.com/tacplus-dev/looper/actions/runs/41559787468"
has "$BODY" "9f6f735"
has "$BODY" "FAIL plan: a nightly scans the main branch"
has "$BODY" "line 60"
! grep -qx "line 1" <<<"$BODY" || fail "the whole log, not its tail: $BODY"
has "$OUT" "issues/99"
pass

NAME="the log is the failed job's by the jobs API, not the run's, which is still in progress"
has "$CALLS" "gh api repos/tacplus-dev/looper/actions/runs/41559787468/jobs"
has "$CALLS" "gh api repos/tacplus-dev/looper/actions/jobs/132391203317/logs"
lacks "$CALLS" "gh run view"
lacks "$CALLS" "132395769913"
pass

NAME="the failed step's lines alone, up to the error that failed it, timestamps and colours stripped"
job_log 20; echo '[]' > "$TMP/issues.json"
run
has "$BODY" 'job `image`, step `Test`'
has "$BODY" "##[error]Process completed with exit code 1."
has "$BODY" "FAIL plan: a nightly scans the main branch"
grep -qx "line 1" <<<"$BODY" || fail "the step's first lines are missing: $BODY"
has "$BODY" "command -v just >/dev/null || sudo apt-get install -y -q just"
lacks "$BODY" "Post job cleanup"
lacks "$BODY" "Cleaning up orphan processes"
lacks "$BODY" "only main: ok"
lacks "$BODY" "Runner Image Provisioner"
lacks "$BODY" "2026-11-14T"
lacks "$BODY" $'\033['
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

NAME="a job log without an error line (the job was cancelled, say) gives its tail"
echo '[]' > "$TMP/issues.json"; job_log 60 no-error
run
has "$BODY" "FAIL plan: a nightly scans the main branch"
has "$BODY" "Cleaning up orphan processes"
! grep -qx "line 1" <<<"$BODY" || fail "the whole log, not its tail: $BODY"
pass

NAME="a job log it cannot read is said, and the issue still opened"
echo '[]' > "$TMP/issues.json"; rm "$TMP/job-132391203317.log"
run
has "$CALLS" "gh issue create"
has "$BODY" "could not be read"
has "$BODY" 'job `image`, step `Test`'
pass

NAME="jobs it cannot list are said, and the issue still opened"
rm "$TMP/jobs.json"
run
has "$CALLS" "gh issue create"
has "$BODY" "could not be read"
pass

echo "image-failed: all passed"
