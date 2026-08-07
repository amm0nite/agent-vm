#!/usr/bin/env bash
set -Eeuo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
image_dir="$script_dir/images"
workspace_image="$image_dir/workspace.qcow2"
workspace_lock="$image_dir/workspace.lock"

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

force=false
case "${1:-}" in
  "") ;;
  --force) force=true ;;
  *) die "usage: $0 [--force]" ;;
esac

command -v flock >/dev/null 2>&1 || die "missing flock; install util-linux"
mkdir -p "$image_dir"
exec 9>"$workspace_lock"
flock -n 9 || die "the VM is running or the persistent workspace is otherwise in use"

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
