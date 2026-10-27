# History: looper

Append-only: add entries at the end, never edit or remove one (CI enforces it). One line each:
`- <YYYY-MM-DD> <who: looper|agent|jody> <kind: issue|decision|release|deploy> <one line> (<links>)`

- 2026-10-27 looper issue Loopers keep STATE/HISTORY/PROPOSALS; never ROADMAP; CI check for the four files in every repo (#13, 3f47c48)
- 2026-10-27 looper issue Issue flow: bug → fix + patch releases; feature → design, approval, ROADMAP first (labels, prompt, scan) (#14, cfb335e)
