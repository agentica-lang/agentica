FROM node:22-trixie-slim

ARG PI_VERSION=1.0.0
RUN apt-get update && apt-get install -y --no-install-recommends \
    bash ca-certificates coreutils libz1 python3 ripgrep \
    && npm install --global @earendil-works/pi-coding-agent@${PI_VERSION} \
    && npm cache clean --force \
    && rm -rf /var/lib/apt/lists/* \
    && usermod --login agent --home /home/agent --move-home node

ENV HOME=/home/agent
ENV PATH=/workspace/bin:/usr/local/bin:/usr/bin:/bin
USER agent
WORKDIR /workspace
