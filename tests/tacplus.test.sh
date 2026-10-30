#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# The tacplus wrapper. Which tacplus (looper#27): the release tacplus.lock
# pins, else the newest patch of the floor's line, verified against its
# checksums.txt and run in the build image of its line (never the retired
# tacplus/tacplus compiler image, which has no go). Its GitHub credentials
# (looper#11): a clone of https://github.com in the container gets $GH_TOKEN,
# a clone from any other host gets no credential, and the token is on no disk
# and no command line. The releases are files (file:// URLs) and every release
# "binary" is git; a stub `docker run` runs it with only the environment the
# wrapper hands it; tests/git-server.py is the network, an HTTPS proxy that
# serves every host itself and logs the credentials it gets.
# Run: tests/tacplus.test.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; SRV="$(mktemp -d)"; pid=""
trap '[[ -n "$pid" ]] && kill "$pid" 2>/dev/null; rm -rf "$TMP" "$SRV"' EXIT
TOKEN="ghp_stub$RANDOM$RANDOM$RANDOM"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

# The server, outside $TMP: its log holds the credentials it was sent.
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=stub -keyout "$SRV/key.pem" -out "$SRV/cert.pem" \
  -addext "subjectAltName=DNS:github.com,DNS:gitlab.example.test" 2>/dev/null
for h in github.com gitlab.example.test; do
  git init -q "$SRV/src-$h"; git -C "$SRV/src-$h" commit -q --allow-empty -m "from $h"
  git clone -q --bare "$SRV/src-$h" "$SRV/repos/$h/org/repo.git"
done
: > "$SRV/log"
python3 -I "$ROOT/tests/git-server.py" "$SRV/repos" "$SRV/cert.pem" "$SRV/key.pem" "$SRV/log" > "$SRV/port" &
pid=$!
for _ in $(seq 50); do [[ -s "$SRV/port" ]] && break; sleep 0.1; done
PORT="$(cat "$SRV/port")"; [[ -n "$PORT" ]] || { echo "FAIL: stub git server did not start" >&2; exit 1; }

# The releases: 2.4.0, 2.4.1 and 2.5.0, whose "binary" (git) first notes its
# version in $TACPLUS_SAYS; a draft and a pre-release of 2.4 that must not be
# taken; and 2.3.0, whose binary does not match its checksums.txt.
case "$(uname -m)" in x86_64 | amd64) ARCH=amd64 ;; *) ARCH=arm64 ;; esac
REL="$TMP/releases"; mkdir -p "$REL/dl"
release() { # VERSION [tampered]
  local d="$REL/dl/v$1" a="tacplus-${1//./-}-linux-$ARCH"
  mkdir -p "$d"
  printf '#!/usr/bin/env bash\necho "tacplus %s" >> "${TACPLUS_SAYS:-/dev/null}"\nexec git "$@"\n' "$1" > "$d/$a"
  { echo "0000  tacplus-${1//./-}-darwin-$ARCH"; (cd "$d" && sha256sum "$a"); } > "$d/checksums.txt"
  [[ -z "${2:-}" ]] || echo "# tampered" >> "$d/$a"
}
release 2.4.0; release 2.4.1; release 2.5.0; release 2.3.0 tampered
releases_json() { # VERSION...
  { printf '['; printf '{"tag_name":"v%s","draft":false},' "$@"
    printf '{"tag_name":"v2.4.7","draft":true},{"tag_name":"v2.4.9-rc.1","draft":false}]'; } > "$REL/releases.json"
}
releases_json 2.5.0 2.4.1 2.4.0 2.3.0

# docker: a pull is recorded; a run runs its command with only the -e
# variables the wrapper passes (a bare -e NAME inherits), plus the container's
# network (the proxy and its CA); its argv is recorded.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/docker" <<EOF
#!/usr/bin/env bash
[[ "\$1" == pull ]] && { printf '%s\n' "\$*" >> "$TMP/docker-pulls"; exit 0; }
[[ "\$1" == run ]] || exit 0
printf '%s\n' "\$*" >> "$TMP/docker-argv"
shift; env=(PATH="/usr/local/bin:/usr/bin:/bin" HTTPS_PROXY="http://127.0.0.1:$PORT" GIT_SSL_CAINFO="$SRV/cert.pem" TACPLUS_SAYS="$TMP/says")
while [[ "\$1" == -* ]]; do
  case "\$1" in
    -e) if [[ "\$2" == *=* ]]; then env+=("\$2"); elif [[ -n "\${!2+x}" ]]; then env+=("\$2=\${!2}"); fi; shift 2 ;;
    -u|-v) shift 2 ;;
    -w) cd "\$2"; shift 2 ;;
    *) shift ;;
  esac
done
shift   # the image
exec env -i "\${env[@]}" "\$@"
EOF
chmod +x "$TMP/bin/docker"

# The compiler's HOME (LOOPER_WORK/.tacplus-home) asks git to store every
# credential: the token must not land there either.
mkdir -p "$TMP/work/.tacplus-home" "$TMP/work/checkout"
git config -f "$TMP/work/.tacplus-home/.gitconfig" credential.helper store
cd "$TMP/work/checkout"

NAME=""
fail() { echo "FAIL $NAME: $*" >&2; cat "$SRV/log" >&2; exit 1; }
pass() { echo "ok $NAME"; }
tacplus() { # env... -- args: the wrapper, as a looper run calls it
  local e=(); while [[ "$1" != -- ]]; do e+=("$1"); shift; done; shift
  env -u GH_TOKEN -u GITHUB_TOKEN PATH="$TMP/bin:$PATH" TMPDIR="$TMP" TACPLUS_MINOR=2.4 \
    TACPLUS_RELEASES_URL="file://$REL/releases.json" TACPLUS_DOWNLOAD_URL="file://$REL/dl" \
    LOOPER_WORK="$TMP/work" LOOPER_LIB="$ROOT/looper-lib.sh" GIT_TERMINAL_PROMPT=0 "${e[@]}" "$ROOT/tacplus" "$@"
}

NAME="a github.com clone gets the token"
: > "$SRV/log"
tacplus GH_TOKEN="$TOKEN" -- clone -q https://github.com/org/repo.git gh 2>"$TMP/err" || { cat "$TMP/err"; fail "clone failed"; }
[[ "$(git -C gh log -1 --format=%s)" == "from github.com" ]] || fail "cloned the wrong repository"
grep -qxF "github.com x-access-token:$TOKEN" "$SRV/log" || fail "github.com did not get the token"
pass

NAME="GITHUB_TOKEN does when GH_TOKEN is unset"
: > "$SRV/log"
tacplus GITHUB_TOKEN="$TOKEN" -- clone -q https://github.com/org/repo.git gh2 2>"$TMP/err" || { cat "$TMP/err"; fail "clone failed"; }
grep -qxF "github.com x-access-token:$TOKEN" "$SRV/log" || fail "github.com did not get the token"
pass

NAME="any other host gets no credential"
: > "$SRV/log"
if tacplus GH_TOKEN="$TOKEN" -- clone -q https://gitlab.example.test/org/repo.git other 2>"$TMP/err"; then fail "clone without a credential succeeded"; fi
grep -q "could not read Username for 'https://gitlab.example.test'" "$TMP/err" || { cat "$TMP/err"; fail "expected git to find no credential"; }
grep -qxF "gitlab.example.test -" "$SRV/log" || fail "gitlab.example.test was never asked"
! grep -qF "$TOKEN" "$SRV/log" || fail "the token reached another host"
pass

NAME="no token, no credential"
: > "$SRV/log"
if tacplus -- clone -q https://github.com/org/repo.git none 2>"$TMP/err"; then fail "clone without a token succeeded"; fi
grep -q "could not read Username for 'https://github.com'" "$TMP/err" || { cat "$TMP/err"; fail "expected git to find no credential"; }
! grep -v '^github.com -$' "$SRV/log" | grep -q . || fail "a credential was sent without a token"
pass

BINS="$TMP/work/.tacplus-home/.cache/tacplus"
NAME="the floor's newest patch, in the build image of its line"
grep -qxF "tacplus 2.4.1" "$TMP/says" || fail "did not run 2.4.1: $(sort -u "$TMP/says")"
! grep -qvxF "tacplus 2.4.1" "$TMP/says" || fail "ran another release: $(sort -u "$TMP/says")"
grep -qF " ghcr.io/tacplus-dev/tacplus/build:2.4 $BINS/2.4.1/tacplus clone " "$TMP/docker-argv" || fail "not run in build:2.4: $(tail -1 "$TMP/docker-argv")"
grep -qxF "pull -q ghcr.io/tacplus-dev/tacplus/build:2.4" "$TMP/docker-pulls" || fail "build:2.4 not pulled"
! grep -qF "tacplus/tacplus:" "$TMP/docker-argv" "$TMP/docker-pulls" || fail "the retired compiler image is used"
[[ "$(wc -l < "$TMP/docker-pulls")" -eq 1 ]] || fail "pulled more than once in ten minutes"
pass

NAME="the newest patch is looked up at most every ten minutes"
releases_json 2.5.0 2.4.5 2.4.1 2.4.0 2.3.0; release 2.4.5
: > "$TMP/says"
tacplus -- --version >/dev/null || fail "run failed"
grep -qxF "tacplus 2.4.1" "$TMP/says" || fail "did not reuse 2.4.1: $(cat "$TMP/says")"
touch -d '-11 minutes' "$TMP/tacplus-newest-2.4"
: > "$TMP/says"
tacplus -- --version >/dev/null || fail "run failed"
grep -qxF "tacplus 2.4.5" "$TMP/says" || fail "did not move to 2.4.5: $(cat "$TMP/says")"
pass

NAME="the pin wins over the floor, in the image of its own line"
mkdir -p "$TMP/work/pinned/sub"
printf 'language: go\ntacplus: "2.4"\n' > "$TMP/work/pinned/tacplus.yaml"
printf 'tacplus: 2.5.0\nbuild_image: ghcr.io/tacplus-dev/tacplus/build:2.5.0@sha256:%064d\n' 0 > "$TMP/work/pinned/tacplus.lock"
: > "$TMP/says"
(cd "$TMP/work/pinned/sub" && tacplus TACPLUS_MINOR= -- --version >/dev/null) || fail "run failed"
grep -qxF "tacplus 2.5.0" "$TMP/says" || fail "did not run the pin: $(cat "$TMP/says")"
tail -1 "$TMP/docker-argv" | grep -qF " ghcr.io/tacplus-dev/tacplus/build:2.5 $BINS/2.5.0/tacplus --version" || fail "not run in build:2.5: $(tail -1 "$TMP/docker-argv")"
pass

NAME="without a pin, the floor of the nearest tacplus.yaml"
rm "$TMP/work/pinned/tacplus.lock"; printf 'tacplus: "2.5"\n' > "$TMP/work/pinned/tacplus.yaml"
(cd "$TMP/work/pinned/sub" && tacplus TACPLUS_MINOR= -- --version >/dev/null) || fail "run failed"
tail -1 "$TMP/docker-argv" | grep -qF " ghcr.io/tacplus-dev/tacplus/build:2.5 $BINS/2.5.0/tacplus --version" || fail "not 2.5.0 in build:2.5: $(tail -1 "$TMP/docker-argv")"
pass

NAME="a checksum mismatch is refused, and nothing is cached or run"
n="$(wc -l < "$TMP/docker-argv")"
rc=0; tacplus TACPLUS_MINOR=2.3 -- --version >/dev/null 2>"$TMP/err" || rc=$?
[[ "$rc" -eq 2 ]] || fail "exit $rc, want 2: $(cat "$TMP/err")"
grep -q "checksum mismatch" "$TMP/err" || fail "no mismatch reported: $(cat "$TMP/err")"
[[ -z "$(ls -A "$BINS/2.3.0")" ]] || fail "cached: $(ls -A "$BINS/2.3.0")"
[[ "$(wc -l < "$TMP/docker-argv")" -eq "$n" ]] || fail "ran it anyway"
pass

NAME="a line with no release is refused"
rc=0; tacplus TACPLUS_MINOR=2.9 -- --version >/dev/null 2>"$TMP/err" || rc=$?
{ [[ "$rc" -eq 2 ]] && grep -q "no release of line 2.9" "$TMP/err"; } || fail "exit $rc: $(cat "$TMP/err")"
pass

NAME="GitHub's releases list gets the token on curl's stdin, no other URL gets it"
cat > "$TMP/bin/curl" <<EOF
#!/usr/bin/env bash
k=""; for a; do [[ "\$a" == -K ]] && k=1; done
[[ -z "\$k" ]] || cat > "$TMP/curl-stdin.\$\$"
for a; do [[ "\$a" == https://api.github.com/* ]] && { cat "$REL/releases.json"; exit 0; }; done
exec "$(command -v curl)" "\$@"
EOF
chmod +x "$TMP/bin/curl"
rm -f "$TMP/tacplus-newest-2.4"
tacplus GH_TOKEN="$TOKEN" TACPLUS_RELEASES_URL=https://api.github.com/repos/tacplus-dev/tacplus/releases -- --version >/dev/null || fail "run failed"
grep -qxF "header = \"Authorization: Bearer $TOKEN\"" "$TMP"/curl-stdin.* || fail "no token on stdin: $(cat "$TMP"/curl-stdin.*)"
rm -f "$TMP"/curl-stdin.* "$TMP/tacplus-newest-2.4"
tacplus GH_TOKEN="$TOKEN" -- --version >/dev/null || fail "run failed"
ls "$TMP"/curl-stdin.* >/dev/null 2>&1 || fail "the file list was not asked"
! grep -qF "$TOKEN" "$TMP"/curl-stdin.* || fail "the token went to another URL"
rm -f "$TMP"/curl-stdin.* "$TMP/bin/curl"
pass

NAME="nothing on disk or on a command line holds the token"
[[ -s "$TMP/docker-argv" ]] || fail "docker run was never called"
! grep -rqF "$TOKEN" "$TMP" || fail "the token is on disk: $(grep -rlF "$TOKEN" "$TMP")"
! grep -qF "$TOKEN" "$ROOT/tacplus" "$ROOT/looper-lib.sh" || fail "the token is in the wrapper"
pass

echo "tacplus: all passed"
