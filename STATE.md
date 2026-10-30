# State: looper

Overwritten to stay current (loopers and agents). Last updated: 2026-10-30 by looper (#25).

- **Version / line:** unreleased (no tags); the image `ghcr.io/tacplus-dev/looper:main` is built FROM the tacplus
  `build:2.5` environment (#1, #26); no tacplus floor of its own (the `tacplus` wrapper runs each repository's floor)
- **Works:** the kicker (`looper-dispatch`, in the image) runs as the GitLab pipeline's hourly kicker schedule, a
  pass every 3 minutes that reads GitHub for the whole org in three requests, never two kicker jobs at once, nothing on
  the Mac (#24); it starts the pipeline; neither it nor the pipeline's plan
  (`repo-looper --list`) starts another job for a repository whose looper job is created, pending, waiting
  for its `resource_group` or running, and a planned job whose issue was taken meanwhile works the next
  ready one (#16); priority labels (#31): ready issues are taken `priority:high`, then unlabelled, then
  `priority:low`, oldest first within each, and across repositories `looper-dispatch ready` (the kicker's order)
  puts first a repository whose next ready issue is `priority:high`; a running issue is never pre-empted; a run killed outright no longer leaves `looper:in-progress` behind: the job for its issue
  resumes it when no other looper job of the repository is active, and `looper-dispatch run` clears the label
  from an issue no looper job holds (#20); a run whose job GitLab no longer reports running (marked failed while
  its container goes on) checkpoints and stops within one poll, pushing and commenting nothing, so it cannot race
  its retry (#21); each repository's looper job is a parent that runs a child per issue, in parallel when the work
  allows (#32): it plans from the issues' `Blocked-by` lines, the areas the model says each will touch (paths,
  generated outputs, contracts, other conflicts), the runner's CPU and memory and the job's remaining time (from the job's start; the job sized by
  `--job-timeout` for the longest limit among the ready issues, 6h with the defaults, so two 4h children start together, #33), logs
  the plan and its reasons (job log, `looper-runs/<time>-plan/`, the issues), runs each child in its own worktree and
  branch, serializes landing (`repo-looper --land`: lock, rebase, gates, push; a direct push to main from a
  worktree is refused), which the parent owns (#34): `--land` queues with the parent's lander, so a land still
  queued or running when its child's limit fires is landed all the same and reported on the issue, and the parent
  waits for the queue before the job ends; it plans again as each child ends; `repo-looper` works each repository's
  `approved` issues (checkpoints and resume, per-issue time limit, idle and done watchdog, Blocked-by outcomes, one or more,
  also from a run that pushed nothing because the issue waits on another, #22; a run that ends with its land
  queued, or early with progress, a fix landed or a new step checkpointed, stays approved and resumes; only one
  that went idle or made no progress is `looper:stuck`, #34);
  it appends HISTORY.md's line for each closed issue and release, creates missing planning files from the
  tacplus-dev/roadmap templates, and refuses a push that touches ROADMAP.md (#13); the nightly scan; the hourly
  SeaBeam port scan (stratum only, #5), which never ports back a SeaBeam commit
  trailered `Ported-from: tacplus-dev/<repo>@<sha>` (the realign), sends one that names tacplus-dev without it to
  `needs-decision`, and files nothing past a flood guard of 5 issues (#23); the `tacplus` wrapper with GitHub credentials for the compiler container
  (#11); the reusable planning-files CI check (`.github/workflows/planning-files.yml`, #13); the issue flow (#14):
  `bug` and `feature` labels in every repository, unlabelled issues classified first, bugs fixed and released as
  the next patch, features built only when a ROADMAP.md links them (else a design proposal and `needs-decision`),
  the scans file bugs as `bug`, never approve a feature, and read the roadmaps before opening an issue; the build
  pipeline (#17): `looper-build` and `ci/build.gitlab-ci.yml`, the `.gitlab-ci.yml` of gitlab.com/tacplus-dev/build
  (started with inputs `repo`, `sha`, `tag`): the commit's gates in its pinned build image, no agent, read-only
  source through the `tacplus-reader` app, a fail verdict without a pin, the GitHub commit status, and on a release
  a reproducible image published to Artifact Registry through WIF; tested against a local origin and stub GitHub,
  and with a real buildx (same commit, same digest). The looper identity pilot (#28), built and tested, not yet
  deployed: kernel's GitLab project (`ci/looper.gitlab-ci.yml`) runs `looper-identity prepare` (read-only
  `tacplus-reader` token, KMS-signed JWT through WIF), `repo-looper --think` (the model and the gates, no identity:
  outcome, patch, tested tree) and `looper-identity commit` (tree check, then `kernel-looper[bot]`: branch, pull
  request with squash auto-merge, build trigger, comment, labels); one run at a time, in a child pipeline. The loopers' `GH_TOKEN`, `GITLAB_TOKEN` and
  `CLAUDE_CODE_OAUTH_TOKEN` are project variables of gitlab.com/tacplus-dev/looper, no longer group variables; the
  model's environment holds no GitLab credential (`MODEL_WITHHELD`), the kicker starts the pipeline with
  `LOOPER_TRIGGER_TOKEN` and the port scan reads SeaBeam with `SEABEAM_READ_TOKEN` when they are set (#25)
- **Released / deployed:** `main` runs as the GitLab pipeline gitlab.com/tacplus-dev/looper on the
  *tacplus-dev arm64 autoscaler* runner, image `ghcr.io/tacplus-dev/looper:main`
- **Known gaps:** until Jody and the hub apply README's Credentials (#25), the jobs' `GITLAB_TOKEN` is still
  Jody's `looper-runtime` (`api`, Owner of the group: it reads fleet-seatrials' protected variables) and the workers
  still run as `build-box` (Artifact Registry uploads, every bucket's objects); its job keeps a runner worker up around the clock (see PROPOSALS.md);
  the Mac's launchd kicker is removed by the hub with Jody (`looper-dispatch uninstall`) once it has run green
  for a day; the ROADMAP.md guard is a pre-push hook in the looper's checkout, so a push that skips hooks
  is not refused (see PROPOSALS.md); the GitLab plan (`looper-plan` in gitlab.com/tacplus-dev/looper) still plans
  repositories in name order until the hub makes it iterate `looper-dispatch ready` (#31, PROPOSALS.md); parallel
  children (#32) are tested against a stub repository but not yet seen end to end on a real repository (they run
  once the image from main is published and a repository has two independent ready issues); the identity pilot's
  think job (kernel, #28) still works one issue per pipeline (PROPOSALS.md); no release line yet
- **Blocked on:** the identity pilot's first real kernel issue (#28) waits on the hub's setup (README, Looper
  identity: WIF pool `gitlab-loopers`, KMS keys `kernel-looper` and `tacplus-reader`, the GitLab project
  tacplus-dev/kernel, the build trigger's bot user, kernel's protection rules) and Jody creating the `kernel-looper`
  app; #15 (native build image) waits on tacplus#193; no build runs until the hub applies the build
  runner (README, Build pipeline) and publishing waits on tacplus-dev/tacplus#223 (Artifact Registry and WIF); every
  build fails "no pin" until a repository commits a `tacplus.lock`
