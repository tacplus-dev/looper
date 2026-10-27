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

## Promoted / declined
