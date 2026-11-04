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
# that is not the project's protected main is refused.
# Run: tests/looper-token.test.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; kids=()
trap 'for k in "${kids[@]+"${kids[@]}"}"; do kill "$k" 2>/dev/null || true; done; rm -rf "$TMP"' EXIT
export TMP
# gh reads the token from GH_CONFIG_DIR only when no token is in its environment.
unset GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN
PROVIDER=projects/1/locations/global/workloadIdentityPools/gitlab-loopers/providers/gitlab-looper
RING=projects/jody1-328023/locations/us/keyRings/looper

mkdir -p "$TMP/keys" "$TMP/bin"
for k in tacplus-looper tacplus-manager; do
  openssl genrsa -out "$TMP/keys/$k.pem" 2048 2>/dev/null
  openssl rsa -in "$TMP/keys/$k.pem" -pubout -out "$TMP/keys/$k.pub" 2>/dev/null
done
# Each key's binding: the environments of the looper project's jobs that may sign with it.
printf 'tacplus-looper looper-report looper-scan kicker looper-plan\ntacplus-manager looper-manager looper-scan\n' > "$TMP/iam"
cat > "$TMP/bin/gcloud" <<'EOF'
#!/usr/bin/env bash
echo "gcloud $*" >> "$TMP/gcloud.log"
src="$CLOUDSDK_CONFIG/source"
case "$*" in
  "iam workload-identity-pools create-cred-config "*)
    for a in "$@"; do
      case "$a" in
        --credential-source-file=*) echo "${a#*=}" > "$src" ;;
        --output-file=*) echo '{}' > "${a#*=}" ;;
      esac
    done ;;
  "auth login "*) [[ -s "$src" && -s "$(cat "$src")" ]] || exit 1 ;;
  "kms asymmetric-sign "*)
    key="" in="" sig=""
    for a in "$@"; do
      case "$a" in --key=*) key="${a##*/}" ;; --input-file=*) in="${a#*=}" ;; --signature-file=*) sig="${a#*=}" ;; esac
    done
    # Exchanged again on each call: the token file must still be there.
    [[ -s "$(cat "$src")" ]] || { echo "no credential source" >&2; exit 1; }
    p="$(cut -d. -f2 < "$(cat "$src")" | tr '_-' '/+')"; while ((${#p} % 4)); do p+="="; done
    env="$(base64 -d <<<"$p" | jq -r '.environment // ""')"
    grep -qE "^$key( .*)? $env( |\$)" "$TMP/iam" || { echo "kms-denied $key $env" >> "$TMP/api.log"; echo "PERMISSION_DENIED" >&2; exit 1; }
    echo "signed $key $env" >> "$TMP/api.log"
    openssl dgst -sha256 -sign "$TMP/keys/$key.pem" -out "$sig" "$in" ;;
  *) exit 3 ;;
esac
EOF
cat > "$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
method=GET data="" auth="" url=""
while (($#)); do
  case "$1" in
    -X) method="$2"; shift 2 ;;
    -H) [[ "$2" == Authorization:* ]] && auth="${2#Authorization: Bearer }"; shift 2 ;;
    -d) data="$2"; shift 2 ;; --retry) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
b64d() { local s; s="$(tr '_-' '/+' <<<"$1")"; while ((${#s} % 4)); do s+="="; done; base64 -d <<<"$s"; }
case "$method $url" in
  "POST https://api.github.com/app/installations/"*/access_tokens)
    inst="${url#*/installations/}"; inst="${inst%%/*}"
    case "$inst" in 31) app=tacplus-looper id=301 ;; 41) app=tacplus-manager id=401 ;; *) exit 22 ;; esac
    IFS=. read -r h p s <<<"$auth"; b64d "$s" > "$TMP/sig"
    printf '%s' "$h.$p" | openssl dgst -sha256 -verify "$TMP/keys/$app.pub" -signature "$TMP/sig" >/dev/null 2>&1 ||
      { echo "jwt-bad $app" >> "$TMP/api.log"; exit 22; }
    b64d "$p" | grep -q "\"iss\":\"$id\"" || { echo "jwt-iss $app" >> "$TMP/api.log"; exit 22; }
    t="ghs_${app#tacplus-}_$RANDOM$RANDOM"
    echo "token $app $t $(jq -c .permissions <<<"$data")" >> "$TMP/api.log"
    printf '{"token": "%s", "expires_at": "2026-11-04T20:00:00Z"}\n' "$t" ;;
  *) echo "curl stub: $method $url" >&2; exit 22 ;;
esac
EOF
chmod +x "$TMP/bin/"*

# GitLab's id_token for a job of the looper project: claims as GitLab signs them.
id_token() { # environment [jq assignments]
  local c; c="$(jq -cn --arg aud "https://iam.googleapis.com/$PROVIDER" --argjson now "$(date +%s)" --arg env "$1" \
    "{iss: \"https://gitlab.com\", aud: \$aud, iat: \$now, exp: (\$now + 39600), project_id: \"900\", project_path: \"tacplus-dev/looper\",
      ref: \"main\", ref_protected: \"true\", pipeline_source: \"parent_pipeline\", job_id: \"5\", environment: \$env} ${2:+| $2}")"
  printf 'eyJhbGciOiJSUzI1NiJ9.%s.c2ln' "$(printf '%s' "$c" | openssl base64 -A | tr '+/' '-_' | tr -d '=')"
}

NAME=""
fail() { echo "FAIL $NAME: $*" >&2; [[ -f "$TMP/err" ]] && cat "$TMP/err" >&2; [[ -f "$TMP/api.log" ]] && cat "$TMP/api.log" >&2; exit 1; }
pass() { echo "ok $NAME"; }
tok() { # environment [VAR=value...] -- args
  local env="$1" e=(); shift; while [[ "$1" != -- ]]; do e+=("$1"); shift; done; shift
  : > "$TMP/api.log"
  env -i PATH="$TMP/bin:$PATH" HOME="$TMP" TMP="$TMP" TMPDIR="$TMP" CI_PROJECT_PATH=tacplus-dev/looper \
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
grep -q 'may not be manager' "$TMP/err" || fail "log: $(cat "$TMP/err")"
for e in looper-manager looper-scan; do
  t="$(tok "$e" -- mint manager 2>"$TMP/err")" || fail "$e could not mint the manager's token"
  [[ "$t" == ghs_manager_* ]] && grep -q '^token tacplus-manager .* {"contents":"write","issues":"write","metadata":"read"}$' "$TMP/api.log" ||
    fail "$e: $t $(cat "$TMP/api.log")"
done
! tok looper-manager -- mint other >/dev/null 2>&1 || fail "a role that is none"
pass

# An id_token that is not the project's protected main, or for another
# audience or project, is refused before GCP sees it; and none at all.
NAME=id-token
for bad in '.ref = "feature"' '.ref_protected = "false"' '.aud = "https://iam.googleapis.com/other"' \
           '.project_path = "tacplus-dev/other"' '.iss = "https://evil.example"'; do
  : > "$TMP/gcloud.log"
  ! env -i PATH="$TMP/bin:$PATH" HOME="$TMP" TMP="$TMP" TMPDIR="$TMP" CI_PROJECT_PATH=tacplus-dev/looper GCP_WIF_PROVIDER="$PROVIDER" \
      LOOPER_KMS_KEYRING="$RING" LOOPER_REPORT_APP_ID=301 LOOPER_REPORT_INSTALLATION_ID=31 GCP_ID_TOKEN="$(id_token looper-report "$bad")" \
      "$ROOT/looper-token" mint report >/dev/null 2>"$TMP/err" || fail "minted with $bad"
  [[ ! -s "$TMP/gcloud.log" ]] || fail "GCP saw the id_token with $bad"
done
! tok looper-report GCP_ID_TOKEN= -- mint report >/dev/null 2>"$TMP/err" || fail "minted with no id_token"
grep -q 'no id_tokens GCP_ID_TOKEN' "$TMP/err" || fail "log: $(cat "$TMP/err")"
pass

echo "looper-token: all scenarios pass"
