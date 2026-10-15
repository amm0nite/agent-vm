# Shared helpers for building and starting the agent VM.
# Sourced by build-image.sh, run.sh, wipe-workspace.sh, and the Docker entrypoint.

vm_repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
vm_image_dir="${ARCH_AGENT_IMAGE_DIR:-$vm_repo_dir/images}"
vm_log_dir="${ARCH_AGENT_LOG_DIR:-$vm_repo_dir/logs}"
vm_base_image="$vm_image_dir/arch-agent-base.qcow2"
vm_workspace_image="$vm_image_dir/workspace.qcow2"
vm_workspace_lock="$vm_image_dir/workspace.lock"
vm_ssh_key="$vm_image_dir/agent-ssh-key"

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

vm_require_command() {
  command -v "$1" >/dev/null 2>&1 || die "missing $1; $2"
}

vm_is_port() {
  [[ "$1" =~ ^(0|[1-9][0-9]*)$ ]] && (( $1 >= 1 && $1 <= 65535 ))
}

# Hold the workspace lock on file descriptor 9 until the process exits.
vm_lock_workspace() {
  mkdir -p "$vm_image_dir"
  exec 9>"$vm_workspace_lock"
  flock -n 9 || die "$1"
}

vm_ensure_workspace() {
  if [[ ! -e "$vm_workspace_image" ]]; then
    printf 'Creating sparse persistent workspace (%s)...\n' "$1"
    qemu-img create -f qcow2 "$vm_workspace_image" "$1"
  fi
}

vm_check_qcow2() {
  [[ "$(qemu-img info --output=json "$1" | jq -r .format 2>/dev/null || true)" == qcow2 ]] || \
    die "$2 is not a qcow2 image"
}

vm_create_overlay() {
  qemu-img create \
    -f qcow2 \
    -F qcow2 \
    -b "$vm_base_image" \
    "$1"
}

# Sets vm_ssh_options for non-interactive connections to the guest.
vm_set_ssh_options() {
  local port="$1"
  local known_hosts="$2"
  vm_ssh_options=(
    -p "$port"
    -F /dev/null
    -i "$vm_ssh_key"
    -o ForwardAgent=no
    -o IdentityAgent=none
    -o ControlMaster=no
    -o ControlPath=none
    -o ServerAliveInterval=15
    -o ServerAliveCountMax=3
    -o BatchMode=yes
    -o IdentitiesOnly=yes
    -o StrictHostKeyChecking=accept-new
    -o "UserKnownHostsFile=$known_hosts"
  )
}

# Sets vm_qemu_args for a VM booting the overlay and the persistent workspace.
# The display mode is exposed to the guest through the SMBIOS product name.
vm_set_qemu_args() {
  local display_mode="$1"
  local overlay="$2"
  local ssh_address="$3"
  local ssh_port="$4"
  local acceleration=(-machine accel=tcg)
  if [[ -r /dev/kvm && -w /dev/kvm ]]; then
    acceleration=(-enable-kvm -cpu host)
  fi

  vm_qemu_args=(
    "${acceleration[@]}"
    -name arch-agent
    -smbios "type=1,product=arch-agent-$display_mode"
    -m "${ARCH_AGENT_MEMORY:-8192}"
    -smp "${ARCH_AGENT_CPUS:-4}"
    -nic "user,model=virtio-net-pci,hostfwd=tcp:$ssh_address:$ssh_port-:22"
    -drive "if=none,id=os,file=$overlay,format=qcow2,discard=unmap"
    -device virtio-blk-pci,drive=os,serial=AI_OS
    -drive "if=none,id=workspace,file=$vm_workspace_image,format=qcow2,cache=writeback,discard=unmap"
    -device virtio-blk-pci,drive=workspace,serial=AI_WORKSPACE
  )
}
