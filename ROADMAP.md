# Roadmap: looper

Owned by Jody; changed only by an agent at Jody's request. Loopers propose in PROPOSALS.md.

## Now
The per-repository loopers of tacplus-dev: `looper-dispatch` on the Mac starts the GitLab pipeline, whose `repo-looper` jobs work each repository's `approved` issues; plus the nightly scan and the hourly SeaBeam port scan.
Unreleased (no tags); the image is the tacplus 2.4 build environment (#1).

## Next
- Per-repository runner tags: tacplus jobs on the 16-CPU pool (runner 58307468), others unchanged (#55). Agent, at Jody's request, 2026-11-02.
- Standing rule: trace propagation implemented and tested in every service's handlers, verified by loopers and the nightly scan (#51) (Jody, 2026-11-01)
- Nightly suggestions: the roadmap scan writes evidenced platform suggestions for Jody's daily review; rejected kept with reasoning (#50) (Jody, 2026-11-01)
- Deterministic security checks in the build pipeline: SCA and SAST on source and generated code, SBOM per release, fail on HIGH/CRITICAL with expiring exceptions (#49) (Jody, 2026-11-01)
- Gates scaled to the diff: a per-repo gate map picks what a land runs; unmapped paths, gate-map changes, nightly and releases run everything (#48) (Jody, 2026-11-01)
- Parent looper runs child loopers in parallel; the parent decides concurrency (#32)
- Priority labels order the ready queue (#31)
- GitLab forge backend; a SeaBeam instance (kicker, runner, credentials) in the seabeam group (#29)
- Looper identity, pilot on kernel: one identity per repository, think/commit split, app JWT signed in KMS (#28)
- The kicker runs as a scheduled GitLab pipeline; nothing on the Mac (#24)
- Retire GitHub Actions in every repo; a gate refuses any workflow file (#18, after #17)
- Build pipeline: (repo, commit) → pinned build image, no agent, read-only source → pass/fail + image (#17)
- Prompt provenance: issue and PR text in per-run nonce blocks; only members' text directs a run (#40) (Jody, 2026-10-31)
- Build pipeline: a manual macOS smoke job on the Mac runner (tag `macos`, Tart VM), the first piece of tacplus#195's macOS builds (#36) (Jody, 2026-10-30)
- Looper image separate from the build image; branch → start a build → land on main only on a passing build (#15, after #17)
- Loopers keep STATE/HISTORY/PROPOSALS, never ROADMAP; CI check for the four files in every repo (#13)
- Org secret TACPLUS_REGISTRY_TOKEN for release CI (#12) (needs Jody's decision)
- The nightly recap: deterministic performance data (queue, prepare and run times, slot use, holds, lands, runner pools) in the suggestion pass; recurring bottlenecks become actionable Performance, Operability or Cost suggestions, transient ones a one-line note; a recap file for Jody's daily report (#57). Agent, at Jody's request, 2026-11-02.

## Later
- A protected release line with review, instead of pushing to main (README)
- Doppelganger decides resource requests (more loopers, new repositories) instead of fixed rules (README)
- A project looper that works from roadmap epics and files issues to repo loopers (tacplus-dev/roadmap:items/looper-hierarchy.md)

## Not doing
- Cloning or building on the Mac: all looper work runs as GitLab pipeline jobs (Jody, 2026-10-26, README)
- Porting anything else from SeaBeam: since 2026-10-27 only stratum still comes over; every other unmapped source is retired, never ported or reported (#5, #6)
