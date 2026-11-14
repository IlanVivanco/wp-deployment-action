#!/bin/bash
# Assertions are eval-ed strings, so single quotes are intended
# shellcheck disable=SC2016,SC2034
# End-to-end tests: runs the action image against a throwaway SSH server.
# Usage: test/e2e.sh (needs Docker). KEEP=1 leaves the server and temp files for debugging.
# TEST_IMAGE=<image> tests an image that is already built instead of the working tree.
set -eo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
NET="wpda-e2e-$$"
SRV="wpda-e2e-srv-$$"
ACTION_IMAGE="${TEST_IMAGE:-wpda-e2e-action}"
SERVER_IMAGE="wpda-e2e-sshd"
PASSED=0
FAILED=0

cleanup() {
	docker rm -f "$SRV" >/dev/null 2>&1 || true
	docker network rm "$NET" >/dev/null 2>&1 || true
	docker run --rm -v "$WORK:/w" alpine:3.23 rm -rf /w/home >/dev/null 2>&1 || true
	rm -rf "$WORK"
}
trap cleanup EXIT
[ -n "$KEEP" ] && trap - EXIT

pass() { PASSED=$((PASSED + 1)); echo "  ✅ $1"; }
failure() { FAILED=$((FAILED + 1)); echo "  ❌ $1"; }
check() { if eval "$2"; then pass "$1"; else failure "$1"; fi; }

# Run a shell command on the server as the deploy user
srv() { docker exec -u deploy "$SRV" bash -c "$1"; }

# Run the action with the given env vars; output goes to $WORK/out.log
run_action() {
	: >"$WORK/ws/github_output"
	set +e
	docker run --rm --network "$NET" \
		-e HOME=/github/home -v "$WORK/home:/github/home" \
		-v "$WORK/ws:/github/workspace" -w /github/workspace \
		-e GITHUB_OUTPUT=/github/workspace/github_output \
		-e SSH_PRIVATE_KEY="$(cat "$WORK/key")" -e SSH_USER=deploy \
		"$@" "$ACTION_IMAGE" >"$WORK/out.log" 2>&1
	STATUS=$?
	set -e
}

show_log_on_failure() { [ "$FAILED" -eq "$1" ] || sed 's/^/      | /' "$WORK/out.log"; }

echo "Building images..."
[ -n "$TEST_IMAGE" ] || docker build -q -t "$ACTION_IMAGE" "$ROOT" >/dev/null
docker build -q -t "$SERVER_IMAGE" "$ROOT/test/sshd" >/dev/null

ssh-keygen -q -t ed25519 -N '' -f "$WORK/key"
docker network create "$NET" >/dev/null
docker run -d --name "$SRV" --network "$NET" \
	--network-alias ssh.pressable.com \
	--network-alias deploy.ssh.wpengine.net \
	--network-alias custom.test \
	-e AUTHORIZED_KEY="$(cat "$WORK/key.pub")" "$SERVER_IMAGE" >/dev/null
for _ in $(seq 20); do docker exec "$SRV" sh -c 'nc -z 127.0.0.1 2222' 2>/dev/null && break; sleep 0.5; done
srv 'mkdir -p ~/htdocs ~/sites/deploy/wp-content/plugins ~/www/wp-content/themes/my-theme ~/www/wp-content/mu-plugins'
KNOWN_HOSTS="$(docker run --rm --network "$NET" --entrypoint ssh-keyscan "$ACTION_IMAGE" -p 2222 custom.test 2>/dev/null)"

mkdir -p "$WORK/home" "$WORK/ws/theme/inc" "$WORK/ws/mu-plugins" "$WORK/ws/bad" "$WORK/ws/bin" \
	"$WORK/ws/site/.git" "$WORK/ws/site/.github" "$WORK/ws/site/wp-content/themes/t"
echo '<?php // theme' >"$WORK/ws/theme/style.php"
echo '<?php // inc' >"$WORK/ws/theme/inc/a.php"
echo '<?php // mu' >"$WORK/ws/mu-plugins/my-mu-plugin.php"
echo '<?php echo 1' >"$WORK/ws/bad/broken.php"
# A whole site, with files that must never be uploaded
echo '<?php // index' >"$WORK/ws/site/index.php"
echo '<?php // theme' >"$WORK/ws/site/wp-content/themes/t/style.php"
echo 'ref: refs/heads/main' >"$WORK/ws/site/.git/HEAD"
echo 'name: ci' >"$WORK/ws/site/.github/ci.yml"
echo 'SECRET=1' >"$WORK/ws/site/.env"
echo 'SECRET=1' >"$WORK/ws/site/wp-content/themes/t/.env.local"
# Re-executes itself, so it needs the executable bit
printf '%s\n' '[ "$1" = child ] || exec "$0" child' 'touch ~/script-ran' >"$WORK/ws/bin/post.sh"

echo "Pressable: cache clear without SCRIPT"
f=$FAILED
run_action -e SERVER_TYPE=pressable -e SRC_PATH=theme -e CACHE_CLEAR=TRUE
check "exits 0" '[ "$STATUS" -eq 0 ]'
check "files land in ~/htdocs" 'srv "test -f ~/htdocs/inc/a.php"'
check "runs the default cache command" 'srv "grep -qx -- \"--skip-plugins --skip-themes cache flush\" ~/wp.log"'
check "sets the destination output" 'grep -qx "destination=deploy@ssh.pressable.com:~/htdocs/" "$WORK/ws/github_output"'
show_log_on_failure "$f"

echo "Pressable: ~/.ssh already exists, second run in the same job"
f=$FAILED
mkdir -p "$WORK/home/.ssh"
run_action -e SERVER_TYPE=PRESSABLE -e SRC_PATH=theme
check "exits 0" '[ "$STATUS" -eq 0 ]'
check "leaves no key behind in HOME" '! docker run --rm -v "$WORK/home:/h" alpine:3.23 sh -c "ls /h/.ssh/deploy_key" >/dev/null 2>&1'
show_log_on_failure "$f"

echo "WP Engine: default cache commands and SCRIPT"
f=$FAILED
srv ': >~/wp.log'
run_action -e SERVER_TYPE=wpengine -e SRC_PATH=. -e REMOTE_PATH=wp-content/plugins/x \
	-e "FLAGS=-azrh --exclude=github_output --exclude=bad --exclude=site" -e CACHE_CLEAR=true -e SCRIPT=bin/post.sh
check "exits 0" '[ "$STATUS" -eq 0 ]'
check "files land in sites/<id>" 'srv "test -f ~/sites/deploy/wp-content/plugins/x/theme/style.php"'
check "runs the script, executable" 'srv "test -f ~/script-ran"'
check "flushes page and CDN cache" 'srv "grep -q page-cache ~/wp.log && grep -q cdn-cache ~/wp.log"'
show_log_on_failure "$f"

echo "WP Engine: missing SCRIPT fails clearly"
f=$FAILED
run_action -e SERVER_TYPE=wpengine -e SRC_PATH=theme -e SCRIPT=nope.sh
check "exits non-zero" '[ "$STATUS" -ne 0 ]'
check "says the script was not found" 'grep -q "Post-deploy script not found" "$WORK/out.log"'
show_log_on_failure "$f"

echo "Custom: theme with --delete, port 2222, strict host key, custom cache command"
f=$FAILED
srv ': >~/wp.log; touch ~/www/wp-content/themes/my-theme/stale.php'
run_action -e SERVER_TYPE=custom -e SSH_HOST=custom.test -e SSH_PORT=2222 -e "BASE_PATH=~/www" \
	-e SSH_KNOWN_HOSTS="$KNOWN_HOSTS" -e SRC_PATH=theme -e REMOTE_PATH=wp-content/themes/my-theme \
	-e "FLAGS=-azrhi --delete --exclude='.*'" -e CACHE_CLEAR=TRUE \
	-e "CACHE_COMMAND=wp eval 'do_action(\"purge_page_cache\", true);'"
check "exits 0" '[ "$STATUS" -eq 0 ]'
check "files land in BASE_PATH/REMOTE_PATH" 'srv "test -f ~/www/wp-content/themes/my-theme/inc/a.php"'
check "--delete removes stale files" '! srv "test -e ~/www/wp-content/themes/my-theme/stale.php"'
check "uses strict host key checking" 'grep -q "strict (SSH_KNOWN_HOSTS)" "$WORK/out.log"'
check "passes the cache command verbatim" "srv 'grep -qxF -- \"eval do_action(\\\"purge_page_cache\\\", true);\" ~/wp.log'"
check "sets files_transferred" 'grep -qx "files_transferred=2" "$WORK/ws/github_output"'
check "sets files_deleted" 'grep -qx "files_deleted=1" "$WORK/ws/github_output"'
show_log_on_failure "$f"

echo "Custom: mu-plugins without --delete keeps server-only files"
f=$FAILED
srv 'touch ~/www/wp-content/mu-plugins/server-only.php'
run_action -e SERVER_TYPE=custom -e SSH_HOST=custom.test -e SSH_PORT=2222 -e "BASE_PATH=~/www/" \
	-e SRC_PATH=mu-plugins -e REMOTE_PATH=wp-content/mu-plugins
check "exits 0" '[ "$STATUS" -eq 0 ]'
check "deploys the mu-plugin" 'srv "test -f ~/www/wp-content/mu-plugins/my-mu-plugin.php"'
check "keeps files that only exist on the server" 'srv "test -f ~/www/wp-content/mu-plugins/server-only.php"'
show_log_on_failure "$f"

echo "Custom: BASE_PATH with spaces and shell syntax stays literal"
f=$FAILED
srv 'rm -f ~/script-ran ~/INJECTED; mkdir -p ~/"site root" ~/"\$(touch ~/INJECTED)x"'
run_action -e SERVER_TYPE=custom -e SSH_HOST=custom.test -e SSH_PORT=2222 -e "BASE_PATH=~/site root" \
	-e "FLAGS=-azrh --exclude=github_output --exclude=bad --exclude=site" -e SCRIPT=bin/post.sh
check "exits 0" '[ "$STATUS" -eq 0 ]'
check "deploys under the path with a space" 'srv "test -f ~/\"site root\"/bin/post.sh"'
check "runs the script there" 'srv "test -f ~/script-ran"'
run_action -e SERVER_TYPE=custom -e SSH_HOST=custom.test -e SSH_PORT=2222 -e 'BASE_PATH=~/$(touch ~/INJECTED)x' \
	-e "FLAGS=-azrh --exclude=github_output --exclude=bad --exclude=site" -e SCRIPT=bin/post.sh
check "exits 0" '[ "$STATUS" -eq 0 ]'
check "does not run command substitutions" '! srv "test -e ~/INJECTED"'
show_log_on_failure "$f"

echo "Custom: absolute BASE_PATH and a non-default port"
f=$FAILED
srv 'rm -f ~/script-ran; mkdir -p ~/abs/public/wp-content/themes'
run_action -e SERVER_TYPE=custom -e SSH_HOST=custom.test -e SSH_PORT=2222 -e BASE_PATH=/home/deploy/abs/public \
	-e SRC_PATH=. -e REMOTE_PATH=wp-content/themes/my-theme \
	-e "FLAGS=-azrh --exclude=github_output --exclude=bad --exclude=site" -e SCRIPT=bin/post.sh
check "exits 0" '[ "$STATUS" -eq 0 ]'
check "files land under the absolute path" 'srv "test -f ~/abs/public/wp-content/themes/my-theme/theme/style.php"'
check "runs the script there" 'srv "test -f ~/script-ran"'
show_log_on_failure "$f"

echo "Custom: DRY_RUN changes nothing"
f=$FAILED
srv ': >~/wp.log; rm -rf ~/www/wp-content/themes/my-theme/*'
run_action -e SERVER_TYPE=custom -e SSH_HOST=custom.test -e SSH_PORT=2222 -e "BASE_PATH=~/www" \
	-e SRC_PATH=theme -e REMOTE_PATH=wp-content/themes/my-theme -e DRY_RUN=TRUE -e CACHE_CLEAR=TRUE -e "CACHE_COMMAND=wp cache flush"
check "exits 0" '[ "$STATUS" -eq 0 ]'
check "writes no files" '! srv "test -e ~/www/wp-content/themes/my-theme/style.php"'
check "skips the cache command" '! srv "test -s ~/wp.log"'
check "still reports files_transferred" 'grep -qx "files_transferred=2" "$WORK/ws/github_output"'
show_log_on_failure "$f"

echo "Custom: wrong SSH_KNOWN_HOSTS is rejected"
f=$FAILED
run_action -e SERVER_TYPE=custom -e SSH_HOST=custom.test -e SSH_PORT=2222 -e "BASE_PATH=~/www" \
	-e SSH_KNOWN_HOSTS="[custom.test]:2222 $(cut -d' ' -f1-2 "$WORK/key.pub")" -e SRC_PATH=theme -e REMOTE_PATH=wp-content/themes/my-theme
check "exits non-zero" '[ "$STATUS" -ne 0 ]'
check "writes no files" '! srv "test -e ~/www/wp-content/themes/my-theme/style.php"'
show_log_on_failure "$f"

echo "Safety rules: WordPress root with --delete and FLAGS that don't skip dotfiles"
f=$FAILED
srv 'mkdir -p ~/root/wp-content/uploads ~/root/wp-content/mu-plugins ~/root/wp-content/plugins/old
	touch ~/root/wp-config.php ~/root/wp-content/uploads/photo.jpg ~/root/wp-content/mu-plugins/host.php \
		~/root/wp-content/object-cache.php ~/root/wp-content/plugins/old/old.php ~/root/stale.php'
run_action -e SERVER_TYPE=custom -e SSH_HOST=custom.test -e SSH_PORT=2222 -e "BASE_PATH=~/root" \
	-e SRC_PATH=site -e "FLAGS=-azvri --delete"
check "exits 0" '[ "$STATUS" -eq 0 ]'
check "uploads the site" 'srv "test -f ~/root/index.php && test -f ~/root/wp-content/themes/t/style.php"'
check "never uploads .git, .github or .env files" '! srv "ls -A ~/root/.git ~/root/.github ~/root/.env ~/root/wp-content/themes/t/.env.local" >/dev/null 2>&1'
check "--delete still removes files that are not in the repository" '! srv "test -e ~/root/stale.php || test -e ~/root/wp-content/plugins/old"'
check "keeps wp-config.php, uploads, mu-plugins and object-cache.php" 'srv "test -f ~/root/wp-config.php && test -f ~/root/wp-content/uploads/photo.jpg && test -f ~/root/wp-content/mu-plugins/host.php && test -f ~/root/wp-content/object-cache.php"'
check "lists the rules in the log" 'grep -q "Never uploaded: .git/" "$WORK/out.log" && grep -q "Never deleted on the server: wp-config.php" "$WORK/out.log"'
show_log_on_failure "$f"

echo "Safety rules: REMOTE_PATH wp-content with --delete-excluded"
f=$FAILED
srv 'mkdir -p ~/root/wp-content/uploads/2026 ~/root/wp-content/cache && touch ~/root/wp-content/uploads/2026/a.jpg ~/root/wp-content/cache/page.html'
run_action -e SERVER_TYPE=custom -e SSH_HOST=custom.test -e SSH_PORT=2222 -e "BASE_PATH=~/root" \
	-e SRC_PATH=site/wp-content -e REMOTE_PATH=wp-content -e "FLAGS=-azvri --delete-excluded --exclude=uploads"
check "exits 0" '[ "$STATUS" -eq 0 ]'
check "keeps uploads and cache, even excluded" 'srv "test -f ~/root/wp-content/uploads/2026/a.jpg && test -f ~/root/wp-content/uploads/photo.jpg && test -f ~/root/wp-content/cache/page.html"'
check "applies only the rules inside REMOTE_PATH" '! grep -q "Never deleted on the server: wp-config.php" "$WORK/out.log" && grep -q "Never deleted on the server: wp-content/uploads/" "$WORK/out.log"'
show_log_on_failure "$f"

echo "Safety rules: PROTECT adds paths, relative to REMOTE_PATH"
f=$FAILED
srv 'mkdir -p ~/root/wp-content/languages/es ~/root/wp-content/plugins/keep "$HOME/root/wp-content/my folder" && touch ~/root/wp-content/languages/es/es.mo ~/root/wp-content/plugins/keep/k.php ~/root/wp-content/notes.txt "$HOME/root/wp-content/my folder/keep.txt"'
run_action -e SERVER_TYPE=custom -e SSH_HOST=custom.test -e SSH_PORT=2222 -e "BASE_PATH=~/root" \
	-e SRC_PATH=site/wp-content -e REMOTE_PATH=wp-content -e "FLAGS=-azvri --delete" \
	-e "PROTECT=$(printf '%s\n' 'wp-content/languages/' '  /wp-content/plugins//keep/  ' 'wp-content/*.txt' 'wp-content/my folder/' 'robots.txt')"
check "exits 0" '[ "$STATUS" -eq 0 ]'
check "keeps the folders and patterns in PROTECT" 'srv "test -f ~/root/wp-content/languages/es/es.mo && test -f ~/root/wp-content/plugins/keep/k.php && test -f ~/root/wp-content/notes.txt"'
check "keeps PROTECT paths with spaces" 'srv "test -f \"\$HOME/root/wp-content/my folder/keep.txt\""'
check "skips PROTECT paths outside REMOTE_PATH" '! grep -q "Never deleted on the server:.*robots.txt" "$WORK/out.log"'
run_action -e SERVER_TYPE=custom -e SSH_HOST=custom.test -e "BASE_PATH=~/root" -e SRC_PATH=site -e "PROTECT=wp-content/../../etc"
check "rejects .. in PROTECT" '[ "$STATUS" -ne 0 ] && grep -q "PROTECT paths can.t contain" "$WORK/out.log"'
show_log_on_failure "$f"

echo "Safety rules: other spellings of REMOTE_PATH and filter resets"
f=$FAILED
srv 'touch ~/root/stale.php'
run_action -e SERVER_TYPE=custom -e SSH_HOST=custom.test -e SSH_PORT=2222 -e "BASE_PATH=~/root" \
	-e SRC_PATH=site -e REMOTE_PATH=./ -e "FLAGS=-azvri --delete-excluded"
check "REMOTE_PATH ./ keeps the root rules" '[ "$STATUS" -eq 0 ] && srv "test -f ~/root/wp-config.php" && ! srv "test -e ~/root/stale.php"'
run_action -e SERVER_TYPE=custom -e SSH_HOST=custom.test -e SSH_PORT=2222 -e "BASE_PATH=~/root" \
	-e SRC_PATH=site/wp-content -e REMOTE_PATH=./wp-content// -e "FLAGS=-azvri --delete-excluded"
check "REMOTE_PATH ./wp-content// keeps uploads" '[ "$STATUS" -eq 0 ] && srv "test -f ~/root/wp-content/uploads/photo.jpg"'
run_action -e SERVER_TYPE=custom -e SSH_HOST=custom.test -e "BASE_PATH=~/root" -e SRC_PATH=site -e "FLAGS=-azvri --delete --filter=!"
check "FLAGS with --filter=! fails" '[ "$STATUS" -ne 0 ] && grep -q "would remove the built-in safety rules" "$WORK/out.log"'
printf '%s\n' 'node_modules' '!' >"$WORK/ws/reset.ignore"
run_action -e SERVER_TYPE=custom -e SSH_HOST=custom.test -e "BASE_PATH=~/root" -e SRC_PATH=site -e "FLAGS=-azvri --delete --exclude-from=reset.ignore"
check "an exclude file with ! fails" '[ "$STATUS" -ne 0 ] && grep -q "reset.ignore has a" "$WORK/out.log"'
printf '%s\n' '.*' 'node_modules' '# a comment' '/vendor/' >"$WORK/ws/.deployignore"
run_action -e SERVER_TYPE=custom -e SSH_HOST=custom.test -e SSH_PORT=2222 -e "BASE_PATH=~/root" -e SRC_PATH=site -e "FLAGS=-azvri --exclude=.git* --exclude-from=.deployignore" -e DRY_RUN=TRUE
check "normal exclude rules still work" '[ "$STATUS" -eq 0 ]'
show_log_on_failure "$f"

echo "PHP_LINT"
f=$FAILED
run_action -e SERVER_TYPE=pressable -e SRC_PATH=bad -e DRY_RUN=TRUE
check "is off by default" '[ "$STATUS" -eq 0 ] && grep -q "Skipping PHP linting" "$WORK/out.log"'
run_action -e SERVER_TYPE=pressable -e SRC_PATH=theme -e PHP_LINT=TRUE
check "lints with PHP 8.4 by default" '[ "$STATUS" -eq 0 ] && grep -q "Starting PHP linting with 8.4" "$WORK/out.log"'
run_action -e SERVER_TYPE=pressable -e SRC_PATH=theme -e PHP_LINT=TRUE -e PHP_VERSION=8.3
check "PHP_VERSION picks the lint binary" '[ "$STATUS" -eq 0 ] && grep -q "Starting PHP linting with 8.3" "$WORK/out.log"'
run_action -e SERVER_TYPE=pressable -e SRC_PATH=theme -e PHP_LINT=TRUE -e PHP_VERSION=8.2
check "rejects unsupported versions" '[ "$STATUS" -ne 0 ] && grep -q "PHP_VERSION .8.2. is not supported" "$WORK/out.log"'
run_action -e SERVER_TYPE=pressable -e SRC_PATH=bad -e PHP_LINT=TRUE
check "a lint failure stops the deploy" '[ "$STATUS" -ne 0 ] && grep -q "PHP linting failed" "$WORK/out.log" && ! srv "test -e ~/htdocs/broken.php"'
show_log_on_failure "$f"

echo "Removed v1 inputs"
f=$FAILED
run_action -e SERVER_TYPE=pressable -e SRC_PATH=theme -e SSH_USER= -e SERVER_ID=deploy
check "SERVER_ID fails with the new name" '[ "$STATUS" -ne 0 ] && grep -q "SERVER_ID was renamed to SSH_USER" "$WORK/out.log"'
show_log_on_failure "$f"

echo "Validation errors"
f=$FAILED
run_action -e SERVER_TYPE=custom -e "BASE_PATH=~/www"
check "custom without SSH_HOST fails" '[ "$STATUS" -ne 0 ] && grep -q "SSH_HOST is required" "$WORK/out.log"'
run_action -e SERVER_TYPE=custom -e SSH_HOST=custom.test -e "BASE_PATH=~/www" -e CACHE_CLEAR=TRUE
check "custom CACHE_CLEAR without CACHE_COMMAND fails" '[ "$STATUS" -ne 0 ] && grep -q "Set CACHE_COMMAND" "$WORK/out.log"'
run_action -e SERVER_TYPE=pressable -e SSH_PRIVATE_KEY="$(cat "$WORK/key.pub")"
check "a public key instead of the private one fails clearly" '[ "$STATUS" -ne 0 ] && grep -q "doesn.t look like a private key" "$WORK/out.log"'
run_action -e SERVER_TYPE=pressable -e SRC_PATH=theme -e "FLAGS=-azrh --delete" -e DRY_RUN=TRUE
check "--delete on the WordPress root warns" '[ "$STATUS" -eq 0 ] && grep -q "::warning::FLAGS has --delete and REMOTE_PATH is empty" "$WORK/out.log"'
run_action -e SERVER_TYPE=pressable -e SRC_PATH=theme -e SSH_USER=
check "missing SSH_USER fails clearly" '[ "$STATUS" -ne 0 ] && grep -q "SSH_USER is missing" "$WORK/out.log"'
run_action -e SERVER_TYPE=kinsta
check "unknown SERVER_TYPE fails" '[ "$STATUS" -ne 0 ] && grep -q "Unknown SERVER_TYPE" "$WORK/out.log"'
show_log_on_failure "$f"

echo
echo "Passed: $PASSED, failed: $FAILED"
[ "$FAILED" -eq 0 ]
