#!/usr/bin/env bash
set -Eeuo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/vm.sh
source "$script_dir/lib/vm.sh"
workspace_image="$vm_workspace_image"

force=false
case "${1:-}" in
  "") ;;
  --force) force=true ;;
  *) die "usage: $0 [--force]" ;;
esac

vm_require_command flock "install util-linux"
vm_lock_workspace "the VM is running or the persistent workspace is otherwise in use"

if [[ ! -e "$workspace_image" ]]; then
  printf 'Persistent workspace is already empty.\n'
  exit 0
fi

if [[ "$force" != true ]]; then
  [[ -t 0 ]] || die "refusing to wipe without a terminal; pass --force to confirm"
  printf 'This permanently deletes all persisted projects, agent logins, and home state.\n'
  printf 'Type "wipe" to continue: '
  read -r confirmation
  [[ "$confirmation" == wipe ]] || die "wipe cancelled"
fi

rm -f -- "$workspace_image"
printf 'Persistent workspace wiped. The next run will create a blank disk.\n'
