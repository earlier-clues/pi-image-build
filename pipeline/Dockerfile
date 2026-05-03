FROM debian:trixie-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
        qemu-user-static binfmt-support \
        parted e2fsprogs dosfstools kpartx \
        util-linux mount coreutils kmod \
        xz-utils gzip rsync curl ca-certificates \
        procps openssl file && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /work
