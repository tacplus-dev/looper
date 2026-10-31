# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# The bake (looper#43): not a script of its own. `runner-image build` boots a
# stock Ubuntu arm64 VM whose startup-script is runner/startup.sh followed by
# this file, so the image gets Docker exactly as a worker would have installed
# it at boot (startup.sh's ERR trap still reports a failure here). Once Docker
# is up, this readies the disk to become the image runner-arm64-docker and says
# so in the guest attribute runner-image/baked; runner-image then stops the VM
# and images its disk.

# No apt run at a worker's boot: a worker lives for one job, and the image is
# rebaked for updates (README: Infrastructure). apt-daily and its upgrade could
# otherwise hold the dpkg lock, or restart a service, under the first job.
systemctl disable --now apt-daily.timer apt-daily-upgrade.timer >/dev/null 2>&1
apt-get clean
rm -rf /var/lib/apt/lists/*

# Nothing of this VM in the image: each worker is a new instance to cloud-init
# (new ssh host keys, a new machine-id); Docker is stopped, its state flushed.
systemctl stop docker.socket docker
if command -v cloud-init >/dev/null; then cloud-init clean --logs --machine-id; fi
rm -f /var/run/runner-ready
sync
attribute runner-image/baked done
echo "runner: baked"
