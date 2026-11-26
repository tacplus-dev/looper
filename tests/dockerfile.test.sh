#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# The looper image's own Dockerfile (looper#258): its base, the tacplus build
# image, is a literal ref pinned by digest by default (looper#234: immutable
# bases only), so looper-scan finds no unpinned FROM and the nightly relock
# reads it and moves it (to its line's newest dated build); and the image's
# tacplus line is the base image's own (its TACPLUS_LINE), written nowhere
# else, so the line it says and the line it is built on cannot drift apart.
# Run: tests/dockerfile.test.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DF="${DOCKERFILE_TEST_FILE:-$ROOT/Dockerfile}"
NAME=""
fail() { echo "FAIL $NAME: $*" >&2; exit 1; }
pass() { echo "ok $NAME"; }

# The FROMs as looper-scan and the relock read them (one program in both).
eval "$(sed -n "/^DOCKERFILE_FROMS_AWK='/,/^}'\$/p" "$ROOT/looper-scan")"
[[ -n "${DOCKERFILE_FROMS_AWK:-}" ]] || { echo "FAIL: looper-scan has no DOCKERFILE_FROMS_AWK" >&2; exit 1; }
[[ "$DOCKERFILE_FROMS_AWK" == "$(sed -n "/^DOCKERFILE_FROMS_AWK='/,/^}'\$/p" "$ROOT/repo-looper" | sed "1s/^DOCKERFILE_FROMS_AWK='//; \$s/'\$//")" ]] ||
  { echo "FAIL: looper-scan and repo-looper read FROMs differently" >&2; exit 1; }
froms="$(awk "$DOCKERFILE_FROMS_AWK" "$DF")"

NAME="every FROM of the Dockerfile is pinned by digest: looper-scan reports no unpinned-from"
[[ -n "$froms" ]] || fail "no FROM read"
while IFS=$'\t' read -r fl _ _ ref _; do
  [[ "$ref" == *@sha256:* ]] || fail "Dockerfile:$fl: FROM $ref"
done <<<"$froms"
pass

NAME="the base is BUILD_IMAGE's default, a literal ref the relock reads (no ARG in it)"
base="$(awk -F '\t' '$5 == "BUILD_IMAGE"' <<<"$froms" | head -n 1)"
[[ -n "$base" ]] || fail "no FROM \${BUILD_IMAGE} with a default: $froms"
IFS=$'\t' read -r _ pl raw ref _ <<<"$base"
[[ "$raw" == "$ref" ]] || fail "Dockerfile:$pl: $raw is built of ARGs ($ref)"
pass

NAME="BUILD_IMAGE is the tacplus build image at a line's tag, a patch's or a dated build's, by digest"
[[ "$ref" =~ ^ghcr\.io/tacplus-dev/tacplus/build:([0-9]+\.[0-9]+|[0-9]+\.[0-9]+\.[0-9]+|[0-9]{8}-[0-9a-f]{7,40})@sha256:[0-9a-f]{64}$ ]] ||
  fail "Dockerfile:$pl: $ref"
pass

NAME="the image's tacplus line is its base's TACPLUS_LINE, written nowhere else"
! grep -nE '^[[:space:]]*ARG[[:space:]].*\bTACPLUS_LINE\b' "$DF" || fail "an ARG TACPLUS_LINE can drift from BUILD_IMAGE's line"
grep -qE '^ENV .*\bLOOPER_TACPLUS_LINE=\$\{TACPLUS_LINE\}( |$)' "$DF" || fail "LOOPER_TACPLUS_LINE is not the base's TACPLUS_LINE"
grep -qF 'test -n "${TACPLUS_LINE:-}"' "$DF" || fail "the build does not fail on a base that names no TACPLUS_LINE"
pass
