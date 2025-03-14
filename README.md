# WordPress Deployment Action

This GitHub Action allows you to easily deploy code directly from GitHub to a [WordPress](https://wordpress.org/) environment hosted on [Pressable](https://pressable.com/) or [WP Engine](https://wpengine.com/) by using an SSH private key and the rsync command.

By default, the action deploys the repository's root directory. However, you can optionally deploy a specific directory, such as a theme or plugin, using the `SRC_PATH` option. Similarly, if you need to deploy to a different destination directory, you can specify it using the `REMOTE_PATH` option.

You can enable cache purging with the `CACHE_CLEAR` flag and perform PHP syntax checks using the `PHP_LINT` flag. Additionally, custom commands can be executed on the server side by defining them with the `SCRIPT` option.


## GitHub Action workflow

1. **Set up your [SSH key](#setting-up-your-ssh-key) on your server:** Ensure the SSH key required for deployment is properly set up and accessible on your server.

1. **Create a workflow file:** In the root directory of your repository, navigate to `.github/workflows/` and create a new YML file. You can name it anything you like, such as `deploy-to-prod.yml`.

1. **Add the workflow configuration:** Copy and paste the following code into your new YML file. Be sure to replace the placeholders with the appropriate values for your deployment environment. You can also specify which branches will trigger this action by editing the **branches** section of the YML file. Check the [examples section](#implementation-examples) for more details.

1. **Push changes to trigger the action:** After editing and saving the file, push the latest changes to your repository. The GitHub Action will automatically execute and handle the deployment process.

   ![Magic](https://media.giphy.com/media/l3V0dy1zzyjbYTQQM/giphy.gif)


## Setting up your SSH key

1. **Generate a new SSH key pair:** Create a new SSH key pair to be used as a deploy key between your GitHub repository and Pressable/WP Engine. To keep things simple, generate a key pair with a blank passphrase, resulting in an unencrypted private key. You can do this with the following [this article](https://help.github.com/articles/generating-a-new-ssh-key-and-adding-it-to-the-ssh-agent/).

1. **Add the public SSH key:** Copy the contents of the public key (the file ending in .pub) and add it to your [Pressable](https://pressable.com/knowledgebase/connect-to-ssh-on-pressable/#connect-to-ssh-with-an-ssh-key/) or [WP Engine](https://wpengine.com/support/ssh-gateway/#Add_SSH_Key) configuration panel under the SSH keys section.

1. **Store the private key in GitHub:** In your GitHub repository, navigate to **`Settings > Secrets and variables > Actions`**, and create a new encrypted secret. You can name the secret whatever you like, but make sure you pass the same name when using it in the workflow.

1. **Reference the private key in your workflow YML file:** In your GitHub Action workflow file, configure the SSH private key by referencing the secret you created. If you named the secret `PRESSABLE_SSH_KEY`, your code should look like this: `SSH_PRIVATE_KEY: ${{ secrets.PRESSABLE_SSH_KEY }}`


## Environment variables

This action requires or supports the following variables:

### Required

| Name              | Type      | Usage                                                                                                                         |
| ----------------- | --------- | ----------------------------------------------------------------------------------------------------------------------------- |
| `SSH_PRIVATE_KEY` | _secrets_ | The private SSH key. This must be stored in GitHub Secrets and authorized on your server.                                     |
| `SERVER_TYPE`     | _string_  | The type of server to deploy to. Use 'pressable' or 'wpengine' for quick plug-and-play or 'custom' for other SSH connections. |
| `SERVER_ID`       | _string_  | The SSH username for Pressable deployments or the install name for WP Engine deployments. Not used in custom mode.            |
| `SSH_USER`        | _string_  | The SSH username. Only used when SERVER_TYPE is 'custom'.                                                                     |
| `SSH_HOST`        | _string_  | The SSH hostname. Only used when SERVER_TYPE is 'custom'.                                                                     |
| `SSH_DEST`        | _string_  | The full destination directory. Only used when SERVER_TYPE is 'custom'.                                                       |

### Optional

| Name          | Type     | Usage                                                                                                     |
| ------------- | -------- | --------------------------------------------------------------------------------------------------------- |
| `REMOTE_PATH` | _string_ | The remote path on the server where files should be deployed. Defaults to the site root directory.        |
| `SRC_PATH`    | _string_ | Local path to the source files for deployment. Defaults to the repository root.                           |
| `FLAGS`       | _string_ | Rsync flags to control the file synchronization behavior. Defaults to `-azvrhi --inplace --exclude='.*'`. |
| `PHP_LINT`    | _string_ | Set to `TRUE` to enable PHP linting before deployment. Defaults to `FALSE`.                               |
| `CACHE_CLEAR` | _string_ | Set to `TRUE` to clear cache after deployment. Defaults to `FALSE`.                                       |
| `SCRIPT`      | _string_ | Custom script to run on the remote server after deployment.                                               |


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

## Implementation Examples

### Deploying Theme to Pressable
Create a workflow file (for example `.github/workflows/prod-to-pressable.yml`) with:

   ```yml
   name: 📦 Production Deployment
   on:
      push:
         branches:
            - main
      workflow_dispatch:
   env:
      SERVER_TYPE: pressable # pressable or wpengine
      SERVER_ID: pressable-username # Pressable SFTP username or WP Engine environment name
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

## Contributing

Contributions to this action are always welcome and highly encouraged.

## License & Attribution

-  Licensed as MIT &copy; [Ilán Vivanco](https://ilanvivanco.com).

-  This action was originally based on the work made by Alex Zuniga on [GitHub Action for WPE Site Deployments](https://github.com/wpengine/github-action-wpe-site-deploy).
