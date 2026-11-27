#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# looper-gatemiss (looper#253): a red full check of main, its record as the
# nightly publishes it, the manager's verdicts on the lands since the last green
# as a stub gh serves them, and a clone of main. A red after a land on a partial
# set files one miss naming the land, its sets and why, and the failing gate,
# and tells the land's issue; read again it files nothing; a land on full files
# none; a flake (red once, green when run again) files none; several lands and
# no bisect file none, a bisect's culprit files its own; a verdict by another
# login than the manager's is no land.
# Run: tests/looper-gatemiss.test.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL $NAME: $*" >&2; exit 1; }
pass() { echo "ok $NAME"; }
has() { grep -qF -- "$2" <<<"$1" || fail "expected \"$2\" in: $1"; }
lacks() { ! grep -qF -- "$2" <<<"$1" || fail "unexpected \"$2\" in: $1"; }

# GitHub: each issue a file $TMP/issues/<n>.json ({number, title, state,
# labels, body, comments: [{body}]}); the repository's comments the manager
# wrote, $TMP/verdicts.json ([{issue_url, user: {login}, body}]); every call in
# $TMP/gh.log.
mkdir -p "$TMP/bin" "$TMP/issues"
cat > "$TMP/bin/gh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
echo "gh \$*" >> "$TMP/gh.log"
if [[ "\$1" == api ]]; then
  shift; q="."; path=""
  while ((\$#)); do case "\$1" in --jq) q="\$2"; shift 2 ;; --paginate) shift ;; *) path="\$1"; shift ;; esac; done
  [[ "\$path" == "repos/tacplus-dev/demo/issues/comments?since="*"&per_page=100" ]] || { echo "gh stub: api \$path" >&2; exit 1; }
  jq -r "\$q" "$TMP/verdicts.json"; exit
fi
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
    jq -s '[.[] | select([.labels[].name] | contains(\$ARGS.positional))] | sort_by(-.number)' \
      "$TMP/issues/"*.json --args "\${labels[@]+"\${labels[@]}"}" | jq -r "\$q" ;;
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
for i in 1 2 3 4 5 6 7 8 9 10; do issue "$i" "The issue of land $i" feature; done

# main: green, then the lands; each a commit (HISTORY.md, the looper's own record, between).
C="$TMP/clone"; git init -q -b main "$C"
g() { git -C "$C" -c user.name=t -c user.email=t@t "$@"; }
cat > "$C/gates.yaml" <<'EOF'
full:
  run: tests/a.test.sh && tests/vm.test.sh && tests/b.test.sh
  paths: [/core]
vm:
  run: tests/vm.test.sh
  paths: [/looper-vm, tests/vm.test.sh]
docs:
  run: ./planning-files-check
  paths: ["*.md"]
EOF
commit() { # file
  mkdir -p "$C/$(dirname "$1")"; echo "$RANDOM" >> "$C/$1"; g add -A; g commit -q -m "$1"; g rev-parse HEAD
}
GREEN="$(commit core)"
VERDICTS=()
land() { # issue set|"" file...: one land of its files, its verdict the manager's (or LOGIN's)
  local n="$1" set="$2" before after f; shift 2
  before="$(g rev-parse HEAD)"; for f in "$@"; do commit "$f" >/dev/null; done; after="$(g rev-parse HEAD)"
  VERDICTS+=("$(jq -n --arg n "$n" --arg l "${LOGIN:-tacplus-manager[bot]}" --arg b "The manager merged [\`looper/demo-$n\`](https://example) on main: ${before:0:7}..${after:0:7}, on the gates ${set:-full} (${WHY:-its one changed path, $1, maps to ${set:-full}}), a build job's verdict (https://gitlab.example/p/1): green. The branch is deleted.

<!-- looper-land id=20261126T000000Z-$n-1 rc=0 landed=$before..$after${set:+ set=$set} -->" \
    '{issue_url: ("https://api.github.com/repos/tacplus-dev/demo/issues/" + $n), user: {login: $l}, body: $b}')")
  printf '%s\n' "${VERDICTS[@]}" | jq -s . > "$TMP/verdicts.json"
}
D="$TMP/record"; mkdir -p "$D"
record() { # result reds [culprit]
  { printf 'repo demo\nkind nightly\nchecked %s\nresult %s\nwhy just gates exited 1: FAIL vm: the VM did not start\n' "$(g rev-parse HEAD)" "$1"
    printf 'green %s\nreds %s\nrun https://gitlab.example/tacplus-dev/build/-/pipelines/7\n' "$GREEN" "$2"
    [[ -z "${3:-}" ]] || printf 'culprit %s\n' "$3"; } > "$D/record"
  printf 'ok a\nFAIL vm: the VM did not start\n' > "$D/log-tail"
}
run() {
  : > "$TMP/gh.log"
  OUT="$(env -i PATH="$TMP/bin:$PATH" HOME="$TMP" GH_TOKEN=ghs_stub "$ROOT/looper-gatemiss" file "$D" tacplus-dev/demo "$C" 2>&1)" || fail "looper-gatemiss failed: $OUT"
  CALLS="$(cat "$TMP/gh.log")"
}
misses() { jq -s '[.[] | select(.title | startswith("gate map miss"))] | length' "$TMP/issues/"*.json; }

NAME="a red full check after a land on a partial set, red again, files one miss: the land, its paths, its sets and why, the failing gate"
land 1 vm looper-vm
commit HISTORY.md >/dev/null
record fail 2
run
[[ "$(misses)" == 1 ]] || fail "not one miss: $OUT"
T="$(jq -r .title "$TMP/issues/11.json")"; B="$(jq -r .body "$TMP/issues/11.json")"
[[ "$T" == "gate map miss: looper-vm ran vm, full broke" ]] || fail "title: $T"
has "$(jq -c .labels "$TMP/issues/11.json")" '"bug"'
has "$B" "#1, $(git -C "$C" rev-parse HEAD~2)..$(git -C "$C" rev-parse HEAD~1)"
has "$B" '- `looper-vm`'
has "$B" '`vm` (its one changed path, looper-vm, maps to vm)'
has "$B" '- `vm`: `tests/vm.test.sh`'
has "$B" '- `full`: `tests/a.test.sh && tests/vm.test.sh && tests/b.test.sh`'
has "$B" "FAIL vm: the VM did not start"
has "$B" "https://gitlab.example/tacplus-dev/build/-/pipelines/7"
has "$B" "the only land since the last green full check, ${GREEN:0:7}"
has "$(jq -r '.comments[].body' "$TMP/issues/1.json")" "filed as #11"
pass

NAME="the same red read again files nothing"
run
lacks "$CALLS" "issue create"
lacks "$CALLS" "issue comment"
pass

NAME="the repository's own account of the sets' legs (gate-audit) is quoted"
rm "$TMP/issues/11.json"
printf 'sets: vm (looper-vm)\n  vm: tests/vm.test.sh 2m\n' > "$D/audit"
run
has "$(jq -r .body "$TMP/issues/11.json")" "  vm: tests/vm.test.sh 2m"
rm "$TMP/issues/11.json" "$D/audit"; issue 1 "The issue of land 1" feature
pass

NAME="a flake (red once, green when run again) files none"
record fail 1
run
has "$OUT" "a flake until it is red again"
lacks "$CALLS" "issue create"
record pass 0
run
lacks "$CALLS" "issue create"
[[ -z "$CALLS" ]] || fail "a green check read GitHub: $CALLS"
pass

NAME="a red after a land on full files none"
VERDICTS=(); GREEN="$(g rev-parse HEAD)"
land 2 "" core
record fail 2
run
has "$OUT" "ran full: no miss of the map"
lacks "$CALLS" "issue create"
pass

NAME="several lands on partial sets and no bisect file none; a bisect's culprit files its own miss"
VERDICTS=(); GREEN="$(g rev-parse HEAD)"
land 3 vm looper-vm
WHY="all 2 changed paths map to docs" land 4 docs README.md NOTES.md
record fail 2
run
has "$OUT" "no single culprit"
has "$OUT" "a possible miss: #3"
has "$OUT" "a possible miss: #4"
lacks "$CALLS" "issue create"
record fail 2 "$(g rev-parse HEAD)"
run
[[ "$(misses)" == 1 ]] || fail "not one miss: $OUT"
T="$(jq -r .title "$TMP/issues/11.json")"; B="$(jq -r .body "$TMP/issues/11.json")"
[[ "$T" == "gate map miss: NOTES.md, README.md ran docs, full broke" ]] || fail "title: $T"
has "$B" "the culprit by bisect"
has "$B" '`docs` (all 2 changed paths map to docs)'
has "$(jq -r '.comments[].body' "$TMP/issues/4.json")" "filed as #11"
rm "$TMP/issues/11.json"
pass

NAME="a verdict by another login than the manager's is no land"
VERDICTS=(); GREEN="$(g rev-parse HEAD)"
LOGIN=someone land 5 vm looper-vm
record fail 2
run
has "$OUT" "no single culprit"
lacks "$CALLS" "issue create"
pass

NAME="a red with no green full check to count from files none"
record fail 2
sed -i '/^green /d' "$D/record"
run
has "$OUT" "no green full check"
lacks "$CALLS" "issue create"
pass
