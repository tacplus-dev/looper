# Roadmap: looper

Owned by Jody; changed only by an agent at Jody's request. Loopers propose in PROPOSALS.md.

## Now
The per-repository loopers of tacplus-dev: `looper-dispatch` on the Mac starts the GitLab pipeline, whose `repo-looper` jobs work each repository's `approved` issues; plus the nightly scan and the hourly SeaBeam port scan.
Unreleased (no tags); the image is the tacplus 2.4 build environment (#1).

## Next
- Retire GitHub Actions in every repo; a gate refuses any workflow file (#18, after #17)
- Build pipeline: (repo, commit) → pinned build image, no agent, read-only source → pass/fail + image (#17)
- Looper image separate from the build image; branch → start a build → land on main only on a passing build (#15, after #17)
- Loopers keep STATE/HISTORY/PROPOSALS, never ROADMAP; CI check for the four files in every repo (#13)
- Org secret TACPLUS_REGISTRY_TOKEN for release CI (#12) (needs Jody's decision)

## Later
- A protected release line with review, instead of pushing to main (README)
- Doppelganger decides resource requests (more loopers, new repositories) instead of fixed rules (README)
- A project looper that works from roadmap epics and files issues to repo loopers (tacplus-dev/roadmap:items/looper-hierarchy.md)

## Not doing
- Cloning or building on the Mac: all looper work runs as GitLab pipeline jobs (Jody, 2026-10-26, README)
- Porting anything else from SeaBeam: since 2026-10-27 only stratum still comes over; every other unmapped source is retired, never ported or reported (#5, #6)
