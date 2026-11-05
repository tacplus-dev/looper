#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# looper-recap (looper#57) against recorded API fixtures (tests/recap/: GitLab's
# jobs and job logs, gh's repositories and workflow runs, and the recaps of
# earlier nights) through stub curl, gh and gcloud: collect gives
# a byte-identical recap.json (tests/recap/expected.json) whatever the clock,
# zone and locale, and finds the seed cases of 2026-11-02 by itself (fresh-VM
# image-pull failures, an issue held hours by "would outlast this job" with one
# tacplus child at a time, a 2-hour scan of tacplus, a 150-minute full-gate
# land); classify puts a once-only, recovered failure in the transient list, a
# 3-night recurrence and a threshold crossed under advice, and ignores a night
# older than 7; report writes the recap file with links to the night's advice.
# tacplus-dev/build's jobs are read with GITLAB_TOKEN, or with its own token
# read from Secret Manager by version when LOOPER_RECAP_BUILD_TOKEN_SECRET is
# set (looper#85; tacplus-dev/cloud#12); Cloud Build is not read.
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
# (never on the command line): tacplus-dev/build's own (glpat-build, the one
# the looper project's bot has 404s there), every other project's glpat-recap;
# every call logged.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
url="${*: -1}"; echo "curl $*" >> "$TMP/calls"
[[ "$*" != *glpat-* ]] || { echo "the token is on the command line" >&2; exit 9; }
p="${url#https://gitlab.test/api/v4/projects/}"; proj="${p%%/*}"; proj="${proj//%2F/_}"; rest="${p#*/}"
tok=glpat-recap; [[ "$proj" != tacplus-dev_build ]] || tok=glpat-build
[[ "$*" == *"-H @-"* && "$(cat)" == "PRIVATE-TOKEN: $tok" ]] || exit 22
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
              repos/tacplus-dev/*/commits) r="${4#repos/tacplus-dev/}"; r="${r%/commits}"
                 [[ "$*" == *"-f sha=main -f since=2026-11-01T03:00:00Z -f until=2026-11-02T03:00:00Z"* ]] || exit 1
                 cat "$FX/gh/main-$r.json" ;;
              *) r="${4#repos/tacplus-dev/}"; r="${r%/actions/runs}"
                 [[ "$*" == *"-f created=2026-11-01T03:00:00Z..2026-11-02T03:00:00Z"* ]] || exit 1
                 cat "$FX/gh/runs-$r.json" ;;
            esac ;;
  "api repos/tacplus-dev/looper/commits/main") cat "$FX/gh/commit-main.json" ;;
  "api repos/tacplus-dev/"*/commits/*/status) r="${2#repos/tacplus-dev/}"; sha="${r#*/commits/}"; sha="${sha%/status}"; r="${r%%/*}"
                                             [[ -f "$FX/gh/status-$r-$sha.json" ]] || exit 1; cat "$FX/gh/status-$r-$sha.json" ;;
  "api repos/tacplus-dev/looper/compare/aaaaaaaaaaaa1111111111111111111111111111...cccccccccccc3333333333333333333333333333") cat "$FX/gh/compare.json" ;;
  *) echo "stub gh: unexpected $*" >&2; exit 3 ;;
esac
EOF
# gcloud: Secret Manager only, the build token's version 3.
cat > "$TMP/bin/gcloud" <<'EOF'
#!/usr/bin/env bash
echo "gcloud $*" >> "$TMP/calls"
[[ "$*" == "secrets versions access 3 --secret=recap-build-token --project=p1" ]] || exit 1
echo glpat-build
EOF
cat > "$TMP/bin/docker" <<'EOF'
#!/usr/bin/env bash
echo "docker $*" >> "$TMP/calls"
[[ "$*" == "buildx imagetools inspect ghcr.io/tacplus-dev/looper:main --format {{json .Image}}" ]] || exit 1
cat "$FX/docker/inspect.json"
EOF
chmod +x "$TMP/bin/"*
export PATH="$TMP/bin:$PATH" TMP FX
ENVS=(GITLAB_TOKEN=glpat-recap LOOPER_BUILD_API=https://gitlab.test/api/v4 LOOPER_ORG=tacplus-dev
      LOOPER_RECAP_BUILD_TOKEN_SECRET=projects/p1/secrets/recap-build-token/versions/3)
recap() { env -u LOOPER_RECAP_PROJECTS -u LOOPER_RECAP_BUILD_PROJECT -u LOOPER_SUGGEST_PROJECTS -u LOOPER_RECAP_ACTIONS_REPOS "${ENVS[@]}" "$ROOT/looper-recap" "$@"; }
UNTIL=2026-11-02T03:00:00Z

NAME=collect-byte-identical
recap collect --until "$UNTIL" --out "$TMP/recap.json" 2> "$TMP/err" || fail "collect: $(cat "$TMP/err")"
if [[ -n "${REGEN:-}" ]]; then cp "$TMP/recap.json" "$FX/expected.json"; fi
cmp -s "$TMP/recap.json" "$FX/expected.json" || { diff -u "$FX/expected.json" "$TMP/recap.json" | head -40 >&2; fail "recap.json is not tests/recap/expected.json"; }
# The same inputs give the same file: another zone, locale and hour of the run.
TZ=America/Chicago LC_ALL=C recap collect --until "2026-11-01T22:00:00-05:00" > "$TMP/again.json" 2>/dev/null || fail "collect again"
cmp -s "$TMP/again.json" "$FX/expected.json" || fail "a second collect differs: $(diff "$FX/expected.json" "$TMP/again.json" | head -5)"
lacks "$(cat "$TMP/calls")" glpat-
# No Cloud Build call: Secret Manager is gcloud's only use.
[[ "$(grep '^gcloud' "$TMP/calls" | sort -u)" == "gcloud secrets versions access 3 --secret=recap-build-token --project=p1" ]] ||
  fail "gcloud: $(grep '^gcloud' "$TMP/calls")"
pass

NAME=collect-finds-the-seed-cases
J="$TMP/recap.json"
q() { jq -r "$1" "$J"; }
[[ "$(q .window.from) $(q .window.until) $(q .night)" == "2026-11-01T03:00:00Z 2026-11-02T03:00:00Z 2026-11-02" ]] || fail "window: $(q .window)"
# LOOPER_SUGGEST_PROJECTS' default plus tacplus-dev/cluster, which cannot be read: named, not guessed.
[[ "$(q '.sources | to_entries | map("\(.key)=\(.value)") | join(" ")')" == "github-actions=ok github-main=ok gitlab:tacplus-dev/build=ok gitlab:tacplus-dev/cluster=unavailable: GET projects/tacplus-dev%2Fcluster/jobs: curl exit 22 gitlab:tacplus-dev/looper=ok image=ok" ]] ||
  fail "sources: $(q .sources)"
[[ "$(q '.projects["tacplus-dev/looper"] | "\(.jobs) \(.status.failed) \(.failures.image_pull) \(.failures.runner_system_failure) \(.failures.timeout)"')" == "23 8 6 1 1" ]] ||
  fail "looper's jobs: $(q '.projects["tacplus-dev/looper"]')"
# tacplus-dev/build's jobs, read with its own token: counted, with their failures, queue and run times.
[[ "$(q '.projects["tacplus-dev/build"] | "\(.jobs) \(.status.failed) \(.failures.gate_failure) \(.queue_s.n) \(.run_s.n)"')" == "2 1 1 2 2" ]] ||
  fail "build: $(q '.projects["tacplus-dev/build"]')"
has "$(q '.items[].key')" "failures/tacplus-dev/build/gate_failure"
lacks "$(q 'keys | join(" ")')" cloud
# Queue (created to started) and prepare (started to Running on): looper-tacplus-16 queued 97 minutes
# behind the scan, looper-kernel-4 50 minutes, looper-tacplus-12 20 minutes, prepared in 2.
[[ "$(q '[.longest.queues[0:3][] | "\(.job) \(.minutes)"] | join(", ")')" == "looper-tacplus-16 97, looper-kernel-4 50, looper-tacplus-12 20" ]] || fail "longest queue: $(q .longest.queues)"
[[ "$(q '.projects["tacplus-dev/looper"].queue_s | "\(.max) \(.p90)"')" == "5820 1200" ]] || fail "queue: $(q '.projects["tacplus-dev/looper"].queue_s')"
has "$(q '.items[] | select(.key == "queue/tacplus-dev/looper") | .summary')" "queue time p90 20 min over 22 jobs (p50 1, max 97; threshold 15 min)"
[[ "$(q '[.failed_jobs[] | select(.class == "image_pull") | select(.before_ready and .recovered)] | length')" == 6 ]] || fail "image pulls: $(q .failed_jobs)"
[[ "$(q '.items[] | select(.key == "failures/tacplus-dev/looper/image_pull") | "\(.count) \(.over) \(.recovered)"')" == "6 true true" ]] || fail "$(q .items)"
# tacplus: one child at a time; #14 held 7.2 h for want of a slot, then 2.42 h by its limit.
[[ "$(q '.loopers.tacplus.slots | "\(.plans) \(.capacity) \(.peak) \(.mean_use)"')" == "3 1 1 0.67" ]] || fail "slots: $(q .loopers.tacplus.slots)"
[[ "$(q '.loopers.tacplus.holds.no_free_slot | "\(.count) \(.issues) \(.max_hours)"')" == "1 [14] 7.2" ]] || fail "holds: $(q .loopers.tacplus.holds)"
[[ "$(q '.loopers.tacplus.holds.limit_outlasts_job.max_hours')" == 2.42 ]] || fail "holds: $(q .loopers.tacplus.holds)"
has "$(q '.items[].key')" "held/tacplus/limit_outlasts_job"
has "$(q '.items[] | select(.key == "held/tacplus/limit_outlasts_job") | .summary')" "tacplus: issues held back by limit_outlasts_job 1 time (#14), up to 2.42 h"
# The hours each ready issue waited, and why (Jody, on looper#57): #15 by a conflict (and what overlaps),
# #12's land behind the others; each reason says what would let it run in parallel. #16 queued 97 minutes
# while the scan of tacplus ran, but in its own resource group (looper-tacplus-16, the scan's looper-tacplus):
# the scan held nothing, its queue was a VM's (looper#92).
[[ "$(q '.loopers.tacplus.waits | "\(.hours) \(.by_issue["14"].hours) \(.by_issue["15"].why.conflict) \(.by_issue["16"]) \(.by_issue["12"].why.behind_a_land)"')" == "17.32 9.62 7.2 null 0.5" ]] ||
  fail "waits: $(q .loopers.tacplus.waits)"
[[ "$(q '.loopers.tacplus.holds.conflict.overlaps[0] | "\(.issues) \(.what)"')" == "[15] both edit src/codec.rs and its tests" ]] || fail "overlaps: $(q .loopers.tacplus.holds.conflict)"
has "$(q '.items[] | select(.key == "held/tacplus/conflict") | "\(.wait_hours) \(.summary) \(.parallel)"')" "7.2 tacplus: issues held back by conflict 1 time (#15), up to 7.2 h, 7.2 h in all; overlapping: both edit src/codec.rs and its tests file-level conflicts instead of areas"
lacks "$(q '.items[].key')" "scan_holds_repo"
lacks "$(q '.loopers.tacplus.holds | keys[]')" "scan_holds_repo"
# The image against main's head (looper#58): 2 commits behind, the latest image run cancelled.
[[ "$(q '.image | "\(.current) \(.revision[0:12]) \(.main[0:12]) \([.missing[].sha] | join(",")) \(.latest_run.conclusion)"')" == "false aaaaaaaaaaaa cccccccccccc bbbbbbbbbbbb,cccccccccccc cancelled" ]] || fail "image: $(q .image)"
has "$(q '.items[] | select(.key == "image/tacplus-dev/looper") | "\(.over) \(.wait_hours) \(.summary)"')" "true 9 ghcr.io/tacplus-dev/looper:main is at aaaaaaaaaaaa, main at cccccccccccc: 2 commits of main not in it, the oldest 9 h old; the latest image run: cancelled at cccccccccccc"
# A 150-minute full-gate land, and a 125-minute scan holding tacplus.
[[ "$(q '.loopers.tacplus.lands.full | "\(.count) \(.minutes.max)"')" == "1 150" ]] || fail "lands: $(q .loopers.tacplus.lands)"
has "$(q '.items[] | select(.key == "land/tacplus/full") | .summary')" "tacplus: 1 land on the gates full, up to 150 min"
[[ "$(q '.loopers.tacplus.scan_minutes | join(",")')" == 125 ]] || fail "scan: $(q .loopers.tacplus)"
has "$(q '.items[].key')" "scan/tacplus"
# Runner pools: the VMs, the jobs that failed before one was ready, the disk at a job's end.
[[ "$(q '.runner_pools["tacplus-dev arm64 autoscaler"] | "\(.vms) \(.failed_before_ready) \(.disk_pct.max)"')" == "14 6 45" ]] || fail "pool: $(q .runner_pools)"
[[ "$(q '.runner_pools["tacplus-dev arm64 autoscale-16"].disk_pct.max')" == 72 ]] || fail "pool: $(q .runner_pools)"
# GitHub Actions (nightly, release, images only).
[[ "$(q '.actions.by_workflow | keys | join(",")')" == tacplus/nightly ]] || fail "actions: $(q .actions)"
[[ "$(q '.items[] | select(.key == "actions/tacplus/nightly") | "\(.count) \(.recovered)"')" == "1 true" ]] || fail "$(q .items)"
# A job outside the window is left out.
lacks "$(q '.failed_jobs[].id')" 900
pass

# The managers, the caps and the capacity (looper#72), from the managers' logs (looper#70), the
# kicker's capacity lines and GitHub: tacplus's manager merged #20, #22 (its Cargo.lock conflict
# regenerated) and #21 (sent back once: redone), red gates on #23, #24 left for the next manager;
# main red after #22's merge, and reverted.
NAME=collect-managers-caps-capacity
[[ "$(q '.managers.tacplus | "\(.lands) \(.merged) \(.resolved) \(.sent_back) \(.red_gates) \(.deferred) \(.redone) \(.red_main)"')" == '5 3 1 1 1 1 [21] ["3333333"]' ]] ||
  fail "tacplus's manager: $(q .managers.tacplus)"
# Report to merge: queued to merged, 75, 240 and 80 minutes; the lands waited 155 minutes for it.
[[ "$(q '.managers.tacplus | "\(.report_to_merge_minutes.p50) \(.report_to_merge_minutes.p90) \(.waited_hours)"')" == "80 240 2.58" ]] || fail "merge time: $(q .managers.tacplus)"
[[ "$(q '[.managers.tacplus.merges[] | "#\(.issue) \(.after) \(.set) \(.status)"] | join(", ")')" == "#20 2222222 docs success, #22 3333333 full failure, #21 4444444 full success" ]] ||
  fail "merges: $(q .managers.tacplus.merges)"
# A revert is a commit that says so; a message only mentioning one is not.
[[ "$(q '[.managers.tacplus.reverts[].sha] | join(",")')" == 555555555555 ]] || fail "reverts: $(q .managers.tacplus.reverts)"
# No build status on alpha's merge: none, not red.
[[ "$(q '.managers.alpha | "\(.merged) \(.merges[0].status) \(.red_main) \(.reverts)"')" == "1 none [] []" ]] || fail "alpha's manager: $(q .managers.alpha)"
for k in manager/tacplus/red-main manager/tacplus/reverts manager/tacplus/merge-time; do
  [[ "$(q ".items[] | select(.key == \"$k\") | .over")" == true ]] || fail "$k: $(q .items)"
done
has "$(q '.items[] | select(.key == "manager/tacplus/sent-back") | "\(.over) \(.recovered) \(.summary)"')" "false true tacplus: the manager sent 1 branch back on a conflict, resolved 1 by regenerating; redone: #21"
lacks "$(q '.items[].key')" "manager/alpha"
# The caps, from the kicker's 39 passes: tacplus at its cap of 6 in 25, its 6 reports running in 20 of
# them (#25 waited 1 h, #26 1 h), 4 of them pending in 5 (#26 0.25 h more: the pool's, not the cap's,
# looper#92), a backlog of 2 at most: raise it; kernel's manager 3 lands behind: lower it; alpha neither.
# A line without running= (the kicker's before looper#92) counts its reports as running.
[[ "$(q '.caps.tacplus | "\(.cap) \(.passes) \(.all_busy) \(.all_busy_hours) \(.all_running) \(.all_running_hours) \(.waiting_hours) \(.waiting["25"]) \(.waiting["26"]) \(.queued_hours) \(.queued["26"]) \(.pool) \(.backlog.p90)"')" == "6 39 0.64 1.25 0.51 1 2 1 1 0.25 0.25 tacplus-dev arm64 autoscale-16 2" ]] ||
  fail "tacplus's cap: $(q .caps.tacplus)"
has "$(q '.items[] | select(.key == "cap/tacplus/raise") | "\(.running) \(.wait_hours) \(.summary)"')" "2 2 tacplus: raise its cap of 6 in caps.yaml: ready issues waited 2 h at it with all its reports running (#25 1 h, #26 1 h), 0.25 h more with some of them queued for a VM; all its reports busy in 64% of the kicker's 39 passes (1.25 h), running in 51% (1 h); merge backlog p90 2, max 2 lands"
has "$(q '.items[] | select(.key == "cap/kernel/lower") | .summary')" "kernel: lower its cap of 3 in caps.yaml, its manager behind: all its reports busy in 0% of the kicker's 39 passes (0 h), running in 0% (0 h); merge backlog p90 3, max 3 lands (threshold 3)"
lacks "$(q '.items[].key')" "cap/alpha"
# Capacity: the queue p90 of every job, the issues whose report waited for a VM (tacplus#16 97
# minutes, the scan holding nothing; kernel#4 50), one more VM a day.
[[ "$(q '.capacity | "\(.queue_minutes.p90) \(.waiting_for_vm.issues) \(.waiting_for_vm.hours) \(.one_more_vm.machine) \(.one_more_vm.usd_day)"')" == "20 3 2.78 t2a-standard-8 7.39" ]] ||
  fail "capacity: $(q .capacity)"
has "$(q '.items[] | select(.key == "capacity/vm") | "\(.over) \(.summary)"')" "true 3 issues waited 2.78 h for a VM (tacplus#16 97 min, kernel#4 50 min, tacplus#12 20 min); queue p90 20 min; one more t2a-standard-8 is about \$7.39 a day"
[[ "$(q '[.capacity.waiting_for_vm.jobs[] | "\(.repo)#\(.issue) \(.pool)"] | join(", ")')" == "tacplus#16 tacplus-dev arm64 autoscale-16, kernel#4 tacplus-dev arm64 autoscaler, tacplus#12 tacplus-dev arm64 autoscale-16" ]] ||
  fail "the VM waits' pools: $(q .capacity.waiting_for_vm)"
# Under its threshold (0.25 h), the pool's wait at tacplus's cap is no item.
lacks "$(q '.items[].key')" "capacity/tacplus-dev"
[[ "$(LOOPER_RECAP_VM_USD_HOUR=1.5 LOOPER_RECAP_VM_MACHINE=t2a-standard-16 recap collect --until "$UNTIL" 2>/dev/null | jq -r '.capacity.one_more_vm | "\(.machine) \(.usd_day)"')" == "t2a-standard-16 36" ]] ||
  fail "the VM's price"
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
# The send-back its report redid too.
[[ "$(c '.transient | map(.key) | join(" ")')" == "actions/tacplus/nightly failures/tacplus-dev/looper/timeout manager/tacplus/sent-back" ]] || fail "transient: $(c .transient)"
# Seen once, not recovered: noted, no advice.
[[ "$(c '.once | map(.key) | join(" ")')" == "cap/kernel/lower failures/tacplus-dev/build/gate_failure" ]] || fail "once: $(c .once)"
lacks "$(c '.recurring[].key')" "timeout"
# A cap is advised after two nights running over its threshold (looper#72): tacplus's, over last
# night too; not kernel's, over tonight and the night before last only.
[[ "$(c '.recurring[] | select(.key == "cap/tacplus/raise") | "\(.running) \(.needs)"')" == "2 2" ]] || fail "$(c .recurring)"
[[ "$(c '.once[] | select(.key == "cap/kernel/lower") | "\(.running) \(.needs) \(.nights)"')" == "1 2 2" ]] || fail "$(c .once)"
for k in manager/tacplus/red-main manager/tacplus/reverts manager/tacplus/merge-time capacity/vm; do has "$(c '.recurring[].key')" "$k"; done
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
has "$R" "| tacplus-dev/looper | 23 | 8 |"
has "$R" "Failures by class: image_pull 6, gate_failure 1,"
has "$R" "Slot use: tacplus peak 1 of 1 (mean use 0.67, 3 plans)."
has "$R" "Hours ready issues waited: tacplus 17.32 h (conflict 7.2, no_free_slot 7.2, limit_outlasts_job 2.42, behind_a_land 0.5)."
has "$R" "Image: ghcr.io/tacplus-dev/looper:main is 2 commits behind main (aaaaaaaaaaaa against cccccccccccc); the latest image run: [cancelled](https://github.com/tacplus-dev/looper/actions/runs/777)."
has "$R" "Longest lands: [tacplus #12 full](https://gitlab.com/tacplus-dev/looper/-/jobs/1200) 150 min."
has "$R" "Not read: gitlab:tacplus-dev/cluster"
# The managers' scores, the caps and the capacity numbers (looper#72).
has "$R" "Managers: alpha 1 merged (report to merge p50 7, p90 7 min), conflicts resolved 0 against 0 sent back, red gates 0, main red after 0, reverts 0, redone 0; tacplus 3 merged (report to merge p50 80, p90 240 min), conflicts resolved 1 against 1 sent back, red gates 1, main red after 1 (3333333), reverts 1, redone 1 (#21), 1 left for the next."
has "$R" "Caps: alpha cap 3: waited at it 0 h, all busy 0% (running 0%) of 39 passes, merge backlog p90 0; kernel cap 3: waited at it 0 h, all busy 0% (running 0%) of 39 passes, merge backlog p90 3; tacplus cap 6: waited at it 2 h (#25, #26), 0.25 h more queued for a VM of tacplus-dev arm64 autoscale-16 (#26), all busy 64% (running 51%) of 39 passes, merge backlog p90 2."
has "$R" "Capacity: queue p90 20 min over 24 jobs; 3 issues waited 2.78 h for a VM ([tacplus#16](https://gitlab.com/tacplus-dev/looper/-/jobs/1310) 97 min, [kernel#4](https://gitlab.com/tacplus-dev/looper/-/jobs/1702) 50 min, [tacplus#12](https://gitlab.com/tacplus-dev/looper/-/jobs/1200) 20 min); one more t2a-standard-8 is about \$7.39 a day (\$0.308 an hour)."
has "$R" "- \`cap/tacplus/raise\`: tacplus: raise its cap of 6 in caps.yaml: "; has "$R" "(2 nights running, over its threshold tonight, 2 h of waiting). No advice tonight."
has "$(sed -n '/^## Once/,$p' <<<"$R")" "- \`cap/kernel/lower\`: kernel: lower its cap of 3 in caps.yaml, its manager behind: "
has "$(sed -n '/^## Once/,$p' <<<"$R")" "(1 night running; advice after 2)."
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

# A variant of the fixtures (looper#92): a copy of tests/recap/ that SED edits (sed -i's script on
# trace-<job>.txt) and JQ edits (on jobs-1.json), collected to $TMP/v.json.
variant() { # trace-id sed-script jq-filter
  rm -rf "$TMP/fx"; cp -r "$FX" "$TMP/fx"; local d="$TMP/fx/gitlab/tacplus-dev_looper"
  [[ -z "$2" ]] || sed -i -E "$2" "$d/trace-$1.txt"
  jq "${3:-.}" "$d/jobs-1.json" > "$TMP/jobs.json" && mv "$TMP/jobs.json" "$d/jobs-1.json"
  FX="$TMP/fx" recap collect --until "$UNTIL" > "$TMP/v.json" 2>/dev/null || fail "collect"
}
v() { jq -r "$1" "$TMP/v.json"; }

# A cap full of pending reports gives no raise (looper#92): tacplus's 6 at its cap, 1 of them running
# in every pass, #25 and #26 waited 2.25 h behind reports queued for its pool's VM. The advice is that
# pool's: its own VM wait beside it, and no cap item.
NAME=cap-full-of-pending-reports
variant 1500 's/tacplus reports=6 running=[0-9]+/tacplus reports=6 running=1/'
lacks "$(v '.items[].key')" "cap/tacplus"
[[ "$(v '.caps.tacplus | "\(.all_busy) \(.all_running) \(.waiting_hours) \(.queued_hours) \(.queued["25"]) \(.queued["26"])"')" == "0.64 0.0 0 2.25 1 1.25" ]] || fail "tacplus's cap: $(v .caps.tacplus)"
has "$(v '.items[] | select(.key == "capacity/tacplus-dev arm64 autoscale-16") | "\(.over) \(.wait_hours) \(.running) \(.summary)"')" "true 2.25 null tacplus-dev arm64 autoscale-16: ready issues waited 2.25 h at a full cap whose reports were queued for this pool's VMs, not running (tacplus at its cap of 6: #25 1 h, #26 1.25 h): the cap is not what limits them, and a raise would only queue more reports; its reports waited 1.95 h for a VM (tacplus#16 97 min, tacplus#12 20 min); one more t2a-standard-8 is about \$7.39 a day (threshold 1 h; the scale-up is Jody's call)"
pass

# A scan holds a queued report only when they share a resource group (looper#92): the plan's log names
# each job's; #16 in the scan's looper-tacplus waited 1.6 h for it, the rest of its queue for a VM.
NAME=scan-sharing-the-resource-group
variant 1600 "" '.'
printf '[2026-11-01T23:00:00Z] planned looper-tacplus-16 (5h, tags arm64, autoscale-16, resource_group looper-tacplus)\n' > "$TMP/fx/gitlab/tacplus-dev_looper/trace-1600.txt"
FX="$TMP/fx" recap collect --until "$UNTIL" > "$TMP/v.json" 2>/dev/null || fail "collect"
[[ "$(v '.loopers.tacplus.waits.by_issue["16"].why.scan_holds_repo')" == 1.6 ]] || fail "waits: $(v .loopers.tacplus.waits)"
has "$(v '.items[] | select(.key == "held/tacplus/scan_holds_repo") | .parallel')" "a scan in its own resource group"
lacks "$(v '.capacity.waiting_for_vm.jobs[] | "\(.repo)#\(.issue)"')" "tacplus#16"
pass

# A scan on another pool, in its own resource group, holds nothing (looper#91, looper#92): #16's queue
# is its pool's VM wait.
NAME=scan-on-another-pool
variant 1300 "" 'map(if .name == "looper-scan-tacplus" then .runner.description = "tacplus-dev arm64 autoscaler" else . end)'
lacks "$(v '.items[].key')" "scan_holds_repo"
[[ "$(v '.capacity.waiting_for_vm.jobs[] | select(.issue == 16) | "\(.minutes) \(.pool)"')" == "97 tacplus-dev arm64 autoscale-16" ]] || fail "VM waits: $(v .capacity.waiting_for_vm)"
pass

NAME=collect-without-credentials
env -u GITLAB_TOKEN -u LOOPER_RECAP_BUILD_TOKEN_SECRET LOOPER_BUILD_API=https://gitlab.test/api/v4 PATH="$TMP/bin:$PATH" \
  "$ROOT/looper-recap" collect --until "$UNTIL" > "$TMP/none.json" 2>/dev/null || fail "collect without a token failed"
[[ "$(jq -r '.sources["gitlab:tacplus-dev/looper"]' "$TMP/none.json")" == "unavailable: no GITLAB_TOKEN" ]] || fail "$(jq .sources "$TMP/none.json")"
lacks "$(jq -r '.sources | keys[]' "$TMP/none.json")" cloud
pass

# The build token: without its secret tacplus-dev/build is read with GITLAB_TOKEN (which its
# project refuses); a secret that cannot be read, or is not a version, is named, and
# tacplus-dev/build is not read with GITLAB_TOKEN instead.
NAME=collect-build-token
src() { jq -r --arg k "gitlab:$1" '.sources[$k]' "$TMP/b.json"; }
: > "$TMP/calls"
env -u LOOPER_RECAP_BUILD_TOKEN_SECRET "${ENVS[@]:0:3}" LOOPER_RECAP_PROJECTS="tacplus-dev/build tacplus-dev/looper" \
  "$ROOT/looper-recap" collect --until "$UNTIL" > "$TMP/b.json" 2>/dev/null || fail "collect"
[[ "$(src tacplus-dev/build)" == "unavailable: GET projects/tacplus-dev%2Fbuild/jobs: curl exit 22" && "$(src tacplus-dev/looper)" == ok ]] || fail "$(jq .sources "$TMP/b.json")"
lacks "$(cat "$TMP/calls")" gcloud
: > "$TMP/calls"
env "${ENVS[@]:0:3}" LOOPER_RECAP_BUILD_TOKEN_SECRET=projects/p1/secrets/recap-build-token/versions/4 LOOPER_RECAP_PROJECTS="tacplus-dev/build tacplus-dev/looper" \
  "$ROOT/looper-recap" collect --until "$UNTIL" > "$TMP/b.json" 2>/dev/null || fail "collect"
[[ "$(src tacplus-dev/build)" == "unavailable: the build token (projects/p1/secrets/recap-build-token/versions/4): gcloud exit 1" && "$(src tacplus-dev/looper)" == ok ]] ||
  fail "$(jq .sources "$TMP/b.json")"
lacks "$(cat "$TMP/calls")" tacplus-dev%2Fbuild
env "${ENVS[@]:0:3}" LOOPER_RECAP_BUILD_TOKEN_SECRET=recap-build-token LOOPER_RECAP_PROJECTS=tacplus-dev/build \
  "$ROOT/looper-recap" collect --until "$UNTIL" > "$TMP/b.json" 2>/dev/null || fail "collect"
[[ "$(src tacplus-dev/build)" == "unavailable: LOOPER_RECAP_BUILD_TOKEN_SECRET is not projects/<project>/secrets/<secret>/versions/<version>" ]] || fail "$(jq .sources "$TMP/b.json")"
pass

echo "looper-recap: all scenarios pass"
