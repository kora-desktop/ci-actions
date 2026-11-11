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
