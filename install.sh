#!/usr/bin/env sh
# shellcheck shell=sh
# - - - - - - - - - - - - - - - - - - - - - - - - -
##@Version           :  202606181200-git
# @@Author           :  Jason Hempstead
# @@Contact          :  git-admin@casjaysdev.pro
# @@License          :  MIT or LICENSE.md
# @@ReadME           :  install.sh --help | README.md
# @@Copyright        :  Copyright: (c) 2026 Jason Hempstead, Casjays Developments
# @@Created          :  Tuesday, May 20, 2026 21:00 EDT
# @@File             :  install.sh
# @@Description      :  Idempotent POSIX installer/updater for a full Nextcloud stack
# @@Changelog        :  Initial version; NEXTCLOUD_ globals; MariaDB + Redis + cron; occ post-init
# @@TODO             :
# @@Other            :  Requires root or sudo; installs Docker Engine from official repos
# @@Resource         :  https://github.com/scriptmgr/nextcloud
# @@Terminal App     :  no
# @@sudo/root        :  yes
# @@Template         :  shell/sh
# - - - - - - - - - - - - - - - - - - - - - - - - -
# shellcheck disable=SC1001,SC1003,SC1091,SC2001,SC2003,SC2016,SC2031,SC2034,SC2090,SC2115,SC2120,SC2155,SC2199,SC2229,SC2317,SC2329
# - - - - - - - - - - - - - - - - - - - - - - - - -
VERSION="202606181200-git"
# - - - - - - - - - - - - - - - - - - - - - - - - -
APPNAME="${0##*/}"
RUN_USER="${USER:-root}"
SET_UID="$(id -u)"
SCRIPT_SRC_DIR="$(dirname -- "$0")"
# - - - - - - - - - - - - - - - - - - - - - - - - -
set -eu
umask 027
# - - - - - - - - - - - - - - - - - - - - - - - - -

# Root check — must be root or able to sudo for package installation and
# writing to /opt (default install path). Fail early with a clear message
# rather than obscure permission errors mid-install.
if [ "$SET_UID" != "0" ] && ! command -v sudo >/dev/null 2>&1; then
	printf "[ERR ] This script requires root or sudo. Re-run as root or install sudo.\n" >&2
	exit 1
fi

# - - - - - - - - - - - - - - - - - - - - - - - - -
# Defaults
# - - - - - - - - - - - - - - - - - - - - - - - - -
NEXTCLOUD_PREFIX="/opt/nextcloud"
NEXTCLOUD_ADMIN_USER="administrator"
NEXTCLOUD_ADMIN_PASS=""            # empty: loaded from .credentials or generated
NEXTCLOUD_PORT=""                  # empty: loaded from .credentials or randomly generated
NEXTCLOUD_LISTEN_ADDR="172.17.0.1" # Docker bridge gateway — reachable from host and containers
NEXTCLOUD_DOMAIN=""
NEXTCLOUD_DB_NAME="nextcloud"
NEXTCLOUD_DB_USER="nextcloud"
NEXTCLOUD_DB_PASS=""             # empty: loaded from .credentials or generated
NEXTCLOUD_DB_ROOT_PASS=""        # empty: loaded from .credentials or generated
NEXTCLOUD_SMTP_HOST="172.17.0.1" # Docker bridge gateway on Linux
NEXTCLOUD_SMTP_PORT="25"
NEXTCLOUD_SMTP_SECURE="" # '' | 'tls' | 'ssl'
NEXTCLOUD_SMTP_AUTH=""   # '' | 'LOGIN' | 'PLAIN' | 'CRAM-MD5'
NEXTCLOUD_SMTP_USER=""
NEXTCLOUD_SMTP_PASS=""
NEXTCLOUD_PHP_MEMORY="512M"
NEXTCLOUD_PHP_UPLOAD="512M"
NEXTCLOUD_NETWORK_NAME="nextcloud"
NEXTCLOUD_UPDATE_ONLY="false"
NEXTCLOUD_REMOVE="false"
# - - - - - - - - - - - - - - - - - - - - - - - - -
# Euro-Office defaults
# - - - - - - - - - - - - - - - - - - - - - - - - -
# empty: loaded from .credentials or randomly generated
EUROOFFICE_PORT=""
# empty: generated on first run
EUROOFFICE_JWT_SECRET=""
EUROOFFICE_ENABLED="true"
# - - - - - - - - - - - - - - - - - - - - - - - - -
# Runtime state flags (not CLI-settable)
# - - - - - - - - - - - - - - - - - - - - - - - - -
# true when admin password is generated this run (not loaded)
_ADMIN_PASS_NEW="false"
# true when --port was supplied on the command line
_PORT_EXPLICIT="false"
# true when --eurooffice-port was supplied on the command line
_EUROOFFICE_PORT_EXPLICIT="false"
# path of nginx vhost written this run (empty if skipped)
_NGINX_VHOST_FILE=""
# path of Euro-Office nginx vhost written this run (empty if skipped)
_EUROOFFICE_NGINX_VHOST_FILE=""

# - - - - - - - - - - - - - - - - - - - - - - - - -
# Helpers (POSIX)
# - - - - - - - - - - - - - - - - - - - - - - - - -
__log() { printf "%s\n" "$*"; }
__info() { printf "  %s\n" "$*"; }
__warn() { printf "  [WARN] %s\n" "$*" >&2; }
__err() { printf "  [ERR ] %s\n" "$*" >&2; }
__step() { printf "\n==> %s\n" "$*"; }

__need_cmd() {
	command -v "$1" >/dev/null 2>&1 || {
		__err "Missing required command: $1"
		exit 1
	}
}

# Generate a random password of the given length (default 32) using
# /dev/urandom. Characters are alphanumeric + common specials safe for
# most password fields.
__random_password() {
	_rp_len="${1:-32}"
	tr -dc 'A-Za-z0-9!@#$%^&*_+-' </dev/urandom | head -c "${_rp_len}"
}

# Generate a random hex string of the given byte count (default 32) using
# openssl when available, falling back to /dev/urandom + tr.
__random_hex() {
	_rh_bytes="${1:-32}"
	if command -v openssl >/dev/null 2>&1; then
		openssl rand -hex "$_rh_bytes"
	else
		tr -dc '0-9a-f' </dev/urandom | head -c $((_rh_bytes * 2))
	fi
}

# Generate a random port in the 62000-64999 range (Docker proxy allocation range).
# Loops until a port is not listed in ss -tlnp (i.e. free on the host).
__random_port() {
	_rp_port=""
	while true; do
		_rp_port="$(awk 'BEGIN { srand(); printf "%d\n", int(rand() * 3000) + 62000 }')"
		if ! ss -tlnp 2>/dev/null | grep -q -- ":${_rp_port}"; then
			break
		fi
	done
	printf '%d\n' "$_rp_port"
}

# Save key=value to a credentials file. Creates parent dirs and sets 600
# permissions. Replaces the key in-place if it already exists; appends and
# prints once on first save.
__save_credential() {
	_sc_file="${1:?Usage: __save_credential <file> <key> <value>}"
	_sc_key="${2:?}"
	_sc_val="${3:?}"
	_sc_dir="${_sc_file%/*}"
	[ "$_sc_dir" = "$_sc_file" ] && _sc_dir="."
	mkdir -p "$_sc_dir"
	if [ -f "$_sc_file" ] && grep -q -- "^${_sc_key}=" "$_sc_file"; then
		_sc_tmp="$(mktemp)"
		grep -v -- "^${_sc_key}=" "$_sc_file" >"$_sc_tmp"
		printf '%s=%s\n' "$_sc_key" "$_sc_val" >>"$_sc_tmp"
		mv "$_sc_tmp" "$_sc_file"
	else
		printf '%s=%s\n' "$_sc_key" "$_sc_val" >>"$_sc_file"
	fi
	chmod 600 "$_sc_file"
	if [ "$SET_UID" -eq 0 ]; then
		chown root:root "$_sc_file"
	else
		chown "${RUN_USER}:${RUN_USER}" "$_sc_file"
	fi
}

# Load the value of key from a credentials file. Prints the value and returns
# 0 on success; returns 1 if the file does not exist or the key is absent.
__load_credential() {
	_lc_file="${1:?Usage: __load_credential <file> <key>}"
	_lc_key="${2:?}"
	[ -f "$_lc_file" ] || return 1
	_lc_val="$(grep -- "^${_lc_key}=" "$_lc_file" | tail -n1 | cut -d= -f2-)"
	[ -n "$_lc_val" ] || return 1
	printf '%s\n' "$_lc_val"
}

# Double-quote a value for safe inclusion in a .env file.
# Escapes embedded backslashes, double-quotes, and dollar-signs.
# Docker Compose expands $VAR inside double-quoted strings unless $ is escaped as \$.
__env_quote() {
	printf '"%s"' "$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\$/\\$/g')"
}

__is_root() {
	[ "$SET_UID" = "0" ]
}

# Run a shell command as root (or via sudo).
# Pass the entire command as a single pre-quoted string.
__sudocmd() {
	if __is_root; then
		sh -c "$1"
	else
		__need_cmd sudo
		sudo sh -c "$1"
	fi
}

__has_systemd() {
	command -v systemctl >/dev/null 2>&1
}

__now_utc() { date -u +"%Y%m%dT%H%M%SZ"; }

# Returns the runtime FQDN via hostname -f. Returns 1 if unavailable.
__determine_hostname_name() {
	_fqdn="$(hostname -f 2>/dev/null)"
	if [ -n "$_fqdn" ]; then
		printf '%s\n' "$_fqdn"
		return 0
	fi
	return 1
}

# Returns the runtime domain name. Tries hostname -d first; falls back to
# stripping the first label from hostname -f. Returns 1 if both fail.
__determine_domain_name() {
	_domain="$(hostname -d 2>/dev/null | grep -v -- '(none)')"
	if [ -n "$_domain" ]; then
		printf '%s\n' "$_domain"
		return 0
	fi
	_fqdn="$(hostname -f 2>/dev/null)"
	if [ -n "$_fqdn" ] && [ "$_fqdn" != "${_fqdn#*.}" ]; then
		printf '%s\n' "${_fqdn#*.}"
		return 0
	fi
	return 1
}

# Returns 0 if $1 is a valid FQDN (at least two labels, each 1-63 chars,
# alphanumeric + interior hyphens, total length <= 253). Returns 1 otherwise.
__validate_fqdn() {
	_vf="${1:-}"
	[ -z "$_vf" ] && return 1
	[ "${#_vf}" -gt 253 ] && return 1
	# Must contain at least one dot (two or more labels).
	case "$_vf" in
	*.*) ;;
	*) return 1 ;;
	esac
	# Reject leading/trailing dots or hyphens and consecutive dots.
	case "$_vf" in
	.* | *.) return 1 ;;
	-* | *-) return 1 ;;
	*..*) return 1 ;;
	esac
	# Each label: 1-63 chars, alphanumeric + interior hyphens only.
	_vf_rest="$_vf"
	while [ -n "$_vf_rest" ]; do
		_label="${_vf_rest%%.*}"
		_vf_rest="${_vf_rest#*.}"
		[ "$_vf_rest" = "$_label" ] && _vf_rest=""
		[ -z "$_label" ] && return 1
		[ "${#_label}" -gt 63 ] && return 1
		_stripped="$(printf '%s' "$_label" | tr -d 'A-Za-z0-9-')"
		[ -n "$_stripped" ] && return 1
		case "$_label" in
		-* | *-) return 1 ;;
		esac
	done
	return 0
}

# - - - - - - - - - - - - - - - - - - - - - - - - -
# Help and version
# - - - - - - - - - - - - - - - - - - - - - - - - -
__help() {
	cat <<EOF
Nextcloud Installer / Updater (POSIX sh)

Usage: sh ${APPNAME} [OPTIONS]

Options:
  --path DIR, --prefix DIR    Install root (default: /opt/nextcloud)
  --admin-user NAME           Nextcloud admin username (default: administrator)
  --admin-pass PASS           Nextcloud admin password (default: random on first setup)
  --port N                    Host port to bind (default: random in 62000-64999, saved on first run)
  --domain HOST               Public hostname (auto-detected from hostname -f)
  --db-name NAME              MariaDB database name (default: nextcloud)
  --db-user USER              MariaDB database user (default: nextcloud)
  --db-pass PASS              MariaDB user password (default: random on first setup)
  --db-root-pass PASS         MariaDB root password (default: random on first setup)
  --smtp-host HOST            SMTP relay host (default: 172.17.0.1)
  --smtp-port PORT            SMTP relay port (default: 25)
  --smtp-secure MODE          '' (none), 'tls' (STARTTLS), or 'ssl' (SSL/TLS) (default: none)
  --smtp-auth METHOD          SMTP auth type: LOGIN, PLAIN, CRAM-MD5 (default: none)
  --smtp-user USER            SMTP username (if auth enabled)
  --smtp-pass PASS            SMTP password (if auth enabled)
  --php-memory LIMIT          PHP memory limit (default: 512M)
  --php-upload LIMIT          PHP upload limit (default: 512M)
  --network NAME              Docker network name (default: nextcloud)
                              Managed by Compose; created automatically on first start.
                              Join your reverse proxy to this network to reach Nextcloud.
  --listen-addr IP            Host IP Docker binds the HTTP port to (default: 172.17.0.1)
                              172.17.0.1 is the Docker bridge gateway; reachable from host and containers.
  --eurooffice-port N         Host port for Euro-Office document server (default: random in 62000-64999)
  --no-eurooffice             Skip Euro-Office document server installation
  --update                    Pull latest images and recreate (with backup)
  --remove                    Stop all containers, remove volumes, and delete the install directory
  -h, --help                  Show this help
  -v, --version               Show version and exit

Notes:
  Credentials (admin password, DB passwords) are generated on first run,
  saved to .credentials (mode 600), and embedded in .env. Re-runs load the
  saved credentials — passing --admin-pass or --db-pass after the first run
  has no effect (Nextcloud only applies them during initial setup).

  The admin password can be reset with:
    docker exec --user www-data nextcloud-app php occ user:resetpassword administrator

  Nextcloud runs behind a reverse proxy. Set --domain to the public hostname
  your proxy forwards to this host. The stack listens on 172.17.0.1:PORT.

  Access the administration panel at: https://DOMAIN/settings/admin

  When --domain is empty or a single-label hostname (e.g. localhost, myserver),
  http:// URLs are used — suitable for local testing only.
EOF
}

__version() {
	printf '%s\n' "$VERSION"
}

# - - - - - - - - - - - - - - - - - - - - - - - - -
# Argument parsing (getopts with -: trick for long options)
# - - - - - - - - - - - - - - - - - - - - - - - - -
__parse_args() {
	OPTIND=1
	while getopts ":hvy-:" _opt; do
		case "${_opt}" in
		h)
			__help
			exit 0
			;;
		v)
			__version
			exit 0
			;;
		y) ;; # kept for compatibility; script never prompts
		-)
			# For --flag value form: OPTARG is the flag name; value is at $OPTIND.
			case "${OPTARG}" in
			help)
				__help
				exit 0
				;;
			version)
				__version
				exit 0
				;;

			path | prefix)
				_idx="$OPTIND"
				OPTIND=$((OPTIND + 1))
				eval "_optval=\${${_idx}:-}"
				[ -z "${_optval:-}" ] && {
					__err "Option --${OPTARG} requires a value."
					exit 1
				}
				case "${_optval}" in -*)
					__err "Option --${OPTARG} requires a value (got flag '${_optval}' instead)."
					exit 1
					;;
				esac
				NEXTCLOUD_PREFIX="${_optval}"
				;;

			admin-user)
				_idx="$OPTIND"
				OPTIND=$((OPTIND + 1))
				eval "_optval=\${${_idx}:-}"
				[ -z "${_optval:-}" ] && {
					__err "Option --${OPTARG} requires a value."
					exit 1
				}
				case "${_optval}" in -*)
					__err "Option --${OPTARG} requires a value (got flag '${_optval}' instead)."
					exit 1
					;;
				esac
				NEXTCLOUD_ADMIN_USER="${_optval}"
				;;

			admin-pass)
				_idx="$OPTIND"
				OPTIND=$((OPTIND + 1))
				eval "_optval=\${${_idx}:-}"
				[ -z "${_optval:-}" ] && {
					__err "Option --${OPTARG} requires a value."
					exit 1
				}
				case "${_optval}" in -*)
					__err "Option --${OPTARG} requires a value (got flag '${_optval}' instead)."
					exit 1
					;;
				esac
				NEXTCLOUD_ADMIN_PASS="${_optval}"
				;;

			port)
				_idx="$OPTIND"
				OPTIND=$((OPTIND + 1))
				eval "_optval=\${${_idx}:-}"
				[ -z "${_optval:-}" ] && {
					__err "Option --${OPTARG} requires a value."
					exit 1
				}
				case "${_optval}" in -*)
					__err "Option --${OPTARG} requires a value (got flag '${_optval}' instead)."
					exit 1
					;;
				esac
				NEXTCLOUD_PORT="${_optval}"
				_PORT_EXPLICIT="true"
				;;

			domain)
				_idx="$OPTIND"
				OPTIND=$((OPTIND + 1))
				eval "_optval=\${${_idx}:-}"
				[ -z "${_optval:-}" ] && {
					__err "Option --${OPTARG} requires a value."
					exit 1
				}
				case "${_optval}" in -*)
					__err "Option --${OPTARG} requires a value (got flag '${_optval}' instead)."
					exit 1
					;;
				esac
				NEXTCLOUD_DOMAIN="${_optval}"
				;;

			db-name)
				_idx="$OPTIND"
				OPTIND=$((OPTIND + 1))
				eval "_optval=\${${_idx}:-}"
				[ -z "${_optval:-}" ] && {
					__err "Option --${OPTARG} requires a value."
					exit 1
				}
				case "${_optval}" in -*)
					__err "Option --${OPTARG} requires a value (got flag '${_optval}' instead)."
					exit 1
					;;
				esac
				NEXTCLOUD_DB_NAME="${_optval}"
				;;

			db-user)
				_idx="$OPTIND"
				OPTIND=$((OPTIND + 1))
				eval "_optval=\${${_idx}:-}"
				[ -z "${_optval:-}" ] && {
					__err "Option --${OPTARG} requires a value."
					exit 1
				}
				case "${_optval}" in -*)
					__err "Option --${OPTARG} requires a value (got flag '${_optval}' instead)."
					exit 1
					;;
				esac
				NEXTCLOUD_DB_USER="${_optval}"
				;;

			db-pass)
				_idx="$OPTIND"
				OPTIND=$((OPTIND + 1))
				eval "_optval=\${${_idx}:-}"
				[ -z "${_optval:-}" ] && {
					__err "Option --${OPTARG} requires a value."
					exit 1
				}
				case "${_optval}" in -*)
					__err "Option --${OPTARG} requires a value (got flag '${_optval}' instead)."
					exit 1
					;;
				esac
				NEXTCLOUD_DB_PASS="${_optval}"
				;;

			db-root-pass)
				_idx="$OPTIND"
				OPTIND=$((OPTIND + 1))
				eval "_optval=\${${_idx}:-}"
				[ -z "${_optval:-}" ] && {
					__err "Option --${OPTARG} requires a value."
					exit 1
				}
				case "${_optval}" in -*)
					__err "Option --${OPTARG} requires a value (got flag '${_optval}' instead)."
					exit 1
					;;
				esac
				NEXTCLOUD_DB_ROOT_PASS="${_optval}"
				;;

			smtp-host)
				_idx="$OPTIND"
				OPTIND=$((OPTIND + 1))
				eval "_optval=\${${_idx}:-}"
				[ -z "${_optval:-}" ] && {
					__err "Option --${OPTARG} requires a value."
					exit 1
				}
				case "${_optval}" in -*)
					__err "Option --${OPTARG} requires a value (got flag '${_optval}' instead)."
					exit 1
					;;
				esac
				NEXTCLOUD_SMTP_HOST="${_optval}"
				;;

			smtp-port)
				_idx="$OPTIND"
				OPTIND=$((OPTIND + 1))
				eval "_optval=\${${_idx}:-}"
				[ -z "${_optval:-}" ] && {
					__err "Option --${OPTARG} requires a value."
					exit 1
				}
				case "${_optval}" in -*)
					__err "Option --${OPTARG} requires a value (got flag '${_optval}' instead)."
					exit 1
					;;
				esac
				NEXTCLOUD_SMTP_PORT="${_optval}"
				;;

			smtp-secure)
				_idx="$OPTIND"
				OPTIND=$((OPTIND + 1))
				eval "_optval=\${${_idx}:-}"
				[ -z "${_optval:-}" ] && {
					__err "Option --${OPTARG} requires a value."
					exit 1
				}
				case "${_optval}" in -*)
					__err "Option --${OPTARG} requires a value (got flag '${_optval}' instead)."
					exit 1
					;;
				esac
				NEXTCLOUD_SMTP_SECURE="${_optval}"
				;;

			smtp-auth)
				_idx="$OPTIND"
				OPTIND=$((OPTIND + 1))
				eval "_optval=\${${_idx}:-}"
				[ -z "${_optval:-}" ] && {
					__err "Option --${OPTARG} requires a value."
					exit 1
				}
				case "${_optval}" in -*)
					__err "Option --${OPTARG} requires a value (got flag '${_optval}' instead)."
					exit 1
					;;
				esac
				NEXTCLOUD_SMTP_AUTH="${_optval}"
				;;

			smtp-user)
				_idx="$OPTIND"
				OPTIND=$((OPTIND + 1))
				eval "_optval=\${${_idx}:-}"
				[ -z "${_optval:-}" ] && {
					__err "Option --${OPTARG} requires a value."
					exit 1
				}
				case "${_optval}" in -*)
					__err "Option --${OPTARG} requires a value (got flag '${_optval}' instead)."
					exit 1
					;;
				esac
				NEXTCLOUD_SMTP_USER="${_optval}"
				;;

			smtp-pass)
				_idx="$OPTIND"
				OPTIND=$((OPTIND + 1))
				eval "_optval=\${${_idx}:-}"
				[ -z "${_optval:-}" ] && {
					__err "Option --${OPTARG} requires a value."
					exit 1
				}
				case "${_optval}" in -*)
					__err "Option --${OPTARG} requires a value (got flag '${_optval}' instead)."
					exit 1
					;;
				esac
				NEXTCLOUD_SMTP_PASS="${_optval}"
				;;

			php-memory)
				_idx="$OPTIND"
				OPTIND=$((OPTIND + 1))
				eval "_optval=\${${_idx}:-}"
				[ -z "${_optval:-}" ] && {
					__err "Option --${OPTARG} requires a value."
					exit 1
				}
				case "${_optval}" in -*)
					__err "Option --${OPTARG} requires a value (got flag '${_optval}' instead)."
					exit 1
					;;
				esac
				NEXTCLOUD_PHP_MEMORY="${_optval}"
				;;

			php-upload)
				_idx="$OPTIND"
				OPTIND=$((OPTIND + 1))
				eval "_optval=\${${_idx}:-}"
				[ -z "${_optval:-}" ] && {
					__err "Option --${OPTARG} requires a value."
					exit 1
				}
				case "${_optval}" in -*)
					__err "Option --${OPTARG} requires a value (got flag '${_optval}' instead)."
					exit 1
					;;
				esac
				NEXTCLOUD_PHP_UPLOAD="${_optval}"
				;;

			network)
				_idx="$OPTIND"
				OPTIND=$((OPTIND + 1))
				eval "_optval=\${${_idx}:-}"
				[ -z "${_optval:-}" ] && {
					__err "Option --${OPTARG} requires a value."
					exit 1
				}
				case "${_optval}" in -*)
					__err "Option --${OPTARG} requires a value (got flag '${_optval}' instead)."
					exit 1
					;;
				esac
				NEXTCLOUD_NETWORK_NAME="${_optval}"
				;;

			listen-addr)
				_idx="$OPTIND"
				OPTIND=$((OPTIND + 1))
				eval "_optval=\${${_idx}:-}"
				[ -z "${_optval:-}" ] && {
					__err "Option --${OPTARG} requires a value."
					exit 1
				}
				case "${_optval}" in -*)
					__err "Option --${OPTARG} requires a value (got flag '${_optval}' instead)."
					exit 1
					;;
				esac
				NEXTCLOUD_LISTEN_ADDR="${_optval}"
				;;

			eurooffice-port)
				_idx="$OPTIND"
				OPTIND=$((OPTIND + 1))
				eval "_optval=\${${_idx}:-}"
				[ -z "${_optval:-}" ] && {
					__err "Option --${OPTARG} requires a value."
					exit 1
				}
				case "${_optval}" in -*)
					__err "Option --${OPTARG} requires a value (got flag '${_optval}' instead)."
					exit 1
					;;
				esac
				EUROOFFICE_PORT="${_optval}"
				_EUROOFFICE_PORT_EXPLICIT="true"
				;;

			no-eurooffice) EUROOFFICE_ENABLED="false" ;;

			update) NEXTCLOUD_UPDATE_ONLY="true" ;;
			remove) NEXTCLOUD_REMOVE="true" ;;
			yes | non-interactive) ;; # kept for compatibility; script never prompts

			*)
				__err "Unknown option: --${OPTARG}"
				exit 1
				;;
			esac
			;;
		?)
			__err "Unknown option: -${OPTARG}"
			exit 1
			;;
		esac
	done
}

# - - - - - - - - - - - - - - - - - - - - - - - - -
# Parse arguments
# - - - - - - - - - - - - - - - - - - - - - - - - -
__parse_args "$@"

# - - - - - - - - - - - - - - - - - - - - - - - - -
# Post-parse validation and normalisation
# - - - - - - - - - - - - - - - - - - - - - - - - -

# Auto-detect domain from the host's FQDN when --domain was not supplied.
if [ -z "$NEXTCLOUD_DOMAIN" ]; then
	_detected_fqdn="$(__determine_domain_name 2>/dev/null || true)"
	if [ -n "$_detected_fqdn" ] && __validate_fqdn "$_detected_fqdn"; then
		NEXTCLOUD_DOMAIN="$_detected_fqdn"
		__info "Auto-detected domain from hostname: $NEXTCLOUD_DOMAIN"
	else
		__warn "Could not auto-detect a valid FQDN from 'hostname -f' (got: '${_detected_fqdn:-none}')."
		__warn "Running in insecure/local mode. Pass --domain to set a real domain."
	fi
fi

# Validate --port when explicitly provided (not yet when empty; port is generated in __load_or_generate_credentials).
if [ "$_PORT_EXPLICIT" = "true" ]; then
	case "$NEXTCLOUD_PORT" in
	*[!0-9]* | '')
		__err "--port must be a number between 1 and 65535 (got: '$NEXTCLOUD_PORT')."
		exit 1
		;;
	esac
	if [ "$NEXTCLOUD_PORT" -lt 1 ] || [ "$NEXTCLOUD_PORT" -gt 65535 ]; then
		__err "--port must be between 1 and 65535 (got: $NEXTCLOUD_PORT)."
		exit 1
	fi
fi

# Validate --smtp-port: same 1-65535 range check as --port.
case "$NEXTCLOUD_SMTP_PORT" in
*[!0-9]* | '')
	__err "--smtp-port must be a number between 1 and 65535 (got: '$NEXTCLOUD_SMTP_PORT')."
	exit 1
	;;
esac
if [ "$NEXTCLOUD_SMTP_PORT" -lt 1 ] || [ "$NEXTCLOUD_SMTP_PORT" -gt 65535 ]; then
	__err "--smtp-port must be between 1 and 65535 (got: $NEXTCLOUD_SMTP_PORT)."
	exit 1
fi

# Validate --eurooffice-port when explicitly provided.
if [ "$_EUROOFFICE_PORT_EXPLICIT" = "true" ]; then
	case "$EUROOFFICE_PORT" in
	*[!0-9]* | '')
		__err "--eurooffice-port must be a number between 1 and 65535 (got: '$EUROOFFICE_PORT')."
		exit 1
		;;
	esac
	if [ "$EUROOFFICE_PORT" -lt 1 ] || [ "$EUROOFFICE_PORT" -gt 65535 ]; then
		__err "--eurooffice-port must be between 1 and 65535 (got: $EUROOFFICE_PORT)."
		exit 1
	fi
fi

# Normalise domain: lowercase only. Reject trailing dot, spaces, and
# shell metacharacters — they cause issues in HTTP URLs and TLS SAN matching.
if [ -n "$NEXTCLOUD_DOMAIN" ]; then
	NEXTCLOUD_DOMAIN="$(printf '%s' "$NEXTCLOUD_DOMAIN" | tr '[:upper:]' '[:lower:]')"
	case "$NEXTCLOUD_DOMAIN" in
	*' '* | *'	'*)
		__err "Invalid domain: must not contain spaces."
		exit 1
		;;
	esac
	case "$NEXTCLOUD_DOMAIN" in
	*['$''!''`''#''&''('')''|''<''>''{''}'' ']*)
		__err "Invalid domain '$NEXTCLOUD_DOMAIN': shell metacharacters are not allowed."
		exit 1
		;;
	esac
	_dom_check="$(printf '%s' "$NEXTCLOUD_DOMAIN" | tr -d 'A-Za-z0-9.-')"
	if [ -n "$_dom_check" ]; then
		__err "Invalid domain '$NEXTCLOUD_DOMAIN': only letters, digits, hyphens, and dots are allowed."
		exit 1
	fi
	case "$NEXTCLOUD_DOMAIN" in
	*..*)
		__err "Invalid domain '$NEXTCLOUD_DOMAIN': consecutive dots (empty label) are not allowed."
		exit 1
		;;
	esac
	case "$NEXTCLOUD_DOMAIN" in
	.* | *.)
		__err "Invalid domain '$NEXTCLOUD_DOMAIN': must not start or end with a dot."
		exit 1
		;;
	-* | *- | *-.* | *.-*)
		__err "Invalid domain '$NEXTCLOUD_DOMAIN': must not start or end with a hyphen."
		exit 1
		;;
	esac
fi

# - - - - - - - - - - - - - - - - - - - - - - - - -
# Directory layout (derived from NEXTCLOUD_PREFIX)
# - - - - - - - - - - - - - - - - - - - - - - - - -
NEXTCLOUD_COMPOSE_DIR="$NEXTCLOUD_PREFIX"
NEXTCLOUD_ENV_FILE="$NEXTCLOUD_COMPOSE_DIR/.env"
NEXTCLOUD_COMPOSE_FILE="$NEXTCLOUD_COMPOSE_DIR/compose.yaml"
NEXTCLOUD_DATA_DIR="$NEXTCLOUD_COMPOSE_DIR/data"
NEXTCLOUD_DB_DIR="$NEXTCLOUD_COMPOSE_DIR/db"
NEXTCLOUD_BACKUP_DIR="$NEXTCLOUD_COMPOSE_DIR/backups"
NEXTCLOUD_ADMIN_OUT="$NEXTCLOUD_COMPOSE_DIR/admin.credentials"
NEXTCLOUD_CRED_FILE="$NEXTCLOUD_COMPOSE_DIR/.credentials"

mkdir -p "$NEXTCLOUD_DATA_DIR" "$NEXTCLOUD_DB_DIR" "$NEXTCLOUD_BACKUP_DIR"

# - - - - - - - - - - - - - - - - - - - - - - - - -
# Package manager detection
# - - - - - - - - - - - - - - - - - - - - - - - - -
__detect_pm() {
	if [ -r /etc/os-release ]; then
		. /etc/os-release
		case "$ID" in
		debian | ubuntu | raspbian | linuxmint)
			echo "apt"
			return
			;;
		fedora)
			echo "dnf"
			return
			;;
		rhel | rocky | almalinux | centos)
			if command -v dnf >/dev/null 2>&1; then echo "dnf"; else echo "yum"; fi
			return
			;;
		opensuse* | sles)
			echo "zypper"
			return
			;;
		arch | manjaro | endeavouros)
			echo "pacman"
			return
			;;
		esac
	fi
	command -v apt-get >/dev/null 2>&1 && {
		echo apt
		return
	}
	command -v dnf >/dev/null 2>&1 && {
		echo dnf
		return
	}
	command -v yum >/dev/null 2>&1 && {
		echo yum
		return
	}
	command -v zypper >/dev/null 2>&1 && {
		echo zypper
		return
	}
	command -v pacman >/dev/null 2>&1 && {
		echo pacman
		return
	}
	__err "Unsupported distribution (no known package manager)."
	exit 1
}

# - - - - - - - - - - - - - - - - - - - - - - - - -
# Docker installation
# - - - - - - - - - - - - - - - - - - - - - - - - -
__install_docker_official() {
	_pm="$(__detect_pm)"
	__info "Detected package manager: $_pm"

	case "$_pm" in
	apt)
		__need_cmd apt-get
		__need_cmd gpg
		__sudocmd "apt-get update"
		__sudocmd "apt-get install -y ca-certificates curl gnupg lsb-release"
		mkdir -p /etc/apt/keyrings
		if [ ! -f /etc/apt/keyrings/docker.gpg ]; then
			_distro_id="$(
				. /etc/os-release
				echo "$ID"
			)"
			curl -fsSL "https://download.docker.com/linux/${_distro_id}/gpg" |
				gpg --dearmor >/tmp/nextcloud-docker.gpg
			__sudocmd "install -m 0644 -o root -g root -D /tmp/nextcloud-docker.gpg /etc/apt/keyrings/docker.gpg"
			rm -f /tmp/nextcloud-docker.gpg
		fi
		_arch="$(dpkg --print-architecture)"
		_distro_id="$(
			. /etc/os-release
			echo "$ID"
		)"
		_codename="$(
			. /etc/os-release
			echo "$VERSION_CODENAME"
		)"
		printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/%s %s stable\n' \
			"$_arch" "$_distro_id" "$_codename" |
			__sudocmd "tee /etc/apt/sources.list.d/docker.list >/dev/null"
		__sudocmd "apt-get update"
		__sudocmd "apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin"
		;;
	dnf)
		__need_cmd dnf
		__sudocmd "dnf -y install dnf-plugins-core"
		_distro_id="$(
			. /etc/os-release
			echo "$ID"
		)"
		# Docker publishes repos for 'centos' and 'fedora' only.
		# AlmaLinux, Rocky, and other RHEL rebuilds must use the centos repo.
		case "$_distro_id" in
		fedora) _docker_repo_id="fedora" ;;
		*) _docker_repo_id="centos" ;;
		esac
		__sudocmd "dnf config-manager --add-repo https://download.docker.com/linux/${_docker_repo_id}/docker-ce.repo"
		__sudocmd "dnf -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin"
		;;
	yum)
		__need_cmd yum
		__sudocmd "yum -y install yum-utils"
		__sudocmd "yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo"
		__sudocmd "yum -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin || true"
		;;
	zypper)
		__need_cmd zypper
		__sudocmd "zypper -n install ca-certificates curl gnupg2"
		_distro_id="$(
			. /etc/os-release
			echo "$ID"
		)"
		__sudocmd "zypper -n addrepo https://download.docker.com/linux/${_distro_id}/docker-ce.repo || true"
		__sudocmd "zypper -n refresh"
		__sudocmd "zypper -n install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin"
		;;
	pacman)
		__need_cmd pacman
		__sudocmd "pacman -Sy --noconfirm docker docker-compose-plugin"
		;;
	*)
		__err "Unsupported package manager: $_pm"
		exit 1
		;;
	esac

	if __has_systemd; then
		__sudocmd "systemctl enable --now docker"
	else
		__warn "systemd not detected. Please start and enable the Docker daemon manually."
	fi
}

__ensure_docker() {
	if ! command -v docker >/dev/null 2>&1; then
		__info "Docker not found; installing from official repository..."
		__info "If automatic install fails, install docker-ce and docker-compose-plugin manually:"
		__info "  https://docs.docker.com/engine/install/"
		__install_docker_official
	fi
	if ! docker compose version >/dev/null 2>&1; then
		__err "Docker Compose v2 plugin missing. Install docker-compose-plugin and re-run."
		exit 1
	fi
}

# - - - - - - - - - - - - - - - - - - - - - - - - -
# Credential management (load or generate; idempotent)
# - - - - - - - - - - - - - - - - - - - - - - - - -
__load_or_generate_credentials() {
	# Port: honour --port if explicitly provided; otherwise load from credentials or generate random.
	if [ "$_PORT_EXPLICIT" = "true" ]; then
		__save_credential "$NEXTCLOUD_CRED_FILE" NEXTCLOUD_PORT "$NEXTCLOUD_PORT"
	else
		NEXTCLOUD_PORT="$(__load_credential "$NEXTCLOUD_CRED_FILE" NEXTCLOUD_PORT 2>/dev/null)" || {
			NEXTCLOUD_PORT="$(__random_port)"
			__save_credential "$NEXTCLOUD_CRED_FILE" NEXTCLOUD_PORT "$NEXTCLOUD_PORT"
		}
	fi

	# Admin password: honour --admin-pass if provided; otherwise load or generate.
	if [ -n "$NEXTCLOUD_ADMIN_PASS" ]; then
		_admin_pass="$NEXTCLOUD_ADMIN_PASS"
		__save_credential "$NEXTCLOUD_CRED_FILE" NEXTCLOUD_ADMIN_PASSWORD "$_admin_pass"
	else
		_admin_pass="$(__load_credential "$NEXTCLOUD_CRED_FILE" NEXTCLOUD_ADMIN_PASSWORD 2>/dev/null)" || {
			_admin_pass="$(__random_password 24)"
			__save_credential "$NEXTCLOUD_CRED_FILE" NEXTCLOUD_ADMIN_PASSWORD "$_admin_pass"
			_ADMIN_PASS_NEW="true"
		}
	fi

	# DB user password.
	if [ -n "$NEXTCLOUD_DB_PASS" ]; then
		_db_pass="$NEXTCLOUD_DB_PASS"
		__save_credential "$NEXTCLOUD_CRED_FILE" NEXTCLOUD_DB_PASSWORD "$_db_pass"
	else
		_db_pass="$(__load_credential "$NEXTCLOUD_CRED_FILE" NEXTCLOUD_DB_PASSWORD 2>/dev/null)" || {
			_db_pass="$(__random_password 32)"
			__save_credential "$NEXTCLOUD_CRED_FILE" NEXTCLOUD_DB_PASSWORD "$_db_pass"
		}
	fi

	# DB root password.
	if [ -n "$NEXTCLOUD_DB_ROOT_PASS" ]; then
		_db_root_pass="$NEXTCLOUD_DB_ROOT_PASS"
		__save_credential "$NEXTCLOUD_CRED_FILE" NEXTCLOUD_DB_ROOT_PASSWORD "$_db_root_pass"
	else
		_db_root_pass="$(__load_credential "$NEXTCLOUD_CRED_FILE" NEXTCLOUD_DB_ROOT_PASSWORD 2>/dev/null)" || {
			_db_root_pass="$(__random_password 32)"
			__save_credential "$NEXTCLOUD_CRED_FILE" NEXTCLOUD_DB_ROOT_PASSWORD "$_db_root_pass"
		}
	fi

	# Euro-Office port: honour --eurooffice-port if explicitly provided; otherwise load or generate.
	if [ "$EUROOFFICE_ENABLED" = "true" ]; then
		if [ "$_EUROOFFICE_PORT_EXPLICIT" = "true" ]; then
			_eurooffice_port="$EUROOFFICE_PORT"
			__save_credential "$NEXTCLOUD_CRED_FILE" EUROOFFICE_PORT "$_eurooffice_port"
		else
			_eurooffice_port="$(__load_credential "$NEXTCLOUD_CRED_FILE" EUROOFFICE_PORT 2>/dev/null)" || {
				_eurooffice_port="$(__random_port)"
				__save_credential "$NEXTCLOUD_CRED_FILE" EUROOFFICE_PORT "$_eurooffice_port"
			}
		fi

		# Euro-Office JWT secret: generate once and persist; never user-supplied.
		_eurooffice_jwt="$(__load_credential "$NEXTCLOUD_CRED_FILE" EUROOFFICE_JWT_SECRET 2>/dev/null)" || {
			_eurooffice_jwt="$(__random_hex 32)"
			__save_credential "$NEXTCLOUD_CRED_FILE" EUROOFFICE_JWT_SECRET "$_eurooffice_jwt"
		}
	else
		_eurooffice_port=""
		_eurooffice_jwt=""
	fi
}
NEXTCLOUD_FQDN="$(__determine_hostname_name)"
if [ "$NEXTCLOUD_FQDN" = "$NEXTCLOUD_DOMAIN" ]; then
	NEXTCLOUD_TRUSTED_DOMAINS="$NEXTCLOUD_DOMAIN"
else
	NEXTCLOUD_TRUSTED_DOMAINS="$NEXTCLOUD_DOMAIN $NEXTCLOUD_FQDN"
fi
# - - - - - - - - - - - - - - - - - - - - - - - - -
# .env file (idempotent: written once only)
# - - - - - - - - - - - - - - - - - - - - - - - - -
__write_env_file() {
	if [ ! -s "$NEXTCLOUD_ENV_FILE" ]; then
		# INSECURE mode: http for single-label or empty domain; https otherwise.
		if [ -z "$NEXTCLOUD_DOMAIN" ] || [ "${NEXTCLOUD_DOMAIN%%.*}" = "$NEXTCLOUD_DOMAIN" ]; then
			_nc_scheme="http"
		else
			_nc_scheme="https"
		fi

		# Quote credentials for safe inclusion in the .env file.
		_admin_pass_q="$(__env_quote "$_admin_pass")"
		_db_pass_q="$(__env_quote "$_db_pass")"
		_db_root_pass_q="$(__env_quote "$_db_root_pass")"
		_smtp_pass_q="$(__env_quote "$NEXTCLOUD_SMTP_PASS")"

		cat >"$NEXTCLOUD_ENV_FILE" <<EOF
# Autogenerated by install.sh on $(date -u)
# Safe to edit and re-run install.sh. Keep this file secure (mode 600).

COMPOSE_PROJECT_NAME=nextcloud

# --- Nextcloud image ---
NEXTCLOUD_DOCKER_IMAGE=nextcloud
NEXTCLOUD_DOCKER_TAG=apache

# --- Network ---
# Host IP Docker binds the HTTP port to (172.17.0.1 = Docker bridge gateway).
NEXTCLOUD_LISTEN_ADDR=$NEXTCLOUD_LISTEN_ADDR
# Host port exposed by the reverse proxy.
NEXTCLOUD_HTTP_PORT=$NEXTCLOUD_PORT
# Public domain name.
NEXTCLOUD_DOMAIN=${NEXTCLOUD_DOMAIN:-localhost}
# Full URL that Nextcloud advertises to clients.
NEXTCLOUD_URL=${_nc_scheme}://${NEXTCLOUD_DOMAIN:-localhost}

# --- Admin credentials (applied on FIRST start only) ---
# To reset the admin password after initial setup, use:
#   docker exec --user www-data nextcloud-app php occ user:resetpassword $NEXTCLOUD_ADMIN_USER
NEXTCLOUD_ADMIN_USER=$NEXTCLOUD_ADMIN_USER
NEXTCLOUD_ADMIN_PASSWORD=${_admin_pass_q}

# --- Database (MariaDB) ---
NEXTCLOUD_DB_NAME=$NEXTCLOUD_DB_NAME
NEXTCLOUD_DB_USER=$NEXTCLOUD_DB_USER
NEXTCLOUD_DB_PASSWORD=${_db_pass_q}
NEXTCLOUD_DB_ROOT_PASSWORD=${_db_root_pass_q}

# --- Redis ---
NEXTCLOUD_REDIS_HOST=redis
NEXTCLOUD_REDIS_PORT=6379

# --- SMTP / email ---
NEXTCLOUD_SMTP_HOST=$NEXTCLOUD_SMTP_HOST
NEXTCLOUD_SMTP_PORT=$NEXTCLOUD_SMTP_PORT
NEXTCLOUD_SMTP_SECURE=$NEXTCLOUD_SMTP_SECURE
NEXTCLOUD_SMTP_AUTH=$NEXTCLOUD_SMTP_AUTH
NEXTCLOUD_SMTP_USER=$NEXTCLOUD_SMTP_USER
NEXTCLOUD_SMTP_PASS=${_smtp_pass_q}
# MAIL_FROM_ADDRESS is the left part of the From: address (before @).
NEXTCLOUD_MAIL_FROM=no-reply
NEXTCLOUD_MAIL_DOMAIN=${NEXTCLOUD_DOMAIN:-localhost}

# --- PHP tuning ---
NEXTCLOUD_PHP_MEMORY=$NEXTCLOUD_PHP_MEMORY
NEXTCLOUD_PHP_UPLOAD=$NEXTCLOUD_PHP_UPLOAD

# --- Docker network ---
# Compose manages the 'nextcloud' bridge network automatically.
# Attach your reverse proxy to it to reach Nextcloud without exposing extra ports.
NEXTCLOUD_NETWORK=$NEXTCLOUD_NETWORK_NAME

# --- Euro-Office document server ---
EUROOFFICE_LISTEN_ADDR=$NEXTCLOUD_LISTEN_ADDR
EUROOFFICE_HTTP_PORT=$_eurooffice_port
EUROOFFICE_JWT_SECRET=$_eurooffice_jwt
EOF
		chmod 600 "$NEXTCLOUD_ENV_FILE"

		if [ ! -s "$NEXTCLOUD_ADMIN_OUT" ]; then
			printf "Admin user    : %s\nAdmin pass    : %s\nAdmin URL     : %s://%s/settings/admin\nDB user       : %s\nDB pass       : %s\nDB name       : %s\n" \
				"$NEXTCLOUD_ADMIN_USER" "$_admin_pass" \
				"$_nc_scheme" "${NEXTCLOUD_DOMAIN:-localhost}" \
				"$NEXTCLOUD_DB_USER" "$_db_pass" "$NEXTCLOUD_DB_NAME" >"$NEXTCLOUD_ADMIN_OUT"
			chmod 600 "$NEXTCLOUD_ADMIN_OUT"
		fi
	else
		if [ -n "$NEXTCLOUD_ADMIN_PASS" ]; then
			__warn "NEXTCLOUD_ADMIN_PASSWORD is ignored after first initialization."
			__warn "Reset the admin password with: docker exec --user www-data nextcloud-app php occ user:resetpassword $NEXTCLOUD_ADMIN_USER"
		fi
	fi

	# Append Euro-Office variables to existing .env files that predate this feature.
	if [ "$EUROOFFICE_ENABLED" = "true" ] && ! grep -q -- "^EUROOFFICE_HTTP_PORT=" "$NEXTCLOUD_ENV_FILE"; then
		printf '\n# --- Euro-Office document server ---\nEUROOFFICE_LISTEN_ADDR=%s\nEUROOFFICE_HTTP_PORT=%s\nEUROOFFICE_JWT_SECRET=%s\n' \
			"$NEXTCLOUD_LISTEN_ADDR" "$_eurooffice_port" "$_eurooffice_jwt" >>"$NEXTCLOUD_ENV_FILE"
	fi
}

# - - - - - - - - - - - - - - - - - - - - - - - - -
# Compose file (regenerated on every run)
# - - - - - - - - - - - - - - - - - - - - - - - - -
__write_compose_file() {
	# NOTE: This file is auto-generated by install.sh on every run.
	# Do not edit it directly — changes will be overwritten.
	# Customise .env (preserved across runs) or re-run install.sh instead.
	printf '# nginx proxy address - http://%s:%s\n' "${NEXTCLOUD_LISTEN_ADDR:-172.17.0.1}" "$NEXTCLOUD_HTTP_PORT" >"$NEXTCLOUD_COMPOSE_FILE"
	cat >>"$NEXTCLOUD_COMPOSE_FILE" <<'EOF'
# Auto-generated by install.sh — do not edit; re-run install.sh to regenerate.
---
name: nextcloud

x-logging: &default-logging
  driver: json-file
  options:
    max-size: "5m"
    max-file: "1"

services:

  nextcloud:
    image: ${NEXTCLOUD_DOCKER_IMAGE:-nextcloud}:${NEXTCLOUD_DOCKER_TAG:-apache}
    container_name: nextcloud-app
    networks:
      - nextcloud
    pull_policy: always
    restart: always
    depends_on:
      db:
        condition: service_healthy
      redis:
        condition: service_healthy
    ports:
      - "${NEXTCLOUD_LISTEN_ADDR:-172.17.0.1}:${NEXTCLOUD_HTTP_PORT}:80"
    environment:
      NEXTCLOUD_ADMIN_USER: "${NEXTCLOUD_ADMIN_USER:-administrator}"
      NEXTCLOUD_ADMIN_PASSWORD: "${NEXTCLOUD_ADMIN_PASSWORD}"
      NEXTCLOUD_TRUSTED_DOMAINS: "${NEXTCLOUD_TRUSTED_DOMAINS:-localhost}"
      MYSQL_HOST: "db"
      MYSQL_DATABASE: "${NEXTCLOUD_DB_NAME:-nextcloud}"
      MYSQL_USER: "${NEXTCLOUD_DB_USER:-nextcloud}"
      MYSQL_PASSWORD: "${NEXTCLOUD_DB_PASSWORD}"
      REDIS_HOST: "${NEXTCLOUD_REDIS_HOST:-redis}"
      REDIS_HOST_PORT: "${NEXTCLOUD_REDIS_PORT:-6379}"
      SMTP_HOST: "${NEXTCLOUD_SMTP_HOST:-172.17.0.1}"
      SMTP_PORT: "${NEXTCLOUD_SMTP_PORT:-25}"
      SMTP_SECURE: "${NEXTCLOUD_SMTP_SECURE:-}"
      SMTP_AUTHTYPE: "${NEXTCLOUD_SMTP_AUTH:-NONE}"
      SMTP_NAME: "${NEXTCLOUD_SMTP_USER:-}"
      SMTP_PASSWORD: "${NEXTCLOUD_SMTP_PASS:-}"
      MAIL_FROM_ADDRESS: "${NEXTCLOUD_MAIL_FROM:-no-reply}"
      MAIL_DOMAIN: "${NEXTCLOUD_MAIL_DOMAIN:-localhost}"
      PHP_MEMORY_LIMIT: "${NEXTCLOUD_PHP_MEMORY:-512M}"
      PHP_UPLOAD_LIMIT: "${NEXTCLOUD_PHP_UPLOAD:-512M}"
    healthcheck:
      test: ["CMD-SHELL", "curl -fsS http://localhost/status.php | grep -q -- '\"installed\":true'"]
      interval: 30s
      timeout: 10s
      retries: 10
      start_period: 2m
    volumes:
      - ${NEXTCLOUD_DATA_DIR:-nextcloud-data}:/var/www/html
    logging: *default-logging

  db:
    image: mariadb:lts
    container_name: nextcloud-db
    networks:
      - nextcloud
    pull_policy: always
    restart: always
    environment:
      MYSQL_ROOT_PASSWORD: "${NEXTCLOUD_DB_ROOT_PASSWORD}"
      MYSQL_DATABASE: "${NEXTCLOUD_DB_NAME:-nextcloud}"
      MYSQL_USER: "${NEXTCLOUD_DB_USER:-nextcloud}"
      MYSQL_PASSWORD: "${NEXTCLOUD_DB_PASSWORD}"
    volumes:
      - ${NEXTCLOUD_DB_DIR:-nextcloud-db}:/var/lib/mysql
    healthcheck:
      test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 30s
    logging: *default-logging

  redis:
    image: redis:alpine
    container_name: nextcloud-redis
    networks:
      - nextcloud
    pull_policy: always
    restart: always
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 30s
      timeout: 10s
      retries: 3
    logging: *default-logging

  cron:
    image: ${NEXTCLOUD_DOCKER_IMAGE:-nextcloud}:${NEXTCLOUD_DOCKER_TAG:-apache}
    container_name: nextcloud-cron
    networks:
      - nextcloud
    pull_policy: always
    restart: always
    depends_on:
      nextcloud:
        condition: service_healthy
    entrypoint: /cron.sh
    volumes:
      - ${NEXTCLOUD_DATA_DIR:-nextcloud-data}:/var/www/html
    logging: *default-logging
EOF

	# Conditionally append the Euro-Office document server service.
	if [ "$EUROOFFICE_ENABLED" = "true" ]; then
		cat >>"$NEXTCLOUD_COMPOSE_FILE" <<'EOF'

  eurooffice:
    image: ghcr.io/euro-office/documentserver:latest
    container_name: eurooffice
    networks:
      - nextcloud
    pull_policy: always
    restart: always
    ports:
      - "${EUROOFFICE_LISTEN_ADDR:-172.17.0.1}:${EUROOFFICE_HTTP_PORT}:80"
    environment:
      JWT_ENABLED: "true"
      JWT_SECRET: "${EUROOFFICE_JWT_SECRET}"
      EXAMPLE_ENABLED: "false"
      ALLOW_PRIVATE_IP_ADDRESS: "true"
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost/healthcheck"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 1m
    volumes:
      - eurooffice-data:/var/lib/euro-office/documentserver
      - eurooffice-logs:/var/log/euro-office/documentserver
      - eurooffice-config:/etc/euro-office/documentserver
    logging: *default-logging
EOF
	fi

	cat >>"$NEXTCLOUD_COMPOSE_FILE" <<'EOF'

networks:
  nextcloud:
    name: nextcloud
    external: false

volumes:
  nextcloud-data:
  nextcloud-db:
EOF

	# Conditionally append Euro-Office named volumes.
	if [ "$EUROOFFICE_ENABLED" = "true" ]; then
		cat >>"$NEXTCLOUD_COMPOSE_FILE" <<'EOF'
  eurooffice-data:
  eurooffice-logs:
  eurooffice-config:
EOF
	fi
}

# - - - - - - - - - - - - - - - - - - - - - - - - -
# Backup (safe before updates)
# - - - - - - - - - - - - - - - - - - - - - - - - -
__snapshot_backup() {
	_ts="$(__now_utc)"
	_bdir="$NEXTCLOUD_BACKUP_DIR/$_ts"
	__info "Creating backup snapshot at $_bdir ..."
	mkdir -p "$_bdir"

	# Credentials and env (critical — failure is fatal for the backup).
	for _f in ".env" ".credentials" "admin.credentials"; do
		if [ -f "$NEXTCLOUD_COMPOSE_DIR/$_f" ]; then
			cp -- "$NEXTCLOUD_COMPOSE_DIR/$_f" "$_bdir/$_f" 2>/dev/null ||
				__warn "Could not back up $_f; continuing."
		fi
	done

	# Data snapshot — warn if large.
	if command -v du >/dev/null 2>&1; then
		_data_mb="$(du -sm "$NEXTCLOUD_DATA_DIR" 2>/dev/null | cut -f1)"
		if [ "${_data_mb:-0}" -gt 10240 ]; then
			__warn "Data directory is ${_data_mb} MB; backup may take some time."
		fi
	fi
	tar -C "$NEXTCLOUD_COMPOSE_DIR" -czf "$_bdir/data.tgz" "$(basename "$NEXTCLOUD_DATA_DIR")" 2>/dev/null ||
		__warn "Data backup failed; continuing (non-fatal)."

	# DB snapshot via mysqldump inside the container.
	__info "Dumping database..."
	_db_pass_bk="$(__load_credential "$NEXTCLOUD_CRED_FILE" NEXTCLOUD_DB_PASSWORD 2>/dev/null)" || _db_pass_bk=""
	if [ -n "$_db_pass_bk" ]; then
		docker exec nextcloud-db \
			sh -c "mysqldump -u\"${NEXTCLOUD_DB_USER}\" -p\"${_db_pass_bk}\" \"${NEXTCLOUD_DB_NAME}\"" \
			>"$_bdir/nextcloud-db.sql" 2>/dev/null ||
			__warn "Database dump failed; continuing (non-fatal)."
		chmod 600 "$_bdir/nextcloud-db.sql" 2>/dev/null || true
	else
		__warn "DB credentials not found in .credentials; skipping DB dump."
	fi

	__info "Backup snapshot complete: $_bdir"
}

# - - - - - - - - - - - - - - - - - - - - - - - - -
# Wait for Nextcloud to complete installation
# - - - - - - - - - - - - - - - - - - - - - - - - -
__wait_for_nextcloud() {
	__info "Waiting for Nextcloud to initialize (this may take a few minutes on first run)..."
	_poll_addr="${NEXTCLOUD_LISTEN_ADDR:-172.17.0.1}"
	_tries=0
	while [ "$_tries" -lt 72 ]; do
		_status="$(curl -q -LSs --max-time 5 "http://${_poll_addr}:${NEXTCLOUD_PORT}/status.php" 2>/dev/null || true)"
		if printf '%s' "$_status" | grep -q -- '"installed":true'; then
			__info "Nextcloud is installed and responding."
			return 0
		fi
		sleep 5
		_tries=$((_tries + 1))
	done
	__warn "Nextcloud did not complete installation within 6 minutes."
	__warn "Check logs: cd $NEXTCLOUD_COMPOSE_DIR && docker compose logs -f nextcloud"
	return 1
}

# - - - - - - - - - - - - - - - - - - - - - - - - -
# Post-installation configuration via occ
# - - - - - - - - - - - - - - - - - - - - - - - - -
__configure_nextcloud() {
	# Determine scheme for overwrite URL.
	if [ -n "$NEXTCLOUD_DOMAIN" ] && [ "${NEXTCLOUD_DOMAIN%%.*}" != "$NEXTCLOUD_DOMAIN" ]; then
		_occ_scheme="https"
	else
		_occ_scheme="http"
	fi

	# Helper wrapper to run occ as www-data inside the container.
	_occ_base="docker exec --user www-data nextcloud-app php occ"

	# Set the canonical URL for CLI-generated links (e.g. share links, notifications).
	if [ -n "$NEXTCLOUD_DOMAIN" ]; then
		${_occ_base} config:system:set overwrite.cli.url \
			--value="${_occ_scheme}://${NEXTCLOUD_DOMAIN}/" >/dev/null 2>&1 || true
	fi

	# Tell Nextcloud the upstream protocol so it generates https:// links
	# even though Apache inside the container receives plain HTTP from the proxy.
	if [ "$_occ_scheme" = "https" ]; then
		${_occ_base} config:system:set overwriteprotocol --value="https" >/dev/null 2>&1 || true
	fi

	# Trust all IPs as proxies so X-Forwarded-For and X-Forwarded-Proto
	# headers are honoured from any upstream reverse proxy.
	${_occ_base} config:system:set trusted_proxies 0 --value="0.0.0.0/0" >/dev/null 2>&1 || true

	# Use APCu for local in-process caching (already available in the apache image).
	${_occ_base} config:system:set memcache.local --value='\OC\Memcache\APCu' >/dev/null 2>&1 || true

	# Use Redis for distributed/locking cache.
	${_occ_base} config:system:set memcache.distributed --value='\OC\Memcache\Redis' >/dev/null 2>&1 || true
	${_occ_base} config:system:set memcache.locking --value='\OC\Memcache\Redis' >/dev/null 2>&1 || true
	${_occ_base} config:system:set redis host --value="redis" >/dev/null 2>&1 || true
	${_occ_base} config:system:set redis port --value="6379" --type=integer >/dev/null 2>&1 || true

	# Default phone region (used for phone number formatting in contacts).
	${_occ_base} config:system:set default_phone_region --value="US" >/dev/null 2>&1 || true

	# Disable skeleton directory — new users start with an empty home folder.
	${_occ_base} config:system:set skeletondirectory --value="" >/dev/null 2>&1 || true

	# Set maximum chunk size for uploads to avoid proxy timeouts.
	${_occ_base} config:system:set max_chunk_size --value="0" --type=integer >/dev/null 2>&1 || true

	# Set admin email to {admin_user}@{domain}.
	_occ_admin_email="${NEXTCLOUD_ADMIN_USER}@${NEXTCLOUD_DOMAIN:-localhost}"
	${_occ_base} user:setting "${NEXTCLOUD_ADMIN_USER}" settings email "${_occ_admin_email}" >/dev/null 2>&1 || true
}

# - - - - - - - - - - - - - - - - - - - - - - - - -
# nginx vhost (created when nginx is installed and a valid FQDN domain is set)
# - - - - - - - - - - - - - - - - - - - - - - - - -
__write_nginx_vhost() {
	# Skip if domain is empty or single-label (local/no-TLS mode).
	if [ -z "$NEXTCLOUD_DOMAIN" ] || [ "${NEXTCLOUD_DOMAIN%%.*}" = "$NEXTCLOUD_DOMAIN" ]; then
		return 0
	fi
	# Skip if nginx is not installed.
	if ! command -v nginx >/dev/null 2>&1; then
		return 0
	fi

	_vhost_dir="/etc/nginx/vhosts.d"
	_vhost_file="${_vhost_dir}/${NEXTCLOUD_DOMAIN}.conf"

	# Skip if the file already exists and contains our marker.
	if [ -f "$_vhost_file" ] && grep -q -- "# reverse proxy for ${NEXTCLOUD_DOMAIN}" "$_vhost_file"; then
		return 0
	fi

	mkdir -p "$_vhost_dir"

	_vhost_tmp="$(mktemp)"
	cat >"$_vhost_tmp" <<EOF
# reverse proxy for ${NEXTCLOUD_DOMAIN}

server {
  listen                                    443 ssl;
  listen                                    [::]:443 ssl;
  server_name                               ${NEXTCLOUD_DOMAIN};
  access_log                                /var/log/nginx/access.${NEXTCLOUD_DOMAIN}.log;
  error_log                                 /var/log/nginx/error.${NEXTCLOUD_DOMAIN}.log info;
  keepalive_timeout                         75 75;
  client_max_body_size                      0;
  chunked_transfer_encoding                 on;
  add_header Strict-Transport-Security      "max-age=31536000; includeSubDomains";
  ssl_protocols                             TLSv1.2 TLSv1.3;
  ssl_ciphers                               ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384;
  ssl_prefer_server_ciphers                 off;
  ssl_session_cache                         shared:SSL:10m;
  ssl_session_timeout                       1d;
  ssl_certificate                           /etc/letsencrypt/live/domain/fullchain.pem;
  ssl_certificate_key                       /etc/letsencrypt/live/domain/privkey.pem;

  location / {
    send_timeout                            3600;
    proxy_connect_timeout                   3600;
    proxy_send_timeout                      3600;
    proxy_read_timeout                      3600;
    proxy_http_version                      1.1;
    proxy_buffering                         off;
    proxy_request_buffering                 off;
    proxy_ssl_verify                        off;
    proxy_set_header Host                   \$host;
    proxy_set_header X-Real-IP              \$remote_addr;
    proxy_set_header X-Forwarded-For        \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto      \$scheme;
    proxy_set_header X-Forwarded-Scheme     \$scheme;
    proxy_set_header X-Forwarded-Port       \$server_port;
    proxy_set_header Upgrade                \$http_upgrade;
    proxy_set_header Connection             \$connection_upgrade;
    proxy_set_header Accept-Encoding        "";
    proxy_redirect                          http:// https://;
    proxy_pass                              http://172.17.0.1:${NEXTCLOUD_PORT};
  }

  include /etc/nginx/global.d/*.conf;
}
EOF

	mv "$_vhost_tmp" "$_vhost_file"
	chmod 644 "$_vhost_file"
	_NGINX_VHOST_FILE="$_vhost_file"

	# Test nginx config and reload gracefully if valid.
	if nginx -t >/dev/null 2>&1; then
		nginx -s reload >/dev/null 2>&1 || true
	else
		__warn "nginx -t failed after writing vhost; check ${_vhost_file} before reloading nginx."
	fi
}

# - - - - - - - - - - - - - - - - - - - - - - - - -
# Euro-Office nginx vhost (office.DOMAIN → EUROOFFICE_HTTP_PORT)
# - - - - - - - - - - - - - - - - - - - - - - - - -
__write_eurooffice_nginx_vhost() {
	# Skip if Euro-Office is disabled.
	[ "$EUROOFFICE_ENABLED" = "true" ] || return 0
	# Skip if domain is empty or single-label (local/no-TLS mode).
	if [ -z "$NEXTCLOUD_DOMAIN" ] || [ "${NEXTCLOUD_DOMAIN%%.*}" = "$NEXTCLOUD_DOMAIN" ]; then
		return 0
	fi
	# Skip if nginx is not installed.
	if ! command -v nginx >/dev/null 2>&1; then
		return 0
	fi

	_eo_domain="office.${NEXTCLOUD_DOMAIN}"
	_eo_vhost_dir="/etc/nginx/vhosts.d"
	_eo_vhost_file="${_eo_vhost_dir}/${_eo_domain}.conf"

	# Skip if the file already exists and contains our marker.
	if [ -f "$_eo_vhost_file" ] && grep -q -- "# reverse proxy for ${_eo_domain}" "$_eo_vhost_file"; then
		return 0
	fi

	mkdir -p "$_eo_vhost_dir"

	_eo_vhost_tmp="$(mktemp)"
	cat >"$_eo_vhost_tmp" <<EOF
# reverse proxy for ${_eo_domain}

server {
  listen                                    443 ssl;
  listen                                    [::]:443 ssl;
  server_name                               ${_eo_domain};
  access_log                                /var/log/nginx/access.${_eo_domain}.log;
  error_log                                 /var/log/nginx/error.${_eo_domain}.log info;
  keepalive_timeout                         75 75;
  client_max_body_size                      0;
  chunked_transfer_encoding                 on;
  add_header Strict-Transport-Security      "max-age=31536000; includeSubDomains";
  ssl_protocols                             TLSv1.2 TLSv1.3;
  ssl_ciphers                               ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384;
  ssl_prefer_server_ciphers                 off;
  ssl_session_cache                         shared:SSL:10m;
  ssl_session_timeout                       1d;
  ssl_certificate                           /etc/letsencrypt/live/domain/fullchain.pem;
  ssl_certificate_key                       /etc/letsencrypt/live/domain/privkey.pem;

  location / {
    send_timeout                            3600;
    proxy_connect_timeout                   3600;
    proxy_send_timeout                      3600;
    proxy_read_timeout                      3600;
    proxy_http_version                      1.1;
    proxy_buffering                         off;
    proxy_request_buffering                 off;
    proxy_ssl_verify                        off;
    proxy_set_header Host                   \$host;
    proxy_set_header X-Real-IP              \$remote_addr;
    proxy_set_header X-Forwarded-For        \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto      \$scheme;
    proxy_set_header X-Forwarded-Scheme     \$scheme;
    proxy_set_header X-Forwarded-Port       \$server_port;
    proxy_set_header Upgrade                \$http_upgrade;
    proxy_set_header Connection             \$connection_upgrade;
    proxy_set_header Accept-Encoding        "";
    proxy_redirect                          http:// https://;
    proxy_pass                              http://172.17.0.1:${_eurooffice_port};
  }

  include /etc/nginx/global.d/*.conf;
}
EOF

	mv "$_eo_vhost_tmp" "$_eo_vhost_file"
	chmod 644 "$_eo_vhost_file"
	_EUROOFFICE_NGINX_VHOST_FILE="$_eo_vhost_file"

	# Test nginx config and reload gracefully if valid.
	if nginx -t >/dev/null 2>&1; then
		nginx -s reload >/dev/null 2>&1 || true
	else
		__warn "nginx -t failed after writing Euro-Office vhost; check ${_eo_vhost_file} before reloading nginx."
	fi
}

# - - - - - - - - - - - - - - - - - - - - - - - - -
# Remove (--remove): stop stack, drop volumes, delete install directory
# - - - - - - - - - - - - - - - - - - - - - - - - -
__remove_stack() {
	if [ ! -d "$NEXTCLOUD_PREFIX" ] && [ ! -f "$NEXTCLOUD_COMPOSE_FILE" ]; then
		__warn "No installation found at $NEXTCLOUD_PREFIX — nothing to remove."
		exit 0
	fi

	__step "Tearing down Nextcloud stack"
	if [ -f "$NEXTCLOUD_COMPOSE_FILE" ]; then
		cd "$NEXTCLOUD_COMPOSE_DIR"
		docker compose down -v --remove-orphans 2>/dev/null || true
	fi

	__step "Removing install directory"
	[ -n "$NEXTCLOUD_PREFIX" ] || {
		__err "NEXTCLOUD_PREFIX is empty — refusing to remove."
		exit 1
	}
	rm -rf -- "$NEXTCLOUD_PREFIX"
	__info "Removed $NEXTCLOUD_PREFIX"
}

# - - - - - - - - - - - - - - - - - - - - - - - - -
# Main flow
# - - - - - - - - - - - - - - - - - - - - - - - - -
__main() {
	printf "Nextcloud Installer %s\n" "$VERSION"

	if [ "$NEXTCLOUD_REMOVE" = "true" ]; then
		__remove_stack
		exit 0
	fi

	# Guard: --update on a path with no existing installation is almost always
	# a typo (wrong --path). Warn loudly so the user can abort.
	if [ "$NEXTCLOUD_UPDATE_ONLY" = "true" ] && [ ! -f "$NEXTCLOUD_ENV_FILE" ]; then
		__warn "--update specified but no existing installation found at $NEXTCLOUD_COMPOSE_DIR"
		__warn "(no .env found). Creating a fresh installation. Use Ctrl-C to abort."
		sleep 3
	fi

	__step "Checking prerequisites"
	__ensure_docker

	__step "Loading credentials"
	__load_or_generate_credentials

	__step "Writing configuration"
	__write_env_file
	__write_compose_file

	cd "$NEXTCLOUD_COMPOSE_DIR"

	if [ "$NEXTCLOUD_UPDATE_ONLY" = "true" ]; then
		__step "Updating Nextcloud stack"
		__snapshot_backup
		docker exec --user www-data nextcloud-app php occ maintenance:mode --on >/dev/null 2>&1 || true
		__info "Pulling latest images..."
		docker compose pull
		__info "Recreating services..."
		docker compose up -d --remove-orphans
		sleep 10
		docker exec --user www-data nextcloud-app php occ maintenance:mode --off >/dev/null 2>&1 || true
		docker exec --user www-data nextcloud-app php occ upgrade >/dev/null 2>&1 || true
		docker exec --user www-data nextcloud-app php occ app:update --all >/dev/null 2>&1 || true
	else
		__step "Starting Nextcloud stack"
		docker compose up -d
	fi

	_nc_up=true
	__wait_for_nextcloud || _nc_up=false

	if [ "$_nc_up" = "true" ] && [ "$NEXTCLOUD_UPDATE_ONLY" = "false" ]; then
		__step "Applying Nextcloud configuration"
		__configure_nextcloud
	fi

	__step "Writing nginx vhost"
	__write_nginx_vhost
	__write_eurooffice_nginx_vhost

	# Derive display scheme from domain.
	if [ -z "$NEXTCLOUD_DOMAIN" ] || [ "${NEXTCLOUD_DOMAIN%%.*}" = "$NEXTCLOUD_DOMAIN" ]; then
		_sum_scheme="http"
	else
		_sum_scheme="https"
	fi

	printf "\n"
	printf "══════════════════════════════════════════════════════════════\n"
	if [ "$_nc_up" = "true" ]; then
		printf " Nextcloud is running\n"
	else
		printf " Nextcloud stack started — initialization may still be in progress\n"
		printf " Check logs: docker compose -f %s/compose.yaml logs -f nextcloud\n" "$NEXTCLOUD_COMPOSE_DIR"
	fi
	printf "══════════════════════════════════════════════════════════════\n"
	if [ -n "$NEXTCLOUD_DOMAIN" ]; then
		printf "  URL          : %s://%s/\n" "$_sum_scheme" "$NEXTCLOUD_DOMAIN"
		printf "  Admin panel  : %s://%s/settings/admin\n" "$_sum_scheme" "$NEXTCLOUD_DOMAIN"
	fi
	printf "  Admin user   : %s\n" "$NEXTCLOUD_ADMIN_USER"
	if [ "$_ADMIN_PASS_NEW" = "true" ]; then
		printf "  Admin pass   : %s  ← shown once; save it now\n" "$_admin_pass"
	fi
	printf "  Proxy bind   : %s:%s\n" "$NEXTCLOUD_LISTEN_ADDR" "$NEXTCLOUD_PORT"
	printf "  Network      : %s\n" "$NEXTCLOUD_NETWORK_NAME"
	if [ -n "$_NGINX_VHOST_FILE" ]; then
		printf "  Nginx vhost  : %s\n" "$_NGINX_VHOST_FILE"
	fi
	printf "  Install dir  : %s\n" "$NEXTCLOUD_COMPOSE_DIR"
	printf "  Credentials  : %s  (mode 600)\n" "$NEXTCLOUD_CRED_FILE"
	printf "\n"
	printf "  Manage : cd %s && docker compose ps\n" "$NEXTCLOUD_COMPOSE_DIR"
	printf "  Update : sh install.sh --update --path %s\n" "$NEXTCLOUD_COMPOSE_DIR"
	printf "══════════════════════════════════════════════════════════════\n"

	if [ "$EUROOFFICE_ENABLED" = "true" ]; then
		if [ -n "$NEXTCLOUD_DOMAIN" ] && [ "${NEXTCLOUD_DOMAIN%%.*}" != "$NEXTCLOUD_DOMAIN" ]; then
			_eo_sum_url="https://office.${NEXTCLOUD_DOMAIN}/"
		else
			_eo_sum_url="http://${NEXTCLOUD_LISTEN_ADDR}:${_eurooffice_port}/"
		fi
		printf "\n"
		printf "══════════════════════════════════════════════════════════════\n"
		printf " Euro-Office document server\n"
		printf "══════════════════════════════════════════════════════════════\n"
		printf "  URL          : %s\n" "$_eo_sum_url"
		printf "  Proxy bind   : %s:%s\n" "$NEXTCLOUD_LISTEN_ADDR" "$_eurooffice_port"
		printf "  JWT secret   : %s\n" "$_eurooffice_jwt"
		if [ -n "$_EUROOFFICE_NGINX_VHOST_FILE" ]; then
			printf "  Nginx vhost  : %s\n" "$_EUROOFFICE_NGINX_VHOST_FILE"
		fi
		printf "\n"
		printf "  To connect Nextcloud to Euro-Office:\n"
		printf "  1. Install the 'Euro-Office integration' app from the Nextcloud App Store\n"
		printf "     (Apps → Office & text → Euro-Office integration → Download and enable)\n"
		printf "  2. Go to Settings → Administration → Euro-Office\n"
		printf "  3. Enter URL  : %s\n" "$_eo_sum_url"
		printf "  4. Enter JWT  : %s\n" "$_eurooffice_jwt"
		printf "  5. Click Save\n"
		printf "══════════════════════════════════════════════════════════════\n"
	fi
}

# - - - - - - - - - - - - - - - - - - - - - - - - -
__main
# ex: ts=2 sw=2 et filetype=sh
