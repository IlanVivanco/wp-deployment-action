#!/bin/bash
set -eo pipefail

# Print a GitHub Actions error annotation and exit
fail() {
	echo "::error::$*"
	exit 1
}

# Return success when the value is a truthy flag (TRUE, true, 1, yes)
is_true() {
	case "${1^^}" in
	TRUE | 1 | YES) return 0 ;;
	*) return 1 ;;
	esac
}

# Validate the required environment variables
validate() {
	[ -n "${SERVER_TYPE}" ] || fail "SERVER_TYPE variable missing from environment variables."
	[ -n "${SSH_PRIVATE_KEY}" ] || fail "SSH_PRIVATE_KEY variable missing from environment variables."
	# Inputs removed in v2 fail with the way to migrate, instead of being ignored
	[ -z "${SERVER_ID}" ] || fail "SERVER_ID was renamed to SSH_USER in v2. Replace 'SERVER_ID:' with 'SSH_USER:' in your workflow."
	[ -n "${SSH_USER}" ] || fail "SSH_USER is missing. Pressable and custom: the SSH username. WP Engine: the environment name."
	REMOTE_PATH="${REMOTE_PATH:-""}"
	SRC_PATH="${SRC_PATH:-"."}"
	FLAGS="${FLAGS:-"-azvrhi --inplace --exclude='.*'"}"
	CACHE_CLEAR="${CACHE_CLEAR:-"false"}"
	SCRIPT="${SCRIPT:-""}"
	SSH_PORT="${SSH_PORT:-"22"}"
	PROTECT="${PROTECT:-""}"
	PHP_LINT="${PHP_LINT:-"false"}"
	PHP_VERSION="${PHP_VERSION:-"8.4"}"
	DRY_RUN="${DRY_RUN:-"false"}"
	DEBUG="${DEBUG:-"false"}"

	[[ "${SSH_PRIVATE_KEY}" == *"PRIVATE KEY-----"* ]] || fail "SSH_PRIVATE_KEY doesn't look like a private key. Paste the whole private key file, including the -----BEGIN and -----END lines, not the .pub file."
	[[ "${SSH_PORT}" =~ ^[0-9]+$ ]] || fail "SSH_PORT must be a number, got '${SSH_PORT}'."
	[ -d "${SRC_PATH}" ] || fail "SRC_PATH '${SRC_PATH}' is not a directory."
	if is_true "${PHP_LINT}"; then
		case "${PHP_VERSION}" in
		8.3 | 8.4 | 8.5) ;;
		*) fail "PHP_VERSION '${PHP_VERSION}' is not supported for linting. Use 8.3, 8.4 or 8.5, or lint in a previous step with shivammathur/setup-php." ;;
		esac
	fi

	# The safety rules compare paths, so they need one spelling for each:
	# ".", "./wp-content" and "wp-content//" are the root and wp-content
	REMOTE_DIR="$(normalize_path "${REMOTE_PATH}")" || fail "REMOTE_PATH can't contain '..', got '${REMOTE_PATH}'."
	# PROTECT has one path per line; spaces inside a path are kept
	local line path
	PROTECT_PATHS=()
	while IFS= read -r line; do
		line="${line#"${line%%[![:space:]]*}"}"
		line="${line%"${line##*[![:space:]]}"}"
		[ -n "${line}" ] || continue
		path="$(normalize_path "${line}")" || fail "PROTECT paths can't contain '..', got '${line}'."
		[ -n "${path}" ] || fail "PROTECT can't protect the whole WordPress root, got '${line}'."
		# A trailing / marks a folder
		[[ "${line}" != */ && "${line}" != */. ]] || path="${path}/"
		PROTECT_PATHS+=("${path}")
	done <<<"${PROTECT}"
}

# Print a server path relative to the WordPress root without leading, trailing
# or repeated slashes and without "." parts; the root prints as "". Fails on "..".
normalize_path() {
	local part parts=() out=()
	IFS=/ read -r -a parts <<<"$1"
	for part in "${parts[@]}"; do
		case "${part}" in
		"" | .) ;;
		..) return 1 ;;
		*) out+=("${part}") ;;
		esac
	done
	local IFS=/
	echo "${out[*]}"
}

# Set up environment variables
init() {
	INPUT_SSH_HOST="${SSH_HOST}"
	case "${SERVER_TYPE^^}" in
	PRESSABLE)
		SSH_HOST="ssh.pressable.com"
		# shellcheck disable=SC2088 # the tilde must expand on the server
		SERVER_BASE_PATH="~/htdocs"
		DEFAULT_CACHE_COMMAND="wp --skip-plugins --skip-themes cache flush"
		;;
	WPENGINE)
		SSH_HOST="${SSH_USER}.ssh.wpengine.net"
		SERVER_BASE_PATH="sites/${SSH_USER}"
		DEFAULT_CACHE_COMMAND="wp --skip-plugins --skip-themes page-cache flush && wp --skip-plugins --skip-themes cdn-cache flush"
		;;
	CUSTOM)
		[ -n "${SSH_HOST}" ] || fail "SSH_HOST is required when SERVER_TYPE is 'custom'."
		[ -n "${BASE_PATH}" ] || fail "BASE_PATH is required when SERVER_TYPE is 'custom'."
		SERVER_BASE_PATH="${BASE_PATH%/}"
		DEFAULT_CACHE_COMMAND=""
		;;
	*)
		fail "Unknown SERVER_TYPE: ${SERVER_TYPE}. Use 'pressable', 'wpengine' or 'custom'."
		;;
	esac

	if [ "${SERVER_TYPE^^}" != "CUSTOM" ]; then
		[ -z "${INPUT_SSH_HOST}" ] || echo "::warning::SSH_HOST is only used when SERVER_TYPE is 'custom'; ignoring it."
		[ -z "${BASE_PATH}" ] || echo "::warning::BASE_PATH is only used when SERVER_TYPE is 'custom'; ignoring it."
	fi

	if is_true "${CACHE_CLEAR}"; then
		CACHE_COMMAND="${CACHE_COMMAND:-${DEFAULT_CACHE_COMMAND}}"
		[ -n "${CACHE_COMMAND}" ] || fail "CACHE_CLEAR is enabled but there is no cache command. Set CACHE_COMMAND when SERVER_TYPE is 'custom'."
	else
		[ -z "${CACHE_COMMAND}" ] || echo "::warning::CACHE_COMMAND is set but CACHE_CLEAR is not enabled; the cache will not be cleared."
		CACHE_COMMAND=""
	fi

	SSH_REMOTE="${SSH_USER}@${SSH_HOST}"
	SERVER_PATH="${SERVER_BASE_PATH}/${REMOTE_PATH}"
	SERVER_DEST="${SSH_REMOTE}:${SERVER_PATH}"

	parse_flags "$FLAGS"
	reject_filter_resets
	safety_rules
	if [ -z "${REMOTE_PATH}" ] && [[ " ${FLAGS_ARRAY[*]} " == *" --delete"* ]]; then
		echo "::warning::FLAGS has --delete and REMOTE_PATH is empty, so files on the server's WordPress root that are not in SRC_PATH will be deleted. Try DRY_RUN first."
	fi
	print_info
}

# Print deployment info
print_info() {
	echo "--- DEPLOYMENT INFO ---"
	echo "* Deploying to: ${SERVER_TYPE}"
	echo "* SSH user: ${SSH_USER}"
	echo "* SSH host: ${SSH_HOST}:${SSH_PORT}"
	echo "* Source path: ${SRC_PATH}"
	echo "* Destination path: ${SERVER_DEST}"
	echo "* Flags: ${FLAGS_ARRAY[*]}"
	echo "* Never uploaded: ${NEVER_UPLOAD[*]}"
	echo "* Never deleted on the server: ${PROTECTED_HERE[*]:-(nothing under this REMOTE_PATH)}"
	echo "* PHP linting: ${PHP_LINT}$(is_true "${PHP_LINT}" && echo " (PHP ${PHP_VERSION})")"
	echo "* Cache clear: ${CACHE_CLEAR}${CACHE_COMMAND:+ (${CACHE_COMMAND})}"
	echo "* Post-deploy script: ${SCRIPT}"
	echo "* Host key check: $([ -n "${SSH_KNOWN_HOSTS}" ] && echo "strict (SSH_KNOWN_HOSTS)" || echo "trust on first use")"
	if is_true "${DRY_RUN}"; then
		echo "* Dry run: rsync runs with --dry-run, no script or cache clear"
	fi
	echo "-----------------------"
}

# Files that are never uploaded, whatever FLAGS and .deployignore say
NEVER_UPLOAD=(.git/ .github/ .gitignore .gitattributes .deployignore .env ".env.*" .DS_Store)
# Server files that are never deleted, relative to the WordPress root
PROTECTED=(
	wp-config.php .htaccess .user.ini
	wp-content/uploads/ wp-content/cache/ wp-content/upgrade/ wp-content/mu-plugins/
	wp-content/advanced-cache.php wp-content/object-cache.php wp-content/db.php
)

# Build the rsync rules for NEVER_UPLOAD and for the PROTECTED paths inside
# REMOTE_PATH. They go before FLAGS, and rsync applies the first rule that matches.
safety_rules() {
	local remote="${REMOTE_DIR}" rule path
	SAFETY_RULES=()
	PROTECTED_HERE=()
	for rule in "${NEVER_UPLOAD[@]}"; do SAFETY_RULES+=("--filter=- ${rule}"); done
	# PROTECT adds paths to the defaults
	for path in "${PROTECTED[@]}" "${PROTECT_PATHS[@]}"; do
		if [ -z "${remote}" ]; then
			rule="/${path}"
		elif [[ "${path}" == "${remote}/"?* ]]; then
			rule="/${path#"${remote}"/}"
		else
			# Outside REMOTE_PATH, or REMOTE_PATH itself (deploying into it is on purpose)
			continue
		fi
		# A protected folder keeps everything inside it too
		[[ "${rule}" != */ ]] || rule="${rule}***"
		SAFETY_RULES+=("--filter=P ${rule}")
		PROTECTED_HERE+=("${path}")
	done
}

# rsync drops every earlier filter rule on a "!" or "clear" rule, and per-folder
# filter files can do the same, which would remove the safety rules. Refuse
# them in FLAGS and in the filter files FLAGS reads.
reject_filter_resets() {
	local i flag next value file
	local msg="would remove the built-in safety rules"
	for ((i = 0; i < ${#FLAGS_ARRAY[@]}; i++)); do
		flag="${FLAGS_ARRAY[i]}"
		next="${FLAGS_ARRAY[i + 1]:-}"
		value=""
		file=""
		case "${flag}" in
		--exclude=* | --include=* | --filter=*) value="${flag#*=}" ;;
		--exclude | --include | --filter) value="${next}" ;;
		--exclude-from=* | --include-from=*) file="${flag#*=}" ;;
		--exclude-from | --include-from) file="${next}" ;;
		--*) ;;
		-f) value="${next}" ;;
		-f*) value="${flag#-f}" ;;
		-*F*) fail "FLAGS can't use -F: per-folder .rsync-filter files ${msg}." ;;
		esac
		# Trim spaces around the rule
		value="${value#"${value%%[![:space:]]*}"}"
		value="${value%"${value##*[![:space:]]}"}"
		case "${value}" in
		"!" | clear) fail "FLAGS can't reset the filter rules with '${value}': it ${msg}." ;;
		dir-merge* | :*) fail "FLAGS can't use per-folder filter files (${value}): they ${msg}." ;;
		merge[,[:space:]]* | .[,[:space:]]*) file="${value#*[[:space:]]}" ;;
		esac
		if [ -n "${file}" ] && [ -f "${file}" ] &&
			grep -Eq '^[[:space:]]*(!|clear|(merge|dir-merge|\.|:)([,[:space:]].*)?)[[:space:]]*$' "${file}"; then
			fail "${file} has a '!', 'clear' or merge line, which ${msg}. Remove that line."
		fi
	done
}

# Parse flags into an array
parse_flags() {
	local flags="$1"
	FLAGS_ARRAY=()
	while IFS= read -r -d '' flag; do FLAGS_ARRAY+=("$flag"); done < <(echo "$flags" | xargs printf '%s\0')
}

# Set up SSH keys, host keys and connection options in a private temp dir
setup_ssh() {
	echo "Setting up SSH..."
	SSH_PATH="$(mktemp -d /tmp/wpda.XXXXXX)"
	trap cleanup EXIT

	SSH_KEY_PATH="${SSH_PATH}/deploy_key"
	KNOWN_HOSTS_PATH="${SSH_PATH}/known_hosts"
	(
		umask 077
		printf '%s\n' "${SSH_PRIVATE_KEY}" | tr -d '\r' >"${SSH_KEY_PATH}"
	)

	if [ -n "${SSH_KNOWN_HOSTS}" ]; then
		printf '%s\n' "${SSH_KNOWN_HOSTS}" >"${KNOWN_HOSTS_PATH}"
		HOST_KEY_CHECKING="yes"
	else
		# The first connection records the host key; no ssh-keyscan, since
		# OpenSSH 9.8+ penalizes connections that never try to authenticate
		: >"${KNOWN_HOSTS_PATH}"
		HOST_KEY_CHECKING="accept-new"
	fi

	SSH_OPTS=(
		-p "${SSH_PORT}"
		-i "${SSH_KEY_PATH}"
		-o IdentitiesOnly=yes
		-o BatchMode=yes
		-o UserKnownHostsFile="${KNOWN_HOSTS_PATH}"
		-o StrictHostKeyChecking="${HOST_KEY_CHECKING}"
		-o ControlPath="${SSH_PATH}/ctl-%C"
		-o ConnectTimeout=60
		-o ServerAliveInterval=30
	)
	if is_true "${DEBUG}"; then
		SSH_OPTS+=(-v)
	fi

	# Create multiplex connection
	ssh -nNf "${SSH_OPTS[@]}" -o ControlMaster=yes "${SSH_REMOTE}" || fail "Could not connect to ${SSH_REMOTE} on port ${SSH_PORT}. If the log says 'timed out', the host or port is wrong or a firewall blocks GitHub; check them in your hosting panel."
	echo "Multiplex SSH connection established."
}

# Close the multiplex connection and remove the key
cleanup() {
	{ set +x; } 2>/dev/null
	ssh -O exit -o ControlPath="${SSH_PATH}/ctl-%C" -p "${SSH_PORT}" "${SSH_REMOTE}" 2>/dev/null || true
	rm -rf "${SSH_PATH}"
}

# Write a step output when running inside GitHub Actions
set_output() {
	[ -n "${GITHUB_OUTPUT}" ] && echo "$1=$2" >>"${GITHUB_OUTPUT}"
	return 0
}

# Read a counter from rsync --stats output
stat_count() {
	grep -m1 "^$1:" "$2" | sed 's/^[^:]*: *//; s/,//g; s/[^0-9].*//' || true
}

# Check PHP linting
check_lint() {
	if ! is_true "${PHP_LINT}"; then
		echo "Skipping PHP linting."
		return
	fi

	# PHP 8.4 ships in the image; other versions are installed on demand
	local php_bin="php${PHP_VERSION//./}"
	if ! command -v "${php_bin}" >/dev/null; then
		echo "Installing PHP ${PHP_VERSION}..."
		apk add --no-cache --quiet "${php_bin}" || fail "Could not install PHP ${PHP_VERSION}."
	fi

	echo "Starting PHP linting with $("${php_bin}" -r 'echo PHP_VERSION;')..."
	local failed=0 count=0 file output
	while IFS= read -r -d '' file; do
		count=$((count + 1))
		if ! output=$("${php_bin}" -l "$file" 2>&1); then
			echo "$output"
			echo "::error file=${file}::PHP linting failed"
			failed=1
		fi
	done < <(find "${SRC_PATH}" -name "*.php" -type f -print0)

	[ "$failed" -eq 0 ] || fail "PHP linting failed."
	echo "PHP linting completed successfully (${count} files)."
}

# Sync files to the server using rsync
sync_files() {
	local rsync_log rsync_args
	rsync_log="$(mktemp)"
	# shellcheck disable=SC2054 # --chmod takes a comma-separated value
	rsync_args=("${SAFETY_RULES[@]}" "${FLAGS_ARRAY[@]}" --chmod=D775,F664 --stats)
	if is_true "${DRY_RUN}"; then
		rsync_args+=(--dry-run)
	fi

	# rsync splits --rsh on spaces, so every path here is space-free
	set -x
	rsync --rsh="ssh ${SSH_OPTS[*]}" \
		"${rsync_args[@]}" \
		"${SRC_PATH}/" "${SERVER_DEST}" | tee "${rsync_log}"
	{ set +x; } 2>/dev/null

	set_output files_transferred "$(stat_count "Number of regular files transferred" "${rsync_log}")"
	set_output files_deleted "$(stat_count "Number of deleted files" "${rsync_log}")"
	set_output destination "${SERVER_DEST}"
	rm -f "${rsync_log}"
}

# Quote a path for the remote shell; a leading ~ becomes "$HOME" so it still
# expands on the server while the rest of the path stays literal
remote_quote() {
	local path="$1"
	# shellcheck disable=SC2016,SC2088 # literal "$HOME" and ~ for the remote shell
	case "${path}" in
	"~") echo '"$HOME"' ;;
	"~/"*) echo "\"\$HOME\"/$(printf '%q' "${path#\~/}")" ;;
	*) printf '%q\n' "${path}" ;;
	esac
}

# Run the post-deploy script and the cache clear in a single remote call
run_remote() {
	local commands=()

	if is_true "${DRY_RUN}"; then
		echo "Dry run: skipping post-deploy script and cache clear."
		return
	fi

	if [ -n "${SCRIPT}" ]; then
		# Base path stays unquoted so a leading ~ expands on the server
		local script_rel script_path
		script_rel="${REMOTE_PATH%/}/${SCRIPT#/}"
		script_path="$(remote_quote "${SERVER_BASE_PATH%/}/${script_rel#/}")"
		echo "Script command: bash ${script_path}"
		commands+=("if [ ! -f ${script_path} ]; then echo Post-deploy script not found: ${script_path} >&2; exit 1; fi")
		commands+=("chmod +x ${script_path}")
		commands+=("bash ${script_path}")
	fi

	if [ -n "${CACHE_COMMAND}" ]; then
		echo "Cache command: ${CACHE_COMMAND}"
		commands+=("${CACHE_COMMAND}")
	fi

	[ "${#commands[@]}" -gt 0 ] || return 0

	local remote_command
	remote_command="$(printf '%s && ' "${commands[@]}")"
	# shellcheck disable=SC2029 # the command is built client-side on purpose
	ssh "${SSH_OPTS[@]}" "${SSH_REMOTE}" "${remote_command% && }" || fail "Post-deploy commands failed on the server."
}

# Main execution
validate
init
check_lint
setup_ssh
sync_files
run_remote
if is_true "${DRY_RUN}"; then
	echo "✅ Dry run finished, nothing was changed on the server."
else
	echo "✅ Site has been deployed!"
fi
