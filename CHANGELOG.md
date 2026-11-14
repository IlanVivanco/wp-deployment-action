# Changelog

## v2.0.0

### Breaking changes

- `SERVER_ID` is removed. Use `SSH_USER`. Setting `SERVER_ID` fails with that message.
- `.git/`, `.github/`, `.gitignore`, `.gitattributes`, `.deployignore`, `.env`, `.env.*` and `.DS_Store` are never uploaded, whatever `FLAGS` and `.deployignore` say. In v1 they were only skipped by the default `FLAGS`, so a custom `FLAGS` uploaded the repository's `.git` folder.

### Added

- Server files that the host or WordPress manage are never deleted, even with `--delete` or `--delete-excluded`: `wp-config.php`, `.htaccess`, `.user.ini`, `wp-content/uploads/`, `cache/`, `upgrade/`, `mu-plugins/`, `advanced-cache.php`, `object-cache.php` and `db.php`. Only the ones inside `REMOTE_PATH` apply.
- `PROTECT` input to add more server paths that are never deleted.
- The release workflow runs from `releases/vX` branches too, to publish fixes for an older major version.

## v1.2.0

### Changed

- The action runs a published image (`ghcr.io/ilanvivanco/wp-deployment-action`) instead of building the Dockerfile on every run. Each release has its own image, so the tools inside never change under a version, and runs start faster.

### Added

- A release workflow that tests the image, publishes it for amd64 and arm64, creates the `vX.Y.Z` tag and moves `vX` and `vX.Y` to it.

### Fixed

- An unreachable server fails after 60 seconds instead of waiting for the system timeout (over 2 minutes), and the error says what to check.

## v1.1.0

### Added

- `SSH_USER` input, which replaces `SERVER_ID`. `SERVER_ID` keeps working as an alias and shows a deprecation notice.

- `SERVER_TYPE: custom` to deploy to any SSH server, with the new `SSH_HOST`, `BASE_PATH` and `CACHE_COMMAND` inputs and `SSH_USER`.
- `SSH_PORT` input for every server type (defaults to 22).
- `SSH_KNOWN_HOSTS` input to check the server's host key strictly.
- `CACHE_COMMAND` input; it replaces the default cache command on Pressable and WP Engine.
- `PHP_VERSION` input to lint with PHP 8.3, 8.4 or 8.5.
- `DRY_RUN` input to preview the rsync changes without touching the server.
- `DEBUG` input for verbose SSH output.
- Outputs: `files_transferred`, `files_deleted` and `destination`.
- ShellCheck and end-to-end tests against a throwaway SSH server, and `test/compat.sh`, which checks that the server ends up exactly as with `v1` against rsync 3.1, 3.2 and 3.5 servers.
- A warning when `FLAGS` has `--delete` and `REMOTE_PATH` is empty, since that syncs against the WordPress root.
- A clear error when `SSH_PRIVATE_KEY` is not a private key, for example the `.pub` file.
- README rewritten as a step-by-step guide per host, with recipes, safety notes and troubleshooting.

### Fixed

- The README said `.deployignore` goes in the source folder; `--exclude-from` paths are relative to the repository root.

- `CACHE_CLEAR: TRUE` without `SCRIPT` failed with a shell syntax error after the files were synced.
- The deploy failed when `~/.ssh` already existed without the `ctl/` folder, for example when a previous step created it.
- A missing post-deploy `SCRIPT` now fails the step with a clear message instead of a `chmod` error.
- `SCRIPT` paths are quoted for the server's shell, so a base or remote path with spaces works and shell syntax in it is not executed. A leading `~` still expands to the SSH user's home.
- The private key no longer stays in `$HOME/.ssh` after the step; it lives in a temporary folder that is removed on exit.
- `StrictHostKeyChecking=no` accepted any host key, even a changed one. The host key is now trusted on first use (`accept-new`) or checked against `SSH_KNOWN_HOSTS`.
- A PHP lint failure now reports every broken file and the "PHP linting failed" message.

### Changed

- The image is built from `alpine:3.23` instead of `instrumentisto/rsync-ssh:latest`, so tool versions (PHP 8.4 for linting) stay fixed.
- SSH no longer runs with `-v` unless `DEBUG` is enabled.
- No `ssh-keyscan` before connecting: OpenSSH 9.8+ penalizes connections that never try to authenticate.
