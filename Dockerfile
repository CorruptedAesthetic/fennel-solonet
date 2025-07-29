# syntax=docker/dockerfile:1.7
######################## unified base (Parity's approach) ########################
FROM --platform=$BUILDPLATFORM docker.io/paritytech/ci-unified:bullseye-1.88.0 as base

WORKDIR /fennel

# Install cargo-chef for dependency optimization
RUN cargo install cargo-chef

# Install ALL targets upfront (True Parity approach - single comprehensive installation)
RUN rustup target add wasm32-unknown-unknown && \
    rustup target add aarch64-unknown-linux-gnu && \
    echo "✅ All targets installed" && \
    rustup target list --installed

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

# Target already installed in base stage

RUN cargo chef cook --release --recipe-path recipe.json --target aarch64-unknown-linux-gnu

######################## deterministic WASM runtime (srtool) ########################
FROM docker.io/paritytech/srtool:1.84.1 AS srtool

# The srtool image expects sources in /build
WORKDIR /build

# Copy the full workspace for frame pallets & dependencies
COPY --chown=builder:builder . .

# Configure srtool for the runtime crate
ENV RUNTIME_DIR=runtime/fennel
ENV PACKAGE=fennel-node-runtime

# Build deterministic runtime
RUN /srtool/build

# Export the deterministic wasm path
ENV DETERMINISTIC_WASM_PATH=target/srtool/release/wbuild/fennel-node-runtime/fennel_node_runtime.compact.wasm

######################## x86_64 builder (uses unified base) ########################
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
ENV SUDO_SS58=${SUDO_SS58} \
    VAL1_AURA_PUB=${VAL1_AURA_PUB} \
    VAL1_GRANDPA_PUB=${VAL1_GRANDPA_PUB} \
    VAL1_STASH_SS58=${VAL1_STASH_SS58} \
    VAL2_AURA_PUB=${VAL2_AURA_PUB} \
    VAL2_GRANDPA_PUB=${VAL2_GRANDPA_PUB} \
    VAL2_STASH_SS58=${VAL2_STASH_SS58}

# Copy pre-cooked dependencies and source
COPY --from=cook /fennel/target target
COPY --from=planner /fennel/recipe.json recipe.json
COPY . .

# Build x86_64 binary (target already installed in base)
RUN cargo build --locked --release --target $TARGET

######################## ARM64 builder (uses unified base) ########################
FROM base AS builder-arm64

# Production environment variables (passed from build args)
ARG SUDO_SS58
ARG VAL1_AURA_PUB
ARG VAL1_GRANDPA_PUB
ARG VAL1_STASH_SS58
ARG VAL2_AURA_PUB
ARG VAL2_GRANDPA_PUB
ARG VAL2_STASH_SS58

# Export as environment variables for cargo build
ENV SUDO_SS58=${SUDO_SS58} \
    VAL1_AURA_PUB=${VAL1_AURA_PUB} \
    VAL1_GRANDPA_PUB=${VAL1_GRANDPA_PUB} \
    VAL1_STASH_SS58=${VAL1_STASH_SS58} \
    VAL2_AURA_PUB=${VAL2_AURA_PUB} \
    VAL2_GRANDPA_PUB=${VAL2_GRANDPA_PUB} \
    VAL2_STASH_SS58=${VAL2_STASH_SS58}

# Copy pre-cooked ARM64 dependencies and source
COPY --from=cook-arm64 /fennel/target target
COPY --from=planner /fennel/recipe.json recipe.json
COPY . .

# Verify ARM64 target from base stage
RUN echo "Verifying ARM64 target from base stage:" && \
    rustup target list --installed && \
    rustup target list --installed | grep aarch64-unknown-linux-gnu && \
    echo "✅ ARM64 target confirmed - ready to build"

# Build ARM64 binary
RUN cargo build --locked --release --target aarch64-unknown-linux-gnu

######################## final runtime image ########################
FROM docker.io/parity/base-bin:latest

ARG TARGETARCH

# Copy both architecture binaries
COPY --from=builder-amd64 /fennel/target/x86_64-unknown-linux-gnu/release/fennel-node /tmp/fennel-node-amd64
COPY --from=builder-arm64 /fennel/target/aarch64-unknown-linux-gnu/release/fennel-node /tmp/fennel-node-arm64

# Select correct binary based on target architecture
RUN if [ "$TARGETARCH" = "amd64" ]; then \
        mv /tmp/fennel-node-amd64 /usr/local/bin/fennel-node; \
    elif [ "$TARGETARCH" = "arm64" ]; then \
        mv /tmp/fennel-node-arm64 /usr/local/bin/fennel-node; \
    else \
        echo "Unsupported architecture: $TARGETARCH" && exit 1; \
    fi && \
    chmod +x /usr/local/bin/fennel-node

# Copy deterministic wasm for governance upgrades
COPY --from=srtool /build/runtime/fennel/target/srtool/release/wbuild/fennel-node-runtime/fennel_node_runtime.compact.wasm /usr/local/bin/fennel_node_runtime.compact.wasm
RUN test -f /usr/local/bin/fennel_node_runtime.compact.wasm

ARG WASM_HASH=unknown
LABEL io.parity.srtool.wasm-hash=${WASM_HASH}

# Create fennel user and setup permissions
USER root
RUN useradd -m -u 1001 -U -s /bin/sh -d /fennel fennel && \
    mkdir -p /data /fennel/.local/share && \
    chown -R fennel:fennel /data && \
    ln -s /data /fennel/.local/share/fennel && \
    /usr/local/bin/fennel-node --version

USER fennel

# Expose standard Substrate ports
EXPOSE 9933 9944 30333 9615
VOLUME ["/data"]

# Use node binary as entrypoint
ENTRYPOINT ["/usr/local/bin/fennel-node"]
