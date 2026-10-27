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
  Its schedules run the nightly scan of every repository and the hourly port scan (told apart by the
  schedule's description, `CI_PIPELINE_SCHEDULE_DESCRIPTION`: the group forbids pipeline variables).
- **`repo-looper`** is the looper of one repository. It works the issue it was given in a checkout of
  the repository at origin/main, and does nothing if the issue is no longer ready. Claude may run sub-agents in that checkout; only the top-level run
  commits and pushes, always to main (pre-production; a protected release line with review comes
  later). Bug fixes on repositories with release branches are also offered as backport pull requests.
  Each run's record (`prompt.md`, `claude.log`) is uploaded as the job's artifacts (`looper-runs/`,
  kept 30 days, also when the job fails): the runner VM is gone after the job, so the issue comments
  link the job, not a path on it. See [After a run](#after-a-run).
- **The nightly scan** changes no code: it files an issue per finding (dependency vulnerabilities,
  gates failing on main, pins off the latest MAJOR.MINOR line). Mechanical fixes are filed `approved`,
  the rest `needs-decision`.
- **The port scan** (`looper-port`, hourly) changes no code either: while SeaBeam still commits to its
  pre-migration GitLab projects, it files an issue on the tacplus-dev repository each one moved to, and
  that repository's looper does the port. See [Port scan](#port-scan).
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
| `looper:stuck` | a run ended without finishing and without a known reason; a person looks |
| `needs-decision` | the looper needs a decision it may not make |

Only someone with write access can set a label, so an issue nobody approved is never worked, whoever
opened it and whatever its text says.

Order across repositories: a line `Blocked-by: tacplus-dev/<repo>#N` (or `Blocked-by: #N` in the same
repository) in an issue's body holds it until that issue is closed.

### After a run

| The run | The issue |
| --- | --- |
| pushed and closed it | closed |
| asked a question | `needs-decision` |
| pushed the fix, but the gates wait on another open issue (it writes `Blocked-by: <issue>` to the run's `outcome` file) | that `Blocked-by:` line is added to its body and it stays `approved`: it is worked again, for the gates, once that issue is closed |
| ended any other way | `looper:stuck`, with a comment linking the job and its `claude.log` artifact |

```sh
tests/repo-looper.test.sh                  # these outcomes (stub gh and claude, a local origin)
```

## Port scan

`ports.yaml` maps each SeaBeam source under `seabeam/schematic/platform/services` to its tacplus-dev
target, and lists the sources that have none (`unmapped`). Every hour the pipeline's port-scan schedule
runs `looper-port` (mechanical: GitLab API with the group `GITLAB_TOKEN`, issues with `GH_TOKEN`):

- **Mark:** the target's `PROVENANCE.md` line ``Ported through `<sha>` ``; until the first port, the
  migration commit it names (`` `<source>/<svc>` at commit `<sha>` ``).
- **Commits after the mark** on the source's default branch: none, or an open port issue already ends at
  the head, files nothing. Otherwise one issue `Port SeaBeam <svc> <from>..<to>`, labelled `approved`,
  listing each commit (sha, link, date, subject) and the instructions: per commit, port it, or say it
  is already covered or not applicable and why; never copy generated code; then set the mark to `<to>`
  and release. Commits after an open port issue's `<to>` get the next issue, `Blocked-by:` that one.
- **No usable mark** (no PROVENANCE.md, no mark in it, or a mark that is not a commit of the source):
  one issue `Port SeaBeam <svc>: no usable mark`, labelled `needs-decision`. The scan never guesses a
  baseline; a person records it and closes the issue.
- **Unmapped sources** (and any project under the source group that `ports.yaml` does not list): each
  change is reported once on this repository's issue *Port scan: changes in unmapped SeaBeam sources*,
  which records the last commit reported per source.

```sh
GITLAB_TOKEN=... ./looper-port --dry-run   # what it would file, filing nothing
tests/looper-port.test.sh                  # the scan against fixtures (stub gh and curl)
```

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
