# syntax=docker/dockerfile:1.7
FROM --platform=$BUILDPLATFORM docker.io/paritytech/ci-unified:latest as base

WORKDIR /fennel

# Override default toolchain to match rust-toolchain.toml (Parity's pattern)
RUN rustup default 1.84.1-x86_64-unknown-linux-gnu

# Install cargo-chef and add targets to default toolchain (Parity's approach)
RUN cargo install cargo-chef && \
    rustup target add wasm32-unknown-unknown && \
    rustup target add aarch64-unknown-linux-gnu

# Install ARM64 cross-compilation tools
RUN apt update && \
    apt install -y --no-install-recommends \
        g++-aarch64-linux-gnu libc6-dev-arm64-cross && \
    rm -rf /var/lib/apt/lists/* && apt clean

# Create Cargo config for cross-compilation
RUN mkdir -p /root/.cargo /home/nonroot/.cargo && \
    echo '[target.aarch64-unknown-linux-gnu]' > /root/.cargo/config && \
    echo 'linker = "aarch64-linux-gnu-gcc"' >> /root/.cargo/config && \
    cp /root/.cargo/config /home/nonroot/.cargo/config

# Set up cross-compilation environment variables
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

# Planner stage - analyze dependencies
FROM base AS planner
COPY . .
RUN cargo chef prepare --recipe-path recipe.json

# Cook dependencies for x86_64
FROM base AS cook
COPY --from=planner /fennel/recipe.json recipe.json
RUN cargo chef cook --release --recipe-path recipe.json

# Cook dependencies for ARM64  
FROM base AS cook-arm64
COPY --from=planner /fennel/recipe.json recipe.json
RUN cargo chef cook --release --recipe-path recipe.json --target aarch64-unknown-linux-gnu

# Testing stage - run tests before building
FROM base AS tester
COPY . .
RUN cargo test --features=runtime-benchmarks

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

# Builder stage - build x86_64 with cached dependencies
FROM base AS builder-amd64
COPY --from=planner /fennel/recipe.json recipe.json
COPY --from=cook /fennel/target target

# Now copy the actual source code and build for x86_64
COPY . .
RUN cargo build --locked --release

# Builder stage - build ARM64 with cached dependencies
FROM base AS builder-arm64
COPY --from=planner /fennel/recipe.json recipe.json
COPY --from=cook-arm64 /fennel/target target

# Now copy the actual source code and build for ARM64
COPY . .
RUN cargo build --locked --release --target aarch64-unknown-linux-gnu

# Runtime stage - final image with minimal components
FROM --platform=$TARGETPLATFORM docker.io/parity/base-bin:latest

# Copy both binaries
COPY --from=builder-amd64 /fennel/target/release/fennel-node /usr/local/bin/fennel-node-amd64
COPY --from=builder-arm64 /fennel/target/aarch64-unknown-linux-gnu/release/fennel-node /usr/local/bin/fennel-node-arm64

# Create platform-appropriate symlink
RUN if [ "$TARGETPLATFORM" = "linux/amd64" ]; then \
        ln -s /usr/local/bin/fennel-node-amd64 /usr/local/bin/fennel-node; \
    elif [ "$TARGETPLATFORM" = "linux/arm64" ]; then \
        ln -s /usr/local/bin/fennel-node-arm64 /usr/local/bin/fennel-node; \
    fi

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
VOLUME ["/data"]

# Use node binary as entrypoint (Parity standard practice)
ENTRYPOINT ["/usr/local/bin/fennel-node"]
