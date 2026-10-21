FROM node:22-trixie-slim

ARG PI_VERSION=1.3.0
ARG MYPY_VERSION=2.3.1
RUN apt-get update && apt-get install -y --no-install-recommends \
    bash ca-certificates coreutils libgc1 libssl3t64 libz1 python3 python3-venv ripgrep \
    && npm install --global @earendil-works/pi-coding-agent@${PI_VERSION} \
    && npm cache clean --force \
    && python3 -m venv /opt/typecheck \
    && /opt/typecheck/bin/pip install --no-cache-dir \
        mypy==${MYPY_VERSION} \
        mypy_extensions==1.1.0 \
        typing_extensions==4.16.0 \
        pathspec==1.1.1 \
        librt==0.16.0 \
        ast_serialize==0.13.0 \
    && ln -s /opt/typecheck/bin/mypy /usr/local/bin/mypy \
    && rm -rf /var/lib/apt/lists/* /root/.cache \
    && usermod --login agent --home /home/agent --move-home node

ENV HOME=/home/agent
ENV PATH=/workspace/bin:/usr/local/bin:/usr/bin:/bin
USER agent
WORKDIR /workspace
