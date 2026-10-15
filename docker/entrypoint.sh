#!/usr/bin/env bash
# Container entrypoint: keeps the VM image up to date and runs the disposable
# VM in the foreground until the container is stopped.
set -Eeuo pipefail

app_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/vm.sh
source "$app_dir/lib/vm.sh"

ssh_port=2222
# QEMU forwards SSH from loopback only; see run_vm.
qemu_ssh_port=2221
runtime_dir="${ARCH_AGENT_RUNTIME_DIR:-/data/run}"
build_stamp="$vm_base_image.inputs"
qemu_pid=""
relay_pid=""

usage() {
  cat <<'EOF'
usage: entrypoint.sh [run | build [--force] | wipe [--force] | --help]

  run     build the VM image if it is missing or outdated, then run the VM (default)
  build   build the VM image
  wipe    permanently delete the persistent workspace
EOF
}

# Everything that determines the contents of the VM image.
build_inputs() {
  local guest_files
  printf 'system_size=%s\n' "${ARCH_AGENT_SYSTEM_SIZE:-40G}"
  mapfile -t guest_files < <(cd "$app_dir" && find guest -type f | LC_ALL=C sort)
  (cd "$app_dir" && sha256sum \
    build-image.sh cloud-init/user-data cloud-init/meta-data config/persist-home.conf \
    "${guest_files[@]}")
}

build_image() {
  local build_pid
  local status=0

  # Run the build in the background so a container stop interrupts it
  # immediately; signal the whole process group to stop QEMU as well.
  "$app_dir/build-image.sh" "$@" &
  build_pid=$!
  trap 'trap - TERM INT; kill -TERM 0 2>/dev/null || true' TERM INT
  wait "$build_pid" || status=$?
  while kill -0 "$build_pid" 2>/dev/null; do
    wait "$build_pid" || status=$?
  done
  trap - TERM INT
  (( status == 0 )) || exit "$status"

  build_inputs >"$build_stamp"
}

ensure_base_image() {
  if [[ -r "$vm_base_image" &&
        "$(build_inputs)" == "$(cat -- "$build_stamp" 2>/dev/null || true)" ]]; then
    return
  fi

  if [[ -e "$vm_base_image" ]]; then
    printf 'The VM image is out of date; rebuilding it...\n'
    build_image --force
  else
    printf 'Building the VM image. The first start takes several minutes...\n'
    build_image
  fi
}

qmp() {
  printf '{"execute":"qmp_capabilities"}\n{"execute":"%s"}\n' "$1" | \
    timeout 5s socat - "UNIX-CONNECT:$runtime_dir/qmp.sock" >/dev/null 2>&1 || true
}

stop_vm() {
  trap - TERM INT
  printf 'Stopping the VM...\n'

  # Prefer a clean guest shutdown so the persistent ext4 workspace unmounts.
  qmp system_powerdown
  vm_set_ssh_options "$qemu_ssh_port" /dev/null
  timeout --kill-after=2s 5s ssh "${vm_ssh_options[@]}" \
    -o ConnectTimeout=2 -o LogLevel=ERROR \
    agent@127.0.0.1 \
    'sudo systemctl poweroff' </dev/null >/dev/null 2>&1 || true

  local deadline=$(( SECONDS + ${ARCH_AGENT_SHUTDOWN_TIMEOUT:-45} ))
  while kill -0 "$qemu_pid" 2>/dev/null && (( SECONDS < deadline )); do
    sleep 0.5
  done
  if kill -0 "$qemu_pid" 2>/dev/null; then
    printf 'Guest did not power off in time; stopping QEMU.\n' >&2
    kill -TERM "$qemu_pid" 2>/dev/null || true
    sleep 5
    kill -KILL "$qemu_pid" 2>/dev/null || true
  fi
}

run_vm() {
  local overlay_image="$runtime_dir/os-overlay.qcow2"
  local authorized_keys
  local status=0

  [[ -n "${ARCH_AGENT_AUTHORIZED_KEYS:-}" ]] || \
    die "set ARCH_AGENT_AUTHORIZED_KEYS to the SSH public keys allowed to log in"
  ssh-keygen -l -f <(printf '%s\n' "$ARCH_AGENT_AUTHORIZED_KEYS") >/dev/null 2>&1 || \
    die "ARCH_AGENT_AUTHORIZED_KEYS does not contain valid SSH public keys"
  authorized_keys="$(printf '%s\n' "$ARCH_AGENT_AUTHORIZED_KEYS" | base64 -w 0)"

  vm_lock_workspace "the persistent workspace is already in use"
  ensure_base_image
  [[ -r "$vm_ssh_key" ]] || die "SSH key not found; rebuild with: build --force"
  vm_ensure_workspace "${ARCH_AGENT_WORKSPACE_SIZE:-64G}"
  vm_check_qcow2 "$vm_base_image" "base image"
  vm_check_qcow2 "$vm_workspace_image" "workspace image"

  # The workspace lock guarantees no other VM uses this runtime directory.
  rm -rf -- "$runtime_dir"
  mkdir -p -- "$runtime_dir"
  vm_create_overlay "$overlay_image"

  printf 'Starting a disposable Arch OS with persistent workspace.\n'
  printf 'SSH: container port %s\n' "$ssh_port"

  # QMP stays on a Unix socket: the guest can reach the container's loopback.
  vm_set_qemu_args none "$overlay_image" 127.0.0.1 "$qemu_ssh_port"
  qemu-system-x86_64 \
    "${vm_qemu_args[@]}" \
    -display none \
    -monitor none \
    -qmp "unix:$runtime_dir/qmp.sock,server=on,wait=off" \
    -serial file:/dev/stdout \
    -smbios "type=11,value=io.systemd.credential.binary:arch-agent.authorized_keys=$authorized_keys" &
  qemu_pid=$!
  trap stop_vm TERM INT

  # QEMU passes non-loopback client addresses through to the guest, where
  # they can collide with guest subnets such as Docker's 172.17.0.0/16 and
  # replies never leave the VM. Relaying through loopback makes every client
  # appear as the QEMU gateway, 10.0.2.2.
  socat "TCP-LISTEN:$ssh_port,fork,reuseaddr" "TCP:127.0.0.1:$qemu_ssh_port" &
  relay_pid=$!

  wait "$qemu_pid" || status=$?
  while kill -0 "$qemu_pid" 2>/dev/null; do
    wait "$qemu_pid" || status=$?
  done

  kill -TERM "$relay_pid" 2>/dev/null || true
  rm -rf -- "$runtime_dir"
  exit "$status"
}

command="${1:-run}"
(( $# == 0 )) || shift
case "$command" in
  run)
    (( $# == 0 )) || die "run takes no arguments"
    run_vm
    ;;
  build)
    build_image "$@"
    ;;
  wipe)
    exec "$app_dir/wipe-workspace.sh" "$@"
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
