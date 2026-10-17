# A local Windows check without a Windows machine: Wine runs the programs, and the llvm-mingw cross toolchain builds
# them for x86_64-w64-windows-gnu. `make windows-docker-build` and `make windows-docker-check` build and use this
# image; no CI job does.
#
# The Wine image is the base because Debian's and Ubuntu's `wine64` alone cannot run a program in a container as a
# user without a passwd entry: it aborts with "free(): invalid pointer" while making its prefix, and the `/usr/bin/wine`
# wrapper comes from the 32-bit metapackage.
FROM scottyhardy/docker-wine:stable-11.0-20261011

# The base starts a VNC and X server for GUI programs; this build runs console programs only and docker run passes
# the command, so its entrypoint goes away.
ENTRYPOINT []

# The UCRT variant, matching the CRT used by the MSYS2 UCRT64 toolchain in CI. The pinned LLVM-MinGW release also
# includes a recent mingw-w64 headers/runtime set; use its UCRT target, not the host's msvcrt-based mingw package.
ADD --checksum=sha256:5f9c6ed95b2d4bdb2869a488c5fd5857fbdabcf288a0aa3eb1da43f6a08d8ab4 \
    https://github.com/mstorsjo/llvm-mingw/releases/download/20261006/llvm-mingw-20261006-ucrt-ubuntu-22.04-x86_64.tar.xz \
    /tmp/llvm-mingw.tar.xz
RUN apt-get update \
 && apt-get install -y --no-install-recommends make xz-utils \
 && tar -xf /tmp/llvm-mingw.tar.xz -C /opt \
 && rm /tmp/llvm-mingw.tar.xz \
 && rm -rf /var/lib/apt/lists/*
ENV PATH=/opt/llvm-mingw-20261006-ucrt-ubuntu-22.04-x86_64/bin:$PATH
