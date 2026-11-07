# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# Sourced first by a test that must not read the environment it runs in
# (looper#103): a looper job's apps (LOOPER_REPORT_*, LOOPER_MANAGER_*), its
# job tags (LOOPER_JOB_TAGS_*), gh's configuration (GH_CONFIG_DIR) and git's
# global credential helper would change what the scripts under test do, and a
# credential they find can reach the test's server and its log. The test runs
# again under `env -i`, with only what it needs and a HOME of its own (git's
# global configuration), which is removed when it ends.
# Use: source "$(dirname "${BASH_SOURCE[0]}")/hermetic.sh"   (before anything else)
if [[ -z "${LOOPER_TEST_HERMETIC:-}" ]]; then
  _hermetic_home="$(mktemp -d)"; _hermetic_rc=0
  env -i LOOPER_TEST_HERMETIC=1 PATH="$PATH" HOME="$_hermetic_home" USER="${USER:-$(id -un)}" \
    LANG=C.UTF-8 TERM=dumb ${TMPDIR:+TMPDIR="$TMPDIR"} \
    "$BASH" "${BASH_SOURCE[1]}" "$@" || _hermetic_rc=$?
  rm -rf "$_hermetic_home"
  exit "$_hermetic_rc"
fi
