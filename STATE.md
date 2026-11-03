# State: looper

Overwritten to stay current (loopers and agents). Last updated: 2026-11-03 by looper (#59).

- **Version / line:** unreleased (no tags); the image `ghcr.io/tacplus-dev/looper:main` is built FROM the tacplus
  `build:2.5` environment (#1, #26); no tacplus floor of its own (the `tacplus` wrapper runs each repository's pin, else its floor's newest patch, #27)
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
  generated outputs, contracts, other conflicts), between issues that conflict the rank, not the order taken (#39): a land-pending one first (landed before any conflicting issue starts), then a bug before a feature, then priority, then age, the other waiting even for one that waits too; the runner's CPU and memory (4 GB a child, 12 in a repository whose gates run Kani, #41) and the job's remaining time (from the job's start; the job sized by
  `--job-timeout` for the longest limit among the ready issues, 6h with the defaults, so two 4h children start together, #33); a child's limit is capped at the job's deadline, its end less an hour, so an issue's `Timeout:` grown after the job was sized stops by itself, checkpointed, not killed by GitLab, and the issue is told, #35, each container a child's model starts (`docker run`, `tacplus`) limited to the child's memory without swap by
  `looper-docker`, the model's `docker`, which refuses a larger `--memory`, so one over it is OOM-killed alone, not the VM (#41); logs
  the plan and its reasons (job log, `looper-runs/<time>-plan/`, the issues), runs each child in its own worktree and
  branch, serializes landing (`repo-looper --land`: lock, rebase, gates, push; a direct push to main from a
  worktree is refused), which the parent owns (#34): `--land` queues with the parent's lander, so a land still
  queued or running when its child's limit fires is landed all the same and reported on the issue, and the parent
  waits for the queue before the job ends; it plans again as each child ends and, while children run, every
  `LOOPER_REPLAN_INTERVAL` (5 minutes) when the ready issues or free slots changed, so an issue ready mid-job starts in a free slot (#59), each re-plan logged and recorded with its occasion; `repo-looper` works each repository's
  `approved` issues (checkpoints and resume, per-issue time limit, idle and done watchdog, done only once the run reported on its closed issue and a stopped one reported by the looper, #54, Blocked-by outcomes, one or more,
  also from a run that pushed nothing because the issue waits on another, #22, a blocker closed by now dropped and one
  naming only closed ones resumed, #46; a run that ends with its land
  queued, or early with progress, a fix landed or a new step checkpointed, stays approved and resumes; only one
  that went idle with nothing landed or queued, or made no progress, is `looper:stuck`, #34; one idle after its land
  landed reports `landed`, with main's range, and stays approved for the next run to close, #37; one that ends any way with its land queued and no outcome, in the
  parent's queue or not, is `land-pending`, #44; a land starts only if the repository's last land, else a
  default (70 minutes for tacplus), fits the job's time left: one that does not is deferred, its issue told and its
  branch left land-pending, and the issue's next run lands it first, as it does a land the job's end cut off, #38;
  gates scaled to the diff, #48: a repository's `gates.yaml` maps paths to gate sets, a land runs the sets its
  changed paths call for, full for a path no set names or one of full's, a `gates.yaml` change, or no change, and lands
  nothing on a map it cannot read; the set and why are in the land's output, the looper's land comments and the issue's
  HISTORY.md line, the budget is the set's, and the prompts name the map's full for verifying, the nightly scan and
  releases; this repository has its `gates.yaml`);
  it appends HISTORY.md's line for each closed issue and release, creates missing planning files from the
  tacplus-dev/roadmap templates, and refuses a push that touches ROADMAP.md (#13); prompt provenance (#40): every
  prompt carries the issue's text (title and body, each comment) in blocks keyed by a per-prompt nonce (`openssl rand`)
  with author and association, only an OWNER's or MEMBER's text, or a write COLLABORATOR's, directing the run and the
  rest, with the port scan's quoted SeaBeam text (source-text markers), data; text holding the nonce refused, the
  nonce redacted from what leaves the job; the nightly scan; the hourly
  SeaBeam port scan (stratum only, #5), which never ports back a SeaBeam commit
  trailered `Ported-from: tacplus-dev/<repo>@<sha>` (the realign), sends one that names tacplus-dev without it to
  `needs-decision`, and files nothing past a flood guard of 5 issues (#23); the `tacplus` wrapper with GitHub credentials for its container
  (#11), which runs the released tacplus (the repository's `tacplus.lock` pin, else its floor's newest patch,
  checksum-verified) in the `build:<MAJOR.MINOR>` image of its line, so Go repositories generate (no longer the
  retired, Go-less `tacplus/tacplus` image), and `looper-smoke` generates Go through it on every image build (#27); the reusable planning-files CI check (`.github/workflows/planning-files.yml`, #13); the issue flow (#14):
  `bug` and `feature` labels in every repository, unlabelled issues classified first, bugs fixed and released as
  the next patch, features built only when a ROADMAP.md links them (else a design proposal and `needs-decision`),
  the scans file bugs as `bug`, never approve a feature, and read the roadmaps before opening an issue; the build
  pipeline (#17): `looper-build` and `ci/build.gitlab-ci.yml`, the `.gitlab-ci.yml` of gitlab.com/tacplus-dev/build
  (started with inputs `repo`, `sha`, `tag`): the commit's gates in its pinned build image, no agent, read-only
  source through the `tacplus-reader` app, a fail verdict without a pin, the GitHub commit status, and on a release
  a reproducible image published to Artifact Registry through WIF; tested against a local origin and stub GitHub,
  and with a real buildx (same commit, same digest); its deterministic security checks (#49, `looper-scan`, README:
  Security checks): every build's child pipeline runs OSV-Scanner, govulncheck, cargo-deny, Semgrep CE, gitleaks, gosec,
  clippy, Bandit and SpotBugs+FindSecBugs (pinned in the looper image) on the commit as its gates built it and on the
  code a `generated` recipe writes, a nightly (input `nightly: true`, main's head, no commit status) and a release add
  CodeQL (public repositories only) and Trivy; the policy fails a secret and a HIGH/CRITICAL finding with a fix unless
  an unexpired `security-exceptions.yaml` entry accepts it; SARIF and JSON reports, the new findings since the
  previous run (the build project's generic package `security-<repo>`), which the nightly agent scan reads; a
  release's image SBOM (CycloneDX, SPDX); tested with stubs shaped as the tools' output and with the real tools,
  and run by hand (`looper-scan local`) on tacplus and kernel. Nightly suggestions (#50, README: Suggestions): the
  platform roadmap's nightly scan is the suggestion pass for the whole platform: the looper reads the pipelines' failed
  jobs of the week and every repository's security report for the model, which writes up to 5 ranked, evidenced
  suggestions with `looper-suggest` (in the image), and the looper commits them to tacplus-dev/roadmap's main as one
  commit touching `suggestions/` only (and `suggestions/TEMPLATE.md` where it is missing), each checked: the four
  leading fields, a type from `suggestions/TYPES.md`, linked evidence, a rejected or deferred one never raised again
  without citing it and new evidence, the index Security first; `looper-suggest file` files one from another
  repository's job (pushed alone), `looper-suggest decide` records Jody's decision for the hub. Trace propagation
  (#51, README: Trace propagation) is a standing rule of every work and think prompt: causal downstream calls carry the
  inbound `trace_id`, unrelated ones say so (`// trace: unrelated: <why>`), each such handler has a propagation test,
  and the outcome comment names the handlers checked and their tests; `looper-trace check` (in the image) reads Go
  and Rust handlers and flags a dropped `trace_id` and a missing test; the nightly scan runs it on main for the model
  to verify and file as bugs (run by hand on tacplus-dev's services, 2026-11-02: gateway, oauth and mailbox flagged). Its manual macOS smoke (#36): a web run on `main` with the input `smoke: true`
  holds only `macos-smoke`, on the Mac runner (tag `macos`, Tart VM): arm64, `sw_vers`, Xcode 27.x, Swift. The looper identity pilot (#28), built and tested, not yet
  deployed: kernel's GitLab project (`ci/looper.gitlab-ci.yml`) runs `looper-identity prepare` (read-only
  `tacplus-reader` token, KMS-signed JWT through WIF), `repo-looper --think` (the model and the gates, no identity:
  outcome, patch, tested tree) and `looper-identity commit` (tree check, then `kernel-looper[bot]`: branch, pull
  request with squash auto-merge, build trigger, comment, labels); one run at a time, in a child pipeline. The loopers' `GH_TOKEN`, `GITLAB_TOKEN` and
  `CLAUDE_CODE_OAUTH_TOKEN` are project variables of gitlab.com/tacplus-dev/looper, no longer group variables; the
  model's environment holds no GitLab credential (`MODEL_WITHHELD`), the kicker starts the pipeline with
  `LOOPER_TRIGGER_TOKEN` and the port scan reads SeaBeam with `SEABEAM_READ_TOKEN` when they are set (#25); the runner
  VMs' image and readiness (#43): `runner/startup.sh`, the templates' startup-script, marks a VM ready
  (`/var/run/runner-ready`) only once Docker answers, for the autoscaler's `instance_ready_command`; `runner-image build`
  (the build pipeline's `runner-image` job, input `runner_image: true`) bakes the image family `runner-arm64-docker`
  (Docker preinstalled) and publishes an image only once a VM booted from it is ready with nothing to install;
  `runner-image template` copies a template onto the family and the script; `runner-image measure` gives jobs'
  creation-to-"Running on" times; tested in an Ubuntu container and against stub gcloud and curl; two forges (#29):
  `LOOPER_FORGE=github` (gh, the default) or `gitlab` (the GitLab API through curl, `LOOPER_FORGE_TOKEN`, a git
  credential helper, the model's `glab`, in the image), every issue, clone and file call through `looper-lib.sh`'s
  `forge_*` functions, `Blocked-by: seabeam/<path>#N` (subgroups) on GitLab, a reference to another org held and
  never read, GitLab roles for prompt provenance; `looper-dispatch plan` writes the pipeline's child jobs, each with its repository's runner tags (`LOOPER_JOB_TAGS_<repo>`, else `LOOPER_JOB_TAGS`, #55) and the plan's git identity, on a schedule a scan per repository (#56),
  `ci/tacplus-dev.gitlab-ci.yml` is tacplus-dev's pipeline file, and `ci/instance.gitlab-ci.yml` is a GitLab-hosted instance's pipeline (kicker, plan, jobs, nightly scan); tested on
  both forges against a gh stub, a GitLab API stub and a stub git server, a SeaBeam issue worked end to end
- **Released / deployed:** `main` runs as the GitLab pipeline gitlab.com/tacplus-dev/looper on the
  *tacplus-dev arm64 autoscaler* runner, image `ghcr.io/tacplus-dev/looper:main`; README (Infrastructure) gives that runner a fresh worker per job
  (`capacity_per_instance = 1`, `max_use_count = 1`, #42), which the hub applies on `gitlab-runner-mgr` after the
  runner image and readiness gate (#43); the `image` workflow builds and pushes `:main` after each land (a land does
  not wait for it), and a failed run on main opens or comments on a `bug` issue here (`image-failed`, #58)
- **Known gaps:** gitlab.com/tacplus-dev/looper's pipeline file is `ci/tacplus-dev.gitlab-ci.yml` here, whose
  `looper-plan` runs `looper-dispatch plan` (#56, tested against the hub's former inline plan), but it takes effect
  when the hub copies it there; until then that pipeline plans with its inline script (tacplus's jobs on the 16-CPU
  pool, #55, through its own `LOOPER_JOB_TAGS_tacplus`); until the hub applies README's "A fresh VM is ready before its job" (#43: the bake's service
  account and WIF binding, the first image, the templates, `instance_ready_command`), a fresh worker installs and
  restarts Docker at boot under its first job, which fails in preparation and is retried; the bake's IAM role and
  `runner-image build` have not run against GCP (no looper may change IAM or create VMs), and #43's acceptance (twenty
  jobs on fresh VMs, before and after times, `runner-image measure`) waits on that; until the hub applies the worker per job (README, Infrastructure, #42), a looper worker
  outlives its jobs: a failed job's containers keep running on it and the autoscaler keeps sending it jobs, even
  once it no longer answers SSH (tacplus, 2026-10-31); until Jody and the hub apply README's Credentials (#25), the jobs' `GITLAB_TOKEN` is still
  Jody's `looper-runtime` (`api`, Owner of the group: it reads fleet-seatrials' protected variables) and the workers
  still run as `build-box` (Artifact Registry uploads, every bucket's objects); its job keeps a runner worker up around the clock (see PROPOSALS.md);
  the Mac's launchd kicker is removed by the hub with Jody (`looper-dispatch uninstall`) once it has run green
  for a day; the ROADMAP.md guard is a pre-push hook in the looper's checkout, so a push that skips hooks
  is not refused (see PROPOSALS.md); SeaBeam's instance (README, A SeaBeam instance: `seabeam/tools/looper`, its
  bots, variables, schedules and runner) is not set up: parked by Jody until tacplus.dev's functional suite is green
  (fleet-seatrials#17), so no SeaBeam issue has been worked end to end on the real GitLab yet, and on GitLab a
  Reporter may set `approved`, and a SeaBeam repository that runs tacplus needs GitHub access it does not have
  (PROPOSALS.md); the GitLab plan plans repositories in name order, not priority:high first (#31),
  until the hub copies `ci/tacplus-dev.gitlab-ci.yml` (#56); parallel
  children (#32) are tested against a stub repository but not yet seen end to end on a real repository (they run
  once the image from main is published and a repository has two independent ready issues); the identity pilot's
  think job (kernel, #28) still works one issue per pipeline (PROPOSALS.md); `macos-smoke` (#36) has not run yet: the hub copies
  `ci/build.gitlab-ci.yml` into tacplus-dev/build and plays it once (no CI file here is linted or run by a test); a child's memory limit is per container and the model's `docker` only, not a boundary: `docker compose`, `docker build`'s containers, the real docker by its path and processes in the job's own container are unlimited, as are the land's gates (#41, PROPOSALS.md); text the model reads itself during a run (a newer comment, a
  pull request) is not wrapped: only the prompt's rule on authors guards it (#40, PROPOSALS.md); tacplus has no `gates.yaml`
  yet, so its lands still run the full gates (#48 waits on it), and the think job (#28) and the build pipeline always
  run the full gates (PROPOSALS.md); the security checks (#49) have run only by hand (`looper-scan local`), not in
  tacplus-dev/build: they start with the next looper image and the hub's copy of `ci/build.gitlab-ci.yml` (the
  `nightly` input; a schedule per repository), and on the day they start tacplus's build fails them (gosec's HIGH
  findings, six OSV advisories with fixes) as kernel's does (gitleaks: PEM markers in its Java) until each is fixed
  or accepted in a `security-exceptions.yaml` (PROPOSALS.md), and tacplus has no `generated` recipe yet, so its
  cross-test models are not scanned; the suggestion pass (#50) has run only against a stub roadmap: it starts with
  the next looper image, on the roadmap's nightly scan, and the hub's daily review (the sitrep, `looper-suggest
  decide`) is the hub's to wire; no release line yet
- **Blocked on:** the identity pilot's first real kernel issue (#28) waits on the hub's setup (README, Looper
  identity: WIF pool `gitlab-loopers`, KMS keys `kernel-looper` and `tacplus-reader`, the GitLab project
  tacplus-dev/kernel, the build trigger's bot user, kernel's protection rules) and Jody creating the `kernel-looper`
  app; #15 (native build image) waits on tacplus#193; no build runs until the hub applies the build
  runner (README, Build pipeline) and publishing waits on tacplus-dev/tacplus#223 (Artifact Registry and WIF); every
  build fails "no pin" until a repository commits a `tacplus.lock`
