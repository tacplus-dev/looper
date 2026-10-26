# looper

Each tacplus-dev repository works on itself. Work reaches a repository only as an issue; an issue
someone with write access labels `approved` is worked by that repository's looper, which commits and
pushes to main and closes the issue. Moved here from `seabeam/tools/looper` (6879339) on 2026-10-26.

## Shape (Jody, 2026-10-26)

- **Nothing is cloned or built on the Mac.** All looper work runs in this image as jobs of the GitLab
  pipeline `seabeam/tools/looper`, on the autoscaled GCE runner (workers exist only while there is
  work; see `sonar/backend/ops/ci-runners.md`).
- **`looper-dispatch`** is the only part on the Mac. It does no work itself: every 3 minutes, when a
  repository has a ready issue and no looper job of its own queued or running, it starts that
  pipeline. Nothing runs when there is no ready issue.
- **The pipeline** plans one job per repository with a ready issue (`looper-<repo>-<issue>`), each
  working that repository's oldest ready issue; jobs of one repository never overlap (`resource_group`).
  Its schedule runs the nightly scan of every repository.
- **`repo-looper`** is the looper of one repository. It works the issue it was given in a checkout of
  the repository at origin/main, and does nothing if the issue is no longer ready. Claude may run sub-agents in that checkout; only the top-level run
  commits and pushes, always to main (pre-production; a protected release line with review comes
  later). Bug fixes on repositories with release branches are also offered as backport pull requests.
- **The nightly scan** changes no code: it files an issue per finding (dependency vulnerabilities,
  gates failing on main, pins off the latest MAJOR.MINOR line). Mechanical fixes are filed `approved`,
  the rest `needs-decision`.
- **The image** is the tacplus build image (the complete build environment) plus the claude CLI and
  these scripts. It has **no tacplus binary**: `tacplus` is a wrapper that runs
  `ghcr.io/tacplus-dev/tacplus/tacplus:<MAJOR.MINOR>`, the compiler image for the repository's floor
  (`tacplus:` in tacplus.yaml or fleet.yaml), always that line's latest patch, as a sibling container on
  the worker's docker socket. The work directory is under the runner's `/builds` bind mount, the same
  path on the worker and in every container, so sibling containers see the same files.

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

## Running it

```sh
./looper-dispatch install    # launchd: start the pipeline every 3 minutes when a repository needs it
./looper-dispatch status     # the looper jobs in GitLab, and what is ready
```

The Mac needs `gh` and `glab` logged in. The jobs' credentials are seabeam group CI variables
(`GH_TOKEN`, `CLAUDE_CODE_OAUTH_TOKEN`), never baked into the image. The model is `LOOPER_MODEL`
(default `claude-opus-5-5`).

## Later

Doppelganger decides resource requests (more loopers, new repositories) instead of the fixed rules
here.
