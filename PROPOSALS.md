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

## Promoted / declined
