FROM rust:1.95-alpine3.22@sha256:064dfc925d68d1a63f4fd2871bd7dc6e6ea56692989a487185855d62885d90aa AS rust
FROM python:3.13-alpine3.22@sha256:e81548ac35b07a3bd4805f275107592ef458b1e893c0e04d45aedaa19416cca5

RUN apk add --no-cache build-base openssl-dev libffi-dev linux-headers patchelf
COPY --from=rust /usr/local/cargo /usr/local/cargo
COPY --from=rust /usr/local/rustup /usr/local/rustup
ENV RUSTUP_HOME=/usr/local/rustup CARGO_HOME=/usr/local/cargo PATH=/usr/local/cargo/bin:$PATH
RUN rustup toolchain install nightly-2026-07-20 --component rust-src --profile minimal \
    && ln -s nightly-2026-07-20-aarch64-unknown-linux-musl /usr/local/rustup/toolchains/nightly-aarch64-unknown-linux-musl
ADD --checksum=sha256:d09ddd83303e9ab1443f51e0e284680154009646a3ce141c63d838ee61b73eb9 https://github.com/aya-rs/bpf-linker/releases/download/v0.11.0/bpf-linker-aarch64-unknown-linux-musl.tar.zst /tmp/bpf-linker.tar.zst
RUN apk add --no-cache zstd tar && tar --zstd -xf /tmp/bpf-linker.tar.zst -C /usr/local/bin && bpf-linker --version
WORKDIR /build
COPY requirements.txt /build/requirements.txt
RUN --mount=type=cache,target=/root/.cache/pip python -m pip wheel --wheel-dir /wheels -r requirements.txt
RUN python -m pip install --no-index --find-links /wheels mitmproxy==12.2.3 \
    && mitmdump --version \
    && python -m pip check
COPY export-runtime.sh /build/export-runtime.sh
CMD ["sh", "/build/export-runtime.sh"]
