#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# looper-docker, the `docker` a child's model sees (looper#41): a container it
# starts gets the child's memory limit, without swap, unless it asks for less;
# more, or none, is refused; everything else passes through. A stub docker
# records its argv. With a docker daemon at hand, a real container that
# allocates more than its limit is OOM-killed on its own (exit 137), while a
# container beside it and this script carry on.
# Run: tests/looper-docker.test.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
NAME=""
fail() { echo "FAIL $NAME: $*" >&2; exit 1; }
pass() { echo "ok $NAME"; }

mkdir -p "$TMP/real" "$TMP/shim"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" > "$TMP/argv"\n' > "$TMP/real/docker"
chmod +x "$TMP/real/docker"
ln -s "$ROOT/looper-docker" "$TMP/shim/docker"
export TMP
# docker as the model runs it: the shim first on the PATH, the stub after it.
dk() { PATH="$TMP/shim:$TMP/real:$PATH" LOOPER_CHILD_MEMORY="${LIMIT-4096m}" docker "$@"; }
argv() { # expected argv... : docker passes it to the real docker
  local want="$1"; shift; rm -f "$TMP/argv"
  dk "$@" 2>"$TMP/err" || fail "refused: docker $* ($(cat "$TMP/err"))"
  [[ "$(cat "$TMP/argv")" == "$want" ]] || fail "docker $*: got \"$(cat "$TMP/argv")\", want \"$want\""
}
refused() { # docker args...: refused, exit 125, nothing run
  local rc=0; rm -f "$TMP/argv"
  dk "$@" 2>"$TMP/err" || rc=$?
  (( rc == 125 )) || fail "docker $*: exit $rc, want 125"
  [[ ! -e "$TMP/argv" ]] || fail "docker $* ran: $(cat "$TMP/argv")"
  grep -qF "limit, 4096m" "$TMP/err" || grep -qF "not a memory size" "$TMP/err" || fail "docker $*: $(cat "$TMP/err")"
}

NAME=limit-added
argv "run --memory 4096m --memory-swap 4096m --rm -i img cargo kani" run --rm -i img cargo kani
argv "container create --memory 4096m --memory-swap 4096m img" container create img
argv "--context x run --memory 4096m --memory-swap 4096m -it img" --context x run -it img
argv "-H unix:///s run --memory 4096m --memory-swap 4096m img" -H unix:///s run img
# The tacplus wrapper's own run (looper#27): -u, -e, -v and -w take a value.
argv "run --memory 4096m --memory-swap 4096m --rm -i -u 1:1 -e HOME=/h -v /a:/a -w /a img tacplus gen" run --rm -i -u 1:1 -e HOME=/h -v /a:/a -w /a img tacplus gen
pass

NAME=less-kept
argv "run --memory-swap 1g -m 1g img" run -m 1g img
argv "run --memory-swap 2g --memory=2g img" run --memory=2g img
argv "run --memory-swap 512m -m512m img" run -m512m img
argv "run -dm 4g --memory-swap 4g img" run -dm 4g --memory-swap 4g img
argv "run --memory 3g --memory-swap=3g img" run --memory-swap=3g img
argv "update -m 1g c1" update -m 1g c1
pass

NAME=more-refused
refused run -m 8g img
refused run --memory=5g img
refused run --memory 0 img
refused run --memory-swap -1 img
refused run -it --memory-swap=16g img
refused container run --rm --memory 4097m img
refused run -m lots img
refused update --memory 12g c1
pass

# The image's own command line is the container's, not docker's: its -m is not a limit.
NAME=image-args
argv "run --memory 4096m --memory-swap 4096m --name n img python -m 64g" run --name n img python -m 64g
argv "run --memory 4096m --memory-swap 4096m -- img -m 64g" run -- img -m 64g
argv "run --memory 4096m --memory-swap 4096m --rm=true -e X img --memory 64g" run --rm=true -e X img --memory 64g
pass

NAME=passed-through
argv "ps -a" ps -a
argv "build --memory 64g ." build --memory 64g .
LIMIT="" argv "run -m 64g img" run -m 64g img
pass

# The real thing: 64 MB, and a container that asks for 256.
NAME=oom-killed-alone
if ! docker info >/dev/null 2>&1; then echo "skip $NAME: no docker daemon"; exit 0; fi
img="${LOOPER_TEST_IMAGE:-alpine:3}"
docker pull -q "$img" >/dev/null 2>&1 || docker image inspect "$img" >/dev/null 2>&1 || { echo "skip $NAME: no $img"; exit 0; }
rd="$(command -v docker)"
lim() { PATH="$TMP/shim:$PATH" LOOPER_REAL_DOCKER="$rd" LOOPER_CHILD_MEMORY=64m docker "$@"; }
lim run --rm "$img" sh -c 'sleep 4; echo alive' > "$TMP/beside" 2>&1 & beside=$!
rc=0; lim run --rm "$img" sh -c 'head -c 256m /dev/zero | tail > /dev/null' 2>"$TMP/err" || rc=$?
(( rc == 137 )) || fail "the hungry container exited $rc, want 137 (OOM-killed): $(cat "$TMP/err")"
wait "$beside" || fail "the container beside it failed: $(cat "$TMP/beside")"
[[ "$(cat "$TMP/beside")" == alive ]] || fail "the container beside it: $(cat "$TMP/beside")"
rc=0; lim run --rm "$img" sh -c 'head -c 16m /dev/zero | tail > /dev/null' || rc=$?
(( rc == 0 )) || fail "a container within its limit exited $rc"
pass
