#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")" && pwd)"
vendors="$root/vendors"

for d in "$vendors"/*; do
  if [ -d "$d/.git" ]; then
    name="$(basename "$d")"
    echo "==> $name"
    git -C "$d" pull --ff-only
  fi
done
