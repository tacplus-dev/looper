# History: looper

Append-only: add entries at the end, never edit or remove one (CI enforces it). One line each:
`- <YYYY-MM-DD> <who: looper|agent|jody> <kind: issue|decision|release|deploy> <one line> (<links>)`

- 2026-10-27 looper issue Loopers keep STATE/HISTORY/PROPOSALS; never ROADMAP; CI check for the four files in every repo (#13, 3f47c48)
- 2026-10-27 looper issue Issue flow: bug → fix + patch releases; feature → design, approval, ROADMAP first (labels, prompt, scan) (#14, cfb335e)
- 2026-10-27 looper issue Plan doesn't re-plan a repo that already has a job queued or waiting (stale duplicates hold the slot) (#16, 45f3fec)
- 2026-10-28 looper issue A run killed by a runner failure leaves looper:in-progress, so its automatic retry finds nothing to do (#20, 70c9b4c)
- 2026-10-28 looper issue A job GitLab marks runner_system_failure can keep running on its VM, so a retry runs the same issue twice (#21, ae593ec)
- 2026-10-29 looper issue A run that pushes nothing but finds the issue blocked is marked looper:stuck instead of Blocked-by (#22, 84d6db4)
- 2026-10-29 looper issue Port scan: skip SeaBeam commits that are ports of tacplus-dev work, so the realign doesn't bounce back (#23, 59ca032)
- 2026-10-29 looper issue Run the kicker on GitLab: a scheduled pipeline replaces looper-dispatch under launchd on the Mac (#24, 56a2391)
- 2026-10-29 looper issue Dockerfile: the build image is pinned to tacplus 2.4, but 2.5 is the newest released line (#26, c57fa92)
- 2026-10-30 looper issue Priority labels: priority:high / priority:low order the ready queue (oldest first within a priority) (#31, 6a09aba)
- 2026-10-30 looper issue Parent looper per repository runs child loopers in parallel; the parent decides what can run concurrently and how many (#32, 62ede1e)
- 2026-10-30 looper issue Parent never starts a second child: every child's 4h limit 'would outlast this job' (the job is sized for the lead issue) (#33, ffa38ec)
- 2026-10-30 looper issue Parallel children lose finished fixes: the land runs inside the child's time limit, and a land-pending child is marked stuck (#34, 88256c5)
- 2026-10-30 looper issue Agents' GITLAB_TOKEN is a group-Owner api token: it reads fleet-seatrials' protected variables and can start its protected deploy jobs (#25, 6d4c73b)
