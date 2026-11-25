#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# looper-vm (looper#238): the parent never blocks (a report or a list that
# hangs holds up nothing), SIGTERM stops the whole tree within 25 seconds,
# each report given its checkpoint, the idle exit, the cache discarded when it
# is bad and never waited on, and two local builds at once sharing the cache.
# A stub repo-looper plays the reports and the list ($FIX/ready, a number a
# line); a stub docker plays the container socket, running looper-build in
# the "container" with the environment it was given. repo-looper's own side
# (its list's orphans, a report's checkpoint on SIGTERM, its resume with no
# disk, the shared git store) is tests/repo-looper.test.sh's.
# Run: tests/looper-vm.test.sh
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/hermetic.sh"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
cleanup() { [[ -z "${VM:-}" ]] || kill_tree "$VM"; rm -rf "$TMP"; }
trap cleanup EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
mkdir -p "$TMP/bin"

# The stub looper-token: `start report DIR PID` writes gh's configuration in DIR
# and records the call; $FIX/no-token refuses it.
cat > "$TMP/bin/looper-token" <<'EOF'
#!/usr/bin/env bash
[[ "$1 $2" == "start report" && ! -e "$FIX/no-token" ]] || { echo "stub looper-token: refused $*" >&2; exit 1; }
mkdir -p "$3"; echo "github.com: {oauth_token: stub}" > "$3/hosts.yml"; echo "token $2 $3" >> "$FIX/calls"; echo 0
EOF
chmod +x "$TMP/bin/looper-token"

# The stub repo-looper: --list prints $FIX/ready (or hangs, with $FIX/list-hang);
# --issue N records its start and runs $FIX/issue-N.sh (default: until $FIX/end-N).
cat > "$TMP/bin/repo-looper" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$3" in
  --list) echo "list gh=${GH_CONFIG_DIR:-none}" >> "$FIX/calls"; [[ ! -e "$FIX/list-hang" ]] || { sleep 1000 & wait; }; cat "$FIX/ready" 2>/dev/null || true ;;
  --issue)
    n="$4"; echo "start $n $$ vm=${LOOPER_VM:+set} work=$LOOPER_WORK store=$LOOPER_GIT_STORE" >> "$FIX/calls"
    if [[ -f "$FIX/issue-$n.sh" ]]; then source "$FIX/issue-$n.sh"
    else until [[ -e "$FIX/end-$n" ]]; do sleep 0.2; done; fi ;;
esac
EOF
chmod +x "$TMP/bin/repo-looper"

fail() { echo "FAIL $NAME: $*" >&2; for f in "$FIX/vm.out" "$FIX/calls"; do [[ -f "$f" ]] && { echo "--- $f" >&2; cat "$f" >&2; }; done; exit 1; }
pass() { echo "ok $NAME"; }
has() { grep -qF -- "$2" <<<"$1" || fail "expected \"$2\" in: $1"; }
kill_tree() { local c; for c in $(pgrep -P "$1" 2>/dev/null); do kill_tree "$c"; done; kill -KILL "$1" 2>/dev/null || true; }
fixture() { # name
  NAME="$1"; FIX="$TMP/$1"; mkdir -p "$FIX"; : > "$FIX/calls"; : > "$FIX/ready"
}
# The parent in the background: VM its pid, its output in $FIX/vm.out.
vm() { # [VAR=value...]
  env FIX="$FIX" CLAUDE_CODE_OAUTH_TOKEN=test-token LOOPER_TOKEN="$TMP/bin/looper-token" LOOPER_VM_REPO_LOOPER="$TMP/bin/repo-looper" LOOPER_CACHE="$FIX/cache" LOOPER_VM_POLL=1 \
    LOOPER_VM_COOLDOWN=1000 "$@" "$ROOT/looper-vm" --repo alpha > "$FIX/vm.out" 2>&1 & VM=$!
}
# Waits, at most 20 seconds, for a command to succeed.
until_true() { # what command...
  local what="$1" i; shift
  for (( i = 0; i < 200; i++ )); do "$@" && return 0; sleep 0.1; done
  fail "not within 20s: $what"
}
started() { grep -q "^start $1 " "$FIX/calls"; } # issue
running() { grep -q "^$1 " "$FIX/cache/vm/running" 2>/dev/null; } # issue
not_running() { [[ -f "$FIX/cache/vm/running" ]] && ! grep -q "^$1 " "$FIX/cache/vm/running"; } # issue

# --- the parent never blocks ----------------------------------------------------
# Issues 1 and 2 start at once and never end; 3, ready later, starts beside
# them. A list that hangs then holds up nothing: 2 ends and is reaped, and the
# parent's passes go on (it records each). Each report gets the VM's mode,
# the cache's work directory and the shared git store.
fixture never-blocks
printf '1\n2\n' > "$FIX/ready"
vm
until_true "1 and 2 started" eval 'started 1 && started 2'
echo 3 >> "$FIX/ready"
until_true "3 started beside 1 and 2" started 3
running 1 && running 2 || fail "1 and 2 no longer run: $(cat "$FIX/cache/vm/running")"
touch "$FIX/list-hang"; sleep 1.5   # the next list hangs
touch "$FIX/end-2"
until_true "2 reaped while the list hangs" not_running 2
running 1 && running 3 || fail "1 and 3: $(cat "$FIX/cache/vm/running")"
has "$(cat "$FIX/vm.out")" "#2: its report ended (exit 0)"
has "$(cat "$FIX/calls")" "start 1 "; has "$(cat "$FIX/calls")" "vm=set work=$FIX/cache/work store=$FIX/cache/git/alpha.git"
(( $(grep -c '^start 1 ' "$FIX/calls") == 1 )) || fail "1 started more than once: $(cat "$FIX/calls")"
kill_tree "$VM"; wait "$VM" 2>/dev/null || true; VM=""
pass

# --- SIGTERM: the tree stopped within 25 seconds --------------------------------
# Report 1 checkpoints on SIGTERM (2 seconds) and exits; report 2 has
# children of its own, one in a session of its own and one under timeout (a
# process group of its own); report 3 ignores SIGTERM. The parent exits 0
# within 25 seconds of the signal, report 1's checkpoint made, and nothing of
# the tree is left.
# The lister runs as the parent's GitHub identity (the report app's token,
# kept by looper-token start; repo-looper mints none for --list), and a VM
# with no token stops at once, saying so.
fixture list-identity
printf '1\n' > "$FIX/ready"
vm
until_true "1 started" started 1
grep -q "^token report $FIX/cache/vm/gh\$" "$FIX/calls" || fail "no report token for the lister: $(cat "$FIX/calls")"
grep -q "^list gh=$FIX/cache/vm/gh\$" "$FIX/calls" || fail "the lister has no GH_CONFIG_DIR: $(cat "$FIX/calls")"
kill_tree "$VM"; wait "$VM" 2>/dev/null || true; VM=""
pass
fixture list-identity-refused
touch "$FIX/no-token"
vm
until_true "the VM stops without a token" eval '! kill -0 "$VM" 2>/dev/null'
has "$(cat "$FIX/vm.out")" "no report token for the lister"
grep -q '^list' "$FIX/calls" 2>/dev/null && fail "it listed without a token: $(cat "$FIX/calls")"
VM=""
pass

fixture sigterm
printf '1\n2\n3\n' > "$FIX/ready"
cat > "$FIX/issue-1.sh" <<'EOF'
trap 'sleep 2; echo "checkpointed 1" >> "$FIX/checkpoints"; exit 0' TERM
sleep 1000 & wait
EOF
cat > "$FIX/issue-2.sh" <<'EOF'
setsid sleep 1001 & echo $! >> "$FIX/tree"
timeout 1000 sleep 1002 & echo $! >> "$FIX/tree"
bash -c 'sleep 1003 & echo $! >> "$FIX/tree"; wait' &
wait
EOF
cat > "$FIX/issue-3.sh" <<'EOF'
trap '' TERM
while :; do sleep 0.2; done
EOF
vm
until_true "1, 2 and 3 started" eval 'started 1 && started 2 && started 3 && [[ $(wc -l < "$FIX/tree" 2>/dev/null || echo 0) == 3 ]]'
sleep 0.5
t0=$(date +%s%N)
kill -TERM "$VM"; rc=0; wait "$VM" || rc=$?; VM=""
ms=$(( ($(date +%s%N) - t0) / 1000000 ))
(( rc == 0 )) || fail "exited $rc"
(( ms < 25000 )) || fail "exited ${ms}ms after SIGTERM, not within 25s"
(( ms >= 2000 )) || fail "exited ${ms}ms after SIGTERM: before report 1's checkpoint"
[[ "$(cat "$FIX/checkpoints" 2>/dev/null)" == "checkpointed 1" ]] || fail "report 1 did not checkpoint"
for p in $(cat "$FIX/tree") $(sed -n 's/^start [0-9]* \([0-9]*\) .*/\1/p' "$FIX/calls"); do
  ! kill -0 "$p" 2>/dev/null || fail "pid $p of the tree still runs ($(ps -o args= -p "$p"))"
done
out="$(cat "$FIX/vm.out")"
has "$out" "SIGTERM: stopping 3 report(s)"; has "$out" "killing what still runs 22s after SIGTERM: report(s) 3"
pass

# --- idle exit ---------------------------------------------------------------------
# No ready issue and no report: exit 0 once the idle time is up. A report
# running is never idle: the parent waits for it to end, the list empty.
fixture idle
vm LOOPER_VM_IDLE_MINUTES=0
rc=0; wait "$VM" || rc=$?; VM=""
(( rc == 0 )) || fail "exited $rc"
has "$(cat "$FIX/vm.out")" "idle: no report running and no ready issue in alpha"
pass

fixture idle-not-while-working
echo 1 > "$FIX/ready"
vm LOOPER_VM_IDLE_MINUTES=0
until_true "1 started" started 1
: > "$FIX/ready"; sleep 2
kill -0 "$VM" 2>/dev/null || fail "exited with report 1 running"
touch "$FIX/end-1"
rc=0; wait "$VM" || rc=$?; VM=""
(( rc == 0 )) || fail "exited $rc"
has "$(cat "$FIX/vm.out")" "idle: no report running"
pass

# --- the cache: discarded when bad, never waited on ---------------------------------
# A cache with no stamp (another layout, half-written) is moved aside and
# emptied; a git store git cannot read is discarded on its own; a cache
# that cannot be written is left for a local one. The parent goes on at once.
fixture cache-bad
mkdir -p "$FIX/cache/junk" "$FIX/cache/git/alpha.git"; echo stale > "$FIX/cache/junk/x"
vm LOOPER_VM_IDLE_MINUTES=0
rc=0; wait "$VM" || rc=$?; VM=""
(( rc == 0 )) || fail "exited $rc"
out="$(cat "$FIX/vm.out")"
has "$out" "the cache $FIX/cache/junk is discarded: no stamp"
[[ "$(cat "$FIX/cache/.looper-vm")" == "looper-vm cache 1" ]] || fail "no stamp"
[[ ! -e "$FIX/cache/junk" ]] || fail "junk kept"
for d in git work builds vm deps/go/mod deps/cargo/registry deps/npm; do [[ -d "$FIX/cache/$d" ]] || fail "no $d"; done
# Stamped now: a store git cannot read is discarded, the rest kept.
mkdir -p "$FIX/cache/git/alpha.git/objects"; echo kept > "$FIX/cache/work/kept"
vm LOOPER_VM_IDLE_MINUTES=0
wait "$VM" || fail "exited $?"; VM=""
has "$(cat "$FIX/vm.out")" "the cache $FIX/cache/git/alpha.git is discarded: git cannot read it"
[[ "$(cat "$FIX/cache/work/kept")" == kept ]] || fail "a good cache's work was not kept"
pass

fixture cache-unwritable
vm LOOPER_VM_IDLE_MINUTES=0 LOOPER_CACHE=/dev/null/cache LOOPER_VM_LOCAL_CACHE="$FIX/local"
wait "$VM" || fail "exited $?"; VM=""
has "$(cat "$FIX/vm.out")" "the cache /dev/null/cache cannot be written: a local one instead"
[[ -f "$FIX/local/.looper-vm" ]] || fail "no local cache"
pass

# --- local builds, two at once, sharing the cache -----------------------------------
# The stub docker runs the "container" here: its -e variables set, in its -w
# directory; every argument recorded, one run a line.
cat > "$TMP/bin/docker" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  pull) exit 0 ;;
  image) echo "PATH=/usr/bin"; echo "CARGO_HOME=/usr/local/cargo"; exit 0 ;;
  run)
    echo "$*" >> "$FIX/docker-runs"; shift
    vars=() wd=""
    while [[ "$1" == -* ]]; do
      case "$1" in -e) vars+=("$2") ;; -w) wd="$2" ;; esac
      [[ "$1" == --rm ]] && { shift; continue; }
      shift 2
    done
    shift   # the image
    cd "$wd" && exec env -i PATH="$PATH" HOME="$HOME" FIX="$FIX" "${vars[@]}" "$@" ;;
esac
EOF
chmod +x "$TMP/bin/docker"
fixture build-shared
git init -q -b main "$FIX/clone"
printf 'build_image: ghcr.io/tacplus-dev/build:1.0.0@sha256:%s\n' "$(printf 'b%.0s' {1..64})" > "$FIX/clone/build.lock"
cat > "$FIX/clone/gates.yaml" <<'EOF'
full:
  run: 'echo "gates of $(git rev-parse --short HEAD) in $PWD; GOMODCACHE=$GOMODCACHE"; sleep 1; echo "$(cat state)" >> "$GOMODCACHE/seen"; [ "$(cat state)" = green ]'
EOF
echo green > "$FIX/clone/state"; git -C "$FIX/clone" add -A; git -C "$FIX/clone" commit -qm green; green="$(git -C "$FIX/clone" rev-parse HEAD)"
echo red > "$FIX/clone/state"; git -C "$FIX/clone" commit -qam red; red="$(git -C "$FIX/clone" rev-parse HEAD)"
lb() { # sha log
  env FIX="$FIX" PATH="$TMP/bin:$PATH" LOOPER_CACHE="$FIX/cache" "$ROOT/looper-vm" build --repo alpha --dir "$FIX/clone" --sha "$1" --log "$2"
}
mkdir -p "$FIX/cache"
lb "$green" "$FIX/green.log" & g=$!
lb "$red" "$FIX/red.log" & r=$!
grc=0; wait "$g" || grc=$?; rrc=0; wait "$r" || rrc=$?
(( grc == 0 )) || { cat "$FIX/green.log"; fail "the green build exited $grc"; }
(( rrc == 1 )) || { cat "$FIX/red.log"; fail "the red build exited $rrc"; }
gl="$(cat "$FIX/green.log")"; rl="$(cat "$FIX/red.log")"
has "$gl" "local build of alpha ${green:0:7}, the gates full, in ghcr.io/tacplus-dev/build:1.0.0@sha256:"
has "$gl" "gates of ${green:0:7} in $FIX/cache/builds/alpha-"; has "$gl" "verdict: success: the gates full passed"
has "$rl" "gates of ${red:0:7}"; has "$rl" "verdict: failure: fail: the gates full (gates.yaml) exited 1"
# One cache: both mounted it at its own path, with the same dependency caches.
[[ "$(sort -u "$FIX/cache/deps/go/mod/seen" | tr '\n' ' ')" == "green red " ]] || fail "the shared module cache saw: $(cat "$FIX/cache/deps/go/mod/seen" 2>/dev/null)"
(( $(grep -c -- "-v $FIX/cache:$FIX/cache .*-e GOMODCACHE=$FIX/cache/deps/go/mod" "$FIX/docker-runs") == 2 )) || fail "runs: $(cat "$FIX/docker-runs")"
(( $(grep -c -- "-v $FIX/cache/deps/cargo/registry:/usr/local/cargo/registry" "$FIX/docker-runs") == 2 )) || fail "cargo: $(cat "$FIX/docker-runs")"
# Each its own checkout, removed after.
[[ -z "$(ls -A "$FIX/cache/builds")" ]] || fail "builds left: $(ls "$FIX/cache/builds")"
# A commit that pins no image builds nothing.
git -C "$FIX/clone" rm -q build.lock; git -C "$FIX/clone" commit -qm unpinned
rc=0; lb "$(git -C "$FIX/clone" rev-parse HEAD)" "$FIX/none.log" || rc=$?
(( rc == 1 )) || fail "unpinned exited $rc"
has "$(cat "$FIX/none.log")" "verdict: failure: alpha pins no build image"
pass

# A cache at another path on the host (LOOPER_CACHE_HOST) is mounted from there.
fixture build-host-path
git init -q -b main "$FIX/clone"
printf 'build_image: ghcr.io/tacplus-dev/build:1.0.0@sha256:%s\n' "$(printf 'b%.0s' {1..64})" > "$FIX/clone/build.lock"
printf 'full:\n  run: "true"\n' > "$FIX/clone/gates.yaml"
git -C "$FIX/clone" add -A; git -C "$FIX/clone" commit -qm c
env FIX="$FIX" PATH="$TMP/bin:$PATH" LOOPER_CACHE="$FIX/cache" LOOPER_CACHE_HOST=/mnt/disks/cache "$ROOT/looper-vm" build --repo alpha \
  --dir "$FIX/clone" --sha "$(git -C "$FIX/clone" rev-parse HEAD)" --log "$FIX/b.log" || fail "exited $?: $(cat "$FIX/b.log")"
has "$(cat "$FIX/docker-runs")" "-v /mnt/disks/cache:$FIX/cache -v /mnt/disks/cache/deps/cargo/registry:/usr/local/cargo/registry"
pass
