#!/bin/bash -l
set -e

# Validate the required environment variables
validate() {
	: "${SERVER_TYPE:?SERVER_TYPE variable missing from environment variables.}"
	if [ "${SERVER_TYPE^^}" = "CUSTOM" ]; then
		: "${SSH_USER:?SSH_USER variable missing for custom server.}"
		: "${SSH_DEST:?SSH_DEST variable missing for custom server.}"
		: "${SSH_HOST:?SSH_HOST variable missing for custom server.}"
	else
		: "${SERVER_ID:?SERVER_ID variable missing from environment variables.}"
	fi
	: "${SSH_PRIVATE_KEY:?SSH_PRIVATE_KEY variable missing from environment variables.}"
	SSH_PORT="${SSH_PORT:-22}"
	REMOTE_PATH="${REMOTE_PATH:-}"
	SRC_PATH="${SRC_PATH:-.}"
	FLAGS="${FLAGS:-"-azvrhi --inplace --exclude='.*'"}"
	PHP_LINT="${PHP_LINT:-false}"
	CACHE_CLEAR="${CACHE_CLEAR:-false}"
	SCRIPT="${SCRIPT:-}"
}

# Set up environment variables
init() {
	case "${SERVER_TYPE^^}" in
	PRESSABLE)
		SSH_HOST="ssh.pressable.com"
		SSH_USER="${SERVER_ID}@${SSH_HOST}"
		SERVER_BASE_PATH="~/htdocs"
		SERVER_DEST="${SSH_USER}:${SERVER_BASE_PATH}/${REMOTE_PATH}"
		;;
	WPENGINE)
		SSH_HOST="${SERVER_ID}.ssh.wpengine.net"
		SSH_USER="${SERVER_ID}@${SSH_HOST}"
		SERVER_BASE_PATH="sites/${SERVER_ID}"
		SERVER_DEST="${SSH_USER}:${SERVER_BASE_PATH}/${REMOTE_PATH}"
		;;
	CUSTOM)
		# For custom, use the provided SSH_USER, SSH_HOST, SSH_DEST and SSH_PORT
		SSH_PORT="${SSH_PORT:-22}"
		SSH_USER="${SSH_USER}@${SSH_HOST}"
		SERVER_DEST="${SSH_USER}:${SSH_DEST}"
		;;
	*)
		echo "❌ Unknown SERVER_TYPE: ${SERVER_TYPE}"
		exit 1
		;;
	esac

	parse_flags "$FLAGS"

	print_info
	setup_ssh
	check_lint
}

# Print deployment info
print_info() {
	echo "--- DEPLOYMENT INFO ---"
	echo "=== Received Variables ==="
	echo "* SERVER_TYPE: ${SERVER_TYPE}"
	if [ "${SERVER_TYPE^^}" = "CUSTOM" ]; then
		echo "* SSH_USER: ${SSH_USER}"
		echo "* SSH_HOST: ${SSH_HOST}"
		echo "* SSH_DEST: ${SSH_DEST}"
	else
		echo "* SERVER_ID: ${SERVER_ID}"
		echo "* SERVER_BASE_PATH: ${SERVER_BASE_PATH}"
	fi
	echo "* SSH_PORT: ${SSH_PORT}"
	echo "* SRC_PATH: ${SRC_PATH}"
	echo "* PHP_LINT: ${PHP_LINT}"
	echo ""
	echo "=== Deploy Variables ==="
	echo "* Destination: ${SERVER_DEST}"
	echo "* Flags: ${FLAGS_ARRAY[@]}"
	echo "* Cache: ${CACHE_CLEAR}"
	echo "* Script: ${SCRIPT}"
	echo ""
	echo "-----------------------"
}

# Parse flags into an array
parse_flags() {
	local flags="$1"
	FLAGS_ARRAY=()
	while IFS= read -r -d '' flag; do FLAGS_ARRAY+=("$flag"); done < <(echo "$flags" | xargs printf '%s\0')
}

# Set up SSH keys based on the provided private key
setup_ssh() {
	echo "Setting SSH path..."
	SSH_PATH="${HOME}/.ssh"
	if [ ! -d "${HOME}/.ssh" ]; then
		mkdir "${HOME}/.ssh"
		mkdir "${SSH_PATH}/ctl/"
		chmod -R 700 "$SSH_PATH"
	fi
	SSH_KEY_PATH="${SSH_PATH}/deploy_key"
	umask 077
	echo "${SSH_PRIVATE_KEY}" >"${SSH_KEY_PATH}"
	chmod 600 "${SSH_KEY_PATH}"
	KNOWN_HOSTS_PATH="${SSH_PATH}/known_hosts"
	ssh-keyscan -t rsa "${SSH_HOST}" >>"${KNOWN_HOSTS_PATH}"
	chmod 644 "${KNOWN_HOSTS_PATH}"
}

# Check PHP linting
check_lint() {
	if [ "${PHP_LINT^^}" = "TRUE" ]; then
		echo "Starting PHP linting..."
		find "${SRC_PATH}" -name "*.php" -type f -print0 | while IFS= read -r -d '' file; do
			php -l "$file"
			status=$?
			if [ $status -ne 0 ]; then
				echo "FAILURE: Linting failed - $file"
				exit 1
			fi
		done
		echo "PHP linting completed successfully."
	else
		echo "Skipping PHP linting."
	fi
}

# Sync files to the server using rsync and execute post-deploy script
sync_files() {
	SSH_SETTINGS="-v -p ${SSH_PORT} -i ${SSH_KEY_PATH} -o StrictHostKeyChecking=no -o ControlPath='${SSH_PATH}/ctl/%C'"

	#create multiplex connection
	ssh -nNf ${SSH_SETTINGS} -o ControlMaster=yes "${SSH_USER}"
	echo "Multiplex SSH connection established."

	# Sync files to Server
	set -x
	rsync --rsh="ssh ${SSH_SETTINGS}" \
		"${FLAGS_ARRAY[@]}" --chmod=D775,F664 \
		"${SRC_PATH}/" "${SERVER_DEST}"
	set +x

	check_script
	check_cache

	# Execute post-deploy script
	ssh ${SSH_SETTINGS} "${SSH_USER}" "${SCRIPT_COMMAND} ${CACHE_COMMAND}"

	# Close SSH multiplex connection
	ssh -O exit -o ControlPath="${SSH_PATH}/ctl/%C" "${SSH_USER}"
	echo "✅ Site has been deployed!"
}

# Check if post-deploy script exists and set permissions
check_script() {
	if [ -n "${SCRIPT}" ]; then
		if [ "${SERVER_TYPE^^}" = "CUSTOM" ]; then
			SCRIPT_PATH="${SSH_DEST}/${SCRIPT}"
		else
			SCRIPT_PATH="${SERVER_BASE_PATH}/${REMOTE_PATH}/${SCRIPT}"
		fi
		SCRIPT_COMMAND="bash ${SCRIPT_PATH}"
		echo "Script command: " ${SCRIPT_COMMAND}

		# Set permissions
		ssh ${SSH_SETTINGS} "${SSH_USER}" "chmod +x ${SCRIPT_PATH}"

		# Does file exist?
		ssh ${SSH_SETTINGS} "${SSH_USER}" "if [ -f ${SCRIPT_PATH} ]; then echo 'Script file found'; else echo 'Script file not found'; fi"
	fi
}

# Check cache clearing command
check_cache() {
	if [ "${CACHE_CLEAR^^}" = "TRUE" ]; then
		if [ "${SERVER_TYPE^^}" = "PRESSABLE" ]; then
			CACHE_COMMAND="&& wp --skip-plugins --skip-themes cache flush"
		elif [ "${SERVER_TYPE^^}" = "WPENGINE" ]; then
			CACHE_COMMAND="&& wp --skip-plugins --skip-themes page-cache flush && wp --skip-plugins --skip-themes cdn-cache flush"
		else
			CACHE_COMMAND=""
		fi
		echo "Cache command: ${CACHE_COMMAND}"
	else
		CACHE_COMMAND=""
	fi
}

# Main execution
validate
init
sync_files
