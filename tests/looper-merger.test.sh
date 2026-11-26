#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# looper-merger (looper#251): a clean, green merge request merged at once,
# unbuilt, at its green head; a conflicting one sent back to its issue, once
# per head; nothing merged while the rolling check is down, red or behind (at
# most 4 merges unchecked, or one gate's age); only a trusted login's status
# read; the shadow compile measured, never required. A stub gh plays GitHub:
# `gh api PATH` answers $FIX/api/<PATH less repos/ORG/REPO/, / as _, no query>,
# else HTTP 404; every write is a line of $FIX/calls.
# Run: tests/looper-merger.test.sh
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/hermetic.sh"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"

cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$1 $2" in
  "issue comment") echo "comment $3 $(head -1 <<<"$7")" >> "$FIX/calls"; [[ "$7" != *"<!-- looper-merger"* ]] || echo "mark $3 $(tail -1 <<<"$7")" >> "$FIX/calls"; exit 0 ;;
  "issue edit") echo "edit $3 ${*:6}" >> "$FIX/calls"; exit 0 ;;
esac
[[ "$1" == api ]] || { echo "stub gh: $*" >&2; exit 1; }
shift; method=GET; jq=""; path=""; fields=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -X) method="$2"; shift 2 ;;
    --jq) jq="$2"; shift 2 ;;
    -H) shift 2 ;;
    -f) fields+=("$2"); shift 2 ;;
    *) path="$1"; shift ;;
  esac
done
key="${path#repos/tacplus-dev/alpha/}"; key="${key%%\?*}"; key="${key//\//_}"
if [[ "$method" == PUT ]]; then
  echo "merge $key ${fields[*]}" >> "$FIX/calls"
  [[ ! -e "$FIX/refuse" ]] || { echo "HTTP 405: not mergeable" >&2; exit 1; }
  out="{\"sha\": \"merge-of-${key}\"}"
else
  [[ -f "$FIX/api/$key" ]] || { echo "HTTP 404: Not Found ($path)" >&2; exit 1; }
  out="$(cat "$FIX/api/$key")"
fi
if [[ -n "$jq" ]]; then jq -r "$jq" <<<"$out"; else printf '%s\n' "$out"; fi
EOF
chmod +x "$TMP/bin/gh"
# A shadow compile: records its arguments, fails with $FIX/shadow-red.
cat > "$TMP/bin/compile" <<'EOF'
#!/usr/bin/env bash
echo "shadow $*" >> "$FIX/calls"; [[ ! -e "$FIX/shadow-red" ]]
EOF
chmod +x "$TMP/bin/compile"

fail() { echo "FAIL $NAME: $*" >&2; for f in "$FIX/out" "$FIX/calls"; do [[ -f "$f" ]] && { echo "--- $f" >&2; cat "$f" >&2; }; done; exit 1; }
pass() { echo "ok $NAME"; }
has() { grep -qF -- "$2" "$1" || fail "expected \"$2\" in $1"; }
hasnt() { ! grep -qF -- "$2" "$1" || fail "did not expect \"$2\" in $1"; }
NOW="$(date +%s)"
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; } # epoch

# A fixture: main-green at g, and main N merges after it (m1..mN, each a minute
# old more than the next, mN main's head; MINUTES, default 1, the oldest's age).
fixture() { # name [unchecked [minutes]]
  local i n="${2:-0}" age="${3:-1}" prev=g cs=""
  NAME="$1"; FIX="$TMP/$1"; mkdir -p "$FIX/api"; : > "$FIX/calls"
  echo '{"object": {"sha": "g"}}' > "$FIX/api/git_ref_heads_main-green"
  for (( i = 1; i <= n; i++ )); do
    cs+="${cs:+,}{\"sha\": \"m$i\", \"parents\": [{\"sha\": \"$prev\"}, {\"sha\": \"side$i\"}], \"commit\": {\"committer\": {\"date\": \"$(iso $((NOW - (age - i + 1) * 60)))\"}}}"
    prev="m$i"; echo '[]' > "$FIX/api/commits_m${i}_statuses"
  done
  echo "{\"object\": {\"sha\": \"$prev\"}}" > "$FIX/api/git_ref_heads_main"
  (( n == 0 )) || echo "{\"status\": \"ahead\", \"commits\": [$cs]}" > "$FIX/api/compare_g...$prev"
  status g looper/rolling-check success
  echo '[]' > "$FIX/api/pulls"
}
# A commit status, newest first in its list; CREATOR default the trusted login.
status() { # sha context state [creator]
  local f="$FIX/api/commits_$1_statuses" old='[]'
  [[ ! -f "$f" ]] || old="$(cat "$f")"
  jq -c --arg c "$2" --arg s "$3" --arg l "${4:-merger-app[bot]}" '[{context: $c, state: $s, creator: {login: $l}}] + .' <<<"$old" > "$f"
}
# An open merge request N from looper/alpha-ISSUE at head hN, green unless STATE, mergeable MERGEABLE.
mr() { # n issue [mergeable [state [labels-json [created]]]]
  local n="$1"
  jq -c --argjson n "$n" --arg ref "looper/alpha-$2" --argjson labels "${5:-[]}" --arg at "${6:-2026-11-26T00:00:0${n}Z}" \
    '. + [{number: $n, title: "t\($n)", draft: false, created_at: $at, labels: $labels, body: "",
           head: {sha: "h\($n)", ref: $ref, repo: {full_name: "tacplus-dev/alpha"}}}]' "$FIX/api/pulls" > "$FIX/api/pulls.new"
  mv "$FIX/api/pulls.new" "$FIX/api/pulls"
  echo "{\"mergeable\": ${3:-true}}" > "$FIX/api/pulls_$n"
  echo '[]' > "$FIX/api/issues_${n}_comments"
  [[ "${4:-success}" == none ]] || status "h$n" looper/gates "${4:-success}"
}
merger() { # [VAR=value...] [-- args...]
  local rc=0 env=()
  while [[ $# -gt 0 && "$1" != -- ]]; do env+=("$1"); shift; done
  [[ $# -eq 0 ]] || shift
  env PATH="$TMP/bin:$PATH" FIX="$FIX" HOME="$FIX/home" LOOPER_MERGER_TRUSTED=merger-app[bot] LOOPER_MERGER_MAX_AGE=30 "${env[@]}" \
    "$ROOT/looper-merger" pass --repo alpha "$@" > "$FIX/out" 2>&1 || rc=$?
  echo "$rc"
}

# --- a clean, green merge request merges at once, unbuilt, at its green head ----
fixture clean-merges 1
mr 7 41
[[ "$(merger)" == 0 ]] || fail "exit"
has "$FIX/calls" "merge pulls_7_merge sha=h7 merge_method=merge"
has "$FIX/calls" "comment 41 The merger merged #7 (h7, its looper/gates green) into main as merge-o, unbuilt"
has "$FIX/calls" "edit 41 --remove-label looper:landing"
has "$FIX/out" "1 of at most 4 merges unchecked"
has "$FIX/out" "#7: merged h7 as merge-o, unbuilt (2 of at most 4 unchecked)"
pass

# --- only a green status of a trusted login merges -----------------------------
fixture not-green 0
mr 1 11 true pending
mr 2 12 true none; status h2 looper/gates success report-app[bot]
mr 3 13 true failure
mr 4 14 true none; status h4 other/ctx success
[[ "$(merger)" == 0 ]] || fail "exit"
hasnt "$FIX/calls" "merge "
has "$FIX/out" "#1: not green at h1 (looper/gates pending): waits"
has "$FIX/out" "#2: not green at h2 (looper/gates none): waits"
has "$FIX/out" "#3: not green at h3 (looper/gates failure): waits"
has "$FIX/out" "#4: not green at h4 (looper/gates none): waits"
pass

fixture no-trusted 0
mr 1 11
[[ "$(merger LOOPER_MERGER_TRUSTED=)" == 2 ]] || fail "merged with no trusted login"
has "$FIX/out" "LOOPER_MERGER_TRUSTED names no login"
hasnt "$FIX/calls" "merge "
pass

# --- a conflict goes back to its issue, once per head ---------------------------
fixture conflict 0
mr 5 51 false
mr 6 61
[[ "$(merger)" == 0 ]] || fail "exit"
has "$FIX/calls" "comment 5 The merger sent this back: it conflicts with main at h5"
has "$FIX/calls" "mark 5 <!-- looper-merger: sent back h5 -->"
has "$FIX/calls" "comment 51 The merger sent back #5: it conflicts with main at h5."
has "$FIX/calls" "edit 51 --remove-label looper:landing"
hasnt "$FIX/calls" "merge pulls_5"
has "$FIX/calls" "merge pulls_6_merge sha=h6"
echo '[]' > "$FIX/api/pulls"; mr 5 51 false; : > "$FIX/calls"
jq -n '[{body: "The merger sent this back\n<!-- looper-merger: sent back h5 -->"}]' > "$FIX/api/issues_5_comments"
[[ "$(merger)" == 0 ]] || fail "exit"
[[ ! -s "$FIX/calls" ]] || fail "sent back twice"
has "$FIX/out" "#5: conflicts with main; sent back already at h5"
pass

fixture not-computed 0
mr 3 31 null
[[ "$(merger)" == 0 ]] || fail "exit"
[[ ! -s "$FIX/calls" ]] || fail "acted on an uncomputed mergeability"
has "$FIX/out" "#3: GitHub has not computed its mergeability yet"
pass

# --- the bound: nothing merges while the rolling check is down, red or behind --
fixture no-main-green 0
rm "$FIX/api/git_ref_heads_main-green"
mr 1 11; mr 2 21 false
[[ "$(merger)" == 0 ]] || fail "exit"
has "$FIX/out" "merges none of its 2 merge request(s): the rolling check is down: tacplus-dev/alpha has no main-green"
hasnt "$FIX/calls" "merge "
has "$FIX/calls" "comment 2 The merger sent this back"
pass

fixture four-unchecked 4
mr 1 11
[[ "$(merger)" == 0 ]] || fail "exit"
has "$FIX/out" "4 merges on main are unchecked by the rolling check (at most 4)"
hasnt "$FIX/calls" "merge "
pass

fixture three-unchecked 3
mr 1 11; mr 2 21
[[ "$(merger)" == 0 ]] || fail "exit"
has "$FIX/calls" "merge pulls_1_merge"
hasnt "$FIX/calls" "merge pulls_2_merge"
has "$FIX/out" "#2: clean and green at h2: held, 4 merges on main are unchecked"
pass

fixture stale 1 31
mr 1 11
[[ "$(merger)" == 0 ]] || fail "exit"
has "$FIX/out" "main's oldest unchecked merge is 31m old (one gate's age, 30m)"
hasnt "$FIX/calls" "merge "
pass

# One gate's age, by default, is full's minutes in main's gates.yaml.
fixture gate-age 1 31
printf 'full:\n  run: x\n  minutes: 45\ndocs:\n  minutes: 1\n' > "$FIX/api/contents_gates.yaml"
mr 1 11
[[ "$(merger LOOPER_MERGER_MAX_AGE=)" == 0 ]] || fail "exit"
has "$FIX/out" "one gate's age 45m"
has "$FIX/calls" "merge pulls_1_merge"
pass

fixture red 2
status m1 looper/rolling-check failure
status m2 looper/rolling-check success report-app[bot]
mr 1 11
[[ "$(merger)" == 0 ]] || fail "exit"
has "$FIX/out" "the rolling check is red on m1: merging reopens with its next green check"
hasnt "$FIX/calls" "merge "
pass

# A newer check running (pending) on main's head holds nothing; a newer green reopens.
fixture check-running 2
status m1 looper/rolling-check failure
status m2 looper/rolling-check pending
mr 1 11
[[ "$(merger)" == 0 ]] || fail "exit"
has "$FIX/calls" "merge pulls_1_merge"
pass

fixture no-check-status 1
echo '[]' > "$FIX/api/commits_g_statuses"
mr 1 11
[[ "$(merger)" == 0 ]] || fail "exit"
has "$FIX/out" "the rolling check is down: no looper/rolling-check status from a trusted login"
hasnt "$FIX/calls" "merge "
pass

fixture off-line 1
jq '.status = "diverged"' "$FIX/api/compare_g...m1" > "$FIX/c" && mv "$FIX/c" "$FIX/api/compare_g...m1"
mr 1 11
[[ "$(merger)" == 0 ]] || fail "exit"
has "$FIX/out" "main-green g is not on main's first-parent line"
hasnt "$FIX/calls" "merge "
pass

# --- order, forks, refusals and the dry run -----------------------------------
fixture order 2
mr 1 11 true success '[]' 2026-11-25T00:00:00Z
mr 2 21 true success '[{"name": "priority:high"}]' 2026-11-26T00:00:00Z
mr 3 31 true success '[]' 2026-11-24T00:00:00Z
[[ "$(merger)" == 0 ]] || fail "exit"
[[ "$(grep '^merge ' "$FIX/calls" | cut -d' ' -f2 | tr '\n' ' ')" == "pulls_2_merge pulls_3_merge " ]] || fail "order"
pass

fixture fork 0
mr 1 11
jq '.[0].head.repo.full_name = "someone/alpha"' "$FIX/api/pulls" > "$FIX/p" && mv "$FIX/p" "$FIX/api/pulls"
[[ "$(merger)" == 0 ]] || fail "exit"
has "$FIX/out" "#1: from a fork: never merged"
hasnt "$FIX/calls" "merge "
pass

fixture refused 0
mr 1 11
touch "$FIX/refuse"
[[ "$(merger)" == 0 ]] || fail "exit"
has "$FIX/out" "#1: GitHub refused its merge at h1: the next pass"
hasnt "$FIX/calls" "comment "
pass

fixture dry-run 0
mr 1 11; mr 2 21 false
[[ "$(merger -- --dry-run)" == 0 ]] || fail "exit"
[[ ! -s "$FIX/calls" ]] || fail "a dry run wrote"
has "$FIX/out" "#1: would merge h1, unbuilt"
has "$FIX/out" "#2: would send back (conflicts with main) to #21"
pass

# --- the shadow compile: measured, never required ------------------------------
fixture shadow 0
mr 1 11; mr 2 21
touch "$FIX/shadow-red"
[[ "$(merger LOOPER_MERGER_SHADOW="$TMP/bin/compile")" == 0 ]] || fail "exit"
has "$FIX/calls" "merge pulls_1_merge"
has "$FIX/calls" "merge pulls_2_merge"
has "$FIX/calls" "shadow alpha merge-of-pulls_1_merge"
has "$FIX/calls" "shadow alpha merge-of-pulls_2_merge"
[[ "$(cut -f2- "$FIX/home/looper-merger/shadow.tsv" | cut -f1-5)" == "alpha	1	h1	merge-of-pulls_1_merge	1
alpha	2	h2	merge-of-pulls_2_merge	1" ]] || fail "shadow.tsv: $(cat "$FIX/home/looper-merger/shadow.tsv")"
has "$FIX/out" "#1: shadow compile of merge-o: exit 1"
pass

echo "looper-merger: all passed"
