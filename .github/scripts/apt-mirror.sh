#!/usr/bin/env bash
# TEMPORARY. Remove this script and its call sites when Canonical's archive
# resolves again (status.canonical.com).
#
# Why: while Canonical's servers are down, apt-get on GitHub's Ubuntu runners
# fails with "Temporary failure resolving 'archive.ubuntu.com'" (and
# security., azure.archive. and, on arm64, ports.ubuntu.com), so every Linux
# job fails at package install. This script points apt at mirrors that do not
# depend on Canonical's DNS:
#   amd64:  https://mirrors.edge.kernel.org/ubuntu/
#   others: https://mirrors.ocf.berkeley.edu/ubuntu-ports/ (arm64 is only
#           served from the ports tree, so archive URLs become this too)
#
# It rewrites the apt sources in place: etc/apt/sources.list.d/*.sources and
# *.list, etc/apt/sources.list and etc/apt/apt-mirrors.txt (the list that the
# runner's ubuntu.sources reads through `URIs: mirror+file:/etc/apt/apt-mirrors.txt`).
# It is a no-op when no file matches, and running it twice changes nothing.
#
# Usage: apt-mirror.sh [ROOT]     ROOT defaults to /, and sudo is used only then.
# Env:   APT_MIRROR_ARCH overrides `dpkg --print-architecture` (for tests).
set -euo pipefail

root="${1:-/}"
root="${root%/}"
arch="${APT_MIRROR_ARCH:-$(dpkg --print-architecture 2>/dev/null || echo amd64)}"

archive_mirror="https://mirrors.edge.kernel.org/ubuntu/"
ports_mirror="https://mirrors.ocf.berkeley.edu/ubuntu-ports/"
# The archive tree has no arm64 packages: a list that names archive URLs
# there must end up on the ports mirror.
case "$arch" in
  amd64 | i386) archive_target="$archive_mirror" ;;
  *) archive_target="$ports_mirror" ;;
esac

sudo_cmd=()
if [ "${1:-/}" = "/" ] && [ "$(id -u)" -ne 0 ]; then
  sudo_cmd=(sudo)
fi

# The trailing slash is optional (the arm64 runner writes
# `URIs: http://ports.ubuntu.com/ubuntu-ports` without it). What follows the
# path must be a slash, whitespace or the end of the line, so `/ubuntu` never
# matches the start of `/ubuntu-ports`. The inner group keeps the whitespace
# (empty for a slash or the end), because the mirrors already end in `/`:
# this way no URI gets a double slash or loses its separator.
archive_re='https?://([A-Za-z0-9-]+\.)*ubuntu\.com/ubuntu(/|([[:space:]]|$))'
ports_re='https?://ports\.ubuntu\.com/ubuntu-ports(/|([[:space:]]|$))'

shopt -s nullglob
files=()
for f in "$root"/etc/apt/sources.list.d/*.sources \
         "$root"/etc/apt/sources.list.d/*.list \
         "$root"/etc/apt/sources.list \
         "$root"/etc/apt/apt-mirrors.txt; do
  [ -f "$f" ] && files+=("$f")
done

if [ "${#files[@]}" -eq 0 ]; then
  echo "apt-mirror: no apt source files under ${root}/etc/apt, nothing to do"
  exit 0
fi

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

for f in "${files[@]}"; do
  sed -E \
    -e "s#${archive_re}#${archive_target}\\3#g" \
    -e "s#${ports_re}#${ports_mirror}\\2#g" "$f" >"$tmp"
  # Several Canonical URLs collapse into one mirror: keep the first line per
  # URL so the mirror list does not name it three times.
  if [ "$(basename "$f")" = "apt-mirrors.txt" ]; then
    awk '!seen[$1]++' "$tmp" >"$tmp.dedup"
    mv "$tmp.dedup" "$tmp"
  fi
  if ! cmp -s "$tmp" "$f"; then
    "${sudo_cmd[@]}" cp "$tmp" "$f"
    echo "apt-mirror: rewrote $f"
  fi
done

echo "apt-mirror: arch=${arch}, apt sources now point at:"
for f in "${files[@]}"; do
  grep -H -E '^(URIs:|deb(-src)? |https?://)' "$f" || true
done
