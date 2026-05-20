#!/usr/bin/env sh
# shellcheck shell=sh
# - - - - - - - - - - - - - - - - - - - - - - - - -
##@Version           :  YYYYMMDDHHMM-git
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
VERSION="YYYYMMDDHHMM-git"
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
NEXTCLOUD_PORT="8080"
NEXTCLOUD_DOMAIN=""
NEXTCLOUD_DB_NAME="nextcloud"
NEXTCLOUD_DB_USER="nextcloud"
NEXTCLOUD_DB_PASS=""               # empty: loaded from .credentials or generated
NEXTCLOUD_DB_ROOT_PASS=""          # empty: loaded from .credentials or generated
NEXTCLOUD_SMTP_HOST="172.17.0.1"  # Docker bridge gateway on Linux
NEXTCLOUD_SMTP_PORT="25"
NEXTCLOUD_SMTP_SECURE=""           # '' | 'tls' | 'ssl'
NEXTCLOUD_SMTP_AUTH=""             # '' | 'LOGIN' | 'PLAIN' | 'CRAM-MD5'
NEXTCLOUD_SMTP_USER=""
NEXTCLOUD_SMTP_PASS=""
NEXTCLOUD_PHP_MEMORY="512M"
NEXTCLOUD_PHP_UPLOAD="512M"
NEXTCLOUD_NETWORK_NAME="nextcloud-net"
NEXTCLOUD_UPDATE_ONLY="false"

# - - - - - - - - - - - - - - - - - - - - - - - - -
# Helpers (POSIX)
# - - - - - - - - - - - - - - - - - - - - - - - - -
__log()  { printf "%s\n" "$*"; }
__info() { printf "[INFO] %s\n" "$*"; }
__warn() { printf "[WARN] %s\n" "$*" >&2; }
__err()  { printf "[ERR ] %s\n" "$*" >&2; }

__need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { __err "Missing required command: $1"; exit 1; }
}

# Generate a random password of the given length (default 32) using
# /dev/urandom. Characters are alphanumeric + common specials safe for
# most password fields.
__random_password() {
  _rp_len="${1:-32}"
  tr -dc 'A-Za-z0-9!@#$%^&*_+-' </dev/urandom | head -c "${_rp_len}"
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
    grep -v -- "^${_sc_key}=" "$_sc_file" > "$_sc_tmp"
    printf '%s=%s\n' "$_sc_key" "$_sc_val" >> "$_sc_tmp"
    mv "$_sc_tmp" "$_sc_file"
  else
    printf '%s=%s\n' "$_sc_key" "$_sc_val" >> "$_sc_file"
    printf 'Generated %s: %s\n' "$_sc_key" "$_sc_val"
    printf 'Saved to: %s\n' "$_sc_file"
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
  _domain="$(hostname -d 2>/dev/null)"
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
    .*|*.) return 1 ;;
    -*|*-) return 1 ;;
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
      -*|*-) return 1 ;;
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
  --port N                    Host port to bind (default: 8080)
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
  --network NAME              Docker network name (default: nextcloud-net)
                              Created automatically if it does not exist.
                              Join your reverse proxy to this network to reach Nextcloud.
  --update                    Pull latest images and recreate (with backup)
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
  your proxy forwards to this host. The stack listens on 127.0.0.1:PORT.

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
      h) __help; exit 0 ;;
      v) __version; exit 0 ;;
      y) ;;  # kept for compatibility; script never prompts
      -)
        # For --flag value form: OPTARG is the flag name; value is at $OPTIND.
        case "${OPTARG}" in
          help)    __help; exit 0 ;;
          version) __version; exit 0 ;;

          path|prefix)
            _idx="$OPTIND"; OPTIND=$((OPTIND + 1))
            eval "_optval=\${${_idx}:-}"
            [ -z "${_optval:-}" ] && { __err "Option --${OPTARG} requires a value."; exit 1; }
            case "${_optval}" in -*) __err "Option --${OPTARG} requires a value (got flag '${_optval}' instead)."; exit 1 ;; esac
            NEXTCLOUD_PREFIX="${_optval}" ;;

          admin-user)
            _idx="$OPTIND"; OPTIND=$((OPTIND + 1))
            eval "_optval=\${${_idx}:-}"
            [ -z "${_optval:-}" ] && { __err "Option --${OPTARG} requires a value."; exit 1; }
            case "${_optval}" in -*) __err "Option --${OPTARG} requires a value (got flag '${_optval}' instead)."; exit 1 ;; esac
            NEXTCLOUD_ADMIN_USER="${_optval}" ;;

          admin-pass)
            _idx="$OPTIND"; OPTIND=$((OPTIND + 1))
            eval "_optval=\${${_idx}:-}"
            [ -z "${_optval:-}" ] && { __err "Option --${OPTARG} requires a value."; exit 1; }
            case "${_optval}" in -*) __err "Option --${OPTARG} requires a value (got flag '${_optval}' instead)."; exit 1 ;; esac
            NEXTCLOUD_ADMIN_PASS="${_optval}" ;;

          port)
            _idx="$OPTIND"; OPTIND=$((OPTIND + 1))
            eval "_optval=\${${_idx}:-}"
            [ -z "${_optval:-}" ] && { __err "Option --${OPTARG} requires a value."; exit 1; }
            case "${_optval}" in -*) __err "Option --${OPTARG} requires a value (got flag '${_optval}' instead)."; exit 1 ;; esac
            NEXTCLOUD_PORT="${_optval}" ;;

          domain)
            _idx="$OPTIND"; OPTIND=$((OPTIND + 1))
            eval "_optval=\${${_idx}:-}"
            [ -z "${_optval:-}" ] && { __err "Option --${OPTARG} requires a value."; exit 1; }
            case "${_optval}" in -*) __err "Option --${OPTARG} requires a value (got flag '${_optval}' instead)."; exit 1 ;; esac
            NEXTCLOUD_DOMAIN="${_optval}" ;;

          db-name)
            _idx="$OPTIND"; OPTIND=$((OPTIND + 1))
            eval "_optval=\${${_idx}:-}"
            [ -z "${_optval:-}" ] && { __err "Option --${OPTARG} requires a value."; exit 1; }
            case "${_optval}" in -*) __err "Option --${OPTARG} requires a value (got flag '${_optval}' instead)."; exit 1 ;; esac
            NEXTCLOUD_DB_NAME="${_optval}" ;;

          db-user)
            _idx="$OPTIND"; OPTIND=$((OPTIND + 1))
            eval "_optval=\${${_idx}:-}"
            [ -z "${_optval:-}" ] && { __err "Option --${OPTARG} requires a value."; exit 1; }
            case "${_optval}" in -*) __err "Option --${OPTARG} requires a value (got flag '${_optval}' instead)."; exit 1 ;; esac
            NEXTCLOUD_DB_USER="${_optval}" ;;

          db-pass)
            _idx="$OPTIND"; OPTIND=$((OPTIND + 1))
            eval "_optval=\${${_idx}:-}"
            [ -z "${_optval:-}" ] && { __err "Option --${OPTARG} requires a value."; exit 1; }
            case "${_optval}" in -*) __err "Option --${OPTARG} requires a value (got flag '${_optval}' instead)."; exit 1 ;; esac
            NEXTCLOUD_DB_PASS="${_optval}" ;;

          db-root-pass)
            _idx="$OPTIND"; OPTIND=$((OPTIND + 1))
            eval "_optval=\${${_idx}:-}"
            [ -z "${_optval:-}" ] && { __err "Option --${OPTARG} requires a value."; exit 1; }
            case "${_optval}" in -*) __err "Option --${OPTARG} requires a value (got flag '${_optval}' instead)."; exit 1 ;; esac
            NEXTCLOUD_DB_ROOT_PASS="${_optval}" ;;

          smtp-host)
            _idx="$OPTIND"; OPTIND=$((OPTIND + 1))
            eval "_optval=\${${_idx}:-}"
            [ -z "${_optval:-}" ] && { __err "Option --${OPTARG} requires a value."; exit 1; }
            case "${_optval}" in -*) __err "Option --${OPTARG} requires a value (got flag '${_optval}' instead)."; exit 1 ;; esac
            NEXTCLOUD_SMTP_HOST="${_optval}" ;;

          smtp-port)
            _idx="$OPTIND"; OPTIND=$((OPTIND + 1))
            eval "_optval=\${${_idx}:-}"
            [ -z "${_optval:-}" ] && { __err "Option --${OPTARG} requires a value."; exit 1; }
            case "${_optval}" in -*) __err "Option --${OPTARG} requires a value (got flag '${_optval}' instead)."; exit 1 ;; esac
            NEXTCLOUD_SMTP_PORT="${_optval}" ;;

          smtp-secure)
            _idx="$OPTIND"; OPTIND=$((OPTIND + 1))
            eval "_optval=\${${_idx}:-}"
            [ -z "${_optval:-}" ] && { __err "Option --${OPTARG} requires a value."; exit 1; }
            case "${_optval}" in -*) __err "Option --${OPTARG} requires a value (got flag '${_optval}' instead)."; exit 1 ;; esac
            NEXTCLOUD_SMTP_SECURE="${_optval}" ;;

          smtp-auth)
            _idx="$OPTIND"; OPTIND=$((OPTIND + 1))
            eval "_optval=\${${_idx}:-}"
            [ -z "${_optval:-}" ] && { __err "Option --${OPTARG} requires a value."; exit 1; }
            case "${_optval}" in -*) __err "Option --${OPTARG} requires a value (got flag '${_optval}' instead)."; exit 1 ;; esac
            NEXTCLOUD_SMTP_AUTH="${_optval}" ;;

          smtp-user)
            _idx="$OPTIND"; OPTIND=$((OPTIND + 1))
            eval "_optval=\${${_idx}:-}"
            [ -z "${_optval:-}" ] && { __err "Option --${OPTARG} requires a value."; exit 1; }
            case "${_optval}" in -*) __err "Option --${OPTARG} requires a value (got flag '${_optval}' instead)."; exit 1 ;; esac
            NEXTCLOUD_SMTP_USER="${_optval}" ;;

          smtp-pass)
            _idx="$OPTIND"; OPTIND=$((OPTIND + 1))
            eval "_optval=\${${_idx}:-}"
            [ -z "${_optval:-}" ] && { __err "Option --${OPTARG} requires a value."; exit 1; }
            case "${_optval}" in -*) __err "Option --${OPTARG} requires a value (got flag '${_optval}' instead)."; exit 1 ;; esac
            NEXTCLOUD_SMTP_PASS="${_optval}" ;;

          php-memory)
            _idx="$OPTIND"; OPTIND=$((OPTIND + 1))
            eval "_optval=\${${_idx}:-}"
            [ -z "${_optval:-}" ] && { __err "Option --${OPTARG} requires a value."; exit 1; }
            case "${_optval}" in -*) __err "Option --${OPTARG} requires a value (got flag '${_optval}' instead)."; exit 1 ;; esac
            NEXTCLOUD_PHP_MEMORY="${_optval}" ;;

          php-upload)
            _idx="$OPTIND"; OPTIND=$((OPTIND + 1))
            eval "_optval=\${${_idx}:-}"
            [ -z "${_optval:-}" ] && { __err "Option --${OPTARG} requires a value."; exit 1; }
            case "${_optval}" in -*) __err "Option --${OPTARG} requires a value (got flag '${_optval}' instead)."; exit 1 ;; esac
            NEXTCLOUD_PHP_UPLOAD="${_optval}" ;;

          network)
            _idx="$OPTIND"; OPTIND=$((OPTIND + 1))
            eval "_optval=\${${_idx}:-}"
            [ -z "${_optval:-}" ] && { __err "Option --${OPTARG} requires a value."; exit 1; }
            case "${_optval}" in -*) __err "Option --${OPTARG} requires a value (got flag '${_optval}' instead)."; exit 1 ;; esac
            NEXTCLOUD_NETWORK_NAME="${_optval}" ;;

          update)         NEXTCLOUD_UPDATE_ONLY="true" ;;
          yes|non-interactive) ;;  # kept for compatibility; script never prompts

          *) __err "Unknown option: --${OPTARG}"; exit 1 ;;
        esac ;;
      ?) __err "Unknown option: -${OPTARG}"; exit 1 ;;
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
# Uses __determine_hostname_name (hostname -f) as the primary source.
# Only accepts the result if it is a valid FQDN (two or more labels).
if [ -z "$NEXTCLOUD_DOMAIN" ]; then
  _detected_fqdn="$(__determine_hostname_name 2>/dev/null || true)"
  if [ -n "$_detected_fqdn" ] && __validate_fqdn "$_detected_fqdn"; then
    NEXTCLOUD_DOMAIN="$_detected_fqdn"
    __info "Auto-detected domain from hostname: $NEXTCLOUD_DOMAIN"
  else
    __warn "Could not auto-detect a valid FQDN from 'hostname -f' (got: '${_detected_fqdn:-none}')."
    __warn "Running in insecure/local mode. Pass --domain to set a real domain."
  fi
fi

# Validate --port: must be a positive integer in range 1-65535.
case "$NEXTCLOUD_PORT" in
  *[!0-9]*|'')
    __err "--port must be a number between 1 and 65535 (got: '$NEXTCLOUD_PORT')."; exit 1 ;;
esac
if [ "$NEXTCLOUD_PORT" -lt 1 ] || [ "$NEXTCLOUD_PORT" -gt 65535 ]; then
  __err "--port must be between 1 and 65535 (got: $NEXTCLOUD_PORT)."; exit 1
fi

# Validate --smtp-port: same 1-65535 range check as --port.
case "$NEXTCLOUD_SMTP_PORT" in
  *[!0-9]*|'')
    __err "--smtp-port must be a number between 1 and 65535 (got: '$NEXTCLOUD_SMTP_PORT')."; exit 1 ;;
esac
if [ "$NEXTCLOUD_SMTP_PORT" -lt 1 ] || [ "$NEXTCLOUD_SMTP_PORT" -gt 65535 ]; then
  __err "--smtp-port must be between 1 and 65535 (got: $NEXTCLOUD_SMTP_PORT)."; exit 1
fi

# Normalise domain: lowercase only. Reject trailing dot, spaces, and
# shell metacharacters — they cause issues in HTTP URLs and TLS SAN matching.
if [ -n "$NEXTCLOUD_DOMAIN" ]; then
  NEXTCLOUD_DOMAIN="$(printf '%s' "$NEXTCLOUD_DOMAIN" | tr '[:upper:]' '[:lower:]')"
  case "$NEXTCLOUD_DOMAIN" in
    *' '*|*'	'*)
      __err "Invalid domain: must not contain spaces."; exit 1 ;;
  esac
  case "$NEXTCLOUD_DOMAIN" in
    *['$''!''`''#''&''('')''|''<''>''{''}'' ']*)
      __err "Invalid domain '$NEXTCLOUD_DOMAIN': shell metacharacters are not allowed."; exit 1 ;;
  esac
  _dom_check="$(printf '%s' "$NEXTCLOUD_DOMAIN" | tr -d 'A-Za-z0-9.-')"
  if [ -n "$_dom_check" ]; then
    __err "Invalid domain '$NEXTCLOUD_DOMAIN': only letters, digits, hyphens, and dots are allowed."; exit 1
  fi
  case "$NEXTCLOUD_DOMAIN" in
    *..*)
      __err "Invalid domain '$NEXTCLOUD_DOMAIN': consecutive dots (empty label) are not allowed."; exit 1 ;;
  esac
  case "$NEXTCLOUD_DOMAIN" in
    .*|*.)
      __err "Invalid domain '$NEXTCLOUD_DOMAIN': must not start or end with a dot."; exit 1 ;;
    -*|*-|*-.*|*.-*)
      __err "Invalid domain '$NEXTCLOUD_DOMAIN': must not start or end with a hyphen."; exit 1 ;;
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
      debian|ubuntu|raspbian|linuxmint) echo "apt";    return ;;
      fedora)                           echo "dnf";    return ;;
      rhel|rocky|almalinux|centos)
        if command -v dnf >/dev/null 2>&1; then echo "dnf"; else echo "yum"; fi
        return ;;
      opensuse*|sles)                   echo "zypper"; return ;;
      arch|manjaro|endeavouros)         echo "pacman"; return ;;
    esac
  fi
  command -v apt-get >/dev/null 2>&1 && { echo apt;    return; }
  command -v dnf     >/dev/null 2>&1 && { echo dnf;    return; }
  command -v yum     >/dev/null 2>&1 && { echo yum;    return; }
  command -v zypper  >/dev/null 2>&1 && { echo zypper; return; }
  command -v pacman  >/dev/null 2>&1 && { echo pacman; return; }
  __err "Unsupported distribution (no known package manager)."; exit 1
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
        _distro_id="$(. /etc/os-release; echo "$ID")"
        curl -fsSL "https://download.docker.com/linux/${_distro_id}/gpg" | \
          gpg --dearmor > /tmp/nextcloud-docker.gpg
        __sudocmd "install -m 0644 -o root -g root -D /tmp/nextcloud-docker.gpg /etc/apt/keyrings/docker.gpg"
        rm -f /tmp/nextcloud-docker.gpg
      fi
      _arch="$(dpkg --print-architecture)"
      _distro_id="$(. /etc/os-release; echo "$ID")"
      _codename="$(. /etc/os-release; echo "$VERSION_CODENAME")"
      printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/%s %s stable\n' \
        "$_arch" "$_distro_id" "$_codename" | \
        __sudocmd "tee /etc/apt/sources.list.d/docker.list >/dev/null"
      __sudocmd "apt-get update"
      __sudocmd "apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin"
      ;;
    dnf)
      __need_cmd dnf
      __sudocmd "dnf -y install dnf-plugins-core"
      _distro_id="$(. /etc/os-release; echo "$ID")"
      # Docker publishes repos for 'centos' and 'fedora' only.
      # AlmaLinux, Rocky, and other RHEL rebuilds must use the centos repo.
      case "$_distro_id" in
        fedora) _docker_repo_id="fedora" ;;
        *)      _docker_repo_id="centos" ;;
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
      _distro_id="$(. /etc/os-release; echo "$ID")"
      __sudocmd "zypper -n addrepo https://download.docker.com/linux/${_distro_id}/docker-ce.repo || true"
      __sudocmd "zypper -n refresh"
      __sudocmd "zypper -n install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin"
      ;;
    pacman)
      __need_cmd pacman
      __sudocmd "pacman -Sy --noconfirm docker docker-compose-plugin"
      ;;
    *)
      __err "Unsupported package manager: $_pm"; exit 1 ;;
  esac

  if __has_systemd; then
    __sudocmd "systemctl enable --now docker"
  else
    __warn "systemd not detected. Please start and enable the Docker daemon manually."
  fi
}

__ensure_network() {
  if docker network inspect -- "$NEXTCLOUD_NETWORK_NAME" >/dev/null 2>&1; then
    __info "Docker network '$NEXTCLOUD_NETWORK_NAME' already exists."
    return 0
  fi
  __info "Creating Docker network '$NEXTCLOUD_NETWORK_NAME'..."
  docker network create --driver bridge -- "$NEXTCLOUD_NETWORK_NAME" >/dev/null 2>&1 || true
  if ! docker network inspect -- "$NEXTCLOUD_NETWORK_NAME" >/dev/null 2>&1; then
    __err "Failed to create or find Docker network '$NEXTCLOUD_NETWORK_NAME'."
    exit 1
  fi
}

__ensure_docker() {
  if command -v docker >/dev/null 2>&1; then
    __info "Docker is present."
  else
    __info "Docker not found; installing from official repository..."
    __info "If automatic install fails, install docker-ce and docker-compose-plugin manually:"
    __info "  https://docs.docker.com/engine/install/"
    __install_docker_official
  fi
  if docker compose version >/dev/null 2>&1; then
    __info "Docker Compose v2 plugin present."
  else
    __err "Docker Compose v2 plugin missing. Install docker-compose-plugin and re-run."; exit 1
  fi
}

# - - - - - - - - - - - - - - - - - - - - - - - - -
# Credential management (load or generate; idempotent)
# - - - - - - - - - - - - - - - - - - - - - - - - -
__load_or_generate_credentials() {
  # Admin password: honour --admin-pass if provided; otherwise load or generate.
  if [ -n "$NEXTCLOUD_ADMIN_PASS" ]; then
    _admin_pass="$NEXTCLOUD_ADMIN_PASS"
    __save_credential "$NEXTCLOUD_CRED_FILE" NEXTCLOUD_ADMIN_PASSWORD "$_admin_pass"
  else
    _admin_pass="$(__load_credential "$NEXTCLOUD_CRED_FILE" NEXTCLOUD_ADMIN_PASSWORD 2>/dev/null)" || {
      _admin_pass="$(__random_password 24)"
      __save_credential "$NEXTCLOUD_CRED_FILE" NEXTCLOUD_ADMIN_PASSWORD "$_admin_pass"
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
}

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

    cat > "$NEXTCLOUD_ENV_FILE" <<EOF
# Autogenerated by install.sh on $(date -u)
# Safe to edit and re-run install.sh. Keep this file secure (mode 600).

COMPOSE_PROJECT_NAME=nextcloud

# --- Nextcloud image ---
NEXTCLOUD_DOCKER_IMAGE=nextcloud
NEXTCLOUD_DOCKER_TAG=apache

# --- Network ---
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

# --- Logging ---
NEXTCLOUD_LOG_DRIVER=local

# --- Docker network ---
# All Nextcloud containers join this network. Attach your reverse proxy to it.
NEXTCLOUD_NETWORK=$NEXTCLOUD_NETWORK_NAME
EOF
    chmod 600 "$NEXTCLOUD_ENV_FILE"
    __info ".env written."

    if [ ! -s "$NEXTCLOUD_ADMIN_OUT" ]; then
      printf "Admin user    : %s\nAdmin pass    : %s\nAdmin URL     : %s://%s/settings/admin\nDB user       : %s\nDB pass       : %s\nDB name       : %s\n" \
        "$NEXTCLOUD_ADMIN_USER" "$_admin_pass" \
        "$_nc_scheme" "${NEXTCLOUD_DOMAIN:-localhost}" \
        "$NEXTCLOUD_DB_USER" "$_db_pass" "$NEXTCLOUD_DB_NAME" > "$NEXTCLOUD_ADMIN_OUT"
      chmod 600 "$NEXTCLOUD_ADMIN_OUT"
      __info "Admin credentials saved to $NEXTCLOUD_ADMIN_OUT"
    fi
  else
    __info ".env exists; leaving as-is (idempotent)."
    if [ -n "$NEXTCLOUD_ADMIN_PASS" ]; then
      __warn "NEXTCLOUD_ADMIN_PASSWORD is ignored after first initialization."
      __warn "Reset the admin password with: docker exec --user www-data nextcloud-app php occ user:resetpassword $NEXTCLOUD_ADMIN_USER"
    fi
  fi
}

# - - - - - - - - - - - - - - - - - - - - - - - - -
# Compose file (regenerated on every run)
# - - - - - - - - - - - - - - - - - - - - - - - - -
__write_compose_file() {
  # NOTE: This file is auto-generated by install.sh on every run.
  # Do not edit it directly — changes will be overwritten.
  # Customise .env (preserved across runs) or re-run install.sh instead.
  cat > "$NEXTCLOUD_COMPOSE_FILE" <<'EOF'
# Auto-generated by install.sh — do not edit; re-run install.sh to regenerate.
---
services:

  nextcloud:
    image: ${NEXTCLOUD_DOCKER_IMAGE:-nextcloud}:${NEXTCLOUD_DOCKER_TAG:-apache}
    container_name: nextcloud-app
    networks:
      - nextcloud-net
    restart: unless-stopped
    depends_on:
      db:
        condition: service_healthy
      redis:
        condition: service_started
    ports:
      - "127.0.0.1:${NEXTCLOUD_HTTP_PORT:-8080}:80"
    environment:
      NEXTCLOUD_ADMIN_USER: "${NEXTCLOUD_ADMIN_USER:-administrator}"
      NEXTCLOUD_ADMIN_PASSWORD: "${NEXTCLOUD_ADMIN_PASSWORD}"
      NEXTCLOUD_TRUSTED_DOMAINS: "${NEXTCLOUD_DOMAIN:-localhost}"
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
    volumes:
      - ${NEXTCLOUD_DATA_DIR:-nextcloud-data}:/var/www/html
    logging:
      driver: "${NEXTCLOUD_LOG_DRIVER:-local}"
      options:
        max-size: "50m"
        max-file: "5"

  db:
    image: mariadb:lts
    container_name: nextcloud-db
    networks:
      - nextcloud-net
    restart: unless-stopped
    environment:
      MYSQL_ROOT_PASSWORD: "${NEXTCLOUD_DB_ROOT_PASSWORD}"
      MYSQL_DATABASE: "${NEXTCLOUD_DB_NAME:-nextcloud}"
      MYSQL_USER: "${NEXTCLOUD_DB_USER:-nextcloud}"
      MYSQL_PASSWORD: "${NEXTCLOUD_DB_PASSWORD}"
    volumes:
      - ${NEXTCLOUD_DB_DIR:-nextcloud-db}:/var/lib/mysql
    healthcheck:
      test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
      interval: 10s
      timeout: 5s
      retries: 10
      start_period: 30s
    logging:
      driver: "${NEXTCLOUD_LOG_DRIVER:-local}"
      options:
        max-size: "50m"
        max-file: "5"

  redis:
    image: redis:alpine
    container_name: nextcloud-redis
    networks:
      - nextcloud-net
    restart: unless-stopped
    logging:
      driver: "${NEXTCLOUD_LOG_DRIVER:-local}"
      options:
        max-size: "10m"
        max-file: "3"

  cron:
    image: ${NEXTCLOUD_DOCKER_IMAGE:-nextcloud}:${NEXTCLOUD_DOCKER_TAG:-apache}
    container_name: nextcloud-cron
    networks:
      - nextcloud-net
    restart: unless-stopped
    depends_on:
      - nextcloud
    entrypoint: /cron.sh
    volumes:
      - ${NEXTCLOUD_DATA_DIR:-nextcloud-data}:/var/www/html
    logging:
      driver: "${NEXTCLOUD_LOG_DRIVER:-local}"
      options:
        max-size: "10m"
        max-file: "3"

networks:
  # External named network — created by install.sh before compose starts.
  # Attach your reverse proxy to this network to reach Nextcloud without
  # exposing extra ports on the host.
  nextcloud-net:
    name: ${NEXTCLOUD_NETWORK:-nextcloud-net}
    external: true

volumes:
  nextcloud-data:
  nextcloud-db:
EOF
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
      cp -- "$NEXTCLOUD_COMPOSE_DIR/$_f" "$_bdir/$_f" 2>/dev/null || \
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
  tar -C "$NEXTCLOUD_COMPOSE_DIR" -czf "$_bdir/data.tgz" "$(basename "$NEXTCLOUD_DATA_DIR")" 2>/dev/null || \
    __warn "Data backup failed; continuing (non-fatal)."

  # DB snapshot via mysqldump inside the container.
  __info "Dumping database..."
  _db_pass_bk="$(__load_credential "$NEXTCLOUD_CRED_FILE" NEXTCLOUD_DB_PASSWORD 2>/dev/null)" || _db_pass_bk=""
  if [ -n "$_db_pass_bk" ]; then
    docker exec nextcloud-db \
      sh -c "mysqldump -u\"${NEXTCLOUD_DB_USER}\" -p\"${_db_pass_bk}\" \"${NEXTCLOUD_DB_NAME}\"" \
      > "$_bdir/nextcloud-db.sql" 2>/dev/null || \
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
  __info "Waiting for Nextcloud to initialize (can take a few minutes on first run)..."
  _tries=0
  while [ "$_tries" -lt 72 ]; do
    _status="$(curl -q -LSs --max-time 5 "http://127.0.0.1:${NEXTCLOUD_PORT}/status.php" 2>/dev/null || true)"
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
  __info "Configuring Nextcloud via occ..."

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
      --value="${_occ_scheme}://${NEXTCLOUD_DOMAIN}/" || true
  fi

  # Tell Nextcloud the upstream protocol so it generates https:// links
  # even though Apache inside the container receives plain HTTP from the proxy.
  if [ "$_occ_scheme" = "https" ]; then
    ${_occ_base} config:system:set overwriteprotocol --value="https" || true
  fi

  # Trust all IPs as proxies so X-Forwarded-For and X-Forwarded-Proto
  # headers are honoured from any upstream reverse proxy.
  ${_occ_base} config:system:set trusted_proxies 0 --value="0.0.0.0/0" || true

  # Use APCu for local in-process caching (already available in the apache image).
  ${_occ_base} config:system:set memcache.local --value='\OC\Memcache\APCu' || true

  # Use Redis for distributed/locking cache.
  ${_occ_base} config:system:set memcache.distributed --value='\OC\Memcache\Redis' || true
  ${_occ_base} config:system:set memcache.locking --value='\OC\Memcache\Redis' || true
  ${_occ_base} config:system:set redis host --value="redis" || true
  ${_occ_base} config:system:set redis port --value="6379" --type=integer || true

  # Default phone region (used for phone number formatting in contacts).
  ${_occ_base} config:system:set default_phone_region --value="US" || true

  # Disable skeleton directory — new users start with an empty home folder.
  ${_occ_base} config:system:set skeletondirectory --value="" || true

  # Set maximum chunk size for uploads to avoid proxy timeouts.
  ${_occ_base} config:system:set max_chunk_size --value="0" --type=integer || true

  __info "Nextcloud occ configuration complete."
}

# - - - - - - - - - - - - - - - - - - - - - - - - -
# Main flow
# - - - - - - - - - - - - - - - - - - - - - - - - -
__main() {
  # Guard: --update on a path with no existing installation is almost always
  # a typo (wrong --path). Warn loudly so the user can abort.
  if [ "$NEXTCLOUD_UPDATE_ONLY" = "true" ] && [ ! -f "$NEXTCLOUD_ENV_FILE" ]; then
    __warn "--update specified but no existing installation found at $NEXTCLOUD_COMPOSE_DIR"
    __warn "(no .env found). Creating a fresh installation. Use Ctrl-C to abort."
    sleep 3
  fi

  __ensure_docker
  __ensure_network
  __load_or_generate_credentials
  __write_env_file
  __write_compose_file

  cd "$NEXTCLOUD_COMPOSE_DIR"

  if [ "$NEXTCLOUD_UPDATE_ONLY" = "true" ]; then
    __info "Running update flow..."
    __snapshot_backup
    __info "Putting Nextcloud in maintenance mode..."
    docker exec --user www-data nextcloud-app php occ maintenance:mode --on 2>/dev/null || true
    __info "Pulling latest images..."
    docker compose pull
    __info "Recreating services..."
    docker compose up -d --remove-orphans
    __info "Taking Nextcloud out of maintenance mode..."
    sleep 10
    docker exec --user www-data nextcloud-app php occ maintenance:mode --off 2>/dev/null || true
    docker exec --user www-data nextcloud-app php occ upgrade 2>/dev/null || true
    docker exec --user www-data nextcloud-app php occ app:update --all 2>/dev/null || true
  else
    __info "Bringing up Nextcloud stack..."
    docker compose up -d
  fi

  _nc_up=true
  __wait_for_nextcloud || _nc_up=false

  if [ "$_nc_up" = "true" ] && [ "$NEXTCLOUD_UPDATE_ONLY" = "false" ]; then
    __configure_nextcloud
  fi

  # Read domain/port from existing .env when not supplied on the command line,
  # so the summary reflects the actual configured values.
  if [ -f "$NEXTCLOUD_ENV_FILE" ]; then
    if [ -z "$NEXTCLOUD_DOMAIN" ]; then
      _env_domain="$(sed -n 's/^NEXTCLOUD_DOMAIN="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "$NEXTCLOUD_ENV_FILE")"
      if [ -n "$_env_domain" ] && [ "$_env_domain" != "localhost" ]; then
        NEXTCLOUD_DOMAIN="$_env_domain"
      fi
    fi
    _env_port="$(sed -n 's/^NEXTCLOUD_HTTP_PORT="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "$NEXTCLOUD_ENV_FILE")"
    if [ -n "$_env_port" ]; then
      NEXTCLOUD_PORT="$_env_port"
    fi
  fi

  # Derive display scheme from domain (mirrors __write_env_file logic).
  if [ -z "$NEXTCLOUD_DOMAIN" ] || [ "${NEXTCLOUD_DOMAIN%%.*}" = "$NEXTCLOUD_DOMAIN" ]; then
    _sum_scheme="http"
  else
    _sum_scheme="https"
  fi

  __info ""
  if [ "$_nc_up" = "true" ]; then
    __info "Nextcloud is up. Summary:"
  else
    __warn "Nextcloud did not come up within the timeout. Summary (check logs above):"
  fi
  __info "  Compose dir   : $NEXTCLOUD_COMPOSE_DIR"
  __info "  Port (HTTP)   : 127.0.0.1:$NEXTCLOUD_PORT  (attach your reverse proxy)"
  __info "  Docker network: $NEXTCLOUD_NETWORK_NAME  (attach your reverse proxy here)"
  if [ -n "$NEXTCLOUD_DOMAIN" ]; then
    __info "  Public URL    : ${_sum_scheme}://$NEXTCLOUD_DOMAIN/"
    __info "  Admin panel   : ${_sum_scheme}://$NEXTCLOUD_DOMAIN/settings/admin"
  fi
  if [ -f "$NEXTCLOUD_ADMIN_OUT" ]; then
    __info "  Admin creds   : $NEXTCLOUD_ADMIN_OUT  (delete after noting; mode 600)"
  fi
  __info "  Credentials   : $NEXTCLOUD_CRED_FILE  (mode 600)"
  __info "  Data dir      : $NEXTCLOUD_DATA_DIR"
  __info "  DB dir        : $NEXTCLOUD_DB_DIR"
  __info "  Backups       : $NEXTCLOUD_BACKUP_DIR"
  __info ""
  __info "To manage:"
  __info "  cd $NEXTCLOUD_COMPOSE_DIR && docker compose ps"
  __info "  cd $NEXTCLOUD_COMPOSE_DIR && docker compose logs -f nextcloud"
  __info "  sh install.sh --update --path $NEXTCLOUD_COMPOSE_DIR"
}

# - - - - - - - - - - - - - - - - - - - - - - - - -
__main
# ex: ts=2 sw=2 et filetype=sh
