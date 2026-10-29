# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# The looper image: the tacplus build image (every SDK, protoc and every
# plugin, just, gh, the docker CLI, gcloud: the complete build environment)
# plus the claude CLI and the looper scripts. Published as
# ghcr.io/tacplus-dev/looper.
#
# No tacplus binary (Jody 2026-10-26): `tacplus` here is a wrapper that runs the
# compiler image for the repository's MAJOR.MINOR floor, at its latest patch,
# as a sibling container on the host's docker socket. No credential is baked in:
# GH_TOKEN, CLAUDE_CODE_OAUTH_TOKEN and GITLAB_TOKEN are the pipeline's CI
# variables, given at run time.
#
# The build environment follows the newest released tacplus line (the project's
# rule: a MAJOR.MINOR, never a patch pin).
ARG BUILD_IMAGE=ghcr.io/tacplus-dev/tacplus/build:2.4
ARG CLAUDE_CODE_VERSION=2.1.308

FROM ${BUILD_IMAGE}
ARG CLAUDE_CODE_VERSION
LABEL org.opencontainers.image.title="looper" \
      org.opencontainers.image.description="tacplus-dev looper: the tacplus build image plus the claude CLI and the per-repository looper; tacplus runs as its own image" \
      org.opencontainers.image.source="https://github.com/tacplus-dev/looper" \
      org.opencontainers.image.licenses="Apache-2.0"
RUN command -v jq >/dev/null || { apt-get update && apt-get install -y --no-install-recommends jq && rm -rf /var/lib/apt/lists/*; }
RUN npm install -g "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" && npm cache clean --force
COPY looper-lib.sh ports.yaml /usr/local/lib/looper/
COPY repo-looper looper-port looper-dispatch tacplus looper-smoke /usr/local/bin/
ENV LOOPER_IMAGE=1 LOOPER_LIB=/usr/local/lib/looper/looper-lib.sh LOOPER_WORK=/work
WORKDIR /work
