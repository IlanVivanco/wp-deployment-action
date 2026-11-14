# WordPress Deployment Action

Deploy a theme, plugin or whole site from GitHub to a [WordPress](https://wordpress.org/) server over SSH with rsync. It works with [Pressable](https://pressable.com/) and [WP Engine](https://wpengine.com/) out of the box, and with any other host that gives you SSH access (`custom`).

On every run the action:

1. Checks your PHP files for syntax errors, if `PHP_LINT` is on. A broken file stops the deploy before anything is uploaded.
2. Connects to the server with your SSH key.
3. Uploads the changed files with rsync.
4. Runs your post-deploy `SCRIPT`, if you set one.
5. Clears the cache, if `CACHE_CLEAR` is on.

Contents:

- [Quick start](#quick-start)
- [Recipes](#recipes)
- [Before you go live](#before-you-go-live)
- [Inputs](#inputs)
- [Outputs](#outputs)
- [Host keys](#host-keys)
- [Troubleshooting](#troubleshooting)

## Quick start

### 1. Create an SSH key for deployments

Run this on your computer. It creates `deploy_key` (private) and `deploy_key.pub` (public) with no passphrase, since GitHub can't type one.

```bash
ssh-keygen -t ed25519 -C "github-deploy" -f deploy_key -N ""
```

Use a new key just for deployments, not your personal one.

### 2. Authorize the public key on the server

Copy the contents of `deploy_key.pub` and add it on your host:

| Host      | Where to add it                                                                                                                                                          |
| --------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Pressable | MyPressable Control Panel, in the site's SFTP/SSH settings ([guide](https://pressable.com/knowledgebase/connect-to-ssh-on-pressable/#connect-to-ssh-with-an-ssh-key/)). |
| WP Engine | User Portal, under **Profile > SSH Keys** ([guide](https://wpengine.com/support/ssh-gateway/#Add_SSH_Key)).                                                              |
| Custom    | Your host's SSH keys panel, or append it to `~/.ssh/authorized_keys` of the SSH user.                                                                                    |

Check that it works before going on: `ssh -i deploy_key USER@HOST` should log you in without asking for a password.

### 3. Save the private key in GitHub

In your repository, go to **Settings > Secrets and variables > Actions > New repository secret**. Name it `SSH_PRIVATE_KEY` and paste the whole contents of `deploy_key`, including the `-----BEGIN` and `-----END` lines. Then delete `deploy_key` from your computer, or keep it somewhere safe.

### 4. Add the workflow

Create `.github/workflows/deploy.yml` in your repository and copy the example for your host. Each one deploys the repository's `theme` folder to `wp-content/themes/my-theme` on every push to `main`.

#### Pressable

`SSH_USER` is the site's SSH/SFTP username, shown in MyPressable next to the SSH connection details.

```yml
name: Deploy
on:
  push:
    branches: [main]
  workflow_dispatch:

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - uses: IlanVivanco/wp-deployment-action@v1
        with:
          SERVER_TYPE: pressable
          SSH_USER: my-site-username
          SSH_PRIVATE_KEY: ${{ secrets.SSH_PRIVATE_KEY }}
          SRC_PATH: theme
          REMOTE_PATH: wp-content/themes/my-theme
          DRY_RUN: TRUE # Remove this line once the dry run looks right
```

#### WP Engine

`SSH_USER` is the environment name, the `my-env` in `my-env.wpengine.com`: on WP Engine the SSH user is the environment itself. The action connects to `my-env@my-env.ssh.wpengine.net`.

```yml
name: Deploy
on:
  push:
    branches: [main]
  workflow_dispatch:

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - uses: IlanVivanco/wp-deployment-action@v1
        with:
          SERVER_TYPE: wpengine
          SSH_USER: my-env
          SSH_PRIVATE_KEY: ${{ secrets.SSH_PRIVATE_KEY }}
          SRC_PATH: theme
          REMOTE_PATH: wp-content/themes/my-theme
          DRY_RUN: TRUE # Remove this line once the dry run looks right
```

#### Custom (any SSH server)

A custom server needs three things that Pressable and WP Engine already know:

- `SSH_HOST`: the server you connect to, e.g. `example.com`.
- `SSH_USER`: the SSH username.
- `BASE_PATH`: the folder where WordPress is installed, the one that contains `wp-config.php`. A leading `~` means the SSH user's home folder, e.g. `~/www` or `~/public_html`.

To find `BASE_PATH`, log in with `ssh -i deploy_key USER@HOST` and look for `wp-config.php`. If `pwd` prints `/home/user` and WordPress is in `/home/user/www`, use `~/www`.

```yml
name: Deploy
on:
  push:
    branches: [main]
  workflow_dispatch:

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - uses: IlanVivanco/wp-deployment-action@v1
        with:
          SERVER_TYPE: custom
          SSH_HOST: example.com
          SSH_USER: ssh-user
          BASE_PATH: '~/www'
          SSH_PRIVATE_KEY: ${{ secrets.SSH_PRIVATE_KEY }}
          SRC_PATH: theme
          REMOTE_PATH: wp-content/themes/my-theme
          DRY_RUN: TRUE # Remove this line once the dry run looks right
```

If your host uses a port other than 22, add `SSH_PORT`.

### 5. Run it

Push to `main`, or run the workflow by hand from the **Actions** tab. With `DRY_RUN: TRUE` the log lists the files that would be uploaded, and nothing changes on the server. When the list looks right, remove the `DRY_RUN` line and push again.

## Recipes

### Theme or plugin

Point `SRC_PATH` at the folder in your repository, and `REMOTE_PATH` at the folder on the server, relative to the WordPress root:

| You deploy       | `SRC_PATH`        | `REMOTE_PATH`                  |
| ---------------- | ----------------- | ------------------------------ |
| A theme          | `theme`           | `wp-content/themes/my-theme`   |
| A plugin         | `plugin`          | `wp-content/plugins/my-plugin` |
| Must-use plugins | `mu-plugins`      | `wp-content/mu-plugins`        |
| The whole site   | `.`               | _(leave it out)_               |

Use `SRC_PATH: .` when the repository itself is the theme or plugin.

### Several folders to the same server

Add one step per folder. Each step is a separate upload, so each can have its own flags:

```yml
      - name: Deploy theme
        uses: IlanVivanco/wp-deployment-action@v1
        with:
          SERVER_TYPE: custom
          SSH_HOST: example.com
          SSH_USER: ssh-user
          BASE_PATH: '~/www'
          SSH_PRIVATE_KEY: ${{ secrets.SSH_PRIVATE_KEY }}
          SRC_PATH: theme
          REMOTE_PATH: wp-content/themes/my-theme
          FLAGS: -azvrhi --inplace --delete --exclude='.*'

      - name: Deploy mu-plugins
        uses: IlanVivanco/wp-deployment-action@v1
        with:
          SERVER_TYPE: custom
          SSH_HOST: example.com
          SSH_USER: ssh-user
          BASE_PATH: '~/www'
          SSH_PRIVATE_KEY: ${{ secrets.SSH_PRIVATE_KEY }}
          SRC_PATH: mu-plugins
          REMOTE_PATH: wp-content/mu-plugins
          CACHE_CLEAR: TRUE
          CACHE_COMMAND: wp cache flush
```

The second step has no `--delete`, because `wp-content/mu-plugins` often also holds files that your host or other plugins put there. Clear the cache only in the last step.

### Remove files you deleted from the repository

By default the action only adds and updates files. To also remove files from the server that are no longer in `SRC_PATH`, add `--delete` to `FLAGS`. Read [Before you go live](#before-you-go-live) first.

```yml
          FLAGS: -azvrhi --inplace --delete --exclude='.*'
```

### Skip files with `.deployignore`

List what should not be uploaded (build sources, `node_modules`, config files) in a `.deployignore` file, one pattern per line. Blank lines and lines starting with `#` are ignored. Patterns are relative to `SRC_PATH`.

```bash
.*
composer*
node_modules
package*
phpcs*
src
vendor
```

Then pass it in `FLAGS`. The path to the file is relative to the **repository root**, not to `SRC_PATH`:

```yml
          SRC_PATH: theme
          FLAGS: -azvrhi --inplace --exclude-from=theme/.deployignore
```

Keep the `.*` line. Your `FLAGS` replace the default ones, including the default `--exclude='.*'`, so without that line `.git` and other hidden files get uploaded.

### Clear the cache

Set `CACHE_CLEAR: TRUE`. What runs depends on the host:

| Host      | Command                                                                                          |
| --------- | ------------------------------------------------------------------------------------------------ |
| Pressable | `wp --skip-plugins --skip-themes cache flush`                                                    |
| WP Engine | `wp --skip-plugins --skip-themes page-cache flush`, then `wp --skip-plugins --skip-themes cdn-cache flush` |
| Custom    | Whatever you set in `CACHE_COMMAND`, which is required with `custom`.                            |

If you set `CACHE_COMMAND` on Pressable or WP Engine, it runs instead of the default. It runs in the SSH user's shell, from their home folder, so it can be any command. For example, if the server's default `php` is not the version WordPress uses, call WP-CLI with the right one: `/usr/bin/php8.3 /usr/local/bin/wp cache flush --path=www`.

### Run a script after deploying

Set `SCRIPT` to the path of a script **inside `SRC_PATH`**, such as `bin/post-deploy.sh`. After the upload, the action runs it on the server with `bash`, from the SSH user's home folder. If the script fails, the step fails.

```yml
          SRC_PATH: theme
          REMOTE_PATH: wp-content/themes/my-theme
          SCRIPT: bin/post-deploy.sh # Runs wp-content/themes/my-theme/bin/post-deploy.sh on the server
```

### Check PHP syntax before uploading

Set `PHP_LINT: TRUE`. Every `.php` file in `SRC_PATH` is checked with `php -l`, and if one fails the deploy stops before anything is uploaded. Set `PHP_VERSION` to the version your server runs: `8.3`, `8.4` (the default) or `8.5`.

For older PHP versions, check in a previous step and leave `PHP_LINT` off:

```yml
      - uses: shivammathur/setup-php@v2
        with:
          php-version: '8.2'
      - run: find theme -name '*.php' -print0 | xargs -0 -n1 php -l
```

### Use the results in later steps

Give the step an `id` and read its [outputs](#outputs):

```yml
      - id: deploy
        uses: IlanVivanco/wp-deployment-action@v1
        with:
          # ...
      - run: echo "Uploaded ${{ steps.deploy.outputs.files_transferred }} files"
```

## Before you go live

- **Always try a dry run first.** `DRY_RUN: TRUE` shows exactly what would be uploaded and deleted, without touching the server.
- **Be careful with `--delete`.** It removes everything in the destination folder that is not in `SRC_PATH`. If `REMOTE_PATH` is empty, the destination is the WordPress root, so a theme repository deployed with `--delete` would wipe WordPress core, `wp-config.php` and your uploads. Only use `--delete` when `REMOTE_PATH` points to a folder your repository fully owns, like your theme. The action shows a warning when it sees `--delete` with an empty `REMOTE_PATH`.
- **`FLAGS` replaces the default flags, it doesn't add to them.** Start from the default, `-azvrhi --inplace --exclude='.*'`, and add what you need.
- **Deploy to production only from the branch you release from**, like `main`. Don't deploy to production from `feature/**` branches.
- **Only put values you control in `FLAGS`, `SCRIPT` and `CACHE_COMMAND`.** They run as written on the server, so never build them from branch names, pull request titles or other text someone else can change.
- **Pin the server's host key** with `SSH_KNOWN_HOSTS`. See [Host keys](#host-keys).

## Inputs

`TRUE`/`FALSE` inputs also accept `true`, `false`, `1` and `yes`.

### Connection

| Name              | Required      | Description                                                                                                            |
| ----------------- | ------------- | ---------------------------------------------------------------------------------------------------------------------- |
| `SERVER_TYPE`     | Yes           | `pressable`, `wpengine` or `custom`.                                                                                   |
| `SSH_USER`        | Yes           | Pressable and custom: the SSH username. WP Engine: the environment name.                                               |
| `SSH_PRIVATE_KEY` | Yes           | The private key, from a secret: `${{ secrets.SSH_PRIVATE_KEY }}`.                                                      |
| `SSH_HOST`        | With `custom` | The server to connect to, e.g. `example.com`. Ignored on Pressable and WP Engine.                                      |
| `BASE_PATH`       | With `custom` | The WordPress root on the server, e.g. `~/www`. Ignored on Pressable (`~/htdocs`) and WP Engine (`sites/<SSH_USER>`). |
| `SSH_PORT`        | No            | The SSH port. Default `22`.                                                                                            |
| `SSH_KNOWN_HOSTS` | No            | The server's host key lines, so the action refuses to connect to an impostor. See [Host keys](#host-keys).             |

### What to deploy

| Name          | Required | Description                                                                                                                          |
| ------------- | -------- | ------------------------------------------------------------------------------------------------------------------------------------ |
| `SRC_PATH`    | No       | Folder in the repository to upload. Default `.`, the whole repository.                                                               |
| `REMOTE_PATH` | No       | Folder on the server, relative to the WordPress root, e.g. `wp-content/themes/my-theme`. Default: the WordPress root.                |
| `FLAGS`       | No       | rsync flags. Default `-azvrhi --inplace --exclude='.*'`. Setting it replaces the default. See [rsync flags](#rsync-flags).            |
| `DRY_RUN`     | No       | `TRUE` to only show what would change. rsync runs with `--dry-run`, and `SCRIPT` and the cache clear are skipped. Default `FALSE`.   |

### Checks and after the deploy

| Name            | Required                        | Description                                                                                                                  |
| --------------- | ------------------------------- | ---------------------------------------------------------------------------------------------------------------------------- |
| `PHP_LINT`      | No                              | `TRUE` to check PHP syntax before uploading. Default `FALSE`.                                                                |
| `PHP_VERSION`   | No                              | PHP version for `PHP_LINT`: `8.3`, `8.4` or `8.5`. Default `8.4`.                                                            |
| `SCRIPT`        | No                              | Script inside `SRC_PATH` to run on the server after the upload, e.g. `bin/post-deploy.sh`.                                   |
| `CACHE_CLEAR`   | No                              | `TRUE` to clear the cache after the upload. Default `FALSE`.                                                                 |
| `CACHE_COMMAND` | With `custom` and `CACHE_CLEAR` | Command that clears the cache. On Pressable and WP Engine it runs instead of the default. See [Clear the cache](#clear-the-cache). |
| `DEBUG`         | No                              | `TRUE` for detailed SSH logs, useful when the connection fails. Default `FALSE`.                                             |

### Renamed inputs

`SERVER_ID` is now `SSH_USER`. Workflows that still use `SERVER_ID` keep working and show a notice; rename it when you next edit the workflow.

## Outputs

| Name                | Description                                |
| ------------------- | ------------------------------------------ |
| `files_transferred` | Number of files uploaded.                  |
| `files_deleted`     | Number of files deleted on the server.     |
| `destination`       | Where the files went, as `user@host:path`. |

With `DRY_RUN`, the counts are the files that would be uploaded or deleted.

## Host keys

The host key is how SSH knows it is talking to your real server and not an impostor.

Without `SSH_KNOWN_HOSTS`, the action trusts whatever key the server presents on the first connection of each run. That is convenient, but it can't detect an impostor. To check the key, save it once:

1. From a computer you trust, run `ssh-keyscan example.com` (add `-p 2222` if the port isn't 22).
2. Copy the lines it prints into a repository variable (**Settings > Secrets and variables > Actions > Variables**), for example `SSH_KNOWN_HOSTS`.
3. Pass it to the action: `SSH_KNOWN_HOSTS: ${{ vars.SSH_KNOWN_HOSTS }}`.

From then on, the deploy fails with `Host key verification failed` if the server's key changes. If your host changed it on purpose, scan it again and update the variable.

## Troubleshooting

| Error in the log                                       | What to check                                                                                                                                          |
| ------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `SSH_PRIVATE_KEY doesn't look like a private key`     | The secret holds the `.pub` file or only part of the key. Paste the whole `deploy_key` file, including the `-----BEGIN` and `-----END` lines. |
| `Permission denied (publickey)`                        | The public key is not authorized for `SSH_USER` on the server, or the secret doesn't hold the matching private key. Test it with `ssh -i deploy_key USER@HOST`. |
| `Could not connect to ...`                             | Check `SSH_HOST`, `SSH_PORT` and `SSH_USER`, and that your host doesn't block GitHub's servers. Set `DEBUG: TRUE` for details.                       |
| `Host key verification failed`                         | The server's key doesn't match `SSH_KNOWN_HOSTS`. See [Host keys](#host-keys).                                                                         |
| `SSH_HOST is required` or `BASE_PATH is required`      | `SERVER_TYPE` is `custom` and that input is missing.                                                                                                   |
| `CACHE_CLEAR is enabled but there is no cache command` | With `custom`, `CACHE_CLEAR: TRUE` needs `CACHE_COMMAND`.                                                                                              |
| `rsync: mkdir ... failed: No such file or directory`   | A parent folder of `REMOTE_PATH` doesn't exist on the server, and rsync only creates the last one. Check `BASE_PATH` and `REMOTE_PATH`.               |
| `Post-deploy script not found`                         | `SCRIPT` must be a path inside `SRC_PATH`, and the file must be uploaded. Check that `.deployignore` doesn't skip it.                                  |
| `PHP linting failed`                                   | The lines above show the file and the error. If the code works on the server, check `PHP_VERSION`.                                                    |
| `SRC_PATH '...' is not a directory`                    | The folder doesn't exist in the repository, or the workflow is missing `actions/checkout` before this step.                                           |

## rsync flags

The most common ones. See the [rsync manual](https://linux.die.net/man/1/rsync) for the rest.

| Flag                | What it does                                                                                               |
| ------------------- | ---------------------------------------------------------------------------------------------------------- |
| `-a`                | Archive mode: copies folders recursively and keeps links, permissions and timestamps.                     |
| `-z`                | Compresses data during the transfer.                                                                       |
| `-v`                | Verbose output.                                                                                            |
| `-r`                | Copies folders recursively. Already included in `-a`.                                                      |
| `-h`                | Human-readable sizes, like KB and MB.                                                                      |
| `-i`                | Lists each changed file and what changed.                                                                  |
| `--inplace`         | Writes directly to the files on the server instead of temporary copies.                                    |
| `--delete`          | Deletes files on the server that are not in `SRC_PATH`. See [Before you go live](#before-you-go-live).     |
| `--delete-excluded` | Also deletes files on the server that match an exclude pattern.                                            |
| `--exclude`         | Skips files matching a pattern, e.g. `--exclude='*.log'`.                                                  |
| `--exclude-from`    | Skips the patterns listed in a file, like `.deployignore`.                                                 |

The action always adds `--chmod=D775,F664`, so folders end up with `775` permissions and files with `664`.

## Contributing

Contributions are welcome. Before opening a pull request, run the tests with Docker. They build the action image, start a throwaway SSH server and deploy to it:

```bash
shellcheck entrypoint.sh test/e2e.sh test/compat.sh test/sshd/entrypoint.sh
test/e2e.sh
test/compat.sh # Same server result as v1.0.0, against several rsync versions
```

## License & Attribution

- Licensed as MIT &copy; [Ilán Vivanco](https://ilanvivanco.com).
- Originally based on [GitHub Action for WPE Site Deployments](https://github.com/wpengine/github-action-wpe-site-deploy) by Alex Zuniga.
