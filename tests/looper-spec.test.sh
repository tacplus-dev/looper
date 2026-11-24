#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# looper-spec (looper#240): a project's VM spec, looper.yaml. A machine type,
# or cpu: and memory: (the smallest c4a type with both), a cache disk and
# spot, checked; vm: false unless said; every mistake named, a line each; fit
# picks the smallest machine of a family that holds a load.
# Run: tests/looper-spec.test.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SPEC="$ROOT/looper-spec"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
NAME=""
fail() { echo "FAIL $NAME: $*" >&2; exit 1; }
pass() { echo "ok $NAME"; }
has() { grep -qF -- "$2" <<<"$1" || fail "expected \"$2\" in: $1"; }

NAME="a machine type"
cat > "$TMP/looper.yaml" <<'EOF'
# tacplus's VM (looper#240)
machine: c4a-standard-32   # 8 builds at once
disk: 200
spot: true
EOF
out="$(cd "$TMP" && "$SPEC" check)" || fail "refused: $out"
[[ "$out" == "c4a-standard-32: 32 CPU, 128 GB memory, a 200 GB cache disk, spot, no VM yet" ]] || fail "$out"
out="$("$SPEC" json "$TMP/looper.yaml")"
[[ "$out" == '{"cpu": 32, "disk_gb": 200, "form": "machine", "machine": "c4a-standard-32", "memory_gb": 128, "spot": true, "vm": false}' ]] || fail "$out"
out="$("$SPEC" check - < "$TMP/looper.yaml")" || fail "stdin: $out"
pass

NAME="cpu and memory: the smallest c4a machine with both; vm on"
printf 'cpu: 6\nmemory: 30\ndisk: 50\nspot: false\nvm: true\n' > "$TMP/cm.yaml"
out="$("$SPEC" json "$TMP/cm.yaml")" || fail "refused: $out"
[[ "$out" == '{"cpu": 8, "disk_gb": 50, "form": "cpu", "machine": "c4a-standard-8", "memory_gb": 32, "spot": false, "vm": true}' ]] || fail "$out"
has "$("$SPEC" check "$TMP/cm.yaml")" "c4a-standard-8: 8 CPU, 32 GB memory, a 50 GB cache disk, not spot, its VM on"
pass

NAME="every mistake named, a line each, exit 1"
cat > "$TMP/bad.yaml" <<'EOF'
machine: n2-standard-8
cpu: 4
disk: 5
spot: yes
size: big
spot: true
  nested: 1
EOF
rc=0; err="$("$SPEC" check "$TMP/bad.yaml" 2>&1)" || rc=$?
(( rc == 1 )) || fail "exit $rc: $err"
has "$err" "line 5: size: not a key of looper.yaml"
has "$err" "line 6: spot: twice"
has "$err" "line 7: not \`key: value\`: nested: 1"
has "$err" "machine: and cpu:/memory: both"
has "$err" "machine: n2-standard-8: not an Arm machine type of c4a or t2a"
has "$err" "disk: 5: not a whole number of GB from 10 to 65536"
has "$err" "spot: yes: not true or false"
for body in 'disk: 10' $'machine: c4a-standard-12\ndisk: 10\nspot: true' $'cpu: 4\ndisk: 10\nspot: true' \
            $'cpu: 100\nmemory: 4\ndisk: 10\nspot: true' $'machine: c4a-standard-8\nspot: true'; do
  printf '%s\n' "$body" > "$TMP/b.yaml"
  if "$SPEC" check "$TMP/b.yaml" 2>/dev/null; then fail "passed: $body"; fi
done
has "$(printf 'disk: 10\n' | "$SPEC" check - 2>&1 || true)" "no machine: (or cpu: and memory:)"
has "$(printf 'disk: 10\n' | "$SPEC" check - 2>&1 || true)" "no spot: (true or false)"
has "$(printf 'cpu: 100\nmemory: 4\ndisk: 10\nspot: true\n' | "$SPEC" check - 2>&1 || true)" "no c4a machine is that large"
has "$(printf 'machine: c4a-standard-8\nspot: true\n' | "$SPEC" check - 2>&1 || true)" "no disk: (the cache disk, GB)"
if "$SPEC" check "$TMP/none.yaml" 2>/dev/null; then fail "a missing file passed"; fi
pass

NAME="fit: the fewest vCPUs, then the least memory, of the family"
[[ "$("$SPEC" fit c4a 3 6)" == "c4a-highcpu-4 4 8" ]] || fail "$("$SPEC" fit c4a 3 6)"
[[ "$("$SPEC" fit c4a 4 20)" == "c4a-highmem-4 4 32" ]] || fail "$("$SPEC" fit c4a 4 20)"
[[ "$("$SPEC" fit c4a 20.5 90)" == "c4a-standard-32 32 128" ]] || fail "$("$SPEC" fit c4a 20.5 90)"
[[ "$("$SPEC" fit t2a 4 20)" == "t2a-standard-8 8 32" ]] || fail "$("$SPEC" fit t2a 4 20)"
if "$SPEC" fit c4a 80 10 2>/dev/null; then fail "fit a machine larger than any"; fi
rc=0; "$SPEC" fit x86 1 1 2>/dev/null || rc=$?; (( rc == 2 )) || fail "an unknown family: exit $rc"
pass

echo "looper-spec: all scenarios pass"
