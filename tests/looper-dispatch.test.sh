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
repo=""; n=""; q="."
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) repo="${2##*/}"; shift 2 ;;
    --jq) q="$2"; shift 2 ;;
    --owner|--state|--label|--limit|--json) shift 2 ;;
    *) n="$1"; shift ;;
  esac
done
case "$cmd" in
  "search issues") jq -s 'map(select(.state == "OPEN" and any(.labels[]; .name == "approved")) | {repository: {name: .repo}})' "$FIX"/issues/*.json | jq -r "$q" ;;
  "issue list") jq -s 'map(select(.state == "OPEN" and any(.labels[]; .name == "approved")))' "$FIX/issues/$repo"-*.json | jq -r "$q" ;;
  "issue view") jq -r "$q" "$FIX/issues/$repo-$n.json" ;;
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

echo "looper-dispatch: all scenarios pass"
