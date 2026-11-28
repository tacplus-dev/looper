# State: looper

Overwritten to stay current (loopers and agents). Last updated: 2026-11-27 by looper (#249).

- **Version / line:** unreleased (no tags); the image `ghcr.io/tacplus-dev/looper` (`main`, `main-<sha7>`; the plan
  runs it by digest, the attested build of main, #115) is built FROM the tacplus
  `build:2.6` environment (#1, #26, #102); no tacplus floor of its own (the `tacplus` wrapper runs each repository's pin, else its floor's newest patch, #27)
- **Works:** the kicker (`looper-dispatch`, in the image) runs as the GitLab pipeline's hourly kicker schedule, a
  pass every 3 minutes that reads GitHub for the whole org in four requests, never two kicker jobs at once and only the newest (a kick stops once a newer one is queued, #104), a GitHub read answered with a 5xx or a 429 tried again (3 tries, 2 then 4 seconds apart; never a write) and a pass that fails logged and skipped, the kick red only when every pass failed (#178), nothing on
  the Mac (#24); it starts the pipeline for a ready issue with no report job, that issue read itself first (the search lags: #175, one request more a start; the plan reads each it plans so too), or a
  queued land with no manager, and nothing during the looper's hold (#157, below); the pipeline's plan (`looper-dispatch plan`) starts **one report job per ready
  issue**, every one of them (no per-repository cap: `caps.yaml` is gone, #107), never a second for an issue whose
  report is created, pending, waiting or running, and the repository's **manager** job, the only one that merges
  to its main, planned ahead of every report so the runner starts it first, and a report pending from an earlier pipeline yields to a manager waiting for a runner (#70, below; #16; #75); priority labels (#31): ready issues are taken `priority:high`, then unlabelled, then
  `priority:low`, oldest first within each, and across repositories `looper-dispatch ready` (the kicker's order)
  puts first a repository whose next ready issue is `priority:high`; a running issue is never pre-empted; a run killed outright no longer leaves `looper:in-progress` behind: the job for its issue
  resumes it when no other looper job of the repository is active, and `looper-dispatch run` clears the label
  from an issue no looper job holds (#20); a run whose job GitLab no longer reports running (marked failed while
  its container goes on) checkpoints and stops within one poll, pushing and commenting nothing, so it cannot race
  its retry (#21); **managers and direct reports** (#70): a report (`repo-looper --issue N`) works its one issue
  in its own clone and branch and never touches main (its pushes to main refused); its `--land` queues its commits
  on its branch (`.looper/land`, the issue `looper:landing` until the verdict) and returns at once: the run ends
  `land-pending`, and the issue's next run, after the verdict, closes it or fixes what came back (#86; `--wait`
  waits for the verdict comment, for tests and runs by hand); the manager (`repo-looper --manage`, `resource_group: looper-<repo>-main`) lands the queued branches
  **in batches, a merge train** (#86, `tacplus-dev/roadmap:decisions/merge-train-2026-11-04.md`): every queued branch at once,
  by their issue's priority (`priority:high`, unlabelled, `priority:low`), then oldest first (#121), the queue read again before each batch and by a verdict job before each land it judges, so a `priority:high` land queued meanwhile goes next and none is judged twice (#184), each rebased onto a candidate from main (`refs/looper/staging`, never main): a conflict only in files `generated.yaml` maps resolved by regenerating them (never
  a hand merge), `PROPOSALS.md`'s and `HISTORY.md`'s appends unioned (git's union merge, #105), a report's last commit touching STATE.md alone whose only conflict is STATE.md dropped, main's kept and
  the rest landed, the dropped diff on the issue for a docs-only land again (#131; `--land` puts the STATE.md change in
  that last commit), any other sent back at once with the files named (by a verdict job too: a land it drops, conflicted, red or refused, gets its verdict and loses `looper:landing` before its next land's gates start, #192; and a verdict job stops after a green land that adds or changes the build image's pin, so main gets it and the next batch is the pinned manager's, #193), that branch alone dropped from the batch; one build of the candidate, on the gate set the batch's combined diff calls for (a build job in a pinned repository, else the gates in the manager's job, in a scratch worktree under its work directory,
  which the host shares, so the tacplus compiler's sibling container sees it: not the job's /tmp, #79); green, main fast-forwarded to the candidate (nothing reaches main without a green build of exactly that commit, but for the planning files, #215), the
  merged branches deleted; red, a batch of more than one land with build jobs judged in one round (#205: each land's commits alone rebased on main, a build job each of its own diff's gate set, all at once; each red one sent back with its own failure, the rest staged again as one batch, one build more), and one whose round sends none back (red only together, a flake), over `LOOPER_RED_ROUND` (40; 0 none) or with its gates in the job bisected on its prefixes (about log2(n) builds), each green prefix landed at once and the next candidate built on the main it made (#208), each candidate built on the main of its build (#215: main fetched before the batch's build and each bisection's, a main moved by planning files alone rebased onto, before a build and when a green candidate cannot fast-forward (#230: a land's STATE.md commit conflicting with main's STATE.md dropped, main's kept, as #131 does, the green build kept), one moved otherwise its lands staged again before a build or left for the next batch after it; a closed issue's HISTORY.md line queued in a batch added once it is done), the breaking land sent back with the failure (its issue stays `approved`), the rest queued for the next batch; the recap counts the rounds; a batch of one red just sent back; a candidate nothing could be built of (its build branch's push refused) no red and not bisected, a land changing `.github/workflows/` that origin refused sent back at once `needs-decision` and the rest landed, any other reason leaving the lands queued with each issue told once (#194); every merge, resolution and send-back a comment on the issue with the gate verdict and the batch; the recap reports per manager its batch sizes, builds per landed change, bisections and queued-to-landed time; it adds
  the planning files and `HISTORY.md`'s lines (closed issues', queued by their reports, and releases'); a land still
  queued when its report's time runs out is merged after it; a land its job has no time for (the last land's time
  on its gate set, #38) waits for the next manager; a manager or verdict job in the looper image ends between lands, exit 0, once
  `ghcr.io/tacplus-dev/looper:main` (`LOOPER_JOB_IMAGE`) names another digest than at its start, both logged, so the next job
  runs the new image (#153: a stale manager kept a fixed fault turning lands red for up to 11 h); with nothing queued, the manager lingers only for report jobs
  running, never for ones created or pending, which on a one-VM pool wait for its VM (#82); the parent and its in-job children (#32), its area plan and
  conflict holds (#39), its time-left holds and re-plans (#33, #59) and its in-job lander (#34, #38, #44) are
  retired; no model has a container runtime (#73: `looper-docker` and its broker, #41 and #68, are retired; its
  `docker` says why), and a report or land in a repository that pins no build image stops at once and says to pin it
  first (the report holds its issue `looper:stuck`, the land is sent back red); a
  report's limit capped at its job's deadline (its job sized for its issue's limit and an hour, #35); each run's model
  chosen per run (#136, #162): `claude-fable-5-1` (`LOOPER_MODEL_HIGH`) for the report of an issue carrying `model:high`
  (set by someone with write access; a bot's or a reader's ignored) and the roadmap's suggestion pass and recap,
  `claude-opus-5-5` (`LOOPER_MODEL_DEFAULT`) otherwise (`priority:high` only orders the queues; each repository's
  nightly scan on the default; the recap names a day the high model's share of the tokens passes
  `LOOPER_RECAP_HIGH_SHARE`), `LOOPER_MODEL` over both, a high model probed
  first and a refused one falling back to the default, said in the run's start comment (which every report posts,
  naming its model), its record's `model` file and the job's log with its tokens per model; every model's
  `pkill` is `looper-pkill`, which signals only its run's own processes (tacplus#222, #61); each report's model runs
  as its own unprivileged user (`looper-<issue>`; uid and gid from a reserved range, never the Docker socket's gid,
  #69, kept since #73: a looper VM's looper holds the VM's socket for its local builds), owning its clone, home and
  run directory, so it cannot signal or read another run's processes or files (#68); `repo-looper` works each repository's
  `approved` issues (checkpoints and resume, per-issue time limit, idle and done watchdog, done only once the run reported on its closed issue and a stopped one reported by the looper, #54, Blocked-by outcomes, one or more,
  also from a run that pushed nothing because the issue waits on another, #22, a blocker closed by now dropped and one
  naming only closed ones resumed, #46; a run that ends with its land
  queued, or early with progress, a fix landed or a new step checkpointed, stays approved and resumes; only one
  that went idle with nothing landed or queued, or made no progress, is `looper:stuck`, #34; one the account's usage
  limit refused (`You've hit your weekly limit · resets 3am (UTC)`, empty usage) on its model and any it may fall back to
  is `held`, not stuck (#157: 19 issues stuck and 17 hours lost on 2026-11-14): its issue keeps its labels and gets no
  comment, the reset time the refusal names is recorded on the hub's one pinned hold issue (`looper:hold`, one comment
  per hold), and the kicker and the plan start no report and no manager until then, resuming by themselves after it; a
  high model the limit refuses mid-run falls back to the default, as a probe's refusal does; one idle after its land
  landed reports `landed`, with main's range, and stays approved for the next run to close, #37; a run waiting on its
  build, pending or running in tacplus-dev/build, is not idle until its verdict or `LOOPER_BUILD_WAIT` from its start, and one idle after its
  build had no verdict within that wait is retried, not stuck, #133; one whose work waits on another run's result (an image build, a pipeline) does not wait in its model: `--wait-on <url>` checkpoints `waiting on <url>` and ends it (one that sits waiting all the same is stopped as done, not idle), its issue `Waiting-on: <url> (since ...)` in its body and `approved`, never stuck, ready again (the kicker, the plan) once that GitHub Actions run or GitLab pipeline or job has finished, or `LOOPER_WAIT_MAX` (6h) after when it cannot be read, its next run resuming with the result named in its prompt, #171; a resumed run that ends with nothing landed or queued and its work what it started from backs off, and so does one that runs `--wait-until <date>` for an outside wait: its issue `Backed-off: until <time> (since <time>, main <sha>)` in its body and `approved`, not ready (the kicker, the plan) until that time (a day, `LOOPER_BACKOFF_MAX`, or the date) or until a member's comment, a label change, a push to its main or a blocker closing after its since, its next run's prompt naming what changed, #181 (kernel#66's ~20 runs for nothing on 2026-11-17); a push wakes it only when one compare from the line's sha to main's head shows a file other than HISTORY.md, STATE.md and PROPOSALS.md changed, or, when `--wait-until --path` named paths on the line (`, paths Dockerfile ci`), one of those, and a run so woken that again finds nothing keeps the until and the paths, #213 (looper#189's 14 runs and cloud#85's 10 on 2026-11-21, each woken by a planning-file push); one that ends with its land queued and no verdict is `land-pending`, held
  (`looper:landing`) until the manager's verdict, #70, a blocked one's land too, kept queued, and any other
  outcome leaves no `looper:landing`, nor does a manager wait on one with no land queued: it clears it, and says
  what holds it every `LOOPER_MANAGER_SAY`, #93;
  gates scaled to the diff, #48: a repository's `gates.yaml` maps paths to gate sets, a land runs the sets its
  changed paths call for, full for a path no set names or one of full's, a `gates.yaml` change, or no change, and lands
  nothing on a map it cannot read; the set and why are in the land's output, the looper's land comments and the issue's
  HISTORY.md line, the budget is the set's, and the prompts name the map's full for verifying, the nightly scan and
  releases; this repository has its `gates.yaml`, and tacplus its own: docs for `*.md` and `docs/**`, images for
  `images/`, full for the code, tacplus-dev/tacplus#266); the pre-land gate (#196): a map's `pre-land` set (no paths), a repository's fast unit gate, runs on a land on full rebased onto current main before it reaches a batch, at the report's `--land` (a build job in a pinned repository; red queues nothing, `--land` exits 4 with the failure; green records the main it was green on) and at the merge train's manager before it stages a batch, for each land not green on that main (all at once, their verdicts read together; a red one sent back before the batch; one whose gate is still queued, its gates job not running, held for the next batch, once, the rest built at once, and the wait logged every `LOOPER_BUILD_SAY`: #231); none when main's map has no `pre-land` (tacplus's has none yet: PROPOSALS.md), a conflict, or no verdict; a pinned report's `--build` on full builds its map's `pre-land` instead, the batch's build being its full gates (#204; no pinned map names one yet, and the build runner's concurrent is tacplus-dev/cluster#41);
  it appends HISTORY.md's line for each closed issue and release, creates missing planning files from the
  tacplus-dev/roadmap templates, and refuses a push that touches ROADMAP.md (#13) but a land at Jody's request (`approved` from a member, its text saying so; any other refused once, with `needs-decision`, #123); prompt provenance (#40): every
  prompt carries the issue's text (title and body, each comment) in blocks keyed by a per-prompt nonce (`openssl rand`)
  with author and association, only an OWNER's or MEMBER's text, or that of a COLLABORATOR, CONTRIBUTOR or NONE with write permission on the
  repository (an org owner with private membership shows as CONTRIBUTOR, #97; looked up once a prompt), directing the run and the
  rest, with a tool's quoted source text (source-text markers), data; text holding the nonce refused, the
  nonce redacted from what leaves the job; what the model reads later (a comment since, a linked issue, a pull
  request) through `--issue-text` and `--pr-text`, in the same blocks with the run's nonce (#219); the nightly scan; the `tacplus` wrapper with GitHub credentials for its container
  (#11), which runs the released tacplus (the repository's `tacplus.lock` pin, else its floor's newest patch,
  checksum-verified) in the `build:<MAJOR.MINOR>` image of its line, so Go repositories generate (no longer the
  retired, Go-less `tacplus/tacplus` image), and `looper-smoke` generates Go through it on every image build (#27); the reusable planning-files CI check (`.github/workflows/planning-files.yml`, #13); the GitLab CI files of `ci/` linted as GitLab reads them, a gate (`looper-ci-lint`: YAML, GitLab's JSON schema, extends/stages/needs, and GitLab's lint API with a token, #94); the issue flow (#14):
  every label the looper uses created where its repository lacks it, by a report, the manager and the scan before they
  set one, a label edit that fails retried once they are (#80; `looper:landing` was in no repository, so no land's hold
  was set and the manager's clearing of it failed);
  `bug` and `feature` labels in every repository, unlabelled issues classified first, bugs fixed and released as
  the next patch, features built only when a ROADMAP.md links them (else a design proposal and `needs-decision`),
  the scans file bugs as `bug`, one issue per cause and not per finding, blocked from the start (its `Blocked-by:` lines)
  when the fix is another repository's open issue (#129), never approve a feature, and read the roadmaps before
  opening an issue, and check STATE.md's Blocked on against the issues' states, a closed one an approved bug (#132); an
  issue's run files the change its issue needs in another repository of the org (its other half) there, `approved` with
  it, its body's first line `Parent: <org>/<repo>#N` naming it, and the looper approves one its outcome waits on that
  was filed without (#218); such a follow-up, a feature no ROADMAP.md links, inherits its parent's approval when the
  looper's app filed it, its parent is open or done, approved, on a roadmap and named it in a looper comment, and the
  model finds it within the parent's scope (no production, standing cost, security or gate exception): built, its
  inherited ROADMAP.md line committed on its branch and let through by the manager with its land, one level only
  (#264); the
  relock (#212): the nightly scan, before its model, moves main's pins by digest (each pin file's `build_image:`, each Dockerfile
  FROM) to their tags' digests now, the tacplus build image at a patch tag and tacplus.lock's `tacplus:` to the line's newest
  released patch, files one approved `bug` a repository for the moves (`<!-- looper-relock -->`) and queues the relock on its
  branch with the manager's identity, `looper:landing`, for the merge train to land on its gates; an open one with its branch
  on origin left to it; the nightly maintenance (#226, tacplus-dev/roadmap decisions/security-gates-ship-only-2026-11-23.md): a CI image
  (build.lock's tacplus build image, any pin of it at its line's tag or a dated one) moves to its line's newest dated build
  (`build:<YYYYMMDD>-<commit>`, the dated tag at `build:X.Y`'s digest now; a dated pin's line the oldest release branch holding its
  commit, none unread), never a floating tag, every other file naming the moved ref with it but markdown, and the scan's model fixes
  the CI tools' advisories of the security report (a bump of the tool's pin, else a 14-day exception for that binary), its
  `security-exceptions.yaml` and `ci/` changes alone landed with the moves as one land on the relock issue, which names them; a release
  Dockerfile's `FROM` at a floating tag (not a CI image's under `ci/`, nor a test's), a builder stage's and a global `ARG`'s default too,
  pinned at its tag's digest in the same land, and moved nightly from then on, a ref built of `ARG`s unread (#234; looper's own
  `Dockerfile` is one: PROPOSALS.md);
  dated pins need cloud#102 and onscreen#6 (their pin tests refuse a dated tag) and cluster#54 to land green there; the build
  pipeline (#17): `looper-build` and `ci/build.gitlab-ci.yml`, the `.gitlab-ci.yml` of gitlab.com/tacplus-dev/build
  (started with inputs `repo`, `sha`, `tag`, and `gates` and `base`: the commit's `gates.yaml` sets and their base,
  #71, and `wait`: the requester's wait, repo-looper's, past which a gates job writes `abandoned` and runs no gates, #130): the commit's gates in its pinned build image (`tacplus.lock`, or `build.lock` for a repository that is no
  tacplus project: the looper's pins the looper image by digest, #71; a `tacplus.lock` project's gates and verify run
  with the image's own tacplus, `TACPLUS_BIN=tacplus`, once the job's image is checked to be the pin, #137), no agent, read-only
  source through the `tacplus-reader` app, a fail verdict without a pin, the GitHub commit status (a red gates or
  security job's why, a red gate's with the gates log's last lines, set by the child pipeline's security job,
  `looper-build scan`, after its scan, #148, #144, #237; every build job, the child pipeline's and the fan-out's too, is retried on an image not
  pulled, `runner_external_dependency_failure`, and on `api_failure`, and a land's build red in its infrastructure alone,
  its gates green (the security job's `no security verdict`, or `the build failed` or no verdict at all with the
  pipeline's jobs read with `GITLAB_TOKEN`), is built again once, gates and all, by the manager, which cannot retry jobs alone (#173; reading
  tacplus-dev/build's jobs needs its bot a Reporter there, else only the first case is told); a manager waits
  its gate set's wait from the build's start, never its trigger: the sum of its sets' `minutes` in the commit's
  `gates.yaml` and `LOOPER_BUILD_MARGIN` (30m), at least `LOOPER_BUILD_WAIT` (3h), #158; a build with no verdict by its job's end leaves the
  land queued and its pipeline, on the build's branch, for the next manager to take up; the recap has each manager's
  build queue time apart from its run time, #128; a build with no status at all, not even pending, within
  `LOOPER_BUILD_START` (15m) of its trigger is "no runner", never red and no wait without a bound: `--build` says so and
  exits 4, a land stays queued with no verdict, its pipeline recorded for the next manager as #128's, and its issue is
  told once, #113; a report's `--build` is asked for with `report: true` and its gates job holds the resource group
  `report-slot-<pipeline id mod BUILD_REPORT_SLOTS>` (4), a land's none, so report builds never take every build slot
  and a land's build finds a runner (#195; in effect once the hub copies `ci/build.gitlab-ci.yml`, until then the
  input refused and the build started again without it); every build but a land's is `report: true` (a report's
  `--build` and pre-land gate, the manager's pre-land gates and red round), its slots held below `BUILD_POOL_NODES` (2,
  at least one) and its child jobs on `BUILD_REPORT_TAGS`, a nightly's gates in a report slot too, and a land's build
  not started within `LOOPER_BUILD_START` while other builds run (read with `GITLAB_TOKEN`) is waited on, not "no
  runner" (#209: four non-land builds held the spot pool's 2 nodes and a 24-land batch's manager gave up; preemption,
  a `build-report` runner with a low PriorityClass, is tacplus-dev/cluster#42); the build's light jobs (`pending`, `plan`, `report-pass`, `report-fail`: looper-build alone) run on `arm64, build-light`, never behind the build runner's slots (#224: 84 of them queued behind 6 slots, a land candidate 77 min at `pending`; in effect once tacplus-dev/cloud#100 bumps `build_ci_commit` after tacplus-dev/cluster#51's runner is online); no build is started while tacplus-dev/build's active jobs are within `LOOPER_BUILD_JOB_ROOM` (50) of GitLab's job activity limit (500), waiting `LOOPER_BUILD_ROOM_WAIT` (15m) at most for room (#237), and a build's child pipeline is `gates` and `security-<repo>` alone (#237: `gates-failed`, `security-report` and `security-failed` folded into the security job); with the CI file's `BUILD_CHILD_VERDICT` "true", an ordinary build is 4 jobs, `plan` setting pending and the `pending`, `report-pass` and `report-fail` jobs a release's alone: it is "true" with the CI file's pin of the looper image of main-e0ab92d, which has `looper-build scan` (#237), in effect in tacplus-dev/build once the hub's copy (tacplus-dev/cloud#109) takes it; gates silent for `BUILD_GATES_IDLE` (1h) are stopped, their
  process group too, and the verdict is red (#195: a hung report build held a slot 1 h 52 min); a build whose pipeline was cancelled or failed with no verdict is red at once (a land's cancelled one built again, once, and cancelled again no red but left queued, nothing built; in a red round no verdict on its own: #209; so is a land's build whose `gates` job failed `runner_system_failure` with no gates verdict, the pool having had no room, a batch built again as one, never fanned out per land: #214; and a build whose child pipeline GitLab refused, failed with no job past the free plan's job activity limit, a land's built again after `LOOPER_BUILD_BACKOFF` (5m), once, refused again left queued, a report's `--build` no verdict, exit 2: #237), its status read with `GITLAB_TOKEN` (a report's model told by its looper), and reused by no request, and gates still running their requester's wait after they started are stopped, red (#198: the manager waited on a cancelled build for hours); a pending or green status names its key, gate set and base: a build
  runs once per repository, commit, gate set and base, a green or queued or running one reused by every request for
  its key and a land whose rebased tree a green build passed on the same base merging on that verdict, its comment
  linking it; the nightly recap counts builds against the commits they built, #134), and on a release
  a reproducible image published to Artifact Registry through WIF, by the child pipeline's `publish-<repo>` once every
  check passed, with **rootless BuildKit and no host Docker** in `BUILD_BUILDER_IMAGE` (`tacplus-image-build`,
  tacplus#315; its daemon failing to start fails the job), else, while that is empty, `docker buildx` in the looper
  image on `BUILD_DOCKER_TAGS`, the plan saying so, and its SBOM by `sbom-<repo>` in the looper image (#73, step 1);
  a nightly's `gates-report` publishes its gates' verdict on main (`gates-<repo>/latest`: record and log tail), which a
  pinned repository's nightly scan reads as its item 3 instead of running the gates, its model with no container
  runtime and its job on the control runner with a report's requests (#73, step 2), the record carrying the last
  green full check and the reds in a row since, from which the scan files each miss of the gate map with
  `looper-gatemiss` (#253: a red held on a second night whose only land since green ran a partial set, one approved
  `bug`, "gate map miss: <paths> ran <sets>, <gate> broke"; a flake, a land on full or several lands, none; README: Gate
  map misses; the rolling check's bisect and the repository's `gate-audit` are #249's part, PROPOSALS.md);
  tested against a local origin and stub GitHub, BuildKit and registry, and with a real buildx (same commit, same
  digest; a real rootless BuildKit where one starts); its deterministic security checks (#49, `looper-scan`, README:
  Security checks): every build's child pipeline runs OSV-Scanner, govulncheck, cargo-deny, Semgrep CE, gitleaks, gosec,
  clippy, Bandit and SpotBugs+FindSecBugs (pinned in the looper image) on the commit as its gates built it (the
  gates' `built/`: the untracked sources, manifests, bytecode, release jars, and each tacplus.yaml's generated tree
  whole, the `.json` and `.md` a crate `include_str!`s too, #155) and on the
  code a `generated` recipe writes (cargo-deny on a service that path-depends on crates its gates generate: with
  them, laid over the checkout or the gates' `generated/` at its tacplus.yaml's generated tree, else on its Cargo.lock's
  crates alone, which the summary says, #126; the SAST findings and secrets in each tacplus.yaml's generated tree
  (its `output-name`, default `model`, in its `output-dir`, as tacplus writes it: operator's `.` is `tacplus/`, #152),
  through its `import:`, kept aside as tacplus's to scan, #108, #149; SpotBugs' heap sized to the job, #149) and
  Trivy on the release jars the gates keep (`trivy rootfs`: the dependencies they shade, #147), a nightly (input
  `nightly: true`, main's head, no commit status; with no `repo`, one pipeline fanning out to every repository whose
  main pins its build image, each its own child pipeline, #164; `BUILD_NIGHTLY_SLOTS`, 1, at a time, each repository's plan and child in the resource group
  `nightly-slot-<n>`, every nightly job on `BUILD_NIGHTLY_TAGS`, a build's never, so the lands' builds never wait behind it, #185:
  `arm64, build-nightly`, the cluster's nightly entry (tacplus-dev/cluster#46), registered by tacplus-dev/cloud#116 (#220), in effect in tacplus-dev/build once the hub's copy takes it after cluster runs that entry, and the schedule's hour the recap's quietest build hours, PROPOSALS.md) and a release add
  CodeQL (public repositories only; its `--ram` and `--threads` sized to the job's cgroup, a 2048 MB or quarter reserve
  left, its job `BUILD_SCAN_CODEQL_REQUESTS`, `2 12Gi 3500m 12Gi`, each analysis's peak in the summary's `### Memory`, #189:
  CodeQL's own default heap ran the Java and Rust nightlies out of memory; the gates job `BUILD_GATES_REQUESTS_<repo>`, unset the runner's defaults, both within `BUILD_RUNNER_CEILINGS`, `3500m 12Gi`, #202: tacplus's gates were OOM-killed at 8Gi) and Trivy; the scanners run side by side, `BUILD_SCAN_JOBS` (the
  job's CPUs, at least 2) at a time, SpotBugs and CodeQL after them alone, each tool's time in the summary's
  `### Durations` and `security/durations.json`, a build's job sized `BUILD_SCAN_REQUESTS_<repo>`, else
  `BUILD_SCAN_REQUESTS` (`2 8Gi 3500m 12Gi`), a build's gitleaks not on the generated code (a nightly's is), and a
  land's Semgrep on the generated code reading only the files its base's build read differently
  (`semgrep-generated.sha256`, published with the findings), the base's findings for the rest (#207: a tacplus land's
  job took 49 minutes, Semgrep 29 of them on the generated sets; under 15 is to be seen on a tacplus land); the policy fails a secret and a HIGH/CRITICAL finding with a fix unless
  an unexpired `security-exceptions.yaml` entry accepts it (only in its `where`, a path or a glob, when it has one, a dependency's
  file too: `go.mod` for `golang.org/x/text@0.3.0 (go.mod)`, #183; an entry without one accepts its id everywhere and the report warns, #182); a land (a build with a base) fails only on the blocking
  findings it adds: its base commit's (`security-<repo>/<sha>`, each build's findings published as its commit's too)
  are `standing`, reported and the nightly's to file, while a nightly and a release fail on them (#180); a base no build published (a HISTORY.md, PROPOSALS.md or ROADMAP.md push) takes its nearest published first-parent ancestor's, up to 20 commits back, else the last nightly's, the summary naming the commit (#217); a service's generated tree (its root `tacplus.yaml`'s
  `output-name` in its `output-dir`) is tacplus's to scan: its SAST findings and secrets are kept aside (`security/generated.json`), not
  counted, its dependencies still checked (#108; blobstore's main, run by hand: 436 set aside); a SAST finding in test
  code (Rust's `#[cfg(test)]` modules and `tests/`, Go's `_test.go`, TS/JS's `test/` and `*.test.*`, Java's
  `src/test/`) is listed (`test: true`), never failing, a secret there still fails (#179); a finding in CI tooling (a dependency under `bin/` or `ci/`, the base image of a Dockerfile under `ci/`: `scope: tooling`) is listed, never failing a land, a nightly or a release, the rest `shipped` and failing as before (#225; the repositories' own `ci/security.sh`: cloud#101, cluster#55, fleet-seatrials#72); an unpinned `FROM` of a release Dockerfile (a builder stage's, a global `ARG`'s default) a HIGH finding (`pins`, `unpinned-from`) the nightly files, failing no run (#234); a recorded baseline per repository (#146,
  `security-baseline.json`, written by `looper-scan baseline`: MEDIUM, LOW and UNKNOWN findings counted per tool, rule
  and file, not line, are baselined, never new, so not filed; an issue's run is handed the repository's latest
  findings to record it from); SARIF and JSON reports, the new findings since the
  last nightly (the build project's generic package `security-<repo>`, version `nightly`, which only a nightly's
  report publishes: not the latest, which a land's build makes old, #211) and the standing HIGH/CRITICAL ones; the
  nightly agent scan reads the latest and files every finding failing the policy or HIGH/CRITICAL, not excepted,
  that no open issue names, new or not (what its model leaves unnamed, the looper files as one bug, #211); each
  summary names its run under its header (the pipeline, the job, the time it started), and a security job that left
  no findings (killed, timed out, its pod never scheduled, its runner lost) has its report publish as the latest a
  summary saying so (`no report`: its run, why, the last report, whose findings the latest still holds) and fail, the
  findings left as they were; the scan's prompt and an issue run's say which run the report is (#210: the
  nightlies of 2026-11-21 and 22 published nothing for ten repositories, and their scans read the last run's
  report as that night's); a release's image SBOM (CycloneDX, SPDX); the looper image's own Go binaries (#167, `looper-scan image`, the
  `Dockerfile`'s last step): `govulncheck -mode=binary` on every one under `/usr/local/bin`, under the same policy and
  `security-exceptions.yaml`, fails the image build (`image.yml`, a release's publish) before a push; a base-image
  binary (by the sha256 recorded after `FROM`) is attributed to tacplus-dev/tacplus, a stripped one said (by hand on
  main's image of 2026-11-16: the docker CLI's GO-2026-6859 alone failed it; the image now takes the CLI from
  `docker:29.10.0-cli` by digest, go1.27.4, and the build checks its Go, #177);
  tested with stubs shaped as the tools' output and with the real tools,
  and run by hand (`looper-scan local`: its reports in a directory its summary names, never in the tree it scans, #161) on
  tacplus and kernel; this repository's own tree passes its gitleaks, a gate
  (`tests/looper-secrets.test.sh`: a test's fake token is built at run time, #117); formal verification out of the gates (#74,
  tacplus-dev/tacplus#275, README: Formal verification): every release runs `just verify` beside the gates, and a
  verify run (input `verify: true`, main's head, no commit status) runs it only when `just verify-changed <the last
  verified commit>` says run or there is no record; its record (the job's artifact and the package `verify-<repo>`)
  keeps the last verified commit and result, and the nightly scan files a red one with `looper-verify` (one `bug` a
  failed harness with its counterexample, a comment on an open bug that names it). Nightly suggestions (#50, README: Suggestions): the
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
  pass, the hours ready issues waited at it, how often all reports were busy (and running) and the merge backlog, with advice to
  raise or lower it after two nights running, a raise only for waits while all its reports ran, else the pool's item
  `capacity/<pool>` (#92); a scan holds a queued report only in its resource group (#92); the capacity: queue p90, issues waiting for a VM and one more VM's cost
  a day, for Jody's manual scale-up, #72; the runs and tokens per model and the refused models, #136; every repository whose nightly published no report, and why, an item `nightly/no_report` always over, #220; the release lines and backports, #275: every open backport ready to merge (green, CLEAN, its main issue closed) with its age, oldest first, the lines with unreleased merges and the supported lines' CI, and `looper-recap act` labels a backport ready over 2 days `backport:ready`, files one `bug` per red supported line and dispatches each supported line's `ci.yml` nightly, which needs the looper's app to hold Actions: write) and classifies its items against the 7 nights (recurring: advice, ranked by the hours of waiting it
  would remove; transient and once: one line); the model writes the advice as Performance, Operability or Cost
  suggestions with cause, change, gain and numbers (`looper-suggest check` refuses advice without numbers), and the
  looper commits `suggestions/recap/<night>.md` and `.json` with them, for Jody's daily report. Trace propagation
  (#51, README: Trace propagation) is a standing rule of every work prompt: causal downstream calls carry the
  inbound `trace_id`, unrelated ones say so (`// trace: unrelated: <why>`), each such handler has a propagation test,
  and the outcome comment names the handlers checked and their tests; `looper-trace check` (in the image) reads Go
  and Rust handlers and flags a dropped `trace_id` and a missing test (a seam handed the `trace_id` as its own parameter, a row by value beside it, is credited through its callers' tests, #66); the nightly scan runs it on main for the model
  to verify and file as bugs (run by hand on tacplus-dev's services, 2026-11-02: gateway, oauth and mailbox flagged). Its manual macOS smoke (#36): a web run on `main` with the input `smoke: true`
  holds only `macos-smoke`, on the Mac runner (tag `macos`, Tart VM): arm64, `sw_vers`, Xcode 27.x, Swift. The per-repository identity pilot (#28) is removed,
  never deployed, superseded by the apps (#83, #111). The loopers' `GH_TOKEN`, `GITLAB_TOKEN` and
  `CLAUDE_CODE_OAUTH_TOKEN` are project variables of gitlab.com/tacplus-dev/looper, no longer group variables; the
  model's environment holds no GitLab credential (`MODEL_WITHHELD`), the kicker starts the pipeline with
  `LOOPER_TRIGGER_TOKEN` when it is set (#25); only the manager writes main, built and tested, not yet set up (#83;
  README, Only the manager writes main): `looper-ruleset apply` puts a ruleset on main in each public repository
  (restricted updates, no force-push or deletion; bypass: the `tacplus-manager` app and Jody; applied to the 28 public
  repositories 2026-11-05; admiral, skipper and fleetbox, 2 to 5 days without it, 2026-11-24, and since #233 the kicker and the plan start no report for a public repository whose `check`, with a report's token, fails, and each nightly scan files a failing one as a `bug` approved `priority:high` for the hub's `apply`, closing it once it passes), idempotent (since #96: GitHub omits `update_allows_fetch_and_merge: false`), with `check`
  and a live `probe` (the CI file's manual `looper-ruleset-probe`, whose script GitLab could not read until #94: the file
  on GitLab is still a691d64's until the hub copies main's); with the apps' variables set, every job's GitHub
  token is an app's, minted by `looper-token` from its id_token through WIF and KMS (its environment naming the key it
  may use; its key's version named whole since #95: the first cutover's `--key=... --version=1` was refused by
  gcloud itself, before any call to GCP; a refusal now logs gcloud's error, its class and the id_token's claims, and
  the CI file's manual `looper-token-diagnose` gives each environment's claims and each key's answer, the cutover not
  yet retried; the manager's token names `workflows: write` since #106, only with `LOOPER_MANAGER_WORKFLOWS=write` since #112 (the app does not hold it yet; asked for without the grant, GitHub refuses it with 422 and the token is minted without it, logged), and every call looper-token makes to GitHub has an end (#112); a report's names it only when its issue carries `looper:workflows`, set by someone with write access, #115; `image.yml` builds only on main and attests what it pushes, and the plan's jobs run the looper image by digest, the attested build of main's head, `ci/`'s files a pinned digest, and the recap compares `:main`'s digest with it, #115) and refreshed for the job's life as gh's configuration: `tacplus-manager`'s for the managers and the
  scans' commits to main, `tacplus-looper`'s (no bypass) for the reports, the scans' models, the kicker and the plan;
  a job that holds `GH_TOKEN` or a personal token refuses to run; the scan's model runs as `looper-scan`, in a clone of its own (#227: the looper runs no git
  there after it, copying out what it takes, and removes it), and leaves its PROPOSALS.md change for the looper to commit; the manager split in two (#90; README, Only the manager writes
  main): with the apps, a repository whose gates are not build jobs gets, for each batch, `looper-<repo>-verdict`
  (environment `looper-report`: its queued lands merged onto `looper/staging`, regenerated and gated, with no job
  credential in the gates' environment, staging pushed with the report app's token, the verdict its artifacts, a
  stale one another job left in the reused project dir cleared, #98; each green recorded as it is given, on
  `looper/green-<repo>-<n>`, so a land whose rebase gives the same tree on the same base tree, gate set, gates and
  image by digest, after a job cancelled or a batch not merged, reuses it and runs no gate, #191) and
  `looper-<repo>-manager` (`looper-manager`, `needs:` the verdict: no repository code, staging checked to be the
  commit the verdict named on the main it was built on, main fast-forwarded, the verdicts and HISTORY.md lines
  posted; a main moved by planning files alone, staging rebased onto it, #114; anything else moved or a conflict,
  nothing merged and the lands left queued); a pinned repository with the build trigger keeps
  the one manager, which with the manager's token runs no gates in its job and regenerates nothing; private repositories' issues get no report
  (`--visibility public`, `LOOPER_PRIVATE_REPORTS=1` to undo); the runner
  VMs' image and readiness (#43): `runner/startup.sh`, the templates' startup-script, marks a VM ready
  (`/var/run/runner-ready`) only once Docker answers, for the autoscaler's `instance_ready_command`; `runner-image build`
  (the build pipeline's `runner-image` job, input `runner_image: true`) bakes the image family `runner-arm64-docker`
  (Docker preinstalled) and publishes an image only once a VM booted from it is ready with nothing to install;
  `runner-image template` copies a template onto the family and the script; `runner-image measure` gives jobs'
  creation-to-"Running on" times; tested in an Ubuntu container and against stub gcloud and curl; two forges (#29):
  `LOOPER_FORGE=github` (gh, the default) or `gitlab` (the GitLab API through curl, `LOOPER_FORGE_TOKEN`, a git
  credential helper, the model's `glab`, in the image), every issue, clone and file call through `looper-lib.sh`'s
  `forge_*` functions, `Blocked-by: seabeam/<path>#N` (subgroups) on GitLab, an issue's URL read as its reference and an unreadable
  `Blocked-by:` line held (#87), a reference to another org held and never read, GitLab roles for prompt provenance; `looper-dispatch plan` writes the pipeline's child jobs, each where it runs (#84: the reports and manager of a repository whose gates are build jobs on the in-cluster control runner, `LOOPER_CONTROL_TAGS`, default `arm64, control`, with their kind's requests and limits as `KUBERNETES_*` variables, a report 150m/512Mi, a manager 250m/256Mi (#229, cluster#53: each kind's p90 of 2026-11-23, the cluster's slot count), the kicker and the plan 50m (#165: from the pods' use, limits unchanged; each pod logs its use at its end, the recap's requests against use per kind, an item once a p90 is over its request by more than LOOPER_RECAP_REQUEST_MARGIN, 10%), `LOOPER_REQUESTS_<kind>`; since #274 every job of every repository there once the project has the trigger and the apps, pinned or not, a split batch's verdict and merge with a manager's requests, no override read, so no looper job is planned on the VM pools' `autoscale` tags; without the trigger a report `LOOPER_JOB_TAGS_<repo>`, #55, a manager `LOOPER_MANAGER_TAGS_<repo>`, a scan `LOOPER_SCAN_TAGS_<repo>`, #91, else `LOOPER_JOB_TAGS`, else the control runner's) and the plan's git identity, on a schedule a scan per repository (#56),
  `ci/tacplus-dev.gitlab-ci.yml` is tacplus-dev's pipeline file, and `ci/instance.gitlab-ci.yml` is a GitLab-hosted instance's pipeline (kicker, plan, jobs, nightly scan); tested on
  both forges against a gh stub, a GitLab API stub and a stub git server, a SeaBeam issue worked end to end; release
  builds by branch (#252): the build pipeline's `release` input, `main` building `main-green`'s commit (never main's
  head), `release/X.Y` its head, `branches` or no repo a fan-out of each branch with something new, publishing
  `<repo>:<branch>-<commit12>` by digest to the release registry `us-central1-docker.pkg.dev/tacplus-ci/releases` as
  `release-publish@tacplus-ci` (#265; a tag's release to the build project's `BUILD_REGISTRY`, no default, refused
  without one: tacplus-dev/tacplus#223's to set); `release-report` moves `release-<repo>/<branch>/record` forward only (an
  older build never takes a newer one's place), sets `tacplus-dev/release/<branch>`, and records a red one, which the
  nightly scan files as an approved bug; `ci/build.gitlab-ci.yml` pins main-7c1dc4d's image (#261), whose
  `looper-build` has them (main-1fca965's, pinned before, ignored `release`); the green record names the tacplus it
  was built with (#262: `tacplus <commit> <build image>`, the pin's release tag's commit, unreadable red, none for
  `build.lock`), and a main record that moved starts fleet-seatrials' pipeline (its environment-scoped trigger token;
  a failed trigger logged, never red);
  on a looper VM (`looper-vm`, #238) a pinned GitHub repository's report `--land`s by opening a merge request (#250,
  step 4 of `tacplus-dev/roadmap:decisions/agentic-dev-flow-2026-11-25.md`): its own commits rebased onto
  `main-green` (main's head until #249 makes it), the set their diff calls for built locally (each local build's
  gates with a dockerd of their own, a privileged `docker:dind` sidecar as their `DOCKER_HOST`, #267, so an
  image-building set such as tacplus's `images` can pass on a VM; unchecked on the VM itself yet), and only on green
  `looper/mr-NAME-N` pushed at that commit and its pull request opened with its evidence (commit, base, gate set,
  verdict, the log on the run's checkpoint); red, no verdict or a conflict opens nothing; the issue
  `looper:merge-request` while it is open, freed by the VM's list and the kicker once merged or closed, its next run
  told which; the kicker (while `LOOPER_VM_REPOS` names a VM) starts each open one's build status in the build project,
  on its merge base and the set main's map gives its diff (`repo-looper --gate-set`), never the report's own; one run
  per issue by a forge claim, `looper/claim-NAME-N`, compare-and-swap, renewed, given up at the end and on SIGTERM (on a
  VM, and for a VM project's fallback report here); `LOOPER_VM_MR=0` in the VM's environment keeps its reports
  queueing with the manager (the hub's switch until the merger, #251); the merger reads its issue from
  `looper/mr-NAME-N` and takes `looper:merge-request` off on a merge or a send-back (left open: its next run is
  told so); the kicker's status (`tacplus-dev/build`) is not yet the merger's (`looper/gates`, PROPOSALS.md);
  `looper-merger pass --repo NAME` (#251, the agentic flow's step 5), a fixed program that reads and writes the forge
  alone: a merge request with a trusted login's green `looper/gates` status on its head (not yet set by the kicker's
  build, PROPOSALS.md) merged at once, unbuilt, as one merge commit at that head, while the rolling check's gate (`looper-check gate`,
  #249) is open, asked for each merge, a gate that cannot be asked closed; a conflicting one sent back to its issue
  once per head; an optional shadow compile measured, never required. `looper-vm merger --org ORG` is its machine's
  process (tacplus-dev/cloud#111: no socket, no model): a pass per repository with a merge request, as looper-token's
  `merger` role (its key and app settings, the manager's until tacplus-merger exists), and `looper-ruleset` adds the
  merger's own App as a bypass actor once it has one. Tested against stubs; live once cloud#111 pins an image with
  it and `looper-check` (PROPOSALS.md);
  the rolling check of main (`looper-check`, #249, in the image, tested with a stub builder and gh; `looper-vm check`
  the reserved machines' mode, a check per repository until all are idle, then exit 0 so the machine sizes to 0,
  `looper-check needed` the orchestrator's question for starting it, as the check's app, `looper-token`'s role
  `check`: `tacplus-check` once configured, else `tacplus-manager`):
  main's head on the full gates whenever main moved, back to back, green moving `main-green` (a VM's report starts
  its branch there), red the fixed procedure (run again for a flake; red on main-green too reverts and freezes
  nothing; else bisect the merges since main-green, propose the culprit's revert once the failed groups are green on
  the reverted tree, its issue ready again with the failure; else one "fix main" issue), its state
  `looper/rolling-check`, red on each new head until a green, naming the recovery's branch; `looper-check gate`, the
  merger's question before each clean merge, closed while the check is down (no `main-green`, off main's
  first-parent line, no state by `LOOPER_CHECK_LOGIN`), red but for the recovery's branch, at 4 merges unchecked or
  the oldest one gate's age old, and for a reverted change until it reverts the revert
- **Released / deployed:** `main` runs as the GitLab pipeline gitlab.com/tacplus-dev/looper, its kicker and plan as
  pods of the in-cluster `kick` runner (59685138, `arm64, kick`, tacplus-dev/cluster#39, #222: never behind the
  reports and managers they start), the pinned repositories' reports and managers and the hub's probes as pods of
  the in-cluster `control` runner (58541761, `arm64, control`, tacplus-dev/cluster#13, #84) once the hub copies `ci/tacplus-dev.gitlab-ci.yml` there
  and unpauses it (the hub's step after #84 lands; until then everything runs on the VM runners as before), no looper job
  needing Docker since #73, and since #274 (once `ci/tacplus-dev.gitlab-ci.yml` pins an image with it and the hub copies it) none planned on the VM runners' tags (`arm64, autoscale`:
  jody1-328023's *tacplus-dev arm64 autoscaler* and cloud's `ci` stack's `shared` pool, runner 58534919, which took #43's job of 2026-11-16, and roadmap's and fleetbox's scans, managers and verdicts until #274), image `ghcr.io/tacplus-dev/looper:main`; README (Infrastructure) gives the jody1 runner a fresh worker per job
  (`capacity_per_instance = 1`, `max_use_count = 1`, #42), which the hub applies on `gitlab-runner-mgr` after the
  runner image and readiness gate (#43); the `image` workflow builds and pushes `:main` after each land (a land does
  not wait for it), and a failed run on main opens or comments on a `bug` issue here (`image-failed`, #58) with the
  failed step's log tail, read by the jobs API since the report job runs inside the run it reports (#154)
- **Known gaps:** the merge request (#250) has no live merger yet (#251's goes live with #249's rolling check): nothing
  merges one, and a red build status on it stays until a person sends it back (the merger sends back conflicts alone); it takes effect on a VM with the image built after its land
  (tacplus-dev/cloud's looper_vms); its status build is the build project's, which the design retires later
  (PROPOSALS.md); branch releases (#252) publish nothing until the rolling check (#249) runs and makes `main-green`, tacplus-dev/cloud#112 adds
  their schedules, tacplus-dev/cloud#115's `apply:ci` the release registry and its provider, and the hub copies
  `ci/build.gitlab-ci.yml` there, pinning an image with #265; dev deploys from their records once tacplus-dev/fleet-seatrials#82 lands, and
  reads them and is triggered once tacplus-dev/cloud#117 sets the build project's job token allowlist, Reporter and
  `BUILD_SEATRIALS_TRIGGER_TOKEN` (until then `release-report` logs "seatrials not started"); a red
  release is filed at the next nightly scan, not at once (PROPOSALS.md); the rolling check (#249) runs nowhere yet: its reserved machines are tacplus-dev/cloud#111's, at 0
  until an image with `looper-vm check` is pinned (it signs as `tacplus-manager`, which then needs Commit
  statuses and Pull requests, until `tacplus-check` exists), its orchestrator (the merger's machine starting it on `looper-check
  needed`) is cloud's, and it goes live with the merger
  (#251), which asks its gate before each merge; until then the merge train builds every batch; the model per run (#136) is tested against a stub `claude`: the probe's reading of a refusal (an
  `is_error` result) and the `modelUsage` names are the CLI's as of 2026-11-13, unexercised against a spent quota; a
  high model refused mid-run (its quota spent during the run) is not retried on the default: that run ends, and the
  next run probes and falls back; the verdict job's gates (#90) still run a report's commits as its job's user,
  which writes the verdict the manager job trusts; the recap has not run against the live APIs yet (its first night does); it reads tacplus-dev/build's
  jobs with `GITLAB_TOKEN` (#85), its bot a Reporter there once tacplus-dev/cloud#12's `apply:gitlab` has run on
  main (until then `sources` names the 404), and the image's revision only where it has `docker buildx`:
  otherwise its `sources` says so; Cloud Build is not read (#85); one more VM's cost is the t2a-standard-8 on-demand list price (`LOOPER_RECAP_VM_USD_HOUR`,
  0.308) and one more node's the c4a-standard-2's (`LOOPER_RECAP_NODE_USD_HOUR`, 0.089, #84), not the billing's; a pod's wait
  for room is read from its job's log as the executor's preparation while it said `Pending` (the image pull included:
  GitLab's timestamped logs would separate them, PROPOSALS.md); a red main is read from the `tacplus-dev/build` commit status, which only a build of the
  merged commit sets (#71 redefines the build jobs);
  gitlab.com/tacplus-dev/looper's pipeline file is `ci/tacplus-dev.gitlab-ci.yml` here, whose
  `looper-plan` runs `looper-dispatch plan` (#56, tested against the hub's former inline plan), but it takes effect
  when the hub copies it there; until then that pipeline plans with its inline script (tacplus's jobs on the 16-CPU
  pool, #55, through its own `LOOPER_JOB_TAGS_tacplus`, its manager and scan too: #91's tags per kind take effect with the plan); README's "A fresh VM is ready before its job" (#43) is not hand-applied on
  jody1-328023 (the hub, 2026-11-03: the recap measured 0.24 h of waiting in 24 h, and lasting infrastructure comes
  from the cloud pipeline): the runner pools of tacplus-dev/cloud's `ci` stack (cloud#4, closed) boot a pinned
  Container-Optimized OS with nothing installed at boot, a `docker info` readiness gate and one VM per job, and the
  baked image is superseded (roadmap `decisions/builds-in-containers-2026-11-03.md`; `runner/` and `runner-image
  build`/`template` stay until the redesign retires them, never run against GCP); until the jobs move onto those
  pools a fresh worker installs and restarts Docker at boot under its first job, which fails in preparation and is
  retried; the VMs get no fix (Jody, 2026-11-06): #84 (closed 2026-11-16) moved the agents' jobs onto the in-cluster
  control runner, and no looper job needs Docker since #73, and
  tacplus-dev/cloud#113 removed cloud's `ci` pools and manager and tacplus-dev/cloud#11 (*No VMs outside GKE*, both closed
  2026-11-27) lists jody1-328023's interim VMs (unused, runners paused) for Jody to delete with the project; #43 is
  blocked by tacplus-dev/cloud#15 (jody1-328023 deleted) and closes when the VMs are gone, with no
  `runner-image measure` tables (no looper job has a GitLab `read_api` token to take them); until the hub applies the worker per job (README, Infrastructure, #42), a looper worker
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
  build jobs (#71, README: Build jobs) are started by the managers of pinned repositories (2026-11-09: blobstore,
  opa and four others), but those builds set no status for hours, no runner took their jobs, and the managers waited
  on them in silence until cancelled; since #113 such a build is "no runner" within `LOOPER_BUILD_START` (15 minutes),
  the land left queued, and since #112 every gh, curl and git call has an end, a land's log lines reach the manager's
  job log as they come, and a build waited for is said so every `LOOPER_BUILD_SAY` (10 minutes); they take effect for
  a repository once its commit is pinned (only this one is: `build.lock`; the hub files the others' pin issues) and
  the report and manager jobs hold `BUILD_TRIGGER_TOKEN` (not yet set in tacplus-dev/looper), and need the hub's copy
  of `ci/build.gitlab-ci.yml` (the `gates` and `base` inputs); without the trigger a pinned repository's manager runs
  the gates in its own job (with the apps, its verdict job: #90) and its report's model has no container runtime and no
  build (#73); since #73 an unpinned repository's report and land stop at once, saying to pin it first (every
  tacplus-dev repository with code is pinned, fleetbox last, fleetbox#9; a SeaBeam instance, `LOOPER_FORGE=gitlab`,
  parked, has no build path at all: PROPOSALS.md); a pinned repository's scan has no gates record to read until the first nightly fan-out
  after the next looper image (`gates-report` is in that image's plan): until then its prompt says none was read and
  asks for no gates run; a release's publish with
  rootless BuildKit has not run yet: no published build image has `tacplus-image-build` (tacplus#315 is open; the
  2026-11-16 scheduled images.yml run on main failed on amd64 and published none), so `BUILD_BUILDER_IMAGE` is empty
  (#172 pins it once one is: PROPOSALS.md) and publish still runs with Docker on `BUILD_DOCKER_TAGS`, `arm64,
  build-docker`, the VM build pool's own tag (tacplus-dev/cloud#70; #172), never the in-cluster `build` runner's, and
  no gate set needs Docker (README: Build pipeline); `macos-smoke` (#36) has not run yet: the hub copies
  `ci/build.gitlab-ci.yml` into tacplus-dev/build and plays it once (no CI file here is linted or run by a test); a report's memory limit is per container and the model's `docker` only, not a boundary: `docker compose`, `docker build`'s containers, the real docker by its path and processes in the job's own container are unlimited, as are the manager's gates (#41, PROPOSALS.md); text the model reads itself during a run other than through
  `--issue-text` and `--pr-text` (its own `gh`, a nightly scan's reads) is not wrapped: only the prompt's rule on authors guards it (#219, PROPOSALS.md); the build pipeline always
  run the full gates unless the manager or a report's `--build` names a set (#71) (PROPOSALS.md); the security checks (#49) have run only by hand (`looper-scan local`), not in
  tacplus-dev/build: they start with the next looper image and the hub's copy of `ci/build.gitlab-ci.yml` (the
  `nightly` input; one schedule, `{"nightly": true}` with no `repo`, fanning out to each pinned repository's nightly,
  #164, which cloud#65 puts in place of its schedule per repository; a nightly's and a verify run's child pipeline got the parent's empty
  `BUILD_SHA` until #138, whose fix, the `gates` trigger forwarding no variables, starts with that copy too), and on the day they start tacplus's build fails them (gosec's HIGH
  findings, six OSV advisories with fixes) as kernel's does (gitleaks: PEM markers in its Java) until each is fixed
  or accepted in a `security-exceptions.yaml` (PROPOSALS.md), and tacplus has no `generated` recipe yet, so its
  cross-test models are not scanned; the suggestion pass (#50) has run only against a stub roadmap: it starts with
  the next looper image, on the roadmap's nightly scan, and the hub's daily review (the sitrep, `looper-suggest
  decide`) is the hub's to wire; formal verification (#74) has run only against stubs: it starts with the next
  looper image and the hub's copy of `ci/build.gitlab-ci.yml`, and its schedule (`verify: true`, tacplus) stays
  inactive until tacplus-dev/tacplus#211 and #257 make it pass; until then a tacplus release fails its verify job;
  no release line yet; the image's Syft carries GO-2026-6905 (github.com/blakesmith/ar, no fixed version: a crafted
  `.deb` panics it and fails the security run closed), accepted in `security-exceptions.yaml` until 2026-12-13 (#142):
  from 2026-12-14 looper's builds fail on it until it is renewed or fixed, and the nightly scan files it again then or
  once a fixed version is published; the image replaces `build:2.6`'s docker CLI (29.9.3, go1.26.10, net/http's
  GO-2026-6859) with 29.10.0's by digest (#177, the #166 exception gone) until `build:2.6` itself carries 29.10.0 or
  later, or #73 step 3 removes the CLI; it replaces `build:2.6`'s npm (11.21.1, ip-address 10.7.2's
  GHSA-rxp7-6hxx-x8q5) with 11.21.3 (#186) until `build:2.6` itself carries 11.21.3 or later; it builds Trivy and
  OSV-Scanner with otel v1.47.0 (GO-2026-6974) and gosec with gorilla/websocket's untagged fix (GO-2026-6278), versions
  upstream did not test, smoke-scanned (#199), until a release of each requires them; it replaces `build:2.6`'s gh
  (otel/trace v1.44.0, GO-2026-6974; gorilla/websocket v1.5.3, GO-2026-6278) with gh 2.105.0 built here on the same
  websocket fix (#199) until `build:2.6` carries a fixed gh (tacplus-dev/tacplus#969)
- **Blocked on:** #15 (the looper image separate from the build image) waits on the build pipeline (#17);
  publishing waits on tacplus-dev/tacplus#223 (Artifact Registry and WIF)
