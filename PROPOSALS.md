# Proposals: looper

Written by loopers. Each proposal: what, why, links. Jody promotes accepted ones into ROADMAP.md (via an agent);
the looper then marks it `promoted` or `declined` here with the date.

## Open
- **ROADMAP.md guard that a model cannot skip** (2026-10-27, #13): repo-looper refuses a push touching ROADMAP.md
  with a pre-push hook in its checkout, which `git push --no-verify` skips. Once main is protected (README, Later),
  require Jody's review for ROADMAP.md (CODEOWNERS); until then, repo-looper could also check the run's pushed
  range (`head_before..head_after`) after the run and mark the issue `looper:stuck` if it touched ROADMAP.md.
- **Pin the planning-files check to the caller's ref** (2026-10-27, #13): the reusable workflow checks out
  `planning-files-check` from tacplus-dev/looper `main`, whatever ref the caller pinned; fine while every caller
  uses `@main`, wrong if one pins a tag.
- **Port issues and the roadmap** (2026-10-27, #14): port issues are `feature` + `approved`, so a port range that
  no ROADMAP.md links gets a design proposal and `needs-decision` instead of being ported, and a live roadmap entry
  for a port turns new SeaBeam commits into a prioritization issue. If ports are meant to flow without a roadmap
  step (Jody's standing decision, #6), either file them as `bug` or let repo-looper treat a `Port SeaBeam` issue
  filed by the scan as on the roadmap.
- **Patch tags on release branches** (2026-10-27, #14): a bug's backport pull request names the patch tag to cut
  once it merges, but nothing cuts it; a release-branch workflow (or the looper, on the merge) could tag it.
- **Check that a bug's patch shipped** (2026-10-27, #14): the patch release is the prompt's rule; repo-looper could
  comment when a run closes a bug in a released repository without a new tag on main.
- **Hold the proposal run to PROPOSALS.md** (2026-10-27, #14): a feature that is not on a roadmap is only proposed,
  but the guard is the prompt; repo-looper could refuse (pre-push hook) any push from that run touching other files.
- **The scan's label guard by issue number** (2026-10-27, #14): after the nightly scan, issues numbered after the
  newest one before it are taken for the scan's; one a person opens during the scan would get `bug` or lose
  `approved` too. Filing through a wrapper that records what the scan filed would make it exact.
- **The plan's script in this repository** (2026-10-27, #16): `looper-plan` is a script in
  gitlab.com/tacplus-dev/looper's `.gitlab-ci.yml`, outside this repository and its tests; #16's busy check lives in
  `repo-looper --list` so it ships with the image. A `repo-looper --plan` that writes `looper-jobs.yml` would put the
  whole plan under test here and leave the GitLab file one line. Its comment also still says the Mac starts the
  pipeline "when no looper pipeline is running", where it is now per repository.
- **The plan in priority order** (2026-10-30, #31): `looper-plan` (gitlab.com/tacplus-dev/looper's `.gitlab-ci.yml`)
  writes one job per repository in the order of `gh search issues ... | sort -u`, by name, so when runners are short
  GitLab starts them in that order whatever their priority. Its loop over
  `$(looper-dispatch ready | cut -d' ' -f1)` instead plans a repository whose next ready issue is `priority:high`
  first (keeping `repo-looper --list` for the busy check), and saves the search; the hub changes that file. A
  `repo-looper --plan` (above) would put that order under this repository's tests.
- **Priority within a capacity-short pipeline** (2026-10-30, #31): the order holds only as far as GitLab starts
  pending jobs in creation order. A `priority:high` issue whose repository's job is already pending behind its
  `resource_group` waits for it; a separate high-priority runner tag or GitLab job priorities would make it firm.
- **A run's limit within its job's timeout** (2026-10-27, #16): a planned job whose issue was taken meanwhile works
  the oldest ready issue instead, but keeps the job timeout computed for the planned one; if the new issue asks for a
  longer `Timeout:`, GitLab stops the job before the model's limit (its work survives as a checkpoint).
  repo-looper could cap the run's limit at `CI_JOB_TIMEOUT` less the hour it reserves.
- **An orphan's last checkpoint and its retry** (2026-10-28, #21): a run whose job GitLab no longer runs stops within
  one `LOOPER_JOB_POLL` and checkpoints to `looper/<repo>-<n>`; a retry that has already resumed from the branch
  meanwhile overwrites that checkpoint with its own (force-with-lease against what it read), losing at most that
  interval's work. The retry could wait one poll interval before resuming when the job it retries was the issue's
  last checkpointer (`CI_JOB_URL` is in each checkpoint's record), or merge a newer orphan checkpoint in.
- **The job poll and the job token** (2026-10-28, #21): with only `CI_JOB_TOKEN`, an orphan is told by GitLab
  refusing the token (`GET /job`, HTTP 401) after it was accepted; a token that never worked (an instance that limits
  job-token API access) leaves the poll blind and the run going. `GITLAB_TOKEN` (read-only) in the looper jobs'
  variables makes it exact (`GET /projects/:id/jobs/:id`), and is worth checking in the GitLab project's settings.
- **Say why a Blocked-by outcome was rejected** (2026-10-29, #22): an outcome naming a closed or missing issue, or
  the issue itself, is rejected whole and the issue is `looper:stuck` with the generic "ended without finishing"
  comment; naming the rejected blocker and the reason in that comment would save the person a trip to the run record.
- **The realign's fail-closed match** (2026-10-29, #23): the port scan sends to `needs-decision` any untrailered
  SeaBeam commit whose message contains `tacplus-dev` (any case) or a `Ported-from:` line, so a genuine change that
  merely mentions tacplus-dev (a pinned image, a link) waits on a person too. If that proves noisy, narrow it to
  references (`tacplus-dev/<repo>#N`, `@<sha>`, GitHub URLs); a realign commit that lacks its trailer cannot be
  amended in SeaBeam's history, so a person moves the target's mark past it.
- **The flood guard's issue goes stale** (2026-10-29, #23): while *Port scan: flood guard tripped* is open, a scan
  still over the limit files nothing and does not update it, so its list is the first run's. A comment when the
  list changes (as the unmapped tracking issue gets) would keep it current.
- **A narrower credential for the kicker** (2026-10-29, #24): the issue asked for a project access token with `api`
  scope, held as a protected project variable; gitlab.com's Free tier does not offer project access tokens (an Owner
  gets "does not have permission"), so the kicker uses the group's `GITLAB_TOKEN`, which already has `api` and
  `write_repository`. A pipeline trigger token (protected project variable, `POST /projects/:id/trigger/pipeline`)
  could only start pipelines; the kicker would still need a read token for the jobs. Or a paid tier's project token.
  Done in #25 (2026-10-30): the trigger token for the start, a `read_api` bot for the reads (README, Credentials).
- **The model reads its parent's environment** (2026-10-30, #25): `repo-looper` withholds the GitLab credentials from
  the model's environment, but the model runs as the job's user, so `/proc/<parent>/environ` still holds them; and
  every `curl -H "PRIVATE-TOKEN: ..."` puts its token on a command line any process of the job can read. Running the
  model as another user (or in a sandbox without the job's processes), and headers from a file (`-H @file`), would make
  the withholding a boundary; until then the tokens' reach is (README, Credentials).
- **Rotate the bots' tokens** (2026-10-30, #25): `tacplus-looper-bot`'s and `tacplus-port-reader`'s tokens and
  memberships expire within a year; nothing reminds anyone. A scheduled check of `GET /personal_access_tokens/self`
  (`expires_at`) filing an issue a month ahead would.
- **Whether fleet-seatrials' key material counts as exposed** (2026-10-30, #25): the jobs' former `GITLAB_TOKEN`
  (`api`, Owner) could read fleet-seatrials' protected variables, `FLEET_CRYPTO_YAML` among them, since they were
  stored. Jody decides whether to re-key (a fleet re-init, `deploy/init.sh` in fleet-seatrials).
- **The kicker holds a worker around the clock** (2026-10-29, #24): its job runs 57 minutes of every hour on the
  autoscaled arm64 runner (t2a-standard-8 workers, size 0 at rest before), in the full looper image, for a few `gh`
  and `curl` calls. A small runner of its own (a tag on the manager VM, say) or a slim image would cost a fraction;
  a paid tier's 5-minute schedules would let a one-pass job end in seconds.
- **The loopers' GitHub budget** (2026-10-29, #24): every looper job, the plan, the scans and the kicker share
  `GH_TOKEN`, and so one user's 5000 GraphQL points an hour (the Mac's `gh` login too, while it runs the old kicker).
  The kicker's pass used about 270 (now three requests); on 2026-10-29 the budget ran out at 06:36 and a run's own
  `gh` calls failed with it. A GitHub App installation token for the loopers (5000+ an hour of its own, per
  installation) would take them off a person's budget; `repo-looper --list` could also use `ready_by_repo`.
- **The port scan runs every two hours, not hourly** (2026-10-29, #24): gitlab.com runs this group's schedules at
  most hourly, on the hour, and a schedule's next run is the first hour after its cron's next time; so the port
  scan's `7 * * * *` fires at 21:07, 23:07, 01:08... (its pipelines on 2026-10-28/29). Its cron `0 * * * *` would
  make it hourly, as README says.
- **Pin the build pipeline's own image** (2026-10-29, #17): `ci/build.gitlab-ci.yml` runs plan, status and publish
  in `ghcr.io/tacplus-dev/looper:main`, a moving tag, and that image carries the claude CLI (inert there: the build
  project holds no Anthropic credential). A digest written by the image workflow, or a slim `looper-build` image
  (git, curl, jq, openssl, gcloud, buildx), would make the orchestration as fixed as the gates' image.
- **Keep ci/build.gitlab-ci.yml in step with the build project** (2026-10-29, #17): it is copied into
  gitlab.com/tacplus-dev/build by hand (as fleet-seatrials' is). A job of the looper pipeline, or the image workflow,
  could commit it there when it changes on main, or the build project could `include:` it from a project that
  mirrors this repository.
- **Line tags for released images** (2026-10-29, #17): publish pushes `<repo>:X.Y.Z` only. The services' GitHub
  release workflows also move `X.Y` (scripts/release-tags.sh) for fleets that pin a line; a step after publish,
  through the same federated token, could move it when the release is its line's highest.
- **Private dependencies in a release image** (2026-10-29, #17): publish's `docker buildx build` gets no credential,
  so a Dockerfile that fetches private tacplus-dev modules cannot. A BuildKit secret (`--secret id=github,env=...`)
  holding the read-only token would give it one without it landing in a layer.
- **Gates that need the reader app's key** (2026-10-29, #17): the gates job mints its read-only token, then deletes
  the app's key file before the repository's code runs, because the key could mint tokens with the app's every
  permission (commit statuses). Scoping `TACPLUS_READER_APP_KEY` to environments that only plan, status and publish
  declare would keep it from the gates job altogether; the gates would then need their token from elsewhere (a
  short-lived token passed in a masked, expiring way).
- **The build trigger's owner needs Maintainer** (2026-10-29, #28): D5 has the commit job start `tacplus-dev/build`
  with a trigger token owned by a bot that is a Developer there. GitLab runs a triggered pipeline as the token's owner,
  and on a protected main only a user allowed to merge to it may run one; GitLab Free grants that by role, so the bot
  must be a Maintainer of `tacplus-dev/build` (its token is revoked once the trigger exists, so only the trigger token
  is stored). Alternatives: let Developers merge to build's main (they could then merge changes to its CI), or have the
  build project watch pull requests itself.
- **The pilot's think job and releases** (2026-10-29, #28): a bug fixed through `repo-looper --think` lands by GitHub's
  squash merge; nothing tags the patch release or opens backport pull requests yet (the old prompt's rule 7 had the
  model do both with Jody's token). The commit job could tag after the merge, or a release step of the build pipeline.
- **The think job's classify and propose** (2026-10-29, #28): an unlabelled issue, or a feature no ROADMAP.md links,
  is answered `question` with a fixed text; the old flow had the model classify it, or write a design proposal into
  PROPOSALS.md. Both fit the think/commit split (the model writes, the commit job labels or opens the pull request).
- **HISTORY.md's line by pull request** (2026-10-29, #28): the think job appends the issue's line before the gates, so
  it names the pull request, not the commit (GitHub's squash commit does not exist yet). A step after the merge could
  rewrite nothing (append-only) but append the commit; or the line format could accept a pull request link.
- **A think job killed outright loses its work** (2026-10-29, #28): it cannot push, so its checkpoints only record the
  step; the commit job keeps what a run that ended left (`looper/<repo>-<n>`), but a VM lost mid-run leaves nothing.
  Its work could ride in the job's artifacts at each checkpoint (`artifacts:when: always` only covers a job that ends).
- **Keep ci/looper.gitlab-ci.yml in step with each looper's project** (2026-10-29, #28): copied by hand, as the build
  project's is (above); one file for every repository's project, so the follow-up's rollout could generate the
  projects, keys and bindings from one repository list (SYNTHESIS 4).

- **Parallel children in the think/commit flow** (2026-10-30, #32): the parent and its children run in the pipeline
  job of `tacplus-dev/looper`; kernel's identity pilot (#28) still runs one `prepare`/`think`/`commit` child pipeline
  per run under its `looper` resource group. Its parent would plan as here and start one child pipeline per issue,
  each with its own think and commit jobs; landing there is GitHub's squash merge of each pull request, so the lock
  becomes the merge itself (or a merge queue), with the gates re-run by the build on the rebased head.
- **Size the job for what fills a slot later** (2026-10-30, #33): `--job-timeout` now sizes the job for the
  longest limit among the issues ready at planning time, so they can all start together; an issue that becomes ready
  later, or one that waits for a free slot and then needs the whole limit, starts only if it still fits the job's
  remaining time. Sizing for a second round (the longest limit plus the next one's, at most 11h) would trade that for
  a job held longer when a run hangs. Also: `looper-plan` (gitlab.com/tacplus-dev/looper's `.gitlab-ci.yml`) takes
  the timeout from `--job-timeout` as before, so it needs no change, but it is still outside this repository's tests.
- **The plan's areas, kept** (2026-10-30, #32): each plan asks the model about every running and candidate issue
  again (tokens are not the concern, but a plan takes minutes). The parent could keep each issue's areas from its
  first plan and ask only about the new ones, and the record could show how well the areas matched what landed
  (`git diff --name-only` of each child's commits), to tune the planning prompt.
- **A landing lock across jobs** (2026-10-30, #32): the landing lock is a file lock in the job's work directory,
  which serializes the children of one parent; one parent per repository (the `resource_group`) is what makes it the
  repository's. A second writer of main (a person, the scan's PROPOSALS.md commit) only makes a landing rebase and
  retry. If a repository ever gets two parents, the lock would have to be on GitHub (a merge queue, or a ref the
  landing creates and deletes).
- **The landing guard is a hook** (2026-10-30, #32): a push to main from a child's worktree other than `--land` is
  refused by the checkout's pre-push hook, which `git push --no-verify` (or setting `LOOPER_LANDING`) skips, as with
  the ROADMAP.md guard (above). Main's protection with a required check (the build pipeline's status, #17) would
  make "broken work never lands" hold for any push.
- **Time a land out of the model's limit, not only out of its loss** (2026-10-30, #34): the parent's lander now owns
  every land, so a child's limit no longer loses a finished fix; but the model still waits for the lock and the gates
  inside its limit, and when the limit fires first the next run (a later job) only comments and closes. The child's
  limit could pause while its land is queued or running (the watchdog already sees it), or the parent could finish
  the issue itself after landing it when the run's last checkpoint says nothing else is left.
- **Size the job for the lands left queued** (2026-10-30, #34): the parent waits for the lander before the job
  ends, inside the hour the job keeps for itself; with full gates over an hour (tacplus, 2026-10-30) a queue of two
  can outlast it. `--job-timeout` or the plan's deadline could count a land per child (the repository's last gates
  time, say).
- **A transient read failure is not stuck** (2026-10-30, #34): a feature whose platform roadmap cannot be read is
  still `looper:stuck`; a GitHub hiccup there needs no person. It could stay `approved` and be retried a few times
  before it is held.
- **Let the build image's launcher pick tacplus** (2026-10-30, #27): the wrapper now downloads, verifies and
  caches the release itself, as tacplus's `images/tacplus.sh` does, because `build:2.5` has no launcher (it came
  with tacplus#193, from 2.6) and the launcher refuses a repository without `tacplus.lock` (none has one yet, opa
  included). Once every supported line's build image has the launcher and the repositories pin, the wrapper could
  run the image's own `tacplus` and drop its copy of that logic.
- **The smoke's tacplus line** (2026-10-30, #27): `looper-smoke` generates Go at the image's own line
  (`LOOPER_TACPLUS_LINE`, the Dockerfile's `TACPLUS_LINE`); a repository on an older supported floor (2.4) is
  covered only by the wrapper's test. It could loop over every supported line.
- **Cap the think job's limit at its job too** (2026-10-30, #35): a parent's children now cap an issue's `Timeout:`
  at the job's deadline; the identity pilot's think job (`--think`, `timeout: 5h` in `ci/looper.gitlab-ci.yml`)
  still takes the issue's limit as is, so a `Timeout: 6h` there is killed by GitLab. It could use the same cap
  (`job_deadline`), with a margin sized for its gates rather than the parent's hour.
- **Size the job when it starts, not when it is planned** (2026-10-30, #35): `--job-timeout` reads the issues when
  the plan job runs; a `Timeout:` line added while the job waits for a runner now only shortens that run (capped), and
  the next job resumes it. The kicker could re-plan a pending job whose issues' limits grew.
- **Check the CI files' rules in a test** (2026-10-31, #36): no test reads `ci/build.gitlab-ci.yml` or
  `ci/looper.gitlab-ci.yml`, so which pipeline shapes their workflow and job rules admit (a push: none; `(repo, sha)`:
  the build; `smoke: true`: only `macos-smoke`) is reviewed by hand. GitLab's CI lint (`POST /projects/:id/ci/lint`,
  `dry_run`) with a read token in the image's CI, or a small rules evaluator in a test, would catch a rule that lets a
  smoke run report a status or a push create a pipeline.

## Promoted / declined
- **A manual macOS smoke job in the build pipeline** (2026-10-31, #36): `ci/build.gitlab-ci.yml` gets a `smoke`
  boolean input (default false) and a workflow rule for a web run on `main` with it set, whose pipeline holds only a
  manual `macos-smoke` job (tag `macos`, the Tart image `macos-tahoe-xcode:27.1`, no credentials) checking arm64,
  `sw_vers`, Xcode 27.x and Swift; the build's own jobs and publish get rules that leave it. It proves Jody's Mac
  runner before tacplus#195's `swift:` and darwin/arm64 `rust:` recipes rely on it. Approved, but no ROADMAP.md
  links it (tacplus's lists #195 only); the design and Jody's questions are on the issue.
  **Promoted** (2026-10-30, ROADMAP.md Next; built 2026-10-31, #36).
