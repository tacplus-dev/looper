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
# that can push, a missing or bad pin are refused. The security checks
# (looper-scan, looper#49): a planted vulnerable pin and a planted secret
# fail, an unexpired exception passes and an expired one fails, with stub
# scanners shaped as the real ones' output, or the real ones when installed.
# Run: tests/looper-build.test.sh
set -euo pipefail
command -v just >/dev/null || { echo "FAIL: these tests run the gates with just, and there is none here" >&2; exit 1; }
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; SRV="$(mktemp -d)"; pid=""
# Go's module cache, under the temporary home, is read-only: as a model user
# (looper#68), not root, rm -rf cannot remove it without u+w (looper#81).
trap '[[ -n "$pid" ]] && kill "$pid" 2>/dev/null; chmod -R u+w "$TMP" "$SRV" 2>/dev/null; rm -rf "$TMP" "$SRV"' EXIT
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
# A repository that is no tacplus project (the looper's, looper#71): its gates
# are gates.yaml's sets, no justfile, and its pin build.lock, the image by digest.
BLOCK="build_image: ghcr.io/tacplus-dev/looper:main@$DIGEST_A"
git -C "$work" checkout -q --orphan mapped; git -C "$work" rm -rqf --ignore-unmatch . >/dev/null
printf 'tracked\n' > "$work/data.txt"; printf '# the pin\n%s\n' "$BLOCK" > "$work/build.lock"
cat > "$work/gates.yaml" <<'EOF'
# The gate map.
full:
  run: echo "full ran base=${LOOPER_GATES_BASE:-none}"
  minutes: 3
docs:
  run: 'echo "docs ran base=$LOOPER_GATES_BASE" && git diff --name-only "$LOOPER_GATES_BASE" HEAD | grep -qx gates.yaml'
  paths: ["*.md"]
red:
  run: echo "red ran"; exit 4
  paths: [red/]
EOF
git -C "$work" add -A; git -C "$work" commit -qm mapped; SHA[mapped]="$(git -C "$work" rev-parse HEAD)"
case_commit blocktag "$PASS_GATES"; printf 'build_image: ghcr.io/tacplus-dev/looper:main\n' > "$work/build.lock"
git -C "$work" add -A; git -C "$work" commit -qm blocktag; SHA[blocktag]="$(git -C "$work" rev-parse HEAD)"
case_commit generated "$PASS_GATES
    mkdir -p gen target/classes/x target/debug node_modules && echo 'package gen' > gen/spec.go
    echo class > target/classes/x/A.class && echo 'fn x() {}' > target/debug/x.rs && echo x > node_modules/a.js
    mkdir -p target/generated-sources/m && echo '[package]' > target/generated-sources/m/Cargo.toml
generated out:
    mkdir -p {{out}}/model && printf 'package model\n' > {{out}}/model/model.go" "$LOCK"

# The security checks' cases (looper-scan, looper#49): a Go module, clean or
# with a planted vulnerable pin (golang.org/x/text v0.3.0, its vulnerable
# Parse called), a planted secret (made here, never in this file), and the
# exceptions a repository accepts.
AKIA="AKIA""QYLPMN5HHHFPZAM2"
scan_commit() { # name [path content]...
  local name="$1"; shift
  git -C "$work" checkout -q --orphan "$name"
  git -C "$work" rm -rqf --ignore-unmatch . >/dev/null
  printf '%s\n' "$PASS_GATES" > "$work/justfile"; printf '%s\n' "$LOCK" > "$work/tacplus.lock"; printf 'tracked\n' > "$work/data.txt"
  printf 'module example.com/demo\n\ngo 1.22\n' > "$work/go.mod"
  printf 'package main\n\nimport "fmt"\n\nfunc main() { fmt.Println("demo") }\n' > "$work/main.go"
  while (($#)); do mkdir -p "$(dirname "$work/$1")"; printf '%s\n' "$2" > "$work/$1"; shift 2; done
  git -C "$work" add -A; git -C "$work" commit -qm "$name"
  SHA[$name]="$(git -C "$work" rev-parse HEAD)"
}
VULN=(go.mod 'module example.com/demo

go 1.22

require golang.org/x/text v0.3.0'
  go.sum 'golang.org/x/text v0.3.0 h1:g61tztE5qeGQ89tm6NTjjM9VPIm088od1l6aSorWRWg=
golang.org/x/text v0.3.0/go.mod h1:NqM8EUOU14njkJ3fqMW+pc6Ldnwhi/IjpwHt7yyuwOQ='
  main.go 'package main

import (
	"fmt"

	"golang.org/x/text/language"
)

func main() {
	t, _ := language.Parse("en-US")
	fmt.Println(t)
}')
exceptions() { # expires [decided_by]
  printf '# Accepted findings.\nexceptions:\n'
  printf '  - id: %s\n    reason: "the planted pin of the tests"\n    decided_by: %s\n    expires: %s\n' \
    GO-2021-0113 "${2:-jodydadescott}" "$1" CVE-2021-38561 "${2:-jodydadescott}" "$1"
}
scan_commit scanclean
scan_commit scanvuln "${VULN[@]}"
scan_commit scansecret deploy/env.txt "aws_access_key_id = $AKIA"
scan_commit scanexcepted "${VULN[@]}" security-exceptions.yaml "$(exceptions 2099-12-31)"
scan_commit scanexpired "${VULN[@]}" security-exceptions.yaml "$(exceptions 2020-01-31)"
scan_commit scanbadexc "${VULN[@]}" security-exceptions.yaml "$(exceptions 2099-12-31 '""')"
scan_commit scanpod k8s/pod.yaml 'apiVersion: v1
kind: Pod
metadata:
  name: p
spec:
  containers:
    - name: c
      image: nginx
      securityContext:
        privileged: true'
git -C "$work" branch -q main scanclean
git clone -q --bare "$work" "$SRV/repos/github.com/tacplus-dev/demo.git"
git -C "$SRV/repos/github.com/tacplus-dev/demo.git" config uploadpack.allowAnySHA1InWant true
: > "$SRV/log"
python3 -I "$ROOT/tests/git-server.py" "$SRV/repos" "$SRV/cert.pem" "$SRV/key.pem" "$SRV/log" "$SRV/writers" > "$SRV/port" &
pid=$!
for _ in $(seq 50); do [[ -s "$SRV/port" ]] && break; sleep 0.1; done
PORT="$(cat "$SRV/port")"; [[ -n "$PORT" ]] || { echo "FAIL: stub git server did not start" >&2; exit 1; }
# Git reaches github.com through the stub by its own config too: the real
# scanners (below) reach the internet, not through HTTPS_PROXY.
mkdir -p "$TMP/home"; git config --file "$TMP/home/.gitconfig" http.https://github.com/.proxy "http://127.0.0.1:$PORT"

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
    -H) [[ "\$2" == Authorization:* ]] && auth="\${2#Authorization: }"; [[ "\$2" == JOB-TOKEN:* ]] && auth="\$2"; shift 2 ;;
    --upload-file) method=PUT; up="\$2"; shift 2 ;;
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
  "GET https://api.github.com/repos/tacplus-dev/demo")   # its visibility: CodeQL's terms (looper#49)
    echo "repo \$auth" >> "$TMP/api.log"; [[ -f "$TMP/private" ]] && echo '{"private": true}' || echo '{"private": false}' ;;
  # The build project's package registry (looper#49): the latest findings, the SBOMs.
  "GET https://gitlab.example/api/v4/projects/42/packages/generic/security-demo/latest/findings.json")
    echo "package-get \$auth \${url#*/generic/}" >> "$TMP/api.log"
    [[ -f "$TMP/previous.json" ]] || exit 22
    cp "$TMP/previous.json" "\$out" ;;
  "PUT https://gitlab.example/api/v4/projects/42/packages/generic/"*)
    echo "package-put \$auth \${url#*/generic/} \$(sha256sum < "\$up" | cut -c1-12)" >> "$TMP/api.log" ;;
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
# syft, for publish's SBOM: it writes each -o format=file it is given.
cat > "$TMP/bin/syft" <<EOF
#!/usr/bin/env bash
echo "syft \$*" >> "$TMP/syft.log"
while ((\$#)); do
  [[ "\$1" == -o ]] && { printf '{"stub": "%s"}\n' "\${2%%=*}" > "\${2#*=}"; shift; }
  shift
done
EOF
chmod +x "$TMP/bin/"*

# --- the scanners (looper-scan) --------------------------------------------------
# With every scanner installed (the looper image), the security checks run
# for real (the vulnerability databases of the day: the network); else these
# stubs stand for them, each writing what the real tool writes (its JSON, as
# captured from the pinned versions) for the planted pin and secret.
REAL_SCAN=1
for t in osv-scanner govulncheck semgrep gitleaks gosec syft; do command -v "$t" >/dev/null || REAL_SCAN=0; done
SB="$TMP/scanbin"; mkdir -p "$SB"
opt() { echo 'out=""; tree="${@: -1}"; a=("$@"); for ((i = 0; i < ${#a[@]}; i++)); do case "${a[i]}" in '"$1"') out="${a[i+1]}" ;; '"$1"'=*) out="${a[i]#*=}" ;; esac; done'; }
cat > "$SB/osv-scanner" <<EOF
#!/usr/bin/env bash
$(opt --output)
echo "osv-scanner job-token=\${CI_JOB_TOKEN:-none} key=\${TACPLUS_READER_APP_KEY:-none}" >> "$TMP/scan-env"
if grep -qs 'golang.org/x/text v0.3.0' "\$tree/go.mod"; then
  cat > "\$out" <<J
{"results":[{"source":{"path":"\$tree/go.mod","type":"lockfile"},"packages":[{"package":{"name":"golang.org/x/text","version":"0.3.0","ecosystem":"Go"},
 "vulnerabilities":[{"id":"GO-2021-0113","summary":"Out-of-bounds read in golang.org/x/text/language","aliases":["CVE-2021-38561","GHSA-ppp9-7jff-5vj2"],"affected":[{"ranges":[{"type":"SEMVER","events":[{"introduced":"0"},{"fixed":"0.3.7"}]}]}]},
  {"id":"GO-2026-5970","aliases":["CVE-2026-56852"],"affected":[{"ranges":[{"type":"SEMVER","events":[{"introduced":"0"}]}]}]}],
 "groups":[{"ids":["GO-2021-0113","GHSA-ppp9-7jff-5vj2"],"aliases":["CVE-2021-38561","GHSA-ppp9-7jff-5vj2","GO-2021-0113"],"max_severity":"7.5"},
  {"ids":["GO-2026-5970"],"aliases":["CVE-2026-56852","GO-2026-5970"],"max_severity":""}]}]}]}
J
  exit 1
fi
echo '{"results": []}' > "\$out"
EOF
cat > "$SB/govulncheck" <<'EOF'
#!/usr/bin/env bash
echo '{"config":{"protocol_version":"v1.0.0","scanner_name":"govulncheck","scanner_version":"v1.1.4","db":"https://vuln.go.dev","db_last_modified":"2026-10-27T21:16:18Z"}}'
grep -qs 'golang.org/x/text v0.3.0' go.mod || exit 0
echo '{"osv":{"id":"GO-2021-0113","aliases":["CVE-2021-38561","GHSA-ppp9-7jff-5vj2"],"summary":"Out-of-bounds read in golang.org/x/text/language"}}'
echo '{"finding":{"osv":"GO-2021-0113","fixed_version":"v0.3.7","trace":[{"module":"golang.org/x/text","version":"v0.3.0","package":"golang.org/x/text/language","function":"Parse"},{"module":"example.com/demo","package":"example.com/demo","function":"main"}]}}'
echo '{"finding":{"osv":"GO-2021-0113","fixed_version":"v0.3.7","trace":[{"module":"golang.org/x/text","version":"v0.3.0"}]}}'
EOF
cat > "$SB/gitleaks" <<EOF
#!/usr/bin/env bash
$(opt -r)
{ echo '['; grep -rl --exclude-dir=.git AKIA "\$tree" | awk '{ printf "%s{\"RuleID\":\"aws-access-token\",\"Description\":\"AWS credentials\",\"StartLine\":1,\"File\":\"%s\",\"Secret\":\"REDACTED\",\"Fingerprint\":\"%s:aws-access-token:1\"}", (NR > 1 ? "," : ""), \$0, \$0 }'; echo ']'; } > "\$out"
EOF
cat > "$SB/semgrep" <<EOF
#!/usr/bin/env bash
$(opt -o)
echo '{"version":"1.183.0","results":[],"errors":[]}' > "\$out"
EOF
cat > "$SB/gosec" <<EOF
#!/usr/bin/env bash
$(opt -out)
[[ "\$1" == -version ]] && { echo "Version: 2.30.0"; exit; }
echo '{"Issues":[],"Stats":{"files":1}}' > "\$out"
EOF
cat > "$SB/trivy" <<EOF
#!/usr/bin/env bash
$(opt -o)
case "\$1" in
  version) echo '{"Version":"0.76.1","VulnerabilityDB":{"UpdatedAt":"2026-11-01T19:08:08Z","DownloadedAt":"2026-11-01T21:04:18Z"}}'; exit ;;
  fs) if [[ -f "\$tree/k8s/pod.yaml" ]]; then
        echo '{"Results":[{"Target":"k8s/pod.yaml","Class":"config","Type":"kubernetes","Misconfigurations":[{"ID":"KSV-0017","Severity":"HIGH","Status":"FAIL","Title":"Privileged container"}]}]}' > "\$out"
      else echo '{"Results":[]}' > "\$out"; fi ;;
  *) echo "trivy stub: \$*" >&2; exit 1 ;;
esac
EOF
cat > "$SB/codeql" <<EOF
#!/usr/bin/env bash
$(opt --output)
echo "codeql \$*" >> "$TMP/codeql.log"
case "\$1 \$2" in
  "database create") mkdir -p "\$3" ;;
  "database analyze") echo '{"version":"2.1.0","runs":[{"tool":{"driver":{"name":"CodeQL","rules":[{"id":"go/log-injection","properties":{"security-severity":"3.1"}}]}},"results":[{"ruleId":"go/log-injection","level":"error","message":{"text":"log entry from user input"},"locations":[{"physicalLocation":{"artifactLocation":{"uri":"main.go"},"region":{"startLine":5}}}]}]}]}' > "\$out" ;;
esac
EOF
cp "$TMP/bin/syft" "$SB/syft"
chmod +x "$SB/"*

NAME=""
fail() { echo "FAIL $NAME: $*" >&2; for f in "$TMP/err" "$TMP/api.log" "$TMP/docker.log"; do [[ -f "$f" ]] && cat "$f" >&2; done; exit 1; }
pass() { echo "ok $NAME"; }
n=0
# The directory a build runs in is a checkout whose own config sends GitHub
# another credential, as actions/checkout leaves one (looper#58): looper-build
# must not read it, whichever directory it is started in.
cwd="$TMP/checkout"; git init -q "$cwd"
git -C "$cwd" config http.https://github.com/.extraheader "AUTHORIZATION: basic $(printf x-access-token:ghs_checkout | base64)"
# looper-build, as a build job runs it: a clean environment (no looper's
# credentials) with the app's variables, a copy of its key file, the inputs.
build() { # [VAR=value...] -- args
  local e=(); while [[ "$1" != -- ]]; do e+=("$1"); shift; done; shift
  n=$((n + 1)); OUT="$TMP/out-$n"; KEY="$TMP/key-$n.pem"; mkdir -p "$OUT" "$TMP/home"
  cp "$TMP/app.pem" "$KEY"
  : > "$TMP/api.log"; : > "$TMP/docker.log"; : > "$TMP/gcloud.log"; : > "$TMP/syft.log"; : > "$SRV/log"
  (cd "$cwd" && env -i PATH="$TMP/bin:$PATH" HOME="$TMP/home" TMPDIR="$TMP" \
    HTTPS_PROXY="http://127.0.0.1:$PORT" GIT_SSL_CAINFO="$SRV/cert.pem" \
    GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t \
    TACPLUS_READER_APP_ID="$APP_ID" TACPLUS_READER_INSTALLATION_ID="$INSTALLATION" TACPLUS_READER_APP_KEY="$KEY" \
    CI_JOB_TOKEN=glcbt-stub CI_PIPELINE_URL=https://gitlab.com/tacplus-dev/build/-/pipelines/1 \
    BUILD_REPO=demo BUILD_OUT="$OUT" "${e[@]}" "${CMD:-$ROOT/looper-build}" "$@")
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

NAME="plan: a repository that is no tacplus project pins its build image in build.lock (looper#71)"
build BUILD_SHA="${SHA[mapped]}" BUILD_GATES=docs BUILD_BASE="${SHA[pass]}" -- plan 2>"$TMP/err" || fail "plan failed: $(cat "$TMP/err")"
y="$OUT/build-gates.yml"
grep -qxF "  image: \"ghcr.io/tacplus-dev/looper:main@$DIGEST_A\"" "$y" || fail "not build.lock's image: $(head -8 "$y")"
grep -qxF '    BUILD_GATES: "docs"' "$y" && grep -qxF "    BUILD_BASE: \"${SHA[pass]}\"" "$y" || fail "the gate set is not the gates job's: $(head -16 "$y")"
if build BUILD_SHA="${SHA[blocktag]}" -- plan 2>"$TMP/err"; then fail "planned with a tag"; fi
verdict_is "fail: build.lock: build_image: 'ghcr.io/tacplus-dev/looper:main' must name the image by digest"
pass

NAME="plan: a gate set or base that is not one is refused"
if build BUILD_SHA="${SHA[mapped]}" BUILD_GATES='docs;rm' -- plan 2>"$TMP/err"; then fail "planned"; fi
verdict_is "fail: BUILD_GATES 'docs;rm' is not a gate set"
if build BUILD_SHA="${SHA[mapped]}" BUILD_BASE=main -- plan 2>"$TMP/err"; then fail "planned"; fi
verdict_is "fail: BUILD_BASE 'main' is not a full commit hash"
pass

NAME="the looper repository's own pin: build.lock names the looper image by digest (looper#71)"
pin="$(cd "$TMP" && BUILD_OUT="$TMP/own-pin" BUILD_REPO=looper BUILD_SHA="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo HEAD)" \
         bash -c 'mkdir -p "$BUILD_OUT"; source "$1"; read_pin "$2"' _ "$ROOT/looper-build" "$ROOT" 2>"$TMP/err")" ||
  fail "$(cat "$TMP/own-pin/build-verdict" 2>/dev/null) $(cat "$TMP/err")"
[[ "$pin" =~ ^ghcr\.io/tacplus-dev/looper(:[A-Za-z0-9_.-]+)?@sha256:[0-9a-f]{64}$ ]] || fail "build.lock pins '$pin', not the looper image by digest"
[[ ! -e "$ROOT/tacplus.lock" ]] || fail "the looper repository has a tacplus.lock: it is no tacplus project, its pin is build.lock"
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

# Gate sets (looper#71): a build runs the set the manager's diff calls for,
# from the commit's own gates.yaml, with LOOPER_GATES_BASE its base.
NAME="gates: the gate set asked for, from the commit's gates.yaml, on its base"
build BUILD_SHA="${SHA[mapped]}" BUILD_GATES=docs BUILD_BASE="${SHA[pass]}" -- gates 2>"$TMP/err" || fail "gates failed: $(cat "$TMP/err")"
verdict_is pass
grep -qxF "docs ran base=${SHA[pass]}" "$OUT/gates.log" || fail "$(cat "$OUT/gates.log")"
! grep -q "full ran" "$OUT/gates.log" || fail "ran full too"
pass

NAME="gates: no set asked for in a repository with a gates.yaml runs its full, without just"
build BUILD_SHA="${SHA[mapped]}" -- gates 2>"$TMP/err" || fail "gates failed: $(cat "$TMP/err")"
verdict_is pass
grep -qxF "full ran base=none" "$OUT/gates.log" || fail "$(cat "$OUT/gates.log")"
pass

NAME="gates: a red set fails the build; sets run in turn; an unknown set fails"
if build BUILD_SHA="${SHA[mapped]}" BUILD_GATES=full+red -- gates 2>"$TMP/err"; then fail "red passed"; fi
verdict_is "fail: the gates full+red (gates.yaml) exited 4"
grep -q "full ran" "$OUT/gates.log" && grep -q "red ran" "$OUT/gates.log" || fail "$(cat "$OUT/gates.log")"
if build BUILD_SHA="${SHA[mapped]}" BUILD_GATES=nosuch -- gates 2>"$TMP/err"; then fail "passed"; fi
verdict_is "fail: gates.yaml has no gate set nosuch"
if build BUILD_SHA="${SHA[pass]}" BUILD_GATES=docs -- gates 2>"$TMP/err"; then fail "passed"; fi
verdict_is "fail: no gates.yaml: demo maps no gate set docs"
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
build BUILD_SHA="${SHA[mapped]}" BUILD_GATES=docs -- status success 2>"$TMP/err" || fail "status failed"
[[ "$(grep '^status ' "$TMP/api.log" | sed 's/^status [^{]*//' | jq -r '.state + "|" + .description')" == "success|pass: gates docs" ]] ||
  fail "a gate set's pass does not name it: $(cat "$TMP/api.log")"
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
     GCP_ID_TOKEN=eyJ.stub.id GCP_WIF_PROVIDER=projects/1/locations/global/workloadIdentityPools/p/providers/g
     CI_API_V4_URL=https://gitlab.example/api/v4 CI_PROJECT_ID=42)

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

NAME="publish: the release's SBOM, of the image, CycloneDX and SPDX, kept and published"
jq -e '.stub == "cyclonedx-json"' "$OUT/sbom.cdx.json" >/dev/null && jq -e '.stub == "spdx-json"' "$OUT/sbom.spdx.json" >/dev/null ||
  fail "no SBOM: $(ls "$OUT")"
grep -q "^syft scan -q oci-archive:.*/image.tar " "$TMP/syft.log" || fail "not of the image: $(cat "$TMP/syft.log")"
for f in sbom.cdx.json sbom.spdx.json; do
  grep -qxF "package-put JOB-TOKEN: glcbt-stub sbom-demo/1.2.3/$f $(sha256sum < "$OUT/$f" | cut -c1-12)" "$TMP/api.log" ||
    fail "$f not published: $(cat "$TMP/api.log")"
done
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

# --- the security checks (looper-scan, looper#49) ------------------------------------
NAME="plan: the child pipeline runs the security checks in the looper image, after the gates, of the run's kind"
build BUILD_SHA="${SHA[pass]}" -- plan 2>"$TMP/err" || fail "plan failed"
y="$OUT/build-gates.yml"
sed -n '/^security-demo:$/,/^security-report:$/p' "$y" > "$TMP/sec.yml"
grep -qxF '  image: "ghcr.io/tacplus-dev/looper:main"' "$TMP/sec.yml" || fail "not in the looper image: $(cat "$TMP/sec.yml")"
grep -qxF '  needs: [{job: gates, artifacts: true}]' "$TMP/sec.yml" || fail "not after the gates, with their generated code"
grep -qxF '  when: always' "$TMP/sec.yml" || fail "not run when the gates fail"
grep -qxF '    BUILD_SCAN_KIND: "build"' "$TMP/sec.yml" || fail "not a build's checks"
grep -qxF '    - looper-scan run' "$TMP/sec.yml" || fail "does not run looper-scan"
grep -qxF '    paths: [gates.log, build-verdict, built/, generated/]' "$y" || fail "the gates keep no generated code"
sed -n '/^security-report:$/,$p' "$y" | grep -qxF '    - looper-scan report' || fail "no report job"
build BUILD_SHA="${SHA[release]}" BUILD_TAG=v1.2.3 CI_COMMIT_TAG=demo/v1.2.3 -- plan 2>"$TMP/err" || fail "release plan failed"
grep -qxF '    BUILD_SCAN_KIND: "release"' "$OUT/build-gates.yml" || fail "not a release's checks"
pass

NAME="plan: a nightly scans the main branch as it is, and is no release"
build BUILD_SHA= BUILD_NIGHTLY=true -- plan 2>"$TMP/err" || fail "nightly plan failed: $(cat "$OUT/build-verdict" "$TMP/err" 2>/dev/null)"
! grep -q ghs_checkout "$SRV/log" || fail "GitHub got the checkout's credential: $(cat "$SRV/log")"
main_sha="$(git -C "$work" rev-parse main)"
grep -qxF "    BUILD_SHA: \"$main_sha\"" "$OUT/build-gates.yml" || fail "not main's head $main_sha"
grep -qxF '    BUILD_SCAN_KIND: "nightly"' "$OUT/build-gates.yml" || fail "not a nightly's checks"
if build BUILD_SHA= -- plan 2>"$TMP/err"; then fail "planned without a commit"; fi
verdict_is "fail: BUILD_SHA ''"
if build BUILD_SHA="${SHA[pass]}" BUILD_NIGHTLY=true BUILD_TAG=v1.2.3 -- plan 2>"$TMP/err"; then fail "a nightly release"; fi
verdict_is "fail: a nightly build is not a release"
pass

NAME="gates: the code a generated recipe writes is the gates' artifact, for the security checks"
build BUILD_SHA="${SHA[generated]}" -- gates 2>"$TMP/err" || fail "gates failed: $(cat "$TMP/err")"
[[ "$(cat "$OUT/generated/model/model.go")" == "package model" ]] || fail "no generated code: $(ls -R "$OUT")"
[[ "$(cd "$OUT/built" && find . -type f | LC_ALL=C sort | tr '\n' ' ')" == "./gen/spec.go ./target/classes/x/A.class ./target/generated-sources/m/Cargo.toml " ]] ||
  fail "built: $(cd "$OUT/built" && find . -type f)"
build BUILD_SHA="${SHA[pass]}" -- gates 2>"$TMP/err" || fail "gates failed"
[[ ! -e "$OUT/generated" ]] || fail "generated code without a recipe"
pass

# looper-scan, as the security job runs it: the stub scanners unless the real
# ones are here, the build project's API (its package registry) at gitlab.example.
SCAN_API=(CI_API_V4_URL=https://gitlab.example/api/v4 CI_PROJECT_ID=42)
scan() { # [VAR=value...] -- args
  local e=(); while [[ "$1" != -- ]]; do e+=("$1"); shift; done; shift
  local p=(PATH="$TMP/bin:$SB:$PATH")
  ((REAL_SCAN)) && p=(PATH="$TMP/bin:$PATH" HTTPS_PROXY=)
  : > "$TMP/scan-env"; : > "$TMP/codeql.log"
  CMD="$ROOT/looper-scan" build "${p[@]}" "${SCAN_API[@]}" "${e[@]}" -- "$@"
}
scan_verdict_is() { # expected (a prefix)
  [[ -f "$OUT/security/verdict" ]] || fail "no security/verdict: $(tail -5 "$TMP/err")"
  [[ "$(cat "$OUT/security/verdict")" == "$1"* ]] || fail "verdict '$(cat "$OUT/security/verdict")', expected '$1...'"
}
blocking() { jq -r '[.[] | select(.blocking) | .tool + " " + .id + " " + .where] | join("\n")' "$OUT/security/findings.json"; }
echo "(security checks with $( ((REAL_SCAN)) && echo "the real scanners" || echo "stub scanners"))"

NAME="security: a clean commit passes, with its reports, SBOM and what it was checked against"
scan BUILD_SHA="${SHA[scanclean]}" -- run 2>"$TMP/err" || fail "the clean commit failed: $(tail -20 "$TMP/err")"
scan_verdict_is pass
s="$OUT/security"
jq -e 'type == "array" and length == 0' "$s/findings.json" >/dev/null || fail "findings: $(cat "$s/findings.json")"
jq -e '.version == "2.1.0" and (.runs | type == "array")' "$s/findings.sarif" >/dev/null || fail "no SARIF"
[[ -s "$s/sbom.cdx.json" && -s "$s/sbom.spdx.json" ]] || fail "no SBOM"
jq -e '."osv-scanner".queried_at and .govulncheck.db_last_modified and .semgrep.rules' "$s/databases.json" >/dev/null ||
  fail "databases: $(cat "$s/databases.json")"
grep -q '^### Checked against' "$s/summary.md" || fail "summary: $(cat "$s/summary.md")"
ls "$s/raw" | grep -q '^osv-scanner-source.json$' || fail "no raw report: $(ls "$s/raw")"
! ls "$s/raw" | grep -q '^trivy\|^codeql' || fail "a build ran the nightly's tools: $(ls "$s/raw")"
grep -qxF "package-get JOB-TOKEN: glcbt-stub security-demo/latest/findings.json" "$TMP/api.log" ||
  fail "the previous run was not asked for with the job token: $(cat "$TMP/api.log")"
[[ ! -e "$KEY" ]] || fail "the app's key file is still there"
((REAL_SCAN)) || grep -qxF "osv-scanner job-token=none key=none" "$TMP/scan-env" || fail "a scanner saw: $(cat "$TMP/scan-env")"
pass

NAME="security: a planted vulnerable pin fails the build"
if scan BUILD_SHA="${SHA[scanvuln]}" -- run 2>"$TMP/err"; then fail "passed"; fi
scan_verdict_is "fail: "
grep -q "security finding(s) the policy fails" "$OUT/security/verdict" || fail "$(cat "$OUT/security/verdict")"
blocking | grep -q '^osv-scanner GO-[0-9-]* golang.org/x/text@0.3.0 (go.mod)$' || fail "no blocking OSV finding: $(blocking)"
if ((REAL_SCAN)); then
  blocking | grep -q '^govulncheck GO-2021-0113 golang.org/x/text@v0.3.0 (go.mod, called: golang.org/x/text/language.Parse)$' || fail "$(blocking)"
else
  [[ "$(blocking)" == "govulncheck GO-2021-0113 golang.org/x/text@v0.3.0 (go.mod, called: golang.org/x/text/language.Parse)
osv-scanner GO-2021-0113 golang.org/x/text@0.3.0 (go.mod)" ]] || fail "blocking: $(blocking)"
  # Without a score, or a fix, a finding is reported and does not fail.
  jq -e '.[] | select(.id == "GO-2026-5970") | .severity == "UNKNOWN" and .fix == false and .blocking == false' \
    "$OUT/security/findings.json" >/dev/null || fail "$(cat "$OUT/security/findings.json")"
  jq -e '.[] | select(.tool == "osv-scanner" and .id == "GO-2021-0113") | .aliases == ["CVE-2021-38561", "GHSA-ppp9-7jff-5vj2"] and .new' \
    "$OUT/security/findings.json" >/dev/null || fail "aliases: $(cat "$OUT/security/findings.json")"
fi
jq -e '[.runs[].results[] | select(.level == "error")] | length >= 2' "$OUT/security/findings.sarif" >/dev/null || fail "SARIF"
grep -q '^### Failing the policy' "$OUT/security/summary.md" || fail "$(cat "$OUT/security/summary.md")"
cp "$OUT/security/findings.json" "$TMP/vuln-findings.json"
pass

NAME="security: a planted secret fails the build, and no report holds it"
if scan BUILD_SHA="${SHA[scansecret]}" -- run 2>"$TMP/err"; then fail "passed"; fi
scan_verdict_is "fail: "
blocking | grep -q '^gitleaks deploy/env.txt:aws-access-token:1 deploy/env.txt:1$' || fail "no blocking secret: $(blocking)"
! grep -qF "$AKIA" "$OUT/security/findings.json" "$OUT/security/findings.sarif" "$OUT/security/summary.md" "$OUT/security"/raw/gitleaks-* ||
  fail "a report holds the secret"
pass

NAME="security: code the gates generated is scanned too"
mkdir -p "$TMP/out-$((n + 1))/generated/model"; printf 'key = "%s"\n' "$AKIA" > "$TMP/out-$((n + 1))/generated/model/keys.txt"
if scan BUILD_SHA="${SHA[scanclean]}" -- run 2>"$TMP/err"; then fail "passed"; fi
blocking | grep -q '^gitleaks generated/model/keys.txt:aws-access-token:1 generated/model/keys.txt:1$' || fail "$(blocking)"
pass

NAME="security: the checkout is scanned as the gates built it (built/ laid over it)"
mkdir -p "$TMP/out-$((n + 1))/built/gen"; printf 'key = "%s"\n' "$AKIA" > "$TMP/out-$((n + 1))/built/gen/keys.txt"
if scan BUILD_SHA="${SHA[scanclean]}" -- run 2>"$TMP/err"; then fail "passed"; fi
blocking | grep -q '^gitleaks gen/keys.txt:aws-access-token:1 gen/keys.txt:1$' || fail "$(blocking)"
mkdir -p "$TMP/out-$((n + 1))/built"; printf 'changed\n' > "$TMP/out-$((n + 1))/built/main.go"
if scan BUILD_SHA="${SHA[scanclean]}" -- run 2>"$TMP/err"; then fail "passed"; fi
scan_verdict_is "fail: the gates' built files change tracked files"
pass

NAME="security: an unexpired exception passes; an expired one, or one that does not say who decided, fails"
if ((REAL_SCAN)); then
  # The real databases name more than the planted findings: an exception for
  # each the planted pin's run failed on, in a commit pushed to the origin now.
  git -C "$work" checkout -q scanvuln && git -C "$work" checkout -q -b scanreal
  { printf 'exceptions:\n'
    jq -r '[.[] | select(.blocking) | .id] | unique[] | "  - id: \(.)\n    reason: \"the planted pin of the tests\"\n    decided_by: jodydadescott\n    expires: 2099-12-31"' \
      "$TMP/vuln-findings.json"; } > "$work/security-exceptions.yaml"
  git -C "$work" add -A; git -C "$work" commit -qm scanreal
  git -C "$work" push -q "$SRV/repos/github.com/tacplus-dev/demo.git" HEAD:refs/heads/scanreal
  scan BUILD_SHA="$(git -C "$work" rev-parse HEAD)" -- run 2>"$TMP/err" || fail "the excepted commit failed: $(cat "$OUT/security/verdict")"
  scan_verdict_is pass
  jq -e '[.[] | select(.excepted)] | length > 0' "$OUT/security/findings.json" >/dev/null || fail "nothing accepted"
else
  scan BUILD_SHA="${SHA[scanexcepted]}" -- run 2>"$TMP/err" || fail "the excepted commit failed: $(cat "$OUT/security/verdict")"
  scan_verdict_is pass
  [[ "$(jq -r '[.[] | select(.excepted) | .tool + ":" + .excepted] | join(" ")' "$OUT/security/findings.json")" == \
     "govulncheck:GO-2021-0113 osv-scanner:GO-2021-0113" ]] || fail "$(cat "$OUT/security/findings.json")"
  grep -q '^### Accepted (security-exceptions.yaml)' "$OUT/security/summary.md" || fail "$(cat "$OUT/security/summary.md")"
fi
if scan BUILD_SHA="${SHA[scanexpired]}" -- run 2>"$TMP/err"; then fail "an expired exception passed"; fi
scan_verdict_is "fail: exception GO-2021-0113 expired on 2020-01-31 (jodydadescott: the planted pin of the tests)"
blocking | grep -q '^osv-scanner GO-2021-0113' || fail "an expired exception still accepts: $(blocking)"
if scan BUILD_SHA="${SHA[scanbadexc]}" -- run 2>"$TMP/err"; then fail "an exception without decided_by passed"; fi
scan_verdict_is "fail: exception GO-2021-0113: it needs a reason and who decided (decided_by)"
pass

NAME="security: findings are compared with the previous run's: the new ones are listed"
if ((REAL_SCAN)); then
  jq '[.[] | select(.tool != "govulncheck")]' "$TMP/vuln-findings.json" > "$TMP/previous.json"
else
  jq '[.[] | select(.tool == "osv-scanner")]' "$TMP/vuln-findings.json" > "$TMP/previous.json"
fi
if scan BUILD_SHA="${SHA[scanvuln]}" -- run 2>"$TMP/err"; then fail "passed"; fi
rm "$TMP/previous.json"
[[ "$(jq -r '[.[] | select(.new) | .tool] | unique | join(" ")' "$OUT/security/findings.json")" == govulncheck ]] ||
  fail "new: $(jq -c '[.[] | select(.new)]' "$OUT/security/findings.json")"
sed -n '/^### New since the previous run/,/^$/p' "$OUT/security/summary.md" | grep -q '^- HIGH govulncheck GO-2021-0113' ||
  fail "$(cat "$OUT/security/summary.md")"
pass

NAME="security: the report publishes the run's findings as the repository's latest, with the job token"
v="$OUT"
scan BUILD_SHA="${SHA[scanvuln]}" BUILD_OUT="$v" -- report 2>"$TMP/err" > "$TMP/report.out" || fail "report failed: $(cat "$TMP/err")"
grep -qxF "package-put JOB-TOKEN: glcbt-stub security-demo/latest/findings.json $(sha256sum < "$v/security/findings.json" | cut -c1-12)" "$TMP/api.log" ||
  fail "$(cat "$TMP/api.log")"
grep -q "^package-put JOB-TOKEN: glcbt-stub security-demo/latest/summary.md " "$TMP/api.log" || fail "$(cat "$TMP/api.log")"
grep -q '^## Security checks: demo ' "$TMP/report.out" || fail "the summary is not in the job's log"
pass

NAME="security: a scanner the image lacks fails the run"
if ((REAL_SCAN)); then
  echo "skip $NAME: the real scanners are here"
else
  mkdir -p "$TMP/scanbin-less"; cp "$SB"/* "$TMP/scanbin-less/"; rm "$TMP/scanbin-less/gosec"
  if CMD="$ROOT/looper-scan" build PATH="$TMP/bin:$TMP/scanbin-less:$PATH" "${SCAN_API[@]}" BUILD_SHA="${SHA[scanclean]}" -- run 2>"$TMP/err"; then
    fail "passed without gosec"
  fi
  scan_verdict_is "fail: gosec: not in this image"
  pass
fi

NAME="security: a nightly adds CodeQL and Trivy (Kubernetes manifests): a privileged pod fails it, not a build"
mkdir -p "$TMP/scanbin-nightly"; cp "$SB/codeql" "$SB/trivy" "$TMP/scanbin-nightly/"
SCAN_API+=(PATH="$TMP/bin:$TMP/scanbin-nightly:$( ((REAL_SCAN)) || echo "$SB:")$PATH")
if scan BUILD_SHA="${SHA[scanpod]}" BUILD_SCAN_KIND=nightly -- run 2>"$TMP/err"; then fail "passed"; fi
blocking | grep -qxF 'trivy KSV-0017 k8s/pod.yaml' || fail "$(blocking)"
grep -q "^codeql database create .* --language=go --build-mode=autobuild " "$TMP/codeql.log" || fail "no CodeQL: $(cat "$TMP/codeql.log")"
jq -e '.[] | select(.tool == "codeql") | .id == "go/log-injection" and .severity == "LOW" and .where == "main.go:5"' \
  "$OUT/security/findings.json" >/dev/null || fail "$(cat "$OUT/security/findings.json")"
jq -e '.trivy.updated_at' "$OUT/security/databases.json" >/dev/null || fail "no Trivy database time"
scan BUILD_SHA="${SHA[scanpod]}" -- run 2>"$TMP/err" || fail "a build ran Trivy: $(cat "$OUT/security/verdict")"
touch "$TMP/private"
if scan BUILD_SHA="${SHA[scanpod]}" BUILD_SCAN_KIND=nightly -- run 2>"$TMP/err"; then fail "passed"; fi
rm "$TMP/private"
[[ ! -s "$TMP/codeql.log" ]] || fail "CodeQL ran on a private repository"
grep -q "^- codeql: not run: demo is not known to be public" "$OUT/security/summary.md" || fail "$(cat "$OUT/security/summary.md")"
unset 'SCAN_API[-1]'
pass

NAME="security: a write credential is refused"
if scan BUILD_SHA="${SHA[scanclean]}" GH_TOKEN=ghp_x -- run 2>"$TMP/err"; then fail "ran with GH_TOKEN"; fi
scan_verdict_is "fail: this job holds a write credential (GH_TOKEN)"
pass

# --- the real thing ---------------------------------------------------------------
# With a docker that runs buildx (a runner, this repository's image), the same
# commit, checked out afresh twice (other file times), gives the same digest.
NAME="publish --dry-run, real buildx: the same commit twice gives the same digest"
real_docker="$(command -v docker || true)"
if [[ -n "$real_docker" ]] && docker buildx version >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  mkdir -p "$TMP/bin-real"; ln -s "$TMP/bin/curl" "$TMP/bin-real/curl"
  command -v syft >/dev/null || ln -s "$TMP/bin/syft" "$TMP/bin-real/syft"   # the SBOM, real where syft is
  digests=()
  for _ in 1 2; do
    build PATH="$TMP/bin-real:$PATH" BUILD_SHA="${SHA[release]}" BUILD_TAG=v1.2.3 CI_COMMIT_TAG=demo/v1.2.3 \
      BUILD_PLATFORMS=linux/arm64,linux/amd64 -- publish --dry-run 2>"$TMP/err" || fail "the real dry run failed"
    digests+=("$(cat "$OUT/image")")
  done
  [[ "${digests[0]}" == "${digests[1]}" && "${digests[0]}" == *@sha256:* ]] || fail "${digests[*]}"
  [[ -s "$OUT/sbom.cdx.json" && -s "$OUT/sbom.spdx.json" ]] || fail "no SBOM of the image"
  echo "ok $NAME: ${digests[0]##*@}"
else
  echo "skip $NAME: no docker with buildx here"
fi

echo "looper-build: all passed"
