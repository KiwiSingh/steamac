# steamac image builder: every tool needed to fetch/verify the SteamOS bundle,
# reconstruct the rootfs and assemble the GPT disk, initramfs and layer.
# Runs as linux/arm64 (native on Apple Silicon via OrbStack). Package set is
# pinned through snapshot.debian.org; desync is pinned by version + sha256.
ARG BUILDER_BASE
FROM ${BUILDER_BASE}
ARG DEBIAN_SNAPSHOT
ARG DESYNC_VERSION
ARG DESYNC_SHA256

RUN set -eux; \
    rm -f /etc/apt/sources.list.d/debian.sources; \
    printf 'deb [check-valid-until=no] http://snapshot.debian.org/archive/debian/%s trixie main\n' "$DEBIAN_SNAPSHOT" > /etc/apt/sources.list; \
    printf 'Acquire::Retries "5";\nAcquire::http::Timeout "60";\n' > /etc/apt/apt.conf.d/80retries; \
    apt-get update; \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        ca-certificates curl openssl jq xxd file binutils \
        squashfs-tools btrfs-progs e2fsprogs dosfstools mtools gdisk fdisk util-linux \
        erofs-utils busybox-static cpio gzip zstd xz-utils rsync kmod; \
    rm -rf /var/lib/apt/lists/*

RUN set -eux; \
    curl -fsSL -o /tmp/desync.tgz "https://github.com/folbricht/desync/releases/download/v${DESYNC_VERSION}/desync_${DESYNC_VERSION}_linux_arm64.tar.gz"; \
    echo "${DESYNC_SHA256}  /tmp/desync.tgz" | sha256sum -c -; \
    tar -xzf /tmp/desync.tgz -C /usr/local/bin desync; \
    rm /tmp/desync.tgz; \
    desync --help >/dev/null
