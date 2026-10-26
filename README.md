# looper

Each tacplus-dev repository works on itself. Work reaches a repository only as an issue; an issue
someone with write access labels `approved` is worked by that repository's looper, which commits and
pushes to main and closes the issue. Moved here from `seabeam/tools/looper` (6879339) on 2026-10-26.

## Shape (Jody, 2026-10-26)

- **`looper-dispatch`** runs on the build host (this Mac today, a small VM or container later) and does
  no work itself. Every few minutes it finds repositories with a ready issue and starts that
  repository's looper container, unless one is already running. Nightly it starts each repository's
  scan. Nothing runs when there is no ready issue.
- **`repo-looper`** is the one looper of one repository, in one container (`looper-<repo>`). It keeps a
  single checkout of the repository, drains the ready issues oldest first, checks for new ones after
  each, and exits when none is left. Claude may run sub-agents in that checkout; only the top-level run
  commits and pushes, always to main (pre-production; a protected release line with review comes
  later). Bug fixes on repositories with release branches are also offered as backport pull requests.
- **The nightly scan** changes no code: it files an issue per finding (dependency vulnerabilities,
  gates failing on main, pins off the latest MAJOR.MINOR line). Mechanical fixes are filed `approved`,
  the rest `needs-decision`.
- **The image** is the tacplus build image (the complete build environment) plus the claude CLI and
  these scripts. It has **no tacplus binary**: `tacplus` is a wrapper that runs
  `ghcr.io/tacplus-dev/tacplus/tacplus:<MAJOR.MINOR>`, the compiler image for the repository's floor
  (`tacplus:` in tacplus.yaml or fleet.yaml), always that line's latest patch, as a sibling container on
  the host's docker socket. The work directory is mounted at the same path on the host and in every
  container so sibling containers see the same files.

## Issues

| Label | Meaning |
| --- | --- |
| `approved` | someone with write access approved it; the looper works it |
| `looper:in-progress` | a looper holds it |
| `looper:stuck` | a run ended without finishing; a person looks |
| `needs-decision` | the looper needs a decision it may not make |

Only someone with write access can set a label, so an issue nobody approved is never worked, whoever
opened it and whatever its text says.

Order across repositories: a line `Blocked-by: tacplus-dev/<repo>#N` (or `Blocked-by: #N` in the same
repository) in an issue's body holds it until that issue is closed.

## Running it on this Mac

```sh
colima start                                   # the docker runtime
security add-generic-password -a "$USER" -s tacplus-looper-claude -w '<token from: claude setup-token>'
./looper-dispatch install                      # every 3 minutes, and the nightly scan at 02:30
./looper-dispatch status
```

Credentials are never baked into the image: the dispatcher passes `GH_TOKEN` (from `gh auth token`)
and `CLAUDE_CODE_OAUTH_TOKEN` (from the keychain) to each container. The model is
`LOOPER_MODEL` (default `claude-opus-5-5`).

## Later

Doppelganger decides resource requests (more loopers, new repositories) instead of the fixed rules
here; the dispatcher moves to a small cloud VM or container.
