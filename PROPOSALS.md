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

## Promoted / declined
