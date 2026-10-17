# Runtime only: derive from an already available Linux image and add VM runtime deps.
ARG REMOVE_SANDBOX_BASE=ubuntu:24.04
FROM ${REMOVE_SANDBOX_BASE}

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
 && apt-get install -y --no-install-recommends libgc1 python3 \
 && rm -rf /var/lib/apt/lists/*
