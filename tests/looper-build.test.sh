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
    mkdir -p target/lib svc/build/libs node_modules/x/target && echo jar > target/demo-1.0.jar && echo jar > svc/build/libs/svc-1.0.jar
    echo jar > target/demo-1.0-sources.jar && echo jar > target/original-demo-1.0.jar && echo jar > target/lib/dep.jar && echo jar > node_modules/x/target/x.jar
    mkdir -p target/generated-sources/model/src target/generated-sources/model/node_modules client/gen/model
    echo '{}' > target/generated-sources/model/registry.json && echo '# Agent' > target/generated-sources/model/AGENT.md
    : > target/generated-sources/model/src/lib.rs && echo x > target/generated-sources/model/node_modules/a.json
    echo '{}' > target/other.json && echo 'openapi: 3.0.0' > client/gen/model/openapi.yaml
generated out:
    mkdir -p {{out}}/model && printf 'package model\n' > {{out}}/model/model.go" "$LOCK"
# A tacplus project (gateway's shape, looper#155): its src/registry.rs compiles
# in files tacplus generates in its output-dir that are no source (.json, .md),
# and a client subproject's tacplus.yaml generates its own tree (looper#149).
mkdir -p "$work/src" "$work/client"
printf 'language: rust\noutput-dir: target/generated-sources/model  # the crates the gates generate\n' > "$work/tacplus.yaml"
printf 'language: go\noutput-dir: gen/\n' > "$work/client/tacplus.yaml"
printf 'const REGISTRY_JSON: &str = include_str!("../target/generated-sources/model/registry.json");\nconst AGENT_MD: &str = include_str!("../target/generated-sources/model/AGENT.md");\n' > "$work/src/registry.rs"
git -C "$work" add -A; git -C "$work" commit -qm "the tacplus configs"; SHA[generated]="$(git -C "$work" rev-parse HEAD)"
# A tacplus project whose justfile runs tacplus through a wrapper that needs
# Docker (kernel's, eventbus's tools/tacplus.sh) unless TACPLUS_BIN names one
# (looper#137): the build job, in the pinned image, has the image's own.
case_commit tacplus 'TACPLUS := env_var_or_default("TACPLUS_BIN", "tools/tacplus.sh")
gates:
    echo "tacplus=${TACPLUS_BIN:-none}"
    {{TACPLUS}} build --tag latest
generated out:
    echo "generated tacplus=${TACPLUS_BIN:-none}"' "$LOCK"
mkdir -p "$work/tools"; printf '#!/bin/sh\necho "tacplus.sh: docker run: no Docker here" >&2; exit 1\n' > "$work/tools/tacplus.sh"
chmod +x "$work/tools/tacplus.sh"; git -C "$work" add -A; git -C "$work" commit -qm "the wrapper"; SHA[tacplus]="$(git -C "$work" rev-parse HEAD)"

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
# A Java service whose release jar shades a vulnerable dependency (kernel#59:
# Hazelcast's shaded Jackson, jackson-databind 2.9.8 here), and the exception
# a repository may take for it.
JAR_CVE=CVE-2020-36518
scan_commit scanjarexc security-exceptions.yaml "exceptions:
  - id: $JAR_CVE
    reason: \"the shaded jackson-databind of the tests\"
    decided_by: jodydadescott
    expires: 2099-12-31"
# A jar (stored, so its pom.properties reads as text) holding its own and a
# shaded dependency's Maven metadata.
shaded_jar() { # file group:artifact:version...
  mkdir -p "$(dirname "$1")"
  python3 -I - "$@" <<'EOF'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1], "w", zipfile.ZIP_STORED) as z:
    z.writestr("META-INF/MANIFEST.MF", "Manifest-Version: 1.0\n")
    for gav in sys.argv[2:]:
        g, a, v = gav.split(":")
        z.writestr(f"META-INF/maven/{g}/{a}/pom.properties", f"groupId={g}\nartifactId={a}\nversion={v}\n")
EOF
}
# A service's tacplus.yaml: its generated tree is the output-dir (looper#108),
# ending in the output-name as tacplus nests it (blobstore's).
scan_commit scangen tacplus.yaml 'language: go
output-dir: "tacplus"
output-name: tacplus
src: proto' .gitignore 'tacplus/'
# The output-dir's output-name (looper#152): operator's `output-dir: .` with
# `output-name: tacplus` (from the base it imports here) generates tacplus/; a
# client's `output-dir: gen` with no output-name, gen/model/.
scan_commit scangen3 tacplus.yaml 'import: tacplus-base.yaml
output-dir: .' tacplus-base.yaml 'language: go
output-name: "tacplus"  # the generated package' client/tacplus.yaml 'language: go
output-dir: gen/' .gitignore 'tacplus/
client/gen/model/'
# Two tacplus configs (looper#149): the root's output-dir from the base it
# imports, a client subproject's its own; server/ is the service's own codegen.
scan_commit scangen2 tacplus.yaml 'import: config/tacplus-base.yaml  # the shared fields
pkg: com.example.demo' config/tacplus-base.yaml 'language: java
output-dir: tacplus/target/generated-sources/' client/tacplus.yaml "language: go
output-dir: 'gen'" .gitignore 'target/
client/gen/'
# A Java project: SpotBugs reads the target/classes the gates compiled.
scan_commit scanjava src/main/java/demo/Main.java 'package demo;

public class Main { public static void main(String[] a) { } }' .gitignore 'target/'
# Test code (looper#179): a Rust file whose #[cfg(test)] modules hold the
# lines marked test, around and between the lines marked production.
scan_commit scantest src/auth.rs 'pub fn nonce() -> [u8; 12] {
    let n = [0u8; 12]; // production
    n
}

#[cfg(test)]
#[allow(clippy::unwrap_used)]
mod tests {
    use super::*;
    const BRACE: &str = "}";
    const C: char = '"'"'}'"'"';
    /* } a brace /* nested } */ in a comment */
    fn life<'"'"'a>(x: &'"'"'a str) -> &'"'"'a str { x }
    #[test]
    fn empty_nonce() {
        let r = r#"{"nonce": "}"}"#;
        let s = "a line \
          and } its continuation";
        assert_eq!(nonce().len(), 12, "{r} {s}"); // test
    }
}

pub fn after() -> &'"'"'static str {
    "after the test module" // production
}

#[cfg(not(test))]
mod prod {
    pub const KEY: [u8; 4] = [0; 4]; // production
}

#[cfg(test)]
fn helper() -> [u8; 4] { [0; 4] }
pub const AFTER_A_TEST_FN: [u8; 4] = [0; 4]; // production

mod outer {
    #[cfg(test)]
    pub(crate) mod inner_tests
    {
        fn t() { let _ = [1u8; 4]; } // test
    }
    pub fn real() -> [u8; 4] { [0; 4] } // production
}' src/tests.rs 'pub const NOT_A_TEST: [u8; 4] = [0; 4];'
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
# A recorded baseline (looper#146): two files written 0644 (gosec's G306,
# MEDIUM), baselined; then the same two moved down by an edit above them and a
# third beside them; the planted pin with a baseline that names its HIGH
# finding too; a baseline without counts.
WRITES='	_ = os.WriteFile("a.txt", []byte("a"), 0644)
	_ = os.WriteFile("b.txt", []byte("b"), 0644)'
scan_commit scanbase main.go "package main

import \"os\"

func main() {
$WRITES
}"
G306_BASELINE='[
  {"count":2,"file":"main.go","id":"G306","tool":"gosec"}
]'
scan_commit scanbased main.go "package main

import \"os\"

// main writes three files,
// each readable by all.
func main() {
$WRITES
	_ = os.WriteFile(\"c.txt\", []byte(\"c\"), 0644)
}" security-baseline.json "$G306_BASELINE"
scan_commit scanvulnbase "${VULN[@]}" security-baseline.json '[{"tool":"osv-scanner","id":"GO-2021-0113","file":"golang.org/x/text@0.3.0 (go.mod)","count":1},
 {"tool":"osv-scanner","id":"GO-2026-5970","file":"golang.org/x/text@0.3.0 (go.mod)","count":1}]'
scan_commit scanbadbase security-baseline.json '[{"tool":"gosec","id":"G306","file":"main.go"}]'
# A Rust service as tacplus's are (gateway, looper#126): its Cargo.toml
# path-depends on the crates its tacplus.yaml output-dir holds, which only a
# build generates; its Cargo.lock locks what they depend on (rustix 1.1.4,
# RUSTSEC-2026-0486).
RUST_SVC=(tacplus.yaml 'language: rust
output-dir: target/generated-sources/model  # the crates the gates generate'
  Cargo.toml '[package]
name = "demo"
version = "1.0.0"
edition = "2021"
license = "Apache-2.0"

[dependencies]
demo-model = { path = "target/generated-sources/model" }
demo-grpcserver = { package = "grpcserver", path = "target/generated-sources/model/chassis/grpcserver" }'
  Cargo.lock 'version = 4

[[package]]
name = "demo"
version = "1.0.0"
dependencies = [
 "demo-model",
 "grpcserver",
]

[[package]]
name = "demo-model"
version = "1.0.0"

[[package]]
name = "grpcserver"
version = "1.0.0"
dependencies = [
 "rustix",
 "tacplus-chassis",
]

[[package]]
name = "rustix"
version = "1.1.4"
source = "registry+https://github.com/rust-lang/crates.io-index"
checksum = "0000000000000000000000000000000000000000000000000000000000000000"

[[package]]
name = "tacplus-chassis"
version = "0.3.0"
source = "git+https://github.com/tacplus-dev/chassis?tag=v0.3.0#0123456789abcdef0123456789abcdef01234567"'
  src/main.rs 'fn main() {}')
scan_commit scanrust "${RUST_SVC[@]}"
# What the gates generate for it: the output-dir's crates.
rust_generated() { # dir
  mkdir -p "$1/chassis/grpcserver/src" "$1/src"
  printf '[package]\nname = "demo-model"\nversion = "1.0.0"\nedition = "2021"\n' > "$1/Cargo.toml"
  printf '[package]\nname = "grpcserver"\nversion = "1.0.0"\nedition = "2021"\n\n[dependencies]\nrustix = "1"\n' > "$1/chassis/grpcserver/Cargo.toml"
  : > "$1/src/lib.rs"; : > "$1/chassis/grpcserver/src/lib.rs"
}
# Formal verification (looper#74; tacplus-dev/tacplus#275): `just verify` is
# red when the commit has a file red (printed as tacplus verify's report);
# `just verify-changed SHA` prints skip only when it has SHA (fetched) and
# deps/ is unchanged since, else run, as tacplus's does.
VERIFY_JUST='gates:
    echo gates
verify:
    echo "verify ran job-token=${CI_JOB_TOKEN:-none} key=${TACPLUS_READER_APP_KEY:-none}"
    echo "verify tacplus=${TACPLUS_BIN:-none}"
    if [ -f red ]; then cat red; exit 1; fi
verify-changed SHA="":
    @if [ -n "{{SHA}}" ] && git cat-file -e "{{SHA}}^{commit}" 2>/dev/null && git diff --quiet "{{SHA}}" -- deps/; then echo "skip: unchanged since {{SHA}}, verified then"; else echo run; fi'
case_commit verify1 "$VERIFY_JUST" "$LOCK"
vcommit() { # name path content
  mkdir -p "$(dirname "$work/$2")"; printf '%s\n' "$3" > "$work/$2"
  git -C "$work" add -A; git -C "$work" commit -qm "$1"; SHA[$1]="$(git -C "$work" rev-parse HEAD)"
}
vcommit verify1 deps/a 1
vcommit verify2 other.txt x     # nothing verification depends on
vcommit verify3 deps/a 2        # something it depends on
vcommit verifyred red '=== verify rust ===
## Rust -- kani (Bounded Model Checking)

### com.example.Msg -- verify_ok
**Status:** VERIFIED

### com.example.Msg -- verify_port_bounds
**Status:** FAILED
**Detail:**
```
Counterexample: port = 65536
```

=== verify rust: FAIL (rc=1; report: target/verify/rust/verification-report.md) ==='
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
method=GET data="" auth="" url="" out="" w=""
while ((\$#)); do
  case "\$1" in
    -X) method="\$2"; shift 2 ;;
    -w) w="\$2"; shift 2 ;;
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
  "GET https://api.github.com/repos/tacplus-dev/demo/commits/"*"/statuses?per_page=100")   # the statuses set so far: \$TMP/statuses
    echo "statuses \$auth" >> "$TMP/api.log"; cat "$TMP/statuses" 2>/dev/null || echo '[]' ;;
  # The org's repositories, as the app's installation sees them (looper#164): \$TMP/installation-<page>.
  "GET https://api.github.com/installation/repositories?per_page=100&page="*)
    echo "installation-repos \$auth page=\${url##*page=}" >> "$TMP/api.log"
    [[ -f "$TMP/installation-\${url##*page=}" ]] || exit 22
    cat "$TMP/installation-\${url##*page=}" ;;
  # A pin on a repository's main: \$TMP/pins/<repo>/<file> holds GitHub's answer, 200 or another; none, 404.
  "GET https://api.github.com/repos/tacplus-dev/"*"/contents/"*"?ref=main")
    p="\${url#https://api.github.com/repos/tacplus-dev/}"; p="\${p%%\?*}"; r="\${p%%/*}"; f="\${p##*/}"
    echo "contents \$auth \$r \$f" >> "$TMP/api.log"
    code="\$(cat "$TMP/pins/\$r/\$f" 2>/dev/null || echo 404)"
    [[ -z "\$w" ]] || printf '%s' "\$code" ;;
  "GET https://api.github.com/repos/tacplus-dev/demo")   # its visibility: CodeQL's terms (looper#49)
    echo "repo \$auth" >> "$TMP/api.log"; [[ -f "$TMP/private" ]] && echo '{"private": true}' || echo '{"private": false}' ;;
  # The build project's package registry (looper#49): the latest findings, the SBOMs.
  "GET https://gitlab.example/api/v4/projects/42/packages/generic/security-demo/latest/findings.json")
    echo "package-get \$auth \${url#*/generic/}" >> "$TMP/api.log"
    [[ -f "$TMP/previous.json" ]] || exit 22
    cp "$TMP/previous.json" "\$out" ;;
  # A commit's findings (looper#180): a land's base's, \$TMP/base-findings.json.
  "GET https://gitlab.example/api/v4/projects/42/packages/generic/security-demo/"*"/findings.json")
    echo "package-get \$auth \${url#*/generic/}" >> "$TMP/api.log"
    [[ -f "$TMP/base-findings.json" ]] || exit 22
    cp "$TMP/base-findings.json" "\$out" ;;
  # The last formal verification's record (looper#74): \$TMP/verify-record.
  "GET https://gitlab.example/api/v4/projects/42/packages/generic/verify-demo/latest/record")
    echo "package-get \$auth \${url#*/generic/}" >> "$TMP/api.log"
    [[ -f "$TMP/verify-record" ]] || exit 22
    cp "$TMP/verify-record" "\$out" ;;
  # Artifact Registry's manifest of the release (publish's check for an image already there): \$TMP/existing, else 404;
  # \$TMP/registry-code another answer.
  "GET https://us-docker.pkg.dev/v2/jody1-328023/tacplus/demo/manifests/1.2.3")
    echo "manifest \$auth" >> "$TMP/api.log"
    code=404; [[ -f "$TMP/existing" ]] && code=200; [[ -f "$TMP/registry-code" ]] && code="\$(cat "$TMP/registry-code")"
    [[ "\$code" != 200 ]] || cp "$TMP/existing" "\$out"
    printf '%s' "\$code" ;;
  "PUT https://gitlab.example/api/v4/projects/42/packages/generic/"*)
    echo "package-put \$auth \${url#*/generic/} \$(sha256sum < "\$up" | cut -c1-12)" >> "$TMP/api.log" ;;
  *) echo "curl stub: \$method \$url" >&2; exit 22 ;;
esac
EOF

# --- buildx, rootless BuildKit and Workload Identity Federation -----------------
# The registry credential a client reads (\$DOCKER_CONFIG/config.json), decoded, for a stub's log.
REGISTRY_AUTH='registry_auth() { jq -r '"'"'.auths["us-docker.pkg.dev"].auth // "none"'"'"' "${DOCKER_CONFIG:-$HOME/.docker}/config.json" 2>/dev/null | base64 -d 2>/dev/null || echo none; }'
cat > "$TMP/bin/docker" <<EOF
#!/usr/bin/env bash
$REGISTRY_AUTH
echo "docker \$*" >> "$TMP/docker.log"
case "\$1 \${2:-}" in
  "buildx inspect")   # amd64 once the emulators are installed
    echo "Platforms: linux/arm64*, linux/arm/v7\$( [[ -f "$TMP/emulated" ]] && echo ', linux/amd64, linux/amd64/v2' )" ;;
  "run --rm") [[ "\$*" == *binfmt*--install* ]] && touch "$TMP/emulated" ;;
  "buildx build")
    meta=""; push=""
    for a in "\$@"; do
      [[ -n "\$want" ]] && { meta="\$a"; want=""; }
      [[ "\$a" == --metadata-file ]] && want=1
      [[ "\$a" == *push=true* ]] && push=1
    done
    echo "SOURCE_DATE_EPOCH=\$SOURCE_DATE_EPOCH" >> "$TMP/docker.log"
    [[ -z "\$push" ]] || echo "auth \$(registry_auth)" >> "$TMP/docker.log"
    d="\$(cat "$TMP/digest")"; [[ -n "\$push" && -f "$TMP/push-digest" ]] && d="\$(cat "$TMP/push-digest")"
    printf '{"containerimage.digest": "%s"}\n' "\$d" > "\$meta" ;;
  *) ;;
esac
EOF
# Rootless BuildKit in the build image (tacplus-dev/tacplus#315): tacplus-image-build starts
# the daemon and prints its address; buildctl builds, as docker's stub does. In \$TMP/bk,
# on PATH only for a job in an image that has them.
mkdir -p "$TMP/bk"
cat > "$TMP/bk/tacplus-image-build" <<EOF
#!/usr/bin/env bash
echo "tacplus-image-build \$*" >> "$TMP/buildctl.log"
case "\$1" in
  start) [[ -f "$TMP/no-userns" ]] && { echo "tacplus-image-build: rootless BuildKit did not start" >&2; exit 2; }
         echo unix:///run/buildkit/buildkitd.sock ;;
  stop) ;;
  *) echo "tacplus-image-build stub: \$*" >&2; exit 2 ;;
esac
EOF
cat > "$TMP/bk/buildctl" <<EOF
#!/usr/bin/env bash
$REGISTRY_AUTH
echo "buildctl BUILDKIT_HOST=\${BUILDKIT_HOST:-} \$*" >> "$TMP/buildctl.log"
meta="" push="" dest=""
while ((\$#)); do
  case "\$1" in
    --metadata-file) meta="\$2"; shift ;;
    --output) [[ "\$2" == *push=true* ]] && push=1; [[ "\$2" == type=oci,dest=* ]] && { dest="\${2#type=oci,dest=}"; dest="\${dest%%,*}"; } ;;
  esac
  shift
done
[[ -z "\$push" ]] || echo "auth \$(registry_auth)" >> "$TMP/buildctl.log"
[[ -z "\$dest" ]] || echo "an oci archive" > "\$dest"
d="\$(cat "$TMP/digest")"; [[ -n "\$push" && -f "$TMP/push-digest" ]] && d="\$(cat "$TMP/push-digest")"
printf '{"containerimage.digest": "%s"}\n' "\$d" > "\$meta"
EOF
chmod +x "$TMP/bk/"*
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
# G306 at each os.WriteFile (each writes 0644) and G402 at each InsecureSkipVerify, as gosec reports them.
grep -rn --include='*.go' -e 'os.WriteFile(' -e 'InsecureSkipVerify: true' . | jq -Rs --arg pwd "\$PWD" '{Issues: [split("\n")[] | capture("^[.]/(?<f>[^:]+):(?<l>[0-9]+):(?<t>.*)")
  | if (.t | contains("InsecureSkipVerify")) then {severity: "HIGH", cwe: {id: "295"}, rule_id: "G402", details: "TLS InsecureSkipVerify set true."}
    else {severity: "MEDIUM", cwe: {id: "276"}, rule_id: "G306", details: "Expect WriteFile permissions to be 0600 or less"} end
    + {confidence: "HIGH", file: (\$pwd + "/" + .f), line: .l}], Stats: {files: 1}}' > "\$out"
EOF
cat > "$SB/trivy" <<EOF
#!/usr/bin/env bash
$(opt -o)
case "\$1" in
  version) echo '{"Version":"0.76.1","VulnerabilityDB":{"UpdatedAt":"2026-11-01T19:08:08Z","DownloadedAt":"2026-11-01T21:04:18Z"}}'; exit ;;
  fs) if [[ -f "\$tree/k8s/pod.yaml" ]]; then
        echo '{"Results":[{"Target":"k8s/pod.yaml","Class":"config","Type":"kubernetes","Misconfigurations":[{"ID":"KSV-0017","Severity":"HIGH","Status":"FAIL","Title":"Privileged container"}]}]}' > "\$out"
      else echo '{"Results":[]}' > "\$out"; fi ;;
  # The release jars (looper#147): jackson-databind 2.9.8, shaded in a jar, has its CVE at the jar's path.
  rootfs) echo "trivy \$* (\$(cd "\$tree" && find . -type f | sed 's:^\./::' | LC_ALL=C sort | paste -sd ' ' -))" >> "$TMP/trivy.log"
    for j in \$(cd "\$tree" && grep -rla --include='*.jar' 'artifactId=jackson-databind' . | sed 's:^\./::' | LC_ALL=C sort); do
      grep -aq 'version=2.9.8' "\$tree/\$j" || continue
      jq -cn --arg p "\$j" '{VulnerabilityID: "$JAR_CVE", PkgName: "com.fasterxml.jackson.core:jackson-databind", PkgPath: \$p, InstalledVersion: "2.9.8",
        FixedVersion: "2.12.6.1, 2.13.2.1", Severity: "HIGH", Title: "jackson-databind: denial of service via a large depth of nested objects"}'
    done | jq -s '{Results: (if length > 0 then [{Target: "Java", Class: "lang-pkgs", Type: "jar", Vulnerabilities: .}] else [] end)}' > "\$out" ;;
  *) echo "trivy stub: \$*" >&2; exit 1 ;;
esac
EOF
cat > "$SB/codeql" <<EOF
#!/usr/bin/env bash
$(opt --output)
echo "codeql \$*" >> "$TMP/codeql.log"
case "\$1 \$2" in
  "database create") mkdir -p "\$3" ;;
  "database analyze") if [[ -f "$TMP/codeql.sarif" ]]; then cp "$TMP/codeql.sarif" "\$out"; exit; fi
    echo '{"version":"2.1.0","runs":[{"tool":{"driver":{"name":"CodeQL","rules":[{"id":"go/log-injection","properties":{"security-severity":"3.1"}}]}},"results":[{"ruleId":"go/log-injection","level":"error","message":{"text":"log entry from user input"},"locations":[{"physicalLocation":{"artifactLocation":{"uri":"main.go"},"region":{"startLine":5}}}]}]}]}' > "\$out" ;;
esac
EOF
cp "$TMP/bin/syft" "$SB/syft"
chmod +x "$SB/"*
# cargo-deny and cargo, stubs with the real scanners too (a build's clean
# environment has no rustup toolchain): cargo-deny starts with cargo
# metadata, which fails as cargo's does when a path dependency's manifest is
# not there, then reports what the real one does for the rustix 1.1.4 the
# manifest's Cargo.lock locks. CARGO_DENY_FAIL=1: it fails on any manifest.
RB="$TMP/scanbin-rust"; mkdir -p "$RB"
cat > "$RB/cargo-deny" <<EOF
#!/usr/bin/env bash
[[ "\$1" == --version ]] && { echo "cargo-deny 0.20.2"; exit; }
$(opt --manifest-path)
m="\$out"; d="\$(dirname "\$m")"; echo "\$m" >> "$TMP/cargo-deny.log"; cp "\$m" "$TMP/cargo-deny-\$(wc -l < "$TMP/cargo-deny.log").toml"
missing() { echo "{\"fields\":{\"level\":\"ERROR\",\"message\":\"\\\`cargo metadata\\\` exited with an error:     Updating crates.io index\\nerror: no matching package named \\\`\$1\\\` found\\nlocation searched: \$2\\nrequired by package \\\`demo v1.0.0 (\$d)\\\`\\n\"},\"type\":\"log\"}" >&2; exit 1; }
[[ -z "\${CARGO_DENY_FAIL:-}" ]] || missing grpcserver "\$d/target/generated-sources/model/chassis/grpcserver"
while read -r p; do
  [[ -f "\$d/\$p/Cargo.toml" ]] || missing "\$(basename "\$p")" "\$d/\$p"
done < <(sed -nE 's/.*\{.*path = "([^"]+)".*/\1/p' "\$m")
if grep -A1 '^name = "rustix"' "\$d/Cargo.lock" | grep -q '^version = "1.1.4"'; then
  echo '{"fields":{"advisory":{"aliases":["GHSA-jh2m-fhpj-3vr7"],"cvss":null,"id":"RUSTSEC-2026-0486","title":"xattr functions mark unwritten bytes as initialized when given a zero-length buffer"},"code":"unsound","graphs":[{"Krate":{"name":"rustix","version":"1.1.4"}}],"message":"xattr functions mark unwritten bytes as initialized when given a zero-length buffer","notes":["ID: RUSTSEC-2026-0486","Solution: Upgrade to >=1.1.6 (try \`cargo update -p rustix\`)"],"severity":"error"},"type":"diagnostic"}' >&2
fi
# The license check of a crate without one (the lock-only manifest's own).
crate="\$(sed -n 's/^name = "\\(.*\\)"\$/\\1/p' "\$m" | head -1)"
grep -q '^license' "\$m" || echo "{\"fields\":{\"code\":\"unlicensed\",\"graphs\":[{\"Krate\":{\"name\":\"\$crate\",\"version\":\"1.0.0\"}}],\"message\":\"unlicensed\",\"severity\":\"error\"},\"type\":\"diagnostic\"}" >&2
echo '{"fields":{"advisories":{"errors":1,"helps":0,"notes":0,"warnings":0}},"type":"summary"}' >&2
exit 1
EOF
cat > "$RB/cargo" <<'EOF'
#!/usr/bin/env bash
[[ "$1 $2" == "clippy --version" ]] && { echo "clippy 0.1.99"; exit; }
[[ "$1" == clippy ]] && exit 0
echo "cargo stub: $*" >&2; exit 1
EOF
chmod +x "$RB/"*

NAME=""
fail() { echo "FAIL $NAME: $*" >&2; for f in "$TMP/err" "$TMP/api.log" "$TMP/docker.log" "$TMP/buildctl.log"; do [[ -f "$f" ]] && cat "$f" >&2; done; exit 1; }
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
  : > "$TMP/api.log"; : > "$TMP/docker.log"; : > "$TMP/buildctl.log"; : > "$TMP/gcloud.log"; : > "$TMP/syft.log"; : > "$SRV/log"
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
# Its own timeout, a report job's longest (looper#140): not the project's default.
sed -n '/^gates:$/,/^security-demo:$/p' "$y" > "$TMP/gates.yml"
grep -qxF '  timeout: 11h' "$TMP/gates.yml" || fail "the gates job sets no 11h timeout: $(head -8 "$TMP/gates.yml")"
# A job whose runner is lost (a spot VM preempted) runs again (looper#148), and
# one whose image could not be pulled or whose runner GitLab's API failed
# (looper#173): the parent's default retry does not reach its child pipeline's
# jobs. Not on its own timeout: the gates' 11h is their own.
grep -A3 -xF 'default:' "$y" | paste -sd'|' - | grep -qxF 'default:|  retry:|    max: 2|    when: [runner_system_failure, scheduler_failure, unknown_failure, runner_external_dependency_failure, api_failure]' ||
  fail "the child pipeline's jobs are not retried when their runner is lost: $(head -12 "$y")"
# The build pipeline's own jobs (ci/build.gitlab-ci.yml), pods on the spot pool (looper#84): retried the GitLab
# way on a preemption, runner_system_failure and stuck_or_timeout_failure, twice, on the build runner's tags;
# and on an image not pulled, runner_external_dependency_failure (tacplus#340's land, looper#173), and api_failure.
grep -A5 -xF 'default:' "$ROOT/ci/build.gitlab-ci.yml" | paste -sd'|' - | grep -qF '|  tags: [arm64, build]|  retry:|    max: 2|    when: [runner_system_failure, stuck_or_timeout_failure, scheduler_failure, unknown_failure, runner_external_dependency_failure, api_failure]' ||
  fail "ci/build.gitlab-ci.yml's default is not the build runner with a spot retry: $(grep -A5 -xF 'default:' "$ROOT/ci/build.gitlab-ci.yml")"
# A failed gates job's verdict, the gates' own or none (its runner lost), is the commit's status, linking this pipeline.
sed -n '/^gates-failed:$/,/^[^ ]/p' "$y" > "$TMP/gates-failed.yml"
for l in '  needs: [{job: gates, artifacts: true}]' '  when: on_failure' '    BUILD_STATUS_URL: "https://gitlab.com/tacplus-dev/build/-/pipelines/1"' \
         '    - looper-build status failure'; do
  grep -qxF -- "$l" "$TMP/gates-failed.yml" || fail "the gates-failed job lacks '$l': $(cat "$TMP/gates-failed.yml")"
done
grep -q '^    BUILD_NO_VERDICT: ".*runner_system_failure' "$TMP/gates-failed.yml" || fail "no text for a gates job with no verdict: $(cat "$TMP/gates-failed.yml")"
# A failed security job's verdict, the gates green, is the commit's status too (looper#144); never a nightly's.
sed -n '/^security-failed:$/,/^[^ ]/p' "$y" > "$TMP/security-failed.yml"
for l in '  image: "ghcr.io/tacplus-dev/looper:main"' '  needs: [{job: gates, artifacts: true}, {job: "security-demo", artifacts: true}]' \
         '  when: on_failure' '    BUILD_STATUS_URL: "https://gitlab.com/tacplus-dev/build/-/pipelines/1"' '    BUILD_STATUS_OF: security' \
         '    - looper-build status failure'; do
  grep -qxF -- "$l" "$TMP/security-failed.yml" || fail "the security-failed job lacks '$l': $(cat "$TMP/security-failed.yml")"
done
grep -q '^    BUILD_NO_VERDICT: "no security verdict: .*runner_system_failure' "$TMP/security-failed.yml" ||
  fail "no text for a security job with no verdict: $(cat "$TMP/security-failed.yml")"
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
  for cmd in plan gates verify "status success"; do
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

NAME="gates: a red gate's verdict ends with the log's last lines, which a report can read (looper#144)"
verdict_is "fail: just gates exited 3: a gate fails; error: "
[[ "$(wc -l < "$OUT/build-verdict")" == 1 ]] || fail "not one line: $(cat "$OUT/build-verdict")"
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

# A build nobody waits for any more (looper#130): past the requester's wait,
# counted from the pipeline's creation, the gates job runs no gates.
ago() { date -u -d "@$(( $(date +%s) - $1 ))" +%Y-%m-%dT%H:%M:%SZ; } # seconds
NAME="gates: a pipeline older than its requester's wait exits at once, abandoned"
if build BUILD_SHA="${SHA[pass]}" BUILD_WAIT=10800 CI_PIPELINE_CREATED_AT="$(ago 10900)" -- gates 2>"$TMP/err"; then fail "built"; fi
verdict_is "fail: abandoned: no verdict wanted after 3h"
[[ ! -e "$OUT/gates.log" && ! -e "$OUT/src" ]] || fail "the gates ran: $(cat "$OUT/gates.log" 2>/dev/null)"
[[ ! -s "$TMP/api.log" && ! -s "$SRV/log" ]] || fail "it asked GitHub: $(cat "$TMP/api.log" "$SRV/log")"
if build BUILD_SHA="${SHA[pass]}" BUILD_WAIT=600 CI_PIPELINE_CREATED_AT="$(ago 700)" -- gates 2>"$TMP/err"; then fail "built"; fi
verdict_is "fail: abandoned: no verdict wanted after 10m"
pass

NAME="gates: a fresh pipeline builds; one with no wait, or no creation time, is never abandoned"
build BUILD_SHA="${SHA[pass]}" BUILD_WAIT=10800 CI_PIPELINE_CREATED_AT="$(ago 60)" -- gates 2>"$TMP/err" || fail "gates failed: $(cat "$TMP/err")"
verdict_is pass; grep -q "gates ok" "$OUT/gates.log" || fail "the gates did not run"
build BUILD_SHA="${SHA[pass]}" CI_PIPELINE_CREATED_AT="$(ago 999999)" -- gates 2>"$TMP/err" || fail "gates failed: $(cat "$TMP/err")"
verdict_is pass
build BUILD_SHA="${SHA[pass]}" BUILD_WAIT=10800 -- gates 2>"$TMP/err" || fail "gates failed: $(cat "$TMP/err")"
verdict_is pass
if build BUILD_SHA="${SHA[pass]}" BUILD_WAIT=3h -- gates 2>"$TMP/err"; then fail "built"; fi
verdict_is "fail: BUILD_WAIT '3h' is not a number of seconds"
pass

NAME="plan: the gates job has a build's wait; a nightly's and a release's never"
build BUILD_SHA="${SHA[pass]}" BUILD_WAIT=10800 -- plan 2>"$TMP/err" || fail "plan failed"
grep -qxF '    BUILD_WAIT: "10800"' <(sed -n '/^gates:$/,/^security-demo:$/p' "$OUT/build-gates.yml") || fail "no wait: $(head -16 "$OUT/build-gates.yml")"
build BUILD_SHA="${SHA[release]}" BUILD_TAG=v1.2.3 CI_COMMIT_TAG=demo/v1.2.3 BUILD_WAIT=10800 -- plan 2>"$TMP/err" || fail "release plan failed"
grep -qxF '    BUILD_WAIT: ""' "$OUT/build-gates.yml" || fail "a release has a wait: $(grep BUILD_WAIT "$OUT/build-gates.yml")"
build BUILD_SHA= BUILD_NIGHTLY=true BUILD_WAIT=10800 -- plan 2>"$TMP/err" || fail "nightly plan failed"
grep -qxF '    BUILD_WAIT: ""' "$OUT/build-gates.yml" || fail "a nightly has a wait: $(grep BUILD_WAIT "$OUT/build-gates.yml")"
pass

# The pinned image's own tacplus (looper#137): a tacplus project's gates run
# with TACPLUS_BIN=tacplus, once the job's image is the one tacplus.lock pins.
PINNED="us-docker.pkg.dev/jody1-328023/tacplus/build:2.6.1@$DIGEST_A"
mkdir -p "$TMP/image-bin"
printf '#!/bin/sh\necho "image tacplus $*"\n' > "$TMP/image-bin/tacplus"; chmod +x "$TMP/image-bin/tacplus"
NAME="gates: a tacplus project's gates run the pinned image's own tacplus, not a wrapper that needs Docker"
build BUILD_SHA="${SHA[tacplus]}" CI_JOB_IMAGE="$PINNED" PATH="$TMP/image-bin:$TMP/bin:$PATH" -- gates 2>"$TMP/err" ||
  fail "gates failed: $(cat "$OUT/build-verdict" "$OUT/gates.log" 2>/dev/null)"
verdict_is pass
grep -qxF "tacplus=tacplus" "$OUT/gates.log" && grep -qxF "image tacplus build --tag latest" "$OUT/gates.log" ||
  fail "not the image's tacplus: $(cat "$OUT/gates.log")"
grep -qxF "generated tacplus=tacplus" "$OUT/gates.log" || fail "just generated ran another tacplus: $(cat "$OUT/gates.log")"
pass

NAME="gates: a job in another image than tacplus.lock pins fails, and runs no gate"
if build BUILD_SHA="${SHA[tacplus]}" CI_JOB_IMAGE="us-docker.pkg.dev/jody1-328023/tacplus/build:2.6.2@$DIGEST_A" \
     PATH="$TMP/image-bin:$TMP/bin:$PATH" -- gates 2>"$TMP/err"; then fail "passed"; fi
verdict_is "fail: the job runs in us-docker.pkg.dev/jody1-328023/tacplus/build:2.6.2@$DIGEST_A, not the build image tacplus.lock pins ($PINNED)"
[[ ! -s "$OUT/gates.log" ]] || fail "the gates ran: $(cat "$OUT/gates.log")"
pass

NAME="gates: a pinned image with no tacplus fails, and runs no gate"
# This machine's PATH, with every tool but a tacplus (the looper image has one).
nt="$TMP/no-tacplus"; mkdir -p "$nt"; ntpath="$TMP/bin"
IFS=: read -ra dirs <<< "$PATH"
for d in "${dirs[@]}"; do
  if [[ -x "$d/tacplus" ]]; then
    for f in "$d"/*; do [[ "${f##*/}" == tacplus || -e "$nt/${f##*/}" ]] || ln -s "$f" "$nt/${f##*/}"; done
  else ntpath+=":$d"; fi
done
if build BUILD_SHA="${SHA[tacplus]}" CI_JOB_IMAGE="$PINNED" PATH="$ntpath:$nt" -- gates 2>"$TMP/err"; then fail "passed"; fi
verdict_is "fail: the build image tacplus.lock pins ($PINNED) has no tacplus"
[[ ! -s "$OUT/gates.log" ]] || fail "the gates ran: $(cat "$OUT/gates.log")"
pass

NAME="gates: a repository that is no tacplus project (build.lock) gets no TACPLUS_BIN"
build BUILD_SHA="${SHA[mapped]}" CI_JOB_IMAGE="ghcr.io/tacplus-dev/looper:main@$DIGEST_A" -- gates 2>"$TMP/err" || fail "gates failed: $(cat "$TMP/err")"
verdict_is pass
! grep -q "the image's own tacplus" "$TMP/err" || fail "$(cat "$TMP/err")"
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
# The status names the build's key (looper#134), the gate set and its base: a
# request for the same key finds it, pending or green, and builds nothing again.
B="$(printf 'b%.0s' {1..40})"
for st in pending:building success:pass; do
  : > "$TMP/api.log"
  build BUILD_SHA="${SHA[mapped]}" BUILD_GATES=docs BUILD_BASE="$B" -- status "${st%%:*}" 2>"$TMP/err" || fail "status failed"
  [[ "$(grep '^status ' "$TMP/api.log" | sed 's/^status [^{]*//' | jq -r '.state + "|" + .description')" == "${st%%:*}|${st#*:}: gates docs on base $B" ]] ||
    fail "the ${st%%:*} status does not name its key: $(cat "$TMP/api.log")"
done
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

NAME="status: a failure with no verdict file (the gates' child pipeline failed) is still reported"
OUT="$TMP/out-status-none"; mkdir -p "$OUT"; : > "$TMP/api.log"
env -i PATH="$TMP/bin:$PATH" HOME="$TMP/home" TACPLUS_READER_APP_ID="$APP_ID" TACPLUS_READER_INSTALLATION_ID="$INSTALLATION" \
  TACPLUS_READER_APP_KEY="$TMP/app.pem" BUILD_REPO=demo BUILD_SHA="${SHA[pass]}" BUILD_OUT="$OUT" \
  "$ROOT/looper-build" status failure 2>"$TMP/err" || fail "status failed: $(cat "$TMP/err")"
[[ "$(grep '^status ' "$TMP/api.log" | sed 's/^status [^{]*//' | jq -r '.state + "|" + .description')" == \
   "failure|the build failed" ]] || fail "$(cat "$TMP/api.log")"
pass

NAME="status: the gates-failed job reports the gates' own verdict, or that their runner was lost, on the build's pipeline"
OUT="$TMP/out-status-gates"; mkdir -p "$OUT"; : > "$TMP/api.log"
GF=(env -i PATH="$TMP/bin:$PATH" HOME="$TMP/home" TACPLUS_READER_APP_ID="$APP_ID" TACPLUS_READER_INSTALLATION_ID="$INSTALLATION"
    TACPLUS_READER_APP_KEY="$TMP/app.pem" BUILD_REPO=demo BUILD_SHA="${SHA[pass]}" BUILD_OUT="$OUT"
    CI_PIPELINE_URL=https://gitlab.com/tacplus-dev/build/-/pipelines/2 BUILD_STATUS_URL=https://gitlab.com/tacplus-dev/build/-/pipelines/1
    BUILD_NO_VERDICT="no gates verdict: the gates job's runner was lost")
echo "fail: the gates docs (gates.yaml) exited 1 (gates.log)" > "$OUT/build-verdict"   # the gates job's artifact
"${GF[@]}" "$ROOT/looper-build" status failure 2>"$TMP/err" || fail "status failed: $(cat "$TMP/err")"
[[ "$(grep '^status ' "$TMP/api.log" | sed 's/^status [^{]*//' | jq -r '.state + "|" + .description + "|" + .target_url')" == \
   "failure|the gates docs (gates.yaml) exited 1 (gates.log)|https://gitlab.com/tacplus-dev/build/-/pipelines/1" ]] || fail "$(cat "$TMP/api.log")"
rm "$OUT/build-verdict"; : > "$TMP/api.log"   # a runner lost, its retries too: no artifact
"${GF[@]}" "$ROOT/looper-build" status failure 2>"$TMP/err" || fail "status failed: $(cat "$TMP/err")"
[[ "$(grep '^status ' "$TMP/api.log" | sed 's/^status [^{]*//' | jq -r '.state + "|" + .description')" == \
   "failure|no gates verdict: the gates job's runner was lost" ]] || fail "$(cat "$TMP/api.log")"
pass

NAME="status: the build's own failure does not overwrite the reason its gates-failed job set"
OUT="$TMP/out-status-set"; mkdir -p "$OUT"; : > "$TMP/api.log"
jq -n '[{state: "failure", context: "tacplus-dev/build", description: "the gates exited 1", target_url: "https://gitlab.com/tacplus-dev/build/-/pipelines/1"}]' > "$TMP/statuses"
env -i PATH="$TMP/bin:$PATH" HOME="$TMP/home" TACPLUS_READER_APP_ID="$APP_ID" TACPLUS_READER_INSTALLATION_ID="$INSTALLATION" \
  TACPLUS_READER_APP_KEY="$TMP/app.pem" BUILD_REPO=demo BUILD_SHA="${SHA[pass]}" BUILD_OUT="$OUT" \
  CI_PIPELINE_URL=https://gitlab.com/tacplus-dev/build/-/pipelines/1 \
  "$ROOT/looper-build" status failure 2>"$TMP/err" || fail "status failed: $(cat "$TMP/err")"
grep -q '^statuses ' "$TMP/api.log" || fail "the statuses were not read: $(cat "$TMP/api.log")"
! grep -q '^status ' "$TMP/api.log" || fail "overwrote the gates' reason: $(cat "$TMP/api.log")"
grep -q "already" "$TMP/err" || fail "$(cat "$TMP/err")"
rm "$TMP/statuses"
pass

NAME="plan: a nightly's security findings set no commit status (looper#144)"
build BUILD_SHA="${SHA[pass]}" BUILD_NIGHTLY=true -- plan 2>"$TMP/err" || fail "nightly plan failed: $(cat "$TMP/err")"
grep -q '^security-demo:' "$OUT/build-gates.yml" || fail "no security job: $(cat "$OUT/build-gates.yml")"
! grep -q '^security-failed:' "$OUT/build-gates.yml" || fail "a nightly's security checks set a commit status"
pass

NAME="status: the security-failed job reports the security checks' verdict when the gates passed, and only then (looper#144)"
OUT="$TMP/out-status-security"; mkdir -p "$OUT/security"; : > "$TMP/api.log"
SF=(env -i PATH="$TMP/bin:$PATH" HOME="$TMP/home" TACPLUS_READER_APP_ID="$APP_ID" TACPLUS_READER_INSTALLATION_ID="$INSTALLATION"
    TACPLUS_READER_APP_KEY="$TMP/app.pem" BUILD_REPO=demo BUILD_SHA="${SHA[pass]}" BUILD_OUT="$OUT" BUILD_STATUS_OF=security
    CI_PIPELINE_URL=https://gitlab.com/tacplus-dev/build/-/pipelines/2 BUILD_STATUS_URL=https://gitlab.com/tacplus-dev/build/-/pipelines/1
    BUILD_NO_VERDICT="no security verdict: the security job's runner was lost")
echo pass > "$OUT/build-verdict"
echo "fail: govulncheck: loading packages: file requires newer Go version go1.27" > "$OUT/security/verdict"
"${SF[@]}" "$ROOT/looper-build" status failure 2>"$TMP/err" || fail "status failed: $(cat "$TMP/err")"
[[ "$(grep '^status ' "$TMP/api.log" | sed 's/^status [^{]*//' | jq -r '.state + "|" + .description + "|" + .target_url')" == \
   "failure|security: govulncheck: loading packages: file requires newer Go version go1.27|https://gitlab.com/tacplus-dev/build/-/pipelines/1" ]] ||
  fail "$(cat "$TMP/api.log")"
rm "$OUT/security/verdict"; : > "$TMP/api.log"   # its runner lost, its retries too: no artifact
"${SF[@]}" "$ROOT/looper-build" status failure 2>"$TMP/err" || fail "status failed: $(cat "$TMP/err")"
[[ "$(grep '^status ' "$TMP/api.log" | sed 's/^status [^{]*//' | jq -r '.state + "|" + .description')" == \
   "failure|no security verdict: the security job's runner was lost" ]] || fail "$(cat "$TMP/api.log")"
# Red gates: their reason is gates-failed's, which this job leaves be.
echo "fail: just gates exited 127: sh: 1: trivy: not found" > "$OUT/build-verdict"
echo "fail: no gates artifacts" > "$OUT/security/verdict"; : > "$TMP/api.log"
"${SF[@]}" "$ROOT/looper-build" status failure 2>"$TMP/err" || fail "status failed: $(cat "$TMP/err")"
! grep -q '^status ' "$TMP/api.log" || fail "overwrote the gates' reason: $(cat "$TMP/api.log")"
rm -f "$OUT/build-verdict"; : > "$TMP/api.log"   # the gates' runner lost: gates-failed's too
"${SF[@]}" "$ROOT/looper-build" status failure 2>"$TMP/err" || fail "status failed: $(cat "$TMP/err")"
! grep -q '^status ' "$TMP/api.log" || fail "overwrote the gates' reason: $(cat "$TMP/api.log")"
pass

# --- publish --------------------------------------------------------------------
echo "sha256:$(printf 'b%.0s' {1..64})" > "$TMP/digest"
REL=(BUILD_SHA="${SHA[release]}" BUILD_TAG=v1.2.3 CI_COMMIT_TAG=demo/v1.2.3 CI_COMMIT_REF_NAME=demo/v1.2.3
     GCP_ID_TOKEN=eyJ.stub.id GCP_WIF_PROVIDER=projects/1/locations/global/workloadIdentityPools/p/providers/g
     CI_API_V4_URL=https://gitlab.example/api/v4 CI_PROJECT_ID=42)
# A job in a build image with rootless BuildKit (tacplus-dev/tacplus#315).
BK=(PATH="$TMP/bk:$TMP/bin:$PATH")
BUILDER="ghcr.io/tacplus-dev/tacplus/build:latest@sha256:$(printf 'd%.0s' {1..64})"

NAME="plan: a release publishes in the builder image, rootless BuildKit on the build runner, after every check; its SBOM in the looper image"
build BUILD_SHA="${SHA[release]}" BUILD_TAG=v1.2.3 CI_COMMIT_TAG=demo/v1.2.3 BUILD_BUILDER_IMAGE="$BUILDER" -- plan 2>"$TMP/err" ||
  fail "plan failed: $(cat "$OUT/build-verdict" "$TMP/err" 2>/dev/null)"
y="$OUT/build-gates.yml"
sed -n '/^publish-demo:$/,/^[^ ]/p' "$y" | sed '$d' > "$TMP/publish.yml"
for l in "  image: \"$BUILDER\"" '  tags: [arm64, build]' \
         '  needs: [{job: gates, artifacts: false}, {job: "security-demo", artifacts: false}, {job: "verify-demo", artifacts: false}]' \
         '  environment:' '    name: registry' '  id_tokens:' '    GCP_ID_TOKEN:' '      aud: https://iam.googleapis.com/$GCP_WIF_PROVIDER' \
         '    BUILD_TAG: "v1.2.3"' "    BUILD_SHA: \"${SHA[release]}\"" '      bash "$CI_PROJECT_DIR/looper-build" publish' \
         '    paths: [image, image.tar]'; do
  grep -qxF -- "$l" "$TMP/publish.yml" || fail "the publish job lacks '$l': $(grep -v '^      ' "$TMP/publish.yml")"
done
sed -n '/^sbom-demo:$/,/^[^ ]/p' "$y" > "$TMP/sbom.yml"
for l in '  image: "ghcr.io/tacplus-dev/looper:main"' '  tags: [arm64, build]' '  needs: [{job: "publish-demo", artifacts: true}]' \
         '    - looper-build sbom' '    paths: [image, sbom.cdx.json, sbom.spdx.json]'; do
  grep -qxF -- "$l" "$TMP/sbom.yml" || fail "the sbom job lacks '$l': $(cat "$TMP/sbom.yml")"
done
grep -q "publish in $BUILDER (rootless BuildKit)" "$TMP/err" || fail "the plan does not say where publish builds: $(cat "$TMP/err")"
# The parent pipeline publishes no more: the plan's child does (ci/build.gitlab-ci.yml).
! grep -q '^publish:' "$ROOT/ci/build.gitlab-ci.yml" || fail "ci/build.gitlab-ci.yml still has its own publish job"
build BUILD_SHA="${SHA[pass]}" BUILD_BUILDER_IMAGE="$BUILDER" -- plan 2>"$TMP/err" || fail "plan failed"
! grep -q '^publish-\|^sbom-' "$OUT/build-gates.yml" || fail "a build that is no release publishes"
pass

NAME="plan: with no builder image, publish still needs host Docker: the looper image on the Docker tags, said so"
build BUILD_SHA="${SHA[release]}" BUILD_TAG=v1.2.3 CI_COMMIT_TAG=demo/v1.2.3 BUILD_DOCKER_TAGS="arm64, build, docker" -- plan 2>"$TMP/err" ||
  fail "plan failed: $(cat "$OUT/build-verdict" "$TMP/err" 2>/dev/null)"
sed -n '/^publish-demo:$/,/^[^ ]/p' "$OUT/build-gates.yml" | sed '$d' > "$TMP/publish.yml"
grep -qxF '  image: "ghcr.io/tacplus-dev/looper:main"' "$TMP/publish.yml" || fail "not the looper image: $(grep -v '^      ' "$TMP/publish.yml")"
grep -qxF '  tags: [arm64, build, docker]' "$TMP/publish.yml" || fail "not on the Docker tags: $(grep -v '^      ' "$TMP/publish.yml")"
grep -q "publish needs host Docker (no BUILD_BUILDER_IMAGE.*): on arm64, build, docker" "$TMP/err" || fail "the plan does not say so: $(cat "$TMP/err")"
pass

# The values the hub's copy runs with (looper#172): the in-cluster build runner (tags arm64, build, no socket)
# never takes a job that needs host Docker, and the builder image is pinned by digest, or none yet.
NAME="ci/build.gitlab-ci.yml: publish's Docker tags are the VM build pool's alone; its builder image by digest"
civar() { sed -n "s/^  $1: \"\(.*\)\"\$/\1/p" "$ROOT/ci/build.gitlab-ci.yml"; }
[[ "$(civar BUILD_DOCKER_TAGS)" == "arm64, build-docker" ]] || fail "BUILD_DOCKER_TAGS is '$(civar BUILD_DOCKER_TAGS)', not 'arm64, build-docker'"
b="$(civar BUILD_BUILDER_IMAGE)"
[[ -z "$b" || "$b" =~ ^ghcr\.io/tacplus-dev/tacplus/build(:[A-Za-z0-9._-]+)?@sha256:[0-9a-f]{64}$ ]] ||
  fail "BUILD_BUILDER_IMAGE '$b' is no tacplus build image by digest"
build BUILD_SHA="${SHA[release]}" BUILD_TAG=v1.2.3 CI_COMMIT_TAG=demo/v1.2.3 BUILD_BUILDER_IMAGE="$b" BUILD_DOCKER_TAGS="$(civar BUILD_DOCKER_TAGS)" -- plan 2>"$TMP/err" ||
  fail "plan failed: $(cat "$OUT/build-verdict" "$TMP/err" 2>/dev/null)"
# Every job but a Docker publish is on the build runner's tags; a Docker publish names build-docker, which it lacks.
grep '^  tags: ' "$OUT/build-gates.yml" | sort | uniq -c > "$TMP/tags"
if [[ -z "$b" ]]; then
  [[ "$(grep -c 'build-docker' "$OUT/build-gates.yml")" == 1 ]] || fail "not publish alone on build-docker: $(cat "$TMP/tags")"
  sed -n '/^publish-demo:$/,/^[^ ]/p' "$OUT/build-gates.yml" > "$TMP/publish.yml"
  grep -qxF '  tags: [arm64, build-docker]' "$TMP/publish.yml" || fail "publish not on build-docker: $(cat "$TMP/tags")"
else
  ! grep -q 'build-docker' "$OUT/build-gates.yml" || fail "a job on build-docker with a builder image: $(cat "$TMP/tags")"
fi
! grep '^  tags: ' "$OUT/build-gates.yml" | grep -vxF -e '  tags: [arm64, build]' -e '  tags: [arm64, build-docker]' ||
  fail "a job on other tags: $(cat "$TMP/tags")"
pass

NAME="publish: rootless BuildKit, reproducible, pushed with a federated token, its digest and archive kept; no Docker"
build "${REL[@]}" "${BK[@]}" -- publish 2>"$TMP/err" || fail "publish failed"
img="us-docker.pkg.dev/jody1-328023/tacplus/demo:1.2.3@$(cat "$TMP/digest")"
[[ "$(cat "$OUT/image")" == "$img" ]] || fail "image $(cat "$OUT/image")"
[[ -s "$OUT/image.tar" ]] || fail "no image.tar for the SBOM job"
[[ ! -s "$TMP/docker.log" ]] || fail "used Docker: $(cat "$TMP/docker.log")"
epoch="$(git -C "$work" log -1 --format=%ct "${SHA[release]}")"
[[ "$(grep -c "^buildctl BUILDKIT_HOST=unix:///run/buildkit/buildkitd.sock build " "$TMP/buildctl.log")" == 2 ]] ||
  fail "not built twice on the rootless daemon"
for o in "--frontend dockerfile.v0" "--opt platform=linux/amd64,linux/arm64" "--opt image-resolve-mode=pull" \
         "--opt build-arg:SOURCE_DATE_EPOCH=$epoch" "--opt build-arg:VERSION=v1.2.3" "--opt build-arg:REVISION=${SHA[release]}" \
         "--opt label:org.opencontainers.image.revision=${SHA[release]}" \
         "--opt label:org.opencontainers.image.source=https://github.com/tacplus-dev/demo" \
         "--output type=oci,dest=$OUT/image.tar,rewrite-timestamp=true" \
         "--output type=image,name=us-docker.pkg.dev/jody1-328023/tacplus/demo:1.2.3,push=true,oci-mediatypes=true,rewrite-timestamp=true"; do
  grep -q -- " $o" "$TMP/buildctl.log" || fail "buildctl without $o: $(cat "$TMP/buildctl.log")"
done
grep -qxF "auth oauth2accesstoken:ya29.stub" "$TMP/buildctl.log" || fail "not pushed with the federated token"
grep -qxF "manifest Bearer ya29.stub" "$TMP/api.log" || fail "the registry was not asked for the release with the token: $(cat "$TMP/api.log")"
grep -qxF "id-token eyJ.stub.id" "$TMP/gcloud.log" || fail "the id token was not exchanged"
grep -qxF "tacplus-image-build stop" "$TMP/buildctl.log" || fail "the daemon was left running"
! grep -q "^syft" "$TMP/syft.log" || fail "the SBOM is the sbom job's, not publish's"
pass

NAME="publish: rootless BuildKit that cannot start fails, and does not fall back to Docker"
touch "$TMP/no-userns"
if build "${REL[@]}" "${BK[@]}" -- publish 2>"$TMP/err"; then fail "published"; fi
rm "$TMP/no-userns"
verdict_is "fail: rootless BuildKit did not start"
[[ ! -s "$TMP/docker.log" ]] || fail "fell back to Docker: $(cat "$TMP/docker.log")"
pass

NAME="sbom: the release's SBOM, of the image publish built, CycloneDX and SPDX, kept and published"
build "${REL[@]}" "${BK[@]}" -- publish 2>"$TMP/err" || fail "publish failed"
PUB="$OUT"   # the publish job's artifacts, image and image.tar, as the sbom job gets them
# The sbom job holds no GCP identity: only publish has one.
SBOM_ENV=(BUILD_SHA="${SHA[release]}" BUILD_TAG=v1.2.3 CI_API_V4_URL=https://gitlab.example/api/v4 CI_PROJECT_ID=42 BUILD_OUT="$PUB")
if build "${SBOM_ENV[@]}" GCP_ID_TOKEN=eyJ.stub.id -- sbom 2>"$TMP/err"; then fail "an SBOM job with the GCP identity"; fi
build "${SBOM_ENV[@]}" -- sbom 2>"$TMP/err" || fail "sbom failed: $(cat "$TMP/err")"
jq -e '.stub == "cyclonedx-json"' "$PUB/sbom.cdx.json" >/dev/null && jq -e '.stub == "spdx-json"' "$PUB/sbom.spdx.json" >/dev/null ||
  fail "no SBOM: $(ls "$PUB")"
grep -q "^syft scan -q oci-archive:$PUB/image.tar " "$TMP/syft.log" || fail "not of the image: $(cat "$TMP/syft.log")"
for f in sbom.cdx.json sbom.spdx.json; do
  grep -qxF "package-put JOB-TOKEN: glcbt-stub sbom-demo/1.2.3/$f $(sha256sum < "$PUB/$f" | cut -c1-12)" "$TMP/api.log" ||
    fail "$f not published: $(cat "$TMP/api.log")"
done
rm "$PUB/image.tar"
if build "${SBOM_ENV[@]}" -- sbom 2>"$TMP/err"; then fail "an SBOM of no image"; fi
OUT="$PUB" verdict_is "fail: no image.tar"
pass

NAME="publish: with no rootless BuildKit, host Docker (buildx), said so; the same token, by its config"
build "${REL[@]}" -- publish 2>"$TMP/err" || fail "publish failed"
[[ "$(cat "$OUT/image")" == "$img" ]] || fail "image $(cat "$OUT/image")"
grep -q "no tacplus-image-build in this image: host Docker" "$TMP/err" || fail "does not say it uses Docker: $(cat "$TMP/err")"
[[ "$(grep -c "^SOURCE_DATE_EPOCH=$epoch\$" "$TMP/docker.log")" == 2 ]] || fail "not built twice at the commit's time"
grep -q -- "--provenance=false --sbom=false" "$TMP/docker.log" || fail "attestations"
grep -q -- "--output type=oci,dest=$OUT/image.tar,rewrite-timestamp=true" "$TMP/docker.log" || fail "no reproducible oci build"
grep -q -- "--output type=image,name=us-docker.pkg.dev/jody1-328023/tacplus/demo:1.2.3,push=true,oci-mediatypes=true,rewrite-timestamp=true" \
  "$TMP/docker.log" || fail "no reproducible push"
grep -q -- "--driver-opt image=moby/buildkit:v[0-9.]*@sha256:" "$TMP/docker.log" || fail "the builder is not pinned"
grep -qxF "auth oauth2accesstoken:ya29.stub" "$TMP/docker.log" || fail "not pushed with the federated token"
! grep -q "^docker login" "$TMP/docker.log" || fail "docker login: the token is the config's"
pass

NAME="publish: the emulators are installed once, when the Docker builder lacks a platform"
grep -q "^docker run --rm --privileged tonistiigi/binfmt:[^ ]*@sha256:[0-9a-f]* --install all$" "$TMP/docker.log" ||
  fail "no emulators installed"
[[ "$(grep -c "^docker buildx create" "$TMP/docker.log")" == 2 ]] || fail "the builder was not made again"
build "${REL[@]}" -- publish 2>"$TMP/err" || fail "publish failed"
! grep -q "binfmt" "$TMP/docker.log" || fail "installed the emulators again"
pass

NAME="publish: a build that does not reproduce is not published"
echo "sha256:$(printf 'c%.0s' {1..64})" > "$TMP/push-digest"
if build "${REL[@]}" "${BK[@]}" -- publish 2>"$TMP/err"; then fail "published"; fi
rm "$TMP/push-digest"
verdict_is "fail: not reproducible"
pass

NAME="publish: a release already published with this digest is not pushed again; another digest fails"
printf '{"schemaVersion":2}' > "$TMP/existing"
echo "sha256:$(printf '{"schemaVersion":2}' | sha256sum | cut -d' ' -f1)" > "$TMP/digest"
build "${REL[@]}" "${BK[@]}" -- publish 2>"$TMP/err" || fail "publish failed"
! grep -q "push=true" "$TMP/buildctl.log" || fail "pushed again"
echo "sha256:$(printf 'b%.0s' {1..64})" > "$TMP/digest"
if build "${REL[@]}" "${BK[@]}" -- publish 2>"$TMP/err"; then fail "published over another digest"; fi
verdict_is "fail: us-docker.pkg.dev/jody1-328023/tacplus/demo:1.2.3 is already published as"
rm "$TMP/existing"
pass

NAME="publish: a registry that cannot say whether the release is there publishes nothing"
echo 500 > "$TMP/registry-code"
if build "${REL[@]}" "${BK[@]}" -- publish 2>"$TMP/err"; then fail "published"; fi
rm "$TMP/registry-code"
verdict_is "fail: the registry answered 500 for us-docker.pkg.dev/jody1-328023/tacplus/demo:1.2.3"
! grep -q "push=true" "$TMP/buildctl.log" || fail "pushed"
pass

NAME="publish: --dry-run builds and pushes nothing, with no GCP identity"
build BUILD_SHA="${SHA[release]}" BUILD_TAG=v1.2.3 CI_COMMIT_TAG=demo/v1.2.3 "${BK[@]}" -- publish --dry-run 2>"$TMP/err" || fail "dry run failed"
[[ "$(cat "$OUT/image")" == "us-docker.pkg.dev/jody1-328023/tacplus/demo:1.2.3@$(cat "$TMP/digest")" ]] || fail "$(cat "$OUT/image")"
! grep -q "push=true" "$TMP/buildctl.log" || fail "pushed"
[[ ! -s "$TMP/gcloud.log" ]] || fail "federated: $(cat "$TMP/gcloud.log")"
pass

NAME="publish: only on the build project's protected tag, for the repository's tag at that commit"
if build "${REL[@]}" "${BK[@]}" CI_COMMIT_TAG= CI_COMMIT_REF_NAME=main -- publish 2>"$TMP/err"; then fail "published from main"; fi
verdict_is "fail: a release build of demo v1.2.3 runs on the build project's protected tag demo/v1.2.3, not 'main'"
if build "${REL[@]}" "${BK[@]}" BUILD_SHA="${SHA[pass]}" -- publish 2>"$TMP/err"; then fail "published another commit"; fi
verdict_is "fail: demo's tag v1.2.3 is at '${SHA[release]}', not ${SHA[pass]}"
if build "${REL[@]}" "${BK[@]}" BUILD_TAG= -- publish 2>"$TMP/err"; then fail "published without a tag"; fi
verdict_is "fail: publish needs a release tag"
[[ ! -s "$TMP/docker.log" && ! -s "$TMP/buildctl.log" ]] || fail "built: $(cat "$TMP/docker.log" "$TMP/buildctl.log")"
pass

NAME="publish: no write credential either, but its GCP identity"
if build "${REL[@]}" "${BK[@]}" GH_TOKEN=ghp_x -- publish 2>"$TMP/err"; then fail "published with GH_TOKEN"; fi
verdict_is "fail: this job holds a write credential (GH_TOKEN)"
pass

# --- formal verification (looper#74) -------------------------------------------------
# The build project's API (its package registry, the last record) at gitlab.example.
VAPI=(CI_API_V4_URL=https://gitlab.example/api/v4 CI_PROJECT_ID=42)
RUN400=https://gitlab.com/tacplus-dev/build/-/pipelines/400
rec() { sed -n "s/^$1 //p" "$OUT/verify/record" | tail -n 1; } # key

NAME="plan: a verify run is the verify job alone, of main's head, with the last record's commit and result"
printf 'repo demo\nkind nightly\nchecked %s\nverified %s\nresult pass\nrun %s\n' "${SHA[verify1]}" "${SHA[verify1]}" "$RUN400" > "$TMP/verify-record"
build BUILD_SHA= BUILD_VERIFY=true "${VAPI[@]}" -- plan 2>"$TMP/err" || fail "verify plan failed: $(cat "$OUT/build-verdict" "$TMP/err" 2>/dev/null)"
y="$OUT/build-gates.yml"
sed -n '/^verify-demo:$/,/^verify-report:$/p' "$y" > "$TMP/v.yml"
grep -qxF "  image: \"us-docker.pkg.dev/jody1-328023/tacplus/build:2.6.1@$DIGEST_A\"" "$TMP/v.yml" || fail "not the pinned image: $(cat "$TMP/v.yml" | head -20)"
grep -qxF "  tags: [arm64, build]" "$TMP/v.yml" || fail "not on the build runner"
grep -qxF "    BUILD_SHA: \"$(git -C "$work" rev-parse main)\"" "$TMP/v.yml" || fail "not main's head"
grep -qxF "    BUILD_VERIFY_SINCE: \"${SHA[verify1]}\"" "$TMP/v.yml" || fail "not the last verified commit: $(grep BUILD_ "$TMP/v.yml")"
grep -qxF '    BUILD_VERIFY_RESULT: "pass"' "$TMP/v.yml" && grep -qxF "    BUILD_VERIFY_RUN: \"$RUN400\"" "$TMP/v.yml" || fail "not the last result and run"
grep -qF 'bash "$CI_PROJECT_DIR/looper-build" verify' "$TMP/v.yml" || fail "the job does not run looper-build verify"
grep -qxF '    paths: [verify/]' "$TMP/v.yml" || fail "the record is not the job's artifact"
sed -n '/^verify-report:$/,$p' "$y" | grep -qxF '    - looper-build verify-report' || fail "no report job"
sed -n '/^verify-report:$/,$p' "$y" | grep -qxF '  needs: [{job: "verify-demo", artifacts: true}]' || fail "the report does not read the verify job's record"
! grep -qE '^(gates|security-demo):$' "$y" || fail "a verify run runs the gates or the security checks: $(grep -E '^[a-z]' "$y")"
grep -qxF "package-get JOB-TOKEN: glcbt-stub verify-demo/latest/record" "$TMP/api.log" || fail "the record was not read with the job token: $(cat "$TMP/api.log")"
pass

NAME="plan: a missing or unreadable record leaves no last commit: the job runs"
rm -f "$TMP/verify-record"
build BUILD_SHA= BUILD_VERIFY=true "${VAPI[@]}" -- plan 2>"$TMP/err" || fail "plan failed"
grep -qxF '    BUILD_VERIFY_SINCE: ""' "$OUT/build-gates.yml" || fail "$(grep BUILD_VERIFY "$OUT/build-gates.yml")"
printf 'verified %s\nresult maybe\nrun %s\n' "${SHA[verify1]}" "$RUN400" > "$TMP/verify-record"
build BUILD_SHA= BUILD_VERIFY=true "${VAPI[@]}" -- plan 2>"$TMP/err" || fail "plan failed"
grep -qxF '    BUILD_VERIFY_SINCE: ""' "$OUT/build-gates.yml" || fail "an unreadable record: $(grep BUILD_VERIFY "$OUT/build-gates.yml")"
printf 'verified %s\nresult pass\nrun "; evil\n' "${SHA[verify1]}" > "$TMP/verify-record"
build BUILD_SHA= BUILD_VERIFY=true "${VAPI[@]}" -- plan 2>"$TMP/err" || fail "plan failed"
grep -qxF '    BUILD_VERIFY_SINCE: ""' "$OUT/build-gates.yml" || fail "a record whose run is no URL: $(grep BUILD_VERIFY "$OUT/build-gates.yml")"
rm -f "$TMP/verify-record"
pass

NAME="plan: a release runs the verification beside the gates, with no change check; a verify run is no release, nor a nightly scan"
printf 'verified %s\nresult pass\nrun %s\n' "${SHA[verify1]}" "$RUN400" > "$TMP/verify-record"
build BUILD_SHA="${SHA[release]}" BUILD_TAG=v1.2.3 CI_COMMIT_TAG=demo/v1.2.3 "${VAPI[@]}" -- plan 2>"$TMP/err" || fail "release plan failed"
y="$OUT/build-gates.yml"
grep -qx 'gates:' "$y" && grep -qx 'security-demo:' "$y" && grep -qx 'verify-demo:' "$y" && grep -qx 'verify-report:' "$y" ||
  fail "a release lacks a job: $(grep -E '^[a-z]' "$y")"
grep -qxF '    BUILD_VERIFY_SINCE: ""' "$y" || fail "a release asked for a change check: $(grep BUILD_VERIFY "$y")"
grep -qxF '    BUILD_TAG: "v1.2.3"' <(sed -n '/^verify-demo:$/,/^verify-report:$/p' "$y") || fail "the verify job is not the release's"
build BUILD_SHA="${SHA[pass]}" "${VAPI[@]}" -- plan 2>"$TMP/err" || fail "build plan failed"
! grep -q '^verify' "$OUT/build-gates.yml" || fail "a build runs the verification"
build BUILD_SHA= BUILD_NIGHTLY=true "${VAPI[@]}" -- plan 2>"$TMP/err" || fail "nightly plan failed"
! grep -q '^verify' "$OUT/build-gates.yml" || fail "the nightly security checks run the verification"
rm -f "$TMP/verify-record"
if build BUILD_SHA="${SHA[release]}" BUILD_VERIFY=true BUILD_TAG=v1.2.3 -- plan 2>"$TMP/err"; then fail "a verify run that is a release"; fi
verdict_is "fail: a verify run is not a release"
if build BUILD_SHA= BUILD_VERIFY=true BUILD_NIGHTLY=true -- plan 2>"$TMP/err"; then fail "a verify run that is a nightly scan"; fi
verdict_is "fail: a verify run is not the nightly security checks"
if build BUILD_SHA="${SHA[verify2]}" BUILD_VERIFY=true BUILD_VERIFY_SINCE=main -- verify 2>"$TMP/err"; then fail "verified"; fi
verdict_is "fail: BUILD_VERIFY_SINCE 'main' is not a full commit hash"
pass

NAME="verify: a nightly with nothing changed since the last verified commit skips, its record that one's"
build BUILD_SHA="${SHA[verify2]}" BUILD_VERIFY=true BUILD_VERIFY_SINCE="${SHA[verify1]}" BUILD_VERIFY_RESULT=pass BUILD_VERIFY_RUN="$RUN400" \
  -- verify 2>"$TMP/err" || fail "the skip failed: $(cat "$TMP/err")"
verdict_is pass
! grep -q "verify ran" "$TMP/err" || fail "just verify ran"
[[ "$(rec verified) $(rec result) $(rec run) $(rec checked)" == "${SHA[verify1]} pass $RUN400 ${SHA[verify2]}" ]] || fail "$(cat "$OUT/verify/record")"
grep -q "^skipped unchanged since ${SHA[verify1]}" "$OUT/verify/record" || fail "$(cat "$OUT/verify/record")"
build BUILD_SHA="${SHA[verify2]}" BUILD_VERIFY=true BUILD_VERIFY_SINCE="${SHA[verify1]}" BUILD_VERIFY_RESULT=fail BUILD_VERIFY_RUN="$RUN400" \
  -- verify 2>"$TMP/err" || fail "the skip failed"
[[ "$(rec result)" == fail ]] || fail "a skip did not keep the last result: $(cat "$OUT/verify/record")"
pass

NAME="verify: a nightly runs on a change, with no record, and when the change check cannot tell"
for since in "${SHA[verify2]}" "" "$(printf '9%.0s' {1..40})"; do
  build BUILD_SHA="${SHA[verify3]}" BUILD_VERIFY=true BUILD_VERIFY_SINCE="$since" BUILD_VERIFY_RESULT="${since:+pass}" BUILD_VERIFY_RUN="${since:+$RUN400}" \
    CI_PIPELINE_URL=https://gitlab.com/tacplus-dev/build/-/pipelines/401 -- verify 2>"$TMP/err" || fail "since '$since': $(cat "$TMP/err")"
  verdict_is pass
  grep -qxF "verify ran job-token=none key=none" "$OUT/verify/verify.log" || fail "since '$since': $(cat "$OUT/verify/verify.log" 2>/dev/null)"
  [[ "$(rec verified) $(rec result) $(rec run)" == "${SHA[verify3]} pass https://gitlab.com/tacplus-dev/build/-/pipelines/401" ]] || fail "$(cat "$OUT/verify/record")"
  ! grep -q '^skipped' "$OUT/verify/record" || fail "$(cat "$OUT/verify/record")"
done
pass

NAME="verify: a release tag always runs, with no change check"
build BUILD_SHA="${SHA[verify2]}" BUILD_TAG=v1.2.3 BUILD_VERIFY_SINCE="${SHA[verify1]}" BUILD_VERIFY_RESULT=pass BUILD_VERIFY_RUN="$RUN400" \
  -- verify 2>"$TMP/err" || fail "the release's verification failed: $(cat "$TMP/err")"
grep -qxF "verify ran job-token=none key=none" "$OUT/verify/verify.log" || fail "just verify did not run"
[[ "$(rec kind) $(rec verified) $(rec result)" == "release ${SHA[verify2]} pass" ]] || fail "$(cat "$OUT/verify/record")"
pass

NAME="verify: in the pinned image, just verify runs the image's own tacplus (looper#137)"
build BUILD_SHA="${SHA[verify2]}" BUILD_TAG=v1.2.3 CI_JOB_IMAGE="us-docker.pkg.dev/jody1-328023/tacplus/build:2.6.1@$DIGEST_A" \
  PATH="$TMP/image-bin:$TMP/bin:$PATH" -- verify 2>"$TMP/err" || fail "the verification failed: $(cat "$TMP/err")"
grep -qxF "verify tacplus=tacplus" "$OUT/verify/verify.log" || fail "not the image's tacplus: $(cat "$OUT/verify/verify.log")"
pass

NAME="verify: a red run fails, its record red, its failed harness and counterexample kept"
if build BUILD_SHA="${SHA[verifyred]}" BUILD_VERIFY=true -- verify 2>"$TMP/err"; then fail "a red verification passed"; fi
verdict_is "fail: just verify exited 1"
[[ "$(rec verified) $(rec result)" == "${SHA[verifyred]} fail" ]] || fail "$(cat "$OUT/verify/record")"
grep -qxF '### com.example.Msg -- verify_port_bounds' "$OUT/verify/failures.md" && grep -qxF 'Counterexample: port = 65536' "$OUT/verify/failures.md" ||
  fail "failures: $(cat "$OUT/verify/failures.md")"
! grep -q verify_ok "$OUT/verify/failures.md" || fail "a verified harness is a failure: $(cat "$OUT/verify/failures.md")"
grep -q 'verify rust: FAIL' "$OUT/verify/log-tail" || fail "no log tail"
RED_OUT="$OUT"
pass

NAME="verify: a repository with no verify recipe has nothing to verify"
build BUILD_SHA="${SHA[pass]}" BUILD_TAG=v1.2.3 -- verify 2>"$TMP/err" || fail "failed: $(cat "$TMP/err")"
verdict_is pass
[[ "$(rec result)" == none ]] || fail "$(cat "$OUT/verify/record")"
pass

NAME="verify-report: the record, the failures and the log's tail as the repository's latest, with the job's token"
build BUILD_SHA="${SHA[verifyred]}" BUILD_OUT="$RED_OUT" "${VAPI[@]}" -- verify-report 2>"$TMP/err" || fail "the report failed: $(cat "$TMP/err")"
for f in record failures.md log-tail; do
  grep -q "^package-put JOB-TOKEN: glcbt-stub verify-demo/latest/$f " "$TMP/api.log" || fail "$f not published: $(cat "$TMP/api.log")"
done
build BUILD_SHA="${SHA[verify2]}" BUILD_VERIFY=true BUILD_VERIFY_SINCE="${SHA[verify1]}" BUILD_VERIFY_RESULT=fail BUILD_VERIFY_RUN="$RUN400" -- verify 2>"$TMP/err"
SKIP_OUT="$OUT"
build BUILD_SHA="${SHA[verify2]}" BUILD_OUT="$SKIP_OUT" "${VAPI[@]}" -- verify-report 2>"$TMP/err" || fail "the report failed"
[[ "$(grep -c '^package-put' "$TMP/api.log")" == 1 ]] && grep -q "verify-demo/latest/record " "$TMP/api.log" ||
  fail "a skip publishes more than its record (the last run's failures stand): $(cat "$TMP/api.log")"
build BUILD_SHA="${SHA[verify2]}" "${VAPI[@]}" -- verify-report 2>"$TMP/err" || fail "no record failed the report"
! grep -q '^package-put' "$TMP/api.log" || fail "published without a record: $(cat "$TMP/api.log")"
pass

# --- the nightly's gates, the scan's item 3 (looper#73) -------------------------------
grec() { sed -n "s/^$1 //p" "$OUT/gates-report/record" | tail -n 1; } # key

NAME="plan: a nightly publishes its gates' verdict on main for the scan (gates-report), a build and a release do not"
build BUILD_SHA= BUILD_NIGHTLY=true -- plan 2>"$TMP/err" || fail "nightly plan failed: $(cat "$TMP/err")"
y="$OUT/build-gates.yml"
sed -n '/^gates-report:$/,/^[^ ]/p' "$y" > "$TMP/gr.yml"
[[ -s "$TMP/gr.yml" ]] || fail "no gates-report job: $(cat "$y")"
for l in '  image: "ghcr.io/tacplus-dev/looper:main"' '  needs: [{job: gates, artifacts: true}]' '  when: always' '  allow_failure: true' \
         '    BUILD_NIGHTLY: "true"' '    - looper-build gates-report'; do
  grep -qxF -- "$l" "$TMP/gr.yml" || fail "the gates-report job lacks '$l': $(cat "$TMP/gr.yml")"
done
grep -qxF "$(sed -n '/^gates:$/,/^[^ ]/p' "$y" | grep -m1 '^    BUILD_SHA: ')" "$TMP/gr.yml" || fail "not the gates' commit: $(cat "$TMP/gr.yml")"
build BUILD_SHA="${SHA[pass]}" -- plan 2>"$TMP/err" || fail "plan failed"
! grep -q '^gates-report:' "$OUT/build-gates.yml" || fail "a build's gates published as main's nightly"
build BUILD_SHA="${SHA[release]}" BUILD_TAG=v1.2.3 CI_COMMIT_TAG=demo/v1.2.3 -- plan 2>"$TMP/err" || fail "release plan failed"
! grep -q '^gates-report:' "$OUT/build-gates.yml" || fail "a release's gates published as main's nightly"
pass

NAME="gates-report: the nightly's verdict, its commit and run, and the gates' log tail, as the repository's latest"
build BUILD_SHA="${SHA[pass]}" -- gates 2>"$TMP/err" || fail "gates failed"
GREEN_OUT="$OUT"
build BUILD_SHA="${SHA[pass]}" BUILD_NIGHTLY=true BUILD_OUT="$GREEN_OUT" "${VAPI[@]}" -- gates-report 2>"$TMP/err" ||
  fail "the report failed: $(cat "$TMP/err")"
OUT="$GREEN_OUT"
[[ "$(grec repo) $(grec kind) $(grec checked) $(grec result) $(grec run)" == "demo nightly ${SHA[pass]} pass https://gitlab.com/tacplus-dev/build/-/pipelines/1" ]] ||
  fail "$(cat "$OUT/gates-report/record")"
[[ "$(grec at)" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$ ]] || fail "no time: $(cat "$OUT/gates-report/record")"
grep -q "gates ok" "$OUT/gates-report/log-tail" || fail "no log tail: $(cat "$OUT/gates-report/log-tail")"
for f in record log-tail; do
  grep -q "^package-put JOB-TOKEN: glcbt-stub gates-demo/latest/$f " "$TMP/api.log" || fail "$f not published: $(cat "$TMP/api.log")"
done
pass

NAME="gates-report: red gates, their reason; none when the gates job left no verdict (its runner lost)"
if build BUILD_SHA="${SHA[fail]}" -- gates 2>"$TMP/err"; then fail "a failing gate passed"; fi
RED_GATES="$OUT"
build BUILD_SHA="${SHA[fail]}" BUILD_NIGHTLY=true BUILD_OUT="$RED_GATES" "${VAPI[@]}" -- gates-report 2>"$TMP/err" || fail "the report failed: $(cat "$TMP/err")"
OUT="$RED_GATES"
[[ "$(grec result)" == fail && "$(grec why)" == "just gates exited 3"* ]] || fail "$(cat "$OUT/gates-report/record")"
build BUILD_SHA="${SHA[pass]}" BUILD_NIGHTLY=true "${VAPI[@]}" -- gates-report 2>"$TMP/err" || fail "the report failed: $(cat "$TMP/err")"
[[ "$(grec result)" == none && "$(grec why)" == "the gates job left no verdict"* ]] || fail "$(cat "$OUT/gates-report/record")"
grep -q "gates-demo/latest/record " "$TMP/api.log" || fail "no verdict is not published: $(cat "$TMP/api.log")"
pass

NAME="gates-report: only a nightly's: a build's or a release's gates are no verdict on main"
build BUILD_SHA="${SHA[pass]}" BUILD_OUT="$GREEN_OUT" "${VAPI[@]}" -- gates-report 2>"$TMP/err" || fail "the report failed: $(cat "$TMP/err")"
! grep -q '^package-put' "$TMP/api.log" || fail "published a build's gates: $(cat "$TMP/api.log")"
grep -q "not a nightly" "$TMP/err" || fail "$(cat "$TMP/err")"
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
grep -qxF '    BUILD_BASE: ""' "$TMP/sec.yml" || fail "the security job is not given the base: $(cat "$TMP/sec.yml")"
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

# One nightly for the org (looper#164): GitLab allows a project 10 pipeline
# schedules (tacplus-dev/cloud#65), so a nightly with no repository is one
# pipeline whose plan lists the repositories that pin their build image on
# main, as the cutover reads a pin, and fans out a child pipeline to each.
# The installation's repositories: page 1 full (100), page 2 the rest; demo
# pins with tacplus.lock, late with build.lock, other with both; bare pins
# nothing; old is archived and elsewhere another owner's: neither is read.
fanout_repos() { # page name[:archived|:owner]...
  local page="$1" r; shift
  { printf '{"total_count": 101, "repositories": ['
    for r in "$@"; do
      printf '{"name": "%s", "owner": {"login": "%s"}, "archived": %s},' "${r%%:*}" \
        "$([[ "$r" == *:owner ]] && echo someone || echo tacplus-dev)" "$([[ "$r" == *:archived ]] && echo true || echo false)"
    done | sed 's/,$//'
    printf ']}\n'; } > "$TMP/installation-$page"
}
fanout_fixture() {
  rm -rf "$TMP/pins"; mkdir -p "$TMP/pins/demo" "$TMP/pins/late" "$TMP/pins/other" "$TMP/pins/old"
  echo 200 > "$TMP/pins/demo/tacplus.lock"; echo 200 > "$TMP/pins/late/build.lock"
  echo 200 > "$TMP/pins/other/tacplus.lock"; echo 200 > "$TMP/pins/other/build.lock"; echo 200 > "$TMP/pins/old/tacplus.lock"
  local fill=() i; for i in $(seq 95); do fill+=("unpinned-$i"); done
  fanout_repos 1 other bare old:archived demo elsewhere:owner "${fill[@]}"
  fanout_repos 2 late
}
FANOUT=(BUILD_REPO= BUILD_SHA= BUILD_NIGHTLY=true CI_JOB_IMAGE="ghcr.io/tacplus-dev/looper@$DIGEST_A")

NAME="plan: a nightly with no repository fans out, one child pipeline per pinned repository, none for another (looper#164)"
fanout_fixture
build "${FANOUT[@]}" -- plan 2>"$TMP/err" || fail "fan-out plan failed: $(cat "$OUT/build-verdict" "$TMP/err" 2>/dev/null)"
y="$OUT/build-gates.yml"
jobs="$(grep -oE '^[A-Za-z][^:]*:' "$y" | paste -sd' ' -)"
[[ "$jobs" == "default: stages: nightly-plan-demo: nightly-demo: nightly-plan-late: nightly-late: nightly-plan-other: nightly-other:" ]] ||
  fail "not one child per pinned repository: $jobs"
grep -qxF 'token {"permissions":{"contents":"read","metadata":"read"}}' "$TMP/api.log" ||
  fail "the listing's token is not contents read-only: $(grep '^token' "$TMP/api.log")"
grep -qF 'installation-repos Bearer '"$READ_TOKEN"' page=2' "$TMP/api.log" || fail "the listing's second page was not read"
! grep -qE '^contents .* (old|elsewhere) ' "$TMP/api.log" || fail "read the pin of an archived or another owner's repository"
grep -qxF "contents Bearer $READ_TOKEN bare build.lock" "$TMP/api.log" || fail "bare's build.lock was not read"
grep -qxF "contents Bearer $READ_TOKEN other tacplus.lock" "$TMP/api.log" || fail "other's tacplus.lock was not read"
for r in demo late other; do
  sed -n "/^nightly-plan-$r:\$/,/^[^ ]/p" "$y" | sed '$d' > "$TMP/plan-$r.yml"
  for l in "  stage: plan" "  image: \"ghcr.io/tacplus-dev/looper@$DIGEST_A\"" '  tags: [arm64, build]' '    GIT_STRATEGY: none' \
           "    BUILD_REPO: \"$r\"" '    BUILD_SHA: ""' '    BUILD_ORG: "tacplus-dev"' '    BUILD_NIGHTLY: "true"' \
           '    - looper-build plan' '    paths: [build-gates.yml, build-verdict]'; do
    grep -qxF -- "$l" "$TMP/plan-$r.yml" || fail "nightly-plan-$r lacks '$l': $(cat "$TMP/plan-$r.yml")"
  done
  sed -n "/^nightly-$r:\$/,/^[^ ]/p" "$y" > "$TMP/child-$r.yml"
  for l in "  stage: nightly" '      - artifact: build-gates.yml' "        job: nightly-plan-$r" '    strategy: depend' \
           '    forward:' '      yaml_variables: false' '      pipeline_variables: false'; do
    grep -qxF -- "$l" "$TMP/child-$r.yml" || fail "nightly-$r lacks '$l': $(cat "$TMP/child-$r.yml")"
  done
done
# A nightly sets no commit status: it is no commit's verdict.
! grep -q 'looper-build status' "$y" || fail "the fan-out sets a commit status: $(grep -n 'looper-build status' "$y")"
[[ ! -e "$OUT/build-verdict" ]] || fail "the fan-out plan wrote a verdict: $(cat "$OUT/build-verdict")"
# Valid as GitLab reads it (its schema, looper-ci-lint, looper#94).
"$ROOT/looper-ci-lint" "$y" > "$TMP/lint" 2>&1 || fail "the fan-out pipeline is not valid GitLab CI: $(cat "$TMP/lint")"
pass

NAME="fan-out: each child is exactly today's nightly of its repository, and one's failure does not stop the others"
# Each child needs its own plan alone: GitLab runs a job once its needs are
# done, whatever another child's plan or pipeline did (strategy: depend: its
# pipeline's result is its trigger job's, the fan-out's red when one is).
for r in demo late other; do
  needs="$(grep '^  needs:' "$TMP/child-$r.yml")"
  [[ "$needs" == "  needs: [nightly-plan-$r]" ]] || fail "nightly-$r needs more than its own plan: $needs"
  ! grep -q '^  needs:\|^  when:\|^  allow_failure:' "$TMP/plan-$r.yml" || fail "nightly-plan-$r waits on another job: $(cat "$TMP/plan-$r.yml")"
done
grep -qxF 'stages: [plan, nightly]' "$y" || fail "no stages: $(grep stages "$y")"
# Its jobs retried as the child's: a job whose image could not be pulled too (looper#173).
grep -A3 -xF 'default:' "$y" | paste -sd'|' - | grep -qxF 'default:|  retry:|    max: 2|    when: [runner_system_failure, scheduler_failure, unknown_failure, runner_external_dependency_failure, api_failure]' ||
  fail "the fan-out's jobs are not retried when their runner is lost or their image not pulled: $(head -8 "$y")"
cp "$y" "$TMP/fanout.yml"
# demo's plan job, as the child pipeline runs it, writes today's nightly of demo.
build BUILD_SHA= BUILD_NIGHTLY=true -- plan 2>"$TMP/err" || fail "the nightly of demo failed: $(cat "$TMP/err")"
cp "$OUT/build-gates.yml" "$TMP/nightly-demo.yml"
v=(); while read -r l; do v+=("$l"); done < <(sed -n 's/^    \(BUILD_[A-Z]*\): "\(.*\)"$/\1=\2/p' "$TMP/plan-demo.yml")
build "${v[@]}" -- plan 2>"$TMP/err" || fail "demo's plan job failed: $(cat "$TMP/err")"
cmp -s "$OUT/build-gates.yml" "$TMP/nightly-demo.yml" || fail "demo's child is not its nightly: $(diff "$TMP/nightly-demo.yml" "$OUT/build-gates.yml" | head)"
# late's (no main to read here) fails in its own plan job, with its own verdict.
v=(); while read -r l; do v+=("$l"); done < <(sed -n 's/^    \(BUILD_[A-Z]*\): "\(.*\)"$/\1=\2/p' "$TMP/plan-late.yml")
if build "${v[@]}" -- plan 2>"$TMP/err"; then fail "late's plan passed with no repository"; fi
verdict_is "fail: tacplus-dev/late has no main branch to scan"
pass

NAME="fan-out: a listing or a pin it cannot read, or no pinned repository, is a fail verdict, never a nightly of fewer"
fanout_fixture; rm "$TMP/installation-2"
if build "${FANOUT[@]}" -- plan 2>"$TMP/err"; then fail "fanned out without the listing's second page"; fi
verdict_is "fail: cannot list the repositories of tacplus-dev"
[[ ! -e "$OUT/build-gates.yml" ]] || fail "wrote a fan-out"
fanout_fixture; mkdir -p "$TMP/pins/bare"; echo 502 > "$TMP/pins/bare/build.lock"
if build "${FANOUT[@]}" -- plan 2>"$TMP/err"; then fail "fanned out without bare's pin"; fi
verdict_is "fail: cannot tell whether tacplus-dev/bare pins its build image: GitHub answered 502 for build.lock"
fanout_fixture; rm -rf "$TMP/pins"
if build "${FANOUT[@]}" -- plan 2>"$TMP/err"; then fail "fanned out to nothing"; fi
verdict_is "fail: no repository of tacplus-dev pins its build image on main"
# A nightly names a repository, or none and no commit: a commit with no repository is refused.
if build "${FANOUT[@]}" BUILD_SHA="${SHA[pass]}" -- plan 2>"$TMP/err"; then fail "a nightly of a commit of no repository"; fi
verdict_is "fail: BUILD_REPO ''"
rm -rf "$TMP/pins" "$TMP/installation-"*
pass

NAME="pipeline: a nightly with no repository (a schedule, or the API) is the fan-out, from the sources a nightly has"
w="$(sed -n '/^workflow:$/,/^[^ w]/p' "$ROOT/ci/build.gitlab-ci.yml")"
grep -qF '    - if: $CI_PIPELINE_SOURCE =~ /^(api|web|trigger|schedule)$/ && $BUILD_REPO == "" && $BUILD_SHA == "" && $BUILD_NIGHTLY == "true"' <<<"$w" ||
  fail "no fan-out rule: $w"
grep -qF '    - if: $CI_PIPELINE_SOURCE =~ /^(api|web|trigger|schedule)$/ && $BUILD_REPO && $BUILD_NIGHTLY == "true"' <<<"$w" ||
  fail "the nightly of one repository is gone: $w"
pass

# GitLab passes a trigger job's variables, the pipeline's global ones among
# them, to the child pipeline, over the child's own: a nightly's BUILD_SHA, ""
# in the parent, would undo the sha the plan wrote (looper#138).
NAME="pipeline: the child pipeline runs on the commit the plan resolved, not the parent's empty sha"
g="$(sed -n '/^gates:$/,/^[^ ]/p' "$ROOT/ci/build.gitlab-ci.yml" | sed '$d')"
grep -qxF '        job: plan' <<<"$g" || fail "no gates trigger job: $g"
grep -qxF '    forward:' <<<"$g" || fail "the gates trigger forwards the parent's variables: $g"
grep -qxF '      yaml_variables: false' <<<"$g" || fail "the gates trigger forwards the parent's BUILD_SHA: $g"
grep -qxF '      pipeline_variables: false' <<<"$g" || fail "the gates trigger forwards the parent's pipeline variables: $g"
pass

NAME="gates: the code a generated recipe writes, the release jars and every tacplus.yaml's generated tree whole are the gates' artifact, for the security checks"
build BUILD_SHA="${SHA[generated]}" -- gates 2>"$TMP/err" || fail "gates failed: $(cat "$TMP/err")"
[[ "$(cat "$OUT/generated/model/model.go")" == "package model" ]] || fail "no generated code: $(ls -R "$OUT")"
# The generated tree's .json and .md a src/registry.rs include_str!s (looper#155), a .yaml a client's generates;
# not a .json outside a generated tree, nor a generated tree's dependencies.
[[ "$(cd "$OUT/built" && find . -type f | LC_ALL=C sort | tr '\n' ' ')" == "./client/gen/model/openapi.yaml ./gen/spec.go ./svc/build/libs/svc-1.0.jar ./target/classes/x/A.class ./target/demo-1.0.jar ./target/generated-sources/m/Cargo.toml ./target/generated-sources/model/AGENT.md ./target/generated-sources/model/registry.json ./target/generated-sources/model/src/lib.rs " ]] ||
  fail "built: $(cd "$OUT/built" && find . -type f)"
[[ "$(cat "$OUT/built/target/generated-sources/model/registry.json")" == "{}" ]] || fail "registry.json not kept as written"
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

# looper-scan local on a checkout, by hand (looper#161): each scanner is
# wrapped to record whether the checkout held the run's reports when it ran.
NAME="security: looper-scan local . scans the checkout, never its own reports, and leaves it as it was"
CO="$TMP/local-co"; git clone -q -b scansecret "$work" "$CO"
REC="$TMP/rec"; mkdir -p "$REC"
for t in osv-scanner govulncheck semgrep gitleaks gosec syft; do
  printf '#!/usr/bin/env bash\n[[ -e "%s/security" ]] && echo %s >> "%s/saw-reports"\nPATH="${PATH#*:}" exec %s "$@"\n' "$CO" "$t" "$TMP" "$t" > "$REC/$t"
  chmod +x "$REC/$t"
done
local_scan() { # [VAR=value...]
  local p="$TMP/bin:$SB:$PATH"; ((REAL_SCAN)) && p="$TMP/bin:$PATH"
  rm -f "$TMP/saw-reports"
  (cd "$CO" && env -i PATH="$REC:$p" HOME="$TMP/home" TMPDIR="$TMP" "$@" "$ROOT/looper-scan" local .)
}
found() { jq -r '[.[] | .tool + " " + .id + " " + .where] | sort | join("\n")' "$1/findings.json"; }
if local_scan BUILD_OUT="$TMP/local-out" 2>"$TMP/err"; then fail "the planted secret passed"; fi
OUTSIDE="$(found "$TMP/local-out/security")"
grep -q '^gitleaks deploy/env.txt:aws-access-token:1 ' <<<"$OUTSIDE" || fail "no secret: $OUTSIDE"
if local_scan 2>"$TMP/err"; then fail "the planted secret passed"; fi
[[ ! -e "$TMP/saw-reports" ]] || fail "scanned with the reports in the checkout: $(sort -u "$TMP/saw-reports" | paste -sd' ')"
[[ -z "$(git -C "$CO" status --porcelain --ignored)" ]] || fail "the checkout changed: $(git -C "$CO" status --porcelain --ignored)"
r="$(sed -n 's/^Reports: //p' "$TMP/err")"
[[ -n "$r" && "$r" != "$CO"* && -f "$r/findings.json" ]] || fail "where the reports went: '$r': $(tail -5 "$TMP/err")"
grep -qxF "Reports: $r" "$r/summary.md" || fail "the summary does not say where the reports went: $(cat "$r/summary.md")"
[[ "$(found "$r")" == "$OUTSIDE" ]] || fail "findings: $(found "$r") (with the reports outside: $OUTSIDE)"
# A BUILD_OUT inside the checkout, given: the reports go there once the scan is done.
if local_scan BUILD_OUT="$CO" 2>"$TMP/err"; then fail "the planted secret passed"; fi
[[ ! -e "$TMP/saw-reports" ]] || fail "scanned with the reports in the checkout: $(sort -u "$TMP/saw-reports" | paste -sd' ')"
[[ "$(found "$CO/security")" == "$OUTSIDE" ]] || fail "findings: $(found "$CO/security") (with the reports outside: $OUTSIDE)"
grep -qxF "Reports: $CO/security" "$CO/security/summary.md" || fail "$(cat "$CO/security/summary.md")"
grep -q '^fail: ' "$CO/security/verdict" || fail "verdict: $(cat "$CO/security/verdict")"
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

NAME="security: a service's generated tree (tacplus.yaml's output-dir) is tacplus's to scan: its SAST findings and secrets do not fail the run, hand-written code's do"
TLS_GO='package tlsconf

import "crypto/tls"

// Config is a planted finding (gosec G402).
func Config() *tls.Config {
	return &tls.Config{InsecureSkipVerify: true}
}'
plant() { # dir: a secret and a gosec finding in dir, among what the gates built
  mkdir -p "$TMP/out-$((n + 1))/built/$1"
  printf 'key = "%s"\n' "$AKIA" > "$TMP/out-$((n + 1))/built/$1/keys.txt"
  printf '%s\n' "$TLS_GO" > "$TMP/out-$((n + 1))/built/$1/tls.go"
}
plant tacplus/chassis/tlsconf
scan BUILD_SHA="${SHA[scangen]}" -- run 2>"$TMP/err" || fail "the generated tree's findings failed it: $(cat "$OUT/security/verdict")"
scan_verdict_is pass
! jq -e '.[] | select(.where | startswith("tacplus/"))' "$OUT/security/findings.json" >/dev/null ||
  fail "the generated tree's findings are counted: $(cat "$OUT/security/findings.json")"
jq -e 'any(.tool == "gosec" and .id == "G402" and .where == "tacplus/chassis/tlsconf/tls.go:7") and
       any(.tool == "gitleaks" and .where == "tacplus/chassis/tlsconf/keys.txt:1") and all(.kind == "sast" or .kind == "secret")' \
  "$OUT/security/generated.json" >/dev/null || fail "not kept aside: $(cat "$OUT/security/generated.json" 2>&1)"
grep -q '^### Not counted: the generated tree (tacplus/)' "$OUT/security/summary.md" || fail "$(cat "$OUT/security/summary.md")"
plant internal/tlsconf
if scan BUILD_SHA="${SHA[scangen]}" -- run 2>"$TMP/err"; then fail "hand-written findings passed"; fi
scan_verdict_is "fail: "
blocking | grep -qxF 'gosec G402 internal/tlsconf/tls.go:7' || fail "no blocking gosec finding: $(blocking)"
blocking | grep -qxF 'gitleaks internal/tlsconf/keys.txt:aws-access-token:1 internal/tlsconf/keys.txt:1' || fail "no blocking secret: $(blocking)"
# Without a tacplus.yaml nothing is skipped; and what a `generated` recipe
# gives (tacplus's own output, scanned at the source) is counted.
plant tacplus/chassis/tlsconf
if scan BUILD_SHA="${SHA[scanclean]}" -- run 2>"$TMP/err"; then fail "passed without a tacplus.yaml"; fi
blocking | grep -qxF 'gosec G402 tacplus/chassis/tlsconf/tls.go:7' || fail "$(blocking)"
mkdir -p "$TMP/out-$((n + 1))/generated/tacplus"; printf 'key = "%s"\n' "$AKIA" > "$TMP/out-$((n + 1))/generated/tacplus/keys.txt"
if scan BUILD_SHA="${SHA[scangen]}" -- run 2>"$TMP/err"; then fail "the output of a generated recipe passed"; fi
blocking | grep -q '^gitleaks generated/tacplus/keys.txt:aws-access-token:1 ' || fail "$(blocking)"
pass

NAME="security: the generated trees are every tacplus.yaml's output-dir, through its import; a service's own codegen is counted"
for d in tacplus/target/generated-sources/model/chassis client/gen/model/chassis server/target/generated-sources/tacplus-backend; do
  mkdir -p "$TMP/out-$((n + 1))/built/$d"; printf 'key = "%s"\n' "$AKIA" > "$TMP/out-$((n + 1))/built/$d/keys.txt"
done
if scan BUILD_SHA="${SHA[scangen2]}" -- run 2>"$TMP/err"; then fail "the service's own codegen passed"; fi
[[ "$(blocking)" == "gitleaks server/target/generated-sources/tacplus-backend/keys.txt:aws-access-token:1 server/target/generated-sources/tacplus-backend/keys.txt:1" ]] ||
  fail "blocking: $(blocking)"
[[ "$(jq -r '[.[] | select(.tool == "gitleaks") | .where] | join(" ")' "$OUT/security/generated.json")" == \
   "client/gen/model/chassis/keys.txt:1 tacplus/target/generated-sources/model/chassis/keys.txt:1" ]] ||
  fail "not kept aside: $(cat "$OUT/security/generated.json" 2>&1)"
grep -qxF '### Not counted: the generated tree (client/gen/model/, tacplus/target/generated-sources/model/)' "$OUT/security/summary.md" ||
  fail "$(cat "$OUT/security/summary.md")"
pass

NAME="security: a generated tree is the output-dir's output-name, as tacplus writes it: operator's output-dir . is tacplus/ (looper#152)"
for d in tacplus/types/services client/gen/model/chassis client/gen/hand; do
  mkdir -p "$TMP/out-$((n + 1))/built/$d"; printf 'key = "%s"\n' "$AKIA" > "$TMP/out-$((n + 1))/built/$d/keys.txt"
done
if scan BUILD_SHA="${SHA[scangen3]}" -- run 2>"$TMP/err"; then fail "the hand-written secret passed"; fi
[[ "$(blocking)" == "gitleaks client/gen/hand/keys.txt:aws-access-token:1 client/gen/hand/keys.txt:1" ]] || fail "blocking: $(blocking)"
[[ "$(jq -r '[.[] | select(.tool == "gitleaks") | .where] | join(" ")' "$OUT/security/generated.json")" == \
   "client/gen/model/chassis/keys.txt:1 tacplus/types/services/keys.txt:1" ]] ||
  fail "not kept aside: $(cat "$OUT/security/generated.json" 2>&1)"
grep -qxF '### Not counted: the generated tree (client/gen/model/, tacplus/)' "$OUT/security/summary.md" ||
  fail "$(cat "$OUT/security/summary.md")"
grep -q 'the generated tree (client/gen/model/, tacplus/): 2 SAST finding(s) and secret(s) not counted' "$TMP/err" || fail "$(cat "$TMP/err")"
pass

# SpotBugs (looper#149): a stub that records how it ran, and throws as the
# real one did on kernel (its heap exhausted writing the SARIF) when told to.
JB="$TMP/scanbin-java"; mkdir -p "$JB"; : > "$TMP/findsecbugs.jar"
cat > "$JB/spotbugs" <<EOF
#!/usr/bin/env bash
[[ "\$1" == -version ]] && { echo 4.10.5; exit; }
$(opt -sarif)
echo "spotbugs \$*" >> "$TMP/spotbugs.log"
if [[ -n "\${SPOTBUGS_THROW:-}" ]]; then
  printf 'Out of memory\nTotal memory: 805M\n free memory: 169M\nAnalyzed: %s\n' "\$tree" >&2
  printf 'Exception in thread "main" java.lang.OutOfMemoryError: Java heap space\n' >&2
  printf '\tat edu.umd.cs.findbugs.sarif.SarifBugReporter.finish(SarifBugReporter.java:43)\n' >&2
  printf '\tat edu.umd.cs.findbugs.FindBugs2.analyzeApplication(FindBugs2.java:1166)\n' >&2
  printf '\tat edu.umd.cs.findbugs.FindBugs2.main(FindBugs2.java:1232)\n' >&2
  exit 1
fi
echo '{"version":"2.1.0","runs":[{"tool":{"driver":{"name":"SpotBugs","rules":[]}},"results":[]}]}' > "\$out"
EOF
chmod +x "$JB/spotbugs"
JAVA_SCAN=(PATH="$JB:$TMP/bin:$( ((REAL_SCAN)) || echo "$SB:")$PATH" BUILD_FINDSECBUGS="$TMP/findsecbugs.jar")
scan_java() { # [VAR=value...]: scan the Java project, its classes compiled
  mkdir -p "$TMP/out-$((n + 1))/built/target/classes/demo"; : > "$TMP/out-$((n + 1))/built/target/classes/demo/Main.class"
  : > "$TMP/spotbugs.log"
  scan "${JAVA_SCAN[@]}" BUILD_SHA="${SHA[scanjava]}" "$@" -- run 2>"$TMP/err"
}

NAME="security: SpotBugs' heap is sized to the job's memory, or BUILD_SPOTBUGS_MAXHEAP"
scan_java || fail "$(cat "$OUT/security/verdict")"
heap="$(sed -nE 's/^spotbugs .*-maxHeap ([0-9]+) .*/\1/p' "$TMP/spotbugs.log")"
[[ -n "$heap" ]] && ((heap >= 768)) || fail "SpotBugs ran with no heap of at least 768 MB: $(cat "$TMP/spotbugs.log")"
grep -q ' [^ ]*/target/classes$' "$TMP/spotbugs.log" || fail "not on the classes: $(cat "$TMP/spotbugs.log")"
scan_java BUILD_SPOTBUGS_MAXHEAP=6144 || fail "$(cat "$OUT/security/verdict")"
grep -q '^spotbugs .*-maxHeap 6144 ' "$TMP/spotbugs.log" || fail "not the heap asked for: $(cat "$TMP/spotbugs.log")"
if scan_java BUILD_SPOTBUGS_MAXHEAP=6g; then fail "passed with a heap that is no size"; fi
scan_verdict_is "fail: spotbugs: BUILD_SPOTBUGS_MAXHEAP '6g' is not a size in MB"
[[ ! -s "$TMP/spotbugs.log" ]] || fail "SpotBugs ran: $(cat "$TMP/spotbugs.log")"
pass

NAME="security: a tool that throws fails the run with its exception's first line, not its stack's last"
if scan_java SPOTBUGS_THROW=1; then fail "passed"; fi
scan_verdict_is 'fail: spotbugs: exited 1: Exception in thread "main" java.lang.OutOfMemoryError: Java heap space'
grep -qxF -- '- spotbugs: exited 1: Exception in thread "main" java.lang.OutOfMemoryError: Java heap space' "$OUT/security/summary.md" ||
  fail "$(cat "$OUT/security/summary.md")"
pass

# cargo-deny on a service whose Cargo.toml path-depends on the crates its
# gates generate (looper#126): the stub cargo-deny and cargo, the other
# scanners as above.
RUST_PATH=(PATH="$RB:$TMP/bin:$( ((REAL_SCAN)) || echo "$SB:")$PATH")
deny_finding() { # the RUSTSEC finding cargo-deny reported, on the source Cargo.lock
  jq -e 'map(select(.tool == "cargo-deny")) | map(.id) == ["RUSTSEC-2026-0486"] and .[0].where == "rustix@1.1.4 (Cargo.lock)" and .[0].fix' \
    "$OUT/security/findings.json" >/dev/null ||
    fail "cargo-deny's findings: $(jq -c '[.[] | select(.tool == "cargo-deny")]' "$OUT/security/findings.json"); $(cat "$OUT/security/summary.md")"
  ! sed -n '/^### Problems/,/^$/p' "$OUT/security/summary.md" | grep -q '^- cargo-deny:' || fail "a cargo-deny problem: $(cat "$OUT/security/summary.md")"
  ls "$OUT/security/raw" | grep -q '^cargo-deny-source-1.json$' || fail "no raw report: $(ls "$OUT/security/raw")"
}

NAME="security: cargo-deny reads a service that path-depends on its output-dir, with what the gates built laid over it"
rust_generated "$TMP/out-$((n + 1))/built/target/generated-sources/model"
: > "$TMP/cargo-deny.log"
scan "${RUST_PATH[@]}" BUILD_SHA="${SHA[scanrust]}" -- run 2>"$TMP/err" || true
deny_finding
[[ "$(wc -l < "$TMP/cargo-deny.log")" == 1 ]] || fail "cargo-deny ran on: $(cat "$TMP/cargo-deny.log")"
! grep -q "crates alone" "$OUT/security/summary.md" || fail "$(cat "$OUT/security/summary.md")"
pass

NAME="security: cargo-deny reads a service that path-depends on its output-dir, with the gates' generated/ laid at it"
rust_generated "$TMP/out-$((n + 1))/generated"
: > "$TMP/cargo-deny.log"
scan "${RUST_PATH[@]}" BUILD_SHA="${SHA[scanrust]}" -- run 2>"$TMP/err" || true
deny_finding
[[ "$(wc -l < "$TMP/cargo-deny.log")" == 2 ]] || fail "cargo-deny ran on: $(cat "$TMP/cargo-deny.log")"
grep -qF 'path = "target/generated-sources/model/chassis/grpcserver"' "$TMP/cargo-deny-2.toml" || fail "not the service's manifest: $(cat "$TMP/cargo-deny-2.toml")"
! grep -q "crates alone" "$OUT/security/summary.md" || fail "$(cat "$OUT/security/summary.md")"
pass

NAME="security: without the generated crates, cargo-deny checks the Cargo.lock's crates alone, and the summary says so"
: > "$TMP/cargo-deny.log"
scan "${RUST_PATH[@]}" BUILD_SHA="${SHA[scanrust]}" -- run 2>"$TMP/err" || true
deny_finding
m="$TMP/cargo-deny-$(wc -l < "$TMP/cargo-deny.log").toml"
grep -qxF 'lock-1 = { package = "rustix", version = "=1.1.4", default-features = false }' "$m" &&
  grep -qxF 'lock-2 = { package = "tacplus-chassis", git = "https://github.com/tacplus-dev/chassis", rev = "0123456789abcdef0123456789abcdef01234567", default-features = false }' "$m" &&
  ! grep -q 'demo\|grpcserver' <(sed -n '/^\[dependencies\]/,$p' "$m") || fail "the lock's manifest: $(cat "$m")"
grep -qF "cargo-deny: Cargo.lock: its crates alone, not the build's graph (Cargo.toml does not load: error: no matching package named \`" \
  "$OUT/security/summary.md" || fail "$(cat "$OUT/security/summary.md")"
pass

NAME="security: cargo-deny that cannot run fails the run with its reason"
if scan "${RUST_PATH[@]}" CARGO_DENY_FAIL=1 BUILD_SHA="${SHA[scanrust]}" -- run 2>"$TMP/err"; then fail "passed"; fi
scan_verdict_is "fail: "
grep -qF -- "- cargo-deny: exited 1: error: no matching package named \`grpcserver\` found; location searched: " \
  "$OUT/security/summary.md" || fail "$(cat "$OUT/security/summary.md")"
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

# A land (looper#180): a build with a base (BUILD_BASE, main's commit) fails
# only on the blocking findings its change adds; the base's are standing.
BASE_SHA="${SHA[scanclean]}"
standing() { jq -r '[.[] | select(.blocking) | "\(.tool) \(.id) \(.standing)"] | unique | join("\n")' "$OUT/security/findings.json"; }
NAME="security: a land adding no blocking finding passes on a red base, the base's marked standing"
cp "$TMP/vuln-findings.json" "$TMP/base-findings.json"
scan BUILD_SHA="${SHA[scanvuln]}" BUILD_BASE="$BASE_SHA" -- run 2>"$TMP/err" || fail "the land failed on the base's findings: $(cat "$OUT/security/verdict")"
scan_verdict_is pass
grep -qxF "package-get JOB-TOKEN: glcbt-stub security-demo/$BASE_SHA/findings.json" "$TMP/api.log" ||
  fail "the base's findings were not asked for with the job token: $(cat "$TMP/api.log")"
jq -e '[.[] | select(.blocking)] | length >= 2 and all(.standing)' "$OUT/security/findings.json" >/dev/null || fail "standing: $(standing)"
grep -q "standing (the base ${BASE_SHA:0:12}'s)" "$OUT/security/summary.md" || fail "$(cat "$OUT/security/summary.md")"
sed -n '/^### Failing the policy/,/^$/p' "$OUT/security/summary.md" | grep -q '^- HIGH osv-scanner GO-2021-0113: .* (standing)$' ||
  fail "$(cat "$OUT/security/summary.md")"
jq -e '[.runs[].results[] | select(.properties.standing)] | length >= 2' "$OUT/security/findings.sarif" >/dev/null || fail "SARIF"
pass

NAME="security: a land adding a blocking finding fails on it alone"
jq '[.[] | select(.tool != "govulncheck")]' "$TMP/vuln-findings.json" > "$TMP/base-findings.json"
if scan BUILD_SHA="${SHA[scanvuln]}" BUILD_BASE="$BASE_SHA" -- run 2>"$TMP/err"; then fail "passed"; fi
scan_verdict_is "fail: "
grep -q "security finding(s) the policy fails, not the base's: GO-2021-0113" "$OUT/security/verdict" || fail "$(cat "$OUT/security/verdict")"
[[ "$(jq -r '[.[] | select(.blocking and (.standing | not)) | .tool] | unique | join(" ")' "$OUT/security/findings.json")" == govulncheck ]] ||
  fail "$(standing)"
jq -e '.[] | select(.tool == "osv-scanner" and .id == "GO-2021-0113") | .standing' "$OUT/security/findings.json" >/dev/null || fail "$(standing)"
pass

NAME="security: standing is by tool, rule and file up to the base's count, wherever the lines move"
scan BUILD_SHA="${SHA[scanbase]}" -- run 2>"$TMP/err" || fail "$(cat "$OUT/security/verdict")"
cp "$OUT/security/findings.json" "$TMP/base-findings.json"
scan BUILD_SHA="${SHA[scanbased]}" BUILD_BASE="$BASE_SHA" -- run 2>"$TMP/err" || fail "$(cat "$OUT/security/verdict")"
[[ "$(jq -c '[.[] | select(.tool == "gosec" and .id == "G306") | [.where, .standing]]' "$OUT/security/findings.json")" == \
   '[["main.go:8",true],["main.go:9",true],["main.go:10",false]]' ]] || fail "$(jq -c . "$OUT/security/findings.json")"
pass

NAME="security: a recorded baseline: its findings, by tool, rule and file up to its count, are baselined, not new, wherever their lines move"
scan BUILD_SHA="${SHA[scanbase]}" -- run 2>"$TMP/err" || fail "MEDIUM findings failed the build: $(cat "$OUT/security/verdict")"
g306() { jq -c '[.[] | select(.tool == "gosec" and .id == "G306") | {where, new, baselined}]' "$OUT/security/findings.json"; }
[[ "$(g306)" == '[{"where":"main.go:6","new":true,"baselined":false},{"where":"main.go:7","new":true,"baselined":false}]' ]] || fail "$(g306)"
"$ROOT/looper-scan" baseline "$OUT/security/findings.json" > "$TMP/baseline.json" 2>"$TMP/err" || fail "baseline: $(cat "$TMP/err")"
if ((REAL_SCAN)); then
  # The real scanners find more: the planted entry among them, written as the README shows it (looper#154).
  grep -qE '^  \{"count":2,"file":"main.go","id":"G306","tool":"gosec"\},?$' "$TMP/baseline.json" || fail "baseline: $(cat "$TMP/baseline.json")"
else
  [[ "$(cat "$TMP/baseline.json")" == "$G306_BASELINE" ]] || fail "baseline: $(cat "$TMP/baseline.json")"
fi
cp "$OUT/security/findings.json" "$TMP/previous.json"
scan BUILD_SHA="${SHA[scanbased]}" -- run 2>"$TMP/err" || fail "the baselined commit failed: $(cat "$OUT/security/verdict")"
rm "$TMP/previous.json"
[[ "$(g306)" == '[{"where":"main.go:8","new":false,"baselined":true},{"where":"main.go:9","new":false,"baselined":true},{"where":"main.go:10","new":true,"baselined":false}]' ]] ||
  fail "$(g306)"
grep -q ', 2 baselined (security-baseline.json), ' "$OUT/security/summary.md" || fail "$(cat "$OUT/security/summary.md")"
sed -n '/^### New since the previous run/,/^$/p' "$OUT/security/summary.md" | grep -q '^- MEDIUM gosec G306: main.go:10$' ||
  fail "$(cat "$OUT/security/summary.md")"
[[ "$(jq -c '[.runs[] | select(.tool.driver.name == "gosec") | .results[] | select(.ruleId == "G306") | [.level, .properties.baselined]]' "$OUT/security/findings.sarif")" == \
   '[["note",true],["note",true],["warning",false]]' ]] || fail "SARIF: $(jq -c . "$OUT/security/findings.sarif")"
pass

NAME="security: a baseline never takes a HIGH finding nor one the policy fails, and a baseline without counts fails the run"
if scan BUILD_SHA="${SHA[scanvulnbase]}" -- run 2>"$TMP/err"; then fail "a baseline accepted a HIGH finding"; fi
blocking | grep -q '^osv-scanner GO-2021-0113 golang.org/x/text@0.3.0 (go.mod)$' || fail "$(blocking)"
jq -e 'all(.[]; .baselined == false or (.severity | IN("MEDIUM", "LOW", "UNKNOWN")))' "$OUT/security/findings.json" >/dev/null ||
  fail "$(cat "$OUT/security/findings.json")"
if ((!REAL_SCAN)); then
  jq -e '.[] | select(.id == "GO-2026-5970") | .baselined and (.new | not)' "$OUT/security/findings.json" >/dev/null || fail "$(cat "$OUT/security/findings.json")"
  "$ROOT/looper-scan" baseline "$TMP/vuln-findings.json" > "$TMP/baseline.json" 2>"$TMP/err" || fail "baseline: $(cat "$TMP/err")"
  [[ "$(cat "$TMP/baseline.json")" == '[
  {"count":1,"file":"golang.org/x/text@0.3.0 (go.mod)","id":"GO-2026-5970","tool":"osv-scanner"}
]' ]] || fail "the baseline of the planted pin: $(cat "$TMP/baseline.json")"
fi
jq -n '[{tool: "gitleaks", kind: "secret", id: "k", severity: "CRITICAL", where: "a:1", blocking: true, excepted: null}]' > "$TMP/secret.json"
[[ "$("$ROOT/looper-scan" baseline "$TMP/secret.json")" == $'[\n]' ]] || fail "a secret was baselined"
# gosec reports a finding over several lines with a range (looper#156): its file is without it too.
jq -n '[{tool: "gosec", kind: "sast", id: "G104", severity: "LOW", where: "pkg/b.go:669-684", blocking: false, excepted: null},
        {tool: "gosec", kind: "sast", id: "G104", severity: "LOW", where: "pkg/b.go:12", blocking: false, excepted: null}]' > "$TMP/range.json"
[[ "$("$ROOT/looper-scan" baseline "$TMP/range.json")" == '[
  {"count":2,"file":"pkg/b.go","id":"G104","tool":"gosec"}
]' ]] || fail "the baseline of a range: $("$ROOT/looper-scan" baseline "$TMP/range.json")"
if scan BUILD_SHA="${SHA[scanbadbase]}" -- run 2>"$TMP/err"; then fail "a baseline without counts passed"; fi
scan_verdict_is "fail: security-baseline.json: not a list of {tool, id, file, count}"
pass

NAME="security: the report publishes the run's findings as the repository's latest, with the job token"
v="$OUT"
scan BUILD_SHA="${SHA[scanvuln]}" BUILD_OUT="$v" -- report 2>"$TMP/err" > "$TMP/report.out" || fail "report failed: $(cat "$TMP/err")"
grep -qxF "package-put JOB-TOKEN: glcbt-stub security-demo/latest/findings.json $(sha256sum < "$v/security/findings.json" | cut -c1-12)" "$TMP/api.log" ||
  fail "$(cat "$TMP/api.log")"
grep -q "^package-put JOB-TOKEN: glcbt-stub security-demo/latest/summary.md " "$TMP/api.log" || fail "$(cat "$TMP/api.log")"
# And as its commit's (looper#180): what a land built on that commit compares with.
grep -qxF "package-put JOB-TOKEN: glcbt-stub security-demo/${SHA[scanvuln]}/findings.json $(sha256sum < "$v/security/findings.json" | cut -c1-12)" "$TMP/api.log" ||
  fail "not published as its commit's: $(cat "$TMP/api.log")"
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

# The release jars (looper#147), in every kind, with the stub trivy (the real
# one's Java database is a download of its own) and CodeQL (the nightly's).
JAR_PATH=(PATH="$TMP/bin:$TMP/scanbin-jars:$( ((REAL_SCAN)) || echo "$SB:")$PATH")
mkdir -p "$TMP/scanbin-jars"; cp "$SB/trivy" "$SB/codeql" "$TMP/scanbin-jars/"
NAME="security: every kind, a build too, scans the release jars the gates kept: a shaded dependency's fixed HIGH fails it"
for kind in build nightly release; do
  shaded_jar "$TMP/out-$((n + 1))/built/target/demo-1.0.jar" com.example:demo:1.0 com.fasterxml.jackson.core:jackson-databind:2.9.8
  shaded_jar "$TMP/out-$((n + 1))/built/svc/build/libs/svc-1.0.jar" com.example:svc:1.0
  : > "$TMP/trivy.log"
  e=(); [[ "$kind" == release ]] && e=(BUILD_TAG=v1.2.3)
  if scan "${JAR_PATH[@]}" "${e[@]}" BUILD_SHA="${SHA[scanclean]}" BUILD_SCAN_KIND="$kind" -- run 2>"$TMP/err"; then fail "$kind passed"; fi
  scan_verdict_is "fail: 1 security finding(s) the policy fails: $JAR_CVE"
  [[ "$(blocking)" == "trivy $JAR_CVE com.fasterxml.jackson.core:jackson-databind@2.9.8 (target/demo-1.0.jar)" ]] || fail "$kind: $(blocking)"
  grep -q "^trivy rootfs .*--scanners vuln .*(svc/build/libs/svc-1.0.jar target/demo-1.0.jar)$" "$TMP/trivy.log" ||
    fail "$kind: not the jars alone: $(cat "$TMP/trivy.log")"
  jq -e '.trivy.updated_at' "$OUT/security/databases.json" >/dev/null || fail "$kind: no Trivy database time"
done
pass

NAME="security: an exception in security-exceptions.yaml accepts a jar's finding"
shaded_jar "$TMP/out-$((n + 1))/built/target/demo-1.0.jar" com.example:demo:1.0 com.fasterxml.jackson.core:jackson-databind:2.9.8
scan "${JAR_PATH[@]}" BUILD_SHA="${SHA[scanjarexc]}" -- run 2>"$TMP/err" || fail "the excepted jar failed: $(cat "$OUT/security/verdict")"
scan_verdict_is pass
[[ "$(jq -r '[.[] | select(.excepted) | .tool + ":" + .excepted] | join(" ")' "$OUT/security/findings.json")" == "trivy:$JAR_CVE" ]] ||
  fail "$(cat "$OUT/security/findings.json")"
pass

NAME="security: no release jar, no jar scan"
: > "$TMP/trivy.log"
scan "${JAR_PATH[@]}" BUILD_SHA="${SHA[scanclean]}" -- run 2>"$TMP/err" || fail "failed: $(cat "$OUT/security/verdict")"
[[ ! -s "$TMP/trivy.log" ]] || fail "trivy ran: $(cat "$TMP/trivy.log")"
pass

NAME="security: a nightly and a release fail on a standing finding, and a land with no base's findings on every one"
cp "$TMP/vuln-findings.json" "$TMP/base-findings.json"
for kind in nightly release; do
  e=(BUILD_SCAN_KIND="$kind"); [[ "$kind" == release ]] && e+=(BUILD_TAG=v1.2.3)
  if scan "${JAR_PATH[@]}" BUILD_SHA="${SHA[scanvuln]}" BUILD_BASE="$BASE_SHA" "${e[@]}" -- run 2>"$TMP/err"; then fail "$kind passed on a standing finding"; fi
  scan_verdict_is "fail: "
  grep -q "security finding(s) the policy fails: " "$OUT/security/verdict" || fail "$kind: $(cat "$OUT/security/verdict")"
  jq -e 'all(.[]; .standing == false)' "$OUT/security/findings.json" >/dev/null || fail "$kind: $(standing)"
  ! grep -q "security-demo/$BASE_SHA/" "$TMP/api.log" || fail "$kind asked for the base's findings: $(cat "$TMP/api.log")"
done
rm "$TMP/base-findings.json"
if scan BUILD_SHA="${SHA[scanvuln]}" BUILD_BASE="$BASE_SHA" -- run 2>"$TMP/err"; then fail "passed without the base's findings"; fi
grep -q "security finding(s) the policy fails: " "$OUT/security/verdict" || fail "$(cat "$OUT/security/verdict")"
grep -q "No findings of the base ${BASE_SHA:0:12}" "$OUT/security/summary.md" || fail "$(cat "$OUT/security/summary.md")"
pass

# looper-scan image (looper#167): the Go binaries of an image's /usr/local/bin,
# read by govulncheck -mode=binary, always with stubs (no image here): go
# (version, tool nm) and govulncheck read what a fake binary says it is: its Go,
# no symbol table, the vulnerable functions it calls (govulncheck reports them
# in the same shape whether a binary is stripped or not).
IB="$TMP/scanbin-image"; mkdir -p "$IB"
cat > "$IB/go" <<'EOF'
#!/usr/bin/env bash
f="${@: -1}"
case "$1 $2" in
  "version -m") echo "$f: go1.27.4"; echo "	mod	golang.org/x/vuln	v1.9.0	h1:stub" ;;
  "version "*) v="$(sed -n 's/^go: //p' "$f" 2>/dev/null)"
    if [[ -n "$v" ]]; then echo "$f: $v"; else echo "$f: could not read Go build info from $f: not a Go executable" >&2; fi ;;
  "tool nm") grep -q '^stripped$' "$f" && { echo "reading $f: no symbols" >&2; exit 1; }; echo " 1000 T main.main" ;;
  *) echo "go stub: $*" >&2; exit 1 ;;
esac
EOF
cat > "$IB/govulncheck" <<'EOF'
#!/usr/bin/env bash
[[ "$1 $2 $3" == "-mode=binary -format json" ]] || { echo "govulncheck stub: $*" >&2; exit 2; }
f="$4"; echo "$f" >> "$TMP_IMAGE_LOG"
grep -q '^unreadable$' "$f" && { echo "govulncheck: fetching vulnerabilities: vuln.go.dev: no route to host" >&2; exit 1; }
echo '{"config":{"protocol_version":"v1.0.0","scanner_name":"govulncheck","scanner_version":"v1.9.0","db":"https://vuln.go.dev","db_last_modified":"2026-11-11T02:51:11Z","scan_mode":"binary"}}'
sed -n 's/^vuln: //p' "$f" | while read -r id fixed module version package function; do
  jq -cn --arg id "$id" '{osv: {id: $id, aliases: [], summary: ("the planted " + $id)}}'
  jq -cn --arg id "$id" --arg fixed "$fixed" --arg m "$module" --arg v "$version" --arg p "$package" --arg fn "$function" \
    '{finding: {osv: $id, fixed_version: (if $fixed == "-" then null else $fixed end), trace: [{module: $m, version: $v, package: $p, function: $fn}]}}'
  jq -cn --arg id "$id" --arg m "$module" --arg v "$version" '{finding: {osv: $id, trace: [{module: $m, version: $v}]}}'
done
EOF
chmod +x "$IB/"*
IMG="$TMP/image-root"; mkdir -p "$IMG/usr/local/bin/sub" "$IMG/usr/local/share/looper"
printf 'go: go1.26.10\nvuln: GO-2026-6859 v1.26.11 stdlib go1.26.10 net/http MaxBytesReader\n' > "$IMG/usr/local/bin/docker"
printf 'go: go1.27.4\n' > "$IMG/usr/local/bin/gh"
printf 'go: go1.27.4\nvuln: GO-2021-0113 v0.3.7 golang.org/x/text v0.3.0 golang.org/x/text/language Parse\n' > "$IMG/usr/local/bin/ours"
printf 'go: go1.27.4\nstripped\nvuln: GO-2026-6905 - github.com/blakesmith/ar v0.0.0-20190502131153-809d4375e1fb github.com/blakesmith/ar Next\n' > "$IMG/usr/local/bin/sub/plain"
printf '#!/bin/sh\necho a script\n' > "$IMG/usr/local/bin/tool.sh"
printf '\177ELF, Rust\n' > "$IMG/usr/local/bin/just"
ln -s tool.sh "$IMG/usr/local/bin/link"
# The base image's record: docker and gh as it had them, and a binary of the
# same name the image replaced (ours: its sha256 is not the base image's).
{ echo "# ghcr.io/tacplus-dev/tacplus/build:2.6"
  (cd "$IMG" && sha256sum usr/local/bin/docker usr/local/bin/gh usr/local/bin/just | sed 's:  usr/:  /usr/:')
  echo "$(printf 'base' | sha256sum | cut -d' ' -f1)  /usr/local/bin/ours"; } > "$IMG/usr/local/share/looper/base-image.sha256"
image_scan() { # dir [VAR=value...]
  local d="$1"; shift
  n=$((n + 1)); OUT="$TMP/out-$n"; : > "$TMP/image.log"
  env -i PATH="$IB:$TMP/bin:$SB:$PATH" HOME="$TMP/home" TMPDIR="$TMP" TMP_IMAGE_LOG="$TMP/image.log" \
    BUILD_REPO=looper BUILD_SHA="${SHA[scanclean]}" BUILD_OUT="$OUT" "$@" "$ROOT/looper-scan" image "$IMG" "$d"
}
EXC_IMG="$TMP/image-exc"; mkdir -p "$EXC_IMG"

NAME="security: image: every Go binary of /usr/local/bin under the policy: a fixed version fails, the base image's is tacplus-dev/tacplus's, a stripped one is said"
if image_scan "$EXC_IMG" 2>"$TMP/err"; then fail "passed: $(cat "$TMP/err")"; fi
scan_verdict_is "fail: 2 security finding(s) the policy fails: GO-2021-0113, GO-2026-6859"
[[ "$(blocking)" == "govulncheck GO-2021-0113 golang.org/x/text@v0.3.0 (/usr/local/bin/ours, called: golang.org/x/text/language.Parse)
govulncheck GO-2026-6859 stdlib@go1.26.10 (/usr/local/bin/docker, the base image's: tacplus-dev/tacplus, called: net/http.MaxBytesReader)" ]] ||
  fail "blocking: $(blocking)"
# A stripped binary's findings are every vulnerable function of a package it links: counted, and said.
jq -e '[.[] | select(.id == "GO-2026-6905")] == [{tool: "govulncheck", kind: "sca", id: "GO-2026-6905", aliases: [], severity: "HIGH", fix: false,
  where: "github.com/blakesmith/ar@v0.0.0-20190502131153-809d4375e1fb (/usr/local/bin/sub/plain, read stripped, called: github.com/blakesmith/ar.Next)",
  title: "the planted GO-2026-6905", excepted: null, test: false, blocking: false, new: true, baselined: false, standing: false}]' "$OUT/security/findings.json" >/dev/null ||
  fail "$(cat "$OUT/security/findings.json")"
[[ "$(sort "$TMP/image.log")" == "$(printf '%s\n' "$IMG/usr/local/bin/docker" "$IMG/usr/local/bin/gh" "$IMG/usr/local/bin/ours" "$IMG/usr/local/bin/sub/plain")" ]] ||
  fail "govulncheck read: $(cat "$TMP/image.log")"
s="$OUT/security/summary.md"
grep -qxF "## Security checks: looper ${SHA[scanclean]} (image)" "$s" || fail "$(cat "$s")"
sed -n "/^### The image's binaries/,/^\$/p" "$s" > "$TMP/bins"
[[ "$(cat "$TMP/bins")" == "### The image's binaries (govulncheck -mode=binary on every Go binary under $IMG/usr/local/bin)
- /usr/local/bin/docker: go1.26.10, the base image's: tacplus-dev/tacplus (ghcr.io/tacplus-dev/tacplus/build:2.6)
- /usr/local/bin/gh: go1.27.4, the base image's: tacplus-dev/tacplus (ghcr.io/tacplus-dev/tacplus/build:2.6)
- /usr/local/bin/ours: go1.27.4
- /usr/local/bin/sub/plain: go1.27.4, read stripped" ]] || fail "$(cat "$s")"
grep -qxF -e "- govulncheck: /usr/local/bin/sub/plain: read stripped (no symbol table): every vulnerable function of a package it links counts as called" "$s" ||
  fail "$(cat "$s")"
grep -qxF -e "- govulncheck: not Go, not read: /usr/local/bin/just, /usr/local/bin/tool.sh" "$s" || fail "$(cat "$s")"
ls "$OUT/security/raw" | grep -q '^govulncheck-binary-' || fail "no raw report: $(ls "$OUT/security/raw")"
jq -e 'keys == ["govulncheck"] and .govulncheck.db_last_modified' "$OUT/security/databases.json" >/dev/null ||
  fail "databases: $(cat "$OUT/security/databases.json")"
pass

NAME="security: image: security-exceptions.yaml accepts a binary's finding, and an expired one fails"
printf 'exceptions:\n  - id: %s\n    reason: "the planted %s"\n    decided_by: jodydadescott\n    expires: %s\n' \
  GO-2021-0113 GO-2021-0113 2099-12-31 GO-2026-6859 GO-2026-6859 2099-12-31 > "$EXC_IMG/security-exceptions.yaml"
image_scan "$EXC_IMG" 2>"$TMP/err" || fail "the accepted findings failed: $(cat "$OUT/security/verdict")"
scan_verdict_is pass
[[ "$(jq -r '[.[] | select(.excepted) | .excepted] | join(" ")' "$OUT/security/findings.json")" == "GO-2021-0113 GO-2026-6859" ]] ||
  fail "$(cat "$OUT/security/findings.json")"
sed -i 's/2099-12-31/2020-01-31/' "$EXC_IMG/security-exceptions.yaml"
if image_scan "$EXC_IMG" 2>"$TMP/err"; then fail "an expired exception passed"; fi
scan_verdict_is "fail: exception GO-2021-0113 expired on 2020-01-31"
pass

NAME="security: image: a binary govulncheck cannot read fails the run; without the base image's record, every binary is the image's own"
rm "$EXC_IMG/security-exceptions.yaml"; mv "$IMG/usr/local/bin/ours" "$TMP/ours"
mv "$IMG/usr/local/share/looper/base-image.sha256" "$TMP/base-image.sha256"
if image_scan "$EXC_IMG" 2>"$TMP/err"; then fail "passed"; fi
blocking | grep -qxF "govulncheck GO-2026-6859 stdlib@go1.26.10 (/usr/local/bin/docker, called: net/http.MaxBytesReader)" || fail "$(blocking)"
grep -qxF -e "- no record of the base image's binaries (/usr/local/share/looper/base-image.sha256): every binary is counted as the image's own" \
  "$OUT/security/summary.md" || fail "$(cat "$OUT/security/summary.md")"
printf 'go: go1.27.4\nunreadable\n' > "$IMG/usr/local/bin/ours"
if image_scan "$EXC_IMG" 2>"$TMP/err"; then fail "passed"; fi
scan_verdict_is "fail: govulncheck: /usr/local/bin/ours: govulncheck: fetching vulnerabilities: vuln.go.dev: no route to host"
mv "$TMP/ours" "$IMG/usr/local/bin/ours"; mv "$TMP/base-image.sha256" "$IMG/usr/local/share/looper/base-image.sha256"
if image_scan "$TMP/nonexistent" 2>"$TMP/err"; then fail "no exceptions directory passed"; fi
grep -q '^usage: ' "$TMP/err" || fail "$(cat "$TMP/err")"
pass

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

# CodeQL's findings (the stub's SARIF), CRITICAL, at each path:line given.
codeql_finds() { # path:line...
  printf '%s\n' "$@" | jq -Rn '{version: "2.1.0", runs: [{tool: {driver: {name: "CodeQL",
      rules: [{id: "rust/hard-coded-cryptographic-value", properties: {"security-severity": "9.8"}}]}},
    results: [inputs | capture("^(?<u>.*):(?<l>[0-9]+)$") | {ruleId: "rust/hard-coded-cryptographic-value", level: "error",
      message: {text: "a hard-coded value"}, locations: [{physicalLocation: {artifactLocation: {uri: .u}, region: {startLine: (.l | tonumber)}}}]}]}]}' \
    > "$TMP/codeql.sarif"
}
NAME="security: a SAST finding in test code is listed (test: true), never failing the policy; one in any other file fails it, and a secret in a test still does"
mkdir -p "$TMP/scanbin-nightly"; cp "$SB/codeql" "$SB/trivy" "$TMP/scanbin-nightly/"
SCAN_API+=(PATH="$TMP/bin:$TMP/scanbin-nightly:$( ((REAL_SCAN)) || echo "$SB:")$PATH")
marked() { git -C "$work" show "${SHA[scantest]}:src/auth.rs" | grep -n "// $1\$" | cut -d: -f1 | sed 's:^:src/auth.rs\::'; }
mapfile -t IN_TESTS < <(marked test; printf '%s\n' tests/it.rs:3 crates/x/tests/common/mod.rs:1 main_test.go:5 pkg/a/b_test.go:9 \
  webapp-login/test/page.test.ts:31 web/test/helper.js:1 web/src/x.test.tsx:2 web/src/util.test.mjs:1 svc/src/test/java/demo/MainTest.java:4)
mapfile -t NOT_TESTS < <(marked production; printf '%s\n' src/tests.rs:1 src/latest/x.rs:1 attests/a.rs:1 src/test/x.rs:1 main.go:5 test/main.go:1 \
  pkg/footest.go:1 web/src/test.ts:1 web/latest/page.ts:1 web/src/testing.ts:2 svc/src/main/java/test/Main.java:1 svc/src/testing/java/X.java:1 tests/run.sh:1)
((${#IN_TESTS[@]} == 11 && ${#NOT_TESTS[@]} == 18)) || fail "the fixture's marks: ${IN_TESTS[*]} / ${NOT_TESTS[*]}"
codeql_finds "${IN_TESTS[@]}" "${NOT_TESTS[@]}"
if scan BUILD_SHA="${SHA[scantest]}" BUILD_SCAN_KIND=nightly -- run 2>"$TMP/err"; then fail "the findings outside test code passed"; fi
codeql_where() { jq -r --argjson t "$1" '[.[] | select(.tool == "codeql" and .test == $t) | .where] | sort | join(" ")' "$OUT/security/findings.json"; }
[[ "$(codeql_where false)" == "$(printf '%s\n' "${NOT_TESTS[@]}" | LC_ALL=C sort | paste -sd' ')" ]] || fail "not test code: $(codeql_where false)"
[[ "$(codeql_where true)" == "$(printf '%s\n' "${IN_TESTS[@]}" | LC_ALL=C sort | paste -sd' ')" ]] || fail "test code: $(codeql_where true)"
[[ "$(blocking | grep '^codeql ' | cut -d' ' -f3 | LC_ALL=C sort | paste -sd' ')" == "$(codeql_where false)" ]] || fail "blocking: $(blocking)"
jq -e '[.[] | select(.test)] | length == 11 and all(.severity == "CRITICAL" and .kind == "sast" and (.blocking | not))' "$OUT/security/findings.json" >/dev/null ||
  fail "$(cat "$OUT/security/findings.json")"
jq -e 'all(.test | type == "boolean")' "$OUT/security/findings.json" >/dev/null || fail "a finding without test: $(cat "$OUT/security/findings.json")"
s="$OUT/security/summary.md"
grep -q ', 11 SAST in test code (listed, never failing)[.]$' "$s" || fail "$(cat "$s")"
grep -qxF '### In test code (SAST: listed, never failing the policy; looper#179)' "$s" || fail "$(cat "$s")"
grep -qxF -e '- CRITICAL codeql rust/hard-coded-cryptographic-value: webapp-login/test/page.test.ts:31: a hard-coded value' "$s" || fail "$(cat "$s")"
[[ "$(jq -r '[.runs[] | select(.tool.driver.name == "codeql") | .results[] | select(.properties.test) | .level] | unique | join(" ")' "$OUT/security/findings.sarif")" == note ]] ||
  fail "SARIF: $(cat "$OUT/security/findings.sarif")"
# Test code's findings alone pass; a secret in a test fails.
codeql_finds "${IN_TESTS[@]}"
scan BUILD_SHA="${SHA[scantest]}" BUILD_SCAN_KIND=nightly -- run 2>"$TMP/err" || fail "test code failed it: $(cat "$OUT/security/verdict")"
scan_verdict_is pass
mkdir -p "$TMP/out-$((n + 1))/built/tests"; printf 'key = "%s"\n' "$AKIA" > "$TMP/out-$((n + 1))/built/tests/keys.txt"
if scan BUILD_SHA="${SHA[scantest]}" BUILD_SCAN_KIND=nightly -- run 2>"$TMP/err"; then fail "a secret in tests/ passed"; fi
[[ "$(blocking)" == "gitleaks tests/keys.txt:aws-access-token:1 tests/keys.txt:1" ]] || fail "blocking: $(blocking)"
rm -f "$TMP/codeql.sarif"
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
    PUB="$OUT"   # the publish job's artifacts, as the sbom job gets them: build gives the sbom job an OUT of its own
    build PATH="$TMP/bin-real:$PATH" BUILD_SHA="${SHA[release]}" BUILD_TAG=v1.2.3 BUILD_OUT="$PUB" BUILD_SBOM_UPLOAD=0 \
      -- sbom 2>"$TMP/err" || fail "the real SBOM failed: $(cat "$TMP/err")"
    [[ -s "$PUB/sbom.cdx.json" && -s "$PUB/sbom.spdx.json" ]] || fail "no SBOM of the image: $(ls "$PUB")"
  done
  [[ "${digests[0]}" == "${digests[1]}" && "${digests[0]}" == *@sha256:* ]] || fail "${digests[*]}"
  echo "ok $NAME: ${digests[0]##*@}"
else
  echo "skip $NAME: no docker with buildx here"
fi

# In a build image with rootless BuildKit (tacplus-dev/tacplus#315), in a container
# that allows it a user namespace (the in-cluster build runner's pods, looper#73),
# the image builds with no host Docker: the same commit twice, the same digest.
NAME="publish --dry-run, real rootless BuildKit, no Docker: the same commit twice gives the same digest"
if command -v tacplus-image-build >/dev/null && command -v buildctl >/dev/null && tacplus-image-build start >/dev/null 2>&1; then
  mkdir -p "$TMP/bin-bk"; ln -sf "$TMP/bin/curl" "$TMP/bin-bk/curl"
  printf '#!/bin/sh\necho "docker: no host Docker here" >&2; exit 1\n' > "$TMP/bin-bk/docker"; chmod +x "$TMP/bin-bk/docker"
  digests=()
  for _ in 1 2; do
    build PATH="$TMP/bin-bk:$PATH" BUILD_SHA="${SHA[release]}" BUILD_TAG=v1.2.3 CI_COMMIT_TAG=demo/v1.2.3 \
      BUILD_PLATFORMS=linux/arm64,linux/amd64 -- publish --dry-run 2>"$TMP/err" || fail "the rootless dry run failed"
    digests+=("$(cat "$OUT/image")")
  done
  [[ "${digests[0]}" == "${digests[1]}" && "${digests[0]}" == *@sha256:* ]] || fail "${digests[*]}"
  grep -q "publish: rootless BuildKit" "$TMP/err" || fail "not rootless BuildKit: $(cat "$TMP/err")"
  echo "ok $NAME: ${digests[0]##*@}"
else
  echo "skip $NAME: no rootless BuildKit that starts here (tacplus-image-build)"
fi

echo "looper-build: all passed"
