# Test-only wire origin/client toolchain. None of these Python dependencies ship in the plugin.
FROM python:3.13-alpine3.22
RUN apk add --no-cache openssl build-base linux-headers pkgconf openssl-dev \
    && pip install --no-cache-dir cryptography hypercorn==0.18.0 'httpx[http2]==0.28.1'
