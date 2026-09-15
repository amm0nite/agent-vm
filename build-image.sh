#!/usr/bin/env bash
set -Eeuo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
image_dir="$script_dir/images"
log_dir="$script_dir/logs"
upstream_image="$image_dir/Arch-Linux-x86_64-cloudimg.qcow2"
upstream_checksum="$upstream_image.SHA256"
prepared_image="$image_dir/arch-agent-base.qcow2"
seed_image="$image_dir/cloud-init-seed.iso"
rendered_user_data="$image_dir/cloud-init-user-data.build"
ssh_key="$image_dir/agent-ssh-key"
persist_home_config="$script_dir/config/persist-home.conf"
image_url="https://fastly.mirror.pkgbuild.com/images/latest/Arch-Linux-x86_64-cloudimg.qcow2"

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

# Keep the lock file in place: all builders must lock the same inode.
# Lock before touching logs, keys, downloads, or build artifacts.
command -v flock >/dev/null 2>&1 || die "missing flock; install util-linux"
mkdir -p "$image_dir"
exec 9>"$image_dir/build.lock"
flock -n 9 || die "another image build is already in progress"

mkdir -p "$log_dir"
log_file="$log_dir/build-$(date -u +%Y%m%dT%H%M%SZ).log"
ln -sfn "$(basename -- "$log_file")" "$log_dir/latest-build.log"
exec > >(tee -a "$log_file") 2>&1

build_finished=false
report_result() {
  status=$?
  if [[ "$build_finished" == true ]]; then
    printf 'Build log: %s\n' "$log_file"
  elif [[ $status -ne 0 ]]; then
    printf '\nBuild failed with status %d.\n' "$status"
    printf 'Full log: %s\n' "$log_file"
  else
    printf '\nBuild stopped before completion.\n'
    printf 'Full log: %s\n' "$log_file"
  fi
}
trap report_result EXIT

if [[ "${ARCH_AGENT_TRACE:-0}" == 1 ]]; then
  export PS4='+ ${BASH_SOURCE}:${LINENO}: '
  set -x
fi

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "missing command '$1' ($2)"
}

force=false
if [[ "${1:-}" == --force ]]; then
  force=true
elif [[ $# -ne 0 ]]; then
  die "usage: $0 [--force]"
fi

require_command curl "install curl"
require_command qemu-img "install QEMU"
require_command qemu-system-x86_64 "install qemu-system-x86_64"
require_command cloud-localds "install cloud-image-utils"
require_command sha256sum "install coreutils"
require_command ssh-keygen "install openssh-client"
require_command base64 "install coreutils"
[[ -r "$persist_home_config" ]] || die "missing persistence config: $persist_home_config"

while read -r entry_type home_relative workspace_relative extra; do
  [[ -n "$entry_type" ]] || continue
  [[ "$entry_type" != \#* ]] || continue
  case "$entry_type" in
    dir|file|json) ;;
    *) die "unknown persistence type '$entry_type' in $persist_home_config" ;;
  esac
  if [[ -z "$home_relative" || -z "$workspace_relative" || -n "$extra" ||
        "$home_relative" == /* || "$workspace_relative" == /* ||
        "$home_relative" == "." || "$workspace_relative" == "." ||
        "/$home_relative/" == *"/../"* || "/$workspace_relative/" == *"/../"* ]]; then
    die "invalid persistence entry: $entry_type $home_relative $workspace_relative $extra"
  fi
done <"$persist_home_config"

mkdir -p "$image_dir"

if [[ ! -e "$ssh_key" ]]; then
  printf 'Creating a dedicated SSH key for this VM...\n'
  ssh-keygen -q -t ed25519 -N '' -C arch-agent-vm -f "$ssh_key"
fi
chmod 600 "$ssh_key"
ssh_public_key="$(<"$ssh_key.pub")"
persist_home_config_base64="$(base64 -w 0 "$persist_home_config")"

if [[ -e "$prepared_image" && "$force" != true ]]; then
  die "$prepared_image already exists; use --force to rebuild it"
fi

printf 'Downloading the official Arch cloud image...\n'
curl --fail --location --retry 3 --output "$upstream_checksum" "$image_url.SHA256"

if ! (cd "$image_dir" && sha256sum --check --status "$(basename -- "$upstream_checksum")"); then
  if [[ -e "$upstream_image" ]]; then
    printf 'Cached image does not match the current checksum; downloading a fresh copy...\n'
    rm -f -- "$upstream_image"
  else
    printf 'Downloading the Arch cloud image...\n'
  fi
  curl --fail --location --retry 3 --output "$upstream_image" "$image_url"
fi

printf 'Verifying image checksum...\n'
(cd "$image_dir" && sha256sum --check "$(basename -- "$upstream_checksum")")

build_image="$image_dir/arch-agent-base.build.qcow2"
rm -f -- "$build_image" "$seed_image" "$rendered_user_data"
cp --reflink=auto -- "$upstream_image" "$build_image"
qemu-img resize "$build_image" +8G
sed \
  -e "s|@@ARCH_AGENT_SSH_PUBLIC_KEY@@|$ssh_public_key|" \
  -e "s|@@ARCH_AGENT_PERSIST_HOME_CONFIG@@|$persist_home_config_base64|" \
  "$script_dir/cloud-init/user-data" >"$rendered_user_data"
cloud-localds "$seed_image" "$rendered_user_data" "$script_dir/cloud-init/meta-data"

acceleration=(-machine accel=tcg)
if [[ -r /dev/kvm && -w /dev/kvm ]]; then
  acceleration=(-enable-kvm -cpu host)
fi

printf 'Provisioning the image. The VM will power itself off when ready...\n'
qemu-system-x86_64 \
  "${acceleration[@]}" \
  -name arch-agent-image-builder \
  -m 4096 \
  -smp 2 \
  -nographic \
  -no-reboot \
  -nic user,model=virtio-net-pci \
  -drive "if=none,id=os,file=$build_image,format=qcow2" \
  -device virtio-blk-pci,drive=os,serial=AI_OS \
  -drive "if=virtio,file=$seed_image,format=raw,readonly=on"

if ! grep -Fq ARCH_AGENT_IMAGE_READY "$log_file"; then
  die "guest provisioning did not emit its success marker; refusing to save the base image"
fi

mv -f -- "$build_image" "$prepared_image"
rm -f -- "$seed_image" "$rendered_user_data"
build_finished=true

printf '\nReady: %s\n' "$prepared_image"
printf 'Next:  %s codex\n' "$script_dir/run.sh"
