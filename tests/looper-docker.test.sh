#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# looper-docker and its broker are retired (looper#73): no model has a
# container runtime of its own, an unpinned repository's report and land stop
# at once, and a pinned one builds in a build job or a looper VM's local build.
# This test keeps them gone: neither script is in the tree, the image, its
# smoke or the gate map, and repo-looper starts neither. (Its name is the old
# test's, which .github/workflows/image.yml still runs: PROPOSALS.md.)
# Run: tests/looper-docker.test.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAME=""
fail() { echo "FAIL $NAME: $*" >&2; exit 1; }
pass() { echo "ok $NAME"; }

NAME="looper-docker and looper-docker-broker are not in the tree"
for f in looper-docker looper-docker-broker; do [[ ! -e "$ROOT/$f" ]] || fail "$f is back"; done
pass

NAME="the image neither copies nor smokes them"
! grep -nE '\blooper-docker(-broker)?\b' "$ROOT/Dockerfile" || fail "the Dockerfile names them"
! grep -nE '\blooper-docker(-broker)?\b' "$ROOT/looper-smoke" || fail "looper-smoke looks for them"
pass

NAME="the gate map names neither"
! grep -nE '/looper-docker(-broker)?([],[:space:]]|$)' "$ROOT/gates.yaml" || fail "gates.yaml maps them"
pass

NAME="repo-looper starts no broker and hands no model a socket of its own"
! grep -nE 'LOOPER_DOCKER_BROKER|LOOPER_REAL_DOCKER|LOOPER_CHILD_MEMORY|looper-docker-broker' "$ROOT/repo-looper" ||
  fail "repo-looper still wires the broker or its memory limit"
pass
