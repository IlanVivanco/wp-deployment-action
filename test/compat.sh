#!/bin/bash
# Assertions are eval-ed strings, so single quotes are intended
# shellcheck disable=SC2016
# Backward compatibility test: deploys the same fixtures with the image built
# from a released ref (v2.0.0, the first v2 release, by default) and with the working tree, against SSH
# servers with different rsync versions, and checks that both leave the server
# in the same state.
# Usage: test/compat.sh [ref] (needs Docker). KEEP=1 keeps the temp files.
# TEST_IMAGE=<image> tests an image that is already built instead of the working tree.
set -eo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REF="${1:-v2.0.0}"
WORK="$(mktemp -d)"
NET="wpda-compat-$$"
SRV="wpda-compat-srv-$$"
OLD_IMAGE="wpda-compat-old"
NEW_IMAGE="${TEST_IMAGE:-wpda-compat-new}"
SERVERS=(alpine ubuntu22.04 ubuntu20.04)
PASSED=0
FAILED=0

cleanup() {
	docker rm -f "$SRV" >/dev/null 2>&1 || true
	docker network rm "$NET" >/dev/null 2>&1 || true
	[ -n "$KEEP" ] && return
	docker run --rm -v "$WORK:/w" alpine:3.23 sh -c 'rm -rf /w/home-*' >/dev/null 2>&1 || true
	rm -rf "$WORK"
}
trap cleanup EXIT

srv() { docker exec -u deploy "$SRV" bash -c "$1"; }

echo "Building images ($REF and working tree)..."
mkdir -p "$WORK/old"
git -C "$ROOT" archive "$REF" | tar -x -C "$WORK/old"
docker build -q -t "$OLD_IMAGE" "$WORK/old" >/dev/null
[ -n "$TEST_IMAGE" ] || docker build -q -t "$NEW_IMAGE" "$ROOT" >/dev/null
docker build -q -t wpda-compat-sshd-alpine "$ROOT/test/sshd" >/dev/null
for version in 22.04 20.04; do
	docker build -q --build-arg UBUNTU="$version" -t "wpda-compat-sshd-ubuntu$version" \
		-f "$ROOT/test/sshd/Dockerfile.ubuntu" "$ROOT/test/sshd" >/dev/null
done
ssh-keygen -q -t ed25519 -N '' -f "$WORK/key"
docker network create "$NET" >/dev/null

# Fixture: a theme repository like the ones that use @v1, built before deploying
make_repo() {
	local dir="$1" ignore="$2" script="$3" php_error="$4"
	rm -rf "$dir"
	mkdir -p "$dir"/{inc,assets/css,bin,src,node_modules/pkg,vendor/lib,.github/workflows}
	echo '<?php // theme' >"$dir/style.php"
	echo '<?php // inc' >"$dir/inc/helpers.php"
	echo 'body{}' >"$dir/assets/css/main.css"
	echo '$a: 1;' >"$dir/src/main.scss"
	echo '<?php // dependency' >"$dir/node_modules/pkg/index.php"
	echo '<?php // vendor' >"$dir/vendor/lib/lib.php"
	echo 'name: ci' >"$dir/.github/workflows/deploy.yml"
	echo '{}' >"$dir/package.json"
	echo '# readme' >"$dir/README.md"
	echo 'echo build' >"$dir/bin/deploy-build.sh"
	[ "$php_error" = yes ] && echo '<?php echo 1' >"$dir/inc/broken.php"

	case "$ignore" in
	full) printf '%s\n' '/node_modules/' '/vendor/' '/dist/' '/bin/deploy*' '.*' 'composer*' 'gulp*' 'package*' 'phpcs*' 'README*' 'src' ;;
	no-dotfiles) printf '%s\n' 'bin/deploy*' 'dist' 'node_modules' 'package*' 'phpcs*' 'README*' 'src' ;;
	empty) : ;;
	esac >"$dir/.deployignore"

	case "$script" in
	template) printf '%s\n' '#!/bin/bash' 'echo "Running custom scripts from $(pwd)"' 'pwd >~/script-cwd' ;;
	cd-pressable) printf '%s\n' '#!/bin/bash' 'cd htdocs/wp-content/themes/my-theme && touch ~/script-ran-$(basename "$PWD")' ;;
	cd-wpengine) printf '%s\n' '#!/bin/bash' 'cd sites/deploy/wp-content/themes/my-theme && touch ~/script-ran-$(basename "$PWD")' ;;
	empty) : ;;
	esac >"$dir/bin/post-deploy.sh"
}

# Leave the server as an earlier deploy would: old, excluded and server-only files
reset_server() {
	srv 'rm -rf ~/htdocs ~/sites ~/wp.log ~/script-*
		for base in ~/htdocs ~/sites/deploy; do
			mkdir -p "$base/wp-content/themes/my-theme/node_modules/old" "$base/wp-content/uploads"
			echo stale >"$base/wp-content/themes/my-theme/removed.php"
			echo old >"$base/wp-content/themes/my-theme/node_modules/old/index.php"
			echo upload >"$base/wp-content/uploads/photo.jpg"
		done'
}

# Run one image and record exit status and server state in $WORK/<label>.state
run_with() {
	local image="$1" label="$2"
	shift 2
	reset_server
	set +e
	docker run --rm --network "$NET" \
		-e HOME=/github/home -v "$WORK/home-$label:/github/home" \
		-v "$WORK/repo:/github/workspace" -w /github/workspace \
		-e SSH_PRIVATE_KEY="$(cat "$WORK/key")" -e SSH_USER=deploy \
		-e PHP_LINT=true -e CACHE_CLEAR=true -e SCRIPT=bin/post-deploy.sh \
		-e REMOTE_PATH=wp-content/themes/my-theme \
		"$@" "$image" >"$WORK/$label.log" 2>&1
	local status=$?
	set -e
	{
		[ "$status" -eq 0 ] && echo "result: success" || echo "result: failure"
		srv 'cd ~ && find htdocs sites -printf "%p %y %m %s\n" | sort'
		echo "wp:"
		srv 'cat ~/wp.log 2>/dev/null || true'
		echo "script:"
		srv 'cd ~ && ls script-* 2>/dev/null; cat script-cwd 2>/dev/null || true'
	} >"$WORK/$label.state"
}

# Deploy with both images and compare the server state
compare() {
	local name="$1"
	shift
	run_with "$OLD_IMAGE" old "$@"
	run_with "$NEW_IMAGE" new "$@"
	if diff -u "$WORK/old.state" "$WORK/new.state" >"$WORK/diff"; then
		PASSED=$((PASSED + 1))
		echo "  ✅ $name ($(head -1 "$WORK/new.state" | cut -d' ' -f2))"
	else
		FAILED=$((FAILED + 1))
		echo "  ❌ $name"
		sed 's/^/      | /' "$WORK/diff"
		echo "      | --- new log"
		tail -15 "$WORK/new.log" | sed 's/^/      | /'
	fi
}

FLAGS_DELETE="-azvrhi --inplace --delete --delete-excluded --exclude-from=.deployignore"
FLAGS_KEEP="-azvrhi --inplace --delete-excluded --exclude-from=.deployignore"
FLAGS_NO_H="-azvri --inplace --delete-excluded --exclude-from=.deployignore"

for server in "${SERVERS[@]}"; do
	docker rm -f "$SRV" >/dev/null 2>&1 || true
	docker run -d --name "$SRV" --network "$NET" \
		--network-alias ssh.pressable.com --network-alias deploy.ssh.wpengine.net \
		-e AUTHORIZED_KEY="$(cat "$WORK/key.pub")" "wpda-compat-sshd-$server" >/dev/null
	for _ in $(seq 20); do srv 'true' 2>/dev/null && docker exec "$SRV" sh -c 'cat /proc/net/tcp* | grep -q ":0016 "' && break; sleep 0.5; done
	echo "Server: $server ($(docker exec "$SRV" rsync --version | head -1 | cut -d' ' -f1-4))"

	make_repo "$WORK/repo" full cd-pressable
	compare "pressable, --delete, full .deployignore, script cds into the theme" -e SERVER_TYPE=pressable -e "FLAGS=$FLAGS_DELETE"
	make_repo "$WORK/repo" no-dotfiles template
	compare "pressable, no --delete, .deployignore without .*, template script" -e SERVER_TYPE=pressable -e "FLAGS=$FLAGS_KEEP"
	make_repo "$WORK/repo" empty empty
	compare "pressable, -azvri, empty .deployignore, empty script" -e SERVER_TYPE=PRESSABLE -e "FLAGS=$FLAGS_NO_H"
	make_repo "$WORK/repo" full cd-wpengine
	compare "wpengine, --delete, full .deployignore, script cds into the theme" -e SERVER_TYPE=wpengine -e "FLAGS=$FLAGS_DELETE"
	make_repo "$WORK/repo" empty template
	compare "wpengine, no --delete, empty .deployignore, template script" -e SERVER_TYPE=wpengine -e "FLAGS=$FLAGS_KEEP"
	make_repo "$WORK/repo" full template yes
	compare "pressable, PHP syntax error stops the deploy" -e SERVER_TYPE=pressable -e "FLAGS=$FLAGS_DELETE"
	make_repo "$WORK/repo" full template no
	compare "pressable, SCRIPT that is not uploaded" -e SERVER_TYPE=pressable -e "FLAGS=$FLAGS_DELETE" -e SCRIPT=bin/deploy-build.sh
done

echo
echo "Same result as $REF: $PASSED, different: $FAILED"
[ "$FAILED" -eq 0 ]
