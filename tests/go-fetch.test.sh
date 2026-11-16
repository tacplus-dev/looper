#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# go-fetch (looper#169), against a stub go that fails its first tries: it runs
# go with its arguments over HTTP/1.1 (GODEBUG http2client=0, beside the
# step's own), retries a failed try up to LOOPER_GO_FETCH_TRIES, exits as the
# last one, and refuses a count that is not one. And the Dockerfile fetches
# every Go step's modules through it: each go install's module by
# `go-fetch install -n`, each module made here by `go-fetch mod tidy`, each
# step's toolchain by `go-fetch version`, before it builds; each go install
# from the module cache so filled (GOPROXY=file://), offline.
# Run: tests/go-fetch.test.sh
source "$(dirname "${BASH_SOURCE[0]}")/hermetic.sh"
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL $NAME: $*" >&2; exit 1; }
pass() { echo "ok $NAME"; }
has() { grep -qF -- "$2" <<<"$1" || fail "expected \"$2\" in: $1"; }

# go: fails while $TMP/fails holds a count above 0 (exit 1, a stream error), each
# call's arguments and GODEBUG in $TMP/go.log; it prints a line on each try.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/go" <<EOF
#!/usr/bin/env bash
echo "go \$* GODEBUG=\${GODEBUG:-}" >> "$TMP/go.log"
echo "WORK=/tmp/go-build"
n="\$(cat "$TMP/fails")"
(( n > 0 )) || exit 0
echo \$((n - 1)) > "$TMP/fails"
echo "stream error: stream ID 297; INTERNAL_ERROR; received from peer" >&2; exit 1
EOF
chmod +x "$TMP/bin/go"
export PATH="$TMP/bin:$PATH" LOOPER_GO_FETCH_SLEEP=0
run() { rm -f "$TMP/go.log"; echo "$1" > "$TMP/fails"; shift; rc=0; out="$("$ROOT/go-fetch" "$@" 2>&1)" || rc=$?; }
calls() { if [[ -f "$TMP/go.log" ]]; then wc -l < "$TMP/go.log" | tr -d ' '; else echo 0; fi; }

NAME="a fetch that succeeds runs go once, over HTTP/1.1, quietly"
run 0 mod tidy
[[ $rc == 0 && "$(calls)" == 1 && -z "$out" ]] || fail "exit $rc, $(calls) calls: $out"
has "$(cat "$TMP/go.log")" "go mod tidy GODEBUG=http2client=0"
pass

NAME="the step's own GODEBUG is kept"
GODEBUG=netdns=go run 0 version
has "$(cat "$TMP/go.log")" "go version GODEBUG=netdns=go,http2client=0"
pass

NAME="a stream error is retried until the fetch succeeds"
run 2 install -n "golang.org/x/vuln/cmd/govulncheck@v1.9.0"
[[ $rc == 0 && "$(calls)" == 3 ]] || fail "exit $rc, $(calls) calls: $out"
has "$out" "go-fetch: go install -n golang.org/x/vuln/cmd/govulncheck@v1.9.0: try 1 of 5 exited 1; again in 0s:
WORK=/tmp/go-build
stream error: stream ID 297"
has "$out" "try 2 of 5 exited 1"
[[ "$(grep -c WORK= <<<"$out")" == 2 ]] || fail "the successful try's output shown: $out"
pass

NAME="the retry is bounded: the last try's exit, said"
LOOPER_GO_FETCH_TRIES=3 run 9 mod tidy
[[ $rc == 1 && "$(calls)" == 3 ]] || fail "exit $rc, $(calls) calls: $out"
has "$out" "go-fetch: go mod tidy: failed 3 times, the last with exit 1:
WORK=/tmp/go-build
stream error"
pass

NAME="a count that is not one is refused, go not run"
LOOPER_GO_FETCH_TRIES=0 run 0 mod tidy
[[ $rc == 2 && "$(calls)" == 0 ]] || fail "exit $rc, $(calls) calls: $out"
has "$out" "LOOPER_GO_FETCH_TRIES is not a count: 0"
run 0
[[ $rc == 2 && "$(calls)" == 0 ]] || fail "no arguments: exit $rc, $(calls) calls: $out"
pass

# The Dockerfile's RUN instructions, one line each.
runs="$(sed -e ':a' -e '/\\$/{N;s/\\\n//;ba' -e '}' "$ROOT/Dockerfile" | grep '^RUN ')"
NAME="the Dockerfile copies go-fetch before its first Go step"
c="$(grep -n '^COPY go-fetch /usr/local/lib/looper/' "$ROOT/Dockerfile" | head -n1 | cut -d: -f1)"
g="$(grep -n 'GOTOOLCHAIN=' "$ROOT/Dockerfile" | head -n1 | cut -d: -f1)"
[[ -n "$c" && -n "$g" && "$c" -lt "$g" ]] || fail "COPY go-fetch at ${c:-none}, the first Go step at ${g:-none}"
pass

NAME="each Go step fetches through go-fetch before it builds"
steps=0
while IFS= read -r r; do
  [[ "$r" == *GOTOOLCHAIN=* ]] || continue; steps=$((steps + 1))
  [[ "$r" == *"go-fetch version"* ]] || fail "no toolchain fetch: $r"
  # Every go install's module, fetched by go-fetch install -n before the first.
  for m in $(grep -oE 'go install [^;]*"[^" ]+@v\$[A-Z_]+"' <<<"$r" | grep -oE '"[^" ]+@v\$[A-Z_]+"' | sort -u); do
    [[ "${r%%go install*}" == *"go-fetch install -n $m"* ]] || fail "$m installed without go-fetch install -n first"
  done
  # And installed offline, from the module cache the fetches filled.
  i="$(grep -oE '(^|; *)[^;]*go install ' <<<"$r" || true)"
  [[ -z "$i" || "$(grep -c . <<<"$i")" == "$(grep -cE 'GOPROXY="(file://\$\(go env GOMODCACHE\)/cache/download|\$fetched)" ' <<<"$i")" ]] ||
    fail "a go install not from the module cache: $i"
  [[ "$r" != *'$fetched'* || "$r" == *'fetched="file://$(go env GOMODCACHE)/cache/download"'* ]] || fail "\$fetched is not the cache: $r"
  # Every module made here, tidied by go-fetch.
  if [[ "$r" == *"go mod init"* ]]; then
    [[ "$r" != *"; go mod tidy"* ]] || fail "a go mod tidy not through go-fetch: $r"
    [[ "$r" == *"go-fetch mod tidy"* ]] || fail "no go-fetch mod tidy: $r"
  fi
done <<<"$runs"
(( steps >= 3 )) || fail "only $steps Go steps read"
pass
