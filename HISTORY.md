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
