# State: looper

Overwritten to stay current (loopers and agents). Last updated: 2026-11-04 by looper (#83).

- **Version / line:** unreleased (no tags); the image `ghcr.io/tacplus-dev/looper:main` is built FROM the tacplus
  `build:2.5` environment (#1, #26); no tacplus floor of its own (the `tacplus` wrapper runs each repository's pin, else its floor's newest patch, #27)
- **Works:** the kicker (`looper-dispatch`, in the image) runs as the GitLab pipeline's hourly kicker schedule, a
  pass every 3 minutes that reads GitHub for the whole org in three requests, never two kicker jobs at once, nothing on
  the Mac (#24); it starts the pipeline for a ready issue with no report job under its repository's cap, or a
  queued land with no manager; the pipeline's plan (`looper-dispatch plan`) starts **one report job per ready
  issue**, up to the repository's cap in `caps.yaml` (tacplus 6, the others 3), never a second for an issue whose
  report is created, pending, waiting or running, and the repository's **manager** job, the only one that merges
  to its main, planned ahead of every report so the runner starts it first, and a report pending from an earlier pipeline yields to a manager waiting for a runner (#70, below; #16; #75); priority labels (#31): ready issues are taken `priority:high`, then unlabelled, then
  `priority:low`, oldest first within each, and across repositories `looper-dispatch ready` (the kicker's order)
  puts first a repository whose next ready issue is `priority:high`; a running issue is never pre-empted; a run killed outright no longer leaves `looper:in-progress` behind: the job for its issue
  resumes it when no other looper job of the repository is active, and `looper-dispatch run` clears the label
  from an issue no looper job holds (#20); a run whose job GitLab no longer reports running (marked failed while
  its container goes on) checkpoints and stops within one poll, pushing and commenting nothing, so it cannot race
  its retry (#21); **managers and direct reports** (#70): a report (`repo-looper --issue N`) works its one issue
  in its own clone and branch and never touches main (its pushes to main refused); its `--land` queues its commits
  on its branch (`.looper/land`, the issue `looper:landing` until the verdict) and waits for the manager's verdict
  comment; the manager (`repo-looper --manage`, `resource_group: looper-<repo>-main`) merges the queued branches
  oldest first: rebased on main, a conflict only in files `generated.yaml` maps resolved by regenerating them (never
  a hand merge), any other sent back with the files named, the gates its diff calls for, pushed only on green, the
  merged branch deleted, every merge, resolution and send-back a comment on the issue with the gate verdict; it adds
  the planning files and `HISTORY.md`'s lines (closed issues', queued by their reports, and releases'); a land still
  queued when its report's time runs out is merged after it; a land its job has no time for (the last land's time
  on its gate set, #38) waits for the next manager; with nothing queued, the manager lingers only for report jobs
  running, never for ones created or pending, which on a one-VM pool wait for its VM (#82); the parent and its in-job children (#32), its area plan and
  conflict holds (#39), its time-left holds and re-plans (#33, #59) and its in-job lander (#34, #38, #44) are
  retired; each report's model's containers limited to its memory (4 GB, 12 in a repository whose gates run Kani)
  without swap by `looper-docker`, which refuses a larger `--memory`, so one over it is OOM-killed alone (#41); a
  report's limit capped at its job's deadline (its job sized for its issue's limit and an hour, #35); every model's
  `pkill` is `looper-pkill`, which signals only its run's own processes (tacplus#222, #61); each report's model runs
  as its own unprivileged user (`looper-<issue>`; uid and gid from a reserved range, never the Docker socket's gid,
  #69), owning its clone, home and run directory, so it cannot signal or read another run's processes or files,
  and its `docker` goes through `looper-docker-broker`, which serves it only its own containers, unprivileged,
  mounting only its clone and home (#68); `repo-looper` works each repository's
  `approved` issues (checkpoints and resume, per-issue time limit, idle and done watchdog, done only once the run reported on its closed issue and a stopped one reported by the looper, #54, Blocked-by outcomes, one or more,
  also from a run that pushed nothing because the issue waits on another, #22, a blocker closed by now dropped and one
  naming only closed ones resumed, #46; a run that ends with its land
  queued, or early with progress, a fix landed or a new step checkpointed, stays approved and resumes; only one
  that went idle with nothing landed or queued, or made no progress, is `looper:stuck`, #34; one idle after its land
  landed reports `landed`, with main's range, and stays approved for the next run to close, #37; one that ends with its land queued and no verdict is `land-pending`, held
  (`looper:landing`) until the manager's verdict, #70;
  gates scaled to the diff, #48: a repository's `gates.yaml` maps paths to gate sets, a land runs the sets its
  changed paths call for, full for a path no set names or one of full's, a `gates.yaml` change, or no change, and lands
  nothing on a map it cannot read; the set and why are in the land's output, the looper's land comments and the issue's
  HISTORY.md line, the budget is the set's, and the prompts name the map's full for verifying, the nightly scan and
  releases; this repository has its `gates.yaml`);
  it appends HISTORY.md's line for each closed issue and release, creates missing planning files from the
  tacplus-dev/roadmap templates, and refuses a push that touches ROADMAP.md (#13); prompt provenance (#40): every
  prompt carries the issue's text (title and body, each comment) in blocks keyed by a per-prompt nonce (`openssl rand`)
  with author and association, only an OWNER's or MEMBER's text, or a write COLLABORATOR's, directing the run and the
  rest, with a tool's quoted source text (source-text markers), data; text holding the nonce refused, the
  nonce redacted from what leaves the job; the nightly scan; the `tacplus` wrapper with GitHub credentials for its container
  (#11), which runs the released tacplus (the repository's `tacplus.lock` pin, else its floor's newest patch,
  checksum-verified) in the `build:<MAJOR.MINOR>` image of its line, so Go repositories generate (no longer the
  retired, Go-less `tacplus/tacplus` image), and `looper-smoke` generates Go through it on every image build (#27); the reusable planning-files CI check (`.github/workflows/planning-files.yml`, #13); the issue flow (#14):
  every label the looper uses created where its repository lacks it, by a report, the manager and the scan before they
  set one, a label edit that fails retried once they are (#80; `looper:landing` was in no repository, so no land's hold
  was set and the manager's clearing of it failed);
  `bug` and `feature` labels in every repository, unlabelled issues classified first, bugs fixed and released as
  the next patch, features built only when a ROADMAP.md links them (else a design proposal and `needs-decision`),
  the scans file bugs as `bug`, never approve a feature, and read the roadmaps before opening an issue; the build
  pipeline (#17): `looper-build` and `ci/build.gitlab-ci.yml`, the `.gitlab-ci.yml` of gitlab.com/tacplus-dev/build
  (started with inputs `repo`, `sha`, `tag`, and `gates` and `base`: the commit's `gates.yaml` sets and their base,
  #71): the commit's gates in its pinned build image (`tacplus.lock`, or `build.lock` for a repository that is no
  tacplus project: the looper's pins the looper image by digest, #71), no agent, read-only
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
  repository's job (pushed alone), `looper-suggest decide` records Jody's decision for the hub. The nightly recap
  (#57, README: Nightly recap), in the same pass: `looper-recap` (in the image) gathers the last 24 hours with no
  model (each job's queue, prepare and run times and failure class; per repository slot use, the hours each ready
  issue waited and why, lands by gate set, scans; runner pools, Actions workflows, the image against
  main's head; per manager its report-to-merge time, conflicts resolved against sent back, red gates, a red main
  after its merges and reverts from GitHub, redone work; per repository's cap, from the kicker's `capacity:` line a
  pass, the hours ready issues waited at it, how often all reports were busy and the merge backlog, with advice to
  raise or lower it after two nights running; the capacity: queue p90, issues waiting for a VM and one more VM's cost
  a day, for Jody's manual scale-up, #72) and classifies its items against the 7 nights (recurring: advice, ranked by the hours of waiting it
  would remove; transient and once: one line); the model writes the advice as Performance, Operability or Cost
  suggestions with cause, change, gain and numbers (`looper-suggest check` refuses advice without numbers), and the
  looper commits `suggestions/recap/<night>.md` and `.json` with them, for Jody's daily report. Trace propagation
  (#51, README: Trace propagation) is a standing rule of every work and think prompt: causal downstream calls carry the
  inbound `trace_id`, unrelated ones say so (`// trace: unrelated: <why>`), each such handler has a propagation test,
  and the outcome comment names the handlers checked and their tests; `looper-trace check` (in the image) reads Go
  and Rust handlers and flags a dropped `trace_id` and a missing test (a seam handed the `trace_id` as its own parameter, a row by value beside it, is credited through its callers' tests, #66); the nightly scan runs it on main for the model
  to verify and file as bugs (run by hand on tacplus-dev's services, 2026-11-02: gateway, oauth and mailbox flagged). Its manual macOS smoke (#36): a web run on `main` with the input `smoke: true`
  holds only `macos-smoke`, on the Mac runner (tag `macos`, Tart VM): arm64, `sw_vers`, Xcode 27.x, Swift. The looper identity pilot (#28), built and tested, not yet
  deployed: kernel's GitLab project (`ci/looper.gitlab-ci.yml`) runs `looper-identity prepare` (read-only
  `tacplus-reader` token, KMS-signed JWT through WIF), `repo-looper --think` (the model and the gates, no identity:
  outcome, patch, tested tree) and `looper-identity commit` (tree check, then `kernel-looper[bot]`: branch, pull
  request with squash auto-merge, build trigger, comment, labels); one run at a time, in a child pipeline. The loopers' `GH_TOKEN`, `GITLAB_TOKEN` and
  `CLAUDE_CODE_OAUTH_TOKEN` are project variables of gitlab.com/tacplus-dev/looper, no longer group variables; the
  model's environment holds no GitLab credential (`MODEL_WITHHELD`), the kicker starts the pipeline with
  `LOOPER_TRIGGER_TOKEN` when it is set (#25); only the manager writes main, built and tested, not yet set up (#83;
  README, Only the manager writes main): `looper-ruleset apply` puts a ruleset on main in each public repository
  (restricted updates, no force-push or deletion; bypass: the `tacplus-manager` app and Jody), idempotent, with `check`
  and a live `probe` (the CI file's manual `looper-ruleset-probe`); with the apps' variables set, every job's GitHub
  token is an app's, minted by `looper-token` from its id_token through WIF and KMS (its environment naming the key it
  may use) and refreshed for the job's life as gh's configuration: `tacplus-manager`'s for the managers and the
  scans' commits to main, `tacplus-looper`'s (no bypass) for the reports, the scans' models, the kicker and the plan;
  a job that holds `GH_TOKEN` or a personal token refuses to run; the scan's model runs as `looper-scan` and leaves
  its PROPOSALS.md change for the looper to commit; private repositories' issues get no report
  (`--visibility public`, `LOOPER_PRIVATE_REPORTS=1` to undo); the runner
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
- **Known gaps:** the model's own user (#68) takes effect with the image built after its land (the broker,
  `looper-docker-broker`, is in it); the manager's gates still run a report's commits as its job's user, and the
  broker's mount check is check-then-use (PROPOSALS.md); the recap has not run against the live APIs yet (its first night does); it reads tacplus-dev/build's
  jobs with `GITLAB_TOKEN` (#85), its bot a Reporter there once tacplus-dev/cloud#12's `apply:gitlab` has run on
  main (until then `sources` names the 404), and the image's revision only where it has `docker buildx`:
  otherwise its `sources` says so; Cloud Build is not read (#85); one more VM's cost is the t2a-standard-8 on-demand list price (`LOOPER_RECAP_VM_USD_HOUR`,
  0.308), not the billing's; a red main is read from the `tacplus-dev/build` commit status, which only a build of the
  merged commit sets (#71 redefines the build jobs);
  gitlab.com/tacplus-dev/looper's pipeline file is `ci/tacplus-dev.gitlab-ci.yml` here, whose
  `looper-plan` runs `looper-dispatch plan` (#56, tested against the hub's former inline plan), but it takes effect
  when the hub copies it there; until then that pipeline plans with its inline script (tacplus's jobs on the 16-CPU
  pool, #55, through its own `LOOPER_JOB_TAGS_tacplus`); README's "A fresh VM is ready before its job" (#43) is not hand-applied on
  jody1-328023 (the hub, 2026-11-03: the recap measured 0.24 h of waiting in 24 h, and lasting infrastructure comes
  from the cloud pipeline): the runner pools of tacplus-dev/cloud's `ci` stack (cloud#4, closed) boot a pinned
  Container-Optimized OS with nothing installed at boot, a `docker info` readiness gate and one VM per job, and the
  baked image is superseded (roadmap `decisions/builds-in-containers-2026-11-03.md`; `runner/` and `runner-image
  build`/`template` stay until the redesign retires them, never run against GCP); until the jobs move onto those
  pools a fresh worker installs and restarts Docker at boot under its first job, which fails in preparation and is
  retried, and #43's acceptance (twenty jobs on fresh VMs, before and after times, `runner-image measure`) waits on
  that move; until the hub applies the worker per job (README, Infrastructure, #42), a looper worker
  outlives its jobs: a failed job's containers keep running on it and the autoscaler keeps sending it jobs, even
  once it no longer answers SSH (tacplus, 2026-10-31); README's Credentials (#25) are applied (hub, checked 2026-11-03): the jobs' `GITLAB_TOKEN` is
  `tacplus-looper-bot`'s `read_api` token (`looper-jobs`, expires 2027-10-01), `looper-runtime` is revoked, and every
  worker runs as `looper-runner` (template `runner-arm64-t2a8-v6` and the 16-CPU pool), not `build-box`; its job keeps a runner worker up around the clock (see PROPOSALS.md);
  the Mac's launchd kicker is removed by the hub with Jody (`looper-dispatch uninstall`) once it has run green
  for a day; the ROADMAP.md guard is a pre-push hook in the looper's checkout, so a push that skips hooks
  is not refused (see PROPOSALS.md); SeaBeam's instance (README, A SeaBeam instance: `seabeam/tools/looper`, its
  bots, variables, schedules and runner) is not set up: parked by Jody until tacplus.dev's functional suite is green
  (fleet-seatrials#17), so no SeaBeam issue has been worked end to end on the real GitLab yet, and on GitLab a
  Reporter may set `approved`, and a SeaBeam repository that runs tacplus needs GitHub access it does not have
  (PROPOSALS.md); the GitLab plan plans repositories in name order, not priority:high first (#31),
  until the hub copies `ci/tacplus-dev.gitlab-ci.yml` (#56); the reports
  and managers (#70) are tested against a stub forge and GitLab but not yet seen end to end: they run once the image
  from main is published and the hub copies `ci/tacplus-dev.gitlab-ci.yml` (its jobs are named by the plan);
  build jobs (#71, README: Build jobs) are built and tested against stubs but run nowhere yet: they take effect for
  a repository once its commit is pinned (only this one is: `build.lock`; the hub files the others' pin issues) and
  the report and manager jobs hold `BUILD_TRIGGER_TOKEN` (not yet set in tacplus-dev/looper), and need the hub's copy
  of `ci/build.gitlab-ci.yml` (the `gates` and `base` inputs); until then every manager runs the gates in its own
  job and every report keeps `looper-docker`; `looper-docker`, its broker and the host socket's path stay until every
  repository is pinned, and an image build in the build job without host Docker waits on rootless BuildKit
  (tacplus-dev/tacplus#315), both the follow-up's (PROPOSALS.md); the identity pilot's
  think job (kernel, #28) still works one issue per pipeline (PROPOSALS.md); `macos-smoke` (#36) has not run yet: the hub copies
  `ci/build.gitlab-ci.yml` into tacplus-dev/build and plays it once (no CI file here is linted or run by a test); a report's memory limit is per container and the model's `docker` only, not a boundary: `docker compose`, `docker build`'s containers, the real docker by its path and processes in the job's own container are unlimited, as are the manager's gates (#41, PROPOSALS.md); text the model reads itself during a run (a newer comment, a
  pull request) is not wrapped: only the prompt's rule on authors guards it (#40, PROPOSALS.md); tacplus has no `gates.yaml`
  yet, so its lands still run the full gates (#48 waits on it), and the think job (#28) and the build pipeline always
  run the full gates unless the manager or a report's `--build` names a set (#71) (PROPOSALS.md); the security checks (#49) have run only by hand (`looper-scan local`), not in
  tacplus-dev/build: they start with the next looper image and the hub's copy of `ci/build.gitlab-ci.yml` (the
  `nightly` input; a schedule per repository), and on the day they start tacplus's build fails them (gosec's HIGH
  findings, six OSV advisories with fixes) as kernel's does (gitleaks: PEM markers in its Java) until each is fixed
  or accepted in a `security-exceptions.yaml` (PROPOSALS.md), and tacplus has no `generated` recipe yet, so its
  cross-test models are not scanned; the suggestion pass (#50) has run only against a stub roadmap: it starts with
  the next looper image, on the roadmap's nightly scan, and the hub's daily review (the sitrep, `looper-suggest
  decide`) is the hub's to wire; no release line yet
- **Blocked on:** "only the manager writes main" (#83) is enforced once Jody creates and installs the two apps,
  imports their keys to KMS with their bindings, applies the ruleset and swaps `GH_TOKEN` for the apps' variables
  (README, Only the manager writes main, Setting it up); until then every job uses `GH_TOKEN` as before; the identity pilot's first real kernel issue (#28) waits on the hub's setup (README, Looper
  identity: WIF pool `gitlab-loopers`, KMS keys `kernel-looper` and `tacplus-reader`, the GitLab project
  tacplus-dev/kernel, the build trigger's bot user, kernel's protection rules) and Jody creating the `kernel-looper`
  app; #15 (native build image) waits on tacplus#193; no build runs until the hub applies the build
  runner (README, Build pipeline) and publishing waits on tacplus-dev/tacplus#223 (Artifact Registry and WIF); every
  build fails "no pin" until a repository commits a `tacplus.lock`
