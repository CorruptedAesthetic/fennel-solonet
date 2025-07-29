# syntax=docker/dockerfile:1.7
FROM docker.io/paritytech/ci-unified:latest as base

WORKDIR /fennel

# Install cargo-chef and pre-fetch the wasm target once
RUN cargo install cargo-chef \
    && rustup target add wasm32-unknown-unknown --toolchain 1.84.1-x86_64-unknown-linux-gnu

# Set up cargo configuration for optimized builds (Parity best practice)
RUN mkdir -p /root/.cargo /home/nonroot/.cargo && \
    echo '[target.x86_64-unknown-linux-gnu]' > /root/.cargo/config && \
    echo 'linker = "clang-15"' >> /root/.cargo/config && \
    echo 'rustflags = ["-Ctarget-feature=+aes,+sse2,+ssse3"]' >> /root/.cargo/config && \
    cp /root/.cargo/config /home/nonroot/.cargo/config

# Optimize cargo for space and reduce compilation units
ENV CARGO_NET_GIT_FETCH_WITH_CLI=true
ENV CARGO_INCREMENTAL=0
ENV CARGO_PROFILE_RELEASE_CODEGEN_UNITS=1
ENV CARGO_PROFILE_RELEASE_LTO=true

# Planner stage - analyze dependencies
FROM base AS planner
COPY . .
RUN cargo chef prepare --recipe-path recipe.json

# Testing stage - run tests before building
FROM base AS tester
COPY . .
RUN cargo test --features=runtime-benchmarks

# --- Deterministic WASM runtime build using srtool -----------------
FROM docker.io/paritytech/srtool:1.84.1 AS srtool

# The srtool image expects the sources to live in /build
WORKDIR /build

# Copy the full workspace so that frame pallets & dependencies are available
COPY --chown=builder:builder . .

# Tell srtool which crate contains the runtime
ENV RUNTIME_DIR=runtime/fennel
ENV PACKAGE=fennel-node-runtime

# Build the runtime in deterministic mode
RUN /srtool/build

# The compact deterministic wasm will be available below
ENV DETERMINISTIC_WASM_PATH=target/srtool/release/wbuild/fennel-node-runtime/fennel_node_runtime.compact.wasm

# Builder stage - build with cached dependencies
FROM base AS builder
COPY --from=planner /fennel/recipe.json recipe.json

# Build dependencies first (this layer will be cached)
RUN cargo chef cook --release --recipe-path recipe.json

# Now copy the actual source code and build
COPY . .
RUN cargo build --locked --release

# Runtime stage - final image with minimal components
FROM docker.io/parity/base-bin:latest

# Copy the node binary
COPY --from=builder /fennel/target/release/fennel-node /usr/local/bin/fennel-node

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
