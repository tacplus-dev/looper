# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# A fixture, not code that runs: the inline `looper-plan` script of
# gitlab.com/tacplus-dev/looper's .gitlab-ci.yml at GitLab commit c082b7bc
# (ci/tacplus-dev.gitlab-ci.yml at c0e7299), verbatim but for its YAML
# indentation. The pipeline now runs `looper-dispatch plan` instead
# (looper#56); tests/looper-dispatch.test.sh runs this beside it for a fixture
# org and diffs the two child pipelines, scheduled and kicked.
set -eux
out=looper-jobs.yml
cat > "$out" <<HEAD
variables:
  GIT_STRATEGY: none
  LOOPER_WORK: /builds/looper
  GIT_AUTHOR_NAME: jodydadescott
  GIT_AUTHOR_EMAIL: jody@thescottsweb.com
  GIT_COMMITTER_NAME: jodydadescott
  GIT_COMMITTER_EMAIL: jody@thescottsweb.com
HEAD
job() { # name, repo-looper args
  name="$1"; shift
  tv="LOOPER_JOB_TAGS_${repo//-/_}"; tags="${!tv:-arm64, autoscale}"
  cat >> "$out" <<JOB
$name:
  image: ghcr.io/tacplus-dev/looper:main
  tags: [$tags]
  retry:
    max: 2
    when: [runner_system_failure, scheduler_failure, unknown_failure]
  resource_group: looper-$repo
  timeout: $timeout
  variables:
    LOOPER_RUNS: \$CI_PROJECT_DIR/looper-runs
  script:
    - repo-looper $*
  artifacts:
    when: always
    expire_in: 30 days
    paths: [looper-runs/]
JOB
}
n=0; timeout=5h
if [ "$CI_PIPELINE_SOURCE" = schedule ]; then
  for repo in $(gh repo list "$LOOPER_ORG" --no-archived --limit 200 --json name --jq '.[].name'); do
    job "looper-scan-$repo" --repo "$repo" --scan; n=$((n+1))
  done
else
  for repo in $(gh search issues --owner "$LOOPER_ORG" --state open --label approved --limit 200 \
                  --json repository --jq '.[].repository.name' | sort -u); do
    issue="$(repo-looper --repo "$repo" --list)"; issue="${issue%%[!0-9]*}"
    [ -n "$issue" ] || continue
    timeout="$(repo-looper --repo "$repo" --job-timeout "$issue")" || timeout=5h
    case "$timeout" in [0-9]h|[0-9][0-9]h) ;; *) timeout=5h ;; esac
    job "looper-$repo-$issue" --repo "$repo" --issue "$issue"; n=$((n+1))
  done
fi
if [ "$n" = 0 ]; then
  printf 'looper-nothing-waiting:\n  image: alpine:3.20\n  tags: [arm64, autoscale]\n  script:\n    - echo "no issue is waiting on the looper"\n' >> "$out"
fi
echo "planned $n job(s)"; cat "$out"
