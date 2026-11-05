#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# looper-ruleset (looper#83): apply puts the ruleset "main: only the manager"
# on each public repository and skips the private ones, saying why; it sends
# exactly the rules and bypass actors wanted; it is idempotent (a second run
# makes no write), and puts a drifted ruleset back; check passes after apply
# and fails on drift. A stub `gh` keeps each repository's rulesets in files, as
# GitHub would, and records every call. probe: a contents API write the stub
# refuses and a push a local origin's pre-receive hook refuses pass; both
# accepted fail, loudly. No network.
# Run: tests/looper-ruleset.test.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# $FIX/repos.json: the org's repositories ({name, visibility}). Each
# repository's rulesets are $FIX/rulesets/<repo>/<id>.json, with the fields
# GitHub adds (id, source, source_type, node_id, current_user_can_bypass,
# _links, created_at), bypass_actors' OrganizationAdmin actor_id as 1, and
# the update rule's parameters without update_allows_fetch_and_merge when it
# is false, its default, which GitHub does not return (looper#96).
# Every call is appended to $FIX/gh ("<METHOD> <path>"), every write's body
# to $FIX/bodies. The contents API: $FIX/refuse-contents refuses a write as a
# ruleset does (HTTP 409); an accepted one is $FIX/contents/<repo>.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
out() { if [[ -n "$q" ]]; then jq -r "$q"; else cat; fi; }
if [[ "$1 $2" == "repo list" ]]; then
  q=""; while [[ $# -gt 0 ]]; do [[ "$1" != --jq ]] || q="$2"; shift; done
  echo "GET repo list" >> "$FIX/gh"; out < "$FIX/repos.json"; exit 0
fi
[[ "$1" == api ]] || { echo "stub gh: unexpected $*" >&2; exit 3; }
shift; m=GET; path=""; q=""; input=""; fields=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -X) m="$2"; shift 2 ;; --jq) q="$2"; shift 2 ;; --input) input="$2"; shift 2 ;;
    -f) fields+=("$2"); shift 2 ;; *) path="$1"; shift ;;
  esac
done
echo "$m $path" >> "$FIX/gh"
body=""; [[ -z "$input" ]] || { body="$(cat)"; printf '%s %s %s\n' "$m" "$path" "$(jq -c . <<<"$body")" >> "$FIX/bodies"; }
store() { # file body id
  jq --argjson id "$3" '. + {id: $id, source: "tacplus-dev/x", source_type: "Repository", node_id: "RRS_x",
       current_user_can_bypass: "always", created_at: "2026-11-04T00:00:00Z", _links: {self: {href: "x"}}}
     | .bypass_actors |= map(if .actor_type == "OrganizationAdmin" then .actor_id = 1 else . end)
     | .rules |= map(if .parameters == null then del(.parameters) else . end
                     | if .parameters.update_allows_fetch_and_merge == false then .parameters = {} else . end)' <<<"$2" > "$1"
}
case "$m $path" in
  "GET user") echo '{"login":"jody"}' | out ;;
  "GET users/jody") echo '{"login":"jody","id":4242}' | out ;;
  GET\ repos/*/rulesets\?includes_parents=false)
    r="${path#repos/*/}"; r="${r%%/*}"; mkdir -p "$FIX/rulesets/$r"
    { ls "$FIX/rulesets/$r"/*.json >/dev/null 2>&1 && jq -s 'map({id, name, target, enforcement})' "$FIX/rulesets/$r"/*.json || echo '[]'; } | out ;;
  GET\ repos/*/rulesets/*)
    r="${path#repos/*/}"; r="${r%%/*}"; f="$FIX/rulesets/$r/${path##*/}.json"
    [[ -f "$f" ]] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }; out < "$f" ;;
  POST\ repos/*/rulesets)
    r="${path#repos/*/}"; r="${r%%/*}"; mkdir -p "$FIX/rulesets/$r"; id="$(( $(cat "$FIX/next-id") + 1 ))"; echo "$id" > "$FIX/next-id"
    store "$FIX/rulesets/$r/$id.json" "$body" "$id"; out < "$FIX/rulesets/$r/$id.json" ;;
  PUT\ repos/*/rulesets/*)
    r="${path#repos/*/}"; r="${r%%/*}"; id="${path##*/}"
    store "$FIX/rulesets/$r/$id.json" "$body" "$id"; out < "$FIX/rulesets/$r/$id.json" ;;
  GET\ repos/*/contents/*)
    r="${path#repos/*/}"; r="${r%%/*}"
    [[ -f "$FIX/contents/$r" ]] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }; echo '{}' ;;
  PUT\ repos/*/contents/*)
    r="${path#repos/*/}"; r="${r%%/*}"; printf '%s\n' "${fields[@]}" > "$FIX/contents-put"
    if [[ -e "$FIX/refuse-contents" ]]; then
      echo '{"message":"Repository rule violations found\n\nCannot update this protected ref.\n\n","status":"409"}'
      echo "gh: Repository rule violations found (HTTP 409)" >&2; exit 1
    fi
    mkdir -p "$FIX/contents"; touch "$FIX/contents/$r"; echo '{"content":{"sha":"abc123"},"commit":{"sha":"def"}}' ;;
  DELETE\ repos/*/contents/*)
    r="${path#repos/*/}"; r="${r%%/*}"; printf '%s\n' "${fields[@]}" > "$FIX/contents-delete"; rm -f "$FIX/contents/$r"; echo '{}' ;;
  *) echo "stub gh: unexpected $m $path" >&2; exit 3 ;;
esac
EOF
chmod +x "$TMP/bin/gh"

NAME=""
fail() { echo "FAIL $NAME: $*" >&2; for f in "$FIX/err" "$FIX/gh"; do [[ -f "$f" ]] && { echo "--- $f" >&2; cat "$f" >&2; }; done; exit 1; }
pass() { echo "ok $NAME"; }
scenario() { # name
  NAME="$1"; FIX="$TMP/$1"; mkdir -p "$FIX/rulesets"; echo 100 > "$FIX/next-id"
  echo '[{"name":"kernel","visibility":"PUBLIC"},{"name":"looper","visibility":"PUBLIC"},
         {"name":"fleet-dev","visibility":"PRIVATE"},{"name":"fleet-seatrials","visibility":"PRIVATE"}]' > "$FIX/repos.json"
}
ruleset() { # args...: exit status kept
  env LOOPER_LIB="$ROOT/looper-lib.sh" PATH="$TMP/bin:$PATH" FIX="$FIX" LOOPER_ORG=tacplus-dev GH_TOKEN=tok \
    LOOPER_MANAGER_APP_ID="${APP_ID-777}" "$ROOT/looper-ruleset" "$@"
}
writes() { grep -cE '^(POST|PUT|DELETE) ' "$FIX/gh" || true; }

WANT_RULES='[{"type":"deletion"},{"type":"non_fast_forward"},{"parameters":{"update_allows_fetch_and_merge":false},"type":"update"}]'
WANT_ACTORS='[{"actor_id":777,"actor_type":"Integration","bypass_mode":"always"},{"actor_id":4242,"actor_type":"User","bypass_mode":"always"}]'

# The first apply creates the ruleset on kernel and looper, skips fleet-dev
# and fleet-seatrials with the reason, and sends exactly what is wanted: main,
# active, update/non_fast_forward/deletion, the manager App and Jody's account
# (User), no RepositoryRole.
scenario apply-creates
ruleset apply >"$FIX/out" 2>"$FIX/err" || fail "apply failed"
[[ "$(grep -c '^POST repos/tacplus-dev/[a-z]*/rulesets ' "$FIX/bodies")" == 2 ]] || fail "creates: $(cat "$FIX/bodies")"
grep -q '^POST repos/tacplus-dev/kernel/rulesets ' "$FIX/bodies" && grep -q '^POST repos/tacplus-dev/looper/rulesets ' "$FIX/bodies" || fail "not on both public repositories"
! grep -q fleet "$FIX/gh" || fail "called the API for a private repository: $(cat "$FIX/gh")"
for r in fleet-dev fleet-seatrials; do grep -q "tacplus-dev/$r: skipped, private: rulesets on a private repository need GitHub Team" "$FIX/out" || fail "$r not logged: $(cat "$FIX/out")"; done
grep -q 'tacplus-dev/kernel: created' "$FIX/out" || fail "log: $(cat "$FIX/out")"
B="$(grep '^POST repos/tacplus-dev/kernel/rulesets ' "$FIX/bodies" | cut -d' ' -f3-)"
[[ "$(jq -c '.rules | sort_by(.type) | map(to_entries | sort_by(.key) | from_entries)' <<<"$B")" == "$WANT_RULES" ]] || fail "rules: $B"
[[ "$(jq -c '.bypass_actors | sort_by(.actor_type) | map(to_entries | sort_by(.key) | from_entries)' <<<"$B")" == "$WANT_ACTORS" ]] || fail "actors: $B"
! jq -e '.bypass_actors[] | select(.actor_type == "RepositoryRole")' <<<"$B" >/dev/null || fail "a RepositoryRole bypasses: $B"
[[ "$(jq -c '[.name, .target, .enforcement, .conditions]' <<<"$B")" == '["main: only the manager (looper#83)","branch","active",{"ref_name":{"include":["refs/heads/main"],"exclude":[]}}]' ]] \
  || fail "ruleset: $B"
grep -q 'bypass: the manager App (777) and jody (4242, User)' "$FIX/err" || fail "the bypass actors not logged: $(cat "$FIX/err")"

# Idempotent: a second apply against what GitHub now holds makes no write,
# though GitHub omits update_allows_fetch_and_merge: false (looper#96).
[[ "$(jq -c '.rules[] | select(.type == "update") | .parameters' "$FIX/rulesets/kernel/"*.json)" == '{}' ]] || fail "the stub kept the default"
: > "$FIX/gh"
ruleset apply >"$FIX/out" 2>"$FIX/err" || fail "second apply failed"
[[ "$(writes)" == 0 ]] || fail "the second apply wrote: $(cat "$FIX/gh")"
[[ "$(grep -c ': unchanged$' "$FIX/out")" == 2 ]] || fail "log: $(cat "$FIX/out")"
ruleset check >"$FIX/out" 2>"$FIX/err" || fail "check failed after apply: $(cat "$FIX/out")"
[[ "$(cat "$FIX/out")" == $'kernel ok\nlooper ok\nfleet-dev skipped (private)\nfleet-seatrials skipped (private)' ]] || fail "check: $(cat "$FIX/out")"
[[ "$(writes)" == 0 ]] || fail "check wrote"
pass

# Drift: kernel's ruleset lost its deletion rule, looper's gained a
# RepositoryRole admin bypass. check fails naming both; apply puts both back
# with PUT on the same ruleset, and the next check passes.
scenario apply-drift
ruleset apply >/dev/null 2>&1 || fail "apply failed"
K="$(ls "$FIX/rulesets/kernel/"*.json)"; L="$(ls "$FIX/rulesets/looper/"*.json)"
jq '.rules |= map(select(.type != "deletion"))' "$K" > "$FIX/t" && mv "$FIX/t" "$K"
jq '.bypass_actors += [{"actor_id":5,"actor_type":"RepositoryRole","bypass_mode":"always"}]' "$L" > "$FIX/t" && mv "$FIX/t" "$L"
: > "$FIX/gh"
! ruleset check >"$FIX/out" 2>"$FIX/err" || fail "check passed on drift"
grep -qx 'kernel differs (ruleset [0-9]*)' "$FIX/out" && grep -qx 'looper differs (ruleset [0-9]*)' "$FIX/out" || fail "check: $(cat "$FIX/out")"
grep -q 'not the manager.s alone in: kernel looper' "$FIX/err" || fail "check log: $(cat "$FIX/err")"
ruleset apply looper >"$FIX/out" 2>"$FIX/err" || fail "apply looper failed"
[[ "$(writes)" == 1 ]] && grep -qx "PUT repos/tacplus-dev/looper/rulesets/$(basename "$L" .json)" "$FIX/gh" || fail "looper not put back alone: $(cat "$FIX/gh")"
ruleset apply >"$FIX/out" 2>"$FIX/err" || fail "apply failed"
[[ "$(writes)" == 2 ]] && grep -qx "PUT repos/tacplus-dev/kernel/rulesets/$(basename "$K" .json)" "$FIX/gh" || fail "kernel not put back: $(cat "$FIX/gh")"
grep -q 'tacplus-dev/kernel: updated' "$FIX/out" && grep -q 'tacplus-dev/looper: unchanged' "$FIX/out" || fail "log: $(cat "$FIX/out")"
ruleset check >/dev/null 2>&1 || fail "check failed after the fix"
[[ "$(ls "$FIX/rulesets/kernel" | wc -l)" == 1 ]] || fail "a second ruleset was created"
pass

# Only the default is dropped: update_allows_fetch_and_merge true differs.
scenario apply-fetch-and-merge
ruleset apply kernel >/dev/null 2>&1 || fail "apply failed"
K="$(ls "$FIX/rulesets/kernel/"*.json)"
jq '(.rules[] | select(.type == "update") | .parameters) = {update_allows_fetch_and_merge: true}' "$K" > "$FIX/t" && mv "$FIX/t" "$K"
! ruleset check kernel >"$FIX/out" 2>"$FIX/err" || fail "check passed with fetch-and-merge allowed"
grep -qx 'kernel differs (ruleset [0-9]*)' "$FIX/out" || fail "check: $(cat "$FIX/out")"
pass

# A ruleset of another name is not ours: left alone, ours created beside it.
# A repository the org has not is fatal.
scenario apply-other-ruleset
mkdir -p "$FIX/rulesets/kernel"
echo '{"id":5,"name":"tags","target":"tag","enforcement":"active","rules":[{"type":"deletion"}]}' > "$FIX/rulesets/kernel/5.json"
ruleset apply kernel >/dev/null 2>"$FIX/err" || fail "apply failed"
grep -qx 'POST repos/tacplus-dev/kernel/rulesets' "$FIX/gh" && ! grep -q '^PUT' "$FIX/gh" || fail "calls: $(cat "$FIX/gh")"
[[ "$(jq -c .rules "$FIX/rulesets/kernel/5.json")" == '[{"type":"deletion"}]' ]] || fail "the other ruleset changed"
! ruleset apply nosuch >/dev/null 2>"$FIX/err" || fail "applied to a repository the org has not"
grep -q 'nosuch: not a non-archived repository' "$FIX/err" || fail "log: $(cat "$FIX/err")"
pass

# LOOPER_RULESET_OWNER=org-admins: the org's owners (OrganizationAdmin)
# instead of Jody's User; GitHub's actor_id 1 for it compares equal.
scenario apply-org-admins
LOOPER_RULESET_OWNER=org-admins ruleset apply kernel >/dev/null 2>"$FIX/err" || fail "apply failed"
jq -e '.bypass_actors | map(.actor_type) | sort == ["Integration","OrganizationAdmin"]' <<<"$(cut -d' ' -f3- "$FIX/bodies")" >/dev/null || fail "actors: $(cat "$FIX/bodies")"
: > "$FIX/gh"
LOOPER_RULESET_OWNER=org-admins ruleset apply kernel >/dev/null 2>"$FIX/err" || fail "second apply failed"
[[ "$(writes)" == 0 ]] || fail "not idempotent: $(cat "$FIX/gh")"
pass

# Without LOOPER_MANAGER_APP_ID apply and check die before any call.
scenario no-app-id
rc=0; APP_ID="" ruleset apply >/dev/null 2>"$FIX/err" || rc=$?
[[ "$rc" == 2 ]] && grep -q 'LOOPER_MANAGER_APP_ID' "$FIX/err" || fail "rc $rc: $(cat "$FIX/err")"
[[ ! -s "$FIX/gh" ]] || fail "called gh: $(cat "$FIX/gh")"
! APP_ID="" ruleset check >/dev/null 2>&1 || fail "check without the App id passed"
pass

# probe: an origin (LOOPER_GITHUB_URL a directory) whose main a pre-receive
# hook refuses as GitHub's ruleset does, or accepts.
origin() { # refuse|accept
  local o="$FIX/github/tacplus-dev/kernel.git" w="$FIX/work"
  git init -q --bare -b main "$o"
  git init -q -b main "$w"
  git -C "$w" -c user.name=t -c user.email=t@t commit -q --allow-empty -m base
  git -C "$w" push -q "$o" main
  if [[ "$1" == refuse ]]; then
    printf '#!/bin/sh\nwhile read o n r; do [ "$r" != refs/heads/main ] || { echo "error: GH013: Repository rule violations found for refs/heads/main." >&2; exit 1; }; done\n' > "$o/hooks/pre-receive"
    chmod +x "$o/hooks/pre-receive"
  fi
  git -C "$o" rev-parse main
}
probe() { LOOPER_GITHUB_URL="$FIX/github" ruleset probe kernel; }

scenario probe-refused
BASE="$(origin refuse)"; touch "$FIX/refuse-contents"
probe >"$FIX/out" 2>"$FIX/err" || fail "probe failed: $(cat "$FIX/out")"
grep -q 'contents API write to main was refused' "$FIX/out" && grep -q 'git push to main was refused' "$FIX/out" || fail "log: $(cat "$FIX/out")"
grep -q "main is the manager's alone" "$FIX/out" || fail "log: $(cat "$FIX/out")"
[[ "$(git -C "$FIX/github/tacplus-dev/kernel.git" rev-parse main)" == "$BASE" ]] || fail "main moved"
grep -qx 'branch=main' "$FIX/contents-put" && grep -q '^message=.*should have been refused' "$FIX/contents-put" || fail "write: $(cat "$FIX/contents-put")"
! grep -q '^DELETE' "$FIX/gh" || fail "deleted a file it did not write"
pass

scenario probe-accepted
BASE="$(origin accept)"
rc=0; probe >"$FIX/out" 2>"$FIX/err" || rc=$?
[[ "$rc" == 1 ]] || fail "rc $rc"
grep -q 'MAIN IS NOT PROTECTED in tacplus-dev/kernel: a contents API write to main was accepted' "$FIX/err" || fail "log: $(cat "$FIX/err")"
grep -q 'MAIN IS NOT PROTECTED in tacplus-dev/kernel: a git push to main' "$FIX/err" || fail "log: $(cat "$FIX/err")"
grep -qx 'sha=abc123' "$FIX/contents-delete" && [[ ! -e "$FIX/contents/kernel" ]] || fail "the probe file not deleted"
M="$(git -C "$FIX/github/tacplus-dev/kernel.git" log -1 --format='%P %s' main)"
[[ "$M" == "$BASE looper-ruleset probe (looper#83): this write to main should have been refused" ]] || fail "pushed: $M"
pass

# A refusal that is not a rule's (a token that cannot write at all) proves
# nothing: inconclusive, exit 2, and the push is not tried.
scenario probe-inconclusive
origin refuse >/dev/null
cat > "$TMP/bin/gh-wrap" <<'EOF'
#!/usr/bin/env bash
[[ "$*" != *"-X PUT repos/tacplus-dev/kernel/contents/"* ]] || { echo "gh: Resource not accessible by integration (HTTP 403)" >&2; exit 1; }
exec "$(dirname "$0")/gh.real" "$@"
EOF
mkdir -p "$FIX/bin"; cp "$TMP/bin/gh" "$FIX/bin/gh.real"; cp "$TMP/bin/gh-wrap" "$FIX/bin/gh"; chmod +x "$FIX/bin/gh"
rc=0; env LOOPER_LIB="$ROOT/looper-lib.sh" PATH="$FIX/bin:$PATH" FIX="$FIX" LOOPER_ORG=tacplus-dev GH_TOKEN=tok \
  LOOPER_GITHUB_URL="$FIX/github" "$ROOT/looper-ruleset" probe kernel >"$FIX/out" 2>"$FIX/err" || rc=$?
[[ "$rc" == 2 ]] && grep -q 'inconclusive' "$FIX/err" || fail "rc $rc: $(cat "$FIX/err")"
pass

echo "looper-ruleset: all scenarios pass"
