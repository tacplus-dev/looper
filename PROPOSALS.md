# Proposals: looper

Written by loopers. Each proposal: what, why, links. Jody promotes accepted ones into ROADMAP.md (via an agent);
the looper then marks it `promoted` or `declined` here with the date.

## Open
- **A build's wait as long as tacplus's full gates** (2026-11-13, #140): the gates job now has its own 11h
  timeout, but `repo-looper --build` and a manager's merge wait for a verdict `LOOPER_BUILD_WAIT` (default 3h),
  and tacplus's full gates take about 3h15m before the security checks: such a build ends "no verdict within 3h"
  while the pipeline still runs. Sizing the wait per repository (as `land_wait` sizes a land's, from gates.yaml's
  `minutes` of the set) would keep it from giving up on a build that is still on time.
- **SpotBugs without the generated tree's bytecode** (2026-11-13, #149): SpotBugs reads every `target/classes`,
  kernel's `tacplus/target/classes` too, the compiled code tacplus generates, whose findings are tacplus's to scan
  (#108); leaving it out would cut the heap kernel's analysis needs. The classes a module compiles from an
  `output-dir` are not named by tacplus.yaml (Maven's module layout says which), so it needs a rule for telling them
  apart, e.g. a `target/classes` whose module's sources all lie under an `output-dir`.
- **The kicker resource group's `newest_first`** (2026-11-07, #104): a kick now stops once a newer one is queued, but
  GitLab's default `unordered` process mode may still hand the `kicker` group to a stale kick first, which takes a VM
  to start and stop. `PUT /projects/:id/resource_groups/kicker` with `process_mode=newest_first` (a token with `api`
  scope, the hub's one-time step) gives it to the newest at once; it is a setting of the project, not of the CI file.
- **The secret scan on every gate set** (2026-11-10, #117): `tests/looper-secrets.test.sh` runs with full and its own
  set, so a token-shaped literal added in a file only a smaller set maps (`tests/looper-recap.test.sh`, the recap set)
  is caught by the build's `security-looper` job, not the gates. A set that every land runs beside the ones its paths
  call for (gates.yaml has none) would close it, as would gitleaks in a pre-commit check the agents run.
- **A build that never starts, told** (2026-11-11, #128): a build with no verdict by the manager's job end now
  leaves its land queued for the next manager, however long it stays queued, so a pipeline that never starts (#113:
  no runner, no commit status) holds its repository's queue, oldest first, across managers with no red verdict and
  nothing on the issue. A comment on the issue once a build has been queued past a bound (`LOOPER_BUILD_QUEUE_WAIT`,
  say, a day), or the recap's `builds_not_started` as an item over a threshold, would surface it; reading the
  pipeline's own status from tacplus-dev/build (a token the manager lacks today) would tell queued from lost.
- **A stale build branch cleared** (2026-11-11, #128): a land left queued keeps `looper/build-<repo>-<n>` with its
  build's record; if the land is then sent back or its main moves, no manager reuses it, and the branch stays until
  the issue's next land builds (the manager force-pushes it afresh and deletes it after the verdict). A manager could
  delete a build branch whose issue has no land queued.
- **The CI files' looper digest bumped by a tool** (2026-11-10, #115): `ci/`'s files name the looper image by digest,
  bumped by hand (a reviewed commit, then the hub's copy into each GitLab project), so a change to `looper-dispatch` or
  the kicker takes effect only after both. A `looper-dispatch pin` that writes main's newest attested digest into them
  (verified as the plan verifies it), run by the hub before its copy, would keep them current without trusting a tag.
  The first bump is due once `image.yml` attests (#115's second land): the pinned build (eea43fc's) predates #115, so
  its plan still gives its jobs `:main`; a bump before an attested build exists would fail every plan.
- **The image's release tags guarded as main is** (2026-11-10, #115): `image.yml` builds a `vX.Y.Z` tag only at a
  commit of main, but a report's token (contents: write) may push a tag, and main's ruleset names no tag; a tag
  ruleset (only the manager creates `v*`) would close it, and `gh attestation verify` of a release could then require
  `--source-ref refs/tags/v…` as the plan requires main.
- **An abandoned build's security checks skipped too** (2026-11-11, #130): a gates job past its requester's wait
  writes `abandoned` and runs no gates, but the child pipeline's `security-<repo>` job (`needs: gates`, `when:
  always`) still runs the scanners on the commit nobody waits for; `looper-scan run` could read the gates' artifact
  `build-verdict` and end at once on `fail: abandoned:`, saving the runner the scan as well.
- **The child pipeline's verdict as the commit status' description** (2026-11-11, #130; gates done 2026-11-13, #148):
  the child's `gates-failed` job now sets a failed gates job's reason; a failure of the child's security job (the
  gates green) is still "the build failed" from `report-fail`, which cannot read the child's artifacts.
- **A gates job dropped as stale** (2026-11-13, #148): the build's jobs are retried on `runner_system_failure`, but
  not on `stuck_or_timeout_failure`, which GitLab also gives a running job whose runner manager went away without a
  word (no update for an hour): retrying on it would retry the gates' own 11h timeout twice too (33h of a manager's
  wait). If the recap shows lost VMs ending that way, the gates could take a timeout below the job's own (`timeout`
  in looper-build gates), so a job timeout means only a lost runner, and the retry could then include it.
- **clippy on a service whose generated crates the scan does not have** (2026-11-11, #126): cargo-deny now falls back
  to the gates' `generated/` at the tacplus.yaml `output-dir`, then to the `Cargo.lock`'s crates alone; clippy, which
  compiles, still fails the run (`no matching package named grpcserver`, gateway at cfe4600 by `looper-scan local`)
  when the gates kept no `built/` (red gates) or generate out of tree. The same `generated/` overlay would cover the
  second; the first is red anyway (gateway's passing gates keep `target/generated-sources/model/**` in `built/`, so
  its `20261111T093923Z` scan's `cargo-deny: exited 1` most likely followed red gates: the security job runs
  `when: always`; the build project's logs, which a report cannot read, would say).
- **A ready issue's wait from when it became ready** (2026-11-08, #107): the recap's `concurrency` counts a ready
  issue's wait with no report job from the kicker's passes, which see an issue only while one runs (a gap between
  kicker jobs or a looper-plan under way logs no line), and a report's own queue for a VM from its job; the time from
  `approved` (or its last blocker closed) to its report's start, from GitHub's timeline, would be the whole wait in
  one number.
- **Every gate hermetic** (2026-11-07, #103): forge, repo-looper, looper-dispatch and tacplus now run under
  `env -i` (`tests/hermetic.sh`); the other fourteen gates pass in a looper job today but still read its
  environment (its apps, job tags, gh's configuration, git's credential helper), so a new scenario in one of them
  can fail only in a job, or send the job's token to a stub. Sourcing the helper in every test file (and a
  planning-files check that each does) would close it; the tests that drive a real docker (looper-docker,
  runner-image, looper-build) need checking for what they read from the job first (`DOCKER_HOST`, the broker).
- **A closed issue's HISTORY.md line beside its queued land** (2026-11-05, #93): a run that closes its issue while
  its land is still queued (no verdict yet) has its report queue the issue's HISTORY.md line with `queue_history`,
  which force-pushes the branch afresh at main: the queued land's commits leave the branch, and the manager merges
  only the line. The prompt has the model close after the verdict, so no run is known to have hit it; the report
  could add `.looper/history` to the branch's last checkpoint instead when a land of its is pending (`post_land`
  already appends a land's history lines after merging it).
- **A stale `looper:landing` told on its issue** (2026-11-05, #93): a manager that clears a `looper:landing` with no
  land queued logs it in its job; a comment on the issue would tell whoever reads it why it lost the hold (a land
  unqueued, a verdict given by a manager that stopped before clearing it).
- **Each pool's own VM in the recap's scale-up** (2026-11-05, #92; its `capacity/<pool>` item went with the caps in
  #107, 2026-11-08): `capacity/vm` names each waiting report's pool, but prices one more VM as
  `LOOPER_RECAP_VM_MACHINE` (t2a-standard-8) whatever the pool: the 16-CPU pool's VM is another machine and price. A
  machine and price per runner description (a map in the recap's environment, say) would make each pool's advice cost
  what its scale-up costs.
- **A plan's resource groups from the plan's own job** (2026-11-05, #92): the recap reads each job's resource group
  from the plan's `planned ... resource_group` lines when the plan's job falls in the night; a scan planned before
  the window falls back to the plan's rule (`looper-<repo>`). Should a scan ever share a report's group again, the
  recap would miss it for a scan planned the night before; the plan could log the groups in the scan's own job too.
- **The verdict a test can write** (2026-11-05, #90): the manager split in two keeps the manager's token out of the
  job that runs a report's code, but the verdict job's gates run as that job's user. That user writes the verdict
  (each land's exit) and pushes `looper/staging`, so a test the batch lands can forge a green the manager job then
  merges. It can no longer hold the bypass, nor reach main past the manager job's checks (staging the commit the
  verdict named, on the main it was built on). The gates as a user of their own in the verdict job (below) would put
  the verdict and the staging push out of its reach; a build job per batch (#86) ends it.
- **A release's HISTORY.md line queued by its report** (2026-11-05, #90): the split manager job adds a release's
  line for each tag that came after its verdict job started. A tag pushed between batches gets none, as one pushed
  between the one manager's jobs got none. The report that tags a release could queue its line beside its closed
  issue's (`.looper/history`), which reaches the manager whenever it runs.
- **Regeneration in the build** (2026-11-05, #90): the one manager a pinned repository keeps holds the manager's
  token, so it regenerates nothing. A rebase that conflicts only in files `generated.yaml` maps is sent back to its
  report, where the split's verdict job, and the one manager before #90, resolved it. The build job could regenerate
  them and build the result (the merge train's batch, #86), or the pinned repositories could keep the split until it
  does.
- **The tacplus wrapper refuses a directory the host cannot see** (2026-11-05, #79): its compiler is a sibling
  container mounting the checkout at its own path, so a checkout outside the runner's `/builds` bind mount (the
  manager's scratch worktrees in the job's `/tmp`, until #79) showed it an empty directory, and every land of a
  tacplus project failed with `tacplus.yaml must declare a language`, far from the cause. The wrapper could check
  that the container sees the checkout (its `tacplus.yaml`, say, with a cheap `test -e` in the same image) and
  otherwise fail with "<root> is not on the docker host: run it under LOOPER_WORK".
- **A hold that did not take is reported** (2026-11-04, #80): every label edit of the looper is `|| true`, so
  `looper:landing` was missing from every repository from #70 until #80 and no land's hold was set, without one line
  in a log anyone read (the manager's stderr had it, among its merge's lines). Labels are now created before a run
  sets one and a failed edit retried once they are; an edit that still fails could be logged as such (`#N: could not
  label it looper:landing: <why>`), and the kicker could flag a branch whose `.looper/land` is queued while its
  issue lacks `looper:landing`.
- **A verdict only the manager can give** (2026-11-03, #70): a report's `--land` takes the newest comment on its
  issue carrying its land's id (`<!-- looper-land id=... -->`) as the manager's verdict, and the id is on its branch
  (`.looper/land`) for anyone to read. Every model holds the same `GH_TOKEN` as the manager, so another issue's model
  could post a verdict for it. The merge itself is the manager's alone (nothing reaches main without its gates), so
  the worst is a model told "merged" or "sent back" falsely. A manager identity of its own (a GitHub App, as the
  looper identity pilot has), checked by author, or a ref only that identity may push, would close it. Since #83
  the manager comments as `tacplus-manager[bot]` once the project has the apps: `--land` can take only that
  author's verdict (the comment's `user.login` and `performed_via_github_app`), the rest left as before.
- **Lock files every repository has, without a generated.yaml** (2026-11-03, #70): the manager regenerates only
  what a repository's `generated.yaml` maps; none has one yet, so every lock-file conflict is sent back today. A
  `generated.yaml` in tacplus (its generated code: `just generate`), kernel and the Go services (`go.sum`: `go mod
  tidy`) and the Rust ones (`Cargo.lock`), or defaults for the well-known lock files, would let the manager resolve
  them. Regenerating runs the repository's tools in the manager's job: with #71, in a build job instead.
- **The manager's gates as a build job** (2026-11-03, #70, #71): done for a pinned repository whose jobs hold
  `BUILD_TRIGGER_TOKEN` (README: Build jobs); the others still run them in the manager's job until their pin issues
  (the hub's) land and the hub sets the token in tacplus-dev/looper. Regenerating a conflict's generated files
  (`generated.yaml`'s commands) still runs in the manager's job: in a pinned repository it could be a build job too,
  one that hands back the files it wrote.
- **Retire looper-docker, its broker and the host socket's path** (2026-11-03, #71; the hub's decision on #71): once
  every repository is pinned no report needs a container runtime, so `looper-docker`, `looper-docker-broker`, the
  `looper-docker` user and the model-user code that guards the socket's gid (#68, #69) can go, and tacplus-dev/cloud
  can drop the socket's mount from the jobs' containers. With it, the test that an image builds in the build job
  without host Docker (rootless BuildKit in the build image: tacplus-dev/tacplus#315, which it is Blocked-by). The
  follow-up issue is #71's (linked from it).
- **A forged build verdict** (2026-11-03, #71): the looper takes a build's verdict only from the commit status the
  `tacplus-reader` app set, by its creator's login (`tacplus-reader[bot]`), linking the pipeline it started. A
  status's creator is GitHub's to record, so the looper's `GH_TOKEN` cannot pass for it; reading the pipeline's own
  status from GitLab would need a read token for tacplus-dev/build that the looper's jobs do not have.
- **The nightly scan's PROPOSALS.md push** (2026-11-03, #70; **done** 2026-11-04, #83: the model leaves the file
  in the checkout and the looper commits its change, as the manager's identity): the scan still commits PROPOSALS.md
  on main itself (`git pull --rebase` and push), the one push to main that is not the manager's.
- **The kernel pilot's merges under main's ruleset** (2026-11-04, #83): `looper-ruleset` restricts updates of main on
  every public repository, kernel's too, so a pull request GitHub squash-merges for `kernel-looper[bot]` (looper#28's
  auto-merge) is refused unless that app is a bypass actor on kernel. Before the pilot goes live, either
  `looper-ruleset` takes a repository's own extra bypass actor (kernel-looper on kernel), or kernel's ruleset swaps
  "restrict updates" for "require a pull request" plus its required check.
- **The id_token for a job's life** (2026-11-04, #83): an app's token lasts an hour, a job up to eleven, so
  `looper-token` keeps the job's GitLab id_token, root's alone, to exchange it again at each refresh; kernel's
  commit job, which mints once, drops its own at once (SYNTHESIS 21). GitLab's id_token lives for the job's timeout,
  so a refresh after it fails (the job ends first). A shorter-lived chain (a GCP service account's own credentials,
  impersonated once) would not need it kept.
- **gcloud's own parsing in the tests** (2026-11-05, #95): the first App cutover failed on `gcloud kms
  asymmetric-sign --key=<whole path> --version=1`, which gcloud refuses before any call (`argument --location: Must be
  specified`), and both stubs (looper-token's, looper-identity's) had accepted it. They now parse `--version` as gcloud
  does, but only for that flag. A gate that runs the image's real gcloud on each command looper-token and
  looper-identity give it, with a credential that cannot authenticate, and requires the failure to be the call's (an
  auth or permission error), not gcloud's usage, would catch the next such slip.
- **The kernel pilot's setup still names jody1-328023's `us` key ring** (2026-11-05, #95): README, Setting it up (the
  hub, looper#28) creates `kernel-looper` and `tacplus-reader` in jody1-328023, `us`; tacplus-dev/cloud#19 moved the
  reader to tacplus-ci's `us-central1` key ring (its signers' move is cloud's follow-up). That section, and kernel's
  `LOOPER_KMS_KEYRING`, follow once cloud's move is applied.
- **Require the build's status on main** (2026-11-04, #83): main's ruleset restricts who updates it; a required
  status check (`tacplus-dev/build` from `tacplus-reader`, as kernel's protection has) would also refuse a manager's
  push whose build did not pass, once every repository builds in tacplus-dev/build (only looper is pinned today).
- **Other jobs' suggestions under main's ruleset** (2026-11-04, #83): `looper-suggest file` without `--dir` (another
  job's suggestion, tacplus-dev/chaos#1's watch, say) pushes to the roadmap's main itself, which main's ruleset refuses
  to any token but the manager's or Jody's. It could push a branch `suggestion/<slug>` instead, which the roadmap scan
  (the manager's identity) checks and commits, as it does its own model's.
- **Private repositories' reports** (2026-11-04, #83): fleet-dev and fleet-seatrials get no report while their main
  has no ruleset (GitHub Team). Jody's call: Team for the org, the reports back with `LOOPER_PRIVATE_REPORTS=1`, or
  the repositories public.
- **The manager's polling** (2026-11-03, #70): every `LOOPER_MANAGER_POLL` (30s) the manager lists its branches
  (one `ls-remote`), reads two labels (two GitHub requests) and, for a branch queued it has not judged, its issue's
  comments; a waiting `--land` reads its issue's comments every `LOOPER_LAND_POLL` (30s). With 15 reports at once
  that is about 2000 requests an hour on the shared `GH_TOKEN`. A longer poll while nothing is queued, or a
  `repository_dispatch`-style wake-up, would cut it.
- **Every report at once on the runner VMs** (2026-11-03, #70; since #107, 2026-11-08, no repository has a cap):
  every ready issue's report is planned at once, and until #84 moves the gates to build jobs each report still runs
  its gates inline in a 4-CPU/14 GB slot of a runner VM, so a burst of ready issues queues reports for VMs (the
  recap's `capacity/vm` and its `concurrency` say how many and how long) rather than for a cap. Nothing to change
  while those numbers stay small (Jody: "If we have a problem we will look to address it"); the runner's `limit` or
  pod requests (decisions/only-vms-are-k8s-nodes-2026-11-04.md) are where a bound would go, never a per-repository
  cap.
- **Scan the looper image's own binaries** (2026-11-03, #62–#65, #47): the build's checks scan the tree and Trivy the
  Dockerfiles' base images, never the tools our Dockerfile downloads (glab, OSV-Scanner, Trivy, Syft, gitleaks,
  gosec, cargo-deny). The nightly scan found reachable vulnerabilities in four of them by running
  `govulncheck -mode=binary` by hand. A step in the image workflow (or `looper-scan` on a release's image, beside its
  SBOM) running `govulncheck -mode=binary` on each Go binary under `/usr/local/bin` that the base image does not
  have, or `trivy image` on the built image, would put them under the same policy as the tree. Trivy built from
  source reports GO-2026-4919 (the compromised v0.69.4 release, an open range: not applicable, #64): such a step
  needs an exception for it. A binary stripped of its symbol table (`-s`, as most releases are) is read less
  precisely: Trivy's source build stripped so reports x/net GO-2026-6860/6866 and openpgp GO-2026-5932 again,
  unstripped none of them (#64); such a step should say which binaries it could read only so.
- **Drop gitleaks' xz replace** (2026-11-03, #65): the image builds gitleaks 8.30.1 from source with
  `github.com/ulikunitz/xz` replaced with v0.5.15 (`GITLEAKS_XZ_VERSION`, Dockerfile; 8.30.1 pins v0.5.12, GO-2025-3922),
  a combination upstream did not test, smoke-tested only by a planted AWS key. When gitleaks releases with xz >= 0.5.15
  (or drops it), move `GITLEAKS_VERSION`, remove the replace and its README note; a release whose own binary
  `govulncheck -mode=binary` reads clean could go back to its release sha256.
- **`child-timeout` is load-sensitive** (2026-11-03, #64; **superseded** 2026-11-03 by #70: no children, and the scenario is gone): `tests/repo-looper.test.sh`'s scenario failed once
  (`expected "#5: closed" in: stub gh: HTTP 404`) while a Go build ran on the same machine, and passed alone right
  after. Its children's time limits are wall-clock; a margin scaled to the load, or limits the stub clock drives,
  would keep a land's gates from failing on it.
- **A cheaper re-plan check** (2026-11-03, #59; **superseded** 2026-11-03 by #70: no parent re-plans; the planner reads the org once a pipeline): every `LOOPER_REPLAN_INTERVAL` the parent reads the ready set
  again (`candidates`: the approved list and each issue's `ready`, a few GitHub requests an issue), and asks the
  plan's model again whenever the set changed, even when only a running issue's areas were judged before. It could
  read the set the kicker already reads for the whole org each pass, and keep each issue's areas from its last plan,
  asking the model only about issues it has not judged.
- **A newly ready issue in a job with no free slot** (2026-11-03, #59; **superseded** 2026-11-03 by #70: an issue gets its own job when its repository is under its cap): a re-plan fills free slots only; an issue
  that becomes ready while every slot is taken waits for a child's end, and one ready after the job's last child
  ended waits for the kicker's next job. Both are as intended (no pre-emption); the recap (#57) measures them.
- **The image workflow runs the full gate set from gates.yaml** (2026-11-03, #58): `.github/workflows/image.yml`'s
  Test step lists the tests by hand and has drifted from gates.yaml's `full` (no `looper-suggest`, `looper-trace`
  nor `image-failed` tests). Reading `full.run` from gates.yaml there would keep the image's tests the land's.
- **The recap's job logs without fetching them all** (2026-11-03, #57): `looper-recap collect` reads every finished
  job's log of the night (`/jobs/:id/trace`) for its prepare time, VM, plans, holds and lands: a few hundred requests
  a night today. The plan records (`looper-runs/*-plan/plan.md`, job artifacts) and a per-job summary line the
  parent logs at its end would let it read the looper jobs' logs only, and the others' first lines.
- **Waits the recap cannot see yet** (2026-11-03, #57): an issue ready while no looper job of its repository runs
  (waiting for the kicker's next pass or GitLab's queue) shows only as its job's queue time, and the image's
  staleness (#58) as hours behind main, not per issue. The kicker could log when it first saw each issue ready, so
  the recap counts every hour from ready to started.
- **The recap without the retired parent's lines** (2026-11-03, #72): `looper-recap` still parses the parent's plan,
  hold and lander lines (slot use, held reasons, `queued since`), which #70 retired; they matter only for logs from
  before it. Once the 7 nights' history holds none, drop them and the report's slot-use line, so the summary shows
  only the managers, caps and capacity.
- **One more VM's cost from the billing** (2026-11-03, #72): the recap's cost of a VM a day is
  `LOOPER_RECAP_VM_USD_HOUR` (the t2a-standard-8 on-demand list price, 0.308) times 24, not what jody1-328023 pays.
  The Cloud Billing catalog API (`gcloud billing` SKUs) or the billing export would give the real price, disk included.
- **The recap's thresholds from the history** (2026-11-03, #57): the thresholds are fixed (environment
  `LOOPER_RECAP_*`); once a few weeks of `suggestions/recap/*.json` exist, a p90 against the 7 nights' own p90
  would flag a regression the fixed numbers miss.
- **A suggestion's sameness beyond its name** (2026-11-01, #50): `looper-suggest` refuses a rejected or deferred
  suggestion raised again by its slug or its name; one reworded under another name passes the check, and only the
  prompt (read every rejected one first) guards it. The doppelganger panel's pre-screen (doppelganger#10), or a
  model-judged similarity check against the rejected list before the commit, could catch rewordings.
- **The suggestion pass reads more of the pipelines** (2026-11-01, #50): the looper hands the model the week's
  failed jobs (name, stage, reason, link), not their logs, and the model holds no GitLab credential (#25). The
  tails of the failed jobs' logs (`/jobs/:id/trace`), read by the looper into `context/`, would let it tell a
  disk-full from a timeout without guessing from the job name.
- **Ready the repositories before the security checks start** (2026-11-01, #49): run by hand on 2026-11-01
  (`looper-scan local`), tacplus fails the policy on 136 findings (gosec: 55 G122, 49 G703, 11 G115, ...; six OSV
  advisories with fixes) and kernel on 8 gitleaks findings (PEM markers in its Java sources and tests). The checks start
  with the next looper image, so the first build of each fails. Before the hub copies `ci/build.gitlab-ci.yml`, a
  nightly agent scan per repository (or a looper issue each) could fix the real ones and propose each other as a
  `security-exceptions.yaml` entry (or a `.gitleaksignore` line) for Jody to decide.
- **tacplus's `generated` recipe** (2026-11-01, #49): tacplus's cross-test models (what consumers ship) are generated
  out of the tree during its gates, so the security checks see them only once tacplus's justfile has
  `generated <dir>` writing them there (README, Security checks). A tacplus issue, as part of #49's roadmap entry.
  Since #108 (2026-11-13) services no longer count their generated tree's SAST findings, so until the recipe exists
  generated code is SAST-scanned nowhere: https://github.com/tacplus-dev/tacplus/issues/376 (feature, for approval).
- **Pin Semgrep's rules** (2026-11-01, #49): `p/default` is fetched from the registry each run, so the same commit
  can get other SAST findings another day; the run records the fetch time only. A pinned semgrep-rules commit,
  fetched at run time (the license forbids redistributing the rules, not fetching them), would make Semgrep as
  reproducible as the tools.
- **Drop Semgrep's dependency override** (2026-11-02, #53): `scanners/requirements.txt` runs Semgrep 1.183.0 on
  mcp 1.30.0 and OpenTelemetry 1.45.2/0.66b2, not the mcp==1.29.0 and ~=1.37.0 it declares (their advisories); the
  image build's smoke scan is all that shows it works. When a Semgrep release requires the fixed versions, move to it
  and make the file again without the override. Raising it upstream with Semgrep (option 3 of #53) would hasten that.
- **The baseline per branch** (2026-11-01, #49): "the previous run" is the repository's latest published findings,
  whatever commit or branch built them (a land's branch build updates it too). A version per branch
  (`security-<repo>/<branch>`) would compare main with main.
- **Prune the findings packages** (2026-11-01, #49): each run uploads `security-<repo>/latest` again; the package
  registry keeps every duplicate file. tacplus-dev/build's duplicate-package settings, or a cleanup policy, should
  keep the last few.
- **Base images the scan cannot read** (2026-11-01, #49): Trivy scans the Dockerfiles' base images by name, and a
  private one (Artifact Registry's tacplus build images) is listed as not analyzed: the security job has no registry
  identity. A read-only WIF binding for it would cover them.
- **Cache CodeQL's bundle** (2026-11-01, #49): 680 MB fetched by every nightly and release of every repository (fresh
  VMs); a scanner image with it, or a cache bucket, would save the transfer.
- **Check who approved, on GitLab** (2026-11-01, #29): on GitHub only write access sets a label, so `approved` is
  the gate. On GitLab a Reporter or a Planner may set one too, so an instance's gate is only as strong as its group's
  roles (README, Forges). The looper could read the issue's label events
  (`GET /projects/:id/issues/:iid/resource_label_events`) and take an issue only when a DEVELOPER or above added
  `approved`, as it reads roles for prompt provenance.
- **SeaBeam's tacplus and GitHub** (2026-11-01, #29): SeaBeam's instance holds no GitHub credential (no coupling),
  but the `tacplus` wrapper reads tacplus' releases from GitHub, and a tacplus 2.4+ repository's `depends` clone the
  private tacplus-dev/registry with `GH_TOKEN` (#11, #27). A SeaBeam repository that builds with tacplus needs either a
  read-only token of tacplus-dev's (a coupling Jody decides) or the releases and registry mirrored to SeaBeam's GitLab.
  Until then, SeaBeam repositories that run tacplus are not ready for the instance.
- **One pipeline file for both instances** (2026-11-01, #29; 2026-11-03, #56): both pipelines now plan with
  `looper-dispatch plan`, but from two files: `ci/tacplus-dev.gitlab-ci.yml` (its nightly
  scan planned as a job per repository) and `ci/instance.gitlab-ci.yml` (its nightly scan one job over
  `LOOPER_SCAN_REPOS`). The instance's scan could be the plan's too (a `LOOPER_SCAN_REPOS` filter on `forge_repos`),
  and the two files one. Neither file is linted by a test yet ("Check
  the CI files' rules in a test" below).
- **Fewer GitLab requests for the blockers' states** (2026-11-01, #29): on GitLab `forge_issue_states` asks once per
  distinct blocker (REST), where GitHub's is one GraphQL query. gitlab.com allows 2000 authenticated requests a
  minute, far above a pass's, but one aliased GraphQL query (`project(fullPath:) { issue(iid:) { state } }`) would
  match GitHub's shape if the group grows.
- **Keep gitlab-runner-mgr's config here** (2026-10-31, #43): the runner entries (`[runners.autoscaler]`: #42's keys,
  #43's `instance_ready_command`) and the instance templates are README snippets that the hub applies by hand,
  and nothing checks that the manager matches them. A `runner/config.toml` (tokens as placeholders) and a hub
  check that diffs it against the manager and lists each group's template would keep the record honest. The README
  also says the runner entries connect as `username = "runner"`, but the workers' docker socket is group `fleeting`
  and the startup-script's comment says the manager connects as `fleeting` (seen on a worker, 2026-10-31). One of
  the two is stale, and only the manager's config.toml can say which.
- **Pin the bake's Docker** (2026-10-31, #43; **superseded** 2026-11-03: the pools boot a pinned
  Container-Optimized OS and nothing is baked, roadmap `decisions/builds-in-containers-2026-11-03.md`, looper#67
  closed): `runner-image build` installs the newest `docker-ce` from Docker's
  apt repository, so two bakes a month apart differ, and a bad Docker release reaches the workers by the monthly
  schedule (the boot check catches only a Docker that does not start). Pinning the version in `runner/startup.sh`
  (bumped by a looper issue) would make each rebake a change on main; deprecating the newest image is the rollback
  meanwhile.
- **Stop a job's containers when it ends** (2026-10-31, #42): a worker per job (`max_use_count = 1`) deletes a
  failed job's containers with its VM, but nothing in the job stops them itself: a VM the manager fails to delete,
  or any later return to reused workers, brings orphans back. `looper-docker` could label each container
  `looper.job=<CI_JOB_ID>`, and `repo-looper` remove its own on exit and, at a job's start, every one whose job
  GitLab no longer runs. That costs the job API reads, and the label holds only for the model's `docker`.
- **A child's memory as one cgroup** (2026-10-31, #41): `looper-docker` limits each container a child's model
  starts to the child's memory, so two at once can use twice its share, and `docker compose`, `docker build`'s
  containers, the real docker by its path and a process the model runs in the job's own container (`cargo kani`
  without docker) are not limited at all. A cgroup per child (the job's container with a writable cgroup v2
  subtree, or the runner's `docker` config giving the job container a memory limit and each child a
  `--cgroup-parent`) would bound the child's whole tree; `looper-docker` could then pass `--cgroup-parent` too.
- **The lander's processes out of the models' reach** (2026-11-03, #61): every model runs as root in the job's
  one PID namespace, beside the parent, the lander and the other children, so any model can signal any of them.
  `looper-pkill` (the model's `pkill`) spares what its run did not start, and rule 4 asks for a PID, never a
  pattern, but `kill $(pgrep -f 'just gates')`, `kill <pid>` of another run's process, or a process started with
  a cleared environment are not guarded. A boundary needs either a PID namespace per model (`unshare --pid`, which
  the job's container refuses without `CAP_SYS_ADMIN`; the runner's docker config could grant it), with
  `--land` finding the lander by a file rather than `kill -0 $LOOPER_LANDER_PID` (see tacplus#200's land, above),
  or each model as its own non-root user, with the docker socket, its worktree and its credentials made its own.
  Seen twice on tacplus#222 (tacplus#256's and tacplus#283's models, 2026-11-03), whose land passed its gates when
  they were cut off. Done in #68 (2026-11-03): each child's model as its own user, docker through a broker
  (README, Credentials).
- **The land's gates as a user of their own** (2026-11-03, #68): a model runs as its own user, but the land's
  gates run its commits (its tests, its gate map's commands, `--gates CMD`) as the job's user, which holds the
  withheld credentials and the Docker socket: what a model cannot read itself, a test it lands can. Since #90 that
  job (the verdict job) holds the report app's token, not the manager's, and its gates' environment none of the
  job's credentials; the user still owns them on disk. The gates
  could run as a gates user per land (its clone, no socket but a broker of its own, the credentials out of its
  environment), as the model does; the push and the comments after them stay the lander's.
- **The full gates as a model's user** (2026-11-03, #69): a model runs the gates as its own user, its docker the
  broker, and three fail there on main too, as they do not in the land's gates (the job's user): `looper-docker`
  (its `docker run img` reaches the real daemon, `pull access denied for img`), `tacplus` (expects `build:2.4`'s run
  in the log) and `looper-build` (its cleanup cannot remove the Go module cache a container wrote, read-only). The
  model cannot tell its change's failure from these; each test could take the broker's docker as given.
- **The broker's path checks are check, then use** (2026-11-03, #68): `looper-docker` resolves a mount's source
  (symlinks too) and refuses one outside the child's worktree and home, but the daemon resolves it again on the
  host when it mounts, and the model owns the directories on the way: one swapped for a symlink between the two
  reaches the host. Passing the resolved path narrows it; closing it needs the daemon to mount what the broker
  opened (a bind of an `O_PATH` descriptor through `/proc/<broker>/fd/N`), or the worktree on a filesystem the
  model cannot add symlinks to.
- **The model's users across jobs** (2026-11-03, #68): `repo-looper` makes `looper-<issue>` when the child starts
  (its uid and gid the first free id of the reserved range, #69) and chowns its worktree and home each time, so a worker reused by a later
  job, whose container numbers the users afresh, cannot hand one issue's files to another's model; nothing deletes
  the users, which end with the job's container. A fixed uid per issue (within that range) would make that
  independent of the order the children start in.
- **Warm caches for the models' users** (2026-11-03, #68): a model's home is its own, so its Go module and build
  caches, cargo's registry (`CARGO_HOME` in its home), npm's, Maven's and tacplus's start empty each run, where the
  job's user had one cache for every child: more downloads and longer first builds. A seed each home starts
  from (a copy of the job's caches, or a module proxy and a registry mirror on the runner) would keep the runs
  apart without the cost.
- **Room for the land's gates** (2026-10-31, #41): the lander runs a land's gates in the parent, unlimited, while
  the children go on; the child whose land it is waits meanwhile, so its share is mostly free, but a gate heavier
  than a child (Kani) can still press the VM. The capacity could keep one child's memory for the lander, or the
  lander run the gates through `looper-docker` with a land's own limit.
- **Size a child by its issue, not its repository** (2026-10-31, #41; narrowed 2026-11-05, #74): a report is now
  sized by the gate set its land runs (`gates.yaml`'s `memory:`), but a fresh report's set is not known until it has
  a diff, so it gets full's. Re-sizing it once its branch has a diff (its containers' limit is set when its run
  starts), or the plan naming the issue's areas, would size even a fresh docs-only report by docs.
- **Verify-run follow-ups** (2026-11-05, #74): a red verification is filed by the nightly scan, so a bug can wait up
  to a day after a red nightly or a red release; a credential the build project may use to write issues (the
  tacplus-reader app with `issues: write`, which would break "a build holds no credential that can change a
  repository" only for issues) would file it at once. And the scan reads only `verify-<repo>/latest`: two red runs
  between two scans file only the last.
- **Wrapped issue text when the model reads it again** (2026-10-31, #40): the prompt carries the issue's text in
  nonce blocks, but a comment posted during the run, a linked issue or a pull request the model reads itself
  (`gh issue view`) comes unwrapped: there only the prompt's rule (its author's association) stands between it and
  the run. A `repo-looper --issue-text N` the model calls instead (the same blocks, the run's nonce from its
  `.nonce`) would carry the provenance to those reads too.
- **Limit who may comment on the public repositories** (2026-10-31, #40): GitHub's interaction limits (org or
  repository: collaborators only, renewable for up to six months) would stop strangers' comments at the source,
  where looper#40 only marks them as data; it also stops legitimate outside reports, so it is Jody's call, maybe only
  on the repositories whose loopers push.
- **A land's time across jobs** (2026-10-31, #38): the lander's estimate is the repository's last land that passed
  its gates, kept in `LOOPER_WORK/<repo>/land-seconds`, which a fresh runner VM does not have: a job's first land uses
  `LOOPER_LAND_MINUTES` or the built-in default (70 minutes for tacplus, 30 for the others). Recording each land's
  time where the next job reads it (a git note on the landed commit, say, or the job's cache) would make it the
  repository's real last land, and would let `--job-timeout` size a job for its children's lands too.
- **ROADMAP.md guard that a model cannot skip** (2026-10-27, #13): repo-looper refuses a push touching ROADMAP.md
  with a pre-push hook in its checkout, which `git push --no-verify` skips. Main is protected since #83 (only the
  manager writes it, after its gates). Once reviews are wanted (README, Later),
  require Jody's review for ROADMAP.md (CODEOWNERS); until then, repo-looper could also check the run's pushed
  range (`head_before..head_after`) after the run and mark the issue `looper:stuck` if it touched ROADMAP.md.
- **Pin the planning-files check to the caller's ref** (2026-10-27, #13): the reusable workflow checks out
  `planning-files-check` from tacplus-dev/looper `main`, whatever ref the caller pinned; fine while every caller
  uses `@main`, wrong if one pins a tag.
- **Patch tags on release branches** (2026-10-27, #14): a bug's backport pull request names the patch tag to cut
  once it merges, but nothing cuts it; a release-branch workflow (or the looper, on the merge) could tag it.
- **Check that a bug's patch shipped** (2026-10-27, #14): the patch release is the prompt's rule; repo-looper could
  comment when a run closes a bug in a released repository without a new tag on main.
- **Hold the proposal run to PROPOSALS.md** (2026-10-27, #14): a feature that is not on a roadmap is only proposed,
  but the guard is the prompt; repo-looper could refuse (pre-push hook) any push from that run touching other files.
- **The scan's label guard by issue number** (2026-10-27, #14): after the nightly scan, issues numbered after the
  newest one before it are taken for the scan's; one a person opens during the scan would get `bug` or lose
  `approved` too. Filing through a wrapper that records what the scan filed would make it exact.
- **Priority within a capacity-short pipeline** (2026-10-30, #31): the order holds only as far as GitLab starts
  pending jobs in creation order. A `priority:high` issue whose repository's job is already pending behind its
  `resource_group` waits for it; a separate high-priority runner tag or GitLab job priorities would make it firm.
- **A run's limit within its job's timeout** (2026-10-27, #16): a planned job whose issue was taken meanwhile works
  the oldest ready issue instead, but keeps the job timeout computed for the planned one; if the new issue asks for a
  longer `Timeout:`, GitLab stops the job before the model's limit (its work survives as a checkpoint).
  repo-looper could cap the run's limit at `CI_JOB_TIMEOUT` less the hour it reserves.
- **An orphan's last checkpoint and its retry** (2026-10-28, #21): a run whose job GitLab no longer runs stops within
  one `LOOPER_JOB_POLL` and checkpoints to `looper/<repo>-<n>`; a retry that has already resumed from the branch
  meanwhile overwrites that checkpoint with its own (force-with-lease against what it read), losing at most that
  interval's work. The retry could wait one poll interval before resuming when the job it retries was the issue's
  last checkpointer (`CI_JOB_URL` is in each checkpoint's record), or merge a newer orphan checkpoint in.
- **The job poll and the job token** (2026-10-28, #21): with only `CI_JOB_TOKEN`, an orphan is told by GitLab
  refusing the token (`GET /job`, HTTP 401) after it was accepted; a token that never worked (an instance that limits
  job-token API access) leaves the poll blind and the run going. `GITLAB_TOKEN` (read-only) in the looper jobs'
  variables makes it exact (`GET /projects/:id/jobs/:id`), and is worth checking in the GitLab project's settings.
- **Say why a Blocked-by outcome was rejected** (2026-10-29, #22): an outcome naming a closed or missing issue, or
  the issue itself, is rejected whole and the issue is `looper:stuck` with the generic "ended without finishing"
  comment; naming the rejected blocker and the reason in that comment would save the person a trip to the run record.
- **A narrower credential for the kicker** (2026-10-29, #24): the issue asked for a project access token with `api`
  scope, held as a protected project variable; gitlab.com's Free tier does not offer project access tokens (an Owner
  gets "does not have permission"), so the kicker uses the group's `GITLAB_TOKEN`, which already has `api` and
  `write_repository`. A pipeline trigger token (protected project variable, `POST /projects/:id/trigger/pipeline`)
  could only start pipelines; the kicker would still need a read token for the jobs. Or a paid tier's project token.
  Done in #25 (2026-10-30): the trigger token for the start, a `read_api` bot for the reads (README, Credentials).
- **The model reads its parent's environment** (2026-10-30, #25): `repo-looper` withholds the GitLab credentials from
  the model's environment, but the model runs as the job's user, so `/proc/<parent>/environ` still holds them; and
  every `curl -H "PRIVATE-TOKEN: ..."` puts its token on a command line any process of the job can read. Running the
  model as another user (or in a sandbox without the job's processes), and headers from a file (`-H @file`), would make
  the withholding a boundary; until then the tokens' reach is (README, Credentials). Done in #68 (2026-11-03): the
  model as its own user, `repo-looper`'s GitLab reads with `-H @<(...)`. Still open: `looper-dispatch`'s
  `curl -H "PRIVATE-TOKEN: ..."` (the kicker's and the plan's jobs, no model beside them).
- **Rotate the bots' tokens** (2026-10-30, #25): `tacplus-looper-bot`'s token and
  membership expire within a year; nothing reminds anyone. A scheduled check of `GET /personal_access_tokens/self`
  (`expires_at`) filing an issue a month ahead would.
- **Whether fleet-seatrials' key material counts as exposed** (2026-10-30, #25): the jobs' former `GITLAB_TOKEN`
  (`api`, Owner) could read fleet-seatrials' protected variables, `FLEET_CRYPTO_YAML` among them, since they were
  stored. Jody decides whether to re-key (a fleet re-init, `deploy/init.sh` in fleet-seatrials).
- **The kicker holds a worker around the clock** (2026-10-29, #24): its job runs 57 minutes of every hour on the
  autoscaled arm64 runner (t2a-standard-8 workers, size 0 at rest before), in the full looper image, for a few `gh`
  and `curl` calls. A small runner of its own (a tag on the manager VM, say) or a slim image would cost a fraction;
  a paid tier's 5-minute schedules would let a one-pass job end in seconds.
- **The loopers' GitHub budget** (2026-10-29, #24): every looper job, the plan, the scans and the kicker share
  `GH_TOKEN`, and so one user's 5000 GraphQL points an hour (the Mac's `gh` login too, while it runs the old kicker).
  The kicker's pass used about 270 (now three requests); on 2026-10-29 the budget ran out at 06:36 and a run's own
  `gh` calls failed with it. A GitHub App installation token for the loopers (5000+ an hour of its own, per
  installation) would take them off a person's budget; `repo-looper --list` could also use `ready_by_repo`.
- **Pin the build pipeline's own image** (2026-10-29, #17): `ci/build.gitlab-ci.yml` runs plan, status and publish
  in `ghcr.io/tacplus-dev/looper:main`, a moving tag, and that image carries the claude CLI (inert there: the build
  project holds no Anthropic credential). A digest written by the image workflow, or a slim `looper-build` image
  (git, curl, jq, openssl, gcloud, buildx), would make the orchestration as fixed as the gates' image.
- **Keep ci/build.gitlab-ci.yml in step with the build project** (2026-10-29, #17): it is copied into
  gitlab.com/tacplus-dev/build by hand (as fleet-seatrials' is). A job of the looper pipeline, or the image workflow,
  could commit it there when it changes on main, or the build project could `include:` it from a project that
  mirrors this repository.
- **Line tags for released images** (2026-10-29, #17): publish pushes `<repo>:X.Y.Z` only. The services' GitHub
  release workflows also move `X.Y` (scripts/release-tags.sh) for fleets that pin a line; a step after publish,
  through the same federated token, could move it when the release is its line's highest.
- **Private dependencies in a release image** (2026-10-29, #17): publish's `docker buildx build` gets no credential,
  so a Dockerfile that fetches private tacplus-dev modules cannot. A BuildKit secret (`--secret id=github,env=...`)
  holding the read-only token would give it one without it landing in a layer.
- **Gates that need the reader app's key** (2026-10-29, #17): the gates job mints its read-only token, then deletes
  the app's key file before the repository's code runs, because the key could mint tokens with the app's every
  permission (commit statuses). Scoping `TACPLUS_READER_APP_KEY` to environments that only plan, status and publish
  declare would keep it from the gates job altogether; the gates would then need their token from elsewhere (a
  short-lived token passed in a masked, expiring way).
- **The build trigger's owner needs Maintainer** (2026-10-29, #28): D5 has the commit job start `tacplus-dev/build`
  with a trigger token owned by a bot that is a Developer there. GitLab runs a triggered pipeline as the token's owner,
  and on a protected main only a user allowed to merge to it may run one; GitLab Free grants that by role, so the bot
  must be a Maintainer of `tacplus-dev/build` (its token is revoked once the trigger exists, so only the trigger token
  is stored). Alternatives: let Developers merge to build's main (they could then merge changes to its CI), or have the
  build project watch pull requests itself.
- **The pilot's think job and releases** (2026-10-29, #28): a bug fixed through `repo-looper --think` lands by GitHub's
  squash merge; nothing tags the patch release or opens backport pull requests yet (the old prompt's rule 7 had the
  model do both with Jody's token). The commit job could tag after the merge, or a release step of the build pipeline.
- **The think job's classify and propose** (2026-10-29, #28): an unlabelled issue, or a feature no ROADMAP.md links,
  is answered `question` with a fixed text; the old flow had the model classify it, or write a design proposal into
  PROPOSALS.md. Both fit the think/commit split (the model writes, the commit job labels or opens the pull request).
- **HISTORY.md's line by pull request** (2026-10-29, #28): the think job appends the issue's line before the gates, so
  it names the pull request, not the commit (GitHub's squash commit does not exist yet). A step after the merge could
  rewrite nothing (append-only) but append the commit; or the line format could accept a pull request link.
- **A think job killed outright loses its work** (2026-10-29, #28): it cannot push, so its checkpoints only record the
  step; the commit job keeps what a run that ended left (`looper/<repo>-<n>`), but a VM lost mid-run leaves nothing.
  Its work could ride in the job's artifacts at each checkpoint (`artifacts:when: always` only covers a job that ends).
- **Keep ci/looper.gitlab-ci.yml in step with each looper's project** (2026-10-29, #28): copied by hand, as the build
  project's is (above); one file for every repository's project, so the follow-up's rollout could generate the
  projects, keys and bindings from one repository list (SYNTHESIS 4).

- **Parallel children in the think/commit flow** (2026-10-30, #32): the parent and its children run in the pipeline
  job of `tacplus-dev/looper`; kernel's identity pilot (#28) still runs one `prepare`/`think`/`commit` child pipeline
  per run under its `looper` resource group. Its parent would plan as here and start one child pipeline per issue,
  each with its own think and commit jobs; landing there is GitHub's squash merge of each pull request, so the lock
  becomes the merge itself (or a merge queue), with the gates re-run by the build on the rebased head.
- **Size the job for what fills a slot later** (2026-10-30, #33): `--job-timeout` now sizes the job for the
  longest limit among the issues ready at planning time, so they can all start together; an issue that becomes ready
  later, or one that waits for a free slot and then needs the whole limit, starts only if it still fits the job's
  remaining time. Sizing for a second round (the longest limit plus the next one's, at most 11h) would trade that for
  a job held longer when a run hangs. `looper-dispatch plan` takes the timeout from `--job-timeout`, so it needs no change.
- **The plan's areas, kept** (2026-10-30, #32): each plan asks the model about every running and candidate issue
  again (tokens are not the concern, but a plan takes minutes). The parent could keep each issue's areas from its
  first plan and ask only about the new ones, and the record could show how well the areas matched what landed
  (`git diff --name-only` of each child's commits), to tune the planning prompt.
- **A landing lock across jobs** (2026-10-30, #32): the landing lock is a file lock in the job's work directory,
  which serializes the children of one parent; one parent per repository (the `resource_group`) is what makes it the
  repository's. A second writer of main (a person, the scan's PROPOSALS.md commit) only makes a landing rebase and
  retry. If a repository ever gets two parents, the lock would have to be on GitHub (a merge queue, or a ref the
  landing creates and deletes).
- **The landing guard is a hook** (2026-10-30, #32): a push to main from a child's worktree other than `--land` is
  refused by the checkout's pre-push hook, which `git push --no-verify` (or setting `LOOPER_LANDING`) skips, as with
  the ROADMAP.md guard (above). Main's protection with a required check (the build pipeline's status, #17) would
  make "broken work never lands" hold for any push.
- **Time a land out of the model's limit, not only out of its loss** (2026-10-30, #34): the parent's lander now owns
  every land, so a child's limit no longer loses a finished fix; but the model still waits for the lock and the gates
  inside its limit, and when the limit fires first the next run (a later job) only comments and closes. The child's
  limit could pause while its land is queued or running (the watchdog already sees it), or the parent could finish
  the issue itself after landing it when the run's last checkpoint says nothing else is left.
- **Size the job for the lands left queued** (2026-10-30, #34): the parent waits for the lander before the job
  ends, inside the hour the job keeps for itself; with full gates over an hour (tacplus, 2026-10-30) a queue of two
  can outlast it. `--job-timeout` or the plan's deadline could count a land per child (the repository's last gates
  time, say).
- **A transient read failure is not stuck** (2026-10-30, #34): a feature whose platform roadmap cannot be read is
  still `looper:stuck`; a GitHub hiccup there needs no person. It could stay `approved` and be retried a few times
  before it is held.
- **Let the build image's launcher pick tacplus** (2026-10-30, #27): the wrapper now downloads, verifies and
  caches the release itself, as tacplus's `images/tacplus.sh` does, because `build:2.5` has no launcher (it came
  with tacplus#193, from 2.6) and the launcher refuses a repository without `tacplus.lock` (none has one yet, opa
  included). Once every supported line's build image has the launcher and the repositories pin, the wrapper could
  run the image's own `tacplus` and drop its copy of that logic.
- **The smoke's tacplus line** (2026-10-30, #27): `looper-smoke` generates Go at the image's own line
  (`LOOPER_TACPLUS_LINE`, the Dockerfile's `TACPLUS_LINE`); a repository on an older supported floor (2.4) is
  covered only by the wrapper's test. It could loop over every supported line.
- **Cap the think job's limit at its job too** (2026-10-30, #35): a parent's children now cap an issue's `Timeout:`
  at the job's deadline; the identity pilot's think job (`--think`, `timeout: 5h` in `ci/looper.gitlab-ci.yml`)
  still takes the issue's limit as is, so a `Timeout: 6h` there is killed by GitLab. It could use the same cap
  (`job_deadline`), with a margin sized for its gates rather than the parent's hour.
- **Size the job when it starts, not when it is planned** (2026-10-30, #35): `--job-timeout` reads the issues when
  the plan job runs; a `Timeout:` line added while the job waits for a runner now only shortens that run (capped), and
  the next job resumes it. The kicker could re-plan a pending job whose issues' limits grew.
- **Check the CI files' rules in a test** (2026-10-31, #36): no test reads `ci/build.gitlab-ci.yml` or
  `ci/looper.gitlab-ci.yml`, so which pipeline shapes their workflow and job rules admit (a push: none; `(repo, sha)`:
  the build; `smoke: true`: only `macos-smoke`) is reviewed by hand. GitLab's CI lint (`POST /projects/:id/ci/lint`,
  `dry_run`) with a read token in the image's CI, or a small rules evaluator in a test, would catch a rule that lets a
  smoke run report a status or a push create a pipeline.
- **Close an idle-after-landed issue in the same run** (2026-10-31, #37): a run that goes idle after its fix landed
  now stays `approved` and the next run only comments and closes, a whole run (worktree, prompt, model) for two
  `gh` calls. When the run's last checkpoint says only "comment and close" is left, the looper could post the
  landed range and close it itself; it needs a reliable reading of the checkpoint (a structured "left:" field
  rather than free text). Also open: an idle run that only checkpointed a new step, nothing landed or queued, is
  still `looper:stuck` (#34's rule); if headless sessions going quiet is the harness, not the model, it could
  resume instead.
- **Release a conflicting issue once the land-pending one has landed** (2026-10-31, #39): the plan now ranks a
  land-pending issue first between conflicting issues, and a conflicting issue waits until that child ends,
  which is after its land and its model's comment, any patch release and backports. Its land is what the
  conflict is about: the parent could plan again when the child's prior land lands (`land_prior`'s outcome) and
  start the conflicting issue then, from the new main. It needs the child to tell the parent (a file in the
  lands queue, say) and a rule for a land-pending issue whose model then changes more code.
- **Find how tacplus#200's land left the parent's queue** (2026-10-31, #44): the watchdog counts a queued or
  running land as activity, so #200 could only go idle at 20:05Z with its request no longer `N.req` or
  `N.running`. The one path in the code that takes it without an outcome is `land_wait` landing it itself when
  `kill -0 $LOOPER_LANDER_PID` fails (`N.taken`), which a model whose processes cannot see the parent's (a PID
  namespace) would always take. #44 makes any end with the run's `land` still `state=queued` land-pending; open:
  read job 17633047780's log (`[lander]`, "landing here") to confirm, then have `--land` find the lander by a
  file it refreshes rather than by its pid, count `N.taken` as a running land in the watchdog, and have a land
  the model's process ran report on the issue like an orphaned one.

- **Gate sets beyond the land** (2026-11-01, #48): only the lander scales the gates to the diff. The think job
  (`repo-looper --think`, #28) runs `LOOPER_GATES` or `just gates` whatever it changed, and the build pipeline's
  `gates` job (`looper-build`) always runs `just gates`: it gets a commit, no base. A `base` input (the PR's base)
  and the same `gates.yaml` reading in `looper-build` would let a kernel docs PR merge in minutes; a release build
  (`tag`) would stay full. `looper-build` is self-contained (no looper-lib.sh), so the map's reader would be
  embedded there too, or moved to a file both carry.
- **A link check and a secrets scan in this repository's docs set** (2026-11-01, #48): its `gates.yaml` `docs` set
  runs only `planning-files-check`; tacplus's design has a link check and a secrets scan too, but the image has
  neither tool. #49's scanners (gitleaks) are the natural home.
- **Preview a land's gate set** (2026-11-01, #48): a `repo-looper --gate-set [BASE]` that prints the set, why and
  its command for the current checkout would let the model verify with exactly what its land will run.
- **Trace propagation in Java handlers** (2026-11-02, #51): `looper-trace` reads Go and Rust and only names the
  Java files (kernel, stratum, eventbus are Java), so their handlers rest on the model's reading. A Java reader
  (grpc-java's `ImplBase` methods, `setTraceId(request.getTraceId())` on the builders, JUnit tests) would make the
  floor the same for all three service targets.
- **Calls through a handler's helpers** (2026-11-02, #51): `looper-trace` sees only the client calls in the
  handler's own body; a helper it calls with the request (mailbox's `RecordPlaneStore`, which the check flags as
  handlers of their own) is read by the model. Following one level of same-file helper calls, the inbound message
  or its `trace_id` passed in, would name the real handler in the finding.
- **Seams that take only references and a trace_id** (2026-11-03, #66): `looper-trace` reads a function taking a
  `trace_id` parameter as a seam only when it also takes a message by value (mailbox's `insert_if_absent`); one
  taking only references (mailbox's `get`, oauth's `exchange_token`) is still not read, so a dropped trace in it
  is not seen. Reading every function with a `trace_id` parameter and a client call would flag oauth's
  `exchange_token` (no test reaches it with a `trace_id`; its one caller passes `""`). Its coverage lookup also
  follows callers by name only, so a seam named like a common method (`get`) is credited by almost any test.
- **USER.md's propagation test example per language** (2026-11-02, #51): the rule points at USER.md's pattern for
  the test, but USER.md's Distributed Tracing section shows only the propagation, not the test; tacplus#265 adds a
  test example per language, and is parked until the trace huddle with Jody. Until then the fixture in
  tests/looper-trace.test.sh is the nearest example (a fake downstream client recording the request it got).
- **The first scan findings** (2026-11-02, #51): run by hand on tacplus-dev's services, the check flags
  gateway's `mint_token`/`mint_x509_cert` (proxies, with no propagation test), oauth's `mint_callback_tokens` (no
  propagation test) and mailbox's record-plane calls (no `trace_id` anywhere in its source). The nightly scans file
  them as bugs once this lands; nothing was filed by hand.
- **The hub lints before it copies a CI file** (2026-11-05, #94): `looper-ci-lint` gates a land, but the hub's copy
  to GitLab (README, The pipeline file) is a manual PUT; running `looper-ci-lint` (or GitLab's `POST
  /projects/:id/ci/lint`) on the exact content first, and refusing on an error, would close the gap for a file that
  reaches GitLab another way. Shipping `looper-ci-lint` and its schema in the image would let the hub run it anywhere.
- **Lint each CI file in its own project** (2026-11-05, #94): with `GITLAB_TOKEN`, `looper-ci-lint` sends only
  `ci/tacplus-dev.gitlab-ci.yml` to GitLab's lint API (project 88136765); `build`, `looper` and `instance` are linted
  offline only, their projects' ids not mapped (and `instance` is on SeaBeam's group). Mapping them, and checking a
  token with the `api` scope reaches the land's gates, would make GitLab's own verdict the gate everywhere.
- **Refresh the vendored CI schema** (2026-11-05, #94): `ci/gitlab-ci.schema.json` is GitLab's `ci.json` at
  a38e1992; a keyword GitLab adds later is refused offline until it is refreshed. The nightly scan could compare it
  with GitLab's current file and propose the update.
- **The security checks scan the binaries the image builds** (2026-11-06, #101): the build's checks scan the tree
  and the Dockerfile's base images, not the Go tools the `Dockerfile` compiles into the looper image (osv-scanner,
  trivy, gitleaks, syft, govulncheck, glab). The nightly scan found GO-2026-6865 and GO-2026-6888 in them only with
  `govulncheck -mode=binary` by hand (#101, #47). Running govulncheck in binary mode on each Go binary of the image
  `publish` pushes, under the same policy (a fixed version HIGH fails), would put a deterministic floor under
  that check as well, and catch an override (looper#65, #88) that stopped working.
- **A secret's identity that survives a moved line** (2026-11-12, #120, #129): a gitleaks finding's id is
  `<path>:<rule>:<line>` (looper-scan, README: Security checks), both for `new` and for an exception's `id`. So an
  unchanged fixture that moves is a new finding: #120's withheld `GITLAB_TOKEN` fixture at
  `tests/repo-looper.test.sh:2253` came back as a new CRITICAL at `:2290` once 4ade983 (#105) added lines above it, and
  any dated exception for a secret would stop matching on the next edit above it. Keying `new` (and accepting an
  exception's id) on gitleaks' own `Fingerprint` without its line, or on the path, rule and a hash of the matched
  secret, would keep a moved secret the same finding; the line stays in `where`. #129's one issue per cause is the
  issue-side half of the same noise.

## Promoted / declined
- **Report the image's revision against main's head** (2026-11-03, #58): done in #57 (2026-11-03): the recap
  compares `ghcr.io/tacplus-dev/looper:main`'s `org.opencontainers.image.revision` with main's head.
- **A manual macOS smoke job in the build pipeline** (2026-10-31, #36): `ci/build.gitlab-ci.yml` gets a `smoke`
  boolean input (default false) and a workflow rule for a web run on `main` with it set, whose pipeline holds only a
  manual `macos-smoke` job (tag `macos`, the Tart image `macos-tahoe-xcode:27.1`, no credentials) checking arm64,
  `sw_vers`, Xcode 27.x and Swift; the build's own jobs and publish get rules that leave it. It proves Jody's Mac
  runner before tacplus#195's `swift:` and darwin/arm64 `rust:` recipes rely on it. Approved, but no ROADMAP.md
  links it (tacplus's lists #195 only); the design and Jody's questions are on the issue.
  **Promoted** (2026-10-30, ROADMAP.md Next; built 2026-10-31, #36).
- **The recap counts dropped STATE.md commits** (2026-11-11, #131): the manager logs `#N: dropped its STATE.md
  commit` when STATE.md was a land's only conflict; `looper-recap` reads `resolved its conflicts by regenerating`
  and `not merged (exit 3)` only, so a drop counts as a plain merge. Counting them beside the sent-backs would show
  whether the docs-only lands again they cause are worth a union or a regeneration of STATE.md instead.
