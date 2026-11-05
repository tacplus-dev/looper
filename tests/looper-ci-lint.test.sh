#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# looper-ci-lint (looper#94): the GitLab CI files of ci/ are valid as GitLab
# reads them, so none that would fail every pipeline of its project lands. On
# fixtures: a script line that YAML reads as a mapping (looper#83's probe),
# broken YAML, a misspelt job key and a header that is not spec: fail; a valid
# file with a spec: header and !reference passes. GitLab's lint API, a stub
# curl: called only with GITLAB_TOKEN and for a file whose project is known,
# the token on stdin; its errors fail the file, a refusal (403) leaves the
# offline verdict. Then every ci/*.gitlab-ci.yml here. No network.
# Run: tests/looper-ci-lint.test.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export TMP
fail() { echo "FAIL: $*" >&2; [[ -z "${OUT:-}" ]] || printf '%s\n' "$OUT" >&2; exit 1; }
has() { [[ "$1" == *"$2"* ]] || fail "expected \"$2\""; }
lint() { RC=0; OUT="$(env -u GITLAB_TOKEN PATH="$TMP/bin:$PATH" "$@" "$ROOT/looper-ci-lint" "${FILES[@]}" 2>&1)" || RC=$?; }

# GitLab's lint API: $TMP/answer is its body, $TMP/code its status; each call's
# argv to $TMP/calls, its stdin (the headers) to $TMP/stdin, its body to $TMP/body.
mkdir -p "$TMP/bin" "$TMP/ci"
cat > "$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
echo "curl $*" >> "$TMP/calls"; cat >> "$TMP/stdin"
for a in "$@"; do [[ "$a" != @/* ]] || cat "${a#@}" > "$TMP/body"; done
cat "$TMP/answer"; printf '\n%s' "$(cat "$TMP/code")"
EOF
chmod +x "$TMP/bin/curl"

cat > "$TMP/ci/good.gitlab-ci.yml" <<'EOF'
spec:
  inputs:
    issue: {type: string, default: ""}
---
stages: [plan]
.setup:
  before_script:
    - echo "setup: done"
plan:
  stage: plan
  image: alpine
  rules:
    - if: $CI_PIPELINE_SOURCE == "web"
  before_script:
    - !reference [.setup, before_script]
  script:
    - 'test -z "${X:-}" || { echo "X is set: unset it"; exit 1; }'
    - echo "$[[ inputs.issue ]]"
EOF
# looper#83's probe: an unquoted ": " makes the script line a mapping.
sed 's/^    - .test -z.*$/    - test -z "${X:-}" || { echo "X is set: unset it"; exit 1; }/' \
  "$TMP/ci/good.gitlab-ci.yml" > "$TMP/ci/mapping.gitlab-ci.yml"
grep -q '^    - test -z' "$TMP/ci/mapping.gitlab-ci.yml" || fail "the mapping fixture"
sed 's/^  script:/  scirpt:/' "$TMP/ci/good.gitlab-ci.yml" > "$TMP/ci/key.gitlab-ci.yml"
printf 'plan:\n  script: [echo\n' > "$TMP/ci/yaml.gitlab-ci.yml"
printf 'stages: [plan]\n---\nplan: {script: [echo]}\n' > "$TMP/ci/header.gitlab-ci.yml"

FILES=("$TMP/ci/good.gitlab-ci.yml"); lint
[[ $RC == 0 ]] || fail "a valid file with a spec: header and !reference fails"
has "$OUT" "good.gitlab-ci.yml: ok"

FILES=("$TMP/ci/mapping.gitlab-ci.yml"); lint
[[ $RC == 1 ]] || fail "a script line read as a mapping passes"
has "$OUT" "mapping.gitlab-ci.yml: invalid: plan:script:"

FILES=("$TMP/ci/key.gitlab-ci.yml"); lint
[[ $RC == 1 ]] || fail "a misspelt job key passes"
has "$OUT" "key.gitlab-ci.yml: invalid: plan:"; has "$OUT" "scirpt"

FILES=("$TMP/ci/yaml.gitlab-ci.yml"); lint
[[ $RC == 1 ]] || fail "broken YAML passes"
has "$OUT" "yaml.gitlab-ci.yml: invalid: not valid YAML"

FILES=("$TMP/ci/header.gitlab-ci.yml"); lint
[[ $RC == 1 ]] || fail "a first document that is not a spec: header passes"
has "$OUT" "is not a spec: header"

# Beyond the schema, as GitLab: an unknown template, stage or needed job.
sed 's/^plan:/plan:\n  extends: .absent/' "$TMP/ci/good.gitlab-ci.yml" > "$TMP/ci/extends.gitlab-ci.yml"
sed 's/^  stage: plan/  stage: run/' "$TMP/ci/good.gitlab-ci.yml" > "$TMP/ci/stage.gitlab-ci.yml"
sed 's/^  stage: plan/  stage: plan\n  needs: [build]/' "$TMP/ci/good.gitlab-ci.yml" > "$TMP/ci/needs.gitlab-ci.yml"
FILES=("$TMP/ci/extends.gitlab-ci.yml"); lint
[[ $RC == 1 ]] || fail "extends: of a template the file lacks passes"; has "$OUT" "plan: extends .absent, which the file does not define"
FILES=("$TMP/ci/stage.gitlab-ci.yml"); lint
[[ $RC == 1 ]] || fail "a stage not in stages: passes"; has "$OUT" "plan: its stage run is not in stages: .pre, plan, .post"
FILES=("$TMP/ci/needs.gitlab-ci.yml"); lint
[[ $RC == 1 ]] || fail "needs: of a job the file lacks passes"; has "$OUT" "plan: needs build, which is not a job of the file"
# A stage inherited through extends:, and the default stages without stages:.
printf '.t: {stage: deploy}\nj:\n  extends: .t\n  script: [echo]\nk:\n  needs: [j]\n  script: [echo]\n' > "$TMP/ci/inherit.gitlab-ci.yml"
FILES=("$TMP/ci/inherit.gitlab-ci.yml"); lint
[[ $RC == 0 ]] || fail "a stage through extends: or a default stage fails"

# One bad file among good ones: each file its line, the run fails.
FILES=("$TMP/ci/good.gitlab-ci.yml" "$TMP/ci/mapping.gitlab-ci.yml"); lint
[[ $RC == 1 ]] || fail "one invalid file of two passes"
has "$OUT" "good.gitlab-ci.yml: ok"; has "$OUT" "mapping.gitlab-ci.yml: invalid"

# --- GitLab's lint API -----------------------------------------------------------
cp "$TMP/ci/good.gitlab-ci.yml" "$TMP/ci/tacplus-dev.gitlab-ci.yml"
FILES=("$TMP/ci/tacplus-dev.gitlab-ci.yml")
echo '{"valid": true, "errors": [], "warnings": []}' > "$TMP/answer"; echo 200 > "$TMP/code"

lint
[[ $RC == 0 && ! -e "$TMP/calls" ]] || fail "the API called without GITLAB_TOKEN"

lint GITLAB_TOKEN=glpat-lint CI_API_V4_URL=https://gl.test/api/v4
[[ $RC == 0 ]] || fail "a file GitLab finds valid fails"
has "$OUT" "GitLab's lint API: valid (project 88136765)"
has "$(cat "$TMP/calls")" "-X POST"; has "$(cat "$TMP/calls")" "https://gl.test/api/v4/projects/88136765/ci/lint"
[[ "$(cat "$TMP/calls")" != *glpat-lint* ]] || fail "the token in curl's argv"
[[ "$(cat "$TMP/stdin")" == "PRIVATE-TOKEN: glpat-lint" ]] || fail "the token not on curl's stdin"
python3 -I -c 'import json,sys; assert json.load(open(sys.argv[1]))["content"] == open(sys.argv[2]).read()' \
  "$TMP/body" "$TMP/ci/tacplus-dev.gitlab-ci.yml" || fail "the body is not the file's content"

rm -f "$TMP/calls"
echo '{"valid": false, "errors": ["jobs:plan:script config should be a string or a nested array of strings up to 10 levels deep"]}' > "$TMP/answer"
lint GITLAB_TOKEN=glpat-lint
[[ $RC == 1 ]] || fail "a file GitLab finds invalid passes"
has "$OUT" "invalid: GitLab: jobs:plan:script config should be a string"

echo '{"message": "403 Forbidden"}' > "$TMP/answer"; echo 403 > "$TMP/code"
lint GITLAB_TOKEN=glpat-lint
[[ $RC == 0 ]] || fail "a refused API call fails a file valid offline"
has "$OUT" "not used (curl 0, HTTP 403): offline only"

# A file of another project: offline only.
rm -f "$TMP/calls"; FILES=("$TMP/ci/good.gitlab-ci.yml"); lint GITLAB_TOKEN=glpat-lint
[[ $RC == 0 && ! -e "$TMP/calls" ]] || fail "the API called for a file of no known project"

# An offline error is not sent to GitLab.
FILES=("$TMP/ci/mapping.gitlab-ci.yml"); lint GITLAB_TOKEN=glpat-lint
[[ $RC == 1 && ! -e "$TMP/calls" ]] || fail "an invalid file sent to the API"

# --- this repository's CI files --------------------------------------------------
FILES=(); lint
[[ $RC == 0 ]] || fail "a CI file of ci/ is invalid"
n="$(grep -c ': ok$' <<<"$OUT")"; m="$(ls "$ROOT"/ci/*.gitlab-ci.yml | wc -l)"
[[ "$n" == "$m" && "$m" -ge 4 ]] || fail "$n of $m CI files linted"

echo "looper-ci-lint: all scenarios pass"
