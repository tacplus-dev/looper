#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# looper-verify (looper#74): the formal verification's record, as the build
# pipeline publishes it, filed against a stub gh. A red run files one `bug` a
# failed harness, naming it and its counterexample; a second red run comments
# on it, and opens none; the same run read again files nothing; an open bug
# that already names the harness is commented on; a green, skipped or missing
# record files nothing; a red run with no harness report files one bug with the
# log's tail.
# Run: tests/looper-verify.test.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL $NAME: $*" >&2; exit 1; }
pass() { echo "ok $NAME"; }
has() { grep -qF -- "$2" <<<"$1" || fail "expected \"$2\" in: $1"; }
lacks() { ! grep -qF -- "$2" <<<"$1" || fail "unexpected \"$2\" in: $1"; }

# GitHub: each issue a file $TMP/issues/<n>.json ({number, title, state,
# labels, body, comments: [{body}]}); every call in $TMP/gh.log.
mkdir -p "$TMP/bin" "$TMP/issues"
cat > "$TMP/bin/gh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
echo "gh \$*" >> "$TMP/gh.log"
cmd="\$1 \$2"; shift 2
n=""; q="."; title=""; body=""; labels=()
while ((\$#)); do
  case "\$1" in
    --jq) q="\$2"; shift 2 ;;
    --title) title="\$2"; shift 2 ;;
    --body) body="\$2"; shift 2 ;;
    --label) labels+=("\$2"); shift 2 ;;
    --repo|--state|--limit|--json) shift 2 ;;
    *) n="\$1"; shift ;;
  esac
done
f="$TMP/issues/\$n.json"
case "\$cmd" in
  "issue list")
    jq -s '[.[] | select(.state == "OPEN" and ([.labels[].name] | contains(\$ARGS.positional)))] | sort_by(-.number)' \
      "$TMP/issues/"*.json --args "\${labels[@]+"\${labels[@]}"}" | jq -r "\$q" ;;
  "issue view") jq -r "\$q" "\$f" ;;
  "issue create")
    n="\$(( \$(jq -s 'map(.number) | max // 0' "$TMP/issues/"*.json) + 1 ))"
    jq -n --argjson n "\$n" --arg t "\$title" --arg b "\$body" \
      '{number: \$n, title: \$t, state: "OPEN", labels: (\$ARGS.positional | map({name: .})), body: \$b, comments: []}' \
      --args "\${labels[@]+"\${labels[@]}"}" > "$TMP/issues/\$n.json"
    echo "https://github.com/tacplus-dev/demo/issues/\$n" ;;
  "issue comment") t="\$(jq --arg b "\$body" '.comments += [{body: \$b}]' "\$f")"; printf '%s\n' "\$t" > "\$f" ;;
  *) echo "gh stub: \$cmd" >&2; exit 1 ;;
esac
EOF
chmod +x "$TMP/bin/gh"
issue() { # n title [label...]
  local n="$1" t="$2"; shift 2
  jq -n --argjson n "$n" --arg t "$t" '{number: $n, title: $t, state: "OPEN", labels: ($ARGS.positional | map({name: .})), body: "", comments: []}' \
    --args "$@" > "$TMP/issues/$n.json"
}
issue 1 "An unrelated bug" bug

# The build pipeline's record (looper-build verify), as the scan reads it.
D="$TMP/verify"
record() { # result run [checked]
  mkdir -p "$D"
  printf 'repo demo\nkind nightly\nchecked %s\nverified %s\nresult %s\nrun %s\n' \
    "${3:-1111111111111111111111111111111111111111}" "${3:-1111111111111111111111111111111111111111}" "$1" "$2" > "$D/record"
}
cat > "$TMP/failures.md" <<'EOF'
### com.example.Msg -- verify_port_bounds
**Status:** FAILED
**Detail:**
```
Counterexample: port = 65536
```

### proof::length_overflows
**Status:** FAILED
**Detail:**
```
Counterexample: len = 4294967295
```

EOF
run() {
  : > "$TMP/gh.log"
  OUT="$(env -i PATH="$TMP/bin:$PATH" GH_TOKEN=ghs_stub "$ROOT/looper-verify" file "$D" tacplus-dev/demo 2>&1)" || fail "looper-verify failed: $OUT"
  CALLS="$(cat "$TMP/gh.log")"
}
body() { jq -r '.body' "$TMP/issues/$1.json"; }
comments() { jq -r '.comments[].body' "$TMP/issues/$1.json"; }

NAME="a red run files one bug a failed harness, naming it and its counterexample"
record fail https://gitlab.com/tacplus-dev/build/-/pipelines/501
cp "$TMP/failures.md" "$D/failures.md"
run
[[ "$(grep -c "issue create" <<<"$CALLS")" == 2 ]] || fail "not two bugs: $CALLS"
has "$(jq -r .title "$TMP/issues/2.json")" "verify_port_bounds"
has "$(jq -c .labels "$TMP/issues/2.json")" '"bug"'
has "$(body 2)" "Counterexample: port = 65536"
has "$(body 2)" "https://gitlab.com/tacplus-dev/build/-/pipelines/501"
has "$(body 2)" "1111111"
lacks "$(body 2)" "len = 4294967295"
has "$(jq -r .title "$TMP/issues/3.json")" "proof::length_overflows"
has "$(body 3)" "Counterexample: len = 4294967295"
[[ "$(jq -s length <<<"$(cat "$TMP/issues/"*.json)")" == 3 ]] || fail "$(ls "$TMP/issues")"
pass

NAME="the same run read again files nothing, nor does a nightly that skipped (its record the last run's)"
run
lacks "$CALLS" "issue create"
lacks "$CALLS" "issue comment"
printf 'checked 3333333333333333333333333333333333333333\nskipped unchanged since 1111111111111111111111111111111111111111\n' >> "$D/record"
run
[[ -z "$CALLS" || "$CALLS" != *"issue c"* ]] || fail "$CALLS"
pass

NAME="a second red run comments on the open bug of each harness, and opens none"
record fail https://gitlab.com/tacplus-dev/build/-/pipelines/502 2222222222222222222222222222222222222222
run
lacks "$CALLS" "issue create"
[[ "$(comments 2 | grep -c '^Run: .*pipelines/502')" == 1 ]] || fail "#2's comments: $(comments 2)"
has "$(comments 2)" "Counterexample: port = 65536"
has "$(comments 2)" "2222222"
[[ "$(comments 3 | grep -c '^Run: .*pipelines/502')" == 1 ]] || fail "#3's comments: $(comments 3)"
lacks "$(comments 2)" "len = 4294967295"
run
lacks "$CALLS" "issue comment"
pass

NAME="an open bug that already names the harness is commented on; a closed one, or one not a bug, is not"
rm -f "$TMP/issues/2.json" "$TMP/issues/3.json"
issue 7 "Kani: proof::length_overflows fails since the u32 change" bug
issue 8 "verify_port_bounds is slow" feature
issue 9 "verify_port_bounds fails" bug
jq '.state = "CLOSED"' "$TMP/issues/9.json" > "$TMP/x" && mv "$TMP/x" "$TMP/issues/9.json"
record fail https://gitlab.com/tacplus-dev/build/-/pipelines/503
run
has "$(comments 7)" "pipelines/503"
[[ "$(grep -c "issue create" <<<"$CALLS")" == 1 ]] || fail "not one new bug: $CALLS"
has "$(jq -r .title "$TMP/issues/10.json")" "verify_port_bounds"
[[ "$(jq '.comments | length' "$TMP/issues/8.json")" == 0 && "$(jq '.comments | length' "$TMP/issues/9.json")" == 0 ]] ||
  fail "commented on a feature or a closed bug"
pass

NAME="a green, skipped or missing record files nothing"
record pass https://gitlab.com/tacplus-dev/build/-/pipelines/504
run
[[ -z "$CALLS" ]] || fail "pass: $CALLS"
record none https://gitlab.com/tacplus-dev/build/-/pipelines/505
run
[[ -z "$CALLS" ]] || fail "none: $CALLS"
rm -f "$D/record"
run
[[ -z "$CALLS" ]] || fail "no record: $CALLS"
has "$OUT" "no record"
printf 'garbage\n' > "$D/record"
run
[[ -z "$CALLS" ]] || fail "unreadable record: $CALLS"
pass

NAME="a red run with no harness report files one bug with the log's tail, once"
rm -f "$D/failures.md"
record fail https://gitlab.com/tacplus-dev/build/-/pipelines/506
printf 'verify: building tacplus failed\n=== verify OVERALL fail=1 ===\n' > "$D/log-tail"
run
[[ "$(grep -c "issue create" <<<"$CALLS")" == 1 ]] || fail "$CALLS"
n="$(jq -s 'map(.number) | max' "$TMP/issues/"*.json)"
has "$(jq -r .title "$TMP/issues/$n.json")" "just verify"
has "$(body "$n")" "verify: building tacplus failed"
record fail https://gitlab.com/tacplus-dev/build/-/pipelines/507
run
lacks "$CALLS" "issue create"
has "$(comments "$n")" "pipelines/507"
pass

echo "looper-verify: all passed"
