#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# The build pipeline (looper-build, looper#17) against a local origin:
# tests/git-server.py is GitHub's git (an HTTPS proxy for every host) and, as
# GitHub does for a read-only token, refuses a push from any password but the
# writers'; a stub curl is GitHub's API (it verifies the tacplus-reader app's
# JWT against the app's public key and records the token requests and commit
# statuses); stub docker and gcloud stand for buildx and Workload Identity
# Federation. The same commit gives the same verdict twice; a gate that
# changes a tracked file or pushes fails; a write credential, a credential
# that can push, a missing or bad pin are refused.
# Run: tests/looper-build.test.sh
set -euo pipefail
command -v just >/dev/null || { echo "FAIL: these tests run the gates with just, and there is none here" >&2; exit 1; }
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; SRV="$(mktemp -d)"; pid=""
trap '[[ -n "$pid" ]] && kill "$pid" 2>/dev/null; rm -rf "$TMP" "$SRV"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
READ_TOKEN="ghs_read$RANDOM$RANDOM"; WRITE_TOKEN="ghs_write$RANDOM$RANDOM"
APP_ID=4242; INSTALLATION=777
DIGEST_A="sha256:$(printf 'a%.0s' {1..64})"

# --- GitHub's git: tacplus-dev/demo, one branch per case ----------------------
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=stub -keyout "$SRV/key.pem" -out "$SRV/cert.pem" \
  -addext "subjectAltName=DNS:github.com" 2>/dev/null
echo "$WRITE_TOKEN" > "$SRV/writers"
work="$TMP/demo"; git init -q "$work"
LOCK="tacplus: 2.6.1
build_image: us-docker.pkg.dev/jody1-328023/tacplus/build:2.6.1@$DIGEST_A"
declare -A SHA
case_commit() { # name justfile-body [lock]
  git -C "$work" checkout -q --orphan "$1"
  git -C "$work" rm -rqf --ignore-unmatch . >/dev/null
  printf 'tracked\n' > "$work/data.txt"
  printf '%s\n' "$2" > "$work/justfile"
  [[ $# -lt 3 ]] || printf '%s\n' "$3" > "$work/tacplus.lock"
  git -C "$work" add -A; git -C "$work" commit -qm "$1"
  SHA[$1]="$(git -C "$work" rev-parse HEAD)"
}
PASS_GATES='gates:
    echo "gates ok job-token=${CI_JOB_TOKEN:-none} key=${TACPLUS_READER_APP_KEY:-none} app=${TACPLUS_READER_APP_ID:-none}"
    mkdir -p target && echo built > target/out
    test "$(cat data.txt)" = tracked'
case_commit pass "$PASS_GATES" "$LOCK"
case_commit fail 'gates:
    echo "a gate fails"; exit 3' "$LOCK"
case_commit dirty 'gates:
    echo changed >> data.txt' "$LOCK"
case_commit push 'gates:
    git push origin HEAD:refs/heads/evil' "$LOCK"
case_commit nogates 'build:
    echo hi' "$LOCK"
case_commit nopin "$PASS_GATES"
case_commit tagpin "$PASS_GATES" "tacplus: 2.6.1
build_image: us-docker.pkg.dev/jody1-328023/tacplus/build:2.6"
case_commit otherline "$PASS_GATES" "tacplus: 2.6.1
build_image: us-docker.pkg.dev/jody1-328023/tacplus/build:2.5.3@$DIGEST_A"
printf 'FROM scratch\nCOPY data.txt /\n' > "$work/Dockerfile"
git -C "$work" checkout -q pass; printf 'FROM scratch\nCOPY data.txt /\n' > "$work/Dockerfile"
git -C "$work" add Dockerfile; git -C "$work" commit -qm "a Dockerfile"; SHA[release]="$(git -C "$work" rev-parse HEAD)"
git -C "$work" tag -a v1.2.3 -m v1.2.3
git clone -q --bare "$work" "$SRV/repos/github.com/tacplus-dev/demo.git"
git -C "$SRV/repos/github.com/tacplus-dev/demo.git" config uploadpack.allowAnySHA1InWant true
: > "$SRV/log"
python3 -I "$ROOT/tests/git-server.py" "$SRV/repos" "$SRV/cert.pem" "$SRV/key.pem" "$SRV/log" "$SRV/writers" > "$SRV/port" &
pid=$!
for _ in $(seq 50); do [[ -s "$SRV/port" ]] && break; sleep 0.1; done
PORT="$(cat "$SRV/port")"; [[ -n "$PORT" ]] || { echo "FAIL: stub git server did not start" >&2; exit 1; }

# --- the tacplus-reader app and GitHub's API ---------------------------------
openssl genrsa -out "$TMP/app.pem" 2048 2>/dev/null
openssl rsa -in "$TMP/app.pem" -pubout -out "$TMP/app.pub" 2>/dev/null
mkdir -p "$TMP/bin"
echo "$READ_TOKEN" > "$TMP/token"   # what the app hands out
cat > "$TMP/bin/curl" <<EOF
#!/usr/bin/env bash
method=GET data="" auth="" url="" out=""
while ((\$#)); do
  case "\$1" in
    -X) method="\$2"; shift 2 ;;
    -H) [[ "\$2" == Authorization:* ]] && auth="\${2#Authorization: }"; shift 2 ;;
    -d) data="\$2"; shift 2 ;;
    -o) out="\$2"; shift 2 ;;
    -*) shift ;;
    *) url="\$1"; shift ;;
  esac
done
b64d() { local s; s="\$(tr '_-' '/+' <<<"\$1")"; while ((\${#s} % 4)); do s+="="; done; base64 -d <<<"\$s"; }
case "\$method \$url" in
  "POST https://api.github.com/app/installations/$INSTALLATION/access_tokens")
    jwt="\${auth#Bearer }"; IFS=. read -r h p s <<<"\$jwt"
    b64d "\$s" > "$TMP/sig"
    printf '%s' "\$h.\$p" | openssl dgst -sha256 -verify "$TMP/app.pub" -signature "$TMP/sig" >/dev/null 2>&1 ||
      { echo "jwt-bad" >> "$TMP/api.log"; exit 22; }
    b64d "\$p" | grep -q '"iss":"$APP_ID"' || { echo "jwt-iss" >> "$TMP/api.log"; exit 22; }
    echo "token \$data" >> "$TMP/api.log"
    printf '{\n  "token": "%s",\n  "expires_at": "2026-10-29T20:00:00Z"\n}\n' "\$(cat "$TMP/token")" ;;
  "POST https://api.github.com/repos/tacplus-dev/demo/statuses/"*)
    echo "status \$auth \${url##*/} \$data" >> "$TMP/api.log" ;;
  *) echo "curl stub: \$method \$url" >&2; exit 22 ;;
esac
EOF

# --- buildx and Workload Identity Federation ---------------------------------
cat > "$TMP/bin/docker" <<EOF
#!/usr/bin/env bash
echo "docker \$*" >> "$TMP/docker.log"
case "\$1 \${2:-}" in
  "buildx inspect")   # amd64 once the emulators are installed
    echo "Platforms: linux/arm64*, linux/arm/v7\$( [[ -f "$TMP/emulated" ]] && echo ', linux/amd64, linux/amd64/v2' )" ;;
  "run --rm") [[ "\$*" == *binfmt*--install* ]] && touch "$TMP/emulated" ;;
  "login "*) echo "login \${*: -1} \$(cat)" >> "$TMP/docker.log" ;;
  "buildx build")
    meta=""; push=""
    for a in "\$@"; do
      [[ -n "\$want" ]] && { meta="\$a"; want=""; }
      [[ "\$a" == --metadata-file ]] && want=1
      [[ "\$a" == *push=true* ]] && push=1
    done
    echo "SOURCE_DATE_EPOCH=\$SOURCE_DATE_EPOCH" >> "$TMP/docker.log"
    d="\$(cat "$TMP/digest")"; [[ -n "\$push" && -f "$TMP/push-digest" ]] && d="\$(cat "$TMP/push-digest")"
    printf '{"containerimage.digest": "%s"}\n' "\$d" > "\$meta" ;;
  "buildx imagetools") [[ -f "$TMP/existing" ]] && cat "$TMP/existing" || exit 1 ;;
  *) ;;
esac
EOF
cat > "$TMP/bin/gcloud" <<EOF
#!/usr/bin/env bash
echo "gcloud \$*" >> "$TMP/gcloud.log"
case "\$*" in
  "iam workload-identity-pools create-cred-config "*)
    for a in "\$@"; do
      case "\$a" in
        --credential-source-file=*) echo "id-token \$(cat "\${a#*=}")" >> "$TMP/gcloud.log" ;;
        --output-file=*) echo '{}' > "\${a#*=}" ;;
      esac
    done ;;
  "auth print-access-token") echo ya29.stub ;;
esac
EOF
chmod +x "$TMP/bin/"*

NAME=""
fail() { echo "FAIL $NAME: $*" >&2; for f in "$TMP/err" "$TMP/api.log" "$TMP/docker.log"; do [[ -f "$f" ]] && cat "$f" >&2; done; exit 1; }
pass() { echo "ok $NAME"; }
n=0
# looper-build, as a build job runs it: a clean environment (no looper's
# credentials) with the app's variables, a copy of its key file, the inputs.
build() { # [VAR=value...] -- args
  local e=(); while [[ "$1" != -- ]]; do e+=("$1"); shift; done; shift
  n=$((n + 1)); OUT="$TMP/out-$n"; KEY="$TMP/key-$n.pem"; mkdir -p "$OUT" "$TMP/home"
  cp "$TMP/app.pem" "$KEY"
  : > "$TMP/api.log"; : > "$TMP/docker.log"; : > "$TMP/gcloud.log"; : > "$SRV/log"
  env -i PATH="$TMP/bin:$PATH" HOME="$TMP/home" TMPDIR="$TMP" \
    HTTPS_PROXY="http://127.0.0.1:$PORT" GIT_SSL_CAINFO="$SRV/cert.pem" \
    GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t \
    TACPLUS_READER_APP_ID="$APP_ID" TACPLUS_READER_INSTALLATION_ID="$INSTALLATION" TACPLUS_READER_APP_KEY="$KEY" \
    CI_JOB_TOKEN=glcbt-stub CI_PIPELINE_URL=https://gitlab.com/tacplus-dev/build/-/pipelines/1 \
    BUILD_REPO=demo BUILD_OUT="$OUT" "${e[@]}" "$ROOT/looper-build" "$@"
}
verdict_is() { # expected (a prefix)
  [[ -f "$OUT/build-verdict" ]] || fail "no build-verdict"
  [[ "$(cat "$OUT/build-verdict")" == "$1"* ]] || fail "verdict '$(cat "$OUT/build-verdict")', expected '$1...'"
}

# --- plan ---------------------------------------------------------------------
NAME="plan: the gates job runs in the pinned image, on the build runner"
build BUILD_SHA="${SHA[pass]}" -- plan 2>"$TMP/err" || fail "plan failed"
y="$OUT/build-gates.yml"
grep -qxF "  image: \"us-docker.pkg.dev/jody1-328023/tacplus/build:2.6.1@$DIGEST_A\"" "$y" || fail "not the pinned image: $(cat "$y" | head -8)"
grep -qxF "  tags: [arm64, build]" "$y" || fail "not on the build runner"
grep -qxF "    BUILD_SHA: \"${SHA[pass]}\"" "$y" || fail "not the commit"
grep -qxF 'token {"permissions":{"contents":"read","metadata":"read"},"repositories":["demo"]}' "$TMP/api.log" ||
  fail "the plan's token is not contents read-only on the repository: $(cat "$TMP/api.log")"
[[ ! -e "$OUT/plan-src" ]] || fail "the plan left its checkout behind"
pass

NAME="plan: a missing pin is a fail verdict, not a guess"
if build BUILD_SHA="${SHA[nopin]}" -- plan 2>"$TMP/err"; then fail "planned without a pin"; fi
verdict_is "fail: no pin: demo has no tacplus.lock"
[[ ! -e "$OUT/build-gates.yml" ]] || fail "wrote a gates pipeline"
pass

NAME="plan: a pin by tag, not digest, fails"
if build BUILD_SHA="${SHA[tagpin]}" -- plan 2>"$TMP/err"; then fail "planned with a tag"; fi
verdict_is "fail: tacplus.lock: build_image: 'us-docker.pkg.dev/jody1-328023/tacplus/build:2.6' must name the image by digest"
pass

NAME="plan: an image of another line than the pin fails"
if build BUILD_SHA="${SHA[otherline]}" -- plan 2>"$TMP/err"; then fail "planned"; fi
verdict_is "fail: tacplus.lock: build_image"
grep -q "not of the pin's line 2.6" "$OUT/build-verdict" || fail "$(cat "$OUT/build-verdict")"
pass

NAME="plan: a commit that is not there fails"
if build BUILD_SHA="$(printf '1%.0s' {1..40})" -- plan 2>"$TMP/err"; then fail "planned"; fi
verdict_is "fail: tacplus-dev/demo has no commit"
pass

NAME="plan: inputs that are not a repository and a full hash are refused"
if build BUILD_REPO=../x BUILD_SHA="${SHA[pass]}" -- plan 2>"$TMP/err"; then fail "planned"; fi
verdict_is "fail: BUILD_REPO '../x'"
if build BUILD_SHA="${SHA[pass]:0:12}" -- plan 2>"$TMP/err"; then fail "planned"; fi
verdict_is "fail: BUILD_SHA"
pass

NAME="a job that holds a write credential refuses to run, and asks GitHub for nothing"
for c in GH_TOKEN=ghp_x GITHUB_TOKEN=x GITLAB_TOKEN=x CLAUDE_CODE_OAUTH_TOKEN=x GHCR_PUSH_TOKEN=x SOME_VAR=glpat-x OTHER=github_pat_x GCP_ID_TOKEN=x; do
  for cmd in plan gates "status success"; do
    # shellcheck disable=SC2086
    if build BUILD_SHA="${SHA[pass]}" "$c" -- $cmd 2>"$TMP/err"; then fail "$cmd ran with $c"; fi
    verdict_is "fail: this job holds a write credential (${c%%=*})"
    [[ ! -s "$TMP/api.log" ]] || fail "$cmd asked GitHub with $c: $(cat "$TMP/api.log")"
  done
done
pass

NAME="the child pipeline's script is this script, and runs the gates"
build BUILD_SHA="${SHA[pass]}" -- plan 2>"$TMP/err" || fail "plan failed"
child="$TMP/child"; mkdir -p "$child"
# The job's script block, as GitLab hands it to the shell.
sed -n '/^    - |$/,/^  artifacts:$/p' "$OUT/build-gates.yml" | sed '1d;$d' | sed 's/^      //' > "$TMP/child.sh"
cp "$TMP/app.pem" "$TMP/child-key.pem"
env -i PATH="$TMP/bin:$PATH" HOME="$TMP/home" TMPDIR="$TMP" HTTPS_PROXY="http://127.0.0.1:$PORT" GIT_SSL_CAINFO="$SRV/cert.pem" \
  TACPLUS_READER_APP_ID="$APP_ID" TACPLUS_READER_INSTALLATION_ID="$INSTALLATION" TACPLUS_READER_APP_KEY="$TMP/child-key.pem" \
  CI_PROJECT_DIR="$child" BUILD_OUT="$child" BUILD_REPO=demo BUILD_SHA="${SHA[pass]}" \
  bash -e "$TMP/child.sh" 2>"$TMP/err" || fail "the child job failed"
cmp -s "$child/looper-build" "$ROOT/looper-build" || fail "the embedded script differs from looper-build"
[[ "$(cat "$child/build-verdict")" == pass ]] || fail "child verdict $(cat "$child/build-verdict")"
pass

# --- gates ----------------------------------------------------------------------
NAME="gates: the same commit twice gives the same verdict (pass)"
build BUILD_SHA="${SHA[pass]}" -- gates 2>"$TMP/err" || fail "gates failed"
verdict_is pass; v1="$(cat "$OUT/build-verdict")"; log1="$OUT/gates.log"
build BUILD_SHA="${SHA[pass]}" -- gates 2>"$TMP/err" || fail "gates failed the second time"
[[ "$(cat "$OUT/build-verdict")" == "$v1" ]] || fail "second verdict $(cat "$OUT/build-verdict")"
cmp -s "$log1" "$OUT/gates.log" || fail "the gates' output differs"
grep -q "gates ok" "$OUT/gates.log" || fail "just gates did not run: $(cat "$OUT/gates.log")"
pass

NAME="gates: the repository's code sees no job token and no app key, and the key file is gone"
grep -qF "job-token=none key=none app=none" "$OUT/gates.log" || fail "$(cat "$OUT/gates.log")"
[[ ! -e "$KEY" ]] || fail "the app's key file is still there"
grep -qxF 'token {"permissions":{"contents":"read","metadata":"read"}}' "$TMP/api.log" || fail "$(cat "$TMP/api.log")"
pass

NAME="gates: the same commit twice gives the same verdict (fail)"
if build BUILD_SHA="${SHA[fail]}" -- gates 2>"$TMP/err"; then fail "a failing gate passed"; fi
verdict_is "fail: just gates exited 3"; v1="$(cat "$OUT/build-verdict")"
if build BUILD_SHA="${SHA[fail]}" -- gates 2>"$TMP/err"; then fail "a failing gate passed"; fi
[[ "$(cat "$OUT/build-verdict")" == "$v1" ]] || fail "second verdict $(cat "$OUT/build-verdict")"
pass

NAME="gates: a change to a tracked file fails the build"
if build BUILD_SHA="${SHA[dirty]}" -- gates 2>"$TMP/err"; then fail "passed"; fi
verdict_is "fail: the build changed tracked files:  M data.txt"
pass

NAME="gates: a build that pushes cannot: GitHub refuses the credential"
if build BUILD_SHA="${SHA[push]}" -- gates 2>"$TMP/err"; then fail "passed"; fi
verdict_is "fail: just gates exited"
grep -q "^github.com x-access-token:$READ_TOKEN push refused$" "$SRV/log" || fail "no refused push: $(cat "$SRV/log")"
[[ -z "$(git -C "$SRV/repos/github.com/tacplus-dev/demo.git" for-each-ref refs/heads/evil)" ]] || fail "the push landed"
pass

NAME="gates: a source credential that can push is refused before any gate runs"
echo "$WRITE_TOKEN" > "$TMP/token"
if build BUILD_SHA="${SHA[pass]}" -- gates 2>"$TMP/err"; then fail "ran with a credential that can push"; fi
echo "$READ_TOKEN" > "$TMP/token"
verdict_is "fail: the source credential can push to tacplus-dev/demo"
[[ ! -s "$OUT/gates.log" ]] || fail "the gates ran: $(cat "$OUT/gates.log")"
[[ -z "$(git -C "$SRV/repos/github.com/tacplus-dev/demo.git" for-each-ref refs/heads/looper-build-push-probe)" ]] ||
  fail "the probe pushed"
pass

NAME="gates: no gates recipe fails"
if build BUILD_SHA="${SHA[nogates]}" -- gates 2>"$TMP/err"; then fail "passed"; fi
verdict_is "fail: no gates: demo's justfile has no \`gates\` recipe"
pass

# --- status ---------------------------------------------------------------------
NAME="status: the commit status, with a token that can only write statuses on the repository"
build BUILD_SHA="${SHA[pass]}" -- status pending 2>"$TMP/err" || fail "status failed"
grep -qxF 'token {"permissions":{"statuses":"write","metadata":"read"},"repositories":["demo"]}' "$TMP/api.log" || fail "$(cat "$TMP/api.log")"
line="$(grep '^status ' "$TMP/api.log")"
[[ "$line" == "status Bearer $READ_TOKEN ${SHA[pass]} "* ]] || fail "$line"
body="${line#status Bearer "$READ_TOKEN" "${SHA[pass]}" }"
[[ "$(jq -r '[.state, .context, .description, .target_url] | join("|")' <<<"$body")" == \
   "pending|tacplus-dev/build|building|https://gitlab.com/tacplus-dev/build/-/pipelines/1" ]] || fail "$body"
pass

NAME="status: a failure says why"
OUT="$TMP/out-status"; mkdir -p "$OUT"; : > "$TMP/api.log"
echo "fail: no pin: demo has no tacplus.lock at x" > "$OUT/build-verdict"   # the plan's
env -i PATH="$TMP/bin:$PATH" HOME="$TMP/home" TACPLUS_READER_APP_ID="$APP_ID" TACPLUS_READER_INSTALLATION_ID="$INSTALLATION" \
  TACPLUS_READER_APP_KEY="$TMP/app.pem" BUILD_REPO=demo BUILD_SHA="${SHA[pass]}" BUILD_OUT="$OUT" \
  "$ROOT/looper-build" status failure 2>"$TMP/err" || fail "status failed"
[[ "$(grep '^status ' "$TMP/api.log" | sed 's/^status [^{]*//' | jq -r '.state + "|" + .description')" == \
   "failure|no pin: demo has no tacplus.lock at x" ]] || fail "$(cat "$TMP/api.log")"
pass

# --- publish --------------------------------------------------------------------
echo "sha256:$(printf 'b%.0s' {1..64})" > "$TMP/digest"
REL=(BUILD_SHA="${SHA[release]}" BUILD_TAG=v1.2.3 CI_COMMIT_TAG=demo/v1.2.3 CI_COMMIT_REF_NAME=demo/v1.2.3
     GCP_ID_TOKEN=eyJ.stub.id GCP_WIF_PROVIDER=projects/1/locations/global/workloadIdentityPools/p/providers/g)

NAME="publish: the image, reproducible, pushed with a federated token, its digest recorded"
build "${REL[@]}" -- publish 2>"$TMP/err" || fail "publish failed"
img="us-docker.pkg.dev/jody1-328023/tacplus/demo:1.2.3@$(cat "$TMP/digest")"
[[ "$(cat "$OUT/image")" == "$img" ]] || fail "image $(cat "$OUT/image")"
epoch="$(git -C "$work" log -1 --format=%ct "${SHA[release]}")"
[[ "$(grep -c "^SOURCE_DATE_EPOCH=$epoch\$" "$TMP/docker.log")" == 2 ]] || fail "not built twice at the commit's time"
grep -q -- "--provenance=false --sbom=false" "$TMP/docker.log" || fail "attestations"
grep -q -- "--output type=oci,dest=.*,rewrite-timestamp=true" "$TMP/docker.log" || fail "no reproducible oci build"
grep -q -- "--output type=image,name=us-docker.pkg.dev/jody1-328023/tacplus/demo:1.2.3,push=true,oci-mediatypes=true,rewrite-timestamp=true" \
  "$TMP/docker.log" || fail "no reproducible push"
grep -q -- "--driver-opt image=moby/buildkit:v[0-9.]*@sha256:" "$TMP/docker.log" || fail "the builder is not pinned"
grep -qxF "login https://us-docker.pkg.dev ya29.stub" "$TMP/docker.log" || fail "no login with the federated token"
grep -qxF "id-token eyJ.stub.id" "$TMP/gcloud.log" || fail "the id token was not exchanged"
pass

NAME="publish: the emulators are installed once, when the builder lacks a platform"
grep -q "^docker run --rm --privileged tonistiigi/binfmt:[^ ]*@sha256:[0-9a-f]* --install all$" "$TMP/docker.log" ||
  fail "no emulators installed"
[[ "$(grep -c "^docker buildx create" "$TMP/docker.log")" == 2 ]] || fail "the builder was not made again"
build "${REL[@]}" -- publish 2>"$TMP/err" || fail "publish failed"
! grep -q "binfmt" "$TMP/docker.log" || fail "installed the emulators again"
pass

NAME="publish: a build that does not reproduce is not published"
echo "sha256:$(printf 'c%.0s' {1..64})" > "$TMP/push-digest"
if build "${REL[@]}" -- publish 2>"$TMP/err"; then fail "published"; fi
rm "$TMP/push-digest"
verdict_is "fail: not reproducible"
pass

NAME="publish: a release already published with this digest is not pushed again; another digest fails"
printf '{"schemaVersion":2}' > "$TMP/existing"
echo "sha256:$(printf '{"schemaVersion":2}' | sha256sum | cut -d' ' -f1)" > "$TMP/digest"
build "${REL[@]}" -- publish 2>"$TMP/err" || fail "publish failed"
! grep -q "push=true" "$TMP/docker.log" || fail "pushed again"
echo "sha256:$(printf 'b%.0s' {1..64})" > "$TMP/digest"
if build "${REL[@]}" -- publish 2>"$TMP/err"; then fail "published over another digest"; fi
verdict_is "fail: us-docker.pkg.dev/jody1-328023/tacplus/demo:1.2.3 is already published as"
rm "$TMP/existing"
pass

NAME="publish: --dry-run builds and pushes nothing, with no GCP identity"
build BUILD_SHA="${SHA[release]}" BUILD_TAG=v1.2.3 CI_COMMIT_TAG=demo/v1.2.3 -- publish --dry-run 2>"$TMP/err" || fail "dry run failed"
[[ "$(cat "$OUT/image")" == "us-docker.pkg.dev/jody1-328023/tacplus/demo:1.2.3@$(cat "$TMP/digest")" ]] || fail "$(cat "$OUT/image")"
! grep -q "push=true\|^login" "$TMP/docker.log" || fail "pushed"
pass

NAME="publish: only on the build project's protected tag, for the repository's tag at that commit"
if build "${REL[@]}" CI_COMMIT_TAG= CI_COMMIT_REF_NAME=main -- publish 2>"$TMP/err"; then fail "published from main"; fi
verdict_is "fail: a release build of demo v1.2.3 runs on the build project's protected tag demo/v1.2.3, not 'main'"
if build "${REL[@]}" BUILD_SHA="${SHA[pass]}" -- publish 2>"$TMP/err"; then fail "published another commit"; fi
verdict_is "fail: demo's tag v1.2.3 is at '${SHA[release]}', not ${SHA[pass]}"
if build "${REL[@]}" BUILD_TAG= -- publish 2>"$TMP/err"; then fail "published without a tag"; fi
verdict_is "fail: publish needs a release tag"
[[ ! -s "$TMP/docker.log" ]] || fail "built: $(cat "$TMP/docker.log")"
pass

NAME="publish: no write credential either, but its GCP identity"
if build "${REL[@]}" GH_TOKEN=ghp_x -- publish 2>"$TMP/err"; then fail "published with GH_TOKEN"; fi
verdict_is "fail: this job holds a write credential (GH_TOKEN)"
pass

# --- the real thing ---------------------------------------------------------------
# With a docker that runs buildx (a runner, this repository's image), the same
# commit, checked out afresh twice (other file times), gives the same digest.
NAME="publish --dry-run, real buildx: the same commit twice gives the same digest"
real_docker="$(command -v docker || true)"
if [[ -n "$real_docker" ]] && docker buildx version >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  mkdir -p "$TMP/bin-real"; ln -s "$TMP/bin/curl" "$TMP/bin-real/curl"
  digests=()
  for _ in 1 2; do
    build PATH="$TMP/bin-real:$PATH" BUILD_SHA="${SHA[release]}" BUILD_TAG=v1.2.3 CI_COMMIT_TAG=demo/v1.2.3 \
      BUILD_PLATFORMS=linux/arm64,linux/amd64 -- publish --dry-run 2>"$TMP/err" || fail "the real dry run failed"
    digests+=("$(cat "$OUT/image")")
  done
  [[ "${digests[0]}" == "${digests[1]}" && "${digests[0]}" == *@sha256:* ]] || fail "${digests[*]}"
  echo "ok $NAME: ${digests[0]##*@}"
else
  echo "skip $NAME: no docker with buildx here"
fi

echo "looper-build: all passed"
