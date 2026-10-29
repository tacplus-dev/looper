# looper

Each tacplus-dev repository works on itself. Work reaches a repository only as an issue; an issue
someone with write access labels `approved` is worked by that repository's looper, which commits and
pushes to main and closes the issue. Moved here from `seabeam/tools/looper` (6879339) on 2026-10-26.

## Shape (Jody, 2026-10-26)

- **Nothing runs on the Mac** (Jody, 2026-10-29, looper#24). All looper work, the kicker included, runs
  in this image as jobs of the GitLab pipeline `tacplus-dev/looper`, on the autoscaled GCE runner (see
  [Infrastructure](#infrastructure)).
- **The kicker** (`looper-dispatch`) does no work itself: every 3 minutes, when a repository has a ready
  issue and no looper job of its own created, pending, waiting for its `resource_group` or running, it
  starts that pipeline. It is the pipeline's kicker schedule (description containing `kicker`), hourly,
  since gitlab.com runs this group's schedules at most once an hour (Free tier): its job, `looper-kick`,
  runs `looper-dispatch run --for 3420`, a pass every `LOOPER_INTERVAL` (180 seconds) for 57 minutes, and
  fails at the end if a pass failed. Two kicker jobs never overlap (`resource_group: kicker`): the next
  hour's waits for the last. Nothing else runs when there is no ready issue.
- **The pipeline** plans one job per repository with a ready issue (`looper-<repo>-<issue>`), each
  working that repository's oldest ready issue; jobs of one repository never overlap (`resource_group`).
  A repository that already has a looper job created, pending, waiting or running in the project gets
  no other one, and the plan's log says so (`repo-looper --list` reads the project's jobs with
  `GITLAB_TOKEN`, else the job's token; looper#16): a duplicate would only wait for the slot to find its
  issue taken. A job takes its repository's oldest ready issue when it runs: the planned one if it is
  still ready, else the one that is oldest now.
- **A run killed outright** (its runner VM gone mid-job, looper#20) never removes `looper:in-progress`.
  The job for that issue (GitLab's automatic retry, say) takes it as a resume, from its checkpoint, when
  no *other* looper job of the repository is created, pending, waiting or running: the label is that
  job's. And every `looper-dispatch run` removes the label, with a comment, from any issue whose
  repository has no such job, so the next pass resumes it. An issue whose job is really running, or
  whose jobs GitLab cannot tell, is never taken twice.
- **A run whose job GitLab no longer runs** (looper#21): GitLab can mark a job failed
  (`runner_system_failure`, the manager's tunnel to the VM lost) while its container keeps working on the
  VM, and retry it. So every few minutes (`LOOPER_JOB_POLL`, default 300 seconds) a run asks GitLab for its
  own job (`CI_JOB_ID`; with `GITLAB_TOKEN`, else the job's token, which GitLab refuses once the job has
  stopped). Once GitLab reports it anything but `running`, the run checkpoints and stops: nothing more
  pushed to main, no comment, `looper:in-progress` left to the retry, which resumes from that checkpoint.
  A run that cannot read GitLab keeps going: GitLab being down is not the job being gone.
  Its schedules run the kicker, the nightly scan of every repository and the port scan (told apart by the
  schedule's description, `CI_PIPELINE_SCHEDULE_DESCRIPTION`: the group forbids pipeline variables).
- **`repo-looper`** is the looper of one repository. It works the issue it was given in a checkout of
  the repository at origin/main, or the oldest ready one if that issue is no longer ready, and does
  nothing if none is. Claude may run sub-agents in that checkout; only the top-level run
  commits and pushes, always to main (pre-production; a protected release line with review comes
  later). Bug fixes on repositories with release branches are also offered as backport pull requests.
  Each run's record (`prompt.md`, `claude.log`) is uploaded as the job's artifacts (`looper-runs/`,
  kept 30 days, also when the job fails): the runner VM is gone after the job, so the issue comments
  link the job, not a path on it. See [After a run](#after-a-run).
- **The nightly scan** changes no code: it files a `bug` per finding (dependency vulnerabilities,
  gates failing on main, pins off the latest MAJOR.MINOR line). Mechanical fixes are filed `approved`,
  the rest `needs-decision`; ideas for new behaviour go to PROPOSALS.md (see [Bug or feature](#bug-or-feature)).
- **The port scan** (`looper-port`, hourly) changes no code either: while SeaBeam still commits to its
  pre-migration GitLab projects, it files an issue on the tacplus-dev repository each one moved to, and
  that repository's looper does the port. See [Port scan](#port-scan).
- **The image** is the tacplus build image (the complete build environment) plus the claude CLI and
  these scripts. It has **no tacplus binary**: `tacplus` is a wrapper that runs
  `ghcr.io/tacplus-dev/tacplus/tacplus:<MAJOR.MINOR>`, the compiler image for the repository's floor
  (`tacplus:` in tacplus.yaml or fleet.yaml), always that line's latest patch, as a sibling container on
  the worker's docker socket. The work directory is under the runner's `/builds` bind mount, the same
  path on the worker and in every container, so sibling containers see the same files.
- **GitHub credentials in containers** (looper#11): since tacplus 2.4 a repository's `depends` resolve
  through the private `tacplus-dev/registry`, so the compiler container clones from GitHub. The wrapper
  gives it, through its environment alone (`DOCKER_GITHUB_CREDS` in `looper-lib.sh`), a git credential
  helper for `https://github.com` and no other host, which answers from `$GH_TOKEN` (else
  `$GITHUB_TOKEN`) when git asks, and drops any other helper for github.com so none stores it. The token
  is only inherited by the container: it is on no command line, in no file and in no image. Any other
  `docker run` of something that clones from GitHub passes the same `"${DOCKER_GITHUB_CREDS[@]}"`.

```sh
tests/tacplus.test.sh                      # the wrapper's credentials against a stub git server: github.com gets the token, any other host none, nothing on disk holds it
```

## Issues

| Label | Meaning |
| --- | --- |
| `approved` | someone with write access approved it; the looper works it (a feature: only once it is on a ROADMAP.md) |
| `bug` | the code does not do what it already promises: fixed, and released as a patch |
| `feature` | new behaviour: needs design, Jody's approval and a ROADMAP.md entry; ships in a minor |
| `looper:in-progress` | a looper holds it |
| `looper:stuck` | a run ended without finishing and without a known reason; a person looks |
| `needs-decision` | the looper needs a decision it may not make |

Only someone with write access can set a label, so an issue nobody approved is never worked, whoever
opened it and whatever its text says.

### Bug or feature

Every issue is a bug or a feature (tacplus-dev/roadmap `decisions/issue-flow-2026-10-27.md`, looper#14); the
looper creates both labels in a repository that lacks them.

- **Unlabelled:** the model first classifies it, in a comment and the label (its record is the run's
  `classify/`); one it leaves unclassified is `needs-decision`, for a person to label.
- **Bug:** fixed on main and released as the next patch of main's newest release (the prompt names the tag,
  `vX.Y.Z+1`; none when the repository has no release yet), and backported by pull request to each supported
  `release/MAJOR.MINOR` (docs/VERSIONING.md in tacplus-dev/tacplus).
- **Feature:** built only if it is `approved` **and** a ROADMAP.md links it: the repository's (`#N` will
  do) or the platform's, tacplus-dev/roadmap `ROADMAP.md` (`tacplus-dev/<repo>#N`). Otherwise it is not
  built: the model writes a design proposal as a comment and into PROPOSALS.md, and the issue is
  `needs-decision`. It ships in a minor, from main only. When the platform's roadmap cannot be read, the
  feature is neither built nor proposed (`looper:stuck`).
- **Before opening any issue**, every looper prompt and the scans read the repository's ROADMAP.md and the
  platform's (`ROADMAP.md` and `items/`): a feature already on a roadmap gets no new issue, but one
  (`feature`) asking for that entry to be prioritized, linking it and saying why now.
- **The nightly scan** files each finding (a vulnerability, a failing gate, a stale pin) as a `bug`,
  `approved` when the fix is mechanical; an idea for new behaviour is a `feature`, never `approved`, and goes
  to PROPOSALS.md. After the scan, an issue it filed with no kind gets `bug`, and a feature it filed loses
  `approved`.

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
- **Done:** once the run closed the issue, or wrote its `Blocked-by:` outcome, the
  model has `LOOPER_DONE_GRACE` (300s) to exit by itself; then it is stopped and the run ends as
  done. The prompt has it close the issue as its last step, after any backport pull requests.

### After a run

| The run | The issue |
| --- | --- |
| pushed and closed it | closed |
| asked a question | `needs-decision` |
| found it waits on other open issues: it pushed the fix and the gates wait, or rightly pushed nothing (looper#22); it writes one `Blocked-by: <issue>` line per issue to the run's `outcome` file | those `Blocked-by:` lines are added to its body and it stays `approved`, with a comment: it is worked again once they are all closed. An outcome naming a closed or missing issue, or the issue itself, is rejected whole (`looper:stuck`) |
| reached its time limit | a comment with what is done and what is left (its last checkpoint) and a link to its branch; it stays `approved`, neither stuck nor done, and the next run resumes from the branch |
| went idle | `looper:stuck`, with a comment that it went idle, the tail of its log and a link to its branch |
| lost its job (GitLab no longer runs it, looper#21) | nothing: its work is checkpointed and the job's retry resumes it |
| ended any other way | `looper:stuck`, with a comment linking the job, its `claude.log` artifact and its branch, and the tail of its log |

```sh
tests/repo-looper.test.sh                  # these outcomes, checkpoints and the record, resume, the time limit, idle and done, the planning files, bug or feature, the scan's labels, and the plan skipping a busy repository, a killed run resumed by its retry, a run whose job GitLab no longer runs stopped (stub gh, claude and curl, a local origin)
```

## Planning files

Every tacplus-dev repository carries `ROADMAP.md`, `PROPOSALS.md`, `STATE.md` and `HISTORY.md`
(tacplus-dev/roadmap `decisions/repo-roadmap-files-2026-10-27.md`, templates in its `templates/repo/`;
looper#13). The loopers keep them:

- **repo-looper, mechanically:** before the model runs, a missing `STATE.md`, `PROPOSALS.md` or
  `HISTORY.md` is created on main from its template (`<repo>` filled in), never `ROADMAP.md`. After the
  run, a closed issue gets one line at the end of `HISTORY.md`,
  `- <YYYY-MM-DD> looper issue <title> (#N, <commit>)` (the run's last commit on main, if it pushed), and
  each release it made (a new `vX.Y.Z` tag) one more, `- <YYYY-MM-DD> looper release <vX.Y.Z> (<release link>)`.
  These are the looper's own commits on main, made in a scratch worktree and made again if the push is
  rejected.
- **The model** (the prompt's rule 6): updates `STATE.md` when its change changes what it states, puts
  follow-ups, debt and ideas in `PROPOSALS.md`, and never edits `ROADMAP.md` (Jody's, changed only by an
  agent at his request) nor `HISTORY.md`.
- **ROADMAP.md is refused:** the checkout's pre-push hook refuses any push of a commit that touches it,
  to main or any other branch, except the issue's own `looper/<repo>-<issue>` branch, so a checkpoint
  still keeps all the work. Commits already on origin (an agent's, at Jody's request) are not the push's.
- Hub and agent deploys and agent decisions are appended to `HISTORY.md` by the agent, not the looper.

**The CI check** is the reusable workflow `.github/workflows/planning-files.yml`
(`planning-files-check`): it fails if `STATE.md`, `PROPOSALS.md` or `HISTORY.md` is missing, or if
`HISTORY.md` changed since the push's or pull request's base other than by lines added at its end; a
repository with no `ROADMAP.md` yet passes with a warning until an agent adds it. It runs on this
repository, and every tacplus-dev repository calls it from its own `.github/workflows/planning-files.yml`:

```yaml
name: planning-files
on:
  push:
    branches: [main]
  pull_request: {}
permissions:
  contents: read
jobs:
  planning-files:
    uses: tacplus-dev/looper/.github/workflows/planning-files.yml@main
```

```sh
./planning-files-check [BASE]              # at a repository's root: the four files, HISTORY.md append-only since BASE
tests/planning-files.test.sh               # the check against a scratch repository
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
  the head, files nothing. Otherwise one issue `Port SeaBeam <svc> <from>..<to>`, labelled `feature` and
  `approved` (so its looper builds it only once a ROADMAP.md links it),
  listing each commit (sha, link, date, subject) and the instructions: per commit, port it, or say it
  is already covered or not applicable and why; never copy generated code; then set the mark to `<to>`
  and release. Commits after an open port issue's `<to>` get the next issue, `Blocked-by:` that one.
- **The roadmaps first** (looper#14): before filing a port issue, the scan reads the target's ROADMAP.md
  and the platform's (`ROADMAP.md`, `items/`). When one has an entry for the port that is not done (a line
  naming `Port SeaBeam <svc>` whose first linked issue is open, or that links none), it files no port
  issue but, once, *Prioritize the roadmap entry: Port SeaBeam <svc>* (`feature`), quoting and linking the
  entry, with the new commits as the why-now. A roadmap it cannot read files nothing.
- **The realign** (looper#23): a SeaBeam commit that ports tacplus-dev work carries
  `Ported-from: tacplus-dev/<repo>@<sha>` (one line per source commit; tacplus-dev/roadmap
  `items/seabeam-realign-2026-10-29.md`), and is never ported back: the issue leaves it out of its commits
  (naming it as not to port), but its range and so the mark still move past it. A range of nothing but such
  commits files nothing. Fail closed: a commit that names tacplus-dev, or has a malformed trailer, without a
  trailer is listed for a person to decide, and the port issue is labelled `needs-decision`, not `approved`.
- **The flood guard** (looper#23): a scan that would file more than `LOOPER_PORT_MAX_ISSUES` (default 5) issues
  on the targets files none, and opens one *Port scan: flood guard tripped* on this repository (`bug`,
  `needs-decision`) listing them; while it is open, a scan still over the limit files nothing more.
- **No usable mark** (no PROVENANCE.md, no mark in it, or a mark that is not a commit of the source):
  one issue `Port SeaBeam <svc>: no usable mark`, labelled `bug` and `needs-decision`. The scan never guesses a
  baseline; a person records it and closes the issue.
- **Unmapped sources** (and any project under the source group that `ports.yaml` does not list): each
  change is reported once on this repository's issue *Port scan: changes in unmapped SeaBeam sources*
  (`feature`, `needs-decision`), which records the last commit reported per source.
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
looper-dispatch run --for 3420   # the kicker job: a pass every LOOPER_INTERVAL seconds for 57 minutes
looper-dispatch status           # the looper jobs in GitLab, and what is ready (GH_TOKEN, GITLAB_TOKEN)
tests/looper-dispatch.test.sh    # a repository with a job created, pending, waiting or running is busy; a stale looper:in-progress is cleared; GitLab unreadable releases and starts nothing; the kicker's loop (stub gh and curl)
```

The jobs' credentials are tacplus-dev GitLab group CI variables, masked and protected (`GH_TOKEN`,
`CLAUDE_CODE_OAUTH_TOKEN`, and `GITLAB_TOKEN`, with `api` scope: the kicker reads the project's jobs
and starts its pipeline with it, the port scan reads SeaBeam), never baked into the image nor on a
laptop. The model is `LOOPER_MODEL` (default `claude-opus-5-5`).

## Infrastructure

The pipeline is gitlab.com/tacplus-dev/looper. Its jobs run on the group runner 57939705
*tacplus-dev arm64 autoscaler*, whose manager is the GCE VM `gitlab-runner-mgr` (us-central1-b,
project jody1-328023). The manager runs the docker-autoscaler executor with the googlecloud fleeting
plugin, driving its own managed instance group `runner-arm64-tacplus` (template
`runner-arm64-t2a8-v5`, t2a-standard-8): up to 5 workers, size 0 at rest.

- The kicker's job runs around the clock (57 minutes of every hour), so a worker is up even when
  there is no other work (looper#24).
- Changing `max_instances` needs a gitlab-runner restart, and a restart kills running jobs.
- The project's maximum job timeout is 11h (a run's 10h at most, plus the job's hour).

## Later

Doppelganger decides resource requests (more loopers, new repositories) instead of the fixed rules
here.
