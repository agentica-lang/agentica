# The Ubuntu test container: build and run the checkout (mounted read-only at /source, with disposable volumes on
# /source/build and /source/dist) against the distribution libgc and OpenSSL, so no vendored dependency is built
# and the build stays a couple of minutes. Node is the peer of the TLS, TCP, HTTP and process tests, as in CI.
# Driven by tools/docker-tests.sh (make tests DOCKER=1).
ARG TEST_BASE=ubuntu:26.04
FROM ${TEST_BASE}

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      build-essential \
      ca-certificates \
      git \
      libgc-dev \
      libssl-dev \
      nodejs \
      pkg-config \
      perl \
      python3 \
      python3-pytest \
 && rm -rf /var/lib/apt/lists/*
