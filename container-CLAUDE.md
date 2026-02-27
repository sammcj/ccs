# Sandboxed Container Environment

You are running inside an isolated Apple container VM (not Docker). The host is macOS but this environment is Debian Linux (debian:bookworm-slim). You are running as the `claude` user, not root.

## Filesystem

- `/workspace` -- the host project directory, mounted read-write. This is your working directory. All code changes go here.
- `~/.claude/` -- persistent config directory mounted from the host (`~/.ccs/`). Auth, settings, skills, and commands survive across container restarts.
- `~/.claude/skills/` -- symlinked from the host. Some skills contain symlinks that resolve via a secondary mount.

The container is ephemeral - anything outside `/workspace` and `~/.claude/` is lost when the session ends.

If you are asked to install local MCP servers, do so to ~/.claude/mcp, they will be persisted and available in future sessions (mcp servers are configured in ~/.claude.json).

## Constraints

- **No macOS APIs**: You are on Linux.
- **No systemd**: This is a minimal container. Use direct process execution.
- **Package manager**: `apt-get` exists but the `claude` user has no root/sudo access, so you cannot install system packages. If you need something, tell the user the Debian package name and they can add it to the Containerfile.
- **Network**: Available but may be restricted depending on host configuration.
