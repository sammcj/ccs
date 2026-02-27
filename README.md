# ccs - Claude Code Sandboxed

Run Claude Code with `--dangerously-skip-permissions` inside an isolated Apple Containers VM.

## Installation

Requirements

- macOS 26+ (Tahoe)
- Apple Silicon
- [Apple container CLI](https://github.com/apple/container/releases)

```mermaid
block-beta
  columns 1

  block:host["Host macOS"]
    columns 2

    block:normal["Standard Claude Code"]
      columns 1
      A["claude<br>Your existing setup - no sandbox"]
    end

    block:sandbox["ccs - Sandboxed Claude Code"]
      columns 1
      block:container["Apple Container - Lightweight VM"]
        columns 1
        block:vm["Linux VM - Dedicated Kernel"]
          columns 1
          B["claude --dangerously-skip-permissions"]
          C["/workspace - your project, mounted from host"]
          D["Isolated network, filesystem, and processes"]
        end
      end
    end
  end

  classDef hostStyle fill:#F5F5F5,stroke:#9E9E9E,color:#616161
  classDef normalStyle fill:#FFF3E0,stroke:#FFB74D,color:#F57C00
  classDef sandboxStyle fill:#E0F2F1,stroke:#4DB6AC,color:#00897B
  classDef containerStyle fill:#E8EAF6,stroke:#7986CB,color:#3F51B5
  classDef vmStyle fill:#F3E5F5,stroke:#BA68C8,color:#8E24AA
  classDef itemStyle fill:#FFFFFF,stroke:#9E9E9E,color:#424242

  class host hostStyle
  class normal normalStyle
  class sandbox sandboxStyle
  class container containerStyle
  class vm vmStyle
  class A,B,C,D itemStyle
```

### Quick Install

Link the script to somewhere in PATH

```bash
git clone https://github.com/sammcj/ccs && cd ccs
ln -s $(PWD)/ccs ~/.local/bin/
```

The script will detect if Apple's container CLI is not installed and install it for you, otherwise it will "just work" if you already have it.

```bash
ccs
```

## Usage

```bash
# Start Claude with dangerous permissions in isolated VM
ccs

# Any normal arguments to claude are passed, e.g.:
ccs -c # continue
ccs -r # resume
ccs "refactor this entire codebase" # prompt

# (Re)build the container image
ccs --build
```

### Configuration

The `ccs` script has several arrays at the top that you can edit to customise behaviour.

At present these are configured in the ccs script itself, which is not ideal so at some point I will move the configuration out.

**`EXTRA_VOLUMES`** -- Additional host directories to mount into the container as `host_path:container_path`. The workspace (`pwd`) and the ccs config directory (`~/.ccs`) are always mounted automatically. The defaults mount your Claude skills, commands, and agents directories so they're available inside the sandbox:

```bash
EXTRA_VOLUMES=(
  "${HOME}/git/anthropic-skills:/Users/${USER}/git/anthropic-skills"
  "${HOME}/.claude/skills:${CONTAINER_CLAUDE_DIR}/skills"
  "${HOME}/.claude/commands:${CONTAINER_CLAUDE_DIR}/commands"
  "${HOME}/.claude/agents:${CONTAINER_CLAUDE_DIR}/agents"
  # Add more volumes here as needed
)
```

To mount additional directories, add entries to this array. For example, to mount a shared library:

```bash
EXTRA_VOLUMES+=(
  "${HOME}/git/my-shared-lib:/workspace/lib"
)
```

**`PASSTHROUGH_VARS`** -- Host environment variable names to forward into the container. `ANTHROPIC_API_KEY` is always passed through automatically.

```bash
PASSTHROUGH_VARS=(
  "GITHUB_TOKEN"
  # "OPENAI_API_KEY"
)
```

**`PLUGINS_MOUNT`** -- By default the container uses its own persistent plugin directory (`~/.ccs/plugins`). Set this to a host path to mount your host plugins directly instead, e.g. `"${HOME}/.claude/plugins"`.

####Runtime Environment Variables

| Variable     | Default | Description               |
| ------------ | ------- | ------------------------- |
| `CCS_MEMORY` | `4G`    | Memory limit per instance |
| `CCS_CPUS`   | `2`     | CPU cores per instance    |

### Manual Install

1. Install Apple's container CLI

   ```bash
   # Download the latest .pkg from:
   # https://github.com/apple/container/releases

   sudo installer -pkg container-installer-signed.pkg -target /
   container system start
   container system kernel set --recommended
   ```

2. Build the Claude container image

   ```bash
   cd ccs
   container build -t ccs:latest .
   ```

3. Install the wrapper script

```bash
ln -s $(PWD)/ccs ~/.local/bin/
```

## Security

ccs provides isolation through multiple layers of Apple's containerisation stack:

- **VM-backed containers** -- Each container runs inside its own lightweight virtual machine, not just a namespace
- **Kernel isolation** -- Every container gets a dedicated Linux kernel, separate from the host and other containers
- **Filesystem isolation** -- The container can only see directories explicitly mounted into it; the rest of the host filesystem is invisible
- **Network isolation** -- Each container has its own network stack with no implicit access to host services

### What ccs Protects Against

- **Accidental host damage** -- Stray `rm -rf` or destructive commands cannot reach files outside the mounted workspace
- **Runaway processes** -- CPU and memory limits prevent a misbehaving process from starving the host
- **Unintended system changes** -- The container has no access to host system configuration, services, or other user data

### What ccs Does NOT Protect Against

- **Modifications within the mounted workspace** -- `/workspace` is read-write by design, so Claude can create, edit, or delete anything inside it
- **Data exfiltration from mounted directories** -- Any file mounted into the container is readable by Claude and could be sent over the network
- **Vulnerabilities in Apple's Virtualisation framework** -- ccs inherits any security limitations of the underlying VM implementation

## Best Practices

1. **Mount only what's needed** -- Limit mounted directories to the project you're working on
2. **Audit changes before merging** -- Review what Claude did in the workspace with `git diff` before committing
3. **Keep software updated** -- Install macOS and container CLI updates promptly for the latest security fixes
4. **Exclude sensitive paths** -- Never mount directories containing credentials or keys, such as `~/.ssh`, `~/.aws`, or `~/.config`

## License

[MIT](LICENSE)
