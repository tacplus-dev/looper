#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# looper-vm (looper#238): the parent never blocks (a report or a list that
# hangs holds up nothing), SIGTERM stops the whole tree within 25 seconds,
# each report given its checkpoint, the idle exit, the cache discarded when it
# is bad and never waited on, and two local builds at once sharing the cache;
# the merger's machine (looper#251): a pass of each repository's merge
# requests, one at a time, as the merger's identity, until SIGTERM.
# A stub repo-looper plays the reports and the list ($FIX/ready, a number a
# line); a stub docker plays the container socket, running looper-build in
# the "container" with the environment it was given. repo-looper's own side
# (its list's orphans, a report's checkpoint on SIGTERM, its resume with no
# disk, the shared git store) is tests/repo-looper.test.sh's. A rolling check
# machine (looper#249) runs a stub looper-check per repository.
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
[[ "$1" == start && "$2" =~ ^(report|check|merger)$ && ! -e "$FIX/no-token" ]] || { echo "stub looper-token: refused $*" >&2; exit 1; }
# As the real one: with no id_token it signs only on a VM (LOOPER_VM).
[[ -n "${LOOPER_VM:-}" ]] || { echo "stub looper-token: no id_token and no LOOPER_VM" >&2; exit 1; }
mkdir -p "$3"; echo "github.com: {oauth_token: stub}" > "$3/hosts.yml"; echo "token $2 $3" >> "$FIX/calls"; echo 0
EOF
chmod +x "$TMP/bin/looper-token"

# The stub repo-looper: --list prints $FIX/ready-REPO, else $FIX/ready (or hangs, with $FIX/list-hang);
# --issue N records its start and runs $FIX/issue-N.sh (default: until $FIX/end-N).
cat > "$TMP/bin/repo-looper" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$3" in
  --list) echo "list gh=${GH_CONFIG_DIR:-none}" >> "$FIX/calls"; [[ ! -e "$FIX/list-hang" ]] || { sleep 1000 & wait; }
          if [[ -f "$FIX/ready-$2" ]]; then cat "$FIX/ready-$2"; else cat "$FIX/ready" 2>/dev/null || true; fi ;;
  --issue)
    n="$4"; echo "start $n $$ repo=$2 vm=${LOOPER_VM:+set} work=$LOOPER_WORK store=$LOOPER_GIT_STORE" >> "$FIX/calls"
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
# The parent in the background: VM its pid, its output in $FIX/vm.out; its
# arguments ARGS (default --repo alpha).
ARGS=(--repo alpha)
vm() { # [VAR=value...]
  env FIX="$FIX" CLAUDE_CODE_OAUTH_TOKEN=test-token LOOPER_TOKEN="$TMP/bin/looper-token" LOOPER_VM_REPO_LOOPER="$TMP/bin/repo-looper" LOOPER_CACHE="$FIX/cache" LOOPER_VM_POLL=1 LOOPER_VM_LIST_EVERY=0 \
    LOOPER_VM_COOLDOWN=1000 "$@" "$ROOT/looper-vm" "${ARGS[@]}" > "$FIX/vm.out" 2>&1 & VM=$!
}
# Waits, at most 20 seconds, for a command to succeed.
until_true() { # what command...
  local what="$1" i; shift
  for (( i = 0; i < 200; i++ )); do "$@" && return 0; sleep 0.1; done
  fail "not within 20s: $what"
}
started() { grep -q "^start $1 " "$FIX/calls"; } # issue
running() { grep -q "^alpha#$1 " "$FIX/cache/vm/running" 2>/dev/null; } # issue
not_running() { [[ -f "$FIX/cache/vm/running" ]] && ! grep -q "^alpha#$1 " "$FIX/cache/vm/running"; } # issue

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

# --- an org's shared VM (decision point 12) ------------------------------------
# One parent works several repositories: --org lists the org's repositories
# with an approved issue (one search, the stub gh's $FIX/org), less --except's,
# and each one's ready issues; a report runs per REPO#N, with that
# repository's store. A repository whose list fails costs only its own issues.
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
[[ "$1 $2" == "search issues" ]] || exit 1
echo "gh $*" >> "$FIX/calls"
[[ ! -e "$FIX/gh-fails" ]] || exit 1
cat "$FIX/org"
EOF
chmod +x "$TMP/bin/gh"
fixture org
printf 'alpha\nbeta\ngamma\nbeta\n' > "$FIX/org"
echo 3 > "$FIX/ready-beta"; echo 5 > "$FIX/ready-gamma"; echo 9 > "$FIX/ready-alpha"
ARGS=(--org tacplus-dev --except alpha)
vm PATH="$TMP/bin:$PATH"
until_true "beta#3 and gamma#5 started" eval 'grep -q "^start 3 .* repo=beta " "$FIX/calls" && grep -q "^start 5 .* repo=gamma " "$FIX/calls"'
grep -q '^start 9 ' "$FIX/calls" && fail "alpha, on its own VM, was worked"
has "$(cat "$FIX/calls")" "repo=beta vm=set work=$FIX/cache/work store=$FIX/cache/git/beta.git"
has "$(cat "$FIX/calls")" "gh search issues --owner tacplus-dev --state open --label approved"
has "$(cat "$FIX/vm.out")" "looper-vm of tacplus-dev (but alpha)"
grep -q '^beta#3 ' "$FIX/cache/vm/running" && grep -q '^gamma#5 ' "$FIX/cache/vm/running" || fail "running: $(cat "$FIX/cache/vm/running")"
kill_tree "$VM"; wait "$VM" 2>/dev/null || true; VM=""
pass
fixture org-search-fails
touch "$FIX/gh-fails"; printf 'beta\n' > "$FIX/org"; echo 3 > "$FIX/ready-beta"
ARGS=(--org tacplus-dev)
vm PATH="$TMP/bin:$PATH" LOOPER_VM_IDLE_MINUTES=0
rc=0; wait "$VM" || rc=$?; VM=""
(( rc == 0 )) || fail "exited $rc"
grep -q '^start ' "$FIX/calls" && fail "started a report with no list"
has "$(cat "$FIX/vm.out")" "the list of tacplus-dev failed"
pass
fixture org-args
for a in "--org tacplus-dev --repo alpha" "--repo alpha --except beta" "--org bad/org"; do
  # shellcheck disable=SC2206
  ARGS=($a); vm
  rc=0; wait "$VM" || rc=$?; VM=""
  (( rc == 2 )) || fail "$a: exited $rc"
done
ARGS=(--repo alpha)
pass

# --- a list every LOOPER_VM_LIST_EVERY, not every pass (looper#256) -------------
# The passes go on each second; the forge is listed once in the interval, so
# an issue ready later waits for the next list, and the installation's API
# limit is not spent on lists.
fixture list-every
echo 1 > "$FIX/ready"
vm LOOPER_VM_LIST_EVERY=1000
until_true "1 started" started 1
echo 2 >> "$FIX/ready"; sleep 4
started 2 && fail "2 started before the next list was due"
(( $(grep -c '^list ' "$FIX/calls") == 1 )) || fail "listed more than once in the interval: $(grep -c '^list ' "$FIX/calls")"
kill -0 "$VM" 2>/dev/null || fail "the parent stopped"
kill_tree "$VM"; wait "$VM" 2>/dev/null || true; VM=""
pass

# --- the merger's machine (looper#251, tacplus-dev/cloud#111) -------------------
# No model, no container socket: every LOOPER_MERGER_POLL seconds one
# `looper-merger pass` per repository with an open merge request into main
# (one search, --except's left out), one at a time, as the merger's token, with
# the machine's settings (it is given none). A pass that fails or hangs costs
# its own repository's turn; SIGTERM stops it at once (it holds no state).
cat > "$TMP/bin/looper-merger" <<'EOF'
#!/usr/bin/env bash
echo "merger $* gh=${GH_CONFIG_DIR:-none} org=$LOOPER_ORG key=$LOOPER_MERGER_KEY app=$LOOPER_MERGER_APP_ID trusted=$LOOPER_MERGER_TRUSTED check=$LOOPER_CHECK_LOGIN dir=$LOOPER_MERGER_DIR model=${CLAUDE_CODE_OAUTH_TOKEN:-none}" >> "$FIX/calls"
[[ ! -e "$FIX/merger-hang-$3" ]] || { echo $$ > "$FIX/merger-pid"; sleep 1000 & wait; }
[[ ! -e "$FIX/merger-fails-$3" ]] || { echo "could not read $3" >&2; exit 2; }
EOF
chmod +x "$TMP/bin/looper-merger"
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in "search issues"|"search prs") ;; *) exit 1 ;; esac
echo "gh $*" >> "$FIX/calls"
[[ ! -e "$FIX/gh-fails" ]] || exit 1
if [[ "$2" == prs ]]; then cat "$FIX/prs"; else cat "$FIX/org"; fi
EOF
merger_vm() { # [VAR=value...]
  env -u CLAUDE_CODE_OAUTH_TOKEN FIX="$FIX" PATH="$TMP/bin:$PATH" LOOPER_TOKEN="$TMP/bin/looper-token" LOOPER_VM_MERGER="$TMP/bin/looper-merger" \
    LOOPER_CACHE="$FIX/cache" LOOPER_MERGER_POLL=1 "$@" "$ROOT/looper-vm" merger "${ARGS[@]}" > "$FIX/vm.out" 2>&1 & VM=$!
}
passes() { grep -c "^merger pass --repo $1 " "$FIX/calls" || true; } # repo
fixture merger-org
printf 'beta\ngamma\nalpha\nbeta\n' > "$FIX/prs"; touch "$FIX/merger-fails-beta"
ARGS=(--org tacplus-dev --except alpha)
merger_vm
until_true "two passes each of beta and gamma" eval '(( $(passes beta) >= 2 && $(passes gamma) >= 2 ))'
(( $(passes alpha) == 0 )) || fail "alpha, --except'd, was passed"
c="$(cat "$FIX/calls")"
has "$c" "gh search prs --owner tacplus-dev --state open --base main"
has "$c" "token merger $FIX/cache/vm/gh"
has "$c" "merger pass --repo gamma gh=$FIX/cache/vm/gh org=tacplus-dev key=tacplus-manager app=5632100 trusted=tacplus-reader[bot] check=tacplus-manager[bot] dir=$FIX/cache/merger model=none"
has "$(cat "$FIX/vm.out")" "beta: the merger's pass failed (exit 2): could not read beta"
grep -q "token report" <<<"$c" && fail "the merger minted a report's token"
kill -TERM "$VM"; rc=0; wait "$VM" || rc=$?; VM=""
(( rc == 0 )) || fail "SIGTERM: exited $rc"
pass

# Its settings are the deployment's to change; --repo passes only those named, with no search.
fixture merger-repo
ARGS=(--repo alpha)
merger_vm LOOPER_MERGER_KEY=tacplus-merger LOOPER_MERGER_APP_ID=7 LOOPER_MERGER_TRUSTED=x LOOPER_CHECK_LOGIN=y
until_true "two passes of alpha" eval '(( $(passes alpha) >= 2 ))'
grep -q "^gh " "$FIX/calls" && fail "searched with --repo"
has "$(cat "$FIX/calls")" "key=tacplus-merger app=7 trusted=x check=y"
kill -TERM "$VM"; wait "$VM" || true; VM=""
pass

# SIGTERM while a pass hangs: out at once, the pass with it.
fixture merger-sigterm
touch "$FIX/merger-hang-alpha"
ARGS=(--repo alpha)
merger_vm
until_true "the pass started" test -s "$FIX/merger-pid"
t0=$SECONDS; kill -TERM "$VM"; rc=0; wait "$VM" || rc=$?; VM=""
(( rc == 0 && SECONDS - t0 <= 5 )) || fail "exited $rc after $((SECONDS - t0))s"
until_true "the pass stopped" eval '! kill -0 "$(cat "$FIX/merger-pid")" 2>/dev/null'
pass

fixture merger-no-identity
touch "$FIX/no-token"; ARGS=(--repo alpha)
merger_vm
rc=0; wait "$VM" || rc=$?; VM=""
(( rc == 2 )) || fail "exited $rc with no token"
grep -q "^merger " "$FIX/calls" && fail "passed with no identity"
has "$(cat "$FIX/vm.out")" "no merger token"
ARGS=(--repo alpha)
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
has "$out" "SIGTERM: stopping 3 report(s)"; has "$out" "killing what still runs 22s after SIGTERM: report(s) alpha#3"
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
    vars=() wd="" detached=""
    while [[ "$1" == -* ]]; do
      case "$1" in -e) vars+=("$2") ;; -w) wd="$2" ;; -d) detached=1 ;; esac
      [[ "$1" == --rm || "$1" == -d || "$1" == --privileged ]] && { shift; continue; }
      shift 2
    done
    [[ -z "$detached" ]] || { echo "c0ffee"; exit 0; }   # the build's dockerd: up, unless dind-down
    shift   # the image
    cd "$wd" && exec env -i PATH="$PATH" HOME="$HOME" FIX="$FIX" "${vars[@]}" "$@" ;;
  exec) echo "$*" >> "$FIX/docker-execs"; [[ ! -e "$FIX/dind-down" ]] ;;
  logs) echo "dockerd: the stub's last words" ;;
  rm) echo "$*" >> "$FIX/docker-rms" ;;
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
# Its dockerd mounts the cache from there too.
grep -q -- "^run -d --privileged .* -v /mnt/disks/cache:$FIX/cache docker:" "$FIX/docker-runs" || fail "dockerd's mount: $(cat "$FIX/docker-runs")"
pass

# A build's own container runtime (looper#267): a gate that builds and runs
# images (tacplus's images set) gets DOCKER_HOST, a dockerd of the build's own
# in a privileged sidecar (so --security-opt seccomp=unconfined and
# apparmor=unconfined are allowed), its socket and data root under the build's
# directory and the cache at its own path, as the gates see it; the sidecar is
# removed with the build. One that does not answer builds nothing, said;
# LOOPER_VM_DIND_IMAGE empty gives none.
fixture build-runtime
git init -q -b main "$FIX/clone"
printf 'build_image: ghcr.io/tacplus-dev/build:1.0.0@sha256:%s\n' "$(printf 'b%.0s' {1..64})" > "$FIX/clone/build.lock"
printf 'full:\n  run: '"'"'echo "DOCKER_HOST=${DOCKER_HOST:-none}"; touch "$FIX/gated"'"'"'\n' > "$FIX/clone/gates.yaml"
git -C "$FIX/clone" add -A; git -C "$FIX/clone" commit -qm c; c="$(git -C "$FIX/clone" rev-parse HEAD)"
rb() { # log env...
  local l="$1"; shift
  env FIX="$FIX" PATH="$TMP/bin:$PATH" LOOPER_CACHE="$FIX/cache" "$@" "$ROOT/looper-vm" build --repo alpha --dir "$FIX/clone" --sha "$c" --log "$l"
}
rb "$FIX/rt.log" || fail "exited $?: $(cat "$FIX/rt.log")"
l="$(cat "$FIX/rt.log")"; runs="$(cat "$FIX/docker-runs")"
b="$(sed -n 's|^DOCKER_HOST=unix://\(.*\)/docker/docker.sock$|\1|p' <<<"$l")"
[[ "$b" == "$FIX/cache/builds/alpha-"* ]] || fail "the gates' DOCKER_HOST: $l"
has "$l" "its own container runtime: dockerd in docker:29.10.1-dind@sha256:"
has "$l" "verdict: success: the gates full passed"
side="$(grep -- '^run -d ' "$FIX/docker-runs")" || fail "no dockerd started: $runs"
has "$side" "run -d --privileged --name looper-vm-alpha-${c:0:12}-"
has "$side" "-v $FIX/cache:$FIX/cache docker:29.10.1-dind@sha256:"
has "$side" "dockerd --host=unix://$b/docker/docker.sock --data-root $b/docker/root"
grep -q "^exec looper-vm-alpha-${c:0:12}-[0-9]*-docker docker --host unix://$b/docker/docker.sock version" "$FIX/docker-execs" || fail "not waited for: $(cat "$FIX/docker-execs")"
grep -q "^rm -f -v looper-vm-alpha-${c:0:12}-[0-9]*-docker$" "$FIX/docker-rms" || fail "the sidecar left: $(cat "$FIX/docker-rms" 2>/dev/null)"
[[ -z "$(ls -A "$FIX/cache/builds")" ]] || fail "builds left: $(ls "$FIX/cache/builds")"
# A dockerd that never answers: nothing built, said, the sidecar removed.
rm -f "$FIX/docker-rms" "$FIX/gated"; touch "$FIX/dind-down"
rc=0; rb "$FIX/down.log" LOOPER_VM_DIND_WAIT=2 || rc=$?
(( rc == 1 )) || fail "a runtime that never answers: exited $rc: $(cat "$FIX/down.log")"
has "$(cat "$FIX/down.log")" "verdict: failure: its container runtime (dockerd in docker:29.10.1-dind@sha256:"
has "$(cat "$FIX/down.log")" "did not answer within 2s: nothing built"
has "$(cat "$FIX/down.log")" "dockerd: the stub's last words"
[[ ! -e "$FIX/gated" ]] || fail "the gates ran with no runtime"
grep -q -- "-docker$" "$FIX/docker-rms" || fail "the dead sidecar left"
# LOOPER_VM_DIND_IMAGE empty: no runtime, as before.
rm -f "$FIX/dind-down" "$FIX/docker-runs"
rb "$FIX/none.log" LOOPER_VM_DIND_IMAGE= || fail "exited $?: $(cat "$FIX/none.log")"
has "$(cat "$FIX/none.log")" "DOCKER_HOST=none"
! grep -q -- '^run -d ' "$FIX/docker-runs" || fail "a dockerd with LOOPER_VM_DIND_IMAGE empty"
pass

# --- build slots (looper#248) --------------------------------------------------------
# LOOPER_VM_BUILDS=2 and three builds at once: two run, the third waits and
# says so in its log, first come first served; the parent's pass logs the
# builds running and waiting and the longest wait, and names the one that
# waits. Once one ends the third takes its slot, saying how long it waited.
fixture build-slots
git init -q -b main "$FIX/clone"
printf 'build_image: ghcr.io/tacplus-dev/build:1.0.0@sha256:%s\n' "$(printf 'b%.0s' {1..64})" > "$FIX/clone/build.lock"
cat > "$FIX/clone/gates.yaml" <<'EOF'
full:
  run: 'n=$(cat n); echo "gates of $n"; touch "$FIX/ran-$n"; until [ -e "$FIX/release-$n" ]; do sleep 0.1; done'
EOF
for n in 1 2 3; do echo "$n" > "$FIX/clone/n"; git -C "$FIX/clone" add -A; git -C "$FIX/clone" commit -qm "$n"; sha[n]="$(git -C "$FIX/clone" rev-parse HEAD)"; done
SLOTS=(LOOPER_VM_BUILDS=2)
vm PATH="$TMP/bin:$PATH" "${SLOTS[@]}"
until_true "the parent's cache" test -f "$FIX/cache/.looper-vm"
slot_build() { # n
  env FIX="$FIX" PATH="$TMP/bin:$PATH" LOOPER_CACHE="$FIX/cache" "${SLOTS[@]}" "$ROOT/looper-vm" build --repo alpha --issue "$1" \
    --dir "$FIX/clone" --sha "${sha[$1]}" --log "$FIX/b$1.log"
}
slot_build 1 & b1=$!
until_true "build 1 runs" test -e "$FIX/ran-1"
slot_build 2 & b2=$!
until_true "build 2 runs" test -e "$FIX/ran-2"
slot_build 3 & b3=$!
until_true "build 3 waits" grep -qs "waiting for a build slot" "$FIX/b3.log"
sleep 1.5
[[ ! -e "$FIX/ran-3" ]] || fail "build 3 ran beside 1 and 2"
has "$(cat "$FIX/b3.log")" "waiting for a build slot: all 2 of this looper VM's (LOOPER_VM_BUILDS) are taken: alpha#1 ${sha[1]:0:7}, alpha#2 ${sha[2]:0:7}"
until_true "the parent counts it" grep -q "builds: 2 running, 1 waiting (the longest for [1-9][0-9]*s), of 2 slots" "$FIX/vm.out"
has "$(cat "$FIX/vm.out")" "alpha#3: its local build of ${sha[3]:0:7} waits for a build slot (2 of 2 run)"
touch "$FIX/release-2"; wait "$b2" || fail "build 2 exited $?"
until_true "build 3 takes 2's slot" test -e "$FIX/ran-3"
grep -q "^took build slot [12] of 2 after [1-9][0-9]*s waiting" "$FIX/b3.log" || fail "build 3: $(cat "$FIX/b3.log")"
grep -q "^build slot 1 of 2 (LOOPER_VM_BUILDS)" "$FIX/b1.log" || fail "build 1: $(cat "$FIX/b1.log")"
until_true "the parent sees it" grep -q "builds: 2 running, 0 waiting, of 2 slots" "$FIX/vm.out"
touch "$FIX/release-1" "$FIX/release-3"; wait "$b1" || fail "build 1 exited $?"; wait "$b3" || fail "build 3 exited $?"
has "$(cat "$FIX/b3.log")" "verdict: success: the gates full passed"
until_true "the parent sees none" grep -q "builds: 0 running, 0 waiting, of 2 slots" "$FIX/vm.out"
[[ -z "$(ls "$FIX/cache/vm/slots" | grep -v '^slot-')" ]] || fail "markers left: $(ls "$FIX/cache/vm/slots")"
kill_tree "$VM"; wait "$VM" 2>/dev/null || true; VM=""
# A build killed outright leaves its marker: no slot is held by it (its lock
# went with it), and the parent drops the marker.
slot_build 1 & b1=$!
until_true "build 1 runs again" eval '[[ -n "$(ls "$FIX/cache/vm/slots" | grep "^run-")" ]]'
kill_tree "$b1"; wait "$b1" 2>/dev/null || true
vm PATH="$TMP/bin:$PATH" "${SLOTS[@]}"
until_true "the dead build's marker dropped" eval '[[ -z "$(ls "$FIX/cache/vm/slots" | grep -v "^slot-")" ]]'
kill_tree "$VM"; wait "$VM" 2>/dev/null || true; VM=""
# One waiting build an issue: issue 2's newer request takes the place of its
# build that still waits (which ends, saying why) and keeps its place in the
# queue, ahead of issue 3's that came later.
rm -f "$FIX"/release-* "$FIX"/ran-*
SLOTS=(LOOPER_VM_BUILDS=1)
slot_build 1 & b1=$!
until_true "build 1 runs alone" test -e "$FIX/ran-1"
slot_build 2 & b2=$!
until_true "issue 2's build waits" grep -qs "waiting for a build slot" "$FIX/b2.log"
sleep 1.1
slot_build 3 & b3=$!
until_true "issue 3's build waits" grep -qs "waiting for a build slot" "$FIX/b3.log"
sleep 1.1
env FIX="$FIX" PATH="$TMP/bin:$PATH" LOOPER_CACHE="$FIX/cache" "${SLOTS[@]}" "$ROOT/looper-vm" build --repo alpha --issue 2 \
  --dir "$FIX/clone" --sha "${sha[3]}" --log "$FIX/b4.log" & b4=$!
rc=0; wait "$b2" || rc=$?
(( rc == 143 )) || fail "issue 2's older build exited $rc: $(cat "$FIX/b2.log")"
has "$(cat "$FIX/b2.log")" "verdict: failure: ended before its gates ran"
until_true "the newer one says whose place it took" grep -qs "took the place of alpha#2's waiting build of ${sha[2]:0:7}" "$FIX/b4.log"
[[ "$(ls "$FIX/cache/vm/slots" | grep -c '^wait-')" == 2 ]] || fail "waiting: $(ls "$FIX/cache/vm/slots")"
touch "$FIX/release-1"; wait "$b1" || fail "build 1 exited $?"
until_true "issue 2's newer build has the slot" grep -qs "^took build slot 1 of 1 after" "$FIX/b4.log"
sleep 1.5
! grep -qs "^took build slot" "$FIX/b3.log" || fail "issue 3's build ran ahead of issue 2's place: $(cat "$FIX/b3.log")"
touch "$FIX/release-3"; wait "$b4" || fail "issue 2's newer build exited $?"; wait "$b3" || fail "build 3 exited $?"
[[ -z "$(ls "$FIX/cache/vm/slots" | grep -v '^slot-')" ]] || fail "markers left: $(ls "$FIX/cache/vm/slots")"
# A limit that is not a number stops the parent at once.
vm LOOPER_VM_BUILDS=x
rc=0; wait "$VM" || rc=$?; VM=""
(( rc == 2 )) || fail "LOOPER_VM_BUILDS=x: exited $rc"
has "$(cat "$FIX/vm.out")" "LOOPER_VM_BUILDS 'x' is not a number of builds"
pass

# --- a rolling check machine (looper#249) ------------------------------------------
# `looper-vm check --org`: a looper-check per repository of the org (gh repo
# list), less --except's, each with this machine's cache and builds, as the
# check's app, until it is idle (--until-idle); one that ends started again
# while another still checks; SIGTERM stops them all at once. Once every check
# ended idle the machine's ends, exit 0: it sizes itself to 0 (cloud#111).
cat > "$TMP/bin/looper-check" <<'EOF'
#!/usr/bin/env bash
echo "check $* vm=${LOOPER_VM:+set} dir=$LOOPER_CHECK_DIR build=$LOOPER_CHECK_BUILD gh=${GH_CONFIG_DIR:-none}" >> "$FIX/calls"
[[ "$3" == --until-idle ]] || { echo "stub looper-check: not --until-idle: $*" >&2; exit 3; }
[[ ! -e "$FIX/check-idle" ]] || exit 0
[[ ! -e "$FIX/check-exit-$2" ]] || { rm -f "$FIX/check-exit-$2"; exit 0; }
sleep 1000 & wait
EOF
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
[[ "$1 $2" == "repo list" ]] || exit 1
echo "gh $*" >> "$FIX/calls"
cat "$FIX/org"
EOF
chmod +x "$TMP/bin/looper-check" "$TMP/bin/gh"
fixture check-machine
printf 'tacplus\nlooper\ncloud\n' > "$FIX/org"; touch "$FIX/check-exit-cloud"
ARGS=(check --org tacplus-dev --except tacplus)
vm PATH="$TMP/bin:$PATH" LOOPER_VM_LOOPER_CHECK="$TMP/bin/looper-check" LOOPER_VM_CHECK_RESTART=1
until_true "looper and cloud checked, cloud again after it ended" eval '(( $(grep -c "^check --repo cloud " "$FIX/calls") >= 2 )) && grep -q "^check --repo looper " "$FIX/calls"'
grep -q '^check --repo tacplus ' "$FIX/calls" && fail "tacplus, on its own machine, was checked"
has "$(cat "$FIX/calls")" "gh repo list tacplus-dev --no-archived"
has "$(cat "$FIX/calls")" "token check $FIX/cache/vm/gh"
has "$(cat "$FIX/calls")" "check --repo looper --until-idle vm=set dir=$FIX/cache/check build=$ROOT/looper-vm build gh=$FIX/cache/vm/gh"
has "$(cat "$FIX/vm.out")" "cloud: its check ended (exit 0): started again in 1s"
grep -q "nothing to check" "$FIX/vm.out" && fail "the machine ended while looper's check ran"
(( $(grep -c '^check --repo looper ' "$FIX/calls") == 1 )) || fail "looper's check started twice"
t0=$(date +%s); kill -TERM "$VM"; rc=0; wait "$VM" || rc=$?; VM=""
(( rc == 0 && $(date +%s) - t0 < 25 )) || fail "SIGTERM: exit $rc after $(( $(date +%s) - t0 ))s"
sleep 0.5; ! pgrep -f "$TMP/bin/looper-check" >/dev/null || fail "a check outlived the machine's SIGTERM"
pass

# Every repository's check idle: the machine's check ends, exit 0.
fixture check-idle
printf 'looper\ncloud\n' > "$FIX/org"; touch "$FIX/check-idle"
ARGS=(check --org tacplus-dev)
vm PATH="$TMP/bin:$PATH" LOOPER_VM_LOOPER_CHECK="$TMP/bin/looper-check" LOOPER_VM_CHECK_RESTART=1
rc=0; timeout 60 tail --pid="$VM" -f /dev/null || fail "the idle machine did not end"
wait "$VM" || rc=$?; VM=""
(( rc == 0 )) || fail "the idle machine exited $rc: $(cat "$FIX/vm.out")"
has "$(cat "$FIX/vm.out")" "nothing to check in tacplus-dev"
(( $(grep -c '^check --repo looper ' "$FIX/calls") == 1 )) || fail "an idle check started again"
pass
