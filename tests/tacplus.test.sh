#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# The tacplus wrapper's GitHub credentials (looper#11): a clone of
# https://github.com in the compiler container gets $GH_TOKEN, a clone from any
# other host gets no credential, and the token is on no disk and no command
# line. A stub `docker run` runs the "image" (its tacplus is git) with only the
# environment the wrapper hands it; tests/git-server.py is the network, an
# HTTPS proxy that serves every host itself and logs the credentials it gets.
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

# The image: its tacplus is git. `docker run` runs it with only the -e
# variables the wrapper passes (a bare -e NAME inherits), plus the container's
# network (the proxy and its CA); its argv is recorded.
mkdir -p "$TMP/bin" "$TMP/image"
printf '#!/usr/bin/env bash\nexec git "$@"\n' > "$TMP/image/tacplus"
cat > "$TMP/bin/docker" <<EOF
#!/usr/bin/env bash
[[ "\$1" == run ]] || exit 0
printf '%s\n' "\$*" >> "$TMP/docker-argv"
shift; env=(PATH="$TMP/image:/usr/local/bin:/usr/bin:/bin" HTTPS_PROXY="http://127.0.0.1:$PORT" GIT_SSL_CAINFO="$SRV/cert.pem")
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
chmod +x "$TMP/bin/docker" "$TMP/image/tacplus"

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
  env -u GH_TOKEN -u GITHUB_TOKEN "${e[@]}" PATH="$TMP/bin:$PATH" TMPDIR="$TMP" TACPLUS_MINOR=2.4 \
    LOOPER_WORK="$TMP/work" LOOPER_LIB="$ROOT/looper-lib.sh" GIT_TERMINAL_PROMPT=0 "$ROOT/tacplus" "$@"
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

NAME="nothing on disk or on a command line holds the token"
[[ -s "$TMP/docker-argv" ]] || fail "docker run was never called"
! grep -rqF "$TOKEN" "$TMP" || fail "the token is on disk: $(grep -rlF "$TOKEN" "$TMP")"
! grep -qF "$TOKEN" "$ROOT/tacplus" "$ROOT/looper-lib.sh" || fail "the token is in the wrapper"
pass

echo "tacplus: all passed"
