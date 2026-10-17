#!/bin/sh
# Portable host entry point; timeout and container cleanup are managed by Python.
set -eu
command -v python3 >/dev/null 2>&1 || {
  echo "docker-tests requires python3; refusing host fallback" >&2
  exit 1
}
exec python3 "$(dirname -- "$0")/docker_tests.py" "$@"
