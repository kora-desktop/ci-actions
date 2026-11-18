# ci-actions

Shared GitHub Actions for CI in the `kora-desktop`, `humain-os` and `playtron-os` organizations.

## git-auth

Lets a job fetch private repositories in those three orgs, with no SSH key and no bot user.

1. It gets a short-lived, read-only token for each org from the `kora-desktop-ci` GitHub App.
2. It writes a git config that sends `ssh://git@github.com/...` (with or without `:22`) and `git@github.com:...` URLs over HTTPS with the right org's token.
   - Old `playtron-os` URLs of repositories that moved, or were renamed, go to wherever each repository lives now. The list of old names is read at run time from an internal repository, so it is not in this one.
   - `https://` URLs are left alone, so the job's own remote keeps the workflow token for pushes.
   - Cargo fetches through the git CLI, so `Cargo.toml` and `Cargo.lock` need no changes.
3. It adds the config to the runner's global git config and exports its path as `GIT_AUTH_CONFIG`, for jobs that build inside a container.

```yaml
- uses: kora-desktop/ci-actions/git-auth@v1
  with:
    client-id: ${{ vars.CI_APP_CLIENT_ID }}
    private-key: ${{ secrets.CI_APP_PRIVATE_KEY }}
```

To build in Docker, mount the config as the container's system git config: `-v "$GIT_AUTH_CONFIG:/etc/gitconfig:ro"`. The file is readable only by the runner user, so run the container as that user (`--user $(id -u):$(id -g)`).

It runs on Linux and macOS runners (bash 3.2 and later). The tokens expire after an hour and are revoked when the job ends.

## goldens

Publishes the golden images a test run drew to the shared golden store and writes the job summary: before, after and difference thumbnails for every capture the change adds or alters, a link to the full report, and the captures that failed. It runs `icetron-golden publish` from the icetron commit the repository's `Cargo.lock` pins, and caches that build. Where the lock takes `icetron-golden` from a path instead (icetron itself, or a vendored icetron checkout), it builds the crate found in the checkout, cached by the crate's git tree. See icetron's `docs/goldens-store.md`.

The tests must run with `ICETRON_GOLDEN_KEEP=all` and leave their frames in `~/.cache/icetron-golden` on the runner (mount it into the build container). Run it after the tests, whether they passed or not, and give the job `id-token: write`:

```yaml
permissions:
  contents: read
  id-token: write
steps:
  # ... git-auth, then the tests with ICETRON_GOLDEN_KEEP=all
  - uses: kora-desktop/ci-actions/goldens@v1
    if: ${{ !cancelled() }}
    with:
      role-arn: ${{ vars.GOLDENS_WRITER_ROLE_ARN }}
      bucket: ${{ vars.GOLDENS_BUCKET }}
```

The store's address comes from the repository's `goldens.toml`. The base defaults to the pull request's base, or to the commit a push replaced. Pull requests from forks get no OIDC token, so they cannot publish.

## retry-notes-push

Makes semantic-release's notes push wait a moment and retry. semantic-release pushes three times within about two seconds: the release commit, the `vX` tag, then `refs/notes/semantic-release-vX`. GitHub sometimes loses that last push, which comes a second after the tag push. It answers `missing necessary objects`, `(failed)` or `fatal error in commit_refs`, and the release stops with the tag pushed but no GitHub release.

The action puts a `git` wrapper first on `PATH` for the rest of the job. For a `git push` whose last argument is a `refs/notes/` ref, the wrapper waits `delay` seconds, then pushes, doubling the wait after each failure, up to `attempts` tries. Pushing the same notes ref again is harmless. Every other git command runs once, unchanged. Add it to the job that runs semantic-release, before that step:

```yaml
- uses: kora-desktop/ci-actions/retry-notes-push@v1
```

`retry-notes-push/test.sh` reproduces the failure with a local repository whose hooks lose such a push, then shows the release completing with the wrapper.
