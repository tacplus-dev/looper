#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# looper-token (looper#83): a job's GitHub identity, an app's installation
# token through Workload Identity Federation and Cloud KMS, against a stub
# gcloud (it signs with a key only for the environments its binding names, as
# roles/cloudkms.signer bound to the provider's attribute does, reading the
# id_token on every call as a federated credential does) and a stub GitHub
# (it verifies each app's JWT against that app's public key). The report's
# token is gh's configuration, which gh reads; it is refreshed while its job
# lives and no longer; a job may not mint another role's token; an id_token
# that is not the project's protected main is refused. A refusal says why
# (looper#95): gcloud's own error, its class (the token exchange, the key's
# binding, a quota project, the key's path, gcloud's own usage) and the
# id_token's claims, never the token; `diagnose` gives the hub each key's answer.
# Run: tests/looper-token.test.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; kids=()
trap 'for k in "${kids[@]+"${kids[@]}"}"; do kill "$k" 2>/dev/null || true; done; rm -rf "$TMP"' EXIT
export TMP
# gh reads the token from GH_CONFIG_DIR only when no token is in its environment.
unset GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN

source "$ROOT/tests/github-app-stub.sh"
app_stub "$TMP"
APP_STUB="$TMP"   # each env -i below passes it

NAME=""
fail() { echo "FAIL $NAME: $*" >&2; [[ -f "$TMP/err" ]] && cat "$TMP/err" >&2; [[ -f "$TMP/api.log" ]] && cat "$TMP/api.log" >&2; exit 1; }
pass() { echo "ok $NAME"; }
tok() { # environment [VAR=value...] -- args
  local env="$1" e=(); shift; while [[ "$1" != -- ]]; do e+=("$1"); shift; done; shift
  : > "$TMP/api.log"
  env -i PATH="$TMP/bin:$PATH" HOME="$TMP" TMP="$TMP" APP_STUB="$TMP" TMPDIR="$TMP" STUB_RING="$RING" CI_PROJECT_PATH=tacplus-dev/looper \
    GCP_WIF_PROVIDER="$PROVIDER" LOOPER_KMS_KEYRING="$RING" LOOPER_TOKEN_REFRESH="${REFRESH:-2700}" \
    LOOPER_REPORT_APP_ID=301 LOOPER_REPORT_INSTALLATION_ID=31 LOOPER_MANAGER_APP_ID=401 LOOPER_MANAGER_INSTALLATION_ID=41 \
    GCP_ID_TOKEN="$(id_token "$env")" "${e[@]+"${e[@]}"}" "$ROOT/looper-token" "$@"
}

NAME=configured
tok looper-report -- configured || fail "not configured with LOOPER_REPORT_APP_ID"
! tok looper-report LOOPER_REPORT_APP_ID= -- configured || fail "configured without LOOPER_REPORT_APP_ID"
pass

# A report's token: its app, its permissions (no bypass of main's ruleset is
# GitHub's to enforce: the app is no bypass actor), as gh's configuration.
NAME=report-start
d="$TMP/report"; sleep 300 & job=$!; kids+=("$job")
pid="$(tok looper-report -- start report "$d" "$job" 2>"$TMP/err")" || fail "start failed"
kids+=("$pid")
grep -q '^token tacplus-looper ghs_looper_.* {"contents":"write","issues":"write","pull_requests":"write","metadata":"read"}$' "$TMP/api.log" ||
  fail "token: $(cat "$TMP/api.log")"
t1="$(awk '/^token / { print $3 }' "$TMP/api.log")"
[[ "$(env -u GH_TOKEN -u GITHUB_TOKEN GH_CONFIG_DIR="$d" gh auth token)" == "$t1" ]] || fail "gh does not read $d/hosts.yml"
printf 'protocol=https\nhost=github.com\n\n' | env -u GH_TOKEN -u GITHUB_TOKEN GH_CONFIG_DIR="$d" gh auth git-credential get | grep -qx "password=$t1" ||
  fail "git's credential is not the token"
[[ "$(stat -c %a "$d/gcloud")" == 700 ]] || fail "the gcloud configuration (the id_token) is $(stat -c %a "$d/gcloud"), not the job's alone"
grep -q "$t1" "$TMP/err" && fail "the token is in the log"
pass

# Fresh while its job lives: a new token replaces it; once the job's process
# ends, the refresher ends too.
NAME=refresh
d="$TMP/fresh"; sleep 300 & job=$!; kids+=("$job")
pid="$(REFRESH=1 tok looper-report -- start report "$d" "$job" 2>"$TMP/err")" || fail "start failed"
kids+=("$pid")
t1="$(GH_CONFIG_DIR="$d" gh auth token)"
for _ in $(seq 40); do t2="$(GH_CONFIG_DIR="$d" gh auth token)"; [[ "$t2" != "$t1" ]] && break; sleep 0.25; done
[[ "$t2" != "$t1" ]] || fail "the token was not refreshed"
kill "$job"
for _ in $(seq 40); do kill -0 "$pid" 2>/dev/null || break; sleep 0.25; done
! kill -0 "$pid" 2>/dev/null || fail "the refresher outlives its job"
pass

# The manager's app only for the environments its key's binding names: a
# report's job cannot mint the manager's token; a manager's and a scan's can.
NAME=roles
! tok looper-report -- mint manager >/dev/null 2>"$TMP/err" || fail "a report minted the manager's token"
grep -q 'kms-denied tacplus-manager looper-report' "$TMP/api.log" || fail "api: $(cat "$TMP/api.log")"
grep -q 'Cloud KMS refused this job the key tacplus-manager: its signer binding does not name' "$TMP/err" &&
  grep -q "gcloud: .*PERMISSION_DENIED: Permission 'cloudkms.cryptoKeyVersions.useToSign'" "$TMP/err" &&
  grep -q 'attribute.role=900:main:true:looper-report' "$TMP/err" || fail "log: $(cat "$TMP/err")"
for e in looper-manager looper-scan; do
  t="$(tok "$e" -- mint manager 2>"$TMP/err")" || fail "$e could not mint the manager's token"
  [[ "$t" == ghs_manager_* ]] && grep -q '^token tacplus-manager .* {"contents":"write","issues":"write","metadata":"read"}$' "$TMP/api.log" ||
    fail "$e: $t $(cat "$TMP/api.log")"
done
! tok looper-manager -- mint other >/dev/null 2>&1 || fail "a role that is none"
pass

# workflows: write lets a token push a change under .github/workflows/
# (looper#106). The manager's set names it only once its app holds it
# (LOOPER_MANAGER_WORKFLOWS=write, looper#112). An installation that does not
# grant it still gets its token, without it, and the log says what that token
# cannot push.
NAME=workflows-ungranted
t="$(tok looper-manager LOOPER_MANAGER_WORKFLOWS=write -- mint manager 2>"$TMP/err")" || fail "no token with the grant"
grep -q '^token tacplus-manager .* {"contents":"write","issues":"write","workflows":"write","metadata":"read"}$' "$TMP/api.log" || fail "$t $(cat "$TMP/api.log")"
t="$(tok looper-manager LOOPER_MANAGER_WORKFLOWS=write STUB_UNGRANTED=tacplus-manager:workflows -- mint manager 2>"$TMP/err")" || fail "no token without the grant"
[[ "$t" == ghs_manager_* ]] && grep -q '^ungranted tacplus-manager workflows$' "$TMP/api.log" &&
  grep -q '^token tacplus-manager .* {"contents":"write","issues":"write","metadata":"read"}$' "$TMP/api.log" || fail "$t $(cat "$TMP/api.log")"
grep -q 'tacplus-manager: GitHub refused a token with workflows: write; minted one without it, which cannot push a change under .github/workflows/' "$TMP/err" ||
  fail "log: $(cat "$TMP/err")"
pass

# A manager whose request GitHub refuses with 422 (looper#112): its job still
# gets its token at once, and each refresh too, without workflows; gh reads
# the last. Every call to GitHub has an end.
NAME=manager-start-ungranted
d="$TMP/manager"; mkdir -m 0700 "$d"; sleep 300 & job=$!; kids+=("$job"); : > "$TMP/curl-limits"
SECONDS=0
pid="$(REFRESH=1 tok looper-manager LOOPER_MANAGER_WORKFLOWS=write STUB_UNGRANTED=tacplus-manager:workflows -- start manager "$d" "$job" 2>"$TMP/err")" ||
  fail "start failed"
kids+=("$pid")
(( SECONDS < 10 )) || fail "start took ${SECONDS}s"
t1="$(GH_CONFIG_DIR="$d" gh auth token)"; [[ "$t1" == ghs_manager_* ]] || fail "gh reads $t1"
for _ in $(seq 40); do t2="$(GH_CONFIG_DIR="$d" gh auth token)"; [[ "$t2" != "$t1" ]] && break; sleep 0.25; done
[[ "$t2" != "$t1" && "$t2" == ghs_manager_* ]] || fail "the token was not refreshed"
(( $(grep -c '^ungranted tacplus-manager workflows$' "$TMP/api.log") >= 2 )) &&
  ! grep -q '^token tacplus-manager .*"workflows"' "$TMP/api.log" || fail "$(cat "$TMP/api.log")"
[[ -s "$TMP/curl-limits" ]] && ! grep -qvx 'limits: --connect-timeout 30 --max-time 300' "$TMP/curl-limits" || fail "a call to GitHub with no end: $(cat "$TMP/curl-limits")"
kill "$job"
pass

# A report's token names workflows: write only for an issue that carries
# looper:workflows, set by someone with write access (looper#115): GitHub runs
# a pushed branch's own copy of a workflow, so it could publish the image every
# manager runs. Set by a triager, a bot (the report's own app) or no one, or an
# issue it cannot read: no workflows. The token that read the issue is revoked.
NAME=workflows-label
mkdir -p "$TMP/gh/repos/tacplus-dev/alpha/issues/7" "$TMP/gh/repos/tacplus-dev/alpha/collaborators/jody" \
  "$TMP/gh/repos/tacplus-dev/alpha/collaborators/tri" "$TMP/gh/repos/tacplus-dev/alpha/collaborators/tacplus-looper[bot]"
echo '{"permission": "admin"}' > "$TMP/gh/repos/tacplus-dev/alpha/collaborators/jody/permission.json"
echo '{"permission": "read", "role_name": "triage"}' > "$TMP/gh/repos/tacplus-dev/alpha/collaborators/tri/permission.json"
echo '{"permission": "write"}' > "$TMP/gh/repos/tacplus-dev/alpha/collaborators/tacplus-looper[bot]/permission.json"
labels() { jq -n --arg l "$1" '{labels: ([{name: "approved"}] + (if $l == "" then [] else [{name: $l}] end))}' > "$TMP/gh/repos/tacplus-dev/alpha/issues/7.json"; }
events() { # "login type event" ...
  local e; rm -f "$TMP/gh/repos/tacplus-dev/alpha/issues/7/events".*.json; for e in "$@"; do read -r who ty ev <<<"$e"
    jq -nc --arg w "$who" --arg t "$ty" --arg e "$ev" '{event: $e, actor: {login: $w, type: $t}, label: {name: "looper:workflows"}}'
  done | jq -s '[{event: "labeled", actor: {login: "jody", type: "User"}, label: {name: "approved"}}] + .' > "$TMP/gh/repos/tacplus-dev/alpha/issues/7/events.json"
}
W='{"contents":"write","issues":"write","pull_requests":"write","workflows":"write","metadata":"read"}'
NOW='{"contents":"write","issues":"write","pull_requests":"write","metadata":"read"}'
while IFS='|' read -r case label evs want said; do
  labels "$label"; IFS=, read -ra e <<<"$evs"; events ${e[@]+"${e[@]}"}
  t="$(tok looper-report -- mint report alpha#7 2>"$TMP/err")" || fail "$case: no token"
  last="$(awk '/^token / { t = $3; p = $4 } END { print t, p }' "$TMP/api.log")"
  [[ "$last" == "$t $want" ]] || fail "$case: $t, the last token minted: $last"
  [[ -z "$said" ]] || grep -qF "$said" "$TMP/err" || fail "$case: log: $(cat "$TMP/err")"
  if [[ "$want" == "$W" ]]; then
    first="$(awk '/^token / { print $3; exit }' "$TMP/api.log")"
    grep -qx "revoked $first" "$TMP/api.log" || fail "$case: the token that read the issue lives on: $(cat "$TMP/api.log")"
  fi
done <<EOF
member|looper:workflows|jody User labeled|$W|alpha#7 carries looper:workflows, set by jody (admin): this token names workflows: write
none||jody User labeled,jody User unlabeled|$NOW|
triager|looper:workflows|tri User labeled|$NOW|alpha#7's looper:workflows was set by tri (read), not someone with write access: ignored
bot|looper:workflows|tacplus-looper[bot] Bot labeled|$NOW|alpha#7's looper:workflows was set by tacplus-looper[bot] (Bot), not someone with write access: ignored
relabelled|looper:workflows|jody User labeled,jody User unlabeled,tri User labeled|$NOW|set by tri (read)
EOF
# An issue of many events, each as large as GitHub's (looper#115: the pages read
# so far, passed to jq as an argument, passed the kernel's limit, and the check
# fell to unreadable): the last labeled event wins, wherever its page.
many() { # page login type: 6 pages of 100 events, looper:workflows labeled on page 1 by jody, then on PAGE by LOGIN
  local d="$TMP/gh/repos/tacplus-dev/alpha/issues/7" n f
  for n in 1 2 3 4 5 6; do
    f="$d/events.$n.json"; [[ "$n" != 1 ]] || f="$d/events.json"
    jq -nc --argjson n "$n" --argjson at "$1" --arg w "$2" --arg t "$3" --arg pad "$(printf '%02000d' 0)" '
      [range(100) as $i | {event: "commented", actor: {login: "someone", type: "User"}, body: $pad}]
      | if $n == 1 then .[0] = {event: "labeled", actor: {login: "jody", type: "User"}, label: {name: "looper:workflows"}} else . end
      | if $n == $at then .[99] = {event: "labeled", actor: {login: $w, type: $t}, label: {name: "looper:workflows"}} else . end' > "$f"
  done
}
labels looper:workflows
for c in "5 jody User|$W|set by jody (admin)" "5 tri User|$NOW|set by tri (read)" "1 jody User|$W|set by jody (admin)"; do
  IFS='|' read -r at want said <<<"$c"; many $at
  t="$(tok looper-report -- mint report alpha#7 2>"$TMP/err")" || fail "many $at: no token"
  last="$(awk '/^token / { t = $3; p = $4 } END { print t, p }' "$TMP/api.log")"
  [[ "$last" == "$t $want" ]] && grep -qF "$said" "$TMP/err" || fail "many $at: $last: $(cat "$TMP/err")"
done
rm -f "$TMP/gh/repos/tacplus-dev/alpha/issues/7/events".*.json

labels looper:workflows; rm "$TMP/gh/repos/tacplus-dev/alpha/issues/7/events.json"
t="$(tok looper-report -- mint report alpha#7 2>"$TMP/err")" || fail "unreadable: no token"
grep -q "^token tacplus-looper $t $NOW\$" "$TMP/api.log" && grep -qF "could not read who set alpha#7's looper:workflows: no workflows: write" "$TMP/err" ||
  fail "unreadable: $(cat "$TMP/api.log" "$TMP/err")"
# The manager's set names it only with LOOPER_MANAGER_WORKFLOWS=write (looper#112), whatever the issue; a report's
# start passes its issue on each refresh.
t="$(tok looper-manager -- mint manager alpha#7 2>"$TMP/err")" || fail "manager: no token"
grep -q "^token tacplus-manager $t {\"contents\":\"write\",\"issues\":\"write\",\"metadata\":\"read\"}\$" "$TMP/api.log" || fail "manager: $(cat "$TMP/api.log")"
t="$(tok looper-manager LOOPER_MANAGER_WORKFLOWS=write -- mint manager alpha#7 2>"$TMP/err")" || fail "manager: no token"
grep -q "^token tacplus-manager $t .*\"workflows\":\"write\"" "$TMP/api.log" || fail "manager: $(cat "$TMP/api.log")"
labels looper:workflows; events "jody User labeled"
d="$TMP/labelled"; sleep 300 & job=$!; kids+=("$job")
pid="$(REFRESH=1 tok looper-report -- start report "$d" "$job" alpha#7 2>"$TMP/err")" || fail "start failed"
kids+=("$pid")
grep -q "^token tacplus-looper $(GH_CONFIG_DIR="$d" gh auth token) $W\$" "$TMP/api.log" || fail "start: $(cat "$TMP/api.log")"
kill "$job"
! tok looper-report -- mint report alpha >/dev/null 2>"$TMP/err" || fail "an issue that is no REPO#N"
pass

# An id_token that is not the project's protected main, or for another
# audience or project, is refused before GCP sees it; and none at all.
NAME=id-token
for bad in '.ref = "feature"' '.ref_protected = "false"' '.aud = "https://iam.googleapis.com/other"' \
           '.project_path = "tacplus-dev/other"' '.iss = "https://evil.example"'; do
  : > "$TMP/gcloud.log"
  ! env -i PATH="$TMP/bin:$PATH" HOME="$TMP" TMP="$TMP" APP_STUB="$TMP" TMPDIR="$TMP" CI_PROJECT_PATH=tacplus-dev/looper GCP_WIF_PROVIDER="$PROVIDER" \
      LOOPER_KMS_KEYRING="$RING" LOOPER_REPORT_APP_ID=301 LOOPER_REPORT_INSTALLATION_ID=31 GCP_ID_TOKEN="$(id_token looper-report "$bad")" \
      "$ROOT/looper-token" mint report >/dev/null 2>"$TMP/err" || fail "minted with $bad"
  [[ ! -s "$TMP/gcloud.log" ]] || fail "GCP saw the id_token with $bad"
done
! tok looper-report GCP_ID_TOKEN= -- mint report >/dev/null 2>"$TMP/err" || fail "minted with no id_token"
grep -q 'no id_tokens GCP_ID_TOKEN' "$TMP/err" || fail "log: $(cat "$TMP/err")"
pass

# Each refusal says why (looper#95): its class, gcloud's own error and the
# claims GCP maps, never the id_token.
NAME=errors
while IFS='|' read -r what want said; do
  ! tok looper-report ${what:+"$what"} -- mint report >/dev/null 2>"$TMP/err" || fail "$what: minted"
  grep -qF "$want" "$TMP/err" || fail "$what: no '$want'"
  grep -F "gcloud: " "$TMP/err" | grep -qF "$said" || fail "$what: not gcloud's error '$said'"
  grep -qF 'project_id=900 ref=main ref_protected=true environment=looper-report attribute.role=900:main:true:looper-report' "$TMP/err" ||
    fail "$what: no claims"
  grep -qF eyJhbGciOiJSUzI1NiJ9 "$TMP/err" && fail "$what: the id_token is in the log"
done <<EOF
STUB_FAIL=sts|the token exchange (STS) refused this job's id_token|ERROR: (gcloud.kms.asymmetric-sign) There was a problem refreshing
STUB_FAIL=quota|counted against a project that refuses it|USER_PROJECT_DENIED
STUB_RING=projects/other/locations/us/keyRings/looper|Cloud KMS has no version 1 of $RING/cryptoKeys/tacplus-looper|NOT_FOUND
LOOPER_KMS_KEYRING=looper|gcloud refused the command itself, before any call to GCP|argument --location: Must be specified
EOF
! tok looper-report STUB_FAIL=login -- mint report >/dev/null 2>"$TMP/err" || fail "login: minted"
grep -qF "Workload Identity Federation refused this job ($PROVIDER): the token exchange (STS) refused this job's id_token" "$TMP/err" &&
  grep -qF 'gcloud: ERROR: (gcloud.auth.login) There was a problem refreshing your current auth tokens' "$TMP/err" &&
  grep -qF 'the id_token: project_id=900 ref=main ref_protected=true environment=looper-report' "$TMP/err" ||
  fail "login: $(cat "$TMP/err")"
# An environment the id_token lacks is named as such.
! env -i PATH="$TMP/bin:$PATH" HOME="$TMP" TMP="$TMP" APP_STUB="$TMP" TMPDIR="$TMP" STUB_RING="$RING" GCP_WIF_PROVIDER="$PROVIDER" LOOPER_KMS_KEYRING="$RING" \
    LOOPER_REPORT_APP_ID=301 LOOPER_REPORT_INSTALLATION_ID=31 GCP_ID_TOKEN="$(id_token "" 'del(.environment)')" \
    "$ROOT/looper-token" mint report >/dev/null 2>"$TMP/err" || fail "minted with no environment"
grep -qF 'environment=(none) attribute.role=(none: no environment claim)' "$TMP/err" || fail "no environment: $(cat "$TMP/err")"
pass

# The hub's diagnosis (looper#95): the claims, the attribute.role GCP
# computes, and each key's answer, against what each key's binding should be.
NAME=diagnose
out="$(tok looper-plan LOOPER_REPORT_APP_ID= -- diagnose 2>"$TMP/err")" || fail "looper-plan: $out"
grep -qF 'attribute.role=900:main:true:looper-plan' <<<"$out" &&
  grep -qx 'tacplus-looper: signed (expected: signed)' <<<"$out" &&
  grep -qx 'tacplus-manager: refused (expected: refused)' <<<"$out" &&
  grep -qF "gcloud: ERROR: (gcloud.kms.asymmetric-sign) PERMISSION_DENIED" <<<"$out" || fail "looper-plan: $out"
out="$(tok looper-scan -- diagnose 2>"$TMP/err")" || fail "looper-scan: $out"
grep -qx 'tacplus-looper: signed (expected: signed)' <<<"$out" && grep -qx 'tacplus-manager: signed (expected: signed)' <<<"$out" ||
  fail "looper-scan: $out"
! out="$(tok looper-report STUB_FAIL=sts -- diagnose 2>"$TMP/err")" || fail "sts: exit 0: $out"
grep -qx 'tacplus-looper: refused (expected: signed)' <<<"$out" && grep -qF "the token exchange (STS) refused" <<<"$out" || fail "sts: $out"
grep -qF eyJhbGciOiJSUzI1NiJ9 <<<"$out" && fail "the id_token is in the diagnosis"
pass

# On a project's looper VM (looper#238): no id_token, no federation; gcloud
# signs as the VM's own service account, which the report app's key names
# (tacplus-dev/cloud#108) and the manager's does not.
NAME=vm
vm() { : > "$TMP/api.log"
  env -i PATH="$TMP/bin:$PATH" HOME="$TMP" TMP="$TMP" APP_STUB="$TMP" TMPDIR="$TMP" STUB_RING="$RING" LOOPER_VM=/usr/local/bin/looper-vm \
    LOOPER_KMS_KEYRING="$RING" LOOPER_REPORT_APP_ID=301 LOOPER_REPORT_INSTALLATION_ID=31 LOOPER_MANAGER_APP_ID=401 \
    LOOPER_MANAGER_INSTALLATION_ID=41 "$@"; }
t="$(vm STUB_GCE_SA=looper-vm-alpha "$ROOT/looper-token" mint report 2>"$TMP/err")" || fail "the VM's account: no token"
[[ -n "$t" ]] && grep -qx 'signed tacplus-looper vm:looper-vm-alpha' "$TMP/api.log" || fail "the VM's account: $(cat "$TMP/api.log")"
! vm STUB_GCE_SA=looper-vm-alpha "$ROOT/looper-token" mint manager >/dev/null 2>"$TMP/err" || fail "the VM minted the manager's token"
! vm STUB_GCE_SA=looper-vm-beta "$ROOT/looper-token" mint report >/dev/null 2>"$TMP/err" || fail "another VM's account signed"
# Not on a VM, no id_token is still refused, as before.
! vm STUB_GCE_SA=looper-vm-alpha LOOPER_VM= "$ROOT/looper-token" mint report >/dev/null 2>"$TMP/err" || fail "minted with no id_token and no VM"
pass

echo "looper-token: all scenarios pass"
