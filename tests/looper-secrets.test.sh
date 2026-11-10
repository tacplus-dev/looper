#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# The repository's own secret scan (looper#117): the build's security-looper
# job runs gitleaks on the commit's tree (looper-scan's tool_gitleaks), and a
# secret fails it. This runs the same scan on the checkout's tracked files, so
# a fixture shaped like a token (a test's fake glpat-, ghp_ or generic key)
# fails the gates before it fails main's build. A planted key shows the scan
# finds one; the tree itself has none. A fake token a test needs is built at
# run time ("glpat-$(printf ...)"), never written as a literal.
# Run: tests/looper-secrets.test.sh
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/hermetic.sh"   # the test's own environment, not the job's (looper#97, looper#103)
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL $NAME: $*" >&2; exit 1; }
pass() { echo "ok $NAME"; }

command -v gitleaks >/dev/null || { echo "FAIL: no gitleaks (the looper image has it)" >&2; exit 1; }

# The tree as the build checks it out: the tracked files, as they are in the checkout.
TREE="$TMP/tree"; mkdir -p "$TREE"
git -C "$ROOT" ls-files -z | (cd "$ROOT" && xargs -0 cp --parents -t "$TREE" 2>/dev/null) ||
  { echo "FAIL: the tracked files cannot be copied" >&2; exit 1; }

# The findings of looper-scan's gitleaks run on a tree, one "file:rule:line" each.
leaks() { # tree
  local raw="$TMP/gitleaks.json"
  gitleaks dir --no-banner --redact --exit-code 0 -f json -r "$raw" "$1" >/dev/null 2>"$TMP/gitleaks.log" ||
    fail "gitleaks: $(tail -1 "$TMP/gitleaks.log")"
  jq -r --arg root "$1" '.[] | (.File | ltrimstr($root + "/")) as $f | select($f | startswith(".git/") | not)
    | "\($f):\(.RuleID):\(.StartLine)"' "$raw"
}

NAME=planted
mkdir -p "$TMP/planted"; printf 'aws_access_key_id = %s\n' "AKIA""QYLPMN5HHHFPZAM2" > "$TMP/planted/env.txt"
grep -qx 'env.txt:aws-access-token:1' <<<"$(leaks "$TMP/planted")" || fail "the planted key is not found: $(leaks "$TMP/planted")"
pass

NAME=tree
OUT="$(leaks "$TREE")"
[[ -z "$OUT" ]] || fail "secrets the build's security job fails: $(tr '\n' ' ' <<<"$OUT")"
pass
