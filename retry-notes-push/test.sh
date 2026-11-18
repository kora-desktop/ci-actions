#!/usr/bin/env bash
# Runs semantic-release against a local bare repository whose hooks reject a push that brings
# objects within two seconds of the previous ref update, the way GitHub sometimes loses the notes
# push that follows the tag push. Without the wrapper the release stops with the tag pushed and
# no notes; with it the release completes. Needs node, npm and GNU date. SEMANTIC_RELEASE picks the version.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL  $*"; exit 1; }

npm install --prefix "$tmp/sr" --no-audit --no-fund --loglevel=error \
  "semantic-release@${SEMANTIC_RELEASE:-25}" @semantic-release/changelog @semantic-release/git >/dev/null

mkdir -p "$tmp/bin"
cp "$here/git" "$tmp/bin/git"
chmod +x "$tmp/bin/git"

cat >"$tmp/pre-receive" <<'EOF'
#!/usr/bin/env bash
refs=$(cut -d' ' -f3 | tr '\n' ' ')
echo "push $refs" >>"$GIT_DIR/pushes.log"
case $refs in *refs/heads/blocked*) echo "blocked ref"; exit 1 ;; esac
now=$(date +%s%3N)
last=$(cat "$GIT_DIR/last-update" 2>/dev/null || echo 0)
if [ -n "$(find "$GIT_QUARANTINE_PATH" -type f 2>/dev/null)" ] && [ $((now - last)) -lt 2000 ]; then
  echo "lost $refs" >>"$GIT_DIR/pushes.log"
  echo "simulated: push lost $((now - last)) ms after the previous one"
  exit 1
fi
EOF
cat >"$tmp/post-receive" <<'EOF'
#!/bin/sh
date +%s%3N >"$GIT_DIR/last-update"
EOF
chmod +x "$tmp/pre-receive" "$tmp/post-receive"

# new_repo <name>: a bare remote with the hooks, and a clone with one feat commit on main.
new_repo() {
  git init -q --bare -b main "$tmp/$1.git"
  cp "$tmp/pre-receive" "$tmp/post-receive" "$tmp/$1.git/hooks/"
  git init -q -b main "$tmp/$1"
  cd "$tmp/$1"
  git config user.name test && git config user.email test@example.invalid
  cat >.releaserc.json <<'EOF'
{"branches": ["main"], "plugins": ["@semantic-release/commit-analyzer",
  "@semantic-release/release-notes-generator", "@semantic-release/changelog",
  ["@semantic-release/git", {"assets": ["CHANGELOG.md"]}]]}
EOF
  git add . && git commit -q -m "feat: first"
  git remote add origin "file://$tmp/$1.git"
  git push -q origin main
  sleep 2.5
}

# release <name> <PATH prefix>: semantic-release outside any CI, the way `task release` runs it.
release() {
  env -i HOME="$tmp" PATH="$2$PATH" CI=true GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid \
    GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid \
    RETRY_NOTES_PUSH_DELAY=1 RETRY_NOTES_PUSH_ATTEMPTS=4 \
    "$tmp/sr/node_modules/.bin/semantic-release" --no-ci --repository-url "file://$tmp/$1.git"
}

has() { git --git-dir "$tmp/$1.git" rev-parse -q --verify "$2" >/dev/null; }

new_repo plain
if release plain "" >"$tmp/plain.log" 2>&1; then fail "the release passed without the wrapper"; fi
grep -q 'remote rejected.*refs/notes/semantic-release-v1.0.0' "$tmp/plain.log" || { cat "$tmp/plain.log"; fail "no notes rejection"; }
has plain refs/tags/v1.0.0 || fail "tag missing"
has plain refs/notes/semantic-release-v1.0.0 && fail "notes pushed"
echo "ok    without the wrapper: tag v1.0.0 pushed, notes push rejected, release stopped"

new_repo wrapped
release wrapped "$tmp/bin:" >"$tmp/wrapped.log" 2>&1 || { cat "$tmp/wrapped.log"; fail "the release failed with the wrapper"; }
has wrapped refs/tags/v1.0.0 || fail "tag missing"
has wrapped refs/notes/semantic-release-v1.0.0 || fail "notes missing"
grep -q 'Published release 1.0.0' "$tmp/wrapped.log" || fail "not published"
grep -q "^lost refs/notes/" "$tmp/wrapped.git/pushes.log" || fail "no notes push was lost, so the retry went untested"
echo "ok    with the wrapper: the lost notes push was retried, release published"

# Other commands pass straight through, failures and exit codes included.
n=$(grep -c 'refs/heads/blocked' "$tmp/wrapped.git/pushes.log" || true)
start=$(date +%s)
if PATH="$tmp/bin:$PATH" git push -q origin HEAD:refs/heads/blocked 2>/dev/null; then fail "blocked push passed"; fi
[ $(($(date +%s) - start)) -lt 2 ] || fail "branch push was delayed"
[ "$(grep -c 'refs/heads/blocked' "$tmp/wrapped.git/pushes.log")" -eq $((n + 1)) ] || fail "branch push was retried"
set +e
PATH="$tmp/bin:$PATH" git rev-parse --verify -q refs/heads/none >/dev/null
code=$?
set -e
[ "$code" -eq 1 ] || fail "exit code $code, expected 1"
echo "ok    other git commands run once, unchanged"
