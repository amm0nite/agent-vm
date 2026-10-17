# Disposable Arch Agent VM

A fresh Arch Linux operating system on every boot, with a persistent workspace
disk. The VM starts headlessly, mounts the workspace at `/workspace`, and opens
a shell through SSH in the host terminal, from which you start Codex or
Claude Code, OpenCode, or Pi.

The operating-system overlay is deleted when QEMU exits. Projects and agent
login state survive in `images/workspace.qcow2`.

The same VM can also run as a long-lived service in a Docker Compose stack;
see [Docker Compose mode](#docker-compose-mode).

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
SHA-256 checksum, installs development tools plus all four agents, then saves the
prepared immutable base image.

OpenCode is installed from Arch's official `opencode` package. Claude Code uses
Anthropic's recommended native Linux installer. Codex uses the official
`@openai/codex` npm package, with Bubblewrap available for its sandbox. This keeps
Codex binaries on the disposable OS disk; its standalone installer places them
under `~/.codex`, which this VM replaces with persistent agent state at boot.

Pi uses its official `@earendil-works/pi-coding-agent` npm package with
`--ignore-scripts`, as documented in the [Pi quickstart](https://pi.dev/docs/latest/quickstart).
This reuses the image's Node.js and npm installation and keeps Pi binaries under
`~/.local` on the disposable OS disk. Pi requires Node.js 22.19 or newer.
Its credentials, settings, sessions, and installed Pi packages under `~/.pi/agent`
are stored on the persistent workspace.

Docker and Docker Compose are installed, and Docker starts automatically on
boot. The `agent` user belongs to the `docker` group, so `docker`,
`docker compose`, and `docker-compose` work without sudo. Docker images,
containers, and volumes use the disposable OS disk and are discarded after
shutdown; bind mount project directories under `/workspace` for persistent data.

```console
./build-image.sh
```

Building needs network access and several minutes. Use `./build-image.sh
--force` to replace an existing prepared image.

The system disk defaults to a sparse 40 GB image, leaving room for larger
development toolchains such as the Android SDK. Override its virtual size when
building with `ARCH_AGENT_SYSTEM_SIZE`:

```console
ARCH_AGENT_SYSTEM_SIZE=64G ./build-image.sh --force
```

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
./run.sh
```

The shell starts in `/workspace/projects`. Start an agent from it with
`codex --yolo`, `claude --dangerously-skip-permissions`, `opencode`, or `pi`.

For an existing base image, run `./build-image.sh --force` to install newly added
tools such as Pi, then start a new VM session. The workspace disk is kept.

To expose a TCP service from the VM through the SSH session on the same
localhost port, pass `--forward`. For example, this makes guest port 8080
available at `http://127.0.0.1:8080` on the host:

```console
./run.sh --forward 8080
```

The guest service can listen on `127.0.0.1:8080` or `0.0.0.0:8080`. The host
listener is restricted to `127.0.0.1`, so it is not exposed to the local
network. Repeat the option to forward multiple ports:

```console
./run.sh --forward 3000 --forward 8080
```

To let Git inside the VM clone and push over SSH, forward one dedicated key
from the host:

```console
./run.sh --git-ssh-key ~/.ssh/agent-github
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

On the first Claude, Codex, OpenCode, or Pi launch, authenticate inside the VM
(use `/connect` in OpenCode or `/login` in Pi). The resulting
agent state is stored on the persistent workspace and reused on later boots.
OpenCode's global configuration (`~/.config/opencode`) and application data
(`~/.local/share/opencode`, including credentials and sessions) persist as well.

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
ARCH_AGENT_WORKSPACE_SIZE=100G ./run.sh
ARCH_AGENT_MEMORY=16384 ARCH_AGENT_CPUS=8 ./run.sh
ARCH_AGENT_SSH_PORT=2223 ./run.sh
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
OS overlay and keeps the workspace disk. Unused workspace blocks are returned
to the host at session startup and during clean shutdown, keeping the sparse
workspace image from retaining space previously occupied by deleted files.

Sessions start only after workspace preparation succeeds and `/workspace` is
mounted. The shutdown SSH command has a five-second timeout (with forced
termination after another two seconds), followed by the QEMU shutdown fallback.
SSH liveness checks also detect an unresponsive connection.

On a failed run or forced shutdown, the full VM serial log is saved as
`logs/run-XXXXXXXX.log`, and its path is printed. If archiving fails, the log
is kept in the temporary runtime directory instead.

For a troubleshooting console, retain the SSH session while also opening the
minimal Cage/Foot display:

```console
ARCH_AGENT_DISPLAY=gtk ./run.sh
```

## Docker Compose mode

The VM can also run as a service in an existing Compose stack. The container
boots the same image, built from the same `cloud-init/` and
`config/persist-home.conf`, and runs until the container stops. Connect over
SSH to get a shell and start an agent.

CI publishes the container image to `ghcr.io/amm0nite/agent-vm` on every
push to `main` that changes the image inputs, tagged `latest` and
`sha-<commit>`. The VM image itself is not part of the container image: it is
built into the data volume on first start, which takes several minutes. When a
newer container image contains different provisioning files, the VM image is
rebuilt automatically on the next start.

Copy the service from [`docker/compose.example.yaml`](docker/compose.example.yaml)
into the stack and set:

- `KVM_GID`: the host's `kvm` group ID (`getent group kvm | cut -d: -f3`).
- `ARCH_AGENT_AUTHORIZED_KEYS`: one or more SSH public keys, one per line,
  allowed to log in as `agent`. Changing them only needs a container restart.

`ARCH_AGENT_MEMORY`, `ARCH_AGENT_CPUS`, `ARCH_AGENT_WORKSPACE_SIZE`,
`ARCH_AGENT_SYSTEM_SIZE`, and `ARCH_AGENT_SHUTDOWN_TIMEOUT` (default 45
seconds) work as in host mode. Keep `stop_grace_period` longer than the
shutdown timeout.

From the stack's directory:

| Operation | Command |
|---|---|
| Start | `docker compose up -d agent-vm` |
| Connect | `ssh -p 2222 agent@127.0.0.1` |
| Update | `docker compose pull agent-vm && docker compose up -d agent-vm` |
| Rebuild the VM image | `docker compose run --rm agent-vm build --force` |
| Logs (build and VM console) | `docker compose logs -f agent-vm` |
| Reset the OS | `docker compose restart agent-vm` |
| Wipe the workspace | Stop the service, then `docker compose run --rm agent-vm wipe --force` |

Unlike host mode, disconnecting does not stop the VM, but it does end the
processes of that SSH session. To keep an agent running between connections,
start it inside `tmux` (`tmux new -A -s agent`), detach with `Ctrl+B D`, and
reattach later with `ssh -p 2222 agent@127.0.0.1 -t tmux new -A -s agent`.
Add `-A` to the SSH command to let Git use your forwarded agent, or `-L` to
reach guest ports. After reattaching to `tmux` over a new connection, shells
that were already open still point to the previous connection's agent; open a
new window, or run `eval "$(tmux show-environment -s SSH_AUTH_SOCK)"` in the
shell, to use the new one.

The container needs `/dev/kvm` but no privileges, Docker socket, or host
directories. Everything persistent lives in the `/data` volume. The example
puts the service on its own network so the VM cannot resolve or reach the
rest of the stack by service name.

## Persistence and security

- `/workspace/projects` contains persistent work.
- `/workspace/.agent-state` contains persistent Codex, Claude, OpenCode, and Pi state.
- Selected home paths such as GitHub CLI state, `.gitconfig`, shell history,
  and SSH `known_hosts` are declared in `config/persist-home.conf`.
- Everything else is discarded after shutdown.
- No host directory is shared with the VM.
- Ports passed with `--forward` are carried through SSH and reachable only
  through the host's loopback interface for the lifetime of the VM session.
- A key passed with `--git-ssh-key` remains on the host, but the VM can request
  signatures from it until the session ends. Prefer a dedicated, narrowly
  authorized Git key rather than forwarding a general-purpose identity.
- The suggested Codex and Claude commands disable permission checks; OpenCode
  uses its default permissions, and Pi does not ask before every tool call. Only place data on the
  workspace disk that the agents are allowed to modify or delete.

To reset only the OS, close the VM and start it again. Use
`./wipe-workspace.sh` to reset the workspace; the next run creates a new blank
disk.
