#!/bin/sh
# Step 25 (runs inside the pinned rust:alpine arm64 container, RUST_IMAGE in
# config.env): build guest/progress-agent as a static aarch64-unknown-linux-musl
# binary -> /work/cache/progress-agent/fx-progress-agent (picked up by step 30).
# Dependencies are resolved strictly from the committed Cargo.lock (--locked);
# the crates.io download cache lives in /work/cache/cargo-home.
set -eu

OUT=/work/cache/progress-agent
export CARGO_HOME=/work/cache/cargo-home
export CARGO_TARGET_DIR=$OUT/target
# Reproducible paths in the binary (panic locations, debug info is stripped).
export RUSTFLAGS="--remap-path-prefix=/src/guest/progress-agent=fx-progress-agent --remap-path-prefix=$CARGO_HOME=cargo -C target-feature=+crt-static"
export SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH:-1767225600}
mkdir -p "$OUT" "$CARGO_HOME"

cd /src/guest/progress-agent
cargo test --locked --release --target aarch64-unknown-linux-musl
cargo build --locked --release --target aarch64-unknown-linux-musl
bin=$CARGO_TARGET_DIR/aarch64-unknown-linux-musl/release/fx-progress-agent

# Must be fully static: the guest has no musl loader (a PT_INTERP would name it).
if grep -q 'ld-musl' "$bin"; then
    echo "[progress-agent] $bin is dynamically linked" >&2; exit 1
fi
install -m 0755 "$bin" "$OUT/fx-progress-agent.tmp"
mv "$OUT/fx-progress-agent.tmp" "$OUT/fx-progress-agent"
sh /src/guest/progress-agent/tests/desktop-session.sh "$OUT/fx-progress-agent"
echo "[progress-agent] $OUT/fx-progress-agent: $(stat -c %s "$OUT/fx-progress-agent") bytes, sha256 $(sha256sum "$OUT/fx-progress-agent" | cut -c1-16), $(rustc -V)"
