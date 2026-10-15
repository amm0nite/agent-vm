#!/usr/bin/env bash
# Healthy once the guest accepts SSH and its persistent workspace is mounted.
set -Eeuo pipefail

# shellcheck source=../lib/vm.sh
source /opt/agent-vm/lib/vm.sh

vm_set_ssh_options 2222 /dev/null
timeout --kill-after=2s 10s ssh "${vm_ssh_options[@]}" \
  -o ConnectTimeout=3 -o LogLevel=ERROR \
  agent@127.0.0.1 \
  'systemctl is-active --quiet prepare-workspace.service && mountpoint -q /workspace' \
  </dev/null
