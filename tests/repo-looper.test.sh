#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# repo-looper's outcome handling: what it does to an issue after the run ends.
# A stub `gh` keeps issues as JSON files, a stub `claude` runs the scenario's
# script in the checkout, and origin is a local bare repository.
# Run: tests/repo-looper.test.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

# Issues: $FIX/issues/<repo>-<n>.json ({number,state,labels:[{name}],body,createdAt}).
# Comments are appended to $FIX/comments as "<repo>#<n> <body>".
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cmd="$1 $2"; shift 2
case "$cmd" in
  "auth setup-git") exit 0 ;;
  "repo clone") git clone -q "$FIX/origin.git" "$2"; exit 0 ;;
esac
n=""; repo=""; q="."; add=(); rm=(); body=""; has_body=""; label=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) repo="${2##*/}"; shift 2 ;;
    --jq) q="$2"; shift 2 ;;
    --add-label) add+=("$2"); shift 2 ;;
    --remove-label) rm+=("$2"); shift 2 ;;
    --body) body="$2"; has_body=1; shift 2 ;;
    --label) label="$2"; shift 2 ;;
    --json|--state|--limit) shift 2 ;;
    *) n="$1"; shift ;;
  esac
done
f="$FIX/issues/$repo-$n.json"
case "$cmd" in
  "issue list")
    jq -s --arg l "$label" '[.[] | select(.state == "OPEN" and any(.labels[].name; . == $l))]' \
      "$FIX/issues/$repo"-*.json | jq -r "$q" ;;
  "issue view") [[ -f "$f" ]] || { echo "stub gh: no issue $repo#$n" >&2; exit 1; }; jq -r "$q" "$f" ;;
  "issue edit")
    t="$(cat "$f")"
    for l in "${add[@]+"${add[@]}"}"; do t="$(jq --arg l "$l" '.labels |= (. + [{name: $l}] | unique)' <<<"$t")"; done
    for l in "${rm[@]+"${rm[@]}"}"; do t="$(jq --arg l "$l" '.labels |= map(select(.name != $l))' <<<"$t")"; done
    [[ -n "$has_body" ]] && t="$(jq --arg b "$body" '.body = $b' <<<"$t")"
    printf '%s\n' "$t" > "$f" ;;
  "issue comment") printf '%s#%s %s\n' "$repo" "$n" "$body" >> "$FIX/comments" ;;
  *) echo "stub gh: unexpected $cmd" >&2; exit 3 ;;
esac
EOF
# The prompt names the run's outcome file; the scenario's script gets it as $OUTCOME.
cat > "$TMP/bin/claude" <<'EOF'
#!/usr/bin/env bash
prompt="$(cat)"
OUTCOME="$(grep -oE '/[^ `]*/outcome' <<<"$prompt" | head -1)" bash "$FIX/claude.sh"
EOF
chmod +x "$TMP/bin/gh" "$TMP/bin/claude"

issue() { # repo n state labels(csv) body
  jq -n --argjson n "$2" --arg s "$3" --arg l "$4" --arg b "$5" \
    '{number: $n, state: $s, labels: ($l | split(",") | map(select(. != "")) | map({name: .})), body: $b, createdAt: "2026-10-27T00:00:00Z"}' \
    > "$FIX/issues/$1-$2.json"
}
scenario() { # name: a fresh origin with one commit and an approved issue alpha#4
  NAME="$1"; FIX="$TMP/$1"; mkdir -p "$FIX/issues"; : > "$FIX/comments"; : > "$FIX/claude.sh"
  git init -q --bare -b main "$FIX/origin.git"
  git clone -q "$FIX/origin.git" "$FIX/seed" 2>/dev/null
  git -C "$FIX/seed" commit -q --allow-empty -m init && git -C "$FIX/seed" push -q origin main
  issue alpha 4 OPEN approved "Fix it."
}
push_fix() { # a claude.sh line: commit and push a fix
  echo 'git commit -q --allow-empty -m fix && git push -q origin main' >> "$FIX/claude.sh"
}
run() {
  OUT="$(PATH="$TMP/bin:$PATH" FIX="$FIX" LOOPER_LIB="$ROOT/looper-lib.sh" LOOPER_WORK="$FIX/work" \
         LOOPER_RUNS="$FIX/project/looper-runs" CI_PROJECT_DIR="$FIX/project" CI_JOB_URL=https://gl.test/jobs/77 \
         "$ROOT/repo-looper" --repo alpha --issue 4 2>&1)" || { echo "$OUT"; fail "repo-looper exited non-zero"; }
}
fail() { echo "FAIL $NAME: $*" >&2; cat "$FIX/comments" >&2; exit 1; }
labels() { jq -r '[.labels[].name] | join(",")' "$FIX/issues/$1-$2.json"; }
body() { jq -r .body "$FIX/issues/$1-$2.json"; }
has() { grep -qF -- "$2" <<<"$1" || fail "expected \"$2\" in: $1"; }
lacks() { ! grep -qF -- "$2" <<<"$1" || fail "unexpected \"$2\" in: $1"; }
pass() { echo "ok $NAME"; }

scenario pushed-gates-blocked
push_fix; echo 'echo "Blocked-by: tacplus-dev/tacplus#9" > "$OUTCOME"' >> "$FIX/claude.sh"
issue tacplus 9 OPEN "" "A compiler floor."
run
[[ "$(labels alpha 4)" == approved ]] || fail "labels $(labels alpha 4)"
has "$(body alpha 4)" "Blocked-by: tacplus-dev/tacplus#9"
has "$(body alpha 4)" "Fix it."
has "$(cat "$FIX/comments")" "https://gl.test/jobs/77"
lacks "$(cat "$FIX/comments")" "looper host"
pass

scenario pushed-gates-blocked-same-repo
push_fix; echo 'echo "Blocked-by: #3" > "$OUTCOME"' >> "$FIX/claude.sh"
issue alpha 3 OPEN "" "First."
run
[[ "$(labels alpha 4)" == approved ]] || fail "labels $(labels alpha 4)"
has "$(body alpha 4)" "Blocked-by: #3"
pass

scenario keeps-other-blockers
push_fix; echo 'echo "Blocked-by: #3" > "$OUTCOME"' >> "$FIX/claude.sh"
issue alpha 3 OPEN "" "First."
issue alpha 4 OPEN approved "Fix it.
Blocked-by: tacplus-dev/beta#1"
issue beta 1 CLOSED "" "Done."
run
[[ "$(labels alpha 4)" == approved ]] || fail "labels $(labels alpha 4)"
has "$(body alpha 4)" "Blocked-by: tacplus-dev/beta#1"
[[ "$(grep -c 'Blocked-by: #3' <<<"$(body alpha 4)")" == 1 ]] || fail "body $(body alpha 4)"
pass

scenario blocked-but-nothing-pushed
echo 'echo "Blocked-by: tacplus-dev/tacplus#9" > "$OUTCOME"' >> "$FIX/claude.sh"
issue tacplus 9 OPEN "" "A compiler floor."
run
[[ "$(labels alpha 4)" == "approved,looper:stuck" ]] || fail "labels $(labels alpha 4)"
lacks "$(body alpha 4)" "Blocked-by"
pass

scenario blocked-by-closed-issue
push_fix; echo 'echo "Blocked-by: tacplus-dev/tacplus#9" > "$OUTCOME"' >> "$FIX/claude.sh"
issue tacplus 9 CLOSED "" "A compiler floor."
run
[[ "$(labels alpha 4)" == "approved,looper:stuck" ]] || fail "labels $(labels alpha 4)"
lacks "$(body alpha 4)" "Blocked-by"
pass

scenario ended-unknown
push_fix
run
[[ "$(labels alpha 4)" == "approved,looper:stuck" ]] || fail "labels $(labels alpha 4)"
c="$(cat "$FIX/comments")"
has "$c" "https://gl.test/jobs/77"
has "$c" "looper-runs/"
lacks "$c" "looper host"
ls "$FIX"/project/looper-runs/*-issue-4/prompt.md "$FIX"/project/looper-runs/*-issue-4/claude.log >/dev/null \
  || fail "no run record under LOOPER_RUNS"
pass

scenario closed
push_fix; echo 'gh issue edit 4 --repo tacplus-dev/alpha --add-label closed-by-test' >> "$FIX/claude.sh"
echo 'jq ".state = \"CLOSED\"" "$FIX/issues/alpha-4.json" > "$FIX/x" && mv "$FIX/x" "$FIX/issues/alpha-4.json"' >> "$FIX/claude.sh"
run
[[ "$(labels alpha 4)" == "approved,closed-by-test" ]] || fail "labels $(labels alpha 4)"
[[ ! -s "$FIX/comments" ]] || fail "unexpected comment"
pass

echo "repo-looper: all scenarios pass"
