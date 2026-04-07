# Multi-stage build: Zig compile → minimal runtime
# Binary is pure Zig (no libc), runtime needs bash+git for agent workspaces

# ── Stage 1: Build ──────────────────────────────────────────
FROM debian:bookworm-slim AS builder

# Install Zig 0.16
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl xz-utils \
    && rm -rf /var/lib/apt/lists/*

# Zig 0.16 — uses zig-x86_64-linux URL format
ARG ZIG_VERSION=0.16.0-dev.3091+557caecaa
RUN curl -fsSL "https://ziglang.org/builds/zig-x86_64-linux-${ZIG_VERSION}.tar.xz" \
    | tar -xJ -C /opt \
    && ln -s "/opt/zig-x86_64-linux-${ZIG_VERSION}/zig" /usr/local/bin/zig

# Copy source
WORKDIR /build
COPY programs/http_sentinel programs/http_sentinel
COPY programs/gcp_auth programs/gcp_auth
COPY programs/zig_ai_server programs/zig_ai_server

# Build release binary
WORKDIR /build/programs/zig_ai_server
RUN zig build -Doptimize=ReleaseSafe \
    && strip zig-out/bin/zig-ai-server 2>/dev/null || true

# ── Stage 2: Runtime ────────────────────────────────────────
FROM debian:bookworm-slim

# Minimal runtime deps: bash + git (for agent workspaces), ca-certs (for HTTPS to providers)
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates bash git \
    && rm -rf /var/lib/apt/lists/* \
    && git config --global user.email "agent@cosmicduck.dev" \
    && git config --global user.name "zig-ai-agent"

# Copy binary
COPY --from=builder /build/programs/zig_ai_server/zig-out/bin/zig-ai-server /usr/local/bin/zig-ai-server

# Models CSV is embedded at compile time — copy for reference only
COPY --from=builder /build/programs/zig_ai_server/data/models.csv /app/data/models.csv

# Data directory for WAL, snapshots, ledger
RUN mkdir -p /app/data
WORKDIR /app

# Cloud Run uses PORT env var
ENV PORT=8080

EXPOSE 8080

# Health check
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s \
    CMD curl -sf http://localhost:8080/health || exit 1

ENTRYPOINT ["zig-ai-server", "--port", "8080", "--host", "0.0.0.0"]
