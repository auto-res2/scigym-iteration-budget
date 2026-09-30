# Base Dockerfile for AIRAS ML Experiments
# This provides a reproducible environment for all experiment stages

# Base image pinned to a version AND its digest.
FROM python:3.11.16-slim-trixie@sha256:be1575ed968de893bd54f4c56315ff7c4736ce522c1bca08fd521731aafc0d76

# Set environment variables
ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

# Install system dependencies
# `make` is the evaluation entry point (see Makefile / `make evaluate`)
RUN apt-get update && apt-get install -y \
    git \
    curl \
    make \
    build-essential \
    && rm -rf /var/lib/apt/lists/*

# Lean toolchain, for `lean` claims (see lean/ and `make run`). elan is pinned
# to a version AND the sha256 of its release tarball; the toolchain it installs
# is the one lean/lean-toolchain names, so that file stays the single place the
# version is written. Both are installed here, root-owned, so nothing at run
# time can write to the compiler, lake or the report tool: a proof's code runs
# with the repository writable, not the toolchain. The mathlib build cache is
# fetched by `lake exe cache get` inside `make run`, into lean/.lake/.
ARG ELAN_VERSION=4.2.4
ENV ELAN_HOME=/opt/elan \
    PATH=/opt/elan/bin:$PATH
COPY lean/lean-toolchain /tmp/lean-toolchain
RUN set -eux; \
    case "$(uname -m)" in \
      x86_64)  arch=x86_64;  sha=42b94d4244e8353142c456ec0e4ca6528fd898a6c604d4059f494e706e431f63 ;; \
      aarch64) arch=aarch64; sha=05febd124d84ebf994b2e7479922a5650b1e950c17ae3bd1ddd776b65bb72bf9 ;; \
      *) echo "unsupported architecture: $(uname -m)"; exit 1 ;; \
    esac; \
    curl -sSfL "https://github.com/leanprover/elan/releases/download/v${ELAN_VERSION}/elan-${arch}-unknown-linux-gnu.tar.gz" -o /tmp/elan.tar.gz; \
    echo "${sha}  /tmp/elan.tar.gz" | sha256sum -c -; \
    tar -xzf /tmp/elan.tar.gz -C /tmp elan-init; \
    /tmp/elan-init -y --no-modify-path --default-toolchain none; \
    elan toolchain install "$(tr -d '[:space:]' < /tmp/lean-toolchain)"; \
    rm -f /tmp/elan.tar.gz /tmp/elan-init /tmp/lean-toolchain

# Install uv package manager.
# Pinned to a version AND its digest: `:latest` moves, so an unpinned uv is a
# floating input to every build. Bump both lines together.
COPY --from=ghcr.io/astral-sh/uv:0.12.6@sha256:88bc6eb1ccd4b82efd0e1b530caffabddf50dc2bf612e66c14ea25b8ee8a4d3d /uv /usr/local/bin/uv

# Set working directory
WORKDIR /workspace

# Copy dependency files. uv.lock is REQUIRED: a missing lock file fails the
# build here rather than silently re-resolving dependencies later.
COPY pyproject.toml uv.lock ./

# Install Python dependencies using uv.
# This layer is cached unless pyproject.toml / uv.lock change.
# --locked: install exactly what uv.lock pins AND verify the lock is still in
# sync with pyproject.toml (--frozen would use the lock without checking).
# So the build fails on dependency drift instead of resolving around it.
RUN uv sync --locked --no-cache --group eval

# From here on, every `uv run` (src.main, `make evaluate`, ...) uses the venv
# built above as-is: no resolution, no network, no writes at run time.
# Set as an env var rather than only on CMD so it also covers the commands the
# GitHub workflows pass to `docker run` and the `uv run` calls in the Makefile.
ENV UV_NO_SYNC=1

# Copy the rest of the application
COPY . .

# Create results directory
RUN mkdir -p .research/results

# Default command (can be overridden in workflow)
CMD ["bash"]
