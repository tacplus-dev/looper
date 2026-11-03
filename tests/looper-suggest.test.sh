#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# looper-suggest (looper#50) against a scratch roadmap repository with the
# real suggestions/TYPES.md and INDEX.md: the format, the types, evidence, a
# rejected or deferred suggestion not raised again without new evidence, the
# index's order (Security first), what check refuses, a decision recorded, and
# another job's suggestion committed and pushed alone (stub gh, a local origin).
# Run: tests/looper-suggest.test.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

# gh: `repo clone` clones $FIX/origin.git; nothing else is expected.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "auth setup-git") exit 0 ;;
  "repo clone") echo "$3" >> "$FIX/cloned"; git clone -q "$FIX/origin.git" "$4" ;;
  *) echo "stub gh: unexpected $*" >&2; exit 3 ;;
esac
EOF
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH" LOOPER_LIB="$ROOT/looper-lib.sh"

fail() { echo "FAIL $NAME: $*" >&2; exit 1; }
pass() { echo "ok $NAME"; }
has() { grep -qF -- "$2" <<<"$1" || fail "expected \"$2\" in: $1"; }
lacks() { ! grep -qF -- "$2" <<<"$1" || fail "unexpected \"$2\" in: $1"; }
suggest() { OUT="$("$ROOT/looper-suggest" "$@" 2>&1)"; }
passes() { suggest "$@" || fail "expected looper-suggest $1 to pass: $OUT"; }
refused() { if suggest "$@"; then fail "expected looper-suggest $1 to be refused: $OUT"; fi; }

# A roadmap repository: tacplus-dev/roadmap's suggestions/TYPES.md and INDEX.md as of 2026-11-01.
scenario() { # name
  NAME="$1"; FIX="$TMP/$1"; R="$FIX/roadmap"; export FIX
  mkdir -p "$R/suggestions"; git init -q -b main "$R"
  echo "# Roadmap" > "$R/ROADMAP.md"
  cat > "$R/suggestions/TYPES.md" <<'T'
# Suggestion types

Every suggestion in `suggestions/` names exactly one **Type** from this list. The list is the source of truth: the nightly
suggestion pass (tacplus-dev/looper#50) reads it and may use no other type.

| Type | Covers | Example |
|---|---|---|
| **Resiliency** | surviving failure: faults, restarts, region or node loss, recovery time, degradation | a chaos agent like Chaos Monkey |
| **Security** | vulnerabilities, identity and access, secrets, supply chain, tenant isolation | deterministic SCA and SAST on every build |
| **Correctness** | the platform doing what its contracts and docs promise; data integrity; tests that prove it | servers end streams at token expiry, as API.md claims |
| **Performance** | latency, throughput, build and gate time, resource use per request | gates scaled to what a change touches |
| **Cost** | spend on cloud, runners, models and storage, and what drives it | right-size runner VMs; scale build pools to zero |
| **Operability** | running and changing the platform: deploys, config, observability, runbooks, automation | the uni-config as the single deployment definition |
| **Developer experience** | what building on tacplus is like: generated APIs, tooling, error messages, docs for users | clearer generation errors that name the proto line |
| **Documentation** | docs that are missing, wrong or out of date relative to the code and decisions | README describing a retired Mac kicker |

Pick the type for the suggestion's **main** benefit. When it serves several, name the others in its *Why*.
T
  cat > "$R/suggestions/INDEX.md" <<'T'
# Suggestions

Written nightly by the roadmap scan (tacplus-dev/looper#50), reviewed by Jody. Accepted ones go to a ROADMAP.md (by an agent at
Jody's request). Rejected ones stay here with the reasoning, and aren't raised again without new evidence. Types: [TYPES.md](TYPES.md).

## Open
| Suggestion | Type | Summary | Status |
|---|---|---|---|

## Accepted

## Deferred

## Rejected
T
  git -C "$R" add -A && git -C "$R" commit -q -m base
}
commit() { git -C "$R" add -A && git -C "$R" commit -q -m "$1"; }
# looper-suggest file in the roadmap checkout: NAME TYPE [more options...]
chaos=(--suggestion Chaos --type Resiliency --summary "Implement a chaos agent like Chaos Monkey"
       --why "Nothing tests that the platform survives a node's loss." --cost "a week" --touches "decisions/fleets-and-canary-huddle-2026-10-22.md"
       --reuse "tacplus-dev/chaos#1's Chaos Mesh watch; Chaos Mesh itself" --date 2026-11-01)
file_it() { suggest file --dir "$R" "$@"; }

scenario format
passes file --dir "$R" "${chaos[@]}" --evidence "https://github.com/tacplus-dev/looper/issues/42 (a VM lost mid-job)" --rank 2 --by "the roadmap scan"
[[ "$OUT" == suggestions/2026-11-01-chaos.md ]] || fail "printed $OUT"
f="$R/suggestions/2026-11-01-chaos.md"
[[ "$(head -n 4 "$f")" == "Suggestion: Chaos
Type: Resiliency
Summary: Implement a chaos agent like Chaos Monkey
Why: Nothing tests that the platform survives a node's loss." ]] || fail "the four fields: $(head -n 4 "$f")"
for s in "## Evidence" "## Cost" "## Touches" "## Reuse considered" "## Status"; do has "$(cat "$f")" "$s"; done
has "$(cat "$f")" "open
Rank: 2
Filed: 2026-11-01 by the roadmap scan"
has "$(cat "$R/suggestions/INDEX.md")" "| [Chaos](2026-11-01-chaos.md) | Resiliency | Implement a chaos agent like Chaos Monkey | open (rank 2, 2026-11-01) |"
has "$(cat "$R/suggestions/INDEX.md")" "Rejected ones stay here with the reasoning"
passes check "$R" HEAD
passes check "$R"
pass

scenario type-from-types-md
refused file --dir "$R" "${chaos[@]}" --type Reliability --evidence "https://example.test/1"
has "$OUT" "its type \`Reliability\` is not one of suggestions/TYPES.md's (Resiliency, Security, Correctness"
[[ ! -e "$R/suggestions/2026-11-01-chaos.md" ]] || fail "the refused suggestion was written"
[[ -z "$(git -C "$R" status --porcelain)" ]] || fail "the refused suggestion changed the checkout: $(git -C "$R" status --porcelain)"
pass

scenario evidence-required
refused file --dir "$R" "${chaos[@]}"
has "$OUT" "--evidence is required"
refused file --dir "$R" "${chaos[@]}" --evidence "I think so"
has "$OUT" "Evidence has no item with a link"
pass

# A rejected suggestion is not raised again without new evidence; it may be,
# citing the rejection and saying what changed, with evidence it lacked.
scenario rejected-not-raised-again
file_it "${chaos[@]}" --evidence "https://github.com/tacplus-dev/looper/issues/42" || fail "$OUT"
passes decide "$R" 2026-11-01-chaos.md rejected --reason "not before the fleets run" --date 2026-11-02
f="$R/suggestions/2026-11-01-chaos.md"
has "$(cat "$f")" "rejected
Rank: 1
Filed: 2026-11-01 by looper-suggest
Decided: 2026-11-02 by Jody: not before the fleets run"
has "$(cat "$R/suggestions/INDEX.md")" "## Rejected
| Suggestion | Type | Summary | Status |
|---|---|---|---|
| [Chaos](2026-11-01-chaos.md) | Resiliency | Implement a chaos agent like Chaos Monkey | rejected (2026-11-02) |"
commit rejected
again=("${chaos[@]/2026-11-01/2026-11-05}")
refused file --dir "$R" "${again[@]}" --evidence "https://github.com/tacplus-dev/looper/issues/42"
has "$OUT" "it raises again 2026-11-01-chaos.md (rejected 2026-11-02) without citing it"
refused file --dir "$R" "${again[@]}" --slug chaos-agent --suggestion "CHAOS" --evidence "https://github.com/tacplus-dev/looper/issues/42"
has "$OUT" "raises again 2026-11-01-chaos.md"
refused file --dir "$R" "${again[@]}" --evidence "https://github.com/tacplus-dev/looper/issues/42" \
  --earlier 2026-11-01-chaos.md --what-changed "the fleets run now"
has "$OUT" "with no new evidence"
[[ -z "$(git -C "$R" status --porcelain)" ]] || fail "a refused suggestion changed the checkout"
passes file --dir "$R" "${again[@]}" --evidence "https://github.com/tacplus-dev/looper/issues/42" \
  --evidence "https://github.com/tacplus-dev/kernel/issues/300 (a node lost on 11-04, 40 minutes down)" \
  --earlier 2026-11-01-chaos.md --what-changed "the fleets run now, and a node's loss took kernel down for 40 minutes"
has "$(cat "$R/suggestions/2026-11-05-chaos.md")" "## Raised again
Earlier: 2026-11-01-chaos.md
What changed: the fleets run now"
passes check "$R" HEAD
# check refuses the same, written by hand (the model's way round the command).
git -C "$R" checkout -q -- . && git -C "$R" clean -fdq
sed '/^## Status/,$d' "$f" > "$R/suggestions/2026-11-05-chaos.md"
printf '## Status\nopen\nRank: 1\nFiled: 2026-11-05 by hand\n' >> "$R/suggestions/2026-11-05-chaos.md"
passes index "$R"
refused check "$R" HEAD
has "$OUT" "suggestions/2026-11-05-chaos.md: it raises again 2026-11-01-chaos.md (rejected 2026-11-02) without citing it"
pass

scenario deferred-not-raised-again
file_it "${chaos[@]}" --evidence "https://github.com/tacplus-dev/looper/issues/42" || fail "$OUT"
passes decide "$R" suggestions/2026-11-01-chaos.md deferred --reason "after skipper" --date 2026-11-02
has "$(cat "$R/suggestions/INDEX.md")" "| [Chaos](2026-11-01-chaos.md) | Resiliency | Implement a chaos agent like Chaos Monkey | deferred (2026-11-02) |"
commit deferred
refused file --dir "$R" "${chaos[@]/2026-11-01/2026-11-03}" --evidence "https://github.com/tacplus-dev/looper/issues/42"
has "$OUT" "raises again 2026-11-01-chaos.md (deferred 2026-11-02)"
pass

scenario open-not-duplicated
file_it "${chaos[@]}" --evidence "https://github.com/tacplus-dev/looper/issues/42" || fail "$OUT"; commit open
refused file --dir "$R" "${chaos[@]/2026-11-01/2026-11-02}" --evidence "https://github.com/tacplus-dev/looper/issues/43"
has "$OUT" "it is already suggested: 2026-11-01-chaos.md (open)"
pass

# Security first, then TYPES.md's order, then rank.
scenario index-order
ev=(--evidence "https://github.com/tacplus-dev/looper/issues/1" --cost x --touches y --reuse z --why w --date 2026-11-01)
file_it --suggestion "Docs gap" --type Documentation --summary d --rank 1 "${ev[@]}" || fail "$OUT"
file_it --suggestion "Chaos B" --type Resiliency --summary r2 --rank 3 "${ev[@]}" || fail "$OUT"
file_it --suggestion "Pin rules" --type Security --summary s --rank 5 "${ev[@]}" || fail "$OUT"
file_it --suggestion "Chaos A" --type Resiliency --summary r1 --rank 2 "${ev[@]}" || fail "$OUT"
file_it --suggestion "Old secret" --type Security --summary s0 --rank 4 "${ev[@]}" || fail "$OUT"
order="$(sed -n '/^## Open/,/^## Accepted/p' "$R/suggestions/INDEX.md" | grep -oE '^\| \[[^]]+\]' | tr -d '|[]' | sed 's/^ //' | paste -sd, -)"
[[ "$order" == "Old secret,Pin rules,Chaos A,Chaos B,Docs gap" ]] || fail "open order: $order"
passes check "$R" HEAD
pass

scenario check-limits
ev=(--evidence "https://github.com/tacplus-dev/looper/issues/1" --cost x --touches y --reuse z --why w --type Cost --date 2026-11-01)
for i in 1 2 3 4 5 6; do file_it --suggestion "S$i" --summary "s$i" "${ev[@]}" || fail "$OUT"; done
refused check "$R" HEAD
has "$OUT" "6 new suggestions: at most 5 at a time"
rm "$R/suggestions/2026-11-01-s6.md"; passes index "$R"; passes check "$R" HEAD
echo x >> "$R/ROADMAP.md"; refused check "$R" HEAD; has "$OUT" "ROADMAP.md: the change may touch suggestions/ only"
git -C "$R" checkout -q -- ROADMAP.md
echo x >> "$R/suggestions/TYPES.md"; refused check "$R" HEAD; has "$OUT" "suggestions/TYPES.md: a filed suggestion or suggestions's own file is changed"
git -C "$R" checkout -q -- suggestions/TYPES.md; passes check "$R" HEAD
commit five
sed -i 's/^Summary: s1$/Summary: other/' "$R/suggestions/2026-11-01-s1.md"; passes index "$R"
refused check "$R" HEAD; has "$OUT" "suggestions/2026-11-01-s1.md: a filed suggestion"
git -C "$R" checkout -q -- .
echo "stale" >> "$R/suggestions/INDEX.md"; refused check "$R" HEAD; has "$OUT" "INDEX.md is not current"
git -C "$R" checkout -q -- .
printf 'Suggestion: x\nType: Cost\n' > "$R/suggestions/2026-11-02-x.md"; passes index "$R"
refused check "$R" HEAD; has "$OUT" "line 3 is not \`Summary: <text>\`"; has "$OUT" "it has no \`## Cost\`"; has "$OUT" "Status is not one of"
pass

# Advice from the nightly recap (looper#57): a Performance, Operability or
# Cost suggestion with its cause, change and gain, and numbers in its
# evidence: no advice without numbers. check refuses the same written by hand,
# and lets the night's recap files (suggestions/recap/<date>.md and .json) in.
scenario advice-needs-numbers
adv=(--suggestion "Fresh VM image" --type Operability --summary "Apply the baked runner image" --why "fresh VMs fail their first job"
     --cost "an hour of the hub's" --touches "looper#43" --reuse "runner-image build exists" --date 2026-11-02
     --recap "2026-11-02 failures/tacplus-dev/looper/image_pull" --cause "Docker installed at boot under the first job"
     --change "the hub applies README's A fresh VM is ready (tacplus-dev/looper#43)" --gain "6 failed jobs and 6 retries a night")
refused file --dir "$R" "${adv[@]}" --evidence "suggestions/recap/2026-11-02.md (tacplus-dev/looper#43, 2026-11-02)"
has "$OUT" "no numeric evidence"
refused file --dir "$R" "${adv[@]}" --type Documentation --evidence "6 image-pull failures (suggestions/recap/2026-11-02.md)"
has "$OUT" "its type is Performance, Operability or Cost, not Documentation"
refused file --dir "$R" "${adv[@]/--gain/--why}" --evidence "6 image-pull failures (suggestions/recap/2026-11-02.md)"
has "$OUT" "--recap needs --cause, --change and --gain"
[[ -z "$(git -C "$R" status --porcelain)" ]] || fail "a refused advice changed the checkout"
passes file --dir "$R" "${adv[@]}" --evidence "6 image-pull failures before a VM was ready, on 2 of 7 nights (suggestions/recap/2026-11-02.md)"
has "$(cat "$R/suggestions/2026-11-02-fresh-vm-image.md")" "## Advice
Recap: 2026-11-02 failures/tacplus-dev/looper/image_pull
Cause: Docker installed at boot under the first job
Change: the hub applies README's A fresh VM is ready (tacplus-dev/looper#43)
Gain: 6 failed jobs and 6 retries a night"
mkdir -p "$R/suggestions/recap"; echo '# Recap of 2026-11-02' > "$R/suggestions/recap/2026-11-02.md"; echo '{}' > "$R/suggestions/recap/2026-11-02.json"
passes check "$R" HEAD
echo x > "$R/suggestions/recap/notes.txt"; refused check "$R" HEAD; has "$OUT" "suggestions/recap/notes.txt: not a suggestion"
rm "$R/suggestions/recap/notes.txt"
commit advice
echo more >> "$R/suggestions/recap/2026-11-02.md"; refused check "$R" HEAD; has "$OUT" "suggestions/recap/2026-11-02.md: a filed suggestion"
git -C "$R" checkout -q -- .
# By hand: a suggestion citing the recap without its Advice, and one without numbers.
printf 'Suggestion: Lands\nType: Performance\nSummary: s\nWhy: w\n\n## Evidence\n- suggestions/recap/2026-11-02.json\n\n## Cost\nc\n\n## Touches\nt\n\n## Reuse considered\nr\n\n## Status\nopen\nRank: 2\nFiled: 2026-11-03 by hand\n' \
  > "$R/suggestions/2026-11-03-lands.md"
passes index "$R"; refused check "$R" HEAD
has "$OUT" "suggestions/2026-11-03-lands.md: its \`## Advice\` has no \`Recap: <night> <item>\`"
has "$OUT" "suggestions/2026-11-03-lands.md: it is advice from the nightly recap with no numeric evidence"
pass

scenario decide-needs-reason
file_it "${chaos[@]}" --evidence "https://github.com/tacplus-dev/looper/issues/42" || fail "$OUT"
refused decide "$R" 2026-11-01-chaos.md rejected
has "$OUT" "--reason is required"
refused decide "$R" 2026-11-01-chaos.md maybe --reason x
passes decide "$R" 2026-11-01-chaos.md accepted --reason "yes, as roadmap item chaos" --by "Jody (hub)" --date 2026-11-02
has "$(cat "$R/suggestions/2026-11-01-chaos.md")" "Decided: 2026-11-02 by Jody (hub): yes, as roadmap item chaos"
has "$(sed -n '/^## Accepted/,/^## Deferred/p' "$R/suggestions/INDEX.md")" "| [Chaos](2026-11-01-chaos.md) |"
passes check "$R"
pass

scenario template
passes template
[[ "$(head -n 4 <<<"$OUT" | cut -d: -f1 | paste -sd, -)" == "Suggestion,Type,Summary,Why" ]] || fail "$OUT"
for s in "## Evidence" "## Cost" "## Touches" "## Reuse considered" "## Status"; do has "$OUT" "$s"; done
pass

# Another job's suggestion (tacplus-dev/chaos#1): a clone of the roadmap
# repository, one commit touching suggestions/ only, pushed to main, made
# again on the new main when the push is rejected; a refused one pushes nothing.
scenario file-and-push
git clone -q --bare "$R" "$FIX/origin.git"
cat > "$FIX/origin.git/hooks/pre-receive" <<'H'
#!/usr/bin/env bash
[[ -e "$FIX/rejected-once" ]] && exit 0
touch "$FIX/rejected-once"; echo "main moved" >&2; exit 1
H
chmod +x "$FIX/origin.git/hooks/pre-receive"
before="$(git -C "$FIX/origin.git" rev-parse main)"
refused file "${chaos[@]}" --type Chaos --evidence "https://example.test/1"
[[ "$(git -C "$FIX/origin.git" rev-parse main)" == "$before" ]] || fail "a refused suggestion was pushed"
passes file "${chaos[@]}" --evidence "https://github.com/tacplus-dev/chaos/issues/1 (Chaos Mesh's nightly watch)" --by "tacplus-dev/chaos nightly"
[[ -e "$FIX/rejected-once" ]] || fail "the push was not rejected once"
has "$(cat "$FIX/cloned")" "tacplus-dev/roadmap"
[[ "$(git -C "$FIX/origin.git" rev-list --count "$before..main")" == 1 ]] || fail "not one commit: $(git -C "$FIX/origin.git" log --oneline main)"
[[ "$(git -C "$FIX/origin.git" diff --name-only "$before" main | paste -sd' ' -)" == "suggestions/2026-11-01-chaos.md suggestions/INDEX.md" ]] ||
  fail "pushed $(git -C "$FIX/origin.git" diff --name-only "$before" main)"
has "$(git -C "$FIX/origin.git" log -1 --format=%s main)" "Suggestion: Chaos (tacplus-dev/chaos nightly"
pass

echo "looper-suggest: all scenarios pass"
