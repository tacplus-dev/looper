# State: looper

Overwritten to stay current (loopers and agents). Last updated: 2026-10-29 by looper (#17).

- **Version / line:** unreleased (no tags); the image `ghcr.io/tacplus-dev/looper:main` is built FROM the tacplus
  `build:2.5` environment (#1, #26); no tacplus floor of its own (the `tacplus` wrapper runs each repository's floor)
- **Works:** the kicker (`looper-dispatch`, in the image) runs as the GitLab pipeline's hourly kicker schedule, a
  pass every 3 minutes that reads GitHub for the whole org in three requests, never two kicker jobs at once, nothing on
  the Mac (#24); it starts the pipeline; neither it nor the pipeline's plan
  (`repo-looper --list`) starts another job for a repository whose looper job is created, pending, waiting
  for its `resource_group` or running, and a planned job whose issue was taken meanwhile works the oldest
  ready one (#16); a run killed outright no longer leaves `looper:in-progress` behind: the job for its issue
  resumes it when no other looper job of the repository is active, and `looper-dispatch run` clears the label
  from an issue no looper job holds (#20); a run whose job GitLab no longer reports running (marked failed while
  its container goes on) checkpoints and stops within one poll, pushing and commenting nothing, so it cannot race
  its retry (#21); `repo-looper` works each repository's
  `approved` issues (checkpoints and resume, per-issue time limit, idle and done watchdog, Blocked-by outcomes, one or more,
  also from a run that pushed nothing because the issue waits on another, #22);
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
  and with a real buildx (same commit, same digest). The loopers' `GH_TOKEN`, `GITLAB_TOKEN` and
  `CLAUDE_CODE_OAUTH_TOKEN` are project variables of gitlab.com/tacplus-dev/looper, no longer group variables
- **Released / deployed:** `main` runs as the GitLab pipeline gitlab.com/tacplus-dev/looper on the
  *tacplus-dev arm64 autoscaler* runner, image `ghcr.io/tacplus-dev/looper:main`
- **Known gaps:** the kicker uses the group's `GITLAB_TOKEN` (api scope), not a project access token, which
  gitlab.com's Free tier does not offer; its job keeps a runner worker up around the clock (see PROPOSALS.md);
  the Mac's launchd kicker is removed by the hub with Jody (`looper-dispatch uninstall`) once it has run green
  for a day; the ROADMAP.md guard is a pre-push hook in the looper's checkout, so a push that skips hooks
  is not refused (see PROPOSALS.md); no release line yet
- **Blocked on:** #15 (native build image) waits on tacplus#193; no build runs until the hub applies the build
  runner (README, Build pipeline) and publishing waits on tacplus-dev/tacplus#223 (Artifact Registry and WIF); every
  build fails "no pin" until a repository commits a `tacplus.lock`
