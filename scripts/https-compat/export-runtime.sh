#!/bin/sh
set -eu
python -m pip install --no-compile --no-index --find-links /wheels --target /output/vendor -r /build/requirements.txt
# Alpine and OpenWrt use the same musl ABI with different library filenames.
find /output/vendor -type f -name '*.so*' -exec sh -c '
  for library do
    if patchelf --print-needed "$library" | grep -Fxq libc.musl-aarch64.so.1; then
      patchelf --replace-needed libc.musl-aarch64.so.1 libc.so "$library"
    fi
  done
' sh {} +
