#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# looper-dispatch run: it starts the looper pipeline only for a repository with
# a ready issue and no looper job of its own created, pending, waiting for its
# resource_group or running (looper#16). A stub `gh` answers from issue JSON
# files, a stub `glab` from the scenario's jobs, filtered by the URL's scope[]
# parameters as GitLab does, and records the pipelines it starts.
# Run: tests/looper-dispatch.test.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# Issues: $FIX/issues/<repo>-<n>.json ({number,state,labels:[{name}],body,createdAt}).
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cmd="$1 $2"; shift 2
repo=""; n=""; q="."; label=""; rm=""; body=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) repo="${2##*/}"; shift 2 ;;
    --jq) q="$2"; shift 2 ;;
    --label) label="$2"; shift 2 ;;
    --remove-label) rm="$2"; shift 2 ;;
    --body) body="$2"; shift 2 ;;
    --owner|--state|--limit|--json) shift 2 ;;
    *) n="$1"; shift ;;
  esac
done
f="$FIX/issues/$repo-$n.json"
case "$cmd" in
  "search issues") jq -s --arg l "$label" 'map(select(.state == "OPEN" and any(.labels[]; .name == $l)) | . + {repository: {name: .repo}})' "$FIX"/issues/*.json | jq -r "$q" ;;
  "issue list") jq -s 'map(select(.state == "OPEN" and any(.labels[]; .name == "approved")))' "$FIX/issues/$repo"-*.json | jq -r "$q" ;;
  "issue view") jq -r "$q" "$f" ;;
  "issue edit") t="$(jq --arg l "$rm" '.labels |= map(select(.name != $l))' "$f")"; printf '%s\n' "$t" > "$f" ;;
  "issue comment") printf '%s#%s %s\n' "$repo" "$n" "$body" >> "$FIX/comments" ;;
  *) echo "stub gh: unexpected $cmd" >&2; exit 3 ;;
esac
EOF
cat > "$TMP/bin/glab" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$1 $2" in
  "ci run") echo "$*" >> "$FIX/started" ;;
  api\ *) jq --arg s "$(grep -oE 'scope\[\]=[a-z_]+' <<<"$2" | cut -d= -f2 | paste -sd, -)" \
            '[.[] | select(.status | IN($s | split(",")[]))]' "$FIX/jobs.json" ;;
  *) echo "stub glab: unexpected $*" >&2; exit 3 ;;
esac
EOF
chmod +x "$TMP/bin/gh" "$TMP/bin/glab"

scenario() { # name: alpha has a ready issue #4
  NAME="$1"; FIX="$TMP/$1"; mkdir -p "$FIX/issues" "$FIX/home"; echo '[]' > "$FIX/jobs.json"
  jq -n '{repo: "alpha", number: 4, state: "OPEN", labels: [{name: "approved"}], body: "Fix it.", createdAt: "2026-10-27T00:00:00Z"}' \
    > "$FIX/issues/alpha-4.json"
}
jobs() { printf '%s\n' "$@" | jq -R 'split(" ") | {name: .[0], status: .[1]}' | jq -s . > "$FIX/jobs.json"; } # "name status"...
dispatch() {
  OUT="$(env PATH="$TMP/bin:$PATH" HOME="$FIX/home" FIX="$FIX" "$ROOT/looper-dispatch" "$@" 2>&1)" \
    || { echo "$OUT"; fail "looper-dispatch exited non-zero"; }
}
started() { [[ -s "$FIX/started" ]]; }
fail() { echo "FAIL $NAME: $*" >&2; exit 1; }
pass() { echo "ok $NAME"; }
labels() { jq -r '[.labels[].name] | join(",")' "$FIX/issues/$1-$2.json"; }
in_progress() { jq '.labels += [{name: "looper:in-progress"}]' "$FIX/issues/alpha-4.json" > "$FIX/x" && mv "$FIX/x" "$FIX/issues/alpha-4.json"; }

scenario ready-free
jobs "looper-alpha-3 success" "looper-beta-7 waiting_for_resource"
dispatch run
started || fail "no pipeline started: $OUT"
pass

for st in created pending waiting_for_resource running; do
  scenario "busy-$st"
  jobs "looper-alpha-4 $st"
  dispatch run
  ! started || fail "started a pipeline while looper-alpha-4 is $st"
  pass
done

scenario plan-under-way
jobs "looper-plan waiting_for_resource"
dispatch run
! started || fail "started a pipeline while a plan waits"
pass

scenario status-busy
jobs "looper-alpha-4 waiting_for_resource"
dispatch status
grep -q "alpha: ready 4 (busy)" <<<"$OUT" || fail "status: $OUT"
pass

# A run killed after it labelled its issue (looper#20) leaves looper:in-progress
# with no job holding it: the pass removes the label, says so on the issue, and
# starts the pipeline, whose job resumes the issue from its checkpoint.
scenario orphan-released
in_progress
jobs "looper-alpha-4 failed" "looper-beta-7 running"
dispatch run
[[ "$(labels alpha 4)" == approved ]] || fail "labels $(labels alpha 4)"
grep -q '^alpha#4 .*no looper job' "$FIX/comments" || fail "comments: $(cat "$FIX/comments" 2>/dev/null)"
started || fail "no pipeline started: $OUT"
grep -q "alpha#4" <<<"$OUT" || fail "log: $OUT"
pass

# A job of the repository created, pending, waiting or running holds the label.
for st in created pending waiting_for_resource running; do
  scenario "orphan-held-$st"
  in_progress
  jobs "looper-alpha-9 $st"
  dispatch run
  [[ "$(labels alpha 4)" == approved,looper:in-progress ]] || fail "labels $(labels alpha 4)"
  [[ ! -s "$FIX/comments" ]] || fail "commented: $(cat "$FIX/comments")"
  pass
done

echo "looper-dispatch: all scenarios pass"
