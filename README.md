# Disposable Arch Agent VM

A fresh Arch Linux operating system on every boot, with a persistent workspace
disk. The VM starts headlessly, mounts the workspace at `/workspace`, and opens
Codex, Claude Code, or a regular shell through SSH in the host terminal.

The operating-system overlay is deleted when QEMU exits. Projects and agent
login state survive in `images/workspace.qcow2`.

## Host requirements

- `qemu-system-x86_64` and `qemu-img`
- `ssh` and `ssh-keygen` from OpenSSH
- `cloud-localds` from `cloud-image-utils` (only while building)
- `curl`, `sha256sum`, and `jq`
- KVM access is optional but strongly recommended

On Arch Linux:

```console
sudo pacman -S qemu-desktop cloud-image-utils curl jq
```

On Debian or Ubuntu:

```console
sudo apt install qemu-system-x86 qemu-utils cloud-image-utils curl jq
```

## Build once

The builder downloads Arch's official cloud image, verifies its published
SHA-256 checksum, installs development tools plus both agents, then saves the
prepared immutable base image.

Codex is installed from its npm package, with Bubblewrap available for its
sandbox. Claude Code uses Anthropic's recommended native Linux installer.

```console
./build-image.sh
```

Building needs network access and several minutes. Use `./build-image.sh
--force` to replace an existing prepared image.

Only one image build can run at a time. A second builder exits before changing
logs or image artifacts.

Every build saves the builder output and the VM's serial/cloud-init console in
`logs/`. The most recent log is always available at:

```console
less logs/latest-build.log
```

To watch it from a second terminal while building:

```console
tail -f logs/latest-build.log
```

For shell command tracing in addition to the normal console output:

```console
ARCH_AGENT_TRACE=1 ./build-image.sh
```

The builder only accepts the image after cloud-init emits an explicit success
marker. Interrupting or closing QEMU cannot promote a partially provisioned
disk to the reusable base image.

## Run

```console
./run.sh codex
./run.sh claude
./run.sh shell
```

To expose a TCP service from the VM through the SSH session on the same
localhost port, pass `--forward`. For example, this makes guest port 8080
available at `http://127.0.0.1:8080` on the host:

```console
./run.sh --forward 8080 codex
```

The guest service can listen on `127.0.0.1:8080` or `0.0.0.0:8080`. The host
listener is restricted to `127.0.0.1`, so it is not exposed to the local
network. Repeat the option to forward multiple ports:

```console
./run.sh --forward 3000 --forward 8080 codex
```

To let Git inside the VM clone and push over SSH, forward one dedicated key
from the host:

```console
./run.sh --git-ssh-key ~/.ssh/agent-github codex
```

The matching public key must be registered with the Git host. `run.sh` starts
a temporary, isolated `ssh-agent`, loads only the selected private key, and
forwards that agent to the VM for the interactive session. The private key is
never copied to the VM or the workspace disk. If the key is encrypted,
`ssh-add` asks for its passphrase before the VM starts.

VM SSH connections ignore host SSH configuration and connection sharing.
Agent forwarding is disabled except for the interactive session when
`--git-ssh-key` is supplied; readiness and shutdown connections never forward it.

On the first connection to a Git host, SSH may ask you to confirm its host key.
Set the persistent commit identity once inside the VM:

```console
git config --global user.name "Your Name"
git config --global user.email "you@example.com"
```

The resulting `.gitconfig` is stored on the persistent workspace. You can
inspect the forwarded identity and test GitHub access from the VM with:

```console
ssh-add -l
ssh -T git@github.com
```

On the first Claude or Codex launch, authenticate inside the VM. The resulting
agent state is stored on the persistent workspace and reused on later boots.

Home-directory persistence is configured in `config/persist-home.conf`. Each
entry declares a `dir`, `file`, or `json`, followed by its path relative to
`/home/agent` and its storage path relative to `/workspace`. Changes take
effect after rebuilding the base image. SSH `known_hosts` entries persist by
default, while private keys and other SSH state remain ephemeral. Persisting
the entire `.ssh` directory is included as a commented opt-in example.

The image build creates a dedicated SSH key. The first run creates a sparse
64 GB workspace disk, which consumes space only as data is written. Override
defaults with environment variables:

```console
ARCH_AGENT_WORKSPACE_SIZE=100G ./run.sh shell
ARCH_AGENT_MEMORY=16384 ARCH_AGENT_CPUS=8 ./run.sh codex
ARCH_AGENT_SSH_PORT=2223 ./run.sh claude
```

The workspace size variable only applies when the disk is first created.

To permanently wipe all projects, agent logins, and other persisted home state:

```console
./wipe-workspace.sh
```

The command refuses to run while the VM is using the workspace and asks for
confirmation. For non-interactive use, pass `--force`.

Leaving SSH—for example with `exit`, `Ctrl+D`, a lost connection, or closing
the host terminal—makes `run.sh` request a clean guest poweroff. If that times
out, it terminates QEMU as a fallback. In both cases it deletes the disposable
OS overlay and keeps the workspace disk.

For a troubleshooting console, retain the SSH session while also opening the
minimal Cage/Foot display:

```console
ARCH_AGENT_DISPLAY=gtk ./run.sh shell
```

## Persistence and security

- `/workspace/projects` contains persistent work.
- `/workspace/.agent-state` contains persistent Codex and Claude login state.
- Selected home paths such as GitHub CLI state, `.gitconfig`, shell history,
  and SSH `known_hosts` are declared in `config/persist-home.conf`.
- Everything else is discarded after shutdown.
- No host directory is shared with the VM.
- Ports passed with `--forward` are carried through SSH and reachable only
  through the host's loopback interface for the lifetime of the VM session.
- A key passed with `--git-ssh-key` remains on the host, but the VM can request
  signatures from it until the session ends. Prefer a dedicated, narrowly
  authorized Git key rather than forwarding a general-purpose identity.
- The agents launch with permission checks disabled. Only place data on the
  workspace disk that the agents are allowed to modify or delete.

To reset only the OS, close the VM and start it again. Use
`./wipe-workspace.sh` to reset the workspace; the next run creates a new blank
disk.
