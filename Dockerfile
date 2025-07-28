# syntax=docker/dockerfile:1.7
######################## common base ########################
FROM --platform=$BUILDPLATFORM docker.io/paritytech/ci-unified:latest as base

WORKDIR /fennel

# Install cargo-chef and pre-fetch the wasm target once
RUN cargo install cargo-chef \
    && rustup target add wasm32-unknown-unknown --toolchain 1.84.1-x86_64-unknown-linux-gnu

# Optimize cargo for space and reduce compilation units
ENV CARGO_NET_GIT_FETCH_WITH_CLI=true
ENV CARGO_INCREMENTAL=0
ENV CARGO_PROFILE_RELEASE_CODEGEN_UNITS=1
ENV CARGO_PROFILE_RELEASE_LTO=true

# Planner stage - analyze dependencies
FROM base AS planner
COPY . .
RUN cargo chef prepare --recipe-path recipe.json

# Cook dependencies on x86_64 (works for both architectures)
FROM base AS cook
COPY --from=planner /fennel/recipe.json recipe.json
RUN cargo chef cook --release --recipe-path recipe.json

# --- New stage: deterministic WASM runtime build using srtool -----------------
FROM docker.io/paritytech/srtool:1.84.1 AS srtool

# The srtool image expects the sources to live in /build
WORKDIR /build

# Copy the full workspace so that frame pallets & dependencies are available
COPY --chown=builder:builder . .

# Tell srtool which crate contains the runtime. Adjust these paths/names if you
# ever rename the runtime crate or move it to another folder.
ENV RUNTIME_DIR=runtime/fennel
ENV PACKAGE=fennel-node-runtime

# Build the runtime in deterministic mode. The build script lives inside the
# image under /scripts/build
RUN /srtool/build

# The compact deterministic wasm will be available below.
ENV DETERMINISTIC_WASM_PATH=target/srtool/release/wbuild/fennel-node-runtime/fennel_node_runtime.compact.wasm

######################## x86_64 builder ####################
FROM base AS builder-amd64
ARG TARGET=x86_64-unknown-linux-gnu

# Production environment variables (passed from build args)
ARG SUDO_SS58
ARG VAL1_AURA_PUB
ARG VAL1_GRANDPA_PUB
ARG VAL1_STASH_SS58
ARG VAL2_AURA_PUB
ARG VAL2_GRANDPA_PUB
ARG VAL2_STASH_SS58

# Export as environment variables for cargo build
ENV SUDO_SS58=${SUDO_SS58}
ENV VAL1_AURA_PUB=${VAL1_AURA_PUB}
ENV VAL1_GRANDPA_PUB=${VAL1_GRANDPA_PUB}
ENV VAL1_STASH_SS58=${VAL1_STASH_SS58}
ENV VAL2_AURA_PUB=${VAL2_AURA_PUB}
ENV VAL2_GRANDPA_PUB=${VAL2_GRANDPA_PUB}
ENV VAL2_STASH_SS58=${VAL2_STASH_SS58}

RUN rustup target add $TARGET

# cargo-chef is already available from base stage (no need to copy)
COPY --from=cook /fennel/target target
COPY --from=planner /fennel/recipe.json recipe.json

# Dependencies are already cooked, skip the cook step

# Now copy the actual source code and build
COPY . .
RUN cargo build --locked --release --target $TARGET

######################## arm64 builder ####################
FROM docker.io/paritytech/xbuilder-aarch64-unknown-linux-gnu:latest AS builder-arm64
# image already has the linker + env-vars configured
ARG TARGET=aarch64-unknown-linux-gnu

# Production environment variables (passed from build args)
ARG SUDO_SS58
ARG VAL1_AURA_PUB
ARG VAL1_GRANDPA_PUB
ARG VAL1_STASH_SS58
ARG VAL2_AURA_PUB
ARG VAL2_GRANDPA_PUB
ARG VAL2_STASH_SS58

# Export as environment variables for cargo build
ENV SUDO_SS58=${SUDO_SS58}
ENV VAL1_AURA_PUB=${VAL1_AURA_PUB}
ENV VAL1_GRANDPA_PUB=${VAL1_GRANDPA_PUB}
ENV VAL1_STASH_SS58=${VAL1_STASH_SS58}
ENV VAL2_AURA_PUB=${VAL2_AURA_PUB}
ENV VAL2_GRANDPA_PUB=${VAL2_GRANDPA_PUB}
ENV VAL2_STASH_SS58=${VAL2_STASH_SS58}

WORKDIR /fennel

# Optimize cargo for space and reduce compilation units (same as base)
ENV CARGO_NET_GIT_FETCH_WITH_CLI=true
ENV CARGO_INCREMENTAL=0
ENV CARGO_PROFILE_RELEASE_CODEGEN_UNITS=1
ENV CARGO_PROFILE_RELEASE_LTO=true

# The xbuilder image already has the aarch64 toolchain configured
# Just switch to it and verify the target is available
RUN rustup show && \
    rustup default stable-aarch64-unknown-linux-gnu && \
    rustup target list --installed && \
    rustup show

# Install cargo-chef for dependency caching (copy from base to avoid reinstall)
COPY --from=base /usr/local/cargo/bin/cargo-chef /usr/local/cargo/bin/cargo-chef

# Copy pre-cooked dependencies from cook stage (avoids ARM64 emulation issues)
COPY --from=cook /fennel/target target
COPY --from=planner /fennel/recipe.json recipe.json
COPY . .
RUN cargo build --locked --release --target $TARGET

######################## final stage #######################
FROM docker.io/parity/base-bin:latest

ARG TARGETARCH
# Copy both binaries using the battle-tested Pattern A approach
# This avoids variable substitution in --from= which Docker doesn't support
COPY --from=builder-amd64 /fennel/target/x86_64-unknown-linux-gnu/release/fennel-node /tmp/fennel-node-amd64
COPY --from=builder-arm64 /fennel/target/aarch64-unknown-linux-gnu/release/fennel-node /tmp/fennel-node-arm64

# Select the correct binary at runtime based on TARGETARCH
RUN if [ "$TARGETARCH" = "amd64" ]; then \
        mv /tmp/fennel-node-amd64 /usr/local/bin/fennel-node; \
    elif [ "$TARGETARCH" = "arm64" ]; then \
        mv /tmp/fennel-node-arm64 /usr/local/bin/fennel-node; \
    else \
        echo "Unsupported architecture: $TARGETARCH" && exit 1; \
    fi && \
    chmod +x /usr/local/bin/fennel-node

# Copy the deterministic wasm compiled with srtool (optional but convenient for
# governance upgrades & CI verification)
COPY --from=srtool /build/runtime/fennel/target/srtool/release/wbuild/fennel-node-runtime/fennel_node_runtime.compact.wasm /usr/local/bin/fennel_node_runtime.compact.wasm
RUN test -f /usr/local/bin/fennel_node_runtime.compact.wasm

ARG WASM_HASH=unknown
LABEL io.parity.srtool.wasm-hash=${WASM_HASH}

USER root
RUN useradd -m -u 1001 -U -s /bin/sh -d /fennel fennel && \
	mkdir -p /data /fennel/.local/share && \
	chown -R fennel:fennel /data && \
	ln -s /data /fennel/.local/share/fennel && \
# check if executable works in this container
	/usr/local/bin/fennel-node --version

USER fennel

EXPOSE 9933 9944 30333 9615
# Removed ports:
# - 9930: Removed unless specific reverse-proxy need (ecosystem standard)
# - 30334: Removed - only needed for relay-within-relay processes
VOLUME ["/data"]

# Use node binary as entrypoint (Parity standard practice)
ENTRYPOINT ["/usr/local/bin/fennel-node"]
