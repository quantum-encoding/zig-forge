# Multi-stage build for Quantum Synapse Engine
# Stage 1: Builder
FROM ubuntu:22.04 AS builder

# Install build dependencies
RUN apt-get update && apt-get install -y \
    wget \
    xz-utils \
    build-essential \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Install Zig 0.16.0
WORKDIR /opt
RUN wget https://ziglang.org/builds/zig-linux-x86_64-0.16.0-dev.tar.xz && \
    tar -xf zig-linux-x86_64-0.16.0-dev.tar.xz && \
    mv zig-linux-x86_64-0.16.0-dev zig && \
    rm zig-linux-x86_64-0.16.0-dev.tar.xz

ENV PATH="/opt/zig:${PATH}"

# Copy source code
WORKDIR /build
COPY src/ ./src/
COPY build.zig ./

# Build the engine with optimizations
RUN zig build-exe src/multi_tenant_engine.zig \
    -O ReleaseFast \
    -femit-bin=quantum-synapse-engine

# Stage 2: Runtime (distroless for security)
FROM gcr.io/distroless/cc-debian12:nonroot

# Labels for container metadata
LABEL org.opencontainers.image.title="Quantum Synapse Engine" \
      org.opencontainers.image.description="Production-grade multi-tenant algorithmic trading platform" \
      org.opencontainers.image.vendor="Quantum Encoding Ltd" \
      org.opencontainers.image.version="1.0.0" \
      org.opencontainers.image.created="2025-01-11" \
      maintainer="engineering@quantumencoding.com"

# Create necessary directories
WORKDIR /app

# Copy the binary from builder
COPY --from=builder /build/quantum-synapse-engine /app/quantum-synapse-engine

# Copy configuration
COPY config/production.json /app/config/production.json

# Create volume mount points for persistent data
VOLUME ["/var/log/quantum-synapse", "/var/lib/quantum-synapse"]

# Health check endpoint
EXPOSE 8080

# Prometheus metrics endpoint
EXPOSE 9090

# Set user to non-root for security
USER nonroot:nonroot

# Health check
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD ["/app/quantum-synapse-engine", "--health-check"]

# Default configuration file path
ENV QSE_CONFIG_PATH=/app/config/production.json

# Runtime configuration via environment variables
ENV APCA_API_KEY_ID="" \
    APCA_API_SECRET_KEY="" \
    QSE_LOG_LEVEL="info" \
    QSE_ENVIRONMENT="production"

# Entrypoint
ENTRYPOINT ["/app/quantum-synapse-engine"]

# Default arguments (can be overridden)
CMD ["--config", "/app/config/production.json"]