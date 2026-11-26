# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# The looper image: the tacplus build image (every SDK, protoc and every
# plugin, just, gh, the docker CLI, gcloud: the complete build environment)
# plus the claude CLI and the looper scripts. Published as
# ghcr.io/tacplus-dev/looper.
#
# No tacplus binary (Jody 2026-10-26): `tacplus` here is a wrapper that runs the
# release the repository pins (else its MAJOR.MINOR floor's latest patch) in the
# build image of that line, as a sibling container on the host's docker socket
# (looper#27; the tacplus/tacplus compiler image is retired, tacplus#193);
# looper-smoke generates Go with it. No credential is baked in: GH_TOKEN,
# CLAUDE_CODE_OAUTH_TOKEN and GITLAB_TOKEN are the pipeline's CI variables,
# given at run time.
#
# The build pipeline's jobs (gitlab.com/tacplus-dev/build) run looper-build in
# this image too, with none of the loopers' credentials and no agent at work:
# its gates run in each repository's pinned build image (looper#17).
#
# The build pipeline's security checks run looper-scan in this image too, with
# its scanners (looper#49).
#
# The build environment follows the newest released tacplus line (the project's
# rule: a MAJOR.MINOR, never a patch pin).
ARG TACPLUS_LINE=2.6
ARG BUILD_IMAGE=ghcr.io/tacplus-dev/tacplus/build:${TACPLUS_LINE}
ARG CLAUDE_CODE_VERSION=2.1.308

FROM ${BUILD_IMAGE}
ARG CLAUDE_CODE_VERSION
ARG TACPLUS_LINE
LABEL org.opencontainers.image.title="looper" \
      org.opencontainers.image.description="tacplus-dev looper: the tacplus build image plus the claude CLI and the per-repository looper; tacplus runs in the build image of its line" \
      org.opencontainers.image.source="https://github.com/tacplus-dev/looper" \
      org.opencontainers.image.licenses="Apache-2.0"
# The base image's own binaries, before this file adds any (looper#167): each
# file of its /usr/local/bin by sha256, under its name, for the scan below to
# say which of the image's binaries are tacplus-dev/tacplus's to fix.
ARG BUILD_IMAGE
RUN mkdir -p /usr/local/share/looper && \
    { echo "# $BUILD_IMAGE"; find /usr/local/bin -type f -exec sha256sum {} + | LC_ALL=C sort -k2; } > /usr/local/share/looper/base-image.sha256
# The docker CLI, replaced by a fixed release by digest (looper#177): build:2.6
# ships 29.9.3, built with go1.26.10, whose net/http has GO-2026-6859 (fixed in
# go1.26.11 and go1.27.4); 29.10.0 is built with go1.27.4. Replaced after the
# record above, so the scan says it is this image's, not the base's. Drop it when
# build:2.6 itself carries 29.10.0 or later (or when #73 step 3 removes the CLI).
COPY --from=docker:29.10.0-cli@sha256:34507eb5069d8be82c95dd3b6987d4250fd5fee49b82e2509b7d7a7030740d6d /usr/local/bin/docker /usr/local/bin/docker
RUN v="$(go version /usr/local/bin/docker | sed -n 's|^/usr/local/bin/docker: go||p')"; \
    test -n "$v" && test "$(printf '%s\n' 1.27.4 "$v" | sort -V | head -n1)" = 1.27.4 || \
      { echo "docker CLI: go${v:-?}, not go1.27.4 or later (GO-2026-6859)" >&2; exit 1; }; \
    docker --version | grep -q '^Docker version 29\.10\.0,'
RUN command -v jq >/dev/null || { apt-get update && apt-get install -y --no-install-recommends jq && rm -rf /var/lib/apt/lists/*; }
# openssl: the nonce of each prompt (repo-looper, looper#40).
RUN command -v openssl >/dev/null || { apt-get update && apt-get install -y --no-install-recommends openssl && rm -rf /var/lib/apt/lists/*; }
# npm, replaced by a fixed release (looper#186): build:2.6 ships npm 11.21.1, whose
# bundled ip-address 10.7.2 has GHSA-rxp7-6hxx-x8q5 (fixed in 10.7.4); 11.21.3
# bundles 10.7.5. Replaced before the claude CLI's install, which it runs; the
# build checks the bundled ip-address is 10.7.4 or later. Drop it when build:2.6
# itself carries npm 11.21.3 or later.
ARG NPM_VERSION=11.21.3
RUN npm install -g "npm@${NPM_VERSION}" && npm cache clean --force && \
    npm --version | grep -qxF "$NPM_VERSION" && \
    v="$(jq -r .version "$(npm root -g)/npm/node_modules/ip-address/package.json")"; \
    test -n "$v" && test "$(printf '%s\n' 10.7.4 "$v" | sort -V | head -n1)" = 10.7.4 || \
      { echo "npm $(npm --version 2>/dev/null || echo ?): ip-address ${v:-?}, not $NPM_VERSION with 10.7.4 or later (GHSA-rxp7-6hxx-x8q5)" >&2; exit 1; }
RUN npm install -g "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" && npm cache clean --force
# glab: the model's way to GitLab issues on a GitLab-hosted instance (SeaBeam's,
# looper#29), as gh is on GitHub; the looper itself calls GitLab's API with curl.
# Built here with GO_TOOLCHAIN (below) by its module checksum, as the scanners
# are: the release binary is built with go1.27.3, whose net/http has GO-2026-6859
# (looper#159). Its version as the release sets it (.goreleaser.yml; glab prints
# it without the v), its symbol table kept as Trivy's.
# Each Go step fetches first, through go-fetch (looper#169): its toolchain, then
# every module it builds (go install -n, or the module made here's go mod tidy),
# over HTTP/1.1, each fetch retried: two builds in a row failed on an HTTP/2
# stream reset from proxy.golang.org and sum.golang.org. It builds from the
# module cache so filled, offline: a go install's GOPROXY is the cache's
# download directory (its checksums still checked by sum.golang.org's tiles
# there), and a module made here builds what its go mod tidy fetched.
COPY go-fetch /usr/local/lib/looper/
ARG GO_TOOLCHAIN=go1.27.4 GLAB_VERSION=1.130.0
RUN set -eu; export PATH="$PATH:/usr/local/lib/looper"; \
    GOTOOLCHAIN="$GO_TOOLCHAIN" go-fetch version; GOTOOLCHAIN="$GO_TOOLCHAIN" go-fetch install -n "gitlab.com/gitlab-org/cli/cmd/glab@v$GLAB_VERSION"; \
    GOPROXY="file://$(go env GOMODCACHE)/cache/download" GOTOOLCHAIN="$GO_TOOLCHAIN" GOBIN=/usr/local/bin GOFLAGS=-mod=mod go install \
      -ldflags "-w -X main.version=v$GLAB_VERSION" "gitlab.com/gitlab-org/cli/cmd/glab@v$GLAB_VERSION"; \
    go clean -cache -modcache; glab --version | grep -q "^glab $GLAB_VERSION "; \
    go version /usr/local/bin/glab | grep -qx "/usr/local/bin/glab: $GO_TOOLCHAIN"
# gh, replaced as the docker CLI is (looper#199): build:2.6's gh has
# go.opentelemetry.io/otel/trace v1.44.0 (GO-2026-6974) and
# github.com/gorilla/websocket v1.5.3 (GO-2026-6278, fixed in an untagged
# commit). 2.105.0 requires otel v1.47.0 but still websocket v1.5.3: built here
# in a module made here with GH_WEBSOCKET_VERSION, a version upstream did not
# test (only gh codespace uses it), after the record above, so the scan says it
# is this image's. Its version as the release sets it (.goreleaser.yml), its
# symbol table kept as Trivy's. Drop the override when a gh release requires
# the fixed websocket, and the step when build:2.6 itself carries a fixed gh
# (tacplus-dev/tacplus#969).
ARG GH_VERSION=2.105.0 GH_WEBSOCKET_VERSION=1.5.4-0.20240701034025-d67f41855da4
RUN set -eu; d="$(mktemp -d)"; export PATH="$PATH:/usr/local/lib/looper"; \
    (cd "$d"; export GOTOOLCHAIN="$GO_TOOLCHAIN" GOFLAGS=-mod=mod; c=github.com/cli/cli/v2; \
      go-fetch version; go mod init looper.local/gh 2>/dev/null; \
      go mod edit -require "$c@v$GH_VERSION" -tool "$c/cmd/gh" -require "github.com/gorilla/websocket@v$GH_WEBSOCKET_VERSION"; \
      go-fetch mod tidy; go build -ldflags "-w -X $c/internal/build.Version=$GH_VERSION" -o /usr/local/bin/gh "$c/cmd/gh"); \
    gh --version | grep -q "^gh version $GH_VERSION"; \
    go version /usr/local/bin/gh | grep -qx "/usr/local/bin/gh: $GO_TOOLCHAIN"; \
    go version -m /usr/local/bin/gh | grep -q "github.com/gorilla/websocket[[:space:]]*v$GH_WEBSOCKET_VERSION[[:space:]]"; \
    for m in otel otel/trace; do v="$(go version -m /usr/local/bin/gh | awk -v m="go.opentelemetry.io/$m" '$1 == "dep" && $2 == m { print $3 }')"; \
      test -n "$v" && test "$(printf '%s\n' v1.47.0 "$v" | sort -V | head -n1)" = v1.47.0 || \
        { echo "gh: go.opentelemetry.io/$m ${v:-missing}, not v1.47.0 or later" >&2; exit 1; }; done; \
    gh help api >/dev/null; \
    go clean -cache -modcache; rm -rf "$d"
# The build pipeline's security checks (looper-scan, looper#49): every scanner
# pinned, each release archive checked against its sha256 here (linux/arm64,
# as the image), govulncheck, OSV-Scanner, Trivy and gosec by their module checksums
# (go install or a module made here, sum.golang.org). OSV-Scanner's and Trivy's release binaries carry
# reachable vulnerabilities (looper#63: its Go's stdlib; looper#64: x/net
# GO-2026-6860/6866, x/crypto's openpgp GO-2026-5932): they are built here with
# GO_TOOLCHAIN, a Go release the go command fetches and checks by its own checksum,
# and each so built must report it (looper#124: go1.27.4 for net/http's GO-2026-6859).
# govulncheck too (looper#109): it type-checks a module with the Go it was built
# with, and the base image's go1.26 cannot load a `go 1.27` module; the smoke
# proves it scans one (vuln.go.dev: the network). It builds the call graph (SSA)
# only when a vulnerable package is imported, and govulncheck 1.1.4's x/tools
# v0.29.0 panics on go1.27's net/http there (looper#151): the smoke imports
# net/http beside x/text v0.3.0 and must report the call to its GO-2021-0113,
# so the image build fails when a govulncheck cannot build go1.27's call graph.
# GO_TOOLCHAIN is the newest Go release: bump it when one lands.
# gosec too (looper#159: its 2.30.0 release binary, go1.27.3, has GO-2026-6859, and
# upstream has not released since), its version as the release sets it (.goreleaser.yml).
# gitleaks too (looper#65: its 8.30.1 release binary, go1.24.11, has 70 reachable
# vulnerabilities, and upstream has not released since): built in a module made
# here, its go.sum from sum.golang.org, which replaces github.com/ulikunitz/xz
# with GITLEAKS_XZ_VERSION (gitleaks pins v0.5.12, GO-2025-3922), a version
# upstream did not test: the smoke below proves it still finds a secret.
# Syft too (looper#88: its 1.56.0 release binary had x/net v0.61.0, GO-2026-6860/6866;
# looper#101: brotli v1.2.0, GO-2026-6888), its version set as the release sets it
# (.goreleaser.yaml), its symbol table kept as Trivy's: 1.57.1 requires x/net v0.62.0
# and brotli v1.2.8, and OSV-Scanner 2.7.1 github.com/klauspost/compress v1.20.2
# (GO-2026-6865); the build checks each binary has that fixed version or later.
# Trivy and gitleaks are built in modules made here (looper#101): every release of
# Trivy requires a compress before v1.20.2, gitleaks' too (v1.17.11), and gitleaks'
# github.com/andybalholm/brotli is before v1.2.7 (GO-2026-6888). Each module requires
# the fixed version, its <TOOL>_COMPRESS_VERSION or <TOOL>_BROTLI_VERSION, and the
# build checks it is the one built in. Drop each when that tool's release requires
# the fixed version or later.
# OSV-Scanner and gosec too (looper#199), and Trivy's otel: Trivy 0.76.2 (containerd/v2
# v2.4.2, GO-2026-7007) and OSV-Scanner 2.7.1, the latest, require go.opentelemetry.io/otel
# before v1.47.0 (GO-2026-6974), and gosec 2.30.0, the latest, github.com/gorilla/websocket
# v1.5.3 (GO-2026-6278, fixed in an untagged commit): <TOOL>_OTEL_VERSION and
# GOSEC_WEBSOCKET_VERSION, versions upstream did not test, so the smoke below runs
# each. Syft 1.57.2 requires otel v1.47.0 itself.
# Trivy built so reports GO-2026-4919 alone, not applicable: the compromised
# v0.69.4 release (CVE-2026-33634), whose range has no fix event and so matches
# every later version. Trivy is a long build: its own layer, before the others,
# so that moving another scanner does not rebuild it. Its version as the release
# sets it (goreleaser.yml), else it reads "dev"; -w without the release's -s: its
# symbol table kept, which govulncheck -mode=binary reads to tell the vulnerable
# code it calls (stripped, the same build reports the x/net and openpgp ones).
# Semgrep CE and Bandit by every wheel's hash (scanners/requirements.txt) in a
# venv of their own. CodeQL (nightly and release) is fetched by looper-scan
# when a run needs it, checked against its pinned checksum there.
ARG TRIVY_VERSION=0.76.2 TRIVY_COMPRESS_VERSION=1.20.2 TRIVY_OTEL_VERSION=1.47.0
RUN set -eu; d="$(mktemp -d)"; export PATH="$PATH:/usr/local/lib/looper"; \
    (cd "$d"; export GOTOOLCHAIN="$GO_TOOLCHAIN" GOFLAGS=-mod=mod; tr=github.com/aquasecurity/trivy; \
      go-fetch version; go mod init looper.local/trivy 2>/dev/null; \
      go mod edit -require "$tr@v$TRIVY_VERSION" -require "github.com/klauspost/compress@v$TRIVY_COMPRESS_VERSION" -tool "$tr/cmd/trivy" \
        -require "go.opentelemetry.io/otel/sdk@v$TRIVY_OTEL_VERSION" -require "go.opentelemetry.io/otel/trace@v$TRIVY_OTEL_VERSION"; \
      go-fetch mod tidy; go build -ldflags "-w -X $tr/pkg/version/app.ver=$TRIVY_VERSION" -o /usr/local/bin/trivy "$tr/cmd/trivy"); \
    trivy --version | grep -qx "Version: $TRIVY_VERSION"; \
    go version /usr/local/bin/trivy | grep -qx "/usr/local/bin/trivy: $GO_TOOLCHAIN"; \
    go version -m /usr/local/bin/trivy | grep -q "github.com/klauspost/compress[[:space:]]*v$TRIVY_COMPRESS_VERSION[[:space:]]"; \
    for m in sdk trace; do go version -m /usr/local/bin/trivy | grep -q "go.opentelemetry.io/otel/$m[[:space:]]*v$TRIVY_OTEL_VERSION[[:space:]]"; done; \
    go clean -cache -modcache; rm -rf "$d"
ARG OSV_SCANNER_VERSION=2.7.1 OSV_SCANNER_OTEL_VERSION=1.47.0
ARG CARGO_DENY_VERSION=0.20.2 CARGO_DENY_SHA256=995c82be0defc7a025cae49a2aa2644ce8245c9a3318fc4103907c6a285e8c7d
ARG SYFT_VERSION=1.57.2
ARG GITLEAKS_VERSION=8.30.1 GITLEAKS_XZ_VERSION=0.5.15 GITLEAKS_COMPRESS_VERSION=1.20.2 GITLEAKS_BROTLI_VERSION=1.2.7
ARG GOSEC_VERSION=2.30.0 GOSEC_WEBSOCKET_VERSION=1.5.4-0.20240701034025-d67f41855da4
ARG SPOTBUGS_VERSION=4.10.5 SPOTBUGS_SHA256=cce3244900cc215ccd9f5a8db29ed9468fc47824faf662f4fad005343d96007e
ARG FINDSECBUGS_VERSION=1.14.0 FINDSECBUGS_SHA256=6fa340344fa433ff46c2985dab1010e8bc739f9395c983594a5240095e92abc8
ARG GOVULNCHECK_VERSION=1.9.0
RUN set -eu; test "$(dpkg --print-architecture)" = arm64; d="$(mktemp -d)"; gh=https://github.com; \
    export PATH="$PATH:/usr/local/lib/looper"; (export GOTOOLCHAIN="$GO_TOOLCHAIN" GOFLAGS=-mod=mod; go-fetch version; \
      go-fetch install -n "golang.org/x/vuln/cmd/govulncheck@v$GOVULNCHECK_VERSION"; \
      CGO_ENABLED=0 go-fetch install -n "github.com/anchore/syft/cmd/syft@v$SYFT_VERSION"); \
    fetched="file://$(go env GOMODCACHE)/cache/download"; \
    get() { curl -fsSL -o "$d/$1" "$2"; echo "$3  $d/$1" | sha256sum -c -; }; \
    get deny.tgz "$gh/EmbarkStudios/cargo-deny/releases/download/$CARGO_DENY_VERSION/cargo-deny-$CARGO_DENY_VERSION-aarch64-unknown-linux-musl.tar.gz" "$CARGO_DENY_SHA256"; \
    tar -xzf "$d/deny.tgz" -C "$d"; install -m 0755 "$d/cargo-deny-$CARGO_DENY_VERSION-aarch64-unknown-linux-musl/cargo-deny" /usr/local/bin/cargo-deny; \
    get spotbugs.tgz "$gh/spotbugs/spotbugs/releases/download/$SPOTBUGS_VERSION/spotbugs-$SPOTBUGS_VERSION.tgz" "$SPOTBUGS_SHA256"; \
    mkdir -p /opt/scanners; tar -xzf "$d/spotbugs.tgz" -C /opt/scanners; ln -s "/opt/scanners/spotbugs-$SPOTBUGS_VERSION/bin/spotbugs" /usr/local/bin/spotbugs; \
    get findsecbugs-plugin.jar "https://repo1.maven.org/maven2/com/h3xstream/findsecbugs/findsecbugs-plugin/$FINDSECBUGS_VERSION/findsecbugs-plugin-$FINDSECBUGS_VERSION.jar" "$FINDSECBUGS_SHA256"; \
    install -m 0644 "$d/findsecbugs-plugin.jar" /opt/scanners/findsecbugs-plugin.jar; \
    GOPROXY="$fetched" GOTOOLCHAIN="$GO_TOOLCHAIN" GOBIN=/usr/local/bin GOFLAGS=-mod=mod go install "golang.org/x/vuln/cmd/govulncheck@v$GOVULNCHECK_VERSION"; \
    go version /usr/local/bin/govulncheck | grep -qx "/usr/local/bin/govulncheck: $GO_TOOLCHAIN"; \
    mkdir "$d/govulncheck"; printf 'module looper.local/smoke\n\ngo 1.27\n\ntoolchain %s\n\nrequire golang.org/x/text v0.3.0\n' "$GO_TOOLCHAIN" > "$d/govulncheck/go.mod"; \
    printf 'package main\n\nimport (\n\t"math/rand/v2"\n\t"net/http"\n\n\t"golang.org/x/text/language"\n)\n\nfunc main() {\n\t_, _ = language.Parse("en")\n\tprintln(rand.N(6))\n\t_ = http.ListenAndServe(":0", nil)\n}\n' > "$d/govulncheck/main.go"; \
    (cd "$d/govulncheck" && GOFLAGS=-mod=mod go-fetch mod tidy && GOFLAGS=-mod=mod govulncheck -format json ./... > "$d/govulncheck.json") || \
      { echo "govulncheck: a go 1.27 module importing net/http does not scan" >&2; exit 1; }; \
    jq -s -e --arg go "$GO_TOOLCHAIN" '[.[] | .config? // empty | .go_version] == [$go]' "$d/govulncheck.json" >/dev/null; \
    jq -s -e '[.[] | .finding? // empty | select(.trace[0].function == "Parse") | .osv] | index("GO-2021-0113")' "$d/govulncheck.json" >/dev/null; \
    mkdir "$d/gosec"; (cd "$d/gosec"; export GOTOOLCHAIN="$GO_TOOLCHAIN" GOFLAGS=-mod=mod; gs=github.com/securego/gosec/v2; \
      go-fetch version; go mod init looper.local/gosec 2>/dev/null; \
      go mod edit -require "$gs@v$GOSEC_VERSION" -tool "$gs/cmd/gosec" -require "github.com/gorilla/websocket@v$GOSEC_WEBSOCKET_VERSION"; \
      go-fetch mod tidy; go build -ldflags "-w -X main.Version=$GOSEC_VERSION -X main.GitTag=v$GOSEC_VERSION" -o /usr/local/bin/gosec "$gs/cmd/gosec"); \
    gosec -version | grep -qx "Version: $GOSEC_VERSION"; \
    go version -m /usr/local/bin/gosec | grep -q "github.com/gorilla/websocket[[:space:]]*v$GOSEC_WEBSOCKET_VERSION[[:space:]]"; \
    mkdir "$d/osv-scanner"; (cd "$d/osv-scanner"; export GOTOOLCHAIN="$GO_TOOLCHAIN" GOFLAGS=-mod=mod; os=github.com/google/osv-scanner/v2; \
      go-fetch version; go mod init looper.local/osv-scanner 2>/dev/null; \
      go mod edit -require "$os@v$OSV_SCANNER_VERSION" -tool "$os/cmd/osv-scanner" -require "go.opentelemetry.io/otel/trace@v$OSV_SCANNER_OTEL_VERSION"; \
      go-fetch mod tidy; go build -ldflags -w -o /usr/local/bin/osv-scanner "$os/cmd/osv-scanner"); \
    osv-scanner --version | grep -qx "osv-scanner version: $OSV_SCANNER_VERSION"; \
    go version -m /usr/local/bin/osv-scanner | grep -q "go.opentelemetry.io/otel/trace[[:space:]]*v$OSV_SCANNER_OTEL_VERSION[[:space:]]"; \
    mkdir "$d/gitleaks"; (cd "$d/gitleaks"; export GOTOOLCHAIN="$GO_TOOLCHAIN" GOFLAGS=-mod=mod; gl=github.com/zricethezav/gitleaks/v8; \
      go-fetch version; go mod init looper.local/gitleaks 2>/dev/null; \
      go mod edit -require "$gl@v$GITLEAKS_VERSION" -tool "$gl" -replace "github.com/ulikunitz/xz=github.com/ulikunitz/xz@v$GITLEAKS_XZ_VERSION" \
        -require "github.com/klauspost/compress@v$GITLEAKS_COMPRESS_VERSION" -require "github.com/andybalholm/brotli@v$GITLEAKS_BROTLI_VERSION"; \
      go-fetch mod tidy; go build -ldflags "-w -X $gl/version.Version=$GITLEAKS_VERSION" -o /usr/local/bin/gitleaks "$gl"); \
    gitleaks version | grep -qx "$GITLEAKS_VERSION"; \
    go version -m /usr/local/bin/gitleaks | grep -q "github.com/klauspost/compress[[:space:]]*v$GITLEAKS_COMPRESS_VERSION[[:space:]]"; \
    go version -m /usr/local/bin/gitleaks | grep -q "github.com/andybalholm/brotli[[:space:]]*v$GITLEAKS_BROTLI_VERSION[[:space:]]"; \
    GOPROXY="$fetched" GOTOOLCHAIN="$GO_TOOLCHAIN" GOBIN=/usr/local/bin GOFLAGS=-mod=mod CGO_ENABLED=0 go install \
      -ldflags "-w -X main.version=$SYFT_VERSION" "github.com/anchore/syft/cmd/syft@v$SYFT_VERSION"; \
    syft --version | grep -qx "syft $SYFT_VERSION"; \
    atleast() { v="$(go version -m "/usr/local/bin/$1" | awk -v m="$2" '$1 == "dep" && $2 == m { print $3 }')"; \
      test -n "$v" && test "$(printf '%s\n' "v$3" "$v" | sort -V | head -n1)" = "v$3" || \
        { echo "$1: $2 ${v:-missing}, not v$3 or later" >&2; exit 1; }; }; \
    atleast osv-scanner github.com/klauspost/compress 1.20.2; \
    atleast syft github.com/andybalholm/brotli 1.2.7; atleast syft golang.org/x/net 0.62.0; \
    atleast syft go.opentelemetry.io/otel/sdk 1.47.0; atleast syft go.opentelemetry.io/otel/trace 1.47.0; \
    for b in gosec osv-scanner gitleaks syft; do go version "/usr/local/bin/$b" | grep -qx "/usr/local/bin/$b: $GO_TOOLCHAIN"; done; \
    go clean -cache -modcache; \
    rm -rf "$d"
# clippy, of the image's Rust toolchain.
RUN rustup component add clippy && cargo clippy --version
# Semgrep runs on dependency versions it does not declare (scanners/requirements.txt,
# looper#53): it scans scanners/smoke/ here, offline, and must report its one finding.
# OSV-Scanner, built from source (looper#63), must find the vulnerable dependency
# planted in scanners/smoke/osv-smoke.pip (OSV's API: the network), and Trivy, built
# from source (looper#64), the same one in the SBOM scanners/smoke/trivy-smoke.json
# (its database fetched into a cache of its own and removed: the scans fetch theirs;
# the file's name keeps it out of the tree scans, which read SBOMs named *.cdx.json).
# gitleaks, built from source with xz replaced (looper#65), must find the AWS key
# planted in a repository made here (the key put together at run time: the tree's
# own scan finds no secret in this file), in its history and in its files, and
# exit as the release does: 1 on a leak, 0 with --exit-code 0 and on a clean file.
# gosec, built with GOSEC_WEBSOCKET_VERSION (looper#199), must report G204 in a Go
# file made here at run time, as the key is, so the tree scans do not report it.
COPY scanners/requirements.txt /opt/scanners/requirements.txt
COPY scanners/smoke/ /opt/scanners/smoke/
RUN set -eu; python3 -m venv /opt/scanners/venv; \
    /opt/scanners/venv/bin/pip install -q --no-cache-dir --require-hashes --no-deps -r /opt/scanners/requirements.txt; \
    ln -s /opt/scanners/venv/bin/semgrep /opt/scanners/venv/bin/bandit /usr/local/bin/; \
    for t in osv-scanner cargo-deny trivy syft gitleaks gosec spotbugs govulncheck semgrep bandit; do command -v "$t" >/dev/null; done; \
    s=/opt/scanners/smoke; semgrep scan --config "$s/rule.yaml" --metrics=off --disable-version-check --json -q "$s/smoke.py" > /tmp/smoke.json; \
    jq -e '[.results[].check_id | endswith("looper-smoke")] == [true] and .errors == []' /tmp/smoke.json >/dev/null || \
      { echo "semgrep: the smoke's finding is missing" >&2; cat /tmp/smoke.json >&2; exit 1; }; \
    osv-scanner scan source -L "requirements.txt:$s/osv-smoke.pip" --format json --output /tmp/smoke.json >/dev/null || test $? = 1; \
    jq -e '[.results[].packages[] | select(.package.name == "urllib3") | (.vulnerabilities | length) > 0] == [true]' /tmp/smoke.json >/dev/null || \
      { echo "osv-scanner: the planted urllib3 1.24.1 is not found vulnerable" >&2; cat /tmp/smoke.json >&2; exit 1; }; \
    trivy sbom -q --cache-dir /tmp/trivy-smoke --scanners vuln --format json -o /tmp/smoke.json "$s/trivy-smoke.json"; rm -rf /tmp/trivy-smoke; \
    jq -e '[.Results[]?.Vulnerabilities[]? | select(.PkgName == "urllib3")] | length > 0' /tmp/smoke.json >/dev/null || \
      { echo "trivy: the planted urllib3 1.24.1 is not found vulnerable" >&2; cat /tmp/smoke.json >&2; exit 1; }; \
    g="$(mktemp -d)"; git -C "$g" init -q; printf 'aws_access_key_id = %s%s\n' AKIA QYLPMN5HHHFPZAM2 > "$g/env.txt"; \
    git -C "$g" add env.txt; git -C "$g" -c user.name=smoke -c user.email=smoke@localhost commit -qm smoke; \
    for m in git dir; do rc=0; gitleaks "$m" --no-banner --redact -f json -r /tmp/smoke.json "$g" 2>/dev/null || rc=$?; \
      jq -e --argjson rc "$rc" '$rc == 1 and ([.[] | [.RuleID, (.File | sub(".*/"; "")), .StartLine]] == [["aws-access-token", "env.txt", 1]])' /tmp/smoke.json >/dev/null || \
        { echo "gitleaks $m: exited $rc, the planted AWS key is not found" >&2; cat /tmp/smoke.json >&2; exit 1; }; done; \
    gitleaks dir --no-banner --exit-code 0 "$g" 2>/dev/null || { echo "gitleaks: --exit-code 0 exited $?" >&2; exit 1; }; \
    rm "$g/env.txt"; echo clean > "$g/ok.txt"; \
    gitleaks dir --no-banner "$g/ok.txt" 2>/dev/null || { echo "gitleaks: a clean file exited $?" >&2; exit 1; }; \
    rm -rf "$g"; g="$(mktemp -d)"; (cd "$g" && go mod init looper.local/smoke 2>/dev/null); \
    printf 'package main\n\nimport (\n\t"os"\n\t"os/exec"\n)\n\nfunc main() {\n\t_ = exec.Command(os.Args[1]).Run()\n}\n' > "$g/main.go"; \
    rc=0; (cd "$g" && gosec -quiet -fmt json -out /tmp/smoke.json ./...) || rc=$?; \
    jq -e --argjson rc "$rc" '$rc == 1 and ([.Issues[].rule_id] | index("G204"))' /tmp/smoke.json >/dev/null || \
      { echo "gosec: exited $rc, the planted G204 is not found" >&2; cat /tmp/smoke.json >&2; exit 1; }; \
    rm -rf "$g" /tmp/smoke.json
COPY looper-lib.sh /usr/local/lib/looper/
# The runner VMs' startup-script and bake (runner-image, looper#43).
COPY runner/ /usr/local/lib/looper/runner/
COPY repo-looper looper-dispatch looper-build looper-scan looper-token looper-ruleset looper-suggest looper-recap looper-trace looper-verify tacplus looper-smoke looper-docker looper-docker-broker looper-pkill runner-image looper-vm looper-merger /usr/local/bin/
# The image's Go binaries under the tree's policy (looper#167; README: Security
# checks): govulncheck -mode=binary on every one under /usr/local/bin, the
# tools above and the base image's, with this commit's security-exceptions.yaml
# (kept beside the record: what the image accepts). A reachable vulnerability
# with a fixed version fails the image build, here and in a release's publish,
# before anything is pushed; the summary is in the build's log. Last, so it
# reads every binary the image ships (vuln.go.dev: the network).
# REVISION: the commit, as a release's publish gives it (image.yml does not: unknown).
ARG REVISION
COPY security-exceptions.yaml /usr/local/share/looper/
RUN BUILD_REPO=looper BUILD_SHA="${REVISION:-unknown}" BUILD_OUT=/tmp/image-scan looper-scan image / /usr/local/share/looper && \
    rm -rf /tmp/image-scan
ENV LOOPER_IMAGE=1 LOOPER_TACPLUS_LINE=${TACPLUS_LINE} LOOPER_LIB=/usr/local/lib/looper/looper-lib.sh LOOPER_WORK=/work
WORKDIR /work
