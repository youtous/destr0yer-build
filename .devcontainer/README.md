# Arch + Claude Code — Isolated Dev Container

A VSCodium-compatible dev container using Arch Linux, Podman, fish shell, asdf, and Claude Code — fully isolated from the host system.

## Requirements

- [VSCodium](https://vscodium.com/) with extension `jeanp413.open-remote-ssh` (Open VSX)
- [Podman](https://podman.io/) (rootless): `sudo pacman -S podman podman-docker`
- SSH key pair (see below)

## File structure

```
.devcontainer/
├── Containerfile
README.md
```

## 1. Generate a dedicated SSH key

Generate a key pair specifically for this container — keep it separate from your personal keys:

```bash
ssh-keygen -t ed25519 -f ~/.ssh/claude_container -C "arch-claude-container" -N ""
```

This creates:
- `~/.ssh/claude_container` — private key (stays on your host)
- `~/.ssh/claude_container.pub` — public key (injected into the container)

## 2. Build

```bash
podman build \
  --build-arg SSH_PUBLIC_KEY="$(cat ~/.ssh/claude_container.pub)" \
  -t arch-claude \
  .devcontainer/
```

## 3. Run

```bash
podman run -d --name arch-claude \
  --userns=keep-id \
  -p 127.0.0.1:2222:2222 \
  -v "$PWD":/workspace:z \
  arch-claude
```

## 4. SSH config

Add to `~/.ssh/config`:

```
Host arch-claude
  HostName 127.0.0.1
  Port 2222
  User vscode
  IdentityFile ~/.ssh/claude_container
  StrictHostKeyChecking no
  RemoteCommand cd /workspace && exec fish
  RequestTTY yes
```

## 5. Connect with VSCodium

1. Install `jeanp413.open-remote-ssh` from the Open VSX marketplace
2. `Ctrl+Shift+P` → `Remote-SSH: Connect to Host...`
3. Select `arch-claude`
4. VSCodium opens `/workspace` inside the container

Claude Code is available immediately in the integrated terminal:

```fish
claude
```

## Add tools via asdf

```fish
asdf plugin add python
asdf install python latest
asdf set --home python latest
```

Pin versions per project with `.tool-versions` at the repo root:

```
nodejs lts
python 3.13.0
```

## Stop / restart

```bash
podman stop arch-claude
podman start arch-claude
```

## Why this setup

| Concern | Solution |
|---|---|
| Claude Code runs as current user | Non-root `vscode` user inside container |
| npm global permission errors | asdf manages Node.js in `~/.asdf` |
| `docker` binary not found | `podman-docker` shim provides `/usr/bin/docker` |
| Proprietary MS extensions | `open-remote-ssh` is fully open-source (Open VSX) |
| File permission mismatches with Podman | `--userns=keep-id` maps host UID to container UID |
| Shared SSH key risk | Dedicated key pair scoped to this container only |
