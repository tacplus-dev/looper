#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# The runner VMs' image and readiness (looper#43). runner/startup.sh runs as
# root in an Ubuntu container (with a docker daemon at hand; its files go in on
# stdin, so no bind mount) with stub systemctl, docker, apt-get, curl and gpg:
# /var/run/runner-ready only once Docker is active, never on a failure (a
# stale one removed); a baked image starts Docker and restarts nothing; a
# stock one installs and restarts it first; the bake readies the disk. Then
# runner-image against a stub gcloud and curl: build publishes in the family
# only an image whose VM boots ready as baked, and leaves no VM behind; the
# token goes through a file, never a command line; template copies the source
# with the family and the startup-script; measure reports the creation to
# "Running on" times and the jobs that failed before it.
# Run: tests/runner-image.test.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
NAME=""
fail() { echo "FAIL $NAME: $*" >&2; exit 1; }
pass() { echo "ok $NAME"; }
has() { grep -qF -- "$2" "$1" || fail "$(basename "$1") lacks: $2"; }
lacks() { ! grep -qF -- "$2" "$1" || fail "$(basename "$1") has: $2"; }

# --- runner/startup.sh, in a container ----------------------------------------
UBUNTU="${RUNNER_TEST_UBUNTU:-ubuntu:24.04}"
ctx="$TMP/ctx"; mkdir -p "$ctx/stubs"
cp "$ROOT/runner/startup.sh" "$ROOT/runner/bake.sh" "$ctx/"
stub() { printf '#!/bin/bash\n%s\n' "$2" > "$ctx/stubs/$1"; chmod +x "$ctx/stubs/$1"; }
# Docker is active once started, unless the state says it never comes up.
stub systemctl 'echo "systemctl: $*" >> /log
case "$1" in
  is-active) [[ -e /state/active ]] ;;
  start|restart) [[ -e /state/broken ]] || touch /state/active ;;
  stop) rm -f /state/active ;;
esac'
stub docker '[[ "$1" == info && -e /state/active ]]'
stub apt-get 'echo "apt-get: $*" >> /log; [[ "$1" != install ]] || cp /t/stubs/docker /usr/local/sbin/docker'
stub curl 'for a; do case "$a" in */guest-attributes/*) k="${a#*/guest-attributes/}";; esac; done
prev=""; for a; do [[ "$prev" != --data ]] || v="$a"; prev="$a"; done
if [[ -n "${k:-}" ]]; then echo "attribute: $k $v" >> /log; else echo key; fi'
stub gpg 'cat >/dev/null; while (($#)); do [[ "$1" != -o ]] || touch "$2"; shift; done'
stub sleep 'true'
stub cloud-init 'echo "cloud-init: $*" >> /log'
cat > "$ctx/run.sh" <<'EOF'
set -u
mkdir -p /state /usr/local/sbin; : > /log
cp /t/stubs/systemctl /t/stubs/apt-get /t/stubs/curl /t/stubs/gpg /t/stubs/sleep /t/stubs/cloud-init /usr/local/sbin/
for s in $SETUP; do
  case "$s" in
    docker) cp /t/stubs/docker /usr/local/sbin/ ;;
    dropin) mkdir -p /etc/systemd/system/docker.socket.d; printf '[Socket]\nSocketGroup=fleeting\n' > /etc/systemd/system/docker.socket.d/override.conf ;;
    olddropin) mkdir -p /etc/systemd/system/docker.socket.d; printf '[Socket]\nSocketGroup=docker\n' > /etc/systemd/system/docker.socket.d/override.conf ;;
    broken) touch /state/broken ;;
    stale) mkdir -p /var/run; touch /var/run/runner-ready ;;
  esac
done
if [[ "$SCRIPT" == bake ]]; then cat /t/startup.sh /t/bake.sh > /t/script; else cp /t/startup.sh /t/script; fi
rc=0; bash /t/script > /dev/null 2>&1 || rc=$?
cat /log
echo "rc: $rc"
[[ -e /var/run/runner-ready ]] && echo "ready: yes" || echo "ready: no"
echo "dropin: $(tr '\n' ' ' < /etc/systemd/system/docker.socket.d/override.conf 2>/dev/null)"
id fleeting >/dev/null 2>&1 && echo "fleeting: yes"
EOF
boot() { # script setup...: runs it; its report is $TMP/out
  local script="$1"; shift
  tar -C "$ctx" -c . | docker run -i --rm -e SCRIPT="$script" -e SETUP="$*" "$UBUNTU" \
    bash -c 'mkdir /t && tar -C /t -x && bash /t/run.sh' > "$TMP/out" 2>&1 || fail "the container: $(cat "$TMP/out")"
}

if docker info >/dev/null 2>&1 && { docker image inspect "$UBUNTU" >/dev/null 2>&1 || docker pull -q "$UBUNTU" >/dev/null 2>&1; }; then
  # The image: Docker, the drop-in and the user baked in. Nothing installed or restarted.
  NAME=startup-baked
  boot startup docker dropin
  has "$TMP/out" "rc: 0"; has "$TMP/out" "ready: yes"
  has "$TMP/out" "systemctl: start docker.socket docker"; lacks "$TMP/out" "restart"; lacks "$TMP/out" "apt-get"
  grep -qE '^attribute: runner/ready [0-9]+ baked$' "$TMP/out" || fail "no ready attribute: $(cat "$TMP/out")"
  pass

  # A stock image: Docker installed and restarted, all before the VM is ready.
  NAME=startup-stock
  boot startup
  has "$TMP/out" "rc: 0"; has "$TMP/out" "ready: yes"; has "$TMP/out" "fleeting: yes"
  has "$TMP/out" "apt-get: install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin"
  has "$TMP/out" "systemctl: restart docker.socket docker"
  has "$TMP/out" "dropin: [Socket] SocketGroup=fleeting "
  grep -qE '^attribute: runner/ready [0-9]+ installed$' "$TMP/out" || fail "no ready attribute: $(cat "$TMP/out")"
  pass

  NAME=startup-dropin-changed
  boot startup docker olddropin
  has "$TMP/out" "rc: 0"; has "$TMP/out" "ready: yes"; lacks "$TMP/out" "apt-get"
  has "$TMP/out" "systemctl: restart docker.socket docker"; has "$TMP/out" "dropin: [Socket] SocketGroup=fleeting "
  pass

  # Docker never comes up: never ready, even with a ready file left from before.
  NAME=startup-never-ready
  boot startup docker dropin broken stale
  grep -q '^rc: [1-9]' "$TMP/out" || fail "it succeeded: $(cat "$TMP/out")"
  has "$TMP/out" "ready: no"; has "$TMP/out" "attribute: runner/ready failed"
  lacks "$TMP/out" "attribute: runner-image"
  pass

  NAME=bake
  boot bake
  has "$TMP/out" "rc: 0"; has "$TMP/out" "ready: no"
  has "$TMP/out" "apt-get: install"; has "$TMP/out" "systemctl: disable --now apt-daily.timer apt-daily-upgrade.timer"
  has "$TMP/out" "apt-get: clean"; has "$TMP/out" "systemctl: stop docker.socket docker"
  has "$TMP/out" "cloud-init: clean --logs --machine-id"
  [[ "$(tail -n +1 "$TMP/out" | grep '^attribute:' | tail -1)" == "attribute: runner-image/baked done" ]] ||
    fail "the bake's last attribute: $(cat "$TMP/out")"
  pass

  NAME=bake-fails
  boot bake broken
  grep -q '^rc: [1-9]' "$TMP/out" || fail "it succeeded: $(cat "$TMP/out")"
  has "$TMP/out" "attribute: runner/ready failed"; lacks "$TMP/out" "runner-image/baked"
  pass
else
  echo "skip startup.sh: no docker daemon, or no $UBUNTU"
fi

# --- runner-image, against a stub gcloud ---------------------------------------
bin="$TMP/bin"; G="$TMP/gcloud"; mkdir -p "$bin" "$G/attrs" "$G/scripts"
export G
cat > "$bin/gcloud" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$G/log"
arg() { local a; for a in "${@:2}"; do [[ "$a" != "--$1="* ]] || { echo "${a#--$1=}"; return; }; done; }
args=("$@"); set -- "${args[@]/--quiet/}"; while [[ "$1" == "" || "$1" == --project=* ]]; do shift; done
case "$1 $2 $3" in
  "compute instances create")
    vm="$4"; echo "$vm" >> "$G/live"; mkdir -p "$G/attrs/$vm"
    f="$(arg metadata-from-file "$@")"; cp "${f#startup-script=}" "$G/scripts/$vm"
    case "$vm" in
      # startup.sh reports the bake VM ready (it installed Docker) before bake.sh is done.
      *bake*) case "$BAKE" in
                done) echo "95 installed" > "$G/attrs/$vm/runner_ready"; echo done > "$G/attrs/$vm/runner-image_baked" ;;
                failed) echo failed > "$G/attrs/$vm/runner_ready" ;;
                none) echo "95 installed" > "$G/attrs/$vm/runner_ready" ;;
              esac ;;
      *smoke*) [[ -z "$SMOKE" ]] || echo "$SMOKE" > "$G/attrs/$vm/runner_ready" ;;
    esac ;;
  "compute instances delete") grep -vxF "$4" "$G/live" > "$G/live.new" || true; mv "$G/live.new" "$G/live" ;;
  "compute instances get-guest-attributes")
    k="$(arg query-path "$@")"; cat "$G/attrs/$4/${k//\//_}" 2>/dev/null || { echo "not found" >&2; exit 1; } ;;
  "compute instances get-serial-port-output") echo "serial: the bake's console" ;;
  "compute images create") echo "$4" >> "$G/images" ;;
  "compute images delete") grep -vxF "$4" "$G/images" > "$G/images.new" || true; mv "$G/images.new" "$G/images" ;;
  "compute images list") printf '%s\n' runner-arm64-docker-new runner-arm64-docker-3 runner-arm64-docker-2 runner-arm64-docker-1 ;;
  "compute instance-templates describe") cat "$G/template.json" ;;
  "auth print-access-token "*) echo access-token ;;
  "iam workload-identity-pools create-cred-config") echo '{"federated": true}' > "$(arg output-file "$@")" ;;
esac
exit 0
EOF
chmod +x "$bin/gcloud"
ri() { PATH="$bin:$PATH" RUNNER_IMAGE_POLL=0 "$ROOT/runner-image" "$@"; }
build() { # bake smoke: runner-image build, exit in rc
  rm -rf "$G/attrs" "$G/scripts"; mkdir -p "$G/attrs" "$G/scripts"; : > "$G/log"; : > "$G/live"; : > "$G/images"
  rc=0; BAKE="$1" SMOKE="$2" ri build > "$TMP/stdout" 2> "$TMP/stderr" || rc=$?
}

NAME=build
build done "11 baked"
((rc == 0)) || fail "exit $rc: $(cat "$TMP/stderr")"
image="$(cat "$TMP/stdout")"
[[ "$image" =~ ^runner-arm64-docker-[0-9]{8}-[0-9]{6}$ ]] || fail "the image: $image"
has "$G/log" "compute instances create runner-image-bake-"
grep -E "instances create runner-image-bake-.* --image-family=ubuntu-2404-lts-arm64 --image-project=ubuntu-os-cloud" "$G/log" |
  grep -q -- "--no-service-account --no-scopes" || fail "the bake VM: $(cat "$G/log")"
bake_vm="$(ls "$G/scripts" | grep bake)"; smoke_vm="$(ls "$G/scripts" | grep smoke)"
[[ "$(cat "$G/scripts/$bake_vm")" == "$(cat "$ROOT/runner/startup.sh" "$ROOT/runner/bake.sh")" ]] || fail "the bake's script"
cmp -s "$G/scripts/$smoke_vm" "$ROOT/runner/startup.sh" || fail "the smoke's script is not startup.sh"
has "$G/log" "compute instances create $smoke_vm --zone=us-central1-b --machine-type=t2a-standard-2 --image=$image-candidate --image-project=jody1-328023"
# The bake VM is stopped before its disk is imaged; the family gets the image only after the smoke.
line() { grep -nF -- "$1" "$G/log" | head -1 | cut -d: -f1; }
prev=0
for step in "instances stop $bake_vm" "images create $image-candidate --source-disk=$bake_vm" "instances create $smoke_vm" \
            "images create $image --source-image=$image-candidate --source-image-project=jody1-328023 --family=runner-arm64-docker"; do
  n="$(line "$step")"; [[ -n "$n" ]] && ((n > prev)) || fail "not in order: $step: $(cat "$G/log")"; prev="$n"
done
[[ ! -s "$G/live" ]] || fail "VMs left: $(cat "$G/live")"
[[ "$(cat "$G/images")" == "$image" ]] || fail "images left: $(cat "$G/images")"
# The newest three in the family are kept.
grep -qx -- "--quiet --project=jody1-328023 compute images delete runner-arm64-docker-1" "$G/log" || fail "the oldest kept"
! grep -qE -- "images delete runner-arm64-docker-(new|3|2)$" "$G/log" || fail "a newer one deleted: $(cat "$G/log")"
has "$TMP/stderr" "ready 11s after boot"
pass

NAME=build-bake-fails
build failed ""
((rc != 0)) || fail "it succeeded"
has "$TMP/stderr" "startup.sh failed"; has "$TMP/stderr" "serial: the bake's console"
lacks "$G/log" "images create"; [[ ! -s "$G/live" ]] || fail "VMs left: $(cat "$G/live")"
pass

NAME=build-bake-times-out
RUNNER_IMAGE_BAKE_TIMEOUT=0 build none ""
((rc != 0)) || fail "it succeeded"
has "$TMP/stderr" "the bake did not finish: timeout"
lacks "$G/log" "images create"; [[ ! -s "$G/live" ]] || fail "VMs left: $(cat "$G/live")"
pass

# A candidate whose VM had to install Docker at boot, or never got ready, is not published.
for smoke in "40 installed" failed ""; do
  NAME="build-smoke-${smoke:-silent}"
  RUNNER_IMAGE_READY_TIMEOUT=0 build done "$smoke"
  ((rc != 0)) || fail "it succeeded"
  has "$TMP/stderr" "is not ready as baked"
  lacks "$G/log" "--family="; [[ ! -s "$G/images" ]] || fail "images left: $(cat "$G/images")"
  [[ ! -s "$G/live" ]] || fail "VMs left: $(cat "$G/live")"
  pass
done

# The pipeline's identity: the id_token through a file, never on a command line.
NAME=build-wif
: > "$G/log"
GCP_ID_TOKEN=eyJ.secret.token GCP_WIF_PROVIDER=projects/1/locations/global/workloadIdentityPools/p/providers/g \
  RUNNER_IMAGE_SA=runner-image@jody1-328023.iam.gserviceaccount.com build done "9 baked"
((rc == 0)) || fail "exit $rc: $(cat "$TMP/stderr")"
has "$G/log" "iam workload-identity-pools create-cred-config projects/1/locations/global/workloadIdentityPools/p/providers/g --service-account=runner-image@jody1-328023.iam.gserviceaccount.com"
has "$G/log" "auth login --cred-file="; lacks "$G/log" "eyJ.secret.token"
pass

# --- template ------------------------------------------------------------------
NAME=template
cat > "$G/template.json" <<'EOF'
{"id": "1", "name": "runner-arm64-t2a8-v5", "selfLink": "x", "creationTimestamp": "t",
 "properties": {"machineType": "t2a-standard-8",
  "disks": [{"boot": true, "autoDelete": true, "initializeParams": {"sourceImage": "projects/ubuntu-os-cloud/global/images/family/ubuntu-2404-lts-arm64", "diskSizeGb": "100"}},
            {"boot": false, "initializeParams": {"sourceImage": "keep-me"}}],
  "serviceAccounts": [{"email": "build-box@jody1-328023.iam.gserviceaccount.com", "scopes": ["https://www.googleapis.com/auth/cloud-platform"]}],
  "metadata": {"fingerprint": "abc", "kind": "compute#metadata",
   "items": [{"key": "ssh-keys", "value": "fleeting:ssh-ed25519 AAAA"}, {"key": "startup-script", "value": "apt-get install docker-ce"}]}}}
EOF
cat > "$bin/curl" <<'EOF'
#!/usr/bin/env bash
url="${*: -1}"; echo "$url" >> "$G/curl"
case "$url" in
  */global/instanceTemplates) cat > "$G/body.json"; echo '{"name": "op-1"}' ;;
  */global/operations/op-1/wait) echo "${OP:-{\"status\": \"DONE\"\}}" ;;
  *) exit 22 ;;
esac
EOF
chmod +x "$bin/curl"
: > "$G/curl"
ri template runner-arm64-t2a8-v5 runner-arm64-t2a8-v7 2> "$TMP/stderr" || fail "exit: $(cat "$TMP/stderr")"
has "$G/curl" "https://compute.googleapis.com/compute/v1/projects/jody1-328023/global/instanceTemplates"
b="$G/body.json"
q() { jq -r "$1" "$b"; }
[[ "$(q .name)" == runner-arm64-t2a8-v7 && "$(q '.id // "none"')" == none ]] || fail "name: $(cat "$b")"
[[ "$(q '.properties.disks[0].initializeParams.sourceImage')" == projects/jody1-328023/global/images/family/runner-arm64-docker ]] || fail "boot image: $(cat "$b")"
[[ "$(q '.properties.disks[0].initializeParams.diskSizeGb')" == 100 && "$(q '.properties.disks[1].initializeParams.sourceImage')" == keep-me ]] || fail "disks: $(cat "$b")"
[[ "$(q '.properties.serviceAccounts[0].email')" == build-box@jody1-328023.iam.gserviceaccount.com && "$(q .properties.machineType)" == t2a-standard-8 ]] || fail "the rest: $(cat "$b")"
[[ "$(q '.properties.metadata.items[] | select(.key == "startup-script") | .value')" == "$(cat "$ROOT/runner/startup.sh")" ]] || fail "startup-script"
[[ "$(q '[.properties.metadata.items[] | select(.key == "startup-script")] | length')" == 1 ]] || fail "two startup-scripts"
[[ "$(q '.properties.metadata.items[] | select(.key == "ssh-keys") | .value')" == "fleeting:ssh-ed25519 AAAA" ]] || fail "ssh-keys"
[[ "$(q '.properties.metadata.items[] | select(.key == "enable-guest-attributes") | .value')" == TRUE ]] || fail "guest attributes"
[[ "$(q '.properties.metadata.fingerprint // "none"')" == none ]] || fail "fingerprint kept"
pass

NAME=template-fails
OP='{"status": "DONE", "error": {"errors": [{"code": "QUOTA"}]}}' ri template runner-arm64-t2a8-v5 v7 2> "$TMP/stderr" && fail "it succeeded"
has "$TMP/stderr" "QUOTA"
pass

# --- measure -------------------------------------------------------------------
NAME=measure
cat > "$bin/curl" <<'EOF'
#!/usr/bin/env bash
url="${*: -1}"
[[ "$*" == *"PRIVATE-TOKEN: glpat-read"* ]] || exit 22
case "$url" in
  */projects/tacplus-dev%2Flooper/jobs\?*) cat <<'J'
[{"id": 105, "name": "looper:tacplus", "status": "success", "created_at": "2026-11-01T10:00:00.000Z", "runner": {"id": 57939705}},
 {"id": 104, "name": "looper:kernel", "status": "failed", "created_at": "2026-11-01T09:00:00.000Z", "failure_reason": "runner_system_failure", "runner": {"id": 57939705}},
 {"id": 103, "name": "elsewhere", "status": "success", "created_at": "2026-11-01T08:00:00.000Z", "runner": {"id": 1}},
 {"id": 102, "name": "looper-kick", "status": "success", "created_at": "2026-11-01T07:00:00.000Z", "runner": {"id": 57939705}},
 {"id": 101, "name": "looper:old", "status": "success", "created_at": "2026-11-01T06:00:00.000Z", "runner": {"id": 57939705}}]
J
  ;;
  */jobs/105/trace) printf '\033[0Ksection_start:%s:prepare_executor\r\033[0KPreparing\n\033[0Ksection_start:%s:prepare_script\r\033[0KRunning on runner-x\n' \
                      "$(date -d 2026-11-01T10:00:30Z +%s)" "$(date -d 2026-11-01T10:01:35Z +%s)" ;;
  */jobs/104/trace) printf '\033[0Ksection_start:%s:prepare_executor\r\033[0Kfailed to pull image\n' "$(date -d 2026-11-01T09:00:30Z +%s)" ;;
  */jobs/102/trace) printf '\033[0Ksection_start:%s:prepare_script\r\033[0KRunning on runner-y\n' "$(date -d 2026-11-01T07:00:40Z +%s)" ;;
  *) exit 22 ;;
esac
EOF
GITLAB_TOKEN=glpat-read RUNNER_IMAGE_RUNNER=57939705 ri measure 3 > "$TMP/stdout" 2> "$TMP/stderr" || fail "exit: $(cat "$TMP/stderr")"
has "$TMP/stdout" "105          looper:tacplus           success  2026-11-01T10:00:00  95s"
has "$TMP/stdout" "104          looper:kernel            failed   2026-11-01T09:00:00  failed before it (runner_system_failure)"
has "$TMP/stdout" "102          looper-kick              success  2026-11-01T07:00:00  40s"
lacks "$TMP/stdout" "elsewhere"; lacks "$TMP/stdout" "looper:old"
has "$TMP/stdout" "2 jobs reached Running on, 1 failed before it; seconds from creation: min 40, median 40, max 95"
pass
