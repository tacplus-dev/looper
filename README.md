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
  fails at the end if a pass failed. A pass reads GitHub for the whole org at once (`ready_by_repo` in
  `looper-lib.sh`: one search, one GraphQL query for the blockers' states), since the per-repository
  reads came to about 270 requests a pass, past the token owner's 5000 an hour. Two kicker jobs never overlap (`resource_group: kicker`): the next
  hour's waits for the last. Nothing else runs when there is no ready issue.
- **The pipeline** plans one job per repository with a ready issue (`looper-<repo>-<issue>`), each
  working that repository's next ready issue (by [priority](#priority), then oldest first), and plans first
  the repositories whose next issue is `priority:high` (`looper-dispatch ready`); jobs of one repository never overlap (`resource_group`).
  A repository that already has a looper job created, pending, waiting or running in the project gets
  no other one, and the plan's log says so (`repo-looper --list` reads the project's jobs with
  `GITLAB_TOKEN`, else the job's token; looper#16): a duplicate would only wait for the slot to find its
  issue taken. A job takes its repository's next ready issue when it runs: the planned one if it is
  still ready, else the one that is next now. The job is that repository's parent looper, which also works
  its other ready issues, in parallel when they allow it ([Parent and children](#parent-and-children)).
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
- **`repo-looper`** is the looper of one repository: a parent that runs a child per issue
  ([Parent and children](#parent-and-children)). It takes the issue it was given first, or the next ready one
  ([priority](#priority), then oldest) if that issue is no longer ready, then the others it can plan, and does
  nothing if none is ready. Each child works its issue in its own worktree of the repository at origin/main;
  Claude may run sub-agents in that worktree; only the child's top-level run commits and lands, always on main
  (pre-production; a protected release line with review comes later). Bug fixes on repositories with release
  branches are also offered as backport pull requests.
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
  these scripts. It has **no tacplus binary**: `tacplus` is a wrapper that runs the released tacplus the
  repository's `tacplus.lock` pins, else the newest patch of its floor (`tacplus:` in tacplus.yaml or
  fleet.yaml), in `ghcr.io/tacplus-dev/tacplus/build:<MAJOR.MINOR>`, the build image of that line (which
  has Go and every SDK), always at its latest patch, as a sibling container on the worker's docker socket
  (looper#27; the `tacplus/tacplus` compiler image, which had no Go, is retired, tacplus#193). The binary
  is checked against its release's `checksums.txt` and cached under the work directory. The work
  directory is under the runner's `/builds` bind mount, the same path on the worker and in every
  container, so sibling containers see the same files. `looper-smoke` (run on every image build with
  the host's docker socket) generates a Go repository through it.
- **GitHub credentials in containers** (looper#11): since tacplus 2.4 a repository's `depends` resolve
  through the private `tacplus-dev/registry`, so tacplus clones from GitHub in its container. The wrapper
  gives it, through its environment alone (`DOCKER_GITHUB_CREDS` in `looper-lib.sh`), a git credential
  helper for `https://github.com` and no other host, which answers from `$GH_TOKEN` (else
  `$GITHUB_TOKEN`) when git asks, and drops any other helper for github.com so none stores it. The token
  is only inherited by the container: it is on no command line, in no file and in no image. Any other
  `docker run` of something that clones from GitHub passes the same `"${DOCKER_GITHUB_CREDS[@]}"`.

```sh
tests/tacplus.test.sh                      # which tacplus: the pin, else the floor's newest patch (looked up at most every ten minutes), in build:<line>, never tacplus/tacplus; a checksum mismatch refused; its credentials against a stub git server: github.com gets the token, any other host none, nothing on disk or command line holds it
```

## Issues

| Label | Meaning |
| --- | --- |
| `approved` | someone with write access approved it; the looper works it (a feature: only once it is on a ROADMAP.md) |
| `bug` | the code does not do what it already promises: fixed, and released as a patch |
| `feature` | new behaviour: needs design, Jody's approval and a ROADMAP.md entry; ships in a minor |
| `looper:in-progress` | a looper holds it |
| `looper:stuck` | a run ended without finishing and without progress or a known reason; a person looks |
| `needs-decision` | the looper needs a decision it may not make |
| `priority:high` | taken before the other ready issues (looper#31) |
| `priority:low` | taken after every other ready issue |

Only someone with write access can set a label, so an issue nobody approved is never worked, whoever
opened it and whatever its text says.

### Priority

A repository's ready issues (approved, not held, every `Blocked-by:` closed) are taken `priority:high` first, then
unlabelled, then `priority:low`, oldest first within each (`approved_issues` in `looper-lib.sh`, looper#31); the
looper creates both labels with `bug` and `feature`. Across repositories, the kicker and the plan take a repository
whose next ready issue is `priority:high` before the others, so it gets a runner first when they are short
(`looper-dispatch ready`). Priority only decides what starts next: a running issue is never pre-empted, and a blocked
issue waits whatever its priority. To put new work ahead, label it `priority:high`; a `Blocked-by:` line is for a
real dependency, not for ordering.

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
instead, at most 10h. The pipeline's job for a repository is sized for what its parent may run together
(`repo-looper --job-timeout N`, looper#33): the longest limit of its issue and of the ready issues that could start
beside it (up to `LOOPER_MAX_CHILDREN` in all), plus the plan's 20 minutes and an hour, rounded up to hours, at most
`LOOPER_JOB_MAX_HOURS` (11h). With the default limits that is 6h, room for two 4h children from the start. A
child's limit is capped at the parent's deadline, the job's end less that hour (looper#35): an issue's `Timeout:`
line added after its job was sized gets the time the job has left, and its start comment says so ("limit 8h capped
at 5h by this job"), so the run stops by itself, checkpointed, before GitLab kills the job.

### Parent and children

A repository's looper job is a **parent** that runs **child loopers** for its issues, in parallel when the work
allows (Jody, 2026-10-30, looper#32). Children run in the parent's job, with the same code (`repo-looper --child N`).
The kicker still starts one parent per repository (`resource_group`), and repositories run in parallel as before.

- **The parent plans.** It takes the ready issues in [priority](#priority) order (each one's `Blocked-by:` lines
  closed; the job's own issue first if it is still ready, and any issue a killed run left `looper:in-progress`),
  then decides which can run together and how many:
  - **the areas each will touch:** when there is more than one issue to place, the model (read-only, at most
    `LOOPER_PLAN_TIMEOUT`, 20 minutes) writes for each the paths it will change, generated outputs included
    (`touches N <path>...`), the contracts it changes (`contract N <name>`), and any other conflict it judges
    (`conflict A B <why>`). Two issues that touch the same path (or one under the other) or the same contract, or
    that it names, never run at the same time; an issue whose areas it does not tell runs alone. `STATE.md`,
    `PROPOSALS.md` and `HISTORY.md` do not count: every issue may touch them, and a landing rebases over them;
  - **the runner's CPU and memory:** as many children as the VM holds at `LOOPER_CHILD_CPUS` (2) and
    `LOOPER_CHILD_MEMORY_GB` (4) a child (a t2a-standard-8 worker: 4), never more than `LOOPER_MAX_CHILDREN`
    (6), a safety ceiling only;
  - **the job's time:** in a GitLab job no child starts that would outlast it (`CI_JOB_TIMEOUT` from the job's
    start, `CI_JOB_STARTED_AT`, less the hour the job keeps for itself); the job's own issue always does, and the
    job is sized for the others that are ready with it. When a child ends, the parent plans again and fills its
    slot if an issue's limit still fits.

  Higher priority goes first, but an issue that conflicts with a running one waits while a lower one that does
  not starts. The plan and its reasons are in the job's log (`plan: ...`), in its record (`looper-runs/<time>-plan/`:
  `plan.md`, and the model's `prompt.md` and `claude.log`), and on each issue when there was a choice to make: a
  comment when it starts beside others, or why it is held back (once per reason).
- **Children:** one per issue, each in its own git worktree (`LOOPER_WORK/<repo>/worktrees/N`) on its own branch
  (`looper/<repo>-N`, the name its checkpoints have on origin), running the per-issue flow below unchanged:
  checkpoints and resume, time limit, idle and done, outcomes. Its log lines in the job's log start `[#N]`.
- **Landing is serialized, and the parent owns it** (looper#34): the model lands its commits with
  `repo-looper --repo R --issue N --land` (`--gates CMD` where the repository has no justfile), which queues them
  with the parent's lander and waits for the result. The lander lands one at a time, in the parent's process, not
  the child's: it takes the repository's landing lock, rebases the commits onto the current main, re-runs the
  gates and pushes. A rejected push is rebased and tried again. The lock wait and the gates (over two hours with
  three children on one runner, tacplus 2026-10-30) no longer lose a finished fix: a land still queued or running
  when its child's limit fires (or its run ends) is landed all the same, under the parent's job timeout, which
  waits for the queue before it ends; the lander says on the issue what came of it, and the issue stays `approved`
  for the next run to comment and close. While its land is queued or running a model is not idle. When the rebase conflicts it lands nothing and names the paths: the model rebases, resolves, verifies and
  lands again, or the run ends stuck. Gates that fail, or that change a tracked file, land nothing, nor does an
  uncommitted change: broken work never lands. A push to main from a child's worktree any other way is refused
  (the checkout's pre-push hook, which `--no-verify` skips, as the ROADMAP.md guard). The looper's own commits
  (planning files, `HISTORY.md`) take the same lock.
- **The parent supervises:** as each child ends it logs its outcome (`#N: closed`, `blocked`, `needs-decision`,
  `proposed`, `timeout`, `land-pending`, `landed`, `ended`, `stuck`, `job-gone`), appends `HISTORY.md`'s line for any release the children made, and
  plans again, so a newly ready issue starts while the others run. Each child labels and comments on its own issue
  as below, and its time limit, idle watchdog and outcome are its own: one that times out or sticks does not stop the
  others. A child whose job GitLab no longer runs (looper#21) stops the planning: the job's retry resumes the rest.

### A run's work is never lost

The runner VM is gone after the job, so a run keeps its work in progress on the branch
`looper/<repo>-<issue>` of the repository (never on main):

- **Checkpoint:** everything in the child's worktree, committed or not, is pushed there as one commit, without
  touching the worktree: whenever the model finishes a step (the prompt has it run
  `repo-looper --repo R --issue N --checkpoint "<what is done; what is left>"`), every hour
  (`LOOPER_CHECKPOINT_INTERVAL`), and when the model stops. The model is stopped ten minutes before the
  limit (`LOOPER_STOP_EARLY`) so that last checkpoint always happens.
- **Resume:** a run on an issue whose branch exists starts from it, rebased on main, as uncommitted
  changes on main (in its worktree, on its own branch at origin/main); its prompt has the last checkpoint's message and the issue's last comment. A branch
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

- **Idle:** no output, nothing changed in the checkout and no land of its queued or running for
  `LOOPER_IDLE_MINUTES` (20). Its work is
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
| ended (its limit, or earlier) with its land queued or running (looper#34) | the same, and the parent lands it after the run and comments what came of it (landed, with main's range, or why not); it stays `approved` |
| ended early with progress: it landed a fix, or checkpointed a step other than the one it resumed from (looper#34) | as a time limit: a comment with its last checkpoint; it stays `approved` and the next run resumes |
| went idle after its fix landed: waiting on a land that was done (looper#37) | as an early end with progress: a comment with main's range and its last checkpoint; it stays `approved` and the next run comments and closes |
| went idle (nothing landed or queued) | `looper:stuck`, with a comment that it went idle, the tail of its log and a link to its branch |
| lost its job (GitLab no longer runs it, looper#21) | nothing: its work is checkpointed and the job's retry resumes it |
| ended any other way (no progress) | `looper:stuck`, with a comment linking the job, its `claude.log` artifact and its branch, and the tail of its log |

```sh
tests/repo-looper.test.sh                  # these outcomes, checkpoints and the record, resume, the time limit, idle and done, the planning files, bug or feature, the scan's labels, and the plan skipping a busy repository, priority order, a killed run resumed by its retry, a run whose job GitLab no longer runs stopped; the parent: two independent issues at once, both landed; two touching one file (or one contract, or named by the plan, or of unknown areas, or with room for one) one after the other; a landing conflict rebased and landed again, a rejected push retried, broken work refused; lands queued or running when their children's limits fire landed by the parent, not stuck; a model waiting on its land not idle, nor stuck when it goes quiet after its land landed; an early end with progress resumable, without it stuck; a child's time limit not stopping the others; a child whose issue asks for more time than the job has left capped at the job's deadline, stopped by the looper with a checkpoint and a timeout outcome; the plan in the log, the record and on the issues (stub gh, claude and curl, a local origin)
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
runs `looper-port` (mechanical: GitLab API with `SEABEAM_READ_TOKEN`, else `GITLAB_TOKEN`; issues with `GH_TOKEN`):

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
SEABEAM_READ_TOKEN=... ./looper-port --dry-run   # what it would file, filing nothing
tests/looper-port.test.sh                  # the scan against fixtures (stub gh and curl)
```

## Build pipeline

A build is the only verdict (tacplus-dev/roadmap `decisions/deterministic-builds-2026-10-27.md`, looper#17): it
takes a commit as it is, in the build image the repository pins, with no agent, and says pass or fail; on a
release it also publishes the image. It never changes the repository. It is the GitLab project
gitlab.com/tacplus-dev/build, whose `.gitlab-ci.yml` is `ci/build.gitlab-ci.yml` here, copied there as is; its
jobs run `looper-build`, from this image.

- **Started** from the API or the web with **inputs** `repo`, `sha` and, for a release, `tag`. The project forbids
  pipeline variables (as this group does); inputs are typed and checked against their pattern before any job runs.
  A push to the project starts nothing.

  ```sh
  curl -H "PRIVATE-TOKEN: <a token that may run its pipeline>" -H 'Content-Type: application/json' \
    -X POST https://gitlab.com/api/v4/projects/tacplus-dev%2Fbuild/pipeline \
    -d '{"ref": "main", "inputs": {"repo": "kernel", "sha": "<40 hex>"}}'
  ```
- **`plan`** fetches exactly that commit and reads its `tacplus.lock` (as tacplus validates it: an exact release,
  the build image by digest, of the same line). No pin, or a bad one, is a **fail** verdict, never a guess. It
  writes the child pipeline: one `gates` job whose `image:` is the pinned digest.
- **`gates`**, in the pinned build image: `just gates` on the commit. It fails if the commit has no `gates` recipe,
  if a gate fails, or if the build changed a tracked file (`git status --porcelain --untracked-files=no`) or moved
  HEAD. Its log is the artifact `gates.log`, and the job's log.
- **`pending`, `report-pass`, `report-fail`** set the GitHub commit status, context `tacplus-dev/build`, linking
  the pipeline, with the failure's reason as its description. This is the only thing a build writes to GitHub.
- **`publish`**, on a release (below), once the gates passed: `docker buildx build` of the repository's
  `Dockerfile` for `linux/amd64` and `linux/arm64`, pushed as `us-docker.pkg.dev/jody1-328023/tacplus/<repo>:X.Y.Z`
  (tacplus-dev/tacplus#223), its digest recorded in the artifact `image`.
- **The same commit gives the same verdict and digest.** The gates image is pinned by digest. The image is built
  with every timestamp the commit's (`SOURCE_DATE_EPOCH`, `rewrite-timestamp=true`), without provenance or SBOM
  attestations (which record the build's time and builder), and by a BuildKit pinned by digest. So publish first
  builds the image to a file, then pushes it, and fails unless both have one digest. A release already in the
  registry under another digest fails rather than being overwritten. The documented exception: a `Dockerfile`
  whose bases are not pinned by digest, or whose steps fetch "latest", builds what its bases are that day.
- **Smoke** (looper#36): the Mac runner end to end, before tacplus-dev/tacplus#195's `swift:` and darwin/arm64
  `rust:` builds rely on it. Start the pipeline from the web on `main` with the input `smoke: true` and no `repo`,
  `sha` or `tag`, then play its one job, **`macos-smoke`** (manual; tag `macos`, image
  `ghcr.io/cirruslabs/macos-tahoe-xcode:27.1`). It fails unless `uname -m` is `arm64`, `sw_vers` prints the guest
  macOS, `xcodebuild -version` prints Xcode 27.x and `swift --version` prints a Swift version. That pipeline holds
  none of the build's jobs (no status, no publish), and the job reads no credential, has no `id_tokens` and needs
  nothing. A push, an API or trigger run, and any run with `repo`, `sha` or `tag` never create it; `smoke: true`
  with any of them creates no pipeline at all.

**Credentials.** A build reads GitHub only through the read-only `tacplus-reader` app (looper#12:
`TACPLUS_READER_APP_ID`, `TACPLUS_READER_INSTALLATION_ID` and the file variable `TACPLUS_READER_APP_KEY`, protected
variables of tacplus-dev/build). Each job mints its own one-hour installation token with only what it needs:
`contents: read` for a fetch, `statuses: write` on the one repository for a status. It holds nothing that can
change a repository:

- every job refuses to run beside a write credential (`GH_TOKEN`, `GITHUB_TOKEN`, `GITLAB_TOKEN`,
  `CLAUDE_CODE_OAUTH_TOKEN`, `ANTHROPIC_API_KEY`, `GHCR_PUSH_TOKEN`, or any variable whose value looks like a
  personal or OAuth token: `ghp_`, `github_pat_`, `gho_`, `ghu_`, `glpat-`);
- before the gates run, the source credential must **fail** to push (a `git push --dry-run`, which GitHub refuses
  to a read-only token), or the build fails. So a gate that pushes cannot. Then the app's key file is deleted, and
  GitLab's job token (and the clone URL that holds it) are dropped, so the repository's code holds only the
  read-only token;
- **publish** has no registry secret: its GitLab `id_token` (`GCP_ID_TOKEN`) is exchanged through Workload Identity
  Federation (`GCP_WIF_PROVIDER`, a project variable, and `GCP_PUBLISH_SA` if the hub's binding goes through a
  service account) for a short-lived token holding `artifactregistry.writer` on that repository. GCP trusts only
  this project's protected tags.

**A release** (the release flow, looper#17): the looper tags the commit `vX.Y.Z` on GitHub after a green build, then
creates the protected tag `<repo>/vX.Y.Z` in tacplus-dev/build (one project builds every repository, so its tags
are per repository) and starts the pipeline on that tag with `"tag": "vX.Y.Z"`. The build checks that the GitHub
tag names `sha`, runs the gates, and publishes; the looper then creates the GitHub release.

```sh
looper-build plan | gates | status STATE [TEXT] | publish [--dry-run]   # what the jobs run; --dry-run builds the release image and pushes nothing
tests/looper-build.test.sh   # against a local origin and a stub GitHub (the app's JWT verified): same commit, same verdict; a tracked-file change, a push, a write credential, a credential that can push, no pin or a bad one all fail; the commit status; publish (stub buildx and WIF), and with a real buildx the same digest twice
```

**The build runner** (Jody, 2026-10-29: jobs that hold credentials never share a runner VM with an agent's job). A
second runner entry on `gitlab-runner-mgr`, which the hub applies (restarting the manager kills running jobs, so at
a moment when no looper job runs). It is a **project** runner of tacplus-dev/build, registered with
`tag_list=arm64,build` and `run_untagged=false`. Every job of the pipeline carries `tags: [arm64, build]`, which the
loopers' runner (`arm64, autoscale`) never takes. Each job gets a fresh VM, deleted after it:

```toml
[[runners]]
  name = "tacplus-dev arm64 build (gitlab-runner-mgr, MIG runner-arm64-build)"
  url = "https://gitlab.com"
  token = "glrt-..."   # the build runner's own authentication token (POST /user/runners, project_type, project 88268985)
  executor = "docker-autoscaler"
  limit = 5
  [runners.docker]
    image = "alpine:3.20"
    privileged = false
    volumes = ["/var/run/docker.sock:/var/run/docker.sock", "/builds:/builds", "/cache"]
  [runners.autoscaler]
    plugin = "googlecloud"   # the same fleeting plugin, and version, as the loopers' entry
    capacity_per_instance = 1
    max_use_count = 1
    max_instances = 5
    [runners.autoscaler.plugin_config]
      name = "runner-arm64-build"
      project = "jody1-328023"
      zone = "us-central1-b"
    [runners.autoscaler.connector_config]
      username = "runner"    # as the loopers' entry
    [[runners.autoscaler.policy]]
      idle_count = 0
      idle_time = "0s"
```

Its instance group `runner-arm64-build` (size 0 at rest) uses a template that is `runner-arm64-t2a8-v5` in every
respect but one: the VM has **no service account and no scopes** (`--no-service-account --no-scopes`), so a build
that reaches the metadata server gets no Google token. fleet-seatrials' `deploy` runner (tag `deploy`) is the same
stanza with its own instance group (fleet-seatrials#18).

**The Mac runner** (live since 2026-10-31, for tacplus-dev/tacplus#195): project runner 58154450 of tacplus-dev/build,
"jody-desktop macOS (Tart)", tag `macos`, protected refs only, untagged jobs off, at most 2 VMs at once. Its Tart
custom executor runs each job in a fresh macOS VM cloned from the job's `image:` and deleted after it. Only
`macos-smoke` uses it so far. Its setup and record are `mac-runner/` in gitlab.com/tacplus-dev/build.

**One-time setup of tacplus-dev/build** (done 2026-10-29 unless marked): the reader app's variables (looper#12);
pipeline variables forbidden; job tokens cannot push to the project; group runners off, so only the build runner
takes its jobs; release tags `*/v*` protected (Maintainers create them); `.gitlab-ci.yml` from `ci/build.gitlab-ci.yml`.
Left to the hub: the build runner above, and `GCP_WIF_PROVIDER` with its binding (tacplus-dev/tacplus#223).

## Looper identity

A looper writes as its own repository's bot, not as Jody (tacplus-dev/roadmap `items/looper-identity-2026-10-29.md`, and
`decisions/looper-identity-panel-2026-10-29/SYNTHESIS.md`, which takes precedence; looper#28). **The pilot is kernel**: its
commits, pull requests, comments and labels are `kernel-looper[bot]`'s, and nothing falls back to Jody's `GH_TOKEN` or
`GITLAB_TOKEN`. Every other repository stays on the pipeline above until a follow-up moves it.

- **The GitLab project `gitlab.com/tacplus-dev/kernel`** holds no code (the code is on GitHub, which hosts everything open
  source), only its `.gitlab-ci.yml`: `ci/looper.gitlab-ci.yml` here, copied as is (its `LOOPER_REPO` is the project's
  name). Its main is protected and changed only by Jody or the hub; pipeline variables are forbidden (`no_one_allowed`); its
  schedule starts it. There is no GitLab write token at all.
- **One run at a time:** the schedule's (or the web's) pipeline has one job, `run`, which runs the three jobs below as a child
  pipeline of the same file and holds the resource group `looper` until the child ends. No issue is claimed: runs never
  overlap, and an issue whose pull request (`looper/kernel-<n>`) is open is in review, not ready.
- **`prepare`** (`looper-identity prepare`, LLM-free): exchanges the job's GitLab `id_token` through Workload Identity
  Federation, has Cloud KMS sign the `tacplus-reader` app's JWT and mints a one-hour installation token with
  `contents`, `issues` and `metadata` **read**. It takes the input `issue` if it is ready, else the next ready issue ([priority](#priority), then oldest), and
  hands both to `think` as a dotenv report (`access: none`, expiring in an hour).
- **`think`** (`repo-looper --think`): the model and the gates. **No identity:** no `id_tokens`, no variable but the model's
  `CLAUDE_CODE_OAUTH_TOKEN`, scoped to the environment `looper-think`. It refuses to run beside a write credential, an
  `id_token` or anything shaped like a personal token; GitLab's job token is dropped; the reader token must **fail** to push
  (`git push --dry-run`). The model leaves its change in the checkout and writes its comment and outcome (`pr` with a title,
  `question`, `blocked` with its `Blocked-by:` lines). On a pull request the looper appends the issue's `HISTORY.md` line and
  runs the gates on the change; they must pass, and must not change the tree. It writes `think/patch` (from `think/base`,
  origin/main) and `think/tree`, **the tested tree**. A run that hits its limit or ends without an outcome is `timeout` or
  `stuck`, its change kept.
- **`commit`** (`looper-identity commit`, LLM-free, compiles nothing, on protected main): applies the patch to its base with
  no hooks and **refuses it unless the tree is the tested one** (or if it touches `ROADMAP.md`). It exchanges its own
  `id_token` at its start, then unsets it; the token's issuer, audience, age (at most 5 minutes) and GitLab's own word for the
  project, ref and source must match the job, so a variable overriding GitLab's own is refused. KMS signs the
  `kernel-looper` app's JWT, and each step mints its own installation token for `repositories: [kernel]` alone, with that
  step's permissions (`contents` to push, `pull_requests` for the pull request, `issues` for the comment). By the outcome:
  - `pr`: pushes `looper/kernel-<n>` (authored by `kernel-looper[bot]`), opens the pull request (`Closes #<n>`), enables
    squash auto-merge, and starts `tacplus-dev/build` on its head with the build trigger token. GitHub squash-merges once
    the required check passes; that commit is GitHub's, so it is **Verified**, and the merge closes the issue.
  - `question`: the comment, and `needs-decision`. `blocked`: the `Blocked-by:` lines the body lacks, and the comment.
  - `timeout`: the change kept on `looper/kernel-<n>` (the next run resumes from it), and a comment. `stuck` (and a think
    job that failed): the same, and `looper:stuck`.
  The outcome is data: its type picks one of these fixed actions, and its text is only ever posted as a comment.
- **Refused:** a job that holds Jody's tokens or the model's credential (in `prepare` or `commit`); a pipeline that is not
  the project's own child pipeline on protected main (`CI_PIPELINE_SOURCE` and the `id_token`'s `pipeline_source` must be
  `parent_pipeline`): a pipeline from the API, a trigger or a push is how variables come in.

```sh
looper-identity prepare | commit                                 # what the jobs run (README: the environment)
repo-looper --repo kernel --issue N --think DIR                  # the think job
tests/looper-identity.test.sh   # prepare and commit against a local origin, a stub GitHub (each app's JWT verified, kernel-looper installed on kernel alone) and a stub WIF and KMS (a key signs only for the project bound to it): a tree mismatch, a ROADMAP.md change, a token for another repository, a pipeline from elsewhere or a variable overriding GitLab's, an old or foreign id_token, Jody's tokens all refused; the pull request, auto-merge, build, question, blocked, timeout and stuck
tests/repo-looper.test.sh       # also the think job: no identity (Jody's tokens, an id_token, a token that can push all refused), nothing written to GitHub, the outcome, the patch that gives the tested tree, gates that fail or change the tree
```

### Setting it up (the hub, with Jody's approval as recorded on looper#28)

`P=jody1-328023`, `PN=$(gcloud projects describe $P --format='value(projectNumber)')`, `NS` the tacplus-dev group's id
(`curl -s https://gitlab.com/api/v4/groups/tacplus-dev | jq .id`), `KP` the kernel project's id once created, and
`PROVIDER=projects/$PN/locations/global/workloadIdentityPools/gitlab-loopers/providers/gitlab-com`.

**Workload Identity Federation**: a pool of its own, with one provider, for gitlab.com. The condition pins tacplus-dev's
namespace and protected refs; the composite attribute `looper` is what each key's binding matches (SYNTHESIS 3, 4, 18, 20):

```sh
gcloud iam workload-identity-pools create gitlab-loopers --project=$P --location=global --display-name="gitlab.com loopers"
gcloud iam workload-identity-pools providers create-oidc gitlab-com --project=$P --location=global \
  --workload-identity-pool=gitlab-loopers --issuer-uri=https://gitlab.com \
  --attribute-mapping='google.subject=assertion.project_id + ":" + assertion.job_id,attribute.namespace_id=assertion.namespace_id,attribute.looper=assertion.project_id + ":" + assertion.ref + ":" + assertion.ref_protected + ":" + assertion.pipeline_source' \
  --attribute-condition="assertion.namespace_id == \"$NS\" && assertion.ref_protected == \"true\""
```

The jobs' `id_tokens` audience is the provider's default, `https://iam.googleapis.com/$PROVIDER`; `GCP_WIF_PROVIDER` is
`$PROVIDER`. Only Jody holds admin on the pool and `setIamPolicy` on the key ring.

**The apps' keys in Cloud KMS.** Jody creates the GitHub App `kernel-looper` (private; installed only on kernel;
permissions contents, issues and pull requests **write**, metadata read; no webhook) and downloads its private key. The
hub imports it once, as a non-exportable key, and deletes the file; it never exists outside Google again (SYNTHESIS 10). The
`tacplus-reader` app's key is imported the same way, as `tacplus-reader`:

```sh
gcloud kms keyrings create looper --location=us --project=$P
gcloud kms keys create kernel-looper --keyring=looper --location=us --project=$P --purpose=asymmetric-signing \
  --default-algorithm=rsa-sign-pkcs1-2048-sha256 --protection-level=software --import-only --skip-initial-version-creation
gcloud kms import-jobs create kernel-looper-import --keyring=looper --location=us --project=$P \
  --import-method=rsa-oaep-3072-sha256-aes-256 --protection-level=software
openssl pkcs8 -topk8 -nocrypt -inform PEM -outform DER -in kernel-looper.private-key.pem -out kernel-looper.der
gcloud kms keys versions import --import-job=kernel-looper-import --keyring=looper --location=us --project=$P \
  --key=kernel-looper --algorithm=rsa-sign-pkcs1-2048-sha256 --target-key-file=kernel-looper.der   # version 1
shred -u kernel-looper.private-key.pem kernel-looper.der
# Each key's own binding, never at the key ring or project: kernel's protected main, in its own child pipeline, alone.
gcloud kms keys add-iam-policy-binding kernel-looper --keyring=looper --location=us --project=$P --role=roles/cloudkms.signer \
  --member="principalSet://iam.googleapis.com/projects/$PN/locations/global/workloadIdentityPools/gitlab-loopers/attribute.looper/$KP:main:true:parent_pipeline"
# The reader: every project of the namespace, on protected refs (the pool's condition).
gcloud kms keys add-iam-policy-binding tacplus-reader --keyring=looper --location=us --project=$P --role=roles/cloudkms.signer \
  --member="principalSet://iam.googleapis.com/projects/$PN/locations/global/workloadIdentityPools/gitlab-loopers/attribute.namespace_id/$NS"
```

Data Access audit logs on, for KMS and the token exchange (`gcloud projects get-iam-policy $P --format=yaml > policy.yaml`, add
this, then `gcloud projects set-iam-policy $P policy.yaml`):

```yaml
auditConfigs:
- service: cloudkms.googleapis.com
  auditLogConfigs: [{logType: DATA_READ}, {logType: DATA_WRITE}, {logType: ADMIN_READ}]
- service: sts.googleapis.com
  auditLogConfigs: [{logType: DATA_READ}, {logType: DATA_WRITE}, {logType: ADMIN_READ}]
```

**The GitLab project** (`G=https://gitlab.com/api/v4`, `H="PRIVATE-TOKEN: <Jody's or the hub's token>"`):

```sh
curl -sH "$H" -X POST $G/projects -d name=kernel -d path=kernel -d namespace_id=$NS -d visibility=private \
  -d shared_runners_enabled=false -d group_runners_enabled=false     # its id is $KP
curl -sH "$H" -X PUT $G/projects/$KP -d ci_pipeline_variables_minimum_override_role=no_one_allowed \
  -d restrict_user_defined_variables=true
curl -sH "$H" -X POST $G/projects/$KP/repository/files/.gitlab-ci.yml -d branch=main -d commit_message="looper (looper#28)" \
  --data-urlencode content@ci/looper.gitlab-ci.yml
curl -sH "$H" -X POST $G/projects/$KP/protected_branches -d name=main -d push_access_level=40 -d merge_access_level=40
for v in "GCP_WIF_PROVIDER=$PROVIDER" "LOOPER_KMS_KEYRING=projects/$P/locations/us/keyRings/looper" \
         LOOPER_APP_ID=<kernel-looper's app id> LOOPER_INSTALLATION_ID=<its installation on kernel> \
         TACPLUS_READER_APP_ID=<the reader's app id> TACPLUS_READER_INSTALLATION_ID=<its installation>; do
  curl -sH "$H" -X POST $G/projects/$KP/variables -d key="${v%%=*}" --data-urlencode value="${v#*=}" -d protected=false
done   # names, not secrets: no protected variable reaches the think job
curl -sH "$H" -X POST $G/projects/$KP/variables -d key=CLAUDE_CODE_OAUTH_TOKEN --data-urlencode value=<the model's token> \
  -d protected=true -d masked=true -d environment_scope=looper-think
curl -sH "$H" -X POST $G/projects/$KP/variables -d key=BUILD_TRIGGER_TOKEN --data-urlencode value=<the build trigger token> \
  -d protected=true -d masked=true -d environment_scope=looper-commit
curl -sH "$H" -X POST $G/projects/$KP/pipeline_schedules -d description=looper -d ref=main -d cron="7 * * * *" \
  -d cron_timezone=UTC -d active=true
curl -sH "$H" -X POST $G/projects/$KP/runners -d runner_id=<the build runner's id>     # below
```

**The build trigger token** (SYNTHESIS 11, 12): a pipeline trigger of `tacplus-dev/build`, owned by a bot user of its own
(a free gitlab.com account, a member of `tacplus-dev/build` alone, never Jody), created with that user's token, which is then
revoked: `curl -H "PRIVATE-TOKEN: <the bot's>" -X POST $G/projects/tacplus-dev%2Fbuild/triggers -d description=kernel-looper`.
The commit job starts the build with it and inputs (`inputs[repo]`, `inputs[sha]`; the trigger API takes inputs). GitLab
runs a triggered pipeline as the token's owner, and on a protected main that owner must be allowed to merge to it, which
GitLab Free grants by role: **the bot needs Maintainer on `tacplus-dev/build`**, not Developer (looper#28; PROPOSALS.md).

**The runner:** one ephemeral VM per job, unprivileged. The build runner (above: `max_use_count = 1`, a VM with no service
account and no scopes, deleted after its job) is enabled on kernel's project too; every job of the pipeline carries
`tags: [arm64, build]`.

**GitHub, on kernel** (public, so GitHub Free allows all of it; the hub, once Jody says the pilot is ready). The required
check is the build's status, from the `tacplus-reader` app alone; main requires signed commits; squash only:

```sh
gh api -X PUT repos/tacplus-dev/kernel/branches/main/protection --input - <<JSON
{"required_status_checks": {"strict": false, "checks": [{"context": "tacplus-dev/build", "app_id": <the reader's app id>}]},
 "enforce_admins": false, "required_pull_request_reviews": null, "restrictions": null}
JSON
gh api -X POST repos/tacplus-dev/kernel/branches/main/protection/required_signatures
gh api -X PATCH repos/tacplus-dev/kernel -F allow_squash_merge=true -F allow_merge_commit=false -F allow_rebase_merge=false \
  -F allow_auto_merge=true -F delete_branch_on_merge=true
```

Then one real kernel issue end to end (a pull request by `kernel-looper[bot]`, squash-merged once the build passed, its
commit Verified on main), and a follow-up issue for every other repository; Jody's group tokens are deleted after that.

## Running it

```sh
looper-dispatch run --for 3420   # the kicker job: a pass every LOOPER_INTERVAL seconds for 57 minutes
looper-dispatch status           # the looper jobs in GitLab, and what is ready (GH_TOKEN, GITLAB_TOKEN)
looper-dispatch ready            # each repository's next ready issue, priority:high repositories first (GH_TOKEN): the plan's order
tests/looper-dispatch.test.sh    # a repository with a job created, pending, waiting or running is busy; a stale looper:in-progress is cleared; GitLab or GitHub unreadable releases and starts nothing; ready and blocked issues; priority across repositories; a pass's GitHub calls do not grow with the issues; the kicker's loop (stub gh and curl)
```

The jobs' credentials are CI variables of the project gitlab.com/tacplus-dev/looper, masked and protected,
never baked into the image nor on a laptop ([Credentials](#credentials)). They are no group variables (moved
2026-10-29, looper#17; the ci-on-gitlab addendum): a group variable reaches every pipeline of the group, the
builds' too. The model is `LOOPER_MODEL` (default `claude-opus-5-5`).

### Credentials

Every looper job's model runs on the same VM, as the same user, as the job that holds its credentials, so whatever
a job's token may do, an agent may do (looper#25). The model's environment holds no GitLab credential: `repo-looper`
withholds `GITLAB_TOKEN`, `LOOPER_TRIGGER_TOKEN`, `SEABEAM_READ_TOKEN`, GitLab's job token and the variables that
carry it, and any `*ID_TOKEN` (`MODEL_WITHHELD`), and keeps them for its own reads of GitLab. That is not a boundary
(the model could read its parent's environment): **the boundary is each token's reach**, which is this project's
and nothing else's, with only the scopes its job uses.

| Variable | What it is | Who uses it |
|---|---|---|
| `GITLAB_TOKEN` | a personal access token of the bot user `tacplus-looper-bot`, scope `read_api` only, the bot a **Reporter** of tacplus-dev/looper alone | the plan (`repo-looper --list`) and each parent's job poll read the project's jobs; the kicker reads them too |
| `LOOPER_TRIGGER_TOKEN` | a pipeline trigger token of tacplus-dev/looper (`glptt-`), environment scope `kicker` | the kicker starts the pipeline with it (`POST /projects/:id/trigger/pipeline`; the token is on no command line) |
| `SEABEAM_READ_TOKEN` | a personal access token of the bot user `tacplus-port-reader`, scope `read_api` only, the bot a **Reporter** of `seabeam/schematic/platform/services` alone, environment scope `port-scan` | the port scan reads the SeaBeam sources |
| `GH_TOKEN`, `CLAUDE_CODE_OAUTH_TOKEN` | as before | GitHub, the model |

A Reporter with `read_api` reads the project's code, pipelines and jobs. It cannot read CI variables (Maintainer),
play a manual job, start a pipeline or change a setting, and it reaches no other project: not fleet-seatrials' protected
variables nor its `apply` jobs. The trigger token can do one thing, start this project's pipeline. A triggered pipeline
runs as the trigger's owner, and on protected main only one allowed to merge to it may run one, so it is Jody's, as the
schedules are: the pipelines run as Jody as they do today (their bot identity is the looper-identity follow-up,
looper#28). Without `LOOPER_TRIGGER_TOKEN` the kicker starts the pipeline with `GITLAB_TOKEN`, and without
`SEABEAM_READ_TOKEN` the port scan reads with `GITLAB_TOKEN`: both work with today's token until the switch below.
gitlab.com's Free tier has no project or group access tokens, hence the bot users (free gitlab.com accounts, never
Jody, each a member of its one project or group).

**Setting them up** (Jody; the values go from GitLab straight into the variables, no agent handles them).
`G=https://gitlab.com/api/v4`, `H="PRIVATE-TOKEN: <Jody's token>"`, `L=tacplus-dev%2Flooper`:

1. The pipeline file of gitlab.com/tacplus-dev/looper (its `.gitlab-ci.yml`, outside this repository): `looper-kick`
   gets `environment: {name: kicker, action: prepare}` and `looper-port` gets `environment: {name: port-scan,
   action: prepare}`, so only those jobs receive their variables; their comments' "the group GITLAB_TOKEN (api
   scope)" becomes this section's tokens.
2. The trigger (Settings, CI/CD, Pipeline trigger tokens, description `kicker`, or the API), stored as is:

   ```sh
   T="$(curl -sfH "$H" -X POST $G/projects/$L/triggers -d description=kicker | jq -r .token)"
   curl -sfH "$H" -X POST $G/projects/$L/variables -d key=LOOPER_TRIGGER_TOKEN --data-urlencode value="$T" \
     -d protected=true -d masked=true -d environment_scope=kicker >/dev/null; unset T
   ```
3. The bot users `tacplus-looper-bot` and `tacplus-port-reader` (sign up, each with an address of Jody's), then their
   memberships, Reporter (`access_level=20`), expiring within a year:

   ```sh
   curl -sfH "$H" -X POST $G/projects/$L/members -d user_id=<tacplus-looper-bot's id> -d access_level=20 -d expires_at=<date>
   curl -sfH "$H" -X POST $G/groups/seabeam%2Fschematic%2Fplatform%2Fservices/members -d user_id=<tacplus-port-reader's id> \
     -d access_level=20 -d expires_at=<date>
   ```
4. Signed in as each bot, a personal access token with the one scope `read_api` (User settings, Access tokens; name
   `looper-jobs` and `port-scan`, expiring within a year), stored by Jody: `SEABEAM_READ_TOKEN` as a new variable
   (`-d protected=true -d masked=true -d environment_scope=port-scan`), then `GITLAB_TOKEN` replaced
   (`curl -sfH "$H" -X PUT $G/projects/$L/variables/GITLAB_TOKEN --data-urlencode value=<the bot's token>`, protected,
   masked, scope `*`).
5. Checked on the next pipeline: the plan's log lists jobs, the kicker's says `started the tacplus-dev/looper
   pipeline`, the port scan files or finds nothing new; `curl -sH "PRIVATE-TOKEN: <the bot's>" $G/projects/<fleet-seatrials' id>`
   is a 404. Then Jody revokes `looper-runtime`, the token the jobs held before (`api`, `write_repository`, Jody's
   own, Owner of the group).

**The runner VMs' Google account.** The loopers' workers (instance group `runner-arm64-tacplus`, template
`runner-arm64-t2a8-v5`) run as `build-box@jody1-328023.iam.gserviceaccount.com` with the `cloud-platform` scope,
and any agent may use it through the metadata server. As of 2026-10-30 it may, in jody1-328023 (`testIamPermissions`
from a looper job): upload to Artifact Registry (so overwrite a release the build pipeline published) and create,
read and delete objects in any bucket of the project, the Cloud Build source bucket `jody1-328023_cloudbuild` among
them. The loopers need none of that: their images are on ghcr.io, a build publishes through its own federated
identity ([Build pipeline](#build-pipeline)), and fleet-seatrials deploys through its own. So their workers get an
account of their own that may at most pull the tacplus build images (the hub, `P=jody1-328023`):

```sh
gcloud iam service-accounts create looper-runner --project=$P --display-name="tacplus-dev looper workers (looper#25)"
gcloud artifacts repositories add-iam-policy-binding tacplus --location=us --project=$P \
  --member=serviceAccount:looper-runner@$P.iam.gserviceaccount.com --role=roles/artifactregistry.reader
gcloud compute instance-templates create runner-arm64-t2a8-v6 --project=$P --source-instance-template=runner-arm64-t2a8-v5 \
  --service-account=looper-runner@$P.iam.gserviceaccount.com --scopes=cloud-platform
gcloud compute instance-groups managed set-instance-template runner-arm64-tacplus --project=$P --zone=us-central1-b \
  --template=runner-arm64-t2a8-v6
```

New workers take the new template (no gitlab-runner restart; a running worker keeps build-box until it is deleted).
In the next looper job `gcloud auth list` names `looper-runner`, and the `testIamPermissions` of
`projects/jody1-328023` grants none of `artifactregistry.repositories.uploadArtifacts`, `storage.objects.create`,
`storage.objects.get`, `storage.objects.list`. build-box itself keeps its roles for whatever else runs as it; the
hub reviews them, but no looper VM holds it.

## Infrastructure

The pipeline is gitlab.com/tacplus-dev/looper. Its jobs run on the group runner 57939705
*tacplus-dev arm64 autoscaler*, whose manager is the GCE VM `gitlab-runner-mgr` (us-central1-b,
project jody1-328023). The manager runs the docker-autoscaler executor with the googlecloud fleeting
plugin, driving its own managed instance group `runner-arm64-tacplus` (template
`runner-arm64-t2a8-v5`, t2a-standard-8): up to 5 workers, size 0 at rest.

- The workers run as their own Google account, `looper-runner`, which may only pull the tacplus build images
  (once the hub applies [Credentials](#credentials); until then, `build-box`).
- The kicker's job runs around the clock (57 minutes of every hour), so a worker is up even when
  there is no other work (looper#24).
- Changing `max_instances` needs a gitlab-runner restart, and a restart kills running jobs.
- The project's maximum job timeout is 11h (a run's 10h at most, plus the job's hour).

## Later

Doppelganger decides resource requests (more loopers, new repositories) instead of the fixed rules
here.
