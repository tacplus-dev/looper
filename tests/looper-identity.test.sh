#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# The LLM-free jobs of a looper with its own identity (looper-identity,
# looper#28), as kernel's project runs them, against: tests/git-server.py as
# GitHub's git (it lets only the writers' tokens push); a stub curl as GitHub's
# API (it verifies each app's JWT against that app's public key, and the
# kernel-looper app is installed on kernel alone) and GitLab's pipeline
# trigger; a stub gcloud as Workload Identity Federation and Cloud KMS (it signs
# with a key only for the federated project its IAM binding names, as
# roles/cloudkms.signer bound to one principal does); a stub gh for the prepare
# job's issue reads. A tree mismatch fails the commit job; a token for another
# repository cannot be minted from kernel's project; a pipeline started any
# other way than the project's own (where variables come in) is refused.
# Run: tests/looper-identity.test.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; SRV="$(mktemp -d)"; pid=""
trap '[[ -n "$pid" ]] && kill "$pid" 2>/dev/null; rm -rf "$TMP" "$SRV"' EXIT
export TMP
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
KERNEL_ID=1001; PROVIDER=projects/1/locations/global/workloadIdentityPools/gitlab/providers/gitlab-com
RING=projects/jody1-328023/locations/us/keyRings/looper

# --- GitHub's git: tacplus-dev/kernel -------------------------------------------
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=stub -keyout "$SRV/key.pem" -out "$SRV/cert.pem" \
  -addext "subjectAltName=DNS:github.com" 2>/dev/null
: > "$SRV/writers"; : > "$SRV/log"
work="$TMP/kernel"; git init -q -b main "$work"
printf 'kernel\n' > "$work/README.md"; printf '# Roadmap\n' > "$work/ROADMAP.md"
git -C "$work" add -A; git -C "$work" commit -qm init
BASE="$(git -C "$work" rev-parse HEAD)"
git clone -q --bare "$work" "$SRV/repos/github.com/tacplus-dev/kernel.git"
git -C "$SRV/repos/github.com/tacplus-dev/kernel.git" config uploadpack.allowAnySHA1InWant true
python3 -I "$ROOT/tests/git-server.py" "$SRV/repos" "$SRV/cert.pem" "$SRV/key.pem" "$SRV/log" "$SRV/writers" > "$SRV/port" &
pid=$!
for _ in $(seq 50); do [[ -s "$SRV/port" ]] && break; sleep 0.1; done
PORT="$(cat "$SRV/port")"; [[ -n "$PORT" ]] || { echo "FAIL: stub git server did not start" >&2; exit 1; }

# A think job's outputs: the change against BASE, its tree, and the outcome.
think_dir() { # dir outcome [file content]
  local d="$1" wt; mkdir -p "$d"; wt="$(mktemp -d)"
  git clone -q "$work" "$wt"
  [[ $# -lt 4 ]] || printf '%s\n' "$4" > "$wt/$3"
  git -C "$wt" add -A
  git -C "$wt" write-tree > "$d/tree"
  git -C "$wt" diff --cached --binary --full-index "$BASE" > "$d/patch"
  echo "$BASE" > "$d/base"
  printf '%s\n' "$2" > "$d/outcome"
  printf 'What changed, and the gates.\n' > "$d/comment.md"
  rm -rf "$wt"
}

# --- the apps' keys, and the GCP side ------------------------------------------
# keys/<name>.pem in "KMS"; iam: "<key> <project_id>" lines, the one principal
# allowed to sign with it (the reader: "*", every project of the namespace).
mkdir -p "$TMP/keys" "$TMP/bin"
for k in kernel-looper registry-looper tacplus-reader; do
  openssl genrsa -out "$TMP/keys/$k.pem" 2048 2>/dev/null
  openssl rsa -in "$TMP/keys/$k.pem" -pubout -out "$TMP/keys/$k.pub" 2>/dev/null
done
printf 'kernel-looper %s\nregistry-looper 2002\ntacplus-reader *\n' "$KERNEL_ID" > "$TMP/iam"
cat > "$TMP/bin/gcloud" <<'EOF'
#!/usr/bin/env bash
echo "gcloud $*" >> "$TMP/gcloud.log"
case "$*" in
  "iam workload-identity-pools create-cred-config "*)
    for a in "$@"; do
      case "$a" in
        --credential-source-file=*) cp "${a#*=}" "$TMP/federated" ;;
        --output-file=*) echo '{}' > "${a#*=}" ;;
      esac
    done ;;
  "auth login "*) [[ -s "$TMP/federated" ]] || exit 1 ;;
  "auth print-access-token") [[ -s "$TMP/federated" ]] && echo ya29.stub ;;
  "kms asymmetric-sign "*)
    key="" in="" sig=""
    for a in "$@"; do
      case "$a" in --key=*) key="${a##*/}" ;; --input-file=*) in="${a#*=}" ;; --signature-file=*) sig="${a#*=}" ;; esac
    done
    p="$(cut -d. -f2 < "$TMP/federated" | tr '_-' '/+')"; while ((${#p} % 4)); do p+="="; done
    project="$(base64 -d <<<"$p" | jq -r .project_id)"
    allowed="$(awk -v k="$key" '$1 == k { print $2 }' "$TMP/iam")"
    if [[ -z "$allowed" || ( "$allowed" != "*" && "$allowed" != "$project" ) ]]; then
      echo "kms-denied $key $project" >> "$TMP/api.log"
      echo "PERMISSION_DENIED: cloudkms.cryptoKeyVersions.useToSign on $key" >&2; exit 1
    fi
    openssl dgst -sha256 -sign "$TMP/keys/$key.pem" -out "$sig" "$in" ;;
esac
EOF
# GitHub's API and GitLab's trigger. An app's installation: the reader on
# every repository, each <repo>-looper on its repository alone.
cat > "$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
method=GET data="" auth="" url="" form=()
while (($#)); do
  case "$1" in
    -X) method="$2"; shift 2 ;;
    -H) [[ "$2" == Authorization:* ]] && auth="${2#Authorization: Bearer }"; shift 2 ;;
    -d) data="$2"; shift 2 ;;
    --form-string) form+=("$2"); method=POST; shift 2 ;;
    -o) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
b64d() { local s; s="$(tr '_-' '/+' <<<"$1")"; while ((${#s} % 4)); do s+="="; done; base64 -d <<<"$s"; }
api() { echo "$*" >> "$TMP/api.log"; }
who() { grep -h "^$1 " "$TMP/tokens" 2>/dev/null | cut -d' ' -f2-; }   # token -> "app perms"
case "$method $url" in
  "POST https://api.github.com/app/installations/"*/access_tokens)
    inst="${url#*/installations/}"; inst="${inst%%/*}"
    case "$inst" in 11) app=kernel-looper id=111 ;; 22) app=registry-looper id=222 ;; 99) app=tacplus-reader id=999 ;; *) exit 22 ;; esac
    IFS=. read -r h p s <<<"$auth"; b64d "$s" > "$TMP/sig"
    printf '%s' "$h.$p" | openssl dgst -sha256 -verify "$TMP/keys/$app.pub" -signature "$TMP/sig" >/dev/null 2>&1 ||
      { api "jwt-bad $app"; exit 22; }
    b64d "$p" | grep -q "\"iss\":\"$id\"" || { api "jwt-iss $app"; exit 22; }
    if [[ "$app" != tacplus-reader ]]; then
      repos="$(jq -c '.repositories // "all"' <<<"$data")"
      [[ "$repos" == "[\"${app%-looper}\"]" ]] || { api "token-refused $app $repos"; exit 22; }
    fi
    t="ghs_${app%%-*}_$RANDOM$RANDOM"
    echo "$t $app $(jq -c .permissions <<<"$data")" >> "$TMP/tokens"
    [[ "$app" == tacplus-reader ]] || echo "$t" >> "$SRV_WRITERS"
    api "token $app $data"
    printf '{"token": "%s", "expires_at": "2026-10-29T20:00:00Z"}\n' "$t" ;;
  "GET https://api.github.com/repos/tacplus-dev/kernel/pulls?"*)
    api "pulls? $(who "$auth" | cut -d' ' -f1)"; cat "$TMP/open-pulls" 2>/dev/null || echo '[]' ;;
  "POST https://api.github.com/repos/tacplus-dev/kernel/pulls")
    api "pull $(who "$auth") $data"; echo '{"html_url": "https://github.com/tacplus-dev/kernel/pull/12", "node_id": "PR_12"}' ;;
  "POST https://api.github.com/graphql") api "graphql $(who "$auth" | cut -d' ' -f1) $data"; echo '{"data":{}}' ;;
  "POST https://api.github.com/repos/tacplus-dev/kernel/issues/"*/comments) api "comment $(who "$auth") $data"; echo '{}' ;;
  "POST https://api.github.com/repos/tacplus-dev/kernel/issues/"*/labels) api "label $(who "$auth" | cut -d' ' -f1) $data"; echo '[]' ;;
  "GET https://api.github.com/repos/tacplus-dev/kernel/issues/"*) api "issue $(who "$auth" | cut -d' ' -f1)"; jq -n --arg b "$(cat "$TMP/body")" '{body: $b}' ;;
  "PATCH https://api.github.com/repos/tacplus-dev/kernel/issues/"*) api "edit $(who "$auth" | cut -d' ' -f1) $data" ;;
  "POST https://gitlab.com/api/v4/projects/tacplus-dev%2Fbuild/trigger/pipeline") api "trigger ${form[*]}" ;;
  *) echo "curl stub: $method $url" >&2; api "unexpected $method $url"; exit 22 ;;
esac
EOF
# gh, for the prepare job's reads: issues/kernel-<n>.json, and the token it used.
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "gh ${GH_TOKEN:-none} $1 $2" >> "$TMP/gh.log"
cmd="$1 $2"; shift 2
n=""; q="."; labels=()
while (($#)); do
  case "$1" in
    --repo) shift 2 ;; --jq) q="$2"; shift 2 ;; --label) labels+=("$2"); shift 2 ;;
    --json|--limit|--state) shift 2 ;; *) n="$1"; shift ;;
  esac
done
case "$cmd" in
  "issue list") jq -s '[.[] | select(.state == "OPEN" and ([.labels[].name] | contains($ARGS.positional)))]' "$TMP/issues/"*.json --args "${labels[@]}" | jq -r "$q" ;;
  "issue view") jq -r "$q" "$TMP/issues/kernel-$n.json" ;;
  *) exit 3 ;;
esac
EOF
chmod +x "$TMP/bin/"*
mkdir -p "$TMP/issues"
issue() { # n labels(csv) created
  jq -n --argjson n "$1" --arg l "$2" --arg c "$3" \
    '{number: $n, state: "OPEN", labels: ($l | split(",") | map({name: .})), body: "Do it.", createdAt: $c}' > "$TMP/issues/kernel-$1.json"
}
issue 5 approved,feature 2026-10-20T00:00:00Z
issue 7 approved,bug 2026-10-21T00:00:00Z
issue 9 approved,needs-decision 2026-10-19T00:00:00Z

# GitLab's id_token for the job: claims as GitLab signs them (the signature is GCP's to check).
id_token() { # [jq assignments]
  local c; c="$(jq -cn --arg aud "https://iam.googleapis.com/$PROVIDER" --argjson now "$(date +%s)" --argjson pid "$KERNEL_ID" \
    "{iss: \"https://gitlab.com\", aud: \$aud, iat: \$now, exp: (\$now + 300), project_id: (\$pid | tostring), project_path: \"tacplus-dev/kernel\",
      namespace_id: \"77\", ref: \"main\", ref_protected: \"true\", pipeline_source: \"parent_pipeline\", job_id: \"5\"} ${1:+| $1}")"
  printf 'eyJhbGciOiJSUzI1NiJ9.%s.c2ln' "$(printf '%s' "$c" | openssl base64 -A | tr '+/' '-_' | tr -d '=')"
}

NAME=""
fail() { echo "FAIL $NAME: $*" >&2; for f in "$TMP/err" "$TMP/api.log"; do [[ -f "$f" ]] && cat "$f" >&2; done; exit 1; }
pass() { echo "ok $NAME"; }
has() { grep -qF -- "$2" "$1" || fail "expected \"$2\" in $1: $(cat "$1")"; }
lacks() { ! grep -qF -- "$2" "$1" || fail "unexpected \"$2\" in $1"; }
n=0
# looper-identity, as a job of kernel's child pipeline runs it.
job() { # [VAR=value...] -- args
  local e=(); while [[ "$1" != -- ]]; do e+=("$1"); shift; done; shift
  n=$((n + 1)); OUT="$TMP/out-$n"; mkdir -p "$OUT" "$TMP/home"
  : > "$TMP/api.log"; : > "$TMP/gcloud.log"; : > "$TMP/gh.log"; rm -f "$TMP/federated"
  env -i PATH="$TMP/bin:$PATH" HOME="$TMP/home" TMP="$TMP" TMPDIR="$TMP" SRV_WRITERS="$SRV/writers" \
    HTTPS_PROXY="http://127.0.0.1:$PORT" GIT_SSL_CAINFO="$SRV/cert.pem" \
    LOOPER_LIB="$ROOT/looper-lib.sh" LOOPER_OUT="$OUT" \
    CI_PIPELINE_SOURCE=parent_pipeline CI_COMMIT_BRANCH=main CI_COMMIT_REF_NAME=main CI_COMMIT_REF_PROTECTED=true \
    CI_PROJECT_ID="$KERNEL_ID" CI_PROJECT_PATH=tacplus-dev/kernel CI_PROJECT_DIR="$OUT" \
    CI_PIPELINE_URL=https://gitlab.com/tacplus-dev/kernel/-/pipelines/3 CI_JOB_TOKEN=glcbt-stub \
    LOOPER_REPO=kernel GCP_WIF_PROVIDER="$PROVIDER" LOOPER_KMS_KEYRING="$RING" \
    LOOPER_APP_ID=111 LOOPER_INSTALLATION_ID=11 TACPLUS_READER_APP_ID=999 TACPLUS_READER_INSTALLATION_ID=99 \
    GCP_ID_TOKEN="$(id_token)" BUILD_TRIGGER_TOKEN=glptt-stub \
    "${e[@]}" "$ROOT/looper-identity" "$@"
}
nothing_written() {
  ! grep -qE '^(pull |comment|label|edit|trigger)' "$TMP/api.log" || fail "it wrote: $(cat "$TMP/api.log")"
  [[ -z "$(git -C "$SRV/repos/github.com/tacplus-dev/kernel.git" for-each-ref refs/heads/looper)" ]] || fail "it pushed a branch"
}

# --- prepare ---------------------------------------------------------------------
NAME="prepare: the oldest ready issue, and a read-only token, from the KMS-signed reader app"
job -- prepare 2>"$TMP/err" || fail "prepare failed"
has "$OUT/prepare.env" "LOOPER_ISSUE=5"
grep -qE '^LOOPER_READER_TOKEN=ghs_tacplus_' "$OUT/prepare.env" || fail "no reader token: $(cat "$OUT/prepare.env")"
has "$TMP/api.log" 'token tacplus-reader {"permissions":{"contents":"read","issues":"read","metadata":"read"}}'
has "$TMP/gcloud.log" "iam workload-identity-pools create-cred-config $PROVIDER"
grep -q "gh ghs_tacplus_.* issue list" "$TMP/gh.log" || fail "the issues were not read with the reader token: $(cat "$TMP/gh.log")"
[[ "$(stat -c %a "$OUT/prepare.env")" == 600 ]] || fail "prepare.env is readable by others"
nothing_written
pass

NAME="prepare: the input issue when it is ready; an issue in review is skipped"
job LOOPER_ISSUE=7 -- prepare 2>"$TMP/err" || fail "prepare failed"
has "$OUT/prepare.env" "LOOPER_ISSUE=7"
echo '[{"number": 12}]' > "$TMP/open-pulls"
job LOOPER_ISSUE=9 -- prepare 2>"$TMP/err" || fail "prepare failed"
has "$OUT/prepare.env" "LOOPER_ISSUE="
lacks "$OUT/prepare.env" "LOOPER_ISSUE=9"
has "$TMP/err" "in review"
rm -f "$TMP/open-pulls"
pass

NAME="prepare: Jody's tokens and the model's credential are refused, nothing minted"
for c in GH_TOKEN=ghp_x GITLAB_TOKEN=x CLAUDE_CODE_OAUTH_TOKEN=x OTHER=glpat-x; do
  if job "$c" -- prepare 2>"$TMP/err"; then fail "ran beside $c"; fi
  has "$TMP/err" "credentials that are not its own"
  [[ ! -s "$TMP/api.log" && ! -s "$TMP/gcloud.log" ]] || fail "minted beside $c"
done
pass

# --- a pipeline started any other way, or with variables -------------------------
NAME="a pipeline started from the API, a trigger, a push or a schedule directly is refused"
for s in api trigger push schedule web pipeline; do
  if job CI_PIPELINE_SOURCE="$s" -- prepare 2>"$TMP/err"; then fail "ran from $s"; fi
  has "$TMP/err" "not one from '$s'"
  [[ ! -s "$TMP/gcloud.log" ]] || fail "exchanged its id_token from $s"
done
pass

NAME="a variable overriding GitLab's own disagrees with the id_token: refused"
if job CI_PIPELINE_SOURCE=parent_pipeline GCP_ID_TOKEN="$(id_token '.pipeline_source = "api"')" -- commit 2>"$TMP/err"; then fail "ran"; fi
has "$TMP/err" "the id_token's pipeline came from 'api'"
if job CI_PROJECT_ID=2002 CI_PROJECT_PATH=tacplus-dev/registry LOOPER_REPO=registry LOOPER_ISSUE=7 -- commit 2>"$TMP/err"; then fail "ran"; fi
has "$TMP/err" "the id_token is project $KERNEL_ID tacplus-dev/kernel"
if job GCP_ID_TOKEN="$(id_token '.ref = "evil" | .ref_protected = "false"')" -- prepare 2>"$TMP/err"; then fail "ran"; fi
has "$TMP/err" "not protected main"
if job CI_COMMIT_REF_PROTECTED=false -- prepare 2>"$TMP/err"; then fail "ran"; fi
has "$TMP/err" "runs on protected main"
nothing_written
pass

NAME="an id_token from another issuer, audience, or older than five minutes is refused"
if job GCP_ID_TOKEN="$(id_token '.iss = "https://gitlab.example"')" -- prepare 2>"$TMP/err"; then fail "ran"; fi
has "$TMP/err" "issuer"
if job GCP_ID_TOKEN="$(id_token '.aud = "kernel"')" -- prepare 2>"$TMP/err"; then fail "ran"; fi
has "$TMP/err" "audience"
if job GCP_ID_TOKEN="$(id_token '.iat = .iat - 600')" -- prepare 2>"$TMP/err"; then fail "ran"; fi
has "$TMP/err" "s ago: exchanged at the job's start"
[[ ! -s "$TMP/gcloud.log" ]] || fail "GCP saw it"
pass

# --- a token for another repository ---------------------------------------------
NAME="kernel's project cannot mint a token for another repository"
# Its looper is kernel's: another LOOPER_REPO in kernel's project is refused.
if job LOOPER_REPO=registry LOOPER_ISSUE=7 LOOPER_APP_ID=222 LOOPER_INSTALLATION_ID=22 -- commit 2>"$TMP/err"; then fail "ran"; fi
has "$TMP/err" "is no looper of tacplus-dev/registry"
nothing_written
# KMS signs with registry-looper's key only for registry's project.
think_dir "$TMP/think-other" $'type: pr\ntitle: t' src.txt x
if job LOOPER_ISSUE=7 LOOPER_THINK_DIR="$TMP/think-other" LOOPER_APP_ID=222 LOOPER_INSTALLATION_ID=22 \
     LOOPER_KMS_KEYRING="$RING" -- commit 2>"$TMP/err"; then :; fi
# (that asks kernel's key for app 222: GitHub refuses the JWT, signed by kernel-looper's key)
has "$TMP/api.log" "jwt-bad registry-looper"
nothing_written
sed -i 's/^kernel-looper .*/kernel-looper 2002/' "$TMP/iam"
if job LOOPER_ISSUE=7 LOOPER_THINK_DIR="$TMP/think-other" -- commit 2>"$TMP/err"; then fail "signed with a key bound to another project"; fi
has "$TMP/api.log" "kms-denied kernel-looper $KERNEL_ID"
nothing_written
printf 'kernel-looper %s\nregistry-looper 2002\ntacplus-reader *\n' "$KERNEL_ID" > "$TMP/iam"
pass

# --- commit ---------------------------------------------------------------------
NAME="commit: a pull request by kernel-looper[bot], squash auto-merge, the build started, the issue told"
think_dir "$TMP/think-pr" $'type: pr\ntitle: kernel: fix the thing' src.txt "the fix"
printf 'Fixed it. Closes #5\n' > "$TMP/think-pr/comment.md"   # the model's text closes nothing
job LOOPER_ISSUE=7 LOOPER_THINK_DIR="$TMP/think-pr" -- commit 2>"$TMP/err" || fail "commit failed"
head="$(git -C "$SRV/repos/github.com/tacplus-dev/kernel.git" rev-parse refs/heads/looper/kernel-7)" || fail "no branch"
[[ "$(git -C "$SRV/repos/github.com/tacplus-dev/kernel.git" rev-parse "$head^{tree}")" == "$(cat "$TMP/think-pr/tree")" ]] || fail "not the tested tree"
[[ "$(git -C "$SRV/repos/github.com/tacplus-dev/kernel.git" rev-parse "$head^")" == "$BASE" ]] || fail "not on the base"
[[ "$(git -C "$SRV/repos/github.com/tacplus-dev/kernel.git" log -1 --format='%an <%ae>|%cn' "$head")" == "kernel-looper[bot] <kernel-looper[bot]@users.noreply.github.com>|kernel-looper[bot]" ]] ||
  fail "author $(git -C "$SRV/repos/github.com/tacplus-dev/kernel.git" log -1 --format='%an <%ae>|%cn' "$head")"
has "$TMP/api.log" 'token kernel-looper {"permissions":{"contents":"write","metadata":"read"},"repositories":["kernel"]}'
has "$TMP/api.log" 'token kernel-looper {"permissions":{"pull_requests":"write","contents":"write","metadata":"read"},"repositories":["kernel"]}'
has "$TMP/api.log" 'token kernel-looper {"permissions":{"issues":"write","metadata":"read"},"repositories":["kernel"]}'
grep -E '^token kernel-looper' "$TMP/api.log" | grep -vqF '"repositories":["kernel"]}' && fail "a token beyond kernel"
grep -q '^pull kernel-looper {"pull_requests":"write".*"title":"kernel: fix the thing","head":"looper/kernel-7","base":"main"' "$TMP/api.log" || fail "no pull request: $(cat "$TMP/api.log")"
grep '^pull ' "$TMP/api.log" | grep -qF 'Closes #7' || fail "the pull request does not close the issue"
grep '^pull ' "$TMP/api.log" | grep -qF '#5' && fail "the model's text is in the pull request"
grep -q '^comment kernel-looper .*Fixed it. Closes #5' "$TMP/api.log" || fail "the model's text is not in the comment"
grep -q '^graphql kernel-looper .*enablePullRequestAutoMerge.*SQUASH.*PR_12' "$TMP/api.log" || fail "no squash auto-merge"
has "$TMP/api.log" "trigger token=glptt-stub ref=main inputs[repo]=kernel inputs[sha]=$head"
grep -q '^comment kernel-looper {"issues":"write".*pull/12' "$TMP/api.log" || fail "the issue was not told"
lacks "$TMP/api.log" "label "
[[ ! -e "$TMP/federated" ]] || grep -q '"project_id":"1001"' <(cut -d. -f2 "$TMP/federated" | tr '_-' '/+' | base64 -d 2>/dev/null) || fail "federated as another project"
pass

NAME="commit: a tree mismatch fails, and nothing is written"
think_dir "$TMP/think-bad" $'type: pr\ntitle: t' src.txt "tested"
think_dir "$TMP/think-evil" $'type: pr\ntitle: t' src.txt "something else"
cp "$TMP/think-evil/patch" "$TMP/think-bad/patch"
git -C "$SRV/repos/github.com/tacplus-dev/kernel.git" update-ref -d refs/heads/looper/kernel-7
if job LOOPER_ISSUE=7 LOOPER_THINK_DIR="$TMP/think-bad" -- commit 2>"$TMP/err"; then fail "committed a tree that was not tested"; fi
has "$TMP/err" "tree mismatch"
nothing_written
pass

NAME="commit: a patch touching ROADMAP.md is refused"
think_dir "$TMP/think-roadmap" $'type: pr\ntitle: t' ROADMAP.md "# Mine now"
if job LOOPER_ISSUE=7 LOOPER_THINK_DIR="$TMP/think-roadmap" -- commit 2>"$TMP/err"; then fail "committed ROADMAP.md"; fi
has "$TMP/err" "touches ROADMAP.md"
nothing_written
pass

NAME="commit: a question is commented and needs-decision, nothing pushed"
think_dir "$TMP/think-q" 'type: question'
job LOOPER_ISSUE=7 LOOPER_THINK_DIR="$TMP/think-q" -- commit 2>"$TMP/err" || fail "commit failed"
grep -q '^comment kernel-looper .*What changed' "$TMP/api.log" || fail "no comment"
has "$TMP/api.log" 'label kernel-looper {"labels":["needs-decision"]}'
lacks "$TMP/api.log" "pull "
[[ -z "$(git -C "$SRV/repos/github.com/tacplus-dev/kernel.git" for-each-ref refs/heads/looper)" ]] || fail "pushed"
pass

NAME="commit: blocked adds the Blocked-by lines the body lacks"
think_dir "$TMP/think-b" $'type: blocked\nBlocked-by: tacplus-dev/tacplus#9\nBlocked-by: #3\nBlocked-by: #7'
printf 'Do it.\nBlocked-by: #3' > "$TMP/body"
job LOOPER_ISSUE=7 LOOPER_THINK_DIR="$TMP/think-b" -- commit 2>"$TMP/err" || fail "commit failed"
has "$TMP/api.log" "comment kernel-looper"
has "$TMP/api.log" "label kernel-looper"   # naming itself: stuck
lacks "$TMP/api.log" "edit "
think_dir "$TMP/think-b" $'type: blocked\nBlocked-by: tacplus-dev/tacplus#9\nBlocked-by: #3'
job LOOPER_ISSUE=7 LOOPER_THINK_DIR="$TMP/think-b" -- commit 2>"$TMP/err" || fail "commit failed"
grep -q '^edit kernel-looper .*Blocked-by: #3\\n\\nBlocked-by: tacplus-dev/tacplus#9"' "$TMP/api.log" || fail "body: $(grep '^edit' "$TMP/api.log")"
lacks "$TMP/api.log" "label "
pass

NAME="commit: a think job that failed or timed out keeps its work on the branch; stuck, or approved"
think_dir "$TMP/think-t" 'type: timeout' src.txt "half"
job LOOPER_ISSUE=7 LOOPER_THINK_DIR="$TMP/think-t" -- commit 2>"$TMP/err" || fail "commit failed"
git -C "$SRV/repos/github.com/tacplus-dev/kernel.git" rev-parse -q --verify refs/heads/looper/kernel-7 >/dev/null || fail "no branch"
grep -q '^comment .*time limit.*looper/kernel-7' "$TMP/api.log" || fail "no comment"
lacks "$TMP/api.log" "label "
job LOOPER_ISSUE=7 LOOPER_THINK_DIR="$TMP/nothing-here" -- commit 2>"$TMP/err" || fail "commit failed"
grep -q '^comment .*ended without finishing' "$TMP/api.log" || fail "no comment"
has "$TMP/api.log" 'label kernel-looper {"labels":["looper:stuck"]}'
pass

NAME="commit: no issue taken, nothing done; the model's credential beside it is refused"
git -C "$SRV/repos/github.com/tacplus-dev/kernel.git" update-ref -d refs/heads/looper/kernel-7
job -- commit 2>"$TMP/err" || fail "commit failed"
[[ ! -s "$TMP/api.log" ]] || fail "it called GitHub"
if job LOOPER_ISSUE=7 CLAUDE_CODE_OAUTH_TOKEN=x LOOPER_THINK_DIR="$TMP/think-q" -- commit 2>"$TMP/err"; then fail "ran beside the model's credential"; fi
nothing_written
pass

# --- the pipeline ----------------------------------------------------------------
NAME="the pipeline: only the project's own child pipeline runs jobs; think has no id_tokens"
y="$ROOT/ci/looper.gitlab-ci.yml"
has "$y" '- if: $CI_PIPELINE_SOURCE =~ /^(schedule|web|parent_pipeline)$/ && $CI_COMMIT_BRANCH == "main" && $CI_COMMIT_REF_PROTECTED == "true"'
think_job="$(awk '/^think:/ { on = 1; print; next } /^[a-z.]/ { on = 0 } on' "$y")"
! grep -q 'id_tokens' <<<"$think_job" || fail "the think job has id_tokens"
grep -q 'name: looper-think' <<<"$think_job" || fail "the think job is not in its environment"
for j in prepare commit; do
  awk -v j="$j:" '$0 == j { on = 1; next } /^[a-z.]/ { on = 0 } on' "$y" | grep -q 'GCP_ID_TOKEN:' || fail "$j has no id_token"
done
awk '/^run:/ { on = 1; next } /^[a-z.]/ { on = 0 } on' "$y" | grep -q 'resource_group: looper' || fail "runs may overlap"
pass
