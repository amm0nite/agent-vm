#!/usr/bin/env bash
set -Eeuo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
image_dir="$script_dir/images"
base_image="$image_dir/arch-agent-base.qcow2"
workspace_image="$image_dir/workspace.qcow2"
workspace_lock="$image_dir/workspace.lock"
ssh_key="$image_dir/agent-ssh-key"
workspace_size="${ARCH_AGENT_WORKSPACE_SIZE:-64G}"
ssh_port="${ARCH_AGENT_SSH_PORT:-2222}"
display_mode="${ARCH_AGENT_DISPLAY:-none}"
mode="${1:-shell}"

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

case "$mode" in
  codex|claude|shell) ;;
  *) die "usage: $0 [codex|claude|shell]" ;;
esac

case "$display_mode" in
  none)
    display=(-display none)
    ;;
  gtk)
    display=(-display gtk,zoom-to-fit=on -device virtio-vga,edid=on,xres=1280,yres=800)
    ;;
  *) die "ARCH_AGENT_DISPLAY must be 'none' or 'gtk'" ;;
esac

[[ "$ssh_port" =~ ^[0-9]+$ ]] && (( ssh_port >= 1 && ssh_port <= 65535 )) || \
  die "ARCH_AGENT_SSH_PORT must be a port number between 1 and 65535"

command -v qemu-img >/dev/null 2>&1 || die "missing qemu-img; install QEMU"
command -v qemu-system-x86_64 >/dev/null 2>&1 || die "missing qemu-system-x86_64; install QEMU"
command -v jq >/dev/null 2>&1 || die "missing jq; install jq"
command -v ssh >/dev/null 2>&1 || die "missing ssh; install openssh-client"
command -v flock >/dev/null 2>&1 || die "missing flock; install util-linux"
[[ -r "$base_image" ]] || die "base image not found; run $script_dir/build-image.sh first"
[[ -r "$ssh_key" ]] || die "SSH key not found; rebuild with $script_dir/build-image.sh --force"

mkdir -p "$image_dir"
exec 9>"$workspace_lock"
flock -n 9 || die "the persistent workspace is already in use"
if [[ ! -e "$workspace_image" ]]; then
  printf 'Creating sparse persistent workspace (%s)...\n' "$workspace_size"
  qemu-img create -f qcow2 "$workspace_image" "$workspace_size"
fi

[[ "$(qemu-img info --output=json "$base_image" | jq -r .format 2>/dev/null || true)" == qcow2 ]] || \
  die "base image is not a qcow2 image"
[[ "$(qemu-img info --output=json "$workspace_image" | jq -r .format 2>/dev/null || true)" == qcow2 ]] || \
  die "workspace image is not a qcow2 image"

runtime_dir="$(mktemp -d -t arch-agent-vm.XXXXXXXX)"
overlay_image="$runtime_dir/os-overlay.qcow2"
pid_file="$runtime_dir/qemu.pid"
serial_log="$runtime_dir/serial.log"
known_hosts="$runtime_dir/known_hosts"
qemu_pid=""
ssh_ready=false
cleanup_started=false

ssh_common_options=(
  -i "$ssh_key"
  -o BatchMode=yes
  -o IdentitiesOnly=yes
  -o StrictHostKeyChecking=accept-new
  -o "UserKnownHostsFile=$known_hosts"
)
ssh_options=(-p "$ssh_port" "${ssh_common_options[@]}")

process_is_running() {
  [[ -n "$qemu_pid" ]] && kill -0 "$qemu_pid" 2>/dev/null
}

wait_for_qemu_exit() {
  local attempts="$1"
  local attempt
  for (( attempt = 0; attempt < attempts; attempt++ )); do
    process_is_running || return 0
    sleep 0.2
  done
  return 1
}

cleanup() {
  local status="${1:-$?}"
  [[ "$cleanup_started" == false ]] || return
  cleanup_started=true
  trap - EXIT HUP INT TERM

  if process_is_running; then
    printf '\nStopping the disposable VM...\n'

    # Prefer a clean guest shutdown so the persistent ext4 workspace unmounts.
    if [[ "$ssh_ready" == true ]]; then
      ssh "${ssh_options[@]}" \
        -o ConnectTimeout=2 \
        agent@127.0.0.1 \
        'sudo systemctl poweroff' </dev/null >/dev/null 2>&1 || true
    fi

    if ! wait_for_qemu_exit 50; then
      printf 'Guest did not power off in time; stopping QEMU.\n' >&2
      kill -TERM "$qemu_pid" 2>/dev/null || true
      wait_for_qemu_exit 25 || kill -KILL "$qemu_pid" 2>/dev/null || true
    fi
  fi

  rm -f -- "$overlay_image" "$pid_file" "$serial_log" "$known_hosts"
  rmdir -- "$runtime_dir" 2>/dev/null || true
  exit "$status"
}

trap 'cleanup $?' EXIT
trap 'cleanup 129' HUP
trap 'cleanup 130' INT
trap 'cleanup 143' TERM

qemu-img create \
  -f qcow2 \
  -F qcow2 \
  -b "$base_image" \
  "$overlay_image"

acceleration=(-machine accel=tcg)
if [[ -r /dev/kvm && -w /dev/kvm ]]; then
  acceleration=(-enable-kvm -cpu host)
fi

printf 'Starting a disposable Arch OS with persistent workspace.\n'
printf 'Mode: %s\nWorkspace: %s\nSSH: 127.0.0.1:%s\n' "$mode" "$workspace_image" "$ssh_port"

qemu-system-x86_64 \
  "${acceleration[@]}" \
  -name "arch-agent-$mode" \
  -smbios "type=1,product=arch-agent-$display_mode-$mode" \
  -m "${ARCH_AGENT_MEMORY:-8192}" \
  -smp "${ARCH_AGENT_CPUS:-4}" \
  "${display[@]}" \
  -daemonize \
  -pidfile "$pid_file" \
  -serial "file:$serial_log" \
  -nic "user,model=virtio-net-pci,hostfwd=tcp:127.0.0.1:$ssh_port-:22" \
  -drive "if=none,id=os,file=$overlay_image,format=qcow2,discard=unmap" \
  -device virtio-blk-pci,drive=os,serial=AI_OS \
  -drive "if=none,id=workspace,file=$workspace_image,format=qcow2,cache=writeback" \
  -device virtio-blk-pci,drive=workspace,serial=AI_WORKSPACE

qemu_pid="$(<"$pid_file")"

printf 'Waiting for SSH'
for (( attempt = 1; attempt <= 120; attempt++ )); do
  if ssh "${ssh_options[@]}" \
      -o ConnectTimeout=1 \
      agent@127.0.0.1 \
      true </dev/null >/dev/null 2>&1; then
    ssh_ready=true
    break
  fi

  if ! process_is_running; then
    printf '\n'
    tail -n 40 "$serial_log" >&2 || true
    die "QEMU stopped before SSH became ready"
  fi

  printf '.'
  sleep 0.5
done
printf '\n'

if [[ "$ssh_ready" != true ]]; then
  tail -n 40 "$serial_log" >&2 || true
  die "timed out waiting for SSH on port $ssh_port"
fi

printf 'Connected. Leaving SSH will stop the VM and discard its OS overlay.\n\n'
set +e
ssh -tt "${ssh_options[@]}" \
  agent@127.0.0.1 \
  env "PATH=/home/agent/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/bin" \
  /usr/local/bin/ssh-agent-session "$mode"
ssh_status=$?
set -e

cleanup "$ssh_status"
