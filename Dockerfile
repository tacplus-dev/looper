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
# A looper with its own identity (looper#28, kernel first) runs looper-identity
# (its LLM-free prepare and commit jobs) and repo-looper --think from it too.
#
# The build environment follows the newest released tacplus line (the project's
# rule: a MAJOR.MINOR, never a patch pin).
ARG TACPLUS_LINE=2.5
ARG BUILD_IMAGE=ghcr.io/tacplus-dev/tacplus/build:${TACPLUS_LINE}
ARG CLAUDE_CODE_VERSION=2.1.308

FROM ${BUILD_IMAGE}
ARG CLAUDE_CODE_VERSION
ARG TACPLUS_LINE
LABEL org.opencontainers.image.title="looper" \
      org.opencontainers.image.description="tacplus-dev looper: the tacplus build image plus the claude CLI and the per-repository looper; tacplus runs in the build image of its line" \
      org.opencontainers.image.source="https://github.com/tacplus-dev/looper" \
      org.opencontainers.image.licenses="Apache-2.0"
RUN command -v jq >/dev/null || { apt-get update && apt-get install -y --no-install-recommends jq && rm -rf /var/lib/apt/lists/*; }
# openssl: the nonce of each prompt (repo-looper, looper#40).
RUN command -v openssl >/dev/null || { apt-get update && apt-get install -y --no-install-recommends openssl && rm -rf /var/lib/apt/lists/*; }
RUN npm install -g "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" && npm cache clean --force
# glab: the model's way to GitLab issues on a GitLab-hosted instance (SeaBeam's,
# looper#29), as gh is on GitHub; the looper itself calls GitLab's API with curl.
# The release's archive, checked against its checksums.txt.
ARG GLAB_VERSION=1.126.0
RUN set -eu; a="$(dpkg --print-architecture)"; f="glab_${GLAB_VERSION}_linux_${a}.tar.gz"; \
    u="https://gitlab.com/gitlab-org/cli/-/releases/v${GLAB_VERSION}/downloads"; d="$(mktemp -d)"; \
    curl -fsSL -o "$d/$f" "$u/$f"; curl -fsSL -o "$d/checksums.txt" "$u/checksums.txt"; \
    (cd "$d" && grep " $f\$" checksums.txt | sha256sum -c -); \
    tar -xzf "$d/$f" -C "$d" bin/glab; install -m 0755 "$d/bin/glab" /usr/local/bin/glab; rm -rf "$d"; glab --version
# The build pipeline's security checks (looper-scan, looper#49): every scanner
# pinned, each release archive checked against its sha256 here (linux/arm64,
# as the image), govulncheck, OSV-Scanner and Trivy by their module checksums (go
# install, sum.golang.org). OSV-Scanner's and Trivy's release binaries carry
# reachable vulnerabilities (looper#63: its Go's stdlib; looper#64: x/net
# GO-2026-6860/6866, x/crypto's openpgp GO-2026-5932): they are built here with
# GO_TOOLCHAIN, a Go release the go command fetches and checks by its own checksum.
# Trivy built so reports GO-2026-4919 alone, not applicable: the compromised
# v0.69.4 release (CVE-2026-33634), whose range has no fix event and so matches
# every later version. Trivy is a long build: its own layer, before the others,
# so that moving another scanner does not rebuild it. Its version as the release
# sets it (goreleaser.yml), else it reads "dev".
# Semgrep CE and Bandit by every wheel's hash (scanners/requirements.txt) in a
# venv of their own. CodeQL (nightly and release) is fetched by looper-scan
# when a run needs it, checked against its pinned checksum there.
ARG GO_TOOLCHAIN=go1.27.3 TRIVY_VERSION=0.76.1
RUN set -eu; GOTOOLCHAIN="$GO_TOOLCHAIN" GOBIN=/usr/local/bin GOFLAGS=-mod=mod go install \
      -ldflags "-s -w -X github.com/aquasecurity/trivy/pkg/version/app.ver=$TRIVY_VERSION" \
      "github.com/aquasecurity/trivy/cmd/trivy@v$TRIVY_VERSION"; \
    go clean -cache -modcache; trivy --version | grep -qx "Version: $TRIVY_VERSION"
ARG OSV_SCANNER_VERSION=2.7.0
ARG CARGO_DENY_VERSION=0.20.2 CARGO_DENY_SHA256=995c82be0defc7a025cae49a2aa2644ce8245c9a3318fc4103907c6a285e8c7d
ARG SYFT_VERSION=1.56.0 SYFT_SHA256=ace61b9397ae28189c674ae332d67a8074dafd71e87724dfb8b22412d8253bb5
ARG GITLEAKS_VERSION=8.30.1 GITLEAKS_SHA256=e4a487ee7ccd7d3a7f7ec08657610aa3606637dab924210b3aee62570fb4b080
ARG GOSEC_VERSION=2.30.0 GOSEC_SHA256=0867994920453070a5d6a713e35921a3058473e5c3bf777fdd5a2d6f95313fda
ARG SPOTBUGS_VERSION=4.10.5 SPOTBUGS_SHA256=cce3244900cc215ccd9f5a8db29ed9468fc47824faf662f4fad005343d96007e
ARG FINDSECBUGS_VERSION=1.14.0 FINDSECBUGS_SHA256=6fa340344fa433ff46c2985dab1010e8bc739f9395c983594a5240095e92abc8
ARG GOVULNCHECK_VERSION=1.1.4
RUN set -eu; test "$(dpkg --print-architecture)" = arm64; d="$(mktemp -d)"; gh=https://github.com; \
    get() { curl -fsSL -o "$d/$1" "$2"; echo "$3  $d/$1" | sha256sum -c -; }; \
    get deny.tgz "$gh/EmbarkStudios/cargo-deny/releases/download/$CARGO_DENY_VERSION/cargo-deny-$CARGO_DENY_VERSION-aarch64-unknown-linux-musl.tar.gz" "$CARGO_DENY_SHA256"; \
    tar -xzf "$d/deny.tgz" -C "$d"; install -m 0755 "$d/cargo-deny-$CARGO_DENY_VERSION-aarch64-unknown-linux-musl/cargo-deny" /usr/local/bin/cargo-deny; \
    get syft.tgz "$gh/anchore/syft/releases/download/v$SYFT_VERSION/syft_${SYFT_VERSION}_linux_arm64.tar.gz" "$SYFT_SHA256"; \
    tar -xzf "$d/syft.tgz" -C "$d" syft; install -m 0755 "$d/syft" /usr/local/bin/syft; \
    get gitleaks.tgz "$gh/gitleaks/gitleaks/releases/download/v$GITLEAKS_VERSION/gitleaks_${GITLEAKS_VERSION}_linux_arm64.tar.gz" "$GITLEAKS_SHA256"; \
    tar -xzf "$d/gitleaks.tgz" -C "$d" gitleaks; install -m 0755 "$d/gitleaks" /usr/local/bin/gitleaks; \
    get gosec.tgz "$gh/securego/gosec/releases/download/v$GOSEC_VERSION/gosec_${GOSEC_VERSION}_linux_arm64.tar.gz" "$GOSEC_SHA256"; \
    tar -xzf "$d/gosec.tgz" -C "$d" gosec; install -m 0755 "$d/gosec" /usr/local/bin/gosec; \
    get spotbugs.tgz "$gh/spotbugs/spotbugs/releases/download/$SPOTBUGS_VERSION/spotbugs-$SPOTBUGS_VERSION.tgz" "$SPOTBUGS_SHA256"; \
    mkdir -p /opt/scanners; tar -xzf "$d/spotbugs.tgz" -C /opt/scanners; ln -s "/opt/scanners/spotbugs-$SPOTBUGS_VERSION/bin/spotbugs" /usr/local/bin/spotbugs; \
    get findsecbugs-plugin.jar "https://repo1.maven.org/maven2/com/h3xstream/findsecbugs/findsecbugs-plugin/$FINDSECBUGS_VERSION/findsecbugs-plugin-$FINDSECBUGS_VERSION.jar" "$FINDSECBUGS_SHA256"; \
    install -m 0644 "$d/findsecbugs-plugin.jar" /opt/scanners/findsecbugs-plugin.jar; \
    GOBIN=/usr/local/bin GOFLAGS=-mod=mod go install "golang.org/x/vuln/cmd/govulncheck@v$GOVULNCHECK_VERSION"; \
    GOTOOLCHAIN="$GO_TOOLCHAIN" GOBIN=/usr/local/bin GOFLAGS=-mod=mod go install "github.com/google/osv-scanner/v2/cmd/osv-scanner@v$OSV_SCANNER_VERSION"; \
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
      { echo "trivy: the planted urllib3 1.24.1 is not found vulnerable" >&2; cat /tmp/smoke.json >&2; exit 1; }; rm -f /tmp/smoke.json
COPY looper-lib.sh /usr/local/lib/looper/
# The runner VMs' startup-script and bake (runner-image, looper#43).
COPY runner/ /usr/local/lib/looper/runner/
COPY repo-looper looper-dispatch looper-build looper-scan looper-identity looper-suggest looper-recap looper-trace tacplus looper-smoke looper-docker looper-pkill runner-image /usr/local/bin/
ENV LOOPER_IMAGE=1 LOOPER_TACPLUS_LINE=${TACPLUS_LINE} LOOPER_LIB=/usr/local/lib/looper/looper-lib.sh LOOPER_WORK=/work
WORKDIR /work
