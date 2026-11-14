#!/bin/bash
# Assertions are eval-ed strings, so single quotes are intended
# shellcheck disable=SC2016,SC2034
# End-to-end tests: runs the action image against a throwaway SSH server.
# Usage: test/e2e.sh (needs Docker). KEEP=1 leaves the server and temp files for debugging.
set -eo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
NET="wpda-e2e-$$"
SRV="wpda-e2e-srv-$$"
ACTION_IMAGE="wpda-e2e-action"
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
docker build -q -t "$ACTION_IMAGE" "$ROOT" >/dev/null
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

mkdir -p "$WORK/home" "$WORK/ws/theme/inc" "$WORK/ws/mu-plugins" "$WORK/ws/bad" "$WORK/ws/bin"
echo '<?php // theme' >"$WORK/ws/theme/style.php"
echo '<?php // inc' >"$WORK/ws/theme/inc/a.php"
echo '<?php // mu' >"$WORK/ws/mu-plugins/my-mu-plugin.php"
echo '<?php echo 1' >"$WORK/ws/bad/broken.php"
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
	-e "FLAGS=-azrh --exclude=github_output --exclude=bad" -e CACHE_CLEAR=true -e SCRIPT=bin/post.sh
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
	-e "FLAGS=-azrh --exclude=github_output --exclude=bad" -e SCRIPT=bin/post.sh
check "exits 0" '[ "$STATUS" -eq 0 ]'
check "deploys under the path with a space" 'srv "test -f ~/\"site root\"/bin/post.sh"'
check "runs the script there" 'srv "test -f ~/script-ran"'
run_action -e SERVER_TYPE=custom -e SSH_HOST=custom.test -e SSH_PORT=2222 -e 'BASE_PATH=~/$(touch ~/INJECTED)x' \
	-e "FLAGS=-azrh --exclude=github_output --exclude=bad" -e SCRIPT=bin/post.sh
check "exits 0" '[ "$STATUS" -eq 0 ]'
check "does not run command substitutions" '! srv "test -e ~/INJECTED"'
show_log_on_failure "$f"

echo "Custom: absolute BASE_PATH and a non-default port"
f=$FAILED
srv 'rm -f ~/script-ran; mkdir -p ~/abs/public/wp-content/themes'
run_action -e SERVER_TYPE=custom -e SSH_HOST=custom.test -e SSH_PORT=2222 -e BASE_PATH=/home/deploy/abs/public \
	-e SRC_PATH=. -e REMOTE_PATH=wp-content/themes/my-theme \
	-e "FLAGS=-azrh --exclude=github_output --exclude=bad" -e SCRIPT=bin/post.sh
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

echo "PHP_VERSION picks the lint binary"
f=$FAILED
run_action -e SERVER_TYPE=pressable -e SRC_PATH=theme -e PHP_LINT=TRUE -e PHP_VERSION=8.3
check "exits 0" '[ "$STATUS" -eq 0 ]'
check "lints with PHP 8.3" 'grep -q "Starting PHP linting with 8.3" "$WORK/out.log"'
run_action -e SERVER_TYPE=pressable -e SRC_PATH=theme -e PHP_LINT=TRUE -e PHP_VERSION=8.2
check "rejects unsupported versions" '[ "$STATUS" -ne 0 ] && grep -q "PHP_VERSION .8.2. is not supported" "$WORK/out.log"'
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
run_action -e SERVER_TYPE=pressable -e SRC_PATH=theme -e SSH_USER= -e SERVER_ID=deploy -e DRY_RUN=TRUE
check "SERVER_ID still works, with a notice" '[ "$STATUS" -eq 0 ] && grep -q "::notice::SERVER_ID is deprecated" "$WORK/out.log"'
run_action -e SERVER_TYPE=pressable -e SRC_PATH=theme -e SERVER_ID=other
check "SSH_USER and a different SERVER_ID fail" '[ "$STATUS" -ne 0 ] && grep -q "both set and differ" "$WORK/out.log"'
run_action -e SERVER_TYPE=pressable -e SRC_PATH=theme -e SSH_USER=
check "missing SSH_USER fails clearly" '[ "$STATUS" -ne 0 ] && grep -q "SSH_USER is missing" "$WORK/out.log"'
run_action -e SERVER_TYPE=kinsta
check "unknown SERVER_TYPE fails" '[ "$STATUS" -ne 0 ] && grep -q "Unknown SERVER_TYPE" "$WORK/out.log"'
run_action -e SERVER_TYPE=pressable -e SRC_PATH=bad -e PHP_LINT=TRUE
check "PHP lint failure stops the deploy" '[ "$STATUS" -ne 0 ] && grep -q "PHP linting failed" "$WORK/out.log" && ! srv "test -e ~/htdocs/broken.php"'
show_log_on_failure "$f"

echo
echo "Passed: $PASSED, failed: $FAILED"
[ "$FAILED" -eq 0 ]
