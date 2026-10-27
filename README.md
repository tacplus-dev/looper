# looper

Each tacplus-dev repository works on itself. Work reaches a repository only as an issue; an issue
someone with write access labels `approved` is worked by that repository's looper, which commits and
pushes to main and closes the issue. Moved here from `seabeam/tools/looper` (6879339) on 2026-10-26.

## Shape (Jody, 2026-10-26)

- **Nothing is cloned or built on the Mac.** All looper work runs in this image as jobs of the GitLab
  pipeline `tacplus-dev/looper`, on the autoscaled GCE runner (workers exist only while there is
  work; see [Infrastructure](#infrastructure)).
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

Time: a run has `LOOPER_TIMEOUT` (4h); a line `Timeout: <hours>h` in an issue's body gives its runs that
instead, at most 10h. The pipeline's job for the issue gets an hour more (`repo-looper --job-timeout N`).

### A run's work is never lost

The runner VM is gone after the job, so a run keeps its work in progress on the branch
`looper/<repo>-<issue>` of the repository (never on main):

- **Checkpoint:** everything in the checkout, committed or not, is pushed there as one commit, without
  touching the checkout: whenever the model finishes a step (the prompt has it run
  `repo-looper --repo R --issue N --checkpoint "<what is done; what is left>"`), every hour
  (`LOOPER_CHECKPOINT_INTERVAL`), and when the model stops. The model is stopped ten minutes before the
  limit (`LOOPER_STOP_EARLY`) so that last checkpoint always happens.
- **Resume:** a run on an issue whose branch exists starts from it, rebased on main, as uncommitted
  changes on main; its prompt has the last checkpoint's message and the issue's last comment. A branch
  that does not rebase cleanly (it carries merges, say, or long-lived work) gets main merged into it
  instead, rewriting no history, and starts the same way. When that merge conflicts too, the run still
  starts from the branch with main merged in: the conflicts are marked in the files, and the prompt names
  the conflicting paths to resolve first. Only a branch that cannot even be merged leaves the run on bare
  main, and the prompt says so. The branch itself is never changed.
- **The record rides along:** each checkpoint also carries the run's record under `.looper/` on that
  branch (`prompt.md` and the last 400 lines of `claude.log`, the job's tokens and anything shaped
  like a token redacted), so a run that is cancelled or killed, and so uploads no artifacts, still
  leaves its log behind. A run that resumes from the branch does not get `.looper/` back as work.
- The branch is deleted when the work lands on main (the issue is closed, or pushed with its gates
  blocked).

### A finished or idle run ends

A watchdog beside the model (every `LOOPER_WATCH_INTERVAL`, 60s) stops it:

- **Idle:** no output and nothing changed in the checkout for `LOOPER_IDLE_MINUTES` (20). Its work is
  checkpointed and the issue gets a comment that the run went idle, with the tail of its log; it is
  `looper:stuck`. The model's output is its event stream (`--output-format stream-json`), rendered
  into `claude.log` as its text, each tool call and the start of each result, so a working run
  always shows output.
- **Done:** once the run closed the issue, or pushed the fix and wrote its `Blocked-by:` outcome, the
  model has `LOOPER_DONE_GRACE` (300s) to exit by itself; then it is stopped and the run ends as
  done. The prompt has it close the issue as its last step, after any backport pull requests.

### After a run

| The run | The issue |
| --- | --- |
| pushed and closed it | closed |
| asked a question | `needs-decision` |
| pushed the fix, but the gates wait on another open issue (it writes `Blocked-by: <issue>` to the run's `outcome` file) | that `Blocked-by:` line is added to its body and it stays `approved`: it is worked again, for the gates, once that issue is closed |
| reached its time limit | a comment with what is done and what is left (its last checkpoint) and a link to its branch; it stays `approved`, neither stuck nor done, and the next run resumes from the branch |
| went idle | `looper:stuck`, with a comment that it went idle, the tail of its log and a link to its branch |
| ended any other way | `looper:stuck`, with a comment linking the job, its `claude.log` artifact and its branch, and the tail of its log |

```sh
tests/repo-looper.test.sh                  # these outcomes, checkpoints and the record, resume, the time limit, idle and done (stub gh and claude, a local origin)
```

## Port scan

The port scan is the one part of this repository that reads SeaBeam (Hub, 2026-10-27, looper#6): its
script, `ports.yaml`, its test and this section are the only places SeaBeam is named, other than the
dated note at the top. Nothing else here fetches from or depends on gitlab.com/seabeam.

`ports.yaml` maps each SeaBeam source under `seabeam/schematic/platform/services` to its tacplus-dev
target, lists the sources that have none (`unmapped`), and the sources that are never carried over
(`retired`, each with its reason and date). Every hour the pipeline's port-scan schedule
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
- **Retired sources** are skipped entirely: never ported, never reported, not even read. Since
  2026-10-27 nothing comes over from SeaBeam that is not already in tacplus-dev, except stratum, so
  every source without a target is retired (looper#5); a new source shows up as unmapped until it is
  listed.

```sh
GITLAB_TOKEN=... ./looper-port --dry-run   # what it would file, filing nothing
tests/looper-port.test.sh                  # the scan against fixtures (stub gh and curl)
```

## Running it

```sh
./looper-dispatch install    # launchd: start the pipeline every 3 minutes when a repository needs it
./looper-dispatch status     # the looper jobs in GitLab, and what is ready
```

The Mac needs `gh` and `glab` logged in. The jobs' credentials are tacplus-dev GitLab group CI
variables, masked and protected (`GH_TOKEN`, `CLAUDE_CODE_OAUTH_TOKEN`, and `GITLAB_TOKEN`, read-only,
for the port scan), never baked into the image. The model is `LOOPER_MODEL` (default `claude-opus-5-5`).

## Infrastructure

The pipeline is gitlab.com/tacplus-dev/looper. Its jobs run on the group runner 57939705
*tacplus-dev arm64 autoscaler*, whose manager is the GCE VM `gitlab-runner-mgr` (us-central1-b,
project jody1-328023). The manager runs the docker-autoscaler executor with the googlecloud fleeting
plugin, driving its own managed instance group `runner-arm64-tacplus` (template
`runner-arm64-t2a8-v5`, t2a-standard-8): up to 5 workers, size 0 at rest.

- Changing `max_instances` needs a gitlab-runner restart, and a restart kills running jobs.
- The project's maximum job timeout is 11h (a run's 10h at most, plus the job's hour).

## Later

Doppelganger decides resource requests (more loopers, new repositories) instead of the fixed rules
here.
