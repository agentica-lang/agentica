FROM debian:trixie-slim AS go
ARG GO_VERSION=1.27.4
ARG GO_SHA256=7226736c2339719cda28fbf3a54d71aa63bcefe376e98cef00034268dab24840
ADD --checksum=sha256:${GO_SHA256} https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz /go.tar.gz
RUN tar -C /usr/local -xzf /go.tar.gz

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

COPY --from=go /usr/local/go /usr/local/go
# The root file system is read-only at run time, so the build cache is warmed here for the standard packages the Go
# arm uses; Go reads a read-only cache and compiles a missing package without storing it.
ENV GOCACHE=/opt/go-cache GOPATH=/tmp/go GOFLAGS=-mod=mod GOPROXY=off GOTOOLCHAIN=local CGO_ENABLED=0
COPY <<EOF /opt/go-warm/main.go
package main

import (
	_ "bufio"
	_ "bytes"
	_ "encoding/csv"
	_ "encoding/json"
	_ "errors"
	_ "fmt"
	_ "io"
	_ "maps"
	_ "math"
	_ "net"
	_ "net/http"
	_ "os"
	_ "path/filepath"
	_ "regexp"
	_ "slices"
	_ "sort"
	_ "strconv"
	_ "strings"
	_ "time"
	_ "unicode"
	_ "unicode/utf8"
)

func main() {}
EOF
RUN ln -s /usr/local/go/bin/go /usr/local/go/bin/gofmt /usr/local/bin/ \
    && cd /opt/go-warm && printf 'module warm\n\ngo 1.27\n' > go.mod \
    && go vet . && go build -o /dev/null . \
    && chmod -R a+rX /opt/go-cache && rm -rf /opt/go-warm /tmp/go

ENV HOME=/home/agent
ENV PATH=/workspace/bin:/usr/local/bin:/usr/bin:/bin
USER agent
WORKDIR /workspace
