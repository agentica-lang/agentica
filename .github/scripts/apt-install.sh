#!/usr/bin/env bash
# Some runners fail apt's DNS lookups for minutes ("Temporary failure resolving").
# Retry the update and install pair instead of failing the job.
set -euo pipefail

attempts=4
for ((try = 1; try <= attempts; try++)); do
  if sudo apt-get -o Acquire::Retries=5 update &&
    sudo apt-get -o Acquire::Retries=5 install -y --no-install-recommends "$@"; then
    exit 0
  fi
  echo "apt-install: try $try of $attempts failed" >&2
  if ((try < attempts)); then sleep 30; fi
done
exit 1
