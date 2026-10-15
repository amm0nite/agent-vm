#!/usr/bin/env bash
set -Eeuo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/vm.sh
source "$script_dir/lib/vm.sh"
workspace_size="${ARCH_AGENT_WORKSPACE_SIZE:-64G}"
ssh_port="${ARCH_AGENT_SSH_PORT:-2222}"
display_mode="${ARCH_AGENT_DISPLAY:-none}"
mode=shell
mode_set=false
git_ssh_key=""
forwarded_ports=()

usage() {
  printf 'usage: %s [--git-ssh-key PATH] [--forward PORT]... [codex|claude|shell]\n' "$0"
}

while (( $# > 0 )); do
  case "$1" in
    --git-ssh-key)
      (( $# >= 2 )) || die "--git-ssh-key requires a private key path"
      git_ssh_key="$2"
      shift 2
      ;;
    --git-ssh-key=*)
      git_ssh_key="${1#*=}"
      [[ -n "$git_ssh_key" ]] || die "--git-ssh-key requires a private key path"
      shift
      ;;
    --forward)
      (( $# >= 2 )) || die "--forward requires a TCP port"
      forwarded_ports+=("$2")
      shift 2
      ;;
    --forward=*)
      forward_port="${1#*=}"
      [[ -n "$forward_port" ]] || die "--forward requires a TCP port"
      forwarded_ports+=("$forward_port")
      shift
      ;;
    codex|claude|shell)
      [[ "$mode_set" == false ]] || die "only one startup mode may be specified"
      mode="$1"
      mode_set=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      die "unknown argument: $1"
      ;;
  esac
done

case "$display_mode" in
  none)
    display=(-display none)
    ;;
  gtk)
    display=(-display gtk,zoom-to-fit=on -device virtio-vga,edid=on,xres=1280,yres=800)
    ;;
  *) die "ARCH_AGENT_DISPLAY must be 'none' or 'gtk'" ;;
esac

vm_is_port "$ssh_port" || \
  die "ARCH_AGENT_SSH_PORT must be a port number between 1 and 65535"

for (( port_index = 0; port_index < ${#forwarded_ports[@]}; port_index++ )); do
  forward_port="${forwarded_ports[port_index]}"
  vm_is_port "$forward_port" || \
    die "--forward must be a TCP port number between 1 and 65535: $forward_port"
  [[ "$forward_port" != "$ssh_port" ]] || \
    die "--forward port $forward_port conflicts with the VM SSH port"

  for (( previous_index = 0; previous_index < port_index; previous_index++ )); do
    [[ "$forward_port" != "${forwarded_ports[previous_index]}" ]] || \
      die "--forward port $forward_port was specified more than once"
  done
done

vm_require_command qemu-img "install QEMU"
vm_require_command qemu-system-x86_64 "install QEMU"
vm_require_command jq "install jq"
vm_require_command ssh "install openssh-client"
vm_require_command flock "install util-linux"
vm_require_command timeout "install coreutils"
if [[ -n "$git_ssh_key" ]]; then
  vm_require_command ssh-agent "install openssh-client"
  vm_require_command ssh-add "install openssh-client"
  [[ -f "$git_ssh_key" && -r "$git_ssh_key" ]] || \
    die "Git SSH private key is not a readable file: $git_ssh_key"
fi
[[ -r "$vm_base_image" ]] || die "base image not found; run $script_dir/build-image.sh first"
[[ -r "$vm_ssh_key" ]] || die "SSH key not found; rebuild with $script_dir/build-image.sh --force"

vm_lock_workspace "the persistent workspace is already in use"
vm_ensure_workspace "$workspace_size"
vm_check_qcow2 "$vm_base_image" "base image"
vm_check_qcow2 "$vm_workspace_image" "workspace image"

runtime_dir="$(mktemp -d -t arch-agent-vm.XXXXXXXX)"
overlay_image="$runtime_dir/os-overlay.qcow2"
pid_file="$runtime_dir/qemu.pid"
serial_log="$runtime_dir/serial.log"
known_hosts="$runtime_dir/known_hosts"
qemu_pid=""
git_agent_pid=""
git_agent_socket=""
git_agent_log=""
ssh_ready=false
cleanup_started=false

vm_set_ssh_options "$ssh_port" "$known_hosts"
ssh_options=("${vm_ssh_options[@]}")

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
      timeout --kill-after=2s 5s ssh "${ssh_options[@]}" \
        -o ConnectTimeout=2 \
        agent@127.0.0.1 \
        'sudo systemctl poweroff' </dev/null >/dev/null 2>&1 || true
    fi

    if ! wait_for_qemu_exit 50; then
      printf 'Guest did not power off in time; stopping QEMU.\n' >&2
      (( status != 0 )) || status=1
      kill -TERM "$qemu_pid" 2>/dev/null || true
      wait_for_qemu_exit 25 || kill -KILL "$qemu_pid" 2>/dev/null || true
    fi
  fi

  if [[ -n "$git_agent_pid" ]] && kill -0 "$git_agent_pid" 2>/dev/null; then
    kill -TERM "$git_agent_pid" 2>/dev/null || true
    wait "$git_agent_pid" 2>/dev/null || true
  fi

  if (( status != 0 )) && [[ -f "$serial_log" ]]; then
    local saved_log=""
    if mkdir -p "$vm_log_dir" && \
        saved_log="$(mktemp "$vm_log_dir/run-XXXXXXXX.log")" && \
        cp -- "$serial_log" "$saved_log"; then
      printf 'VM serial log: %s\n' "$saved_log" >&2
      rm -f -- "$serial_log"
    else
      printf 'Could not archive VM serial log; retained at: %s\n' "$serial_log" >&2
    fi
  else
    rm -f -- "$serial_log"
  fi

  rm -f -- \
    "$overlay_image" "$pid_file" "$known_hosts" \
    "$git_agent_socket" "$git_agent_log"
  rmdir -- "$runtime_dir" 2>/dev/null || true
  exit "$status"
}

trap 'cleanup $?' EXIT
trap 'cleanup 129' HUP
trap 'cleanup 130' INT
trap 'cleanup 143' TERM

session_ssh_options=(-tt -o ExitOnForwardFailure=yes)
for forward_port in "${forwarded_ports[@]}"; do
  session_ssh_options+=(
    -L "127.0.0.1:$forward_port:127.0.0.1:$forward_port"
  )
done
if [[ -n "$git_ssh_key" ]]; then
  git_agent_socket="$runtime_dir/git-agent.sock"
  git_agent_log="$runtime_dir/git-agent.log"
  SSH_AUTH_SOCK="$git_agent_socket" ssh-agent -D -a "$git_agent_socket" \
    >"$git_agent_log" 2>&1 &
  git_agent_pid=$!

  for (( attempt = 1; attempt <= 50; attempt++ )); do
    [[ -S "$git_agent_socket" ]] && break
    kill -0 "$git_agent_pid" 2>/dev/null || break
    sleep 0.1
  done
  if [[ ! -S "$git_agent_socket" ]]; then
    sed -n '1,20p' "$git_agent_log" >&2 || true
    die "temporary Git SSH agent failed to start"
  fi

  printf 'Loading the Git SSH key into a temporary agent...\n'
  SSH_AUTH_SOCK="$git_agent_socket" ssh-add "$git_ssh_key" || \
    die "could not load the Git SSH private key"
  export SSH_AUTH_SOCK="$git_agent_socket"
  # Override IdentityAgent=none before the common options: -A alone cannot
  # forward an agent when SSH has disabled access to its socket.
  session_ssh_options=(-A -o "IdentityAgent=$git_agent_socket" "${session_ssh_options[@]}")
  printf 'Git SSH agent forwarding enabled for this VM session.\n'
fi

vm_create_overlay "$overlay_image"

printf 'Starting a disposable Arch OS with persistent workspace.\n'
printf 'Mode: %s\nWorkspace: %s\nSSH: 127.0.0.1:%s\n' "$mode" "$vm_workspace_image" "$ssh_port"
for forward_port in "${forwarded_ports[@]}"; do
  printf 'TCP forward: 127.0.0.1:%s -> guest:%s\n' "$forward_port" "$forward_port"
done

vm_set_qemu_args "$mode" "$display_mode" "$overlay_image" 127.0.0.1 "$ssh_port"
qemu-system-x86_64 \
  "${vm_qemu_args[@]}" \
  "${display[@]}" \
  -daemonize \
  -pidfile "$pid_file" \
  -serial "file:$serial_log"

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

if ! timeout --kill-after=2s 5s ssh "${ssh_options[@]}" \
    -o ConnectTimeout=2 agent@127.0.0.1 \
    'systemctl is-active --quiet prepare-workspace.service && mountpoint -q /workspace'; then
  die "workspace preparation failed; refusing to start a session (see the retained serial log)"
fi

# Reclaim host storage occupied by blocks deleted during earlier sessions.
# This also handles base images built before shutdown trimming was introduced.
if ! trim_output="$(ssh "${ssh_options[@]}" \
    agent@127.0.0.1 \
    'sudo fstrim --verbose /workspace' </dev/null 2>&1)"; then
  printf 'Warning: could not reclaim unused workspace storage: %s\n' "$trim_output" >&2
elif [[ -n "$trim_output" ]]; then
  printf '%s\n' "$trim_output"
fi

printf 'Connected. Leaving SSH will stop the VM and discard its OS overlay.\n\n'
set +e
ssh "${session_ssh_options[@]}" "${ssh_options[@]}" \
  agent@127.0.0.1 \
  env "PATH=/home/agent/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/bin" \
  /usr/local/bin/ssh-agent-session "$mode"
ssh_status=$?
set -e

cleanup "$ssh_status"
