#!/usr/bin/env bash
# Prints the base commit to compare with, fetched if the checkout lacks it, and the icetron-golden
# source and revision Cargo.lock pins, as step outputs. When the lock takes icetron-golden from a
# path (icetron itself, or a vendored checkout), it prints that crate's directory and its tree.
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

# The icetron-golden entry's lines up to the blank line that ends it; a path crate has no source.
entry=$(sed -n '/^name = "icetron-golden"$/,/^$/p' Cargo.lock)
if [ -z "$entry" ]; then
  echo "::error::Cargo.lock has no icetron-golden"
  exit 1
fi
path=
pin=$(sed -n 's/^source = "git+\([^?#]*\).*#\([0-9a-f]*\)"$/\1 \2/p' <<<"$entry")
if [ -n "$pin" ]; then
  read -r source rev <<<"$pin"
elif grep -q '^source = ' <<<"$entry"; then
  echo "::error::Cargo.lock takes icetron-golden from neither git nor a path"
  exit 1
else
  manifest=$(find . \( -name target -o -name .cache -o -name .git \) -prune -o \
    -path '*/icetron-golden/Cargo.toml' -print | head -1)
  if [ -z "$manifest" ]; then
    echo "::error::Cargo.lock takes icetron-golden from a path, but no icetron-golden crate is checked out"
    exit 1
  fi
  path=$(cd "$(dirname "$manifest")" && pwd)
  source=$path
  # The crate's tree in whichever repository holds it, so the cached build follows its source.
  rev=tree-$(git -C "$path" rev-parse HEAD:./)
fi
{
  echo "base=$base"
  echo "source=$source"
  echo "rev=$rev"
  echo "path=$path"
} >>"$GITHUB_OUTPUT"
echo "base $base, icetron-golden $source $rev"
