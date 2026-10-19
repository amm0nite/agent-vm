# Disposable Arch Agent VM

A fresh Arch Linux VM on every boot, with a persistent workspace for projects
and agent logins. Connect through SSH and start Codex, Claude Code, OpenCode,
or Pi. Development tools, Docker, and Docker Compose are included.

Run it from your terminal or as a [Docker Compose service](#docker-compose-mode).

## Quick start

Install the host dependencies. KVM access is optional but strongly recommended
for performance.

On Arch Linux:

```console
sudo pacman -S qemu-desktop cloud-image-utils openssh curl jq
```

On Debian or Ubuntu:

```console
sudo apt install qemu-system-x86 qemu-utils cloud-image-utils openssh-client curl jq
```

Build the base image, then start a session:

```console
./build-image.sh
./run.sh
```

The build downloads and verifies Arch's official cloud image and installs the
included tools. It needs network access and takes several minutes.

The VM opens a Bash shell in `/workspace/projects`, with completion, persistent
history, and a Starship prompt. Start your preferred agent:

| Agent | Command |
|---|---|
| Codex | `codex --yolo` |
| Claude Code | `claude --dangerously-skip-permissions` |
| OpenCode | `opencode` |
| Pi | `pi` |

Authenticate inside the VM on first use (`/connect` in OpenCode, `/login` in Pi).
Credentials and sessions persist across boots.

Exit the shell or close the terminal to stop the VM. Its OS changes are discarded;
projects and saved agent state remain on the workspace disk.

## Daily use

### Access a development server

Forward guest ports to the same ports on the host:

```console
./run.sh --forward 3000 --forward 8080
```

For example, guest port 8080 becomes available at `http://127.0.0.1:8080`.
The service can listen on `127.0.0.1` or `0.0.0.0` inside the VM. Forwarded ports
are accessible only from the host and close when the session ends.

### Use Git over SSH

Forward a dedicated Git key from the host:

```console
./run.sh --git-ssh-key ~/.ssh/agent-github
```

Register the matching public key with your Git host first. If the key is
encrypted, you will be prompted for its passphrase. Only this key is forwarded;
the private key stays on the host. The VM can use it for authentication while
the session is open, so choose a key with appropriately limited access.

Set your commit identity once inside the VM:

```console
git config --global user.name "Your Name"
git config --global user.email "you@example.com"
```

These settings persist. To check forwarding and GitHub access, run `ssh-add -l`
and `ssh -T git@github.com` inside the VM.

### Adjust resources

| Environment variable | Default | Purpose |
|---|---|---|
| `ARCH_AGENT_MEMORY` | `8192` | VM memory in MiB |
| `ARCH_AGENT_CPUS` | `4` | Virtual CPUs |
| `ARCH_AGENT_SSH_PORT` | `2222` | Host SSH port |
| `ARCH_AGENT_SYSTEM_SIZE` | `40G` | OS disk size when building |
| `ARCH_AGENT_WORKSPACE_SIZE` | `64G` | Workspace size when first created |

For example:

```console
ARCH_AGENT_MEMORY=16384 ARCH_AGENT_CPUS=8 ./run.sh
```

Both disks are sparse: their configured sizes are capacity limits, not space
reserved on the host. Changing the workspace size setting does not resize an
existing disk.

### Update or reset

Rebuild to update the included tools, then start a new session:

```console
./build-image.sh --force
./run.sh
```

Rebuilding keeps the workspace. To reset only the OS, simply stop and restart
the VM.

To permanently delete all projects, agent logins, and other saved state:

```console
./wipe-workspace.sh
```

This asks for confirmation and refuses to run while the workspace is in use.
Pass `--force` for non-interactive use.

## Persistent data

The workspace disk is stored in `images/workspace.qcow2`.

| Guest location | Contents |
|---|---|
| `/workspace/projects` | Your projects |
| `/workspace/.agent-state` | Codex, Claude Code, OpenCode, and Pi credentials, settings, and sessions |
| `/workspace/.home-state` | Selected home files, including GitHub CLI state, Git identity, shell history, and SSH known hosts |

Edit [config/persist-home.conf](config/persist-home.conf) and rebuild to change
which home paths persist. SSH private keys are not persisted by default; the
config includes an example for opting in to the entire `.ssh` directory.

Everything outside the workspace is disposable, including tools installed
during a session and Docker images, containers, and volumes. Docker works
without sudo; bind mount directories under `/workspace` for persistent data.
No host directory is shared with the VM.

The suggested Codex and Claude Code commands disable permission checks;
OpenCode uses its default permissions, and Pi does not ask before every tool
call. Keep only data the agents may modify or delete on the workspace disk.

## Docker Compose mode

Run the VM as a service that stays up until the container stops. Copy
[docker/compose.example.yaml](docker/compose.example.yaml) into your stack and set:

- `KVM_GID`: the host's KVM group ID (`getent group kvm | cut -d: -f3`).
- `ARCH_AGENT_AUTHORIZED_KEYS`: SSH public keys allowed to log in as `agent`,
  one per line. Restart the container after changing them.

The example uses `ghcr.io/amm0nite/agent-vm:latest`; `sha-<commit>` tags are also
published. The first start builds the VM image in the data volume and takes
several minutes. Updated container images automatically rebuild the VM image
when provisioning files change.

Memory, CPU, and disk-size settings use the same variables as above. Container
shutdown allows 45 seconds by default, configurable with
`ARCH_AGENT_SHUTDOWN_TIMEOUT`. Keep Compose's `stop_grace_period` longer than
this timeout.

Run these commands from your stack's directory:

| Operation | Command |
|---|---|
| Start | `docker compose up -d agent-vm` |
| Connect | `ssh -p 2222 agent@127.0.0.1` |
| Update | `docker compose pull agent-vm && docker compose up -d agent-vm` |
| Rebuild the VM image | `docker compose run --rm agent-vm build --force` |
| View logs | `docker compose logs -f agent-vm` |
| Reset the OS | `docker compose restart agent-vm` |
| Wipe the workspace | Stop the service, then `docker compose run --rm agent-vm wipe --force` |

Disconnecting leaves the VM running. To keep an agent session running too,
connect with tmux:

```console
ssh -p 2222 agent@127.0.0.1 -t tmux new -A -s agent
```

Detach with `Ctrl+B D` and use the same command to reconnect. Add `-A` to forward
your SSH agent, or `-L 8080:127.0.0.1:8080` to reach a guest service. After
reconnecting with agent forwarding, open a new tmux window so its shell uses
the new connection's agent.

The container needs access to `/dev/kvm`, but requires no privileged mode,
Docker socket, or host directory mounts. Persistent data lives in the `/data`
volume. The example uses a separate network to isolate it from other services
in the stack.

## Troubleshooting

Build logs are saved in `logs/`. To watch the latest build:

```console
tail -f logs/latest-build.log
```

Use `ARCH_AGENT_TRACE=1 ./build-image.sh --force` for detailed shell tracing.
Failed or interrupted builds do not replace the base image.

Failed runs and forced shutdowns retain a VM console log and print its path,
normally `logs/run-XXXXXXXX.log`.

To open a graphical troubleshooting console alongside SSH:

```console
ARCH_AGENT_DISPLAY=gtk ./run.sh
```
