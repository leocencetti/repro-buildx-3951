# syntax=docker/dockerfile:1.10
# Toolchain image shared by the SSH targets: Rust + git + ssh client.
FROM rust:1.95-slim-bookworm AS build-base
RUN apt-get update && \
    apt-get install -y --no-install-recommends openssh-client git ca-certificates && \
    rm -rf /var/lib/apt/lists/*
