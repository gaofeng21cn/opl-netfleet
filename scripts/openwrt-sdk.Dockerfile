# Host tools for the official Linux x86_64 OpenWrt SDK; never installed on devices.
FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential ca-certificates clang file flex bison gawk gcc-multilib \
    gettext git libncurses-dev libssl-dev python3 python3-setuptools rsync \
    swig unzip wget zlib1g-dev zstd util-linux && rm -rf /var/lib/apt/lists/*
WORKDIR /build
CMD ["/bin/bash"]
