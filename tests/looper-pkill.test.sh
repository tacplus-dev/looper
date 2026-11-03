#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# looper-pkill, the `pkill` a model sees (looper#61): it signals the matching
# processes its run started (LOOPER_MODEL_RUN in their environment) and spares
# the others, another run's or the looper's lands, naming them; pkill's
# signal and echo options work; without LOOPER_MODEL_RUN it is the real pkill.
# Processes here are sleeps under a tag only this test's run uses.
# It runs as a child runs it too: with a looper-pkill first on the PATH and
# LOOPER_MODEL_RUN set, neither of which it may inherit.
# Run: tests/looper-pkill.test.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
PIDS=()
trap 'kill "${PIDS[@]}" 2>/dev/null || true; rm -rf "$TMP"' EXIT
NAME=""
fail() { echo "FAIL $NAME: $*" >&2; exit 1; }
pass() { echo "ok $NAME"; }

is_shim() { [[ -f "$1" ]] && head -n 10 "$1" | grep -qa '^# looper-pkill: '; }
unset LOOPER_MODEL_RUN LOOPER_REAL_PKILL
path=""; IFS=: read -ra dirs <<< "$PATH"
for d in "${dirs[@]}"; do is_shim "$d/pkill" || path="${path:+$path:}$d"; done
PATH="$path"

mkdir -p "$TMP/shim" "$TMP/real"
ln -s "$ROOT/looper-pkill" "$TMP/shim/pkill"
TAG="looper-pkill-test-$$"
start() { # run tag: a sleep of that run (none: no run), its PID in PID
  if [[ -n "$1" ]]; then LOOPER_MODEL_RUN="$1" bash -c 'exec -a "$0" sleep 60' "$TAG-$2" & PID=$!
  else env -u LOOPER_MODEL_RUN bash -c 'exec -a "$0" sleep 60' "$TAG-$2" & PID=$!; fi
  PIDS+=("$PID")
  for _ in $(seq 50); do grep -q "$TAG" "/proc/$PID/cmdline" 2>/dev/null && return 0; sleep 0.1; done
  fail "$TAG-$2 did not start"
}
alive() { kill -0 "$1" 2>/dev/null && [[ "$(ps -o stat= -p "$1")" != Z* ]]; }
gone() { # pid: it ends soon
  for _ in $(seq 50); do alive "$1" || return 0; sleep 0.1; done
  return 1
}
# pkill as the model of run $1 runs it: the shim first on the PATH.
pk() { local run="$1"; shift; PATH="$TMP/shim:$PATH" LOOPER_MODEL_RUN="$run" pkill "$@"; }

NAME=own-spared
start /runs/a mine; mine=$PID
start /runs/b theirs; theirs=$PID
start "" lander; lander=$PID
rc=0; pk /runs/a -f "$TAG" 2> "$TMP/err" || rc=$?
(( rc == 0 )) || fail "exit $rc: $(cat "$TMP/err")"
gone "$mine" || fail "its own process was not signalled"
alive "$theirs" || fail "another run's process was signalled"
alive "$lander" || fail "a process of no run (the lander's) was signalled"
grep -q "spared 2 process" "$TMP/err" || fail "stderr: $(cat "$TMP/err")"
grep -q "$theirs ($TAG-theirs" "$TMP/err" && grep -q "$lander ($TAG-lander" "$TMP/err" || fail "stderr: $(cat "$TMP/err")"
pass

NAME=none-ours
rc=0; pk /runs/a -f "$TAG" 2> "$TMP/err" || rc=$?
(( rc == 1 )) || fail "exit $rc, want 1"
alive "$theirs" && alive "$lander" || fail "a process of another run was signalled"
grep -q "spared 2 process" "$TMP/err" || fail "stderr: $(cat "$TMP/err")"
rc=0; pk /runs/a -f "$TAG-nothing" 2> "$TMP/err" || rc=$?
(( rc == 1 )) || fail "no match: exit $rc, want 1"
[[ ! -s "$TMP/err" ]] || fail "no match: stderr: $(cat "$TMP/err")"
pass

# The signal, given as pkill takes it, and -e.
NAME=signal
for s in "-KILL" "-9" "--signal KILL" "--signal=9" "-SIGKILL"; do
  start /runs/a sig; p=$PID
  # shellcheck disable=SC2086
  out="$(pk /runs/a $s -e -f "$TAG-sig" 2>&1)" || fail "$s: $out"
  gone "$p" || fail "$s: not signalled"
  wait "$p" 2>/dev/null && st=0 || st=$?
  (( st == 137 )) || fail "$s: ended $st, want 137 (KILL)"
  [[ "$out" == "sleep killed (pid $p)" ]] || fail "$s: -e said: $out"
done
start /runs/a term; p=$PID
pk /runs/a -f "$TAG-term"; gone "$p" || fail "TERM: not signalled"
wait "$p" 2>/dev/null && st=0 || st=$?
(( st == 143 )) || fail "default: ended $st, want 143 (TERM)"
pass

# Outside a run it is the real pkill, whatever it is given.
NAME=no-run
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" > "$TMP/argv"\n' > "$TMP/real/pkill"; chmod +x "$TMP/real/pkill"
export TMP
PATH="$TMP/shim:$TMP/real:$PATH" pkill -9 -f "x y"
[[ "$(cat "$TMP/argv")" == "-9 -f x y" ]] || fail "argv: $(cat "$TMP/argv")"
rm -f "$TMP/argv"; LOOPER_REAL_PKILL="$TMP/real/pkill" PATH="$TMP/shim:$PATH" pkill -f z
[[ "$(cat "$TMP/argv")" == "-f z" ]] || fail "LOOPER_REAL_PKILL: argv: $(cat "$TMP/argv")"
# One that names the shim itself (inherited from a run) is passed over.
rm -f "$TMP/argv"; LOOPER_REAL_PKILL="$TMP/shim/pkill" PATH="$TMP/shim:$TMP/real:$PATH" timeout 10 pkill -f w
[[ "$(cat "$TMP/argv")" == "-f w" ]] || fail "LOOPER_REAL_PKILL the shim: argv: $(cat "$TMP/argv")"
pass
