# Roadmap: looper

Owned by Jody; changed only by an agent at Jody's request. Loopers propose in PROPOSALS.md.

## Now
The tacplus-dev loopers run as GitLab pipelines (gitlab.com/tacplus-dev/looper), with nothing on the Mac: a scheduled kicker (schedule 4520605) plans a **report job per ready issue**, up to each repository's cap (caps.yaml), and a **manager per repository** that alone merges to main (#70). Builds and gates run as build jobs where a repository is pinned (#71). Then there are the nightly scans, the roadmap suggestions and the recap. Jobs run on the interim runner VMs until the in-cluster runner takes over (#84). The image is `ghcr.io/tacplus-dev/looper:main`, built from the pinned tacplus build image. Unreleased (no tags).

Done (moved from Next on 2026-11-05):
- Per-repository runner tags: tacplus jobs on the 16-CPU pool (runner 58307468), others unchanged (#55). Agent, at Jody's request, 2026-11-02.
- Standing rule: trace propagation implemented and tested in every service's handlers, verified by loopers and the nightly scan (#51) (Jody, 2026-11-01)
- Nightly suggestions: the roadmap scan writes evidenced platform suggestions for Jody's daily review; rejected kept with reasoning (#50) (Jody, 2026-11-01)
- Deterministic security checks in the build pipeline: SCA and SAST on source and generated code, SBOM per release, fail on HIGH/CRITICAL with expiring exceptions (#49) (Jody, 2026-11-01)
- Parent looper runs child loopers in parallel; the parent decides concurrency (#32) **Retired:** #70 replaced the parent and children with a job per issue and a manager per repository.
- Priority labels order the ready queue (#31)
- The kicker runs as a scheduled GitLab pipeline; nothing on the Mac (#24)
- Prompt provenance: issue and PR text in per-run nonce blocks; only members' text directs a run (#40) (Jody, 2026-10-31)
- Loopers keep STATE/HISTORY/PROPOSALS, never ROADMAP; CI check for the four files in every repo (#13)
- Org secret TACPLUS_REGISTRY_TOKEN for release CI (#12) (needs Jody's decision)
- The nightly recap: deterministic performance data (queue, prepare and run times, slot use, holds, lands, runner pools) in the suggestion pass; recurring bottlenecks become actionable Performance, Operability or Cost suggestions, transient ones a one-line note; a recap file for Jody's daily report (#57). Agent, at Jody's request, 2026-11-02.
- Retire looper-port, the SeaBeam port scan: SeaBeam is retired on cutover, not ported (#60). Agent, at Jody's request, 2026-11-03.
- Each child's model as its own unprivileged user: no signalling or /proc reads across runs, docker only through the looper-docker broker (#68). Agent, at Jody's request, 2026-11-03 (suggestion accepted).
- One job per issue (direct reports) and a manager per repo that alone merges to main (#70); agents never build, build requests run as build jobs (#71); the recap reports managers, caps and capacity (#72). Agent, at Jody's request, 2026-11-03 (`tacplus-dev/roadmap:decisions/looper-job-per-issue-2026-11-03.md`).
- Enforce 'only the manager writes main': a ruleset on main in the public repositories, a manager App as the only writer, reports on a token that cannot bypass it, Jody's PAT out of every job (#83). Agent, at Jody's request, 2026-11-04 (`tacplus-dev/roadmap:suggestions/2026-11-04-only-the-manager-can-write-main.md`).
- Recap: read tacplus-dev/build's jobs; drop the Cloud Build source (#85). Agent, at Jody's request, 2026-11-04 (`tacplus-dev/roadmap:suggestions/2026-11-04-let-the-recap-see-the-build-pipeline.md`).

## Next
- Gates scaled to the diff: a per-repo gate map picks what a land runs; unmapped paths, gate-map changes, nightly and releases run everything (#48) (Jody, 2026-11-01)
- GitLab forge backend; a SeaBeam instance (kicker, runner, credentials) in the seabeam group (#29)
- Looper identity, pilot on kernel: one identity per repository, think/commit split, app JWT signed in KMS (#28)
- Retire GitHub Actions in every repo; a gate refuses any workflow file (#18, after #17)
- Build pipeline: (repo, commit) → pinned build image, no agent, read-only source → pass/fail + image (#17)
- Build pipeline: a manual macOS smoke job on the Mac runner (tag `macos`, Tart VM), the first piece of tacplus#195's macOS builds (#36) (Jody, 2026-10-30)
- Looper image separate from the build image; branch → start a build → land on main only on a passing build (#15, after #17)
- runner-image build in projects with no default network (RUNNER_IMAGE_SUBNET, --no-address), a pinned Docker, the published image's name printed for pinning (#67; for tacplus-dev/cloud#4). Agent, hub's call under Jody's deterministic-deployments rule, 2026-11-03.
- Formal verification in the build pipeline: nightly when changed and on every release tag, a bug on failure, and child sizing by gate set (#74). Hub, splitting tacplus-dev/tacplus#275 (approved), 2026-11-04.
- Looper jobs on the in-cluster runner: normal-pool tags, builds on spot with retry:, requests per job type, no Docker in any pod (#84). Agent, at Jody's request, 2026-11-04 (`tacplus-dev/roadmap:decisions/only-vms-are-k8s-nodes-2026-11-04.md`).
- The manager lands in batches (merge train): one build per batch on a staging candidate, main fast-forwarded on green, bisect and send back on red (#86). Agent, at Jody's request, 2026-11-04 (`tacplus-dev/roadmap:decisions/merge-train-2026-11-04.md`).
- Security: split the manager, so the job that runs a batch's gates never holds the tacplus-manager token (#90). Agent, at Jody's request, 2026-11-05 (suggestion accepted).
- Per-repository job tags for reports only: tacplus's manager and scan off its reports' pool (#91). Agent, at Jody's request, 2026-11-05 (suggestion accepted).
- The recap's cap advice counts running reports only (#92). Agent, at Jody's request, 2026-11-05 (suggestion accepted).
- Retire looper-docker, its broker and the host socket's path once every repository is pinned (#73). Agent, at Jody's request, 2026-11-06.
- No per-repository caps: a report for every ready issue, loopers never blocked (#107). Agent, at Jody's request, 2026-11-07 (`tacplus-dev/roadmap:decisions/only-vms-are-k8s-nodes-2026-11-04.md`).

## Later
- A protected release line with review, instead of pushing to main (README)
- Doppelganger decides resource requests (more loopers, new repositories) instead of fixed rules (README)
- A project looper that works from roadmap epics and files issues to repo loopers (tacplus-dev/roadmap:items/looper-hierarchy.md)

## Not doing
- Cloning or building on the Mac: all looper work runs as GitLab pipeline jobs (Jody, 2026-10-26, README)
- Porting anything else from SeaBeam: since 2026-10-27 only stratum still comes over; every other unmapped source is retired, never ported or reported (#5, #6)
