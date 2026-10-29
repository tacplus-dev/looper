#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# looper-port against fixtures: stub `gh` and `curl` serve a scenario's
# GitHub and GitLab answers from files and record every issue and comment the
# scan would file. Run: tests/looper-port.test.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
API=https://gl.test/api/v4

# Stubs. GitLab: $FIX/gl/<path with every other character as _>. GitHub:
# $FIX/gh/<repo>/{PROVENANCE.md,ROADMAP.md,issues.json,issue-N.json,comments-N.json},
# and tacplus-dev/roadmap's items/ from $FIX/gh/roadmap/items/ (a file
# <name>.fail answers HTTP 502);
# writes are appended to $FIX/filed as "<repo> <json>".
mkdir -p "$TMP/bin"
cat > "$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
url=""; w=""
while [[ $# -gt 0 ]]; do case "$1" in -w) w=1; shift 2 ;; http*) url="$1"; shift ;; -H|-o) shift 2 ;; *) shift ;; esac; done
f="$FIX/gl/$(printf '%s' "${url#"$GITLAB_API"/}" | tr -c 'A-Za-z0-9.-' '_')"
echo "${url#"$GITLAB_API"/}" >> "$FIX/requests"
if [[ -n "$w" ]]; then [[ -f "$f" ]] && printf 200 || printf 404; exit 0; fi
[[ -f "$f" ]] || { echo "curl: (22) The requested URL returned error: 404" >&2; exit 22; }
cat "$f"
EOF
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == api ]] || { echo "stub gh: unexpected $*" >&2; exit 3; }
path="$2"; shift 2; input=""; q=""
while [[ $# -gt 0 ]]; do case "$1" in --input) input=1; shift 2 ;; --jq) q="$2"; shift 2 ;; *) shift ;; esac; done
repo="$(cut -d/ -f3 <<<"$path")"; rest="$(cut -d/ -f4- <<<"$path")"; d="$FIX/gh/$repo"
if [[ -n "$input" && -e "$FIX/writes-fail" ]]; then cat >/dev/null; echo "gh: Server Error (HTTP 502)" >&2; exit 1; fi
if [[ -n "$input" ]]; then echo "$repo $(jq -c --arg p "$rest" '. + {path: $p}')" >> "$FIX/filed"; [[ -n "$q" ]] && echo 100; exit 0; fi
case "$rest" in
  contents/items) [[ -d "$d/items" ]] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
    for f in "$d"/items/*.md; do jq -n --arg n "${f##*/}" '{name: $n, path: "items/\($n)", type: "file"}'; done | jq -s . | jq -r "${q:-.}" ;;
  contents/*) f="$d/${rest#contents/}"; [[ -f "$f.fail" ]] && { echo "gh: Server Error (HTTP 502)" >&2; exit 1; }
    [[ -f "$f" ]] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }; cat "$f" ;;
  issues\?*) cat "$d/issues.json" 2>/dev/null || echo '[]' ;;
  issues/*/comments) cat "$d/comments-$(cut -d/ -f2 <<<"$rest").json" 2>/dev/null || echo '[]' ;;
  issues/*) jq -r "$q" "$d/issue-${rest#issues/}.json" ;;
  *) echo "stub gh: unexpected path $path" >&2; exit 3 ;;
esac
EOF
chmod +x "$TMP/bin/curl" "$TMP/bin/gh"

A=aaaaaaa111111111111111111111111111111111; B=bbbbbbbb22222222222222222222222222222222
C=cccccccc33333333333333333333333333333333; D=dddddddd44444444444444444444444444444444
Z=eeeeeeee55555555555555555555555555555555; Y=ffffffff66666666666666666666666666666666

key() { printf '%s' "$1" | tr -c 'A-Za-z0-9.-' '_'; }
gl() { mkdir -p "$FIX/gl"; printf '%s' "$2" > "$FIX/gl/$(key "$1")"; }       # path json
ghf() { mkdir -p "$FIX/gh/$1"; printf '%s' "$3" > "$FIX/gh/$1/$2"; }          # repo file content
commit() { # sha title [message, default the title]
  jq -nc --arg id "$1" --arg t "$2" --arg m "${3:-$2}" \
    '{id: $id, short_id: $id[0:8], title: $t, message: $m, authored_date: "2026-10-26T10:00:00.000-06:00", web_url: "https://gl.test/c/\($id)"}'
}
compare() { gl "projects/seabeam%2Fsrc%2F$1/repository/compare?from=$2&to=main" "{\"commits\":[$3]}"; }
known() { gl "projects/seabeam%2Fsrc%2F$1/repository/commits/$2" "$(commit "$2" "$3")"; }   # svc ref title

scenario() { # name: a fresh fixture with one mapped source, alpha, migrated at A
  NAME="$1"; FIX="$TMP/$1"; mkdir -p "$FIX"; : > "$FIX/filed"; : > "$FIX/requests"
  gl "groups/seabeam%2Fsrc/projects?per_page=100&archived=false" '[{"path":"alpha","default_branch":"main"}]'
  ghf alpha PROVENANCE.md 'Copied **wholesale** from `gitlab.com/seabeam/src/alpha` at
commit `aaaaaaa` (history carried over).'
  known alpha aaaaaaa "migrated"; known alpha main "head"
}
run() {
  OUT="$(PATH="$TMP/bin:$PATH" FIX="$FIX" GITLAB_API="$API" GITLAB_TOKEN=x LOOPER_PORTS="${PORTS:-$TMP/ports.yaml}" \
         LOOPER_LIB="$ROOT/looper-lib.sh" "$ROOT/looper-port" 2>&1)" || { echo "$OUT"; fail "looper-port exited non-zero"; }
}
fail() { echo "FAIL $NAME: $*" >&2; [[ -s "$FIX/filed" ]] && cat "$FIX/filed" >&2; exit 1; }
filed() { grep -c . "$FIX/filed" || true; }
field() { sed -n "${1}p" "$FIX/filed" | cut -d' ' -f2- | jq -r "$2"; }
has() { grep -qF -- "$2" <<<"$1" || fail "expected \"$2\" in: $1"; }
lacks() { ! grep -qF -- "$2" <<<"$1" || fail "unexpected \"$2\" in: $1"; }
pass() { echo "ok $NAME"; }

cat > "$TMP/ports.yaml" <<'EOF'
# fixture
source: seabeam/src
target: tacplus-dev
ports:
  alpha: alpha
unmapped:
  - zeta  # undecided
retired:
  - rho  # dead (fixture, 2026-10-27)
EOF

scenario new-commits
compare alpha aaaaaaa "$(commit "$B" "first change"),$(commit "$C" "second change")"
run
[[ "$(filed)" == 1 ]] || fail "want one issue, got $(filed)"
[[ "$(field 1 .title)" == "Port SeaBeam alpha aaaaaaa..cccccccc" ]] || fail "title $(field 1 .title)"
[[ "$(field 1 '.labels|join(",")')" == feature,approved ]] || fail "labels $(field 1 .labels)"
body="$(field 1 .body)"
has "$body" '[`bbbbbbbb`](https://gl.test/c/'"$B"') 2026-10-26 first change'
has "$body" '[`cccccccc`](https://gl.test/c/'"$C"') 2026-10-26 second change'
has "$body" "Ported through \`$C\`."
has "$body" "never copy generated code"
lacks "$body" "Blocked-by"
pass

scenario no-commits
compare alpha aaaaaaa ""
run
[[ "$(filed)" == 0 ]] || fail "want nothing, got $(filed)"
pass

scenario open-issue-covers
ghf alpha issues.json '[{"number":5,"title":"Port SeaBeam alpha aaaaaaa..cccccccc"},{"number":6,"title":"other","pull_request":{}}]'
compare alpha cccccccc ""
run
[[ "$(filed)" == 0 ]] || fail "want nothing, got $(filed)"
pass

scenario after-open-issue
ghf alpha issues.json '[{"number":5,"title":"Port SeaBeam alpha aaaaaaa..cccccccc"}]'
compare alpha cccccccc "$(commit "$D" "third change")"
run
[[ "$(filed)" == 1 ]] || fail "want one issue, got $(filed)"
[[ "$(field 1 .title)" == "Port SeaBeam alpha cccccccc..dddddddd" ]] || fail "title $(field 1 .title)"
body="$(field 1 .body)"; has "$body" "Blocked-by: #5"; lacks "$body" bbbbbbbb
pass

scenario ported-through-wins
ghf alpha PROVENANCE.md 'Copied from `gitlab.com/seabeam/src/alpha` at commit `aaaaaaa`.

Ported through `'"$B"'`.'
known alpha "$B" "first change"
compare alpha "$B" "$(commit "$C" "second change")"
run
[[ "$(field 1 .title)" == "Port SeaBeam alpha bbbbbbbb..cccccccc" ]] || fail "title $(field 1 .title)"
pass

scenario missing-mark
rm "$FIX/gh/alpha/PROVENANCE.md"
run
[[ "$(filed)" == 1 ]] || fail "want one issue, got $(filed)"
[[ "$(field 1 .title)" == "Port SeaBeam alpha: no usable mark" ]] || fail "title $(field 1 .title)"
[[ "$(field 1 '.labels|join(",")')" == bug,needs-decision ]] || fail "labels $(field 1 .labels)"
has "$(field 1 .body)" "has no PROVENANCE.md"
lacks "$(cat "$FIX/requests")" compare
pass

scenario missing-mark-asked
rm "$FIX/gh/alpha/PROVENANCE.md"
ghf alpha issues.json '[{"number":7,"title":"Port SeaBeam alpha: no usable mark"}]'
run
[[ "$(filed)" == 0 ]] || fail "want nothing, got $(filed)"
pass

scenario mark-not-in-source
rm "$FIX/gl/$(key "projects/seabeam%2Fsrc%2Falpha/repository/commits/aaaaaaa")"
run
[[ "$(field 1 .title)" == "Port SeaBeam alpha: no usable mark" ]] || fail "title $(field 1 .title)"
has "$(field 1 .body)" "is not a commit of"
pass

scenario unmapped-first-sight
gl "groups/seabeam%2Fsrc/projects?per_page=100&archived=false" '[{"path":"alpha","default_branch":"main"},{"path":"zeta","default_branch":"main"},{"path":"omega","default_branch":"main"}]'
compare alpha aaaaaaa ""
gl "projects/seabeam%2Fsrc%2Fzeta/repository/commits/main" "$(commit "$Z" "zeta head")"; gl "projects/seabeam%2Fsrc%2Fomega/repository/commits/main" "$(commit "$Y" "omega head")"
run
[[ "$(filed)" == 1 ]] || fail "want one issue, got $(filed)"
[[ "$(sed -n 1p "$FIX/filed" | cut -d' ' -f1)" == looper ]] || fail "not on looper"
[[ "$(field 1 '.labels|join(",")')" == feature,needs-decision ]] || fail "labels"
body="$(field 1 .body)"; has "$body" "**zeta**: through \`$Z\`"; has "$body" "**omega**: through \`$Y\` (not in ports.yaml)"
pass

scenario unmapped-new-commits
gl "groups/seabeam%2Fsrc/projects?per_page=100&archived=false" '[{"path":"alpha","default_branch":"main"},{"path":"zeta","default_branch":"main"}]'
compare alpha aaaaaaa ""
ghf looper issues.json '[{"number":3,"title":"Port scan: changes in unmapped SeaBeam sources"}]'
ghf looper issue-3.json "{\"body\":\"- **zeta**: through \`$Z\`\"}"
gl "projects/seabeam%2Fsrc%2Fzeta/repository/commits/main" "$(commit "$D" "zeta new")"
compare zeta "$Z" "$(commit "$D" "zeta new")"
run
[[ "$(filed)" == 1 ]] || fail "want one comment, got $(filed)"
[[ "$(field 1 .path)" == issues/3/comments ]] || fail "not a comment on #3: $(field 1 .path)"
body="$(field 1 .body)"; has "$body" "**zeta**: through \`$D\`"; has "$body" "zeta new"
pass

scenario unmapped-reported
gl "groups/seabeam%2Fsrc/projects?per_page=100&archived=false" '[{"path":"alpha","default_branch":"main"},{"path":"zeta","default_branch":"main"}]'
compare alpha aaaaaaa ""
ghf looper issues.json '[{"number":3,"title":"Port scan: changes in unmapped SeaBeam sources"}]'
ghf looper issue-3.json "{\"body\":\"- **zeta**: through \`$Z\`\"}"
ghf looper comments-3.json "[{\"body\":\"- **zeta**: through \`$D\`\"}]"
gl "projects/seabeam%2Fsrc%2Fzeta/repository/commits/main" "$(commit "$D" "zeta new")"
run
[[ "$(filed)" == 0 ]] || fail "want nothing, got $(filed)"
pass

scenario retired-never-reported
gl "groups/seabeam%2Fsrc/projects?per_page=100&archived=false" '[{"path":"alpha","default_branch":"main"},{"path":"omega","default_branch":"main"},{"path":"rho","default_branch":"main"},{"path":"zeta","default_branch":"main"}]'
compare alpha aaaaaaa ""
gl "projects/seabeam%2Fsrc%2Fzeta/repository/commits/main" "$(commit "$Z" "zeta head")"; gl "projects/seabeam%2Fsrc%2Fomega/repository/commits/main" "$(commit "$Y" "omega head")"
gl "projects/seabeam%2Fsrc%2Frho/repository/commits/main" "$(commit "$D" "rho head")"
run
[[ "$(filed)" == 1 ]] || fail "want one issue, got $(filed)"
body="$(field 1 .body)"; has "$body" "**zeta**: through \`$Z\`"; has "$body" "**omega**: through \`$Y\` (not in ports.yaml)"
lacks "$body" "**zeta**: through \`$Z\` (not in ports.yaml)"; lacks "$body" rho; lacks "$OUT" rho; lacks "$(cat "$FIX/requests")" rho
pass

scenario retired-only
gl "groups/seabeam%2Fsrc/projects?per_page=100&archived=false" '[{"path":"alpha","default_branch":"main"},{"path":"rho","default_branch":"main"}]'
compare alpha aaaaaaa ""
gl "projects/seabeam%2Fsrc%2Frho/repository/commits/main" "$(commit "$D" "rho head")"
run
[[ "$(filed)" == 0 ]] || fail "want nothing, got $(filed)"
lacks "$(cat "$FIX/requests")" rho
pass

scenario write-fails
compare alpha aaaaaaa "$(commit "$B" "first change")"
touch "$FIX/writes-fail"
if OUT="$(PATH="$TMP/bin:$PATH" FIX="$FIX" GITLAB_API="$API" GITLAB_TOKEN=x LOOPER_PORTS="$TMP/ports.yaml" \
          LOOPER_LIB="$ROOT/looper-lib.sh" "$ROOT/looper-port" 2>&1)"; then fail "exited 0 when filing failed"; fi
has "$OUT" "ERROR could not file"
pass

# The roadmaps first (looper#14): porting a source whose port is already an
# entry on a roadmap (the target's ROADMAP.md, the platform's, or its items/)
# that is not done gets no new port issue, but one asking for that entry to be
# prioritized, once.
scenario roadmap-entry
ghf alpha issues.json '[{"number":5,"title":"Port SeaBeam alpha aaaaaaa..cccccccc"}]'
ghf alpha issue-5.json '{"state":"open"}'; ghf alpha issue-3.json '{"state":"closed"}'
ghf alpha ROADMAP.md '# Roadmap: alpha

## Later
- Port SeaBeam alpha aaaaaaa..cccccccc (#5), after #3'
compare alpha cccccccc "$(commit "$D" "third change")"
run
[[ "$(filed)" == 1 ]] || fail "want one issue, got $(filed)"
[[ "$(field 1 .title)" == "Prioritize the roadmap entry: Port SeaBeam alpha" ]] || fail "title $(field 1 .title)"
[[ "$(field 1 '.labels|join(",")')" == feature ]] || fail "labels $(field 1 .labels)"
body="$(field 1 .body)"
has "$body" "- Port SeaBeam alpha aaaaaaa..cccccccc (#5), after #3"
has "$body" "https://github.com/tacplus-dev/alpha/blob/main/ROADMAP.md"
has "$body" "Why now"; has "$body" "third change"
lacks "$body" "Blocked-by"
pass

scenario roadmap-entry-asked
ghf alpha issues.json '[{"number":6,"title":"Prioritize the roadmap entry: Port SeaBeam alpha"}]'
ghf alpha ROADMAP.md '- Port SeaBeam alpha (no issue yet)'
compare alpha aaaaaaa "$(commit "$B" "first change")"
run
[[ "$(filed)" == 0 ]] || fail "want nothing, got $(filed)"
pass

scenario roadmap-entry-platform-item
mkdir -p "$FIX/gh/roadmap/items"
printf '# Ports\n\n- **Port SeaBeam alpha** when it settles.\n' > "$FIX/gh/roadmap/items/ports.md"
ghf roadmap ROADMAP.md '- Port SeaBeam alphabet (tacplus-dev/other#1)'
compare alpha aaaaaaa "$(commit "$B" "first change")"
run
[[ "$(field 1 .title)" == "Prioritize the roadmap entry: Port SeaBeam alpha" ]] || fail "title $(field 1 .title)"
body="$(field 1 .body)"
has "$body" "https://github.com/tacplus-dev/roadmap/blob/main/items/ports.md"; lacks "$body" alphabet
pass

# An entry whose issue is closed is done: the next range is a port issue, as without one.
scenario roadmap-entry-done
ghf alpha issue-5.json '{"state":"closed"}'
ghf alpha ROADMAP.md '- Port SeaBeam alpha 11111111..aaaaaaaa (#5)'
compare alpha aaaaaaa "$(commit "$B" "first change")"
run
[[ "$(field 1 .title)" == "Port SeaBeam alpha aaaaaaa..bbbbbbbb" ]] || fail "title $(field 1 .title)"
pass

# A roadmap that cannot be read: nothing is filed, and the scan fails.
scenario roadmap-unreadable
ghf alpha ROADMAP.md.fail ''
compare alpha aaaaaaa "$(commit "$B" "first change")"
if OUT="$(PATH="$TMP/bin:$PATH" FIX="$FIX" GITLAB_API="$API" GITLAB_TOKEN=x LOOPER_PORTS="$TMP/ports.yaml" \
          LOOPER_LIB="$ROOT/looper-lib.sh" "$ROOT/looper-port" 2>&1)"; then fail "exited 0"; fi
[[ "$(filed)" == 0 ]] || fail "want nothing, got $(filed)"
has "$OUT" "cannot read the roadmaps"
pass

# The realign (looper#23): a SeaBeam commit that ports tacplus-dev work carries
# `Ported-from: tacplus-dev/<repo>@<sha>` and is never ported back.
trailered() { commit "$1" "$2" "$2

Adopt it as tacplus-dev has it.

Ported-from: tacplus-dev/alpha@$3
Ported-from: tacplus-dev/kernel@c630f29"; }
scenario realign-all-trailered
compare alpha aaaaaaa "$(trailered "$B" "adopt XIDs" 1234567),$(trailered "$C" "adopt tid routing" 89abcde)"
run
[[ "$(filed)" == 0 ]] || fail "want nothing, got $(filed)"
has "$OUT" "ported from tacplus-dev"
pass

scenario realign-mixed
compare alpha aaaaaaa "$(trailered "$B" "adopt XIDs" 1234567),$(commit "$C" "seabeam fix" "seabeam fix

Only here."),$(trailered "$D" "adopt tid routing" 89abcde)"
run
[[ "$(filed)" == 1 ]] || fail "want one issue, got $(filed)"
[[ "$(field 1 .title)" == "Port SeaBeam alpha aaaaaaa..dddddddd" ]] || fail "title $(field 1 .title)"
[[ "$(field 1 '.labels|join(",")')" == feature,approved ]] || fail "labels $(field 1 .labels)"
body="$(field 1 .body)"
has "$body" '[`cccccccc`](https://gl.test/c/'"$C"') 2026-10-26 seabeam fix'
lacks "$body" "](https://gl.test/c/$B)"; lacks "$body" "](https://gl.test/c/$D)"
has "$body" '`bbbbbbbb` adopt XIDs'; has "$body" "Ported-from: tacplus-dev/alpha@89abcde"
has "$body" "Ported through \`$D\`."
pass

# Fail closed: one that names tacplus-dev (or has a malformed trailer) without
# a trailer is a person's call.
scenario realign-untrailered
compare alpha aaaaaaa "$(commit "$B" "seabeam fix"),$(commit "$C" "adopt XIDs" "adopt XIDs

As in tacplus-dev/kernel#23."),$(commit "$D" "adopt tids" "adopt tids

Ported-from: kernel@c630f29")"
run
[[ "$(filed)" == 1 ]] || fail "want one issue, got $(filed)"
[[ "$(field 1 .title)" == "Port SeaBeam alpha aaaaaaa..dddddddd" ]] || fail "title $(field 1 .title)"
[[ "$(field 1 '.labels|join(",")')" == feature,needs-decision ]] || fail "labels $(field 1 .labels)"
body="$(field 1 .body)"
has "$body" "](https://gl.test/c/$B) 2026-10-26 seabeam fix"
has "$body" "no \`Ported-from:\` trailer"
decide="$(sed -n '/no `Ported-from:` trailer/,/^$/p' <<<"$body")"
has "$decide" "adopt XIDs"; has "$decide" "adopt tids"; lacks "$decide" "seabeam fix"
pass

# The flood guard: a scan that would file more than 5 issues files none, and
# asks on looper instead, once.
flood() { # sources
  PORTS="$FIX/ports.yaml"; printf 'source: seabeam/src\ntarget: tacplus-dev\nports:\n' > "$PORTS"
  local s projects=""
  for s in "$@"; do
    printf '  %s: %s\n' "$s" "$s" >> "$PORTS"; projects="$projects,{\"path\":\"$s\",\"default_branch\":\"main\"}"
    ghf "$s" PROVENANCE.md "Ported through \`aaaaaaa\`."; known "$s" aaaaaaa migrated; known "$s" main head
    compare "$s" aaaaaaa "$(commit "$B" "change in $s")"
  done
  gl "groups/seabeam%2Fsrc/projects?per_page=100&archived=false" "[${projects#,}]"
}
scenario flood-under
flood s1 s2 s3 s4 s5
run; PORTS=""
[[ "$(filed)" == 5 ]] || fail "want five issues, got $(filed)"
pass

scenario flood-trips
flood s1 s2 s3 s4 s5 s6
run; PORTS=""
[[ "$(filed)" == 1 ]] || fail "want one issue, got $(filed)"
[[ "$(sed -n 1p "$FIX/filed" | cut -d' ' -f1)" == looper ]] || fail "not on looper"
[[ "$(field 1 .title)" == "Port scan: flood guard tripped" ]] || fail "title $(field 1 .title)"
[[ "$(field 1 '.labels|join(",")')" == bug,needs-decision ]] || fail "labels $(field 1 .labels)"
body="$(field 1 .body)"
for s in s1 s2 s3 s4 s5 s6; do has "$body" "tacplus-dev/$s: Port SeaBeam $s aaaaaaa..bbbbbbbb"; done
has "$body" "LOOPER_PORT_MAX_ISSUES"
pass

scenario flood-asked
flood s1 s2 s3 s4 s5 s6
ghf looper issues.json '[{"number":9,"title":"Port scan: flood guard tripped"}]'
run; PORTS=""
[[ "$(filed)" == 0 ]] || fail "want nothing, got $(filed)"
has "$OUT" "flood guard"
pass

echo "looper-port: all scenarios pass"
