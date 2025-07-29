# syntax=docker/dockerfile:1.7
######################## unified base (Parity's approach) ########################
FROM --platform=$BUILDPLATFORM docker.io/paritytech/ci-unified:latest as base

WORKDIR /fennel

# Install cargo-chef and targets with explicit toolchain (your proven approach)
RUN cargo install cargo-chef && \
    rustup target add wasm32-unknown-unknown --toolchain 1.84.1-x86_64-unknown-linux-gnu && \
    rustup target add aarch64-unknown-linux-gnu --toolchain 1.84.1-x86_64-unknown-linux-gnu

# Install only ARM64-specific cross-compilation tools (ci-unified has the rest)
RUN apt update && \
    apt install -y --no-install-recommends \
        g++-aarch64-linux-gnu libc6-dev-arm64-cross && \
    rm -rf /var/lib/apt/lists/* && apt clean && \
    echo "✅ ARM64 cross-compilation tools installed"

# Create Cargo config for cross-compilation (Parity's approach)
RUN mkdir -p /root/.cargo /home/nonroot/.cargo && \
    echo '[target.aarch64-unknown-linux-gnu]' > /root/.cargo/config && \
    echo 'linker = "aarch64-linux-gnu-gcc"' >> /root/.cargo/config && \
    echo '[target.wasm32-unknown-unknown]' >> /root/.cargo/config && \
    echo 'linker = "clang-15"' >> /root/.cargo/config && \
    cp /root/.cargo/config /home/nonroot/.cargo/config

# Set up cross-compilation environment variables (Parity's way)
ENV CC_aarch64_unknown_linux_gnu="aarch64-linux-gnu-gcc" \
    CXX_aarch64_unknown_linux_gnu="aarch64-linux-gnu-g++" \
    BINDGEN_EXTRA_CLANG_ARGS="-I/usr/aarch64-linux-gnu/include/" \
    CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_LINKER="aarch64-linux-gnu-gcc" \
    SKIP_WASM_BUILD=1

# Optimize cargo for space and reduce compilation units
ENV CARGO_NET_GIT_FETCH_WITH_CLI=true \
    CARGO_INCREMENTAL=0 \
    CARGO_PROFILE_RELEASE_CODEGEN_UNITS=1 \
    CARGO_PROFILE_RELEASE_LTO=true

######################## dependency planning ########################
FROM base AS planner
COPY . .
RUN cargo chef prepare --recipe-path recipe.json

######################## cook dependencies (both architectures) ########################
FROM base AS cook
COPY --from=planner /fennel/recipe.json recipe.json
RUN cargo chef cook --release --recipe-path recipe.json

FROM base AS cook-arm64
COPY --from=planner /fennel/recipe.json recipe.json
# Targets already installed in base with explicit toolchain
RUN cargo chef cook --release --recipe-path recipe.json --target aarch64-unknown-linux-gnu

######################## x86_64 builder (uses unified base) ########################
FROM base AS builder-amd64
ARG TARGET=x86_64-unknown-linux-gnu

# Build arguments for node features and secrets
ARG BUILD_RUST_LOG
ARG BUILD_FENNEL_LOG
ARG SUDO_SS58
ARG VAL1_AURA_PUB
ARG VAL1_GRANDPA_PUB
ARG VAL1_STASH_SS58
ARG VAL2_AURA_PUB
ARG VAL2_GRANDPA_PUB
ARG VAL2_STASH_SS58

# Convert build args to environment variables for cargo build
ENV BUILD_RUST_LOG=$BUILD_RUST_LOG \
    BUILD_FENNEL_LOG=$BUILD_FENNEL_LOG \
    SUDO_SS58=$SUDO_SS58 \
    VAL1_AURA_PUB=$VAL1_AURA_PUB \
    VAL1_GRANDPA_PUB=$VAL1_GRANDPA_PUB \
    VAL1_STASH_SS58=$VAL1_STASH_SS58 \
    VAL2_AURA_PUB=$VAL2_AURA_PUB \
    VAL2_GRANDPA_PUB=$VAL2_GRANDPA_PUB \
    VAL2_STASH_SS58=$VAL2_STASH_SS58

# Copy pre-cooked dependencies and source
COPY --from=cook /fennel/target target
COPY --from=planner /fennel/recipe.json recipe.json
COPY . .

# Build x86_64 binary (target already installed in base)
RUN cargo build --locked --release --target $TARGET

######################## ARM64 builder (uses unified base) ########################
FROM base AS builder-arm64

# Build arguments for node features and secrets  
ARG BUILD_RUST_LOG
ARG BUILD_FENNEL_LOG
ARG SUDO_SS58
ARG VAL1_AURA_PUB
ARG VAL1_GRANDPA_PUB
ARG VAL1_STASH_SS58
ARG VAL2_AURA_PUB
ARG VAL2_GRANDPA_PUB
ARG VAL2_STASH_SS58

# Convert build args to environment variables for cargo build
ENV BUILD_RUST_LOG=$BUILD_RUST_LOG \
    BUILD_FENNEL_LOG=$BUILD_FENNEL_LOG \
    SUDO_SS58=$SUDO_SS58 \
    VAL1_AURA_PUB=$VAL1_AURA_PUB \
    VAL1_GRANDPA_PUB=$VAL1_GRANDPA_PUB \
    VAL1_STASH_SS58=$VAL1_STASH_SS58 \
    VAL2_AURA_PUB=$VAL2_AURA_PUB \
    VAL2_GRANDPA_PUB=$VAL2_GRANDPA_PUB \
    VAL2_STASH_SS58=$VAL2_STASH_SS58

# Copy pre-cooked ARM64 dependencies and source
COPY --from=cook-arm64 /fennel/target target
COPY --from=planner /fennel/recipe.json recipe.json
COPY . .

# Targets already installed in base with explicit toolchain

# Build ARM64 binary
RUN cargo build --locked --release --target aarch64-unknown-linux-gnu

######################## deterministic wasm runtime ########################
FROM docker.io/paritytech/srtool:1.84.1 AS wasm-builder

# Pass all build arguments for WASM runtime inclusion
ARG BUILD_RUST_LOG
ARG BUILD_FENNEL_LOG
ARG SUDO_SS58
ARG VAL1_AURA_PUB
ARG VAL1_GRANDPA_PUB
ARG VAL1_STASH_SS58
ARG VAL2_AURA_PUB
ARG VAL2_GRANDPA_PUB
ARG VAL2_STASH_SS58

ENV BUILD_RUST_LOG=$BUILD_RUST_LOG \
    BUILD_FENNEL_LOG=$BUILD_FENNEL_LOG \
    SUDO_SS58=$SUDO_SS58 \
    VAL1_AURA_PUB=$VAL1_AURA_PUB \
    VAL1_GRANDPA_PUB=$VAL1_GRANDPA_PUB \
    VAL1_STASH_SS58=$VAL1_STASH_SS58 \
    VAL2_AURA_PUB=$VAL2_AURA_PUB \
    VAL2_GRANDPA_PUB=$VAL2_GRANDPA_PUB \
    VAL2_STASH_SS58=$VAL2_STASH_SS58

COPY . /build
RUN build --skip-wasm-api

######################## final runtime ########################
FROM --platform=$TARGETPLATFORM docker.io/parity/base-bin:latest

# Copy the appropriate binary based on target platform
COPY --from=builder-amd64 /fennel/target/x86_64-unknown-linux-gnu/release/fennel-node /usr/local/bin/fennel-node-amd64
COPY --from=builder-arm64 /fennel/target/aarch64-unknown-linux-gnu/release/fennel-node /usr/local/bin/fennel-node-arm64

# Create platform-appropriate symlink
RUN if [ "$TARGETPLATFORM" = "linux/amd64" ]; then \
        ln -s /usr/local/bin/fennel-node-amd64 /usr/local/bin/fennel-node; \
    elif [ "$TARGETPLATFORM" = "linux/arm64" ]; then \
        ln -s /usr/local/bin/fennel-node-arm64 /usr/local/bin/fennel-node; \
    fi

ENTRYPOINT ["/usr/local/bin/fennel-node"]
