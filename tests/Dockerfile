# Test harness: runs the ARM DroboApp under qemu-user with syscall tracing.
FROM debian:bookworm-slim
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      qemu-user python3 python3-venv procps busybox ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*
