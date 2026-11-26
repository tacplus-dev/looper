#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# looper-merger (looper#251): a clean, green merge request merged at once,
# unbuilt, at its green head; a conflicting one sent back to its issue, once
# per head; a clean merge only while the rolling check's gate is open
# (looper#249's `looper-check gate`, asked for each one, a stub here: its line
# says why); only a trusted login's status read; the shadow compile measured,
# never required. A stub gh plays GitHub:
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
# The rolling check's gate: records its arguments; answers with $FIX/gate-<branch,
# / as _>, else $FIX/gate ("EXIT LINE", default open). $FIX/gate-opens N: open
# the first N times it is asked, closed after (the merges a pass made count).
cat > "$TMP/bin/check-gate" <<'EOF'
#!/usr/bin/env bash
echo "gate $*" >> "$FIX/calls"
[[ "$1" == gate ]] || exit 3
b=""; while (( $# )); do [[ "$1" != --branch ]] || b="$2"; shift; done
if [[ -f "$FIX/gate-opens" ]]; then
  n="$(cat "$FIX/gate-opens")"; echo $((n - 1)) > "$FIX/gate-opens"
  if (( n > 0 )); then echo "open: $((4 - n)) merge(s) unchecked (at most 4)"; exit 0; fi
  echo "closed: 4 merges on main are unchecked (at most 4)"; exit 1
fi
f="$FIX/gate-${b//\//_}"; [[ -f "$f" ]] || f="$FIX/gate"
read -r rc line < "$f" 2>/dev/null || { rc=0; line="open: 0 merge(s) unchecked (at most 4), the check's state: open: green g"; }
echo "$line"; exit "$rc"
EOF
chmod +x "$TMP/bin/check-gate"

fail() { echo "FAIL $NAME: $*" >&2; for f in "$FIX/out" "$FIX/calls"; do [[ -f "$f" ]] && { echo "--- $f" >&2; cat "$f" >&2; }; done; exit 1; }
pass() { echo "ok $NAME"; }
has() { grep -qF -- "$2" "$1" || fail "expected \"$2\" in $1"; }
hasnt() { ! grep -qF -- "$2" "$1" || fail "did not expect \"$2\" in $1"; }
NOW="$(date +%s)"
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; } # epoch

# A fixture: no merge request yet; the gate open unless told otherwise.
fixture() { # name
  NAME="$1"; FIX="$TMP/$1"; mkdir -p "$FIX/api"; : > "$FIX/calls"
  echo '[]' > "$FIX/api/pulls"
}
# A commit status, newest first in its list; CREATOR default the trusted login.
status() { # sha context state [creator]
  local f="$FIX/api/commits_$1_statuses" old='[]'
  [[ ! -f "$f" ]] || old="$(cat "$f")"
  jq -c --arg c "$2" --arg s "$3" --arg l "${4:-tacplus-reader[bot]}" '[{context: $c, state: $s, creator: {login: $l}}] + .' <<<"$old" > "$f"
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
  env PATH="$TMP/bin:$PATH" FIX="$FIX" HOME="$FIX/home" LOOPER_MERGER_TRUSTED='tacplus-reader[bot]' LOOPER_MERGER_GATE="$TMP/bin/check-gate gate" "${env[@]}" \
    "$ROOT/looper-merger" pass --repo alpha "$@" > "$FIX/out" 2>&1 || rc=$?
  echo "$rc"
}

# --- a clean, green merge request merges at once, unbuilt, at its green head ----
fixture clean-merges
mr 7 41
[[ "$(merger)" == 0 ]] || fail "exit"
has "$FIX/calls" "merge pulls_7_merge sha=h7 merge_method=merge"
has "$FIX/calls" "gate gate --repo alpha --branch looper/alpha-41 --sha h7 --dir $FIX/home/looper-merger/clones/alpha"
has "$FIX/calls" "comment 41 The merger merged #7 (h7, its looper/gates green) into main as merge-o, unbuilt"
has "$FIX/calls" "edit 41 --remove-label looper:landing --remove-label looper:merge-request"
has "$FIX/out" "#7: merged h7 as merge-o, unbuilt (the rolling check's gate: open: 0 merge(s) unchecked"
pass

# --- a VM report's merge request (looper#250): its issue is its branch's, looper/mr-NAME-N
fixture mr-branch 1
mr 8 0 && mr 9 0 false
jq -c 'map(if .number == 8 then .head.ref = "looper/mr-alpha-81" else .head.ref = "looper/mr-alpha-91" end)' "$FIX/api/pulls" > "$FIX/p" && mv "$FIX/p" "$FIX/api/pulls"
[[ "$(merger)" == 0 ]] || fail "exit"
has "$FIX/calls" "merge pulls_8_merge sha=h8"
has "$FIX/calls" "comment 81 The merger merged #8 (h8"
has "$FIX/calls" "edit 81 --remove-label looper:landing --remove-label looper:merge-request"
has "$FIX/calls" "comment 91 The merger sent back #9"
has "$FIX/calls" "edit 91 --remove-label looper:landing --remove-label looper:merge-request"
pass

# --- only a green status of a trusted login merges -----------------------------
fixture not-green
mr 1 11 true pending
mr 2 12 true none; status h2 looper/gates success tacplus-looper[bot]
mr 3 13 true failure
mr 4 14 true none; status h4 other/ctx success
[[ "$(merger)" == 0 ]] || fail "exit"
hasnt "$FIX/calls" "merge "
has "$FIX/out" "#1: not green at h1 (looper/gates pending): waits"
has "$FIX/out" "#2: not green at h2 (looper/gates none): waits"
has "$FIX/out" "#3: not green at h3 (looper/gates failure): waits"
has "$FIX/out" "#4: not green at h4 (looper/gates none): waits"
pass

fixture no-trusted
mr 1 11
[[ "$(merger LOOPER_MERGER_TRUSTED=)" == 2 ]] || fail "merged with no trusted login"
has "$FIX/out" "LOOPER_MERGER_TRUSTED names no login"
hasnt "$FIX/calls" "merge "
pass

# --- a conflict goes back to its issue, once per head ---------------------------
fixture conflict
mr 5 51 false
mr 6 61
[[ "$(merger)" == 0 ]] || fail "exit"
has "$FIX/calls" "comment 5 The merger sent this back: it conflicts with main at h5"
has "$FIX/calls" "mark 5 <!-- looper-merger: sent back h5 -->"
has "$FIX/calls" "comment 51 The merger sent back #5: it conflicts with main at h5."
has "$FIX/calls" "edit 51 --remove-label looper:landing --remove-label looper:merge-request"
hasnt "$FIX/calls" "merge pulls_5"
has "$FIX/calls" "merge pulls_6_merge sha=h6"
echo '[]' > "$FIX/api/pulls"; mr 5 51 false; : > "$FIX/calls"
jq -n '[{body: "The merger sent this back\n<!-- looper-merger: sent back h5 -->"}]' > "$FIX/api/issues_5_comments"
[[ "$(merger)" == 0 ]] || fail "exit"
[[ ! -s "$FIX/calls" ]] || fail "sent back twice"
has "$FIX/out" "#5: conflicts with main; sent back already at h5"
pass

fixture not-computed
mr 3 31 null
[[ "$(merger)" == 0 ]] || fail "exit"
[[ ! -s "$FIX/calls" ]] || fail "acted on an uncomputed mergeability"
has "$FIX/out" "#3: GitHub has not computed its mergeability yet"
pass

# --- the bound: a clean merge only while the rolling check's gate is open -----
# Closed (no main-green, the check red or recovering, 4 unchecked, its age:
# looper-check's to say), nothing merges and its line says why; a conflict
# still goes back; the gate is not asked for what would not merge anyway.
fixture gate-closed
echo "1 closed: there is no main-green: the check has found no head of main green" > "$FIX/gate"
mr 1 11; mr 2 21 false; mr 3 31 true pending
[[ "$(merger)" == 0 ]] || fail "exit"
has "$FIX/out" "#1: clean and green at h1: held, closed: there is no main-green"
hasnt "$FIX/calls" "merge "
has "$FIX/calls" "comment 2 The merger sent this back"
[[ "$(grep -c '^gate ' "$FIX/calls")" == 1 ]] || fail "the gate was asked for more than the clean, green one"
pass

# Asked again for each clean merge: the pass's own merges count against it.
fixture gate-per-merge
echo 3 > "$FIX/gate-opens"
mr 1 11; mr 2 21; mr 3 31; mr 4 41
[[ "$(merger)" == 0 ]] || fail "exit"
[[ "$(grep -c '^merge ' "$FIX/calls")" == 3 ]] || fail "merged $(grep -c '^merge ' "$FIX/calls"), not 3"
hasnt "$FIX/calls" "merge pulls_4_merge"
has "$FIX/out" "#4: clean and green at h4: held, closed: 4 merges on main are unchecked (at most 4)"
pass

# While the check recovers, the gate opens for its own branch alone (looper-check's answer).
fixture gate-recovery
echo "1 closed: reverting abc1234: allow looper/revert-abc1234" > "$FIX/gate"
echo "0 open: looper/revert-abc1234 is the recovery's own branch (reverting abc1234: allow looper/revert-abc1234)" > "$FIX/gate-looper_revert-abc1234"
mr 1 11
mr 2 0; jq '.[1].head.ref = "looper/revert-abc1234"' "$FIX/api/pulls" > "$FIX/p" && mv "$FIX/p" "$FIX/api/pulls"
[[ "$(merger)" == 0 ]] || fail "exit"
has "$FIX/calls" "merge pulls_2_merge sha=h2"
hasnt "$FIX/calls" "merge pulls_1_merge"
has "$FIX/out" "#1: clean and green at h1: held, closed: reverting abc1234"
pass

# A gate that cannot be asked (no looper-check, GitHub unreadable) is closed.
fixture gate-missing
mr 1 11
[[ "$(merger LOOPER_MERGER_GATE="$TMP/no-such-looper-check gate")" == 0 ]] || fail "exit"
hasnt "$FIX/calls" "merge "
has "$FIX/out" "#1: clean and green at h1: held, the rolling check's gate could not be asked (exit 127)"
echo "2 " > "$FIX/gate"
[[ "$(merger)" == 0 ]] || fail "exit"
hasnt "$FIX/calls" "merge "
has "$FIX/out" "#1: clean and green at h1: held, the rolling check's gate could not be asked (exit 2)"
pass

# --- order, forks, refusals and the dry run -----------------------------------
fixture order
echo 2 > "$FIX/gate-opens"
mr 1 11 true success '[]' 2026-11-25T00:00:00Z
mr 2 21 true success '[{"name": "priority:high"}]' 2026-11-26T00:00:00Z
mr 3 31 true success '[]' 2026-11-24T00:00:00Z
[[ "$(merger)" == 0 ]] || fail "exit"
[[ "$(grep '^merge ' "$FIX/calls" | cut -d' ' -f2 | tr '\n' ' ')" == "pulls_2_merge pulls_3_merge " ]] || fail "order"
pass

fixture fork
mr 1 11
jq '.[0].head.repo.full_name = "someone/alpha"' "$FIX/api/pulls" > "$FIX/p" && mv "$FIX/p" "$FIX/api/pulls"
[[ "$(merger)" == 0 ]] || fail "exit"
has "$FIX/out" "#1: from a fork: never merged"
hasnt "$FIX/calls" "merge "
pass

fixture refused
mr 1 11
touch "$FIX/refuse"
[[ "$(merger)" == 0 ]] || fail "exit"
has "$FIX/out" "#1: GitHub refused its merge at h1: the next pass"
hasnt "$FIX/calls" "comment "
pass

fixture dry-run
mr 1 11; mr 2 21 false
[[ "$(merger -- --dry-run)" == 0 ]] || fail "exit"
! grep -qv '^gate ' "$FIX/calls" || fail "a dry run wrote"   # the gate reads, and writes nothing on GitHub
has "$FIX/out" "#1: would merge h1, unbuilt"
has "$FIX/out" "#2: would send back (conflicts with main) to #21"
pass

# --- the shadow compile: measured, never required ------------------------------
fixture shadow
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
