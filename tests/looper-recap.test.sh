#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# looper-recap (looper#57) against recorded API fixtures (tests/recap/: GitLab's
# jobs and job logs, gh's repositories and workflow runs, gcloud's builds, and
# the recaps of earlier nights) through stub curl, gh and gcloud: collect gives
# a byte-identical recap.json (tests/recap/expected.json) whatever the clock,
# zone and locale, and finds the seed cases of 2026-11-02 by itself (fresh-VM
# image-pull failures, an issue held hours by "would outlast this job" with one
# tacplus child at a time, a 2-hour scan of tacplus, a 150-minute full-gate
# land); classify puts a once-only, recovered failure in the transient list, a
# 3-night recurrence and a threshold crossed under advice, and ignores a night
# older than 7; report writes the recap file with links to the night's advice.
# The advice's check is looper-suggest's (tests/looper-suggest.test.sh).
# Run: tests/looper-recap.test.sh   (REGEN=1: rewrite tests/recap/expected.json)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FX="$ROOT/tests/recap"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
NAME=""
fail() { echo "FAIL $NAME: $*" >&2; exit 1; }
pass() { echo "ok $NAME"; }
has() { grep -qF -- "$2" <<<"$1" || fail "expected \"$2\" in: $1"; }
lacks() { ! grep -qF -- "$2" <<<"$1" || fail "unexpected \"$2\" in: $1"; }

# curl: the GitLab API from $FX/gitlab/<project>/, the token read from stdin
# (never on the command line); every call logged.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
url="${*: -1}"; echo "curl $*" >> "$TMP/calls"
[[ "$*" != *glpat-recap* ]] || { echo "the token is on the command line" >&2; exit 9; }
[[ "$*" == *"-H @-"* && "$(cat)" == "PRIVATE-TOKEN: glpat-recap" ]] || exit 22
p="${url#https://gitlab.test/api/v4/projects/}"; proj="${p%%/*}"; proj="${proj//%2F/_}"; rest="${p#*/}"
case "$rest" in
  jobs\?*) page="$(grep -oE 'page=[0-9]+' <<<"$rest" | tail -1 | cut -d= -f2)"
           f="$FX/gitlab/$proj/jobs-$page.json"; [[ -f "$f" ]] || { [[ -d "$FX/gitlab/$proj" ]] && { echo '[]'; exit 0; }; exit 22; }; cat "$f" ;;
  jobs/*/trace) id="${rest#jobs/}"; id="${id%/trace}"; f="$FX/gitlab/$proj/trace-$id.txt"; [[ -f "$f" ]] || exit 22; cat "$f" ;;
  *) exit 22 ;;
esac
EOF
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
echo "gh $*" >> "$TMP/calls"
case "$1 $2" in
  "repo list") [[ "$3" == tacplus-dev ]] && cat "$FX/gh/repos.json" ;;
  "api -X") case "$4" in
              repos/tacplus-dev/looper/actions/workflows/image.yml/runs) [[ "$*" == *"-f branch=main"* ]] && cat "$FX/gh/image-runs.json" ;;
              *) r="${4#repos/tacplus-dev/}"; r="${r%/actions/runs}"
                 [[ "$*" == *"-f created=2026-11-01T03:00:00Z..2026-11-02T03:00:00Z"* ]] || exit 1
                 cat "$FX/gh/runs-$r.json" ;;
            esac ;;
  "api repos/tacplus-dev/looper/commits/main") cat "$FX/gh/commit-main.json" ;;
  "api repos/tacplus-dev/looper/compare/aaaaaaaaaaaa1111111111111111111111111111...cccccccccccc3333333333333333333333333333") cat "$FX/gh/compare.json" ;;
  *) echo "stub gh: unexpected $*" >&2; exit 3 ;;
esac
EOF
cat > "$TMP/bin/gcloud" <<'EOF'
#!/usr/bin/env bash
echo "gcloud $*" >> "$TMP/calls"
[[ "$1 $2 $3" == "builds list --project=jody1-328023" && "$*" == *'createTime>="2026-11-01T03:00:00Z"'* ]] || exit 1
cat "$FX/gcloud/builds.json"
EOF
cat > "$TMP/bin/docker" <<'EOF'
#!/usr/bin/env bash
echo "docker $*" >> "$TMP/calls"
[[ "$*" == "buildx imagetools inspect ghcr.io/tacplus-dev/looper:main --format {{json .Image}}" ]] || exit 1
cat "$FX/docker/inspect.json"
EOF
chmod +x "$TMP/bin/"*
export PATH="$TMP/bin:$PATH" TMP FX
ENVS=(GITLAB_TOKEN=glpat-recap LOOPER_BUILD_API=https://gitlab.test/api/v4 LOOPER_ORG=tacplus-dev)
recap() { env -u LOOPER_RECAP_PROJECTS -u LOOPER_SUGGEST_PROJECTS -u LOOPER_RECAP_ACTIONS_REPOS "${ENVS[@]}" "$ROOT/looper-recap" "$@"; }
UNTIL=2026-11-02T03:00:00Z

NAME=collect-byte-identical
recap collect --until "$UNTIL" --out "$TMP/recap.json" 2> "$TMP/err" || fail "collect: $(cat "$TMP/err")"
if [[ -n "${REGEN:-}" ]]; then cp "$TMP/recap.json" "$FX/expected.json"; fi
cmp -s "$TMP/recap.json" "$FX/expected.json" || { diff -u "$FX/expected.json" "$TMP/recap.json" | head -40 >&2; fail "recap.json is not tests/recap/expected.json"; }
# The same inputs give the same file: another zone, locale and hour of the run.
TZ=America/Chicago LC_ALL=C recap collect --until "2026-11-01T22:00:00-05:00" > "$TMP/again.json" 2>/dev/null || fail "collect again"
cmp -s "$TMP/again.json" "$FX/expected.json" || fail "a second collect differs: $(diff "$FX/expected.json" "$TMP/again.json" | head -5)"
lacks "$(cat "$TMP/calls")" glpat-recap
pass

NAME=collect-finds-the-seed-cases
J="$TMP/recap.json"
q() { jq -r "$1" "$J"; }
[[ "$(q .window.from) $(q .window.until) $(q .night)" == "2026-11-01T03:00:00Z 2026-11-02T03:00:00Z 2026-11-02" ]] || fail "window: $(q .window)"
# LOOPER_SUGGEST_PROJECTS' default plus tacplus-dev/cluster, which cannot be read: named, not guessed.
[[ "$(q '.sources | to_entries | map("\(.key)=\(.value)") | join(" ")')" == "cloud-build=ok github-actions=ok gitlab:tacplus-dev/build=ok gitlab:tacplus-dev/cluster=unavailable: GET projects/tacplus-dev%2Fcluster/jobs: curl exit 22 gitlab:tacplus-dev/looper=ok image=ok" ]] ||
  fail "sources: $(q .sources)"
[[ "$(q '.projects["tacplus-dev/looper"] | "\(.jobs) \(.status.failed) \(.failures.image_pull) \(.failures.runner_system_failure) \(.failures.timeout)"')" == "20 8 6 1 1" ]] ||
  fail "looper's jobs: $(q '.projects["tacplus-dev/looper"]')"
[[ "$(q '.projects["tacplus-dev/build"].failures.gate_failure')" == 1 ]] || fail "build: $(q '.projects["tacplus-dev/build"]')"
# Queue (created to started) and prepare (started to Running on): looper-tacplus-16 queued 97 minutes
# behind the scan, looper-tacplus-12 20 minutes, prepared in 2.
[[ "$(q '[.longest.queues[0:2][] | "\(.job) \(.minutes)"] | join(", ")')" == "looper-tacplus-16 97, looper-tacplus-12 20" ]] || fail "longest queue: $(q .longest.queues)"
[[ "$(q '.projects["tacplus-dev/looper"].queue_s | "\(.max) \(.p90)"')" == "5820 1200" ]] || fail "queue: $(q '.projects["tacplus-dev/looper"].queue_s')"
has "$(q '.items[] | select(.key == "queue/tacplus-dev/looper") | .summary')" "queue time p90 20 min over 19 jobs (p50 1, max 97; threshold 15 min)"
[[ "$(q '[.failed_jobs[] | select(.class == "image_pull") | select(.before_ready and .recovered)] | length')" == 6 ]] || fail "image pulls: $(q .failed_jobs)"
[[ "$(q '.items[] | select(.key == "failures/tacplus-dev/looper/image_pull") | "\(.count) \(.over) \(.recovered)"')" == "6 true true" ]] || fail "$(q .items)"
# tacplus: one child at a time; #14 held 7.2 h for want of a slot, then 2.42 h by its limit.
[[ "$(q '.loopers.tacplus.slots | "\(.plans) \(.capacity) \(.peak) \(.mean_use)"')" == "3 1 1 0.67" ]] || fail "slots: $(q .loopers.tacplus.slots)"
[[ "$(q '.loopers.tacplus.holds.no_free_slot | "\(.count) \(.issues) \(.max_hours)"')" == "1 [14] 7.2" ]] || fail "holds: $(q .loopers.tacplus.holds)"
[[ "$(q '.loopers.tacplus.holds.limit_outlasts_job.max_hours')" == 2.42 ]] || fail "holds: $(q .loopers.tacplus.holds)"
has "$(q '.items[].key')" "held/tacplus/limit_outlasts_job"
has "$(q '.items[] | select(.key == "held/tacplus/limit_outlasts_job") | .summary')" "tacplus: issues held back by limit_outlasts_job 1 time (#14), up to 2.42 h"
# The hours each ready issue waited, and why (Jody, on looper#57): #15 by a conflict (and what overlaps),
# #16 queued behind the scan of tacplus, #12's land behind the others; each reason says what would let it run in parallel.
[[ "$(q '.loopers.tacplus.waits | "\(.hours) \(.by_issue["14"].hours) \(.by_issue["15"].why.conflict) \(.by_issue["16"].why.scan_holds_repo) \(.by_issue["12"].why.behind_a_land)"')" == "18.92 9.62 7.2 1.6 0.5" ]] ||
  fail "waits: $(q .loopers.tacplus.waits)"
[[ "$(q '.loopers.tacplus.holds.conflict.overlaps[0] | "\(.issues) \(.what)"')" == "[15] both edit src/codec.rs and its tests" ]] || fail "overlaps: $(q .loopers.tacplus.holds.conflict)"
has "$(q '.items[] | select(.key == "held/tacplus/conflict") | "\(.wait_hours) \(.summary) \(.parallel)"')" "7.2 tacplus: issues held back by conflict 1 time (#15), up to 7.2 h, 7.2 h in all; overlapping: both edit src/codec.rs and its tests file-level conflicts instead of areas"
has "$(q '.items[] | select(.key == "held/tacplus/scan_holds_repo") | .parallel')" "a scan that does not hold the repository's lock"
# The image against main's head (looper#58): 2 commits behind, the latest image run cancelled.
[[ "$(q '.image | "\(.current) \(.revision[0:12]) \(.main[0:12]) \([.missing[].sha] | join(",")) \(.latest_run.conclusion)"')" == "false aaaaaaaaaaaa cccccccccccc bbbbbbbbbbbb,cccccccccccc cancelled" ]] || fail "image: $(q .image)"
has "$(q '.items[] | select(.key == "image/tacplus-dev/looper") | "\(.over) \(.wait_hours) \(.summary)"')" "true 9 ghcr.io/tacplus-dev/looper:main is at aaaaaaaaaaaa, main at cccccccccccc: 2 commits of main not in it, the oldest 9 h old; the latest image run: cancelled at cccccccccccc"
# A 150-minute full-gate land, and a 125-minute scan holding tacplus.
[[ "$(q '.loopers.tacplus.lands.full | "\(.count) \(.minutes.max)"')" == "1 150" ]] || fail "lands: $(q .loopers.tacplus.lands)"
has "$(q '.items[] | select(.key == "land/tacplus/full") | .summary')" "tacplus: 1 land on the gates full, up to 150 min"
[[ "$(q '.loopers.tacplus.scan_minutes | join(",")')" == 125 ]] || fail "scan: $(q .loopers.tacplus)"
has "$(q '.items[].key')" "scan/tacplus"
# Runner pools: the VMs, the jobs that failed before one was ready, the disk at a job's end.
[[ "$(q '.runner_pools["tacplus-dev arm64 autoscaler"] | "\(.vms) \(.failed_before_ready) \(.disk_pct.max)"')" == "12 6 45" ]] || fail "pool: $(q .runner_pools)"
[[ "$(q '.runner_pools["tacplus-dev arm64 autoscale-16"].disk_pct.max')" == 72 ]] || fail "pool: $(q .runner_pools)"
# GitHub Actions (nightly, release, images only) and Cloud Build.
[[ "$(q '.actions.by_workflow | keys | join(",")')" == tacplus/nightly ]] || fail "actions: $(q .actions)"
[[ "$(q '.items[] | select(.key == "actions/tacplus/nightly") | "\(.count) \(.recovered)"')" == "1 true" ]] || fail "$(q .items)"
[[ "$(q '.cloud_build | "\(.builds) \(.failed) \(.minutes.max)"')" == "2 1 21" ]] || fail "cloud build: $(q .cloud_build)"
# A job outside the window is left out.
lacks "$(q '.failed_jobs[].id')" 900
pass

NAME=classify
recap classify "$J" --history "$FX/history" > "$TMP/classes.json" || fail "classify"
c() { jq -r "$1" "$TMP/classes.json"; }
[[ "$(c '.history | join(",")')" == "2026-10-31,2026-11-01" ]] || fail "history: $(c .history)"
# A 3-night recurrence, though recovered and under its threshold tonight: advice.
[[ "$(c '.recurring[] | select(.key == "failures/tacplus-dev/looper/runner_system_failure") | "\(.nights) \(.over)"')" == "3 false" ]] || fail "$(c .)"
# Over a threshold tonight: advice, the seed cases among them.
for k in failures/tacplus-dev/looper/image_pull held/tacplus/limit_outlasts_job held/tacplus/no_free_slot land/tacplus/full scan/tacplus; do
  has "$(c '.recurring[].key')" "$k"
done
# Seen once (the 10-25 night is older than 7), recovered on retry: transient, no advice.
[[ "$(c '.transient | map(.key) | join(" ")')" == "actions/tacplus/nightly failures/tacplus-dev/looper/timeout" ]] || fail "transient: $(c .transient)"
# Seen once, not recovered: noted, no advice.
[[ "$(c '.once | map(.key) | join(" ")')" == "cloud-build/jody1-328023 failures/tacplus-dev/build/gate_failure" ]] || fail "once: $(c .once)"
lacks "$(c '.recurring[].key')" "timeout"
pass

NAME=report
mkdir -p "$TMP/s"
cat > "$TMP/s/2026-11-02-fresh-vm-image.md" <<'S'
Suggestion: Fresh VM image
Type: Operability
Summary: Apply the baked runner image

## Advice
Recap: 2026-11-02 failures/tacplus-dev/looper/image_pull
Cause: c
Change: d
Gain: g

## Status
open
S
printf 'held/tacplus/limit_outlasts_job tacplus-dev/looper#33 the job sizing\nnot/a/key tacplus-dev/looper#1 x\nscan/tacplus nonsense x\n' > "$TMP/covered"
recap report "$J" "$TMP/classes.json" --suggestions "$TMP/s" --covered "$TMP/covered" > "$TMP/r.md" || fail "report"
R="$(cat "$TMP/r.md")"
has "$R" "# Recap of 2026-11-02"
has "$R" "| tacplus-dev/looper | 20 | 8 |"
has "$R" "Failures by class: image_pull 6, gate_failure 1,"
has "$R" "Slot use: tacplus peak 1 of 1 (mean use 0.67, 3 plans)."
has "$R" "Hours ready issues waited: tacplus 18.92 h (conflict 7.2, no_free_slot 7.2, limit_outlasts_job 2.42, scan_holds_repo 1.6, behind_a_land 0.5)."
has "$R" "Image: ghcr.io/tacplus-dev/looper:main is 2 commits behind main (aaaaaaaaaaaa against cccccccccccc); the latest image run: [cancelled](https://github.com/tacplus-dev/looper/actions/runs/777)."
has "$R" "Longest lands: [tacplus #12 full](https://gitlab.com/tacplus-dev/looper/-/jobs/1200) 150 min."
has "$R" "Not read: gitlab:tacplus-dev/cluster"
has "$R" "- \`failures/tacplus-dev/looper/image_pull\`: gitlab.com/tacplus-dev/looper: 6 jobs failed with image_pull, 6 recovered on retry (2 of 7 nights, over its threshold tonight, 0.3 h of waiting). Advice: [Fresh VM image](../2026-11-02-fresh-vm-image.md)"
has "$R" "- \`held/tacplus/limit_outlasts_job\`: "; has "$R" "Advice: covered by tacplus-dev/looper#33: the job sizing"
has "$R" "- \`scan/tacplus\`: tacplus: its nightly scan held the repository 125 min (threshold 60 min) (1 of 7 nights, over its threshold tonight). No advice tonight."
# Ranked by the hours of waiting each would remove: the stale image's 9, the conflict's 7.2, ...
[[ "$(sed -n '/^## Recurring/,/^## Transient/p' <<<"$R" | grep -o '^- `[^`]*`' | head -3 | paste -sd' ' -)" == '- `image/tacplus-dev/looper` - `held/tacplus/conflict` - `held/tacplus/no_free_slot`' ]] ||
  fail "the advice's order: $(sed -n '/^## Recurring/,/^## Transient/p' <<<"$R")"
lacks "$R" "not/a/key"; lacks "$R" nonsense
has "$(sed -n '/^## Transient/,/^## Once/p' <<<"$R")" "- \`failures/tacplus-dev/looper/timeout\`: gitlab.com/tacplus-dev/looper: 1 job failed with timeout, 1 recovered on retry (once in 7 nights, recovered on retry)."
has "$(sed -n '/^## Once/,$p' <<<"$R")" "- \`failures/tacplus-dev/build/gate_failure\`:"
(( $(wc -l < "$TMP/r.md") <= 60 )) || fail "not one screen: $(wc -l < "$TMP/r.md") lines"
pass

NAME=collect-without-credentials
env -u GITLAB_TOKEN LOOPER_BUILD_API=https://gitlab.test/api/v4 PATH="$TMP/bin:$PATH" LOOPER_RECAP_CLOUDBUILD_PROJECT= \
  "$ROOT/looper-recap" collect --until "$UNTIL" > "$TMP/none.json" 2>/dev/null || fail "collect without a token failed"
[[ "$(jq -r '.sources["gitlab:tacplus-dev/looper"]' "$TMP/none.json")" == "unavailable: no GITLAB_TOKEN" ]] || fail "$(jq .sources "$TMP/none.json")"
[[ "$(jq -r '.sources["cloud-build"]' "$TMP/none.json")" == "not configured" ]] || fail "$(jq .sources "$TMP/none.json")"
pass

echo "looper-recap: all scenarios pass"
