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
# It runs as a child runs it too (looper#52): with a looper-docker first on
# the PATH and LOOPER_REAL_DOCKER set, neither of which it may inherit.
# Run: tests/looper-docker.test.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
NAME=""
fail() { echo "FAIL $NAME: $*" >&2; exit 1; }
pass() { echo "ok $NAME"; }

# The test's own environment, not the child's it may run in (looper#52): a
# child's docker is a looper-docker first on its PATH, with LOOPER_REAL_DOCKER
# set. Drop both, so the shim under test finds the stub, or the real docker.
is_shim() { [[ -f "$1" ]] && head -n 10 "$1" | grep -qa '^# looper-docker: '; }
unset LOOPER_REAL_DOCKER LOOPER_CHILD_MEMORY
path=""; IFS=: read -ra dirs <<< "$PATH"
for d in "${dirs[@]}"; do is_shim "$d/docker" || path="${path:+$path:}$d"; done
PATH="$path"

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

# The test as a child runs it: a copy of looper-docker first on its PATH, with
# LOOPER_REAL_DOCKER the real docker, or unset (looper#52). It passes, in time.
NAME=child-env
if [[ -z "${LOOPER_DOCKER_TEST_CHILD:-}" ]]; then
  mkdir -p "$TMP/child"; cp "$ROOT/looper-docker" "$TMP/child/docker"
  for rd in "$(command -v docker || true)" ""; do
    rc=0; timeout 600 env LOOPER_DOCKER_TEST_CHILD=1 PATH="$TMP/child:$PATH" LOOPER_REAL_DOCKER="$rd" \
      LOOPER_CHILD_MEMORY=4096m "${BASH_SOURCE[0]}" > "$TMP/child.out" 2>&1 || rc=$?
    (( rc == 0 )) || fail "under a child, LOOPER_REAL_DOCKER=\"$rd\": exit $rc: $(tail -n 5 "$TMP/child.out")"
  done
  pass
fi

# The broker's checks (looper#68), as looper-docker-broker runs them: brokered,
# for one owner and its roots. The stub docker also answers `container
# inspect` with an owner label (mine, theirs; anything else is no container)
# and copies an --env-file it is given to $TMP/envfile.
cat > "$TMP/real/docker" <<'EOF2'
#!/usr/bin/env bash
if [[ "$1 $2" == "container inspect" ]]; then
  case "${!#}" in mine) echo m1 ;; theirs) echo m2 ;; *) exit 1 ;; esac; exit 0
fi
printf "%s\n" "$*" > "$TMP/argv"
a=("$@"); for i in "${!a[@]}"; do [[ "${a[i]}" != --env-file ]] || cat "${a[i+1]}" > "$TMP/envfile"; done
EOF2
mkdir -p "$TMP/wt/src" "$TMP/home" "$TMP/elsewhere"; ln -s "$TMP/elsewhere" "$TMP/wt/escape"
bk() { ( cd "$TMP/wt" && PATH="$TMP/shim:$TMP/real:$PATH" LOOPER_DOCKER_BROKERED=1 LOOPER_DOCKER_OWNER=m1 \
  LOOPER_DOCKER_ROOTS="$TMP/wt:$TMP/home" LOOPER_CHILD_MEMORY="${LIMIT-4096m}" LOOPER_REAL_DOCKER="$TMP/real/docker" docker "$@" ); }
bargv() { # expected argv...: the broker passes it to the real docker
  local want="$1"; shift; rm -f "$TMP/argv"
  bk "$@" 2>"$TMP/err" || fail "refused: docker $* ($(cat "$TMP/err"))"
  [[ "$(cat "$TMP/argv")" == "$want" ]] || fail "docker $*: got \"$(cat "$TMP/argv")\", want \"$want\""
}
brefused() { # what-it-says docker args...: refused, exit 125, nothing run
  local says="$1" rc=0; shift; rm -f "$TMP/argv"
  bk "$@" 2>"$TMP/err" || rc=$?
  (( rc == 125 )) || fail "docker $*: exit $rc, want 125"
  [[ ! -e "$TMP/argv" ]] || fail "docker $* ran: $(cat "$TMP/argv")"
  grep -qF -- "$says" "$TMP/err" || fail "docker $*: $(cat "$TMP/err")"
}
L="--label io.tacplus.looper.owner=m1"

NAME=broker-mounts
bargv "run --memory 4096m --memory-swap 4096m $L --rm -v $TMP/wt:$TMP/wt -w $TMP/wt img" run --rm -v "$TMP/wt:$TMP/wt" -w "$TMP/wt" img
bargv "run --memory 4096m --memory-swap 4096m $L -v ./src:/s:ro --mount type=bind,src=$TMP/home/x,dst=/h -v /anon img" \
  run -v ./src:/s:ro --mount "type=bind,src=$TMP/home/x,dst=/h" -v /anon img
bargv "run --memory 4096m --memory-swap 4096m $L --mount type=tmpfs,dst=/t -it img sh" run --mount type=tmpfs,dst=/t -it img sh
brefused "outside this child's own directories" run -v /:/host img
brefused "outside this child's own directories" run -v "$TMP/elsewhere:/x" img
brefused "outside this child's own directories" run -v "$TMP/wt/escape:/x" img
brefused "outside this child's own directories" run -v "$TMP/wt/../elsewhere:/x" img
brefused "outside this child's own directories" run -it -v/var/run/docker.sock:/s img
brefused "outside this child's own directories" run --mount type=bind,source=/etc,target=/e img
brefused "outside this child's own directories" run --mount Type=Bind,SRC=/etc,dst=/e img
brefused "a quoted field" run --mount 'type=bind,"src=/etc",dst=/e' img
brefused "a named volume" run --mount TYPE=volume,Source=cache,dst=/c img
brefused "outside this child's own directories" create --volume=/root:/r img
brefused "a named volume" run -v cache:/c img
brefused "outside this child's own directories" run --env-file /etc/shadow img
pass

NAME=broker-privilege
for o in --privileged "--cap-add SYS_ADMIN" "--device /dev/sda" "--security-opt seccomp=unconfined" --use-api-socket \
         "--volumes-from c" "--cgroup-parent /" "--runtime runc" "--sysctl a=b"; do
  # shellcheck disable=SC2086
  brefused "is not for a looper's model" run $o img
done
for o in "--pid host" "--pid=host" "--network host" "--net=container:c" "--ipc host" "--uts host" "--userns host" "--cgroupns host"; do
  # shellcheck disable=SC2086
  brefused "shares a namespace" run $o img
done
brefused "the label io.tacplus.looper.owner is the looper's" run -l io.tacplus.looper.owner=m2 img
brefused "the looper's docker is the runner's own" -H unix:///other.sock run img
brefused "the looper's docker is the runner's own" --context x ps
bargv "run --memory 4096m --memory-swap 4096m $L --network none --pid=private img" run --network none --pid=private img
brefused "limit, 4096m" run -m 8g img
pass

# A `-e NAME` takes its value from the model's environment (the broker's
# LOOPER_DOCKER_ENV_NAME) through an env file, never a command line.
NAME=broker-env
rm -f "$TMP/envfile"
LOOPER_DOCKER_ENV_GH_TOKEN=s3cret LOOPER_DOCKER_ENV_X='a b' bargv "run --memory 4096m --memory-swap 4096m $L --env-file /dev/fd/3 -i -e Y=1 img" \
  run -e GH_TOKEN -ie X -e Y=1 -e UNSET img
[[ "$(cat "$TMP/envfile")" == $'GH_TOKEN=s3cret\nX=a b' ]] || fail "env file: $(cat "$TMP/envfile")"
pass

NAME=broker-own-containers
bargv "logs -f mine" logs -f mine
bargv "stop -t 3 mine" stop -t 3 mine
bargv "container rm -f mine" container rm -f mine
bargv "exec -it mine sh -c ps" exec -it mine sh -c ps
bargv "cp mine:/out $TMP/wt/out" cp mine:/out "$TMP/wt/out"
bargv "inspect mine alpine" inspect mine alpine
bargv "ps --filter label=io.tacplus.looper.owner=m1 -a" ps -a
bargv "container ls --filter label=io.tacplus.looper.owner=m1" container ls
brefused "not this child's container" kill theirs
brefused "not this child's container" rm -f mine theirs
brefused "not this child's container" exec theirs sh
brefused "not this child's container" inspect theirs
brefused "outside this child's own directories" cp mine:/out /etc/out
brefused "is not for a looper's model" exec --privileged mine sh
pass

NAME=broker-commands
bargv "pull -q alpine:3" pull -q alpine:3
bargv "image inspect alpine" image inspect alpine
bargv "build -t x -f src/Dockerfile src" build -t x -f src/Dockerfile src
brefused "outside this child's own directories" build "$TMP/elsewhere"
brefused "reaches beyond the build's own context" build --secret id=a,src=/root/x .
brefused "reaches beyond the build's own context" build -o /tmp/out .
for c in "compose up" "buildx create" "volume create v" "network create n" "system prune -af" "login ghcr.io" "rmi alpine" "image rm alpine" "container prune"; do
  # shellcheck disable=SC2086
  brefused "is not for a looper's model" $c
done
pass

# The broker for real (root, as repo-looper runs it): a model's user calls it;
# the stub docker runs as the broker's user, with the model's stdin and
# output, and its exit status comes back. A user the broker was not told of
# is refused, and so is the socket itself to a model's user.
NAME=broker-users
if [[ "$(id -u)" != 0 ]] || ! command -v setpriv useradd python3 >/dev/null; then echo "skip $NAME: not root, or no setpriv, useradd or python3"
else
  u_m="lpdt-m$$" u_x="lpdt-x$$" u_b="lpdt-b$$"
  for u in "$u_m" "$u_x" "$u_b"; do useradd -M -N -s /bin/bash -d / "$u"; done
  trap '[[ -z "${BROKER:-}" ]] || kill "$BROKER" 2>/dev/null; for u in "$u_m" "$u_x" "$u_b"; do userdel "$u" 2>/dev/null; done; rm -rf "$TMP"' EXIT
  chmod 755 "$TMP" "$TMP/shim" "$TMP/real"; mkdir -p "$TMP/conf" "$TMP/sock"; chown "$u_m" "$TMP/wt"; chown "$u_b" "$TMP/sock"
  cat > "$TMP/real/docker" <<'EOF2'
#!/usr/bin/env bash
echo "as $(id -un): $*"; cat; echo "err" >&2; [[ "$1" != fail ]] || exit 7
EOF2
  printf 'owner=%s\nroots=%s\nmemory=1g\n' "$u_m" "$TMP/wt" > "$TMP/conf/$(id -u "$u_m")"
  setpriv --reuid "$u_b" --regid "$(id -g "$u_b")" --init-groups env -i PATH="$PATH" HOME=/ python3 -I "$ROOT/looper-docker-broker" serve "$TMP/sock/s" "$TMP/conf" "$TMP/real/docker" & BROKER=$!
  for _ in $(seq 50); do [[ -S "$TMP/sock/s" ]] && break; sleep 0.1; done
  as() { local u="$1"; shift; ( cd "$TMP/wt" && setpriv --reuid "$u" --regid "$(id -g "$u")" --init-groups env -i PATH="$TMP/shim:/usr/bin:/bin" LOOPER_DOCKER_BROKER="$TMP/sock/s" "$@" ); }
  out="$(echo hello | as "$u_m" docker run --rm -i img 2>"$TMP/err")" || fail "exit $?: $(cat "$TMP/err")"
  [[ "$out" == "as $u_b: run --memory 1g --memory-swap 1g --label io.tacplus.looper.owner=$u_m --rm -i img"$'\n'hello ]] || fail "out: $out"
  [[ "$(cat "$TMP/err")" == err ]] || fail "stderr: $(cat "$TMP/err")"
  rc=0; as "$u_m" docker fail </dev/null >/dev/null 2>&1 || rc=$?; (( rc == 125 )) || fail "a refused command: exit $rc"
  rc=0; as "$u_m" docker run -v /etc:/e img </dev/null >/dev/null 2>"$TMP/err" || rc=$?
  (( rc == 125 )) && grep -q "outside this child's own directories" "$TMP/err" || fail "a mount outside: exit $rc: $(cat "$TMP/err")"
  rc=0; as "$u_x" docker ps </dev/null >/dev/null 2>"$TMP/err" || rc=$?
  (( rc == 125 )) && grep -q "no looper model's" "$TMP/err" || fail "an unknown user: exit $rc: $(cat "$TMP/err")"
  if [[ -S /var/run/docker.sock ]]; then
    ! as "$u_m" test -r /var/run/docker.sock -o -w /var/run/docker.sock || fail "a model's user reaches the docker socket"
    if command -v docker >/dev/null && docker info >/dev/null 2>&1; then
      ! as "$u_m" "$(command -v docker)" info >/dev/null 2>&1 || fail "a model's user runs the real docker"
    fi
  fi
  kill "$BROKER"; wait "$BROKER" 2>/dev/null || true; BROKER=""
  # With a docker daemon: the real docker, as the broker's user in the socket's group, the
  # model's stdin and output its own. (The daemon is the host's: this test's paths are not, so no mount.)
  rd="$(command -v docker || true)" img="${LOOPER_TEST_IMAGE:-alpine:3}"
  if [[ -n "$rd" && -S /var/run/docker.sock ]] && docker info >/dev/null 2>&1 && { docker image inspect "$img" >/dev/null 2>&1 || docker pull -q "$img" >/dev/null 2>&1; }; then
    printf 'owner=%s\nroots=%s\nmemory=64m\n' "$u_m" "$TMP/wt" > "$TMP/conf/$(id -u "$u_m")"
    rm -f "$TMP/sock/s"
    setpriv --reuid "$u_b" --regid "$(id -g "$u_b")" --groups "$(stat -c %g /var/run/docker.sock)" env -i PATH="$PATH" HOME=/ \
      python3 -I "$ROOT/looper-docker-broker" serve "$TMP/sock/s" "$TMP/conf" "$rd" & BROKER=$!
    for _ in $(seq 50); do [[ -S "$TMP/sock/s" ]] && break; sleep 0.1; done
    out="$(echo hi | as "$u_m" docker run --rm -i "$img" sh -c 'cat; echo there' 2>"$TMP/err")" || fail "the real docker: $(cat "$TMP/err")"
    [[ "$out" == $'hi\nthere' ]] || fail "the real docker: $out"
    rc=0; as "$u_m" docker run --rm -v /etc:/e "$img" true </dev/null 2>"$TMP/err" || rc=$?
    (( rc == 125 )) || fail "the real docker mounted /etc: exit $rc"
    kill "$BROKER"; wait "$BROKER" 2>/dev/null || true; BROKER=""
  else
    echo "skip $NAME (the real docker): no docker daemon or $img"
  fi
  pass
fi

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
