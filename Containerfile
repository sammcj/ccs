FROM debian:bookworm-slim

SHELL ["/bin/bash", "-c"]

# Optionally set the username used on the host to create symlinks within the
# container for name resolution as might be mentioned in skills / tools mounted in.
# Pass at build time: --build-arg HOST_USER=$USER
ARG HOST_USER=""

# Optionally provide a list of directories that exist on the host that are being
# mounted into the container so we can pre-create them and set permissions for
# the non-root user. This is needed for the skills symlink target since it needs
# to be mounted at the same absolute path on the host and container for symlinks
# to resolve.
# Format: space-separated list of absolute paths
ARG HOST_MOUNT_DIRS="${HOST_USER:+/Users/${HOST_USER}/git/anthropic-skills}"

# These can be passed in to skip installing certain packages to slim the image
ARG INSTALL_RUST=true
ARG INSTALL_GO=true
ARG INSTALL_NODE=true
ARG INSTALL_UV=true

# Install base dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    git \
    ca-certificates \
    vim \
    less \
    htop \
    gnupg \
    jq \
    lsb-release \
    zsh \
    build-essential

### Optional global dev tools ###
ARG TARGETARCH
RUN if [ "$INSTALL_GO" = "true" ]; then \
        GO_VERSION=$(curl --proto '=https' --tlsv1.2 -fsSL 'https://go.dev/dl/?mode=json' \
            | sed -n 's/.*"version": *"go\([0-9][0-9.]*\)".*/\1/p' | head -1) \
        && echo "Installing Go ${GO_VERSION} for ${TARGETARCH}" \
        && curl --proto '=https' --tlsv1.2 -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-${TARGETARCH}.tar.gz" \
        | tar -C /usr/local -xzf - \
        && ln -s /usr/local/go/bin/go /usr/local/bin/go \
        && ln -s /usr/local/go/bin/gofmt /usr/local/bin/gofmt; \
    fi

RUN if [ "$INSTALL_NODE" = "true" ]; then \
        curl --proto '=https' --tlsv1.2 -fsSL https://deb.nodesource.com/setup_current.x | bash - \
        && apt-get install -y --no-install-recommends nodejs; \
    fi

# Clean apt cache after all apt installs are done
RUN rm -rf /var/lib/apt/lists/*

# Create non-root user
RUN useradd -m -s /bin/bash claude

# Switch to non-root user for remaining installs
USER claude

# pnpm install script needs SHELL to detect the shell type
ENV SHELL=/bin/bash
ENV PNPM_HOME="/home/claude/.local/share/pnpm"

### Install user dev tools ###
RUN if [ "$INSTALL_NODE" = "true" ]; then \
        curl --proto '=https' --tlsv1.2 -fsSL https://get.pnpm.io/install.sh | sh -;\
    fi

RUN if [ "$INSTALL_RUST" = "true" ]; then \
        curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y; \
    fi

RUN if [ "$INSTALL_UV" = "true" ]; then \
        curl --proto '=https' --tlsv1.2 -LsSf https://astral.sh/uv/install.sh | sh; \
    fi

# Install Claude Code via native installer
RUN curl -fsSL https://claude.ai/install.sh | bash

# Elevate back to root temporarily to symlink (prevents cache busting)
USER root

# Pre-create mount target dirs for host path symlink resolution
RUN if [ -n "$HOST_MOUNT_DIRS" ]; then \
        for dir in $HOST_MOUNT_DIRS; do \
            mkdir -p "$dir"; \
            chown claude:claude "$dir"; \
        done; \
    fi

ADD statusline-command.sh /usr/local/bin/statusline-command.sh
RUN chmod +x /usr/local/bin/statusline-command.sh && chown claude:claude /usr/local/bin/statusline-command.sh

USER claude

# Ensure all user-installed tools are on PATH
ENV PATH="/home/claude/.cargo/bin:/home/claude/.local/bin:${PNPM_HOME}:$PATH"

# Entrypoint sets up symlinks for config persistence (placed last for cache efficiency)
COPY --chmod=755 entrypoint.sh /usr/local/bin/entrypoint.sh

WORKDIR /workspace

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["claude", "--dangerously-skip-permissions"]
