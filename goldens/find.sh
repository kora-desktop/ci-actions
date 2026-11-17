#!/usr/bin/env bash
# Prints the base commit to compare with, fetched if the checkout lacks it, and the icetron-golden
# source and revision Cargo.lock pins, as step outputs.
set -euo pipefail

base=${BASE:-${PR_BASE:-}}
if [ -z "$base" ] && [ -n "${BEFORE:-}" ] && [ "${BEFORE//0/}" != "" ]; then
  base=$BEFORE
fi
if [ -z "$base" ]; then
  git fetch --quiet --no-tags --deepen=1 origin
  base=$(git rev-parse HEAD~1)
fi
if ! git cat-file -e "$base^{commit}" 2>/dev/null; then
  git fetch --quiet --no-tags --depth=1 origin "$base"
fi

pin=$(sed -n '/^name = "icetron-golden"$/,/^source/s/^source = "git+\([^?#]*\).*#\([0-9a-f]*\)"$/\1 \2/p' Cargo.lock)
if [ -z "$pin" ]; then
  echo "::error::Cargo.lock pins no icetron-golden from git"
  exit 1
fi
read -r source rev <<<"$pin"
{
  echo "base=$base"
  echo "source=$source"
  echo "rev=$rev"
} >>"$GITHUB_OUTPUT"
echo "base $base, icetron-golden $rev"
