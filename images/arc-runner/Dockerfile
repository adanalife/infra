# The image the arc-amd64 pool runs (k8s/arc/runners/values.yml points both the
# runner container and the chown-caches initContainer at it).
#
# Everything here is a tool some workflow in the fleet installs at job time
# today. Ephemeral runners repeat that install on every single job: measured on
# tempomat, apt + toolchain setup was 50% of the `testing / sidecar` job and 32%
# of `testing / core`. Baking it moves the cost to one weekly build on a
# GitHub-hosted runner.
#
# `gh` is the load-bearing one. It is absent upstream, so a `gh` call in a
# workflow step exits 127 — and those calls tend to sit behind `if: failure()`
# or a `schedule:`, so the breakage stays invisible until the moment it matters.
# Six were fixed one at a time on 2026-09-06/07 by rewriting them as curl
# against the REST API.
#
# NOTHING DOCKER IS ADDED HERE, deliberately. The pool runs no daemon (see the
# values.yml header — a Docker daemon on this node is the one workload every
# self-reboot had in common). Upstream's image already carries the `docker`
# client; with no socket to talk to it is inert, and that is the intended
# state. Do not add dind, buildx, or a daemon to make it work.
#
# Adding a tool: it belongs here when it is version-agnostic — a compiler, a
# system library, a CLI whose exact version no repo pins. Language toolchains
# do NOT: they are pinned per repo in .mise.toml, and a copy baked here would
# rot silently against those pins. mise installs those, out of the shared
# download cache the pool mounts at ~/.cache.
FROM ghcr.io/actions/actions-runner:latest

USER root

# gh ships from GitHub's own apt repo rather than a pinned release tarball so
# the weekly rebuild picks up new versions with no bump here.
RUN install -d -m 0755 /etc/apt/keyrings \
 && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      -o /etc/apt/keyrings/githubcli-archive-keyring.gpg \
 && chmod 0644 /etc/apt/keyrings/githubcli-archive-keyring.gpg \
 && echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list \
 && apt-get update -q \
 && apt-get install -y -q --no-install-recommends \
      gh \
      # cgo for `go test`, and the linker Rust shells out to
      build-essential \
      # flare's smoke gate renders video
      ffmpeg \
      # actions/cache uses zstd when it is present, gzip when it is not
      zstd \
      rsync \
      unzip \
      # the Swift toolchain's system dependencies (tempomat: testing +
      # console-contract both install this set per job)
      binutils \
      libcurl4-openssl-dev \
      libedit2 \
      libncurses-dev \
      libpython3-dev \
      libsqlite3-0 \
      libxml2-dev \
      libz3-dev \
      pkg-config \
      tzdata \
      zlib1g-dev \
 && rm -rf /var/lib/apt/lists/*

# Single static binaries, installed system-wide so the matching setup action
# finds one already on PATH instead of downloading it. The actions stay in the
# workflows — they still resolve versions and prime caches.
# The env var goes on the `sh` that consumes the script, not on the curl that
# fetches it — a prefix on the left of the pipe lands in curl's environment
# and the installer falls back to its default path.
RUN curl -fsSL https://mise.run | MISE_INSTALL_PATH=/usr/local/bin/mise sh \
 && curl -LsSf https://astral.sh/uv/install.sh | UV_INSTALL_DIR=/usr/local/bin sh \
 && curl -fsSL https://taskfile.dev/install.sh | sh -s -- -d -b /usr/local/bin \
 && gh --version && mise --version && uv --version && task --version

USER runner
