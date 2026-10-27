# State: looper

Overwritten to stay current (loopers and agents). Last updated: 2026-10-27 by looper (#16).

- **Version / line:** unreleased (no tags); the image `ghcr.io/tacplus-dev/looper:main` is built FROM the tacplus
  `build:2.4` environment (#1); no tacplus floor of its own (the `tacplus` wrapper runs each repository's floor)
- **Works:** `looper-dispatch` on the Mac starts the GitLab pipeline; neither it nor the pipeline's plan
  (`repo-looper --list`) starts another job for a repository whose looper job is created, pending, waiting
  for its `resource_group` or running, and a planned job whose issue was taken meanwhile works the oldest
  ready one (#16); `repo-looper` works each repository's
  `approved` issues (checkpoints and resume, per-issue time limit, idle and done watchdog, Blocked-by outcomes);
  it appends HISTORY.md's line for each closed issue and release, creates missing planning files from the
  tacplus-dev/roadmap templates, and refuses a push that touches ROADMAP.md (#13); the nightly scan; the hourly
  SeaBeam port scan (stratum only, #5); the `tacplus` wrapper with GitHub credentials for the compiler container
  (#11); the reusable planning-files CI check (`.github/workflows/planning-files.yml`, #13); the issue flow (#14):
  `bug` and `feature` labels in every repository, unlabelled issues classified first, bugs fixed and released as
  the next patch, features built only when a ROADMAP.md links them (else a design proposal and `needs-decision`),
  the scans file bugs as `bug`, never approve a feature, and read the roadmaps before opening an issue
- **Released / deployed:** `main` runs as the GitLab pipeline gitlab.com/tacplus-dev/looper on the
  *tacplus-dev arm64 autoscaler* runner, image `ghcr.io/tacplus-dev/looper:main`
- **Known gaps:** the ROADMAP.md guard is a pre-push hook in the looper's checkout, so a push that skips hooks
  is not refused (see PROPOSALS.md); no release line yet
- **Blocked on:** #15 (native build image) waits on tacplus#193
