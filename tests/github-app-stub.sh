# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# A GitHub App's installation token as looper-token mints it (looper#83), for
# the tests: a stub gcloud (it signs with a key only for the environments its
# binding names, as roles/cloudkms.signer bound to the provider's attribute
# does, reading the id_token on every call as a federated credential does) and
# a stub curl for GitHub's access_tokens (it verifies each app's JWT against
# that app's public key; STUB_UNGRANTED="<app>:workflows" refuses a set that
# names workflows, as GitHub's 422 does). Each mint is a line of
# $APP_STUB/api.log, each curl call's limits a line of $APP_STUB/curl-limits.
# Use: source it, `app_stub DIR`, then run looper-token with APP_STUB=DIR,
# DIR/bin first on its PATH, STUB_RING="$RING" and GCP_ID_TOKEN="$(id_token ENV)".
PROVIDER=projects/1/locations/global/workloadIdentityPools/gitlab-loopers/providers/gitlab-looper
RING=projects/tacplus-ci/locations/us-central1/keyRings/looper

app_stub() { # dir
  mkdir -p "$1/keys" "$1/bin"
  for k in tacplus-looper tacplus-manager; do
    openssl genrsa -out "$1/keys/$k.pem" 2048 2>/dev/null
    openssl rsa -in "$1/keys/$k.pem" -pubout -out "$1/keys/$k.pub" 2>/dev/null
  done
  # Each key's binding: the environments of the looper project's jobs that may sign with it.
  printf 'tacplus-looper looper-report looper-scan kicker looper-plan\ntacplus-manager looper-manager looper-scan\n' > "$1/iam"
  cat > "$1/bin/gcloud" <<'EOF'
#!/usr/bin/env bash
echo "gcloud $*" >> "$APP_STUB/gcloud.log"
src="$CLOUDSDK_CONFIG/source"
case "$*" in
  "iam workload-identity-pools create-cred-config "*)
    for a in "$@"; do
      case "$a" in
        --credential-source-file=*) echo "${a#*=}" > "$src" ;;
        --output-file=*) echo '{}' > "${a#*=}" ;;
      esac
    done ;;
  "auth login "*)
    [[ "${STUB_FAIL:-}" != login ]] || { echo "ERROR: (gcloud.auth.login) There was a problem refreshing your current auth tokens: ('Error code unauthorized_client: The given credential is rejected by the attribute condition.', '{\"error\":\"unauthorized_client\"}')" >&2; exit 1; }
    [[ -s "$src" && -s "$(cat "$src")" ]] || exit 1 ;;
  "kms asymmetric-sign "*)
    ver="" key="" ring="" loc="" in="" sig=""
    for a in "$@"; do
      case "$a" in
        --version=*) ver="${a#*=}" ;; --key=*) key="${a#*=}" ;; --keyring=*) ring="${a#*=}" ;; --location=*) loc="${a#*=}" ;;
        --input-file=*) in="${a#*=}" ;; --signature-file=*) sig="${a#*=}" ;;
      esac
    done
    # As gcloud parses it: --version is the resource, a bare one relative to
    # --key, --keyring and --location, refused before any call without them.
    if [[ "$ver" != projects/*/cryptoKeyVersions/* ]]; then
      for f in location keyring key; do
        [[ -n "${!f}" ]] || { echo "ERROR: (gcloud.kms.asymmetric-sign) argument --$f: Must be specified." >&2; exit 1; }
      done
      echo "stub: a relative --version" >&2; exit 1
    fi
    key="${ver%/cryptoKeyVersions/*}"; key="${key##*/}"
    # Exchanged again on each call: the token file must still be there.
    [[ -s "$(cat "$src")" ]] || { echo "no credential source" >&2; exit 1; }
    case "${STUB_FAIL:-}" in
      sts) echo "ERROR: (gcloud.kms.asymmetric-sign) There was a problem refreshing your current auth tokens: ('Error code invalid_grant: The audience in ID Token [x] does not match the expected audience.', '{\"error\":\"invalid_grant\"}')" >&2; exit 1 ;;
      quota) echo "ERROR: (gcloud.kms.asymmetric-sign) PERMISSION_DENIED: Caller does not have required permission to use project 1. Grant the caller the roles/serviceusage.serviceUsageConsumer role. reason: USER_PROJECT_DENIED" >&2; exit 1 ;;
    esac
    [[ "$ver" == "$STUB_RING/cryptoKeys/$key/cryptoKeyVersions/1" && -f "$APP_STUB/keys/$key.pem" ]] ||
      { echo "ERROR: (gcloud.kms.asymmetric-sign) NOT_FOUND: $ver not found." >&2; exit 1; }
    p="$(cut -d. -f2 < "$(cat "$src")" | tr '_-' '/+')"; while ((${#p} % 4)); do p+="="; done
    env="$(base64 -d <<<"$p" | jq -r '.environment // ""')"
    grep -qE "^$key( .*)? $env( |\$)" "$APP_STUB/iam" || { echo "kms-denied $key $env" >> "$APP_STUB/api.log"
      echo "ERROR: (gcloud.kms.asymmetric-sign) PERMISSION_DENIED: Permission 'cloudkms.cryptoKeyVersions.useToSign' denied on resource '${ver%/cryptoKeyVersions/*}' (or it may not exist)." >&2; exit 1; }
    echo "signed $key $env" >> "$APP_STUB/api.log"
    openssl dgst -sha256 -sign "$APP_STUB/keys/$key.pem" -out "$sig" "$in" ;;
  *) exit 3 ;;
esac
EOF
  cat > "$1/bin/curl" <<'EOF'
#!/usr/bin/env bash
method=GET data="" auth="" url="" limits=""
while (($#)); do
  case "$1" in
    -X) method="$2"; shift 2 ;;
    -H) [[ "$2" == Authorization:* ]] && auth="${2#Authorization: Bearer }"; shift 2 ;;
    -d) data="$2"; shift 2 ;; --retry) shift 2 ;;
    --connect-timeout|--max-time) limits+=" $1 $2"; shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
echo "limits:$limits" >> "$APP_STUB/curl-limits"
b64d() { local s; s="$(tr '_-' '/+' <<<"$1")"; while ((${#s} % 4)); do s+="="; done; base64 -d <<<"$s"; }
case "$method $url" in
  "POST https://api.github.com/app/installations/"*/access_tokens)
    inst="${url#*/installations/}"; inst="${inst%%/*}"
    case "$inst" in 31) app=tacplus-looper id=301 ;; 41) app=tacplus-manager id=401 ;; *) exit 22 ;; esac
    IFS=. read -r h p s <<<"$auth"; b64d "$s" > "$APP_STUB/sig"
    printf '%s' "$h.$p" | openssl dgst -sha256 -verify "$APP_STUB/keys/$app.pub" -signature "$APP_STUB/sig" >/dev/null 2>&1 ||
      { echo "jwt-bad $app" >> "$APP_STUB/api.log"; exit 22; }
    b64d "$p" | grep -q "\"iss\":\"$id\"" || { echo "jwt-iss $app" >> "$APP_STUB/api.log"; exit 22; }
    # An installation that does not grant a permission the request names: 422.
    [[ " ${STUB_UNGRANTED:-} " == *" $app:workflows "* && "$data" == *'"workflows"'* ]] &&
      { echo "ungranted $app workflows" >> "$APP_STUB/api.log"; exit 22; }
    t="ghs_${app#tacplus-}_$RANDOM$RANDOM"
    echo "token $app $t $(jq -c .permissions <<<"$data")" >> "$APP_STUB/api.log"
    printf '{"token": "%s", "expires_at": "2026-11-04T20:00:00Z"}\n' "$t" ;;
  *) echo "curl stub: $method $url" >&2; exit 22 ;;
esac
EOF
  chmod +x "$1/bin/"*
}

# GitLab's id_token for a job of the looper project: claims as GitLab signs them.
id_token() { # environment [jq assignments]
  local c; c="$(jq -cn --arg aud "https://iam.googleapis.com/$PROVIDER" --argjson now "$(date +%s)" --arg env "$1" \
    "{iss: \"https://gitlab.com\", aud: \$aud, iat: \$now, exp: (\$now + 39600), project_id: \"900\", project_path: \"tacplus-dev/looper\",
      ref: \"main\", ref_protected: \"true\", pipeline_source: \"parent_pipeline\", job_id: \"5\", environment: \$env} ${2:+| $2}")"
  printf 'eyJhbGciOiJSUzI1NiJ9.%s.c2ln' "$(printf '%s' "$c" | openssl base64 -A | tr '+/' '-_' | tr -d '=')"
}

