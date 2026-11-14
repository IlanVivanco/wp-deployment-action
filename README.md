# WordPress Deployment Action

This GitHub Action allows you to easily deploy code directly from GitHub to a [WordPress](https://wordpress.org/) environment hosted on [Pressable](https://pressable.com/), [WP Engine](https://wpengine.com/) or any other server you can reach over SSH, by using an SSH private key and the rsync command.

By default, the action deploys the repository's root directory. However, you can optionally deploy a specific directory, such as a theme or plugin, using the `SRC_PATH` option. Similarly, if you need to deploy to a different destination directory, you can specify it using the `REMOTE_PATH` option.

You can enable cache purging with the `CACHE_CLEAR` flag and perform PHP syntax checks using the `PHP_LINT` flag. Additionally, custom commands can be executed on the server side by defining them with the `SCRIPT` option, and you can preview a deployment without changing anything with `DRY_RUN`.


## GitHub Action workflow

1. **Set up your [SSH key](#setting-up-your-ssh-key) on your server:** Ensure the SSH key required for deployment is properly set up and accessible on your server.

1. **Create a workflow file:** In the root directory of your repository, navigate to `.github/workflows/` and create a new YML file. You can name it anything you like, such as `deploy-to-prod.yml`.

1. **Add the workflow configuration:** Copy and paste the following code into your new YML file. Be sure to replace the placeholders with the appropriate values for your deployment environment. You can also specify which branches will trigger this action by editing the **branches** section of the YML file:

   **`> .github/workflows/deploy-to-prod.yml`**

   ```yml
   name: 📦 Production Deployment
   on:
      push:
         branches:
            - main
            - dev
            - 'feature/**'
      workflow_dispatch:
   env:
      SERVER_TYPE: pressable # pressable, wpengine or custom
      SERVER_ID: pressable-username # SSH username (Pressable, custom) or WP Engine environment name
      PROJECT_TYPE: theme # plugin or theme
      PROJECT_NAME: theme-name # Name of the plugin or theme
   jobs:
      build:
         name: 🚩 Deployment Job
         runs-on: ubuntu-latest
         steps:
         - name: 🚚 Getting latest code
           uses: actions/checkout@v4

         - name: 🔁 Starting Deployment
           uses: IlanVivanco/wp-deployment-action@v1
           with:
               SSH_PRIVATE_KEY: ${{ secrets.MY_SSH_KEY }}
               SERVER_ID: ${{ env.SERVER_ID }}
               SERVER_TYPE: ${{ env.SERVER_TYPE }}
               REMOTE_PATH: 'wp-content/${{ env.PROJECT_TYPE }}s/${{ env.PROJECT_NAME }}'
               FLAGS: -azvrhi --inplace --delete --delete-excluded --exclude-from=.deployignore
               SCRIPT: 'bin/post-deploy.sh'
               PHP_LINT: TRUE
               CACHE_CLEAR: TRUE
   ```

4. **Push changes to trigger the action:** After editing and saving the file, push the latest changes to your repository. The GitHub Action will automatically execute and handle the deployment process.

   ![Magic](https://media.giphy.com/media/l3V0dy1zzyjbYTQQM/giphy.gif)


## Setting up your SSH key

1. **Generate a new SSH key pair:** Create a new SSH key pair to be used as a deploy key between your GitHub repository and your server. To keep things simple, generate a key pair with a blank passphrase, resulting in an unencrypted private key. You can follow [this article](https://help.github.com/articles/generating-a-new-ssh-key-and-adding-it-to-the-ssh-agent/).

1. **Add the public SSH key:** Copy the contents of the public key (the file ending in .pub) and add it to your [Pressable](https://pressable.com/knowledgebase/connect-to-ssh-on-pressable/#connect-to-ssh-with-an-ssh-key/) or [WP Engine](https://wpengine.com/support/ssh-gateway/#Add_SSH_Key) configuration panel under the SSH keys section. On any other server, append it to `~/.ssh/authorized_keys` for the SSH user.

1. **Store the private key in GitHub:** In your GitHub repository, navigate to **`Settings > Secrets and variables > Actions`**, and create a new encrypted secret. You can name the secret whatever you like, but make sure you pass the same name when using it in the workflow.

1. **Reference the private key in your workflow YML file:** In your GitHub Action workflow file, configure the SSH private key by referencing the secret you created. If you named the secret `PRESSABLE_SSH_KEY`, your code should look like this: `SSH_PRIVATE_KEY: ${{ secrets.PRESSABLE_SSH_KEY }}`


## Custom servers

Set `SERVER_TYPE: custom` to deploy to any server you can reach over SSH, such as shared hosting. `SERVER_ID` is the SSH user, and you also set the host, the WordPress root and, if you clear the cache, the command that does it:

```yml
- name: 🔁 Deploy theme
  uses: IlanVivanco/wp-deployment-action@v1
  with:
    SERVER_TYPE: custom
    SERVER_ID: ssh-user
    SSH_HOST: example.com
    SSH_PORT: 22
    BASE_PATH: '~/www' # WordPress root on the server
    SSH_KNOWN_HOSTS: ${{ vars.SSH_KNOWN_HOSTS }}
    SSH_PRIVATE_KEY: ${{ secrets.SSH_KEY }}
    SRC_PATH: theme
    REMOTE_PATH: wp-content/themes/my-theme
    FLAGS: -azrhi --delete --exclude-from=.deployignore
    CACHE_CLEAR: TRUE
    CACHE_COMMAND: wp cache flush
```

`BASE_PATH` can start with `~`, which expands to the SSH user's home on the server. `CACHE_COMMAND` runs as is in the SSH user's shell, so you can call a specific PHP binary or WP-CLI path (for example `/usr/bin/php8.3 ~/bin/wp cache flush`) when the server's default `php` is not the one WordPress uses.

To deploy several folders to the same server, such as a theme and `mu-plugins`, add one step per folder. Leave `--delete` out of `FLAGS` for folders that also hold files that only exist on the server.

## Host keys

By default the action trusts the server's host key the first time it connects in each run, and refuses a different key for the rest of the run. To protect against a spoofed server, pass the expected keys in `SSH_KNOWN_HOSTS` and the host key is checked strictly. You can get the lines from a machine you trust with `ssh-keyscan -p 22 example.com` (for a port other than 22 the lines start with `[example.com]:2222`) and store them in a repository variable.

## Environment variables

This action requires or supports the following variables:

### Required

| Name              | Type      | Usage                                                                                                                |
| ----------------- | --------- | -------------------------------------------------------------------------------------------------------------------- |
| `SSH_PRIVATE_KEY` | _secrets_ | The private SSH key. This must be stored in GitHub Secrets and authorized on the server.                             |
| `SERVER_TYPE`     | _string_  | The type of server to deploy to: Pressable (`pressable`), WP Engine (`wpengine`) or any other SSH server (`custom`). |
| `SERVER_ID`       | _string_  | The SSH username for Pressable and custom deployments, or the install name for WP Engine deployments.                |

### Required for `custom`

| Name        | Type     | Usage                                                     |
| ----------- | -------- | --------------------------------------------------------- |
| `SSH_HOST`  | _string_ | The SSH host. Pressable and WP Engine use their own host. |
| `BASE_PATH` | _string_ | The WordPress root on the server, e.g. `~/www`.           |

### Optional

| Name              | Type     | Usage                                                                                                                                            |
| ----------------- | -------- | ------------------------------------------------------------------------------------------------------------------------------------------------ |
| `SSH_PORT`        | _string_ | The SSH port. Defaults to `22`.                                                                                                                  |
| `SSH_KNOWN_HOSTS` | _string_ | Known hosts lines for the server. When set, the host key is checked strictly. See [Host keys](#host-keys).                                       |
| `REMOTE_PATH`     | _string_ | The remote path, relative to the site root, where files should be deployed. Defaults to the site root directory.                                 |
| `SRC_PATH`        | _string_ | Local path to the source files for deployment. Defaults to the repository root.                                                                  |
| `FLAGS`           | _string_ | Rsync flags to control the file synchronization behavior. Defaults to `-azvrhi --inplace --exclude='.*'`.                                        |
| `PHP_LINT`        | _string_ | Set to `TRUE` to enable PHP linting before deployment. Defaults to `FALSE`.                                                                      |
| `PHP_VERSION`     | _string_ | PHP version used by `PHP_LINT`: `8.3`, `8.4` or `8.5`. Defaults to `8.4`. See [PHP linting](#php-linting).                                       |
| `CACHE_CLEAR`     | _string_ | Set to `TRUE` to clear cache after deployment. Defaults to `FALSE`.                                                                              |
| `CACHE_COMMAND`   | _string_ | Command that clears the cache when `CACHE_CLEAR` is `TRUE`. Required for `custom`; replaces the Pressable and WP Engine defaults.                |
| `SCRIPT`          | _string_ | Path to a script, relative to the deployed directory, to run on the remote server after deployment. It runs with `bash` from the SSH user's home. |
| `DRY_RUN`         | _string_ | Set to `TRUE` to run rsync with `--dry-run` and skip the script and the cache clear. Defaults to `FALSE`.                                       |
| `DEBUG`           | _string_ | Set to `TRUE` for verbose SSH output. Defaults to `FALSE`.                                                                                       |

The default cache commands are `wp cache flush` on Pressable, and `wp page-cache flush` plus `wp cdn-cache flush` on WP Engine.

`FLAGS`, `SCRIPT` and `CACHE_COMMAND` are passed to rsync and the server's shell as written, so only set them from trusted values, never from pull request titles, branch names or other user input.

## PHP linting

With `PHP_LINT: TRUE`, every `.php` file in `SRC_PATH` is checked with `php -l` before anything is uploaded, and the deploy stops if one fails. Set `PHP_VERSION` to the version your server runs so the check matches it. PHP 8.4 is built into the action; 8.3 and 8.5 are installed when the step runs, which adds a few seconds.

For an older PHP version, lint in a previous step and leave `PHP_LINT` off:

```yml
- uses: shivammathur/setup-php@v2
  with:
    php-version: '8.2'
- run: find theme -name '*.php' -print0 | xargs -0 -n1 php -l
```

## Outputs

| Name                | Usage                                                       |
| ------------------- | ----------------------------------------------------------- |
| `files_transferred` | Number of regular files transferred by rsync.               |
| `files_deleted`     | Number of files deleted on the server by rsync.             |
| `destination`       | The rsync destination, as `user@host:path`.                 |

With `DRY_RUN`, the counts are the files that would be transferred or deleted.

## Ignoring files

If you want to exclude certain files or directories from being deployed, you can create a `.deployignore` file in your source directory. In this file, you can specify patterns of files and directories to exclude—one pattern per line. Blank lines and lines starting with `#` will be ignored.

### Example `.deployignore` file

```bash
.*
composer*
dist
node_modules
package*
phpcs*
src
vendor
```

### Configuring rsync with `.deployignore`

To ensure the file is respected during deployment, you need to pass the appropriate rsync flags, including the `.deployignore` file, in your GitHub Action workflow. The default flags for rsync are `-azvrhi --inplace --exclude='.*'`.

When using a `.deployignore` file, make sure to include the default flags (or customize them as needed) to ensure the deployment runs smoothly. To incorporate them, you need to modify the flags like this:
`FLAGS: -azvrhi --inplace --exclude-from=.deployignore`

### Rsync option flags

You can read the full details [here](https://linux.die.net/man/1/rsync), but these are the most common ones:

| **Flag**              | **Description**                                                                                      |
| --------------------- | ---------------------------------------------------------------------------------------------------- |
| `-a` *archive*        | Enables archive mode, preserving symbolic links, permissions, timestamps, and other file attributes. |
| `-z` *compress*       | Compresses file data during transfer to speed up the process over slower network connections.        |
| `-v` *verbose*        | Enables verbose output for detailed information during execution.                                    |
| `-r` *recursive*      | Recursively copies directories and their contents.                                                   |
| `-i` *itemized*       | Provides a detailed list of changes made during synchronization.                                     |
| `--inplace`           | Updates files in place, writing directly to destination files without creating temporary copies.     |
| `--delete`            | Deletes files from the destination that no longer exist in the source.                               |
| `--delete-excluded`   | Deletes files from the destination that are excluded by an exclusion pattern.                        |
| `--exclude`           | Excludes specific files or directories from the sync, e.g., `--exclude='*.log'`.                     |
| `--exclude-from`      | Specifies a file (like `.deployignore`) containing a list of patterns to exclude.                    |
| `-h` *human-readable* | Displays file sizes and transfer statistics in human-readable formats (e.g., KB, MB, GB).            |

## Contributing

Contributions to this action are always welcome and highly encouraged.

Run the tests with Docker before opening a pull request. They build the action image, start a throwaway SSH server and deploy to it:

```bash
shellcheck entrypoint.sh test/e2e.sh test/sshd/entrypoint.sh
test/e2e.sh
```

## License & Attribution

-  Licensed as MIT &copy; [Ilán Vivanco](https://ilanvivanco.com).

-  This action was originally based on the work made by Alex Zuniga on [GitHub Action for WPE Site Deployments](https://github.com/wpengine/github-action-wpe-site-deploy).
