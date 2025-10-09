#!/usr/bin/env bash
set -Eeuo pipefail

# -------------------------------------------------------------------
# WordPress wp-content migration (PUSH mode) + DB dump transfer
# -------------------------------------------------------------------
# Run this on the SOURCE server from the WP root (where wp-config.php is).
# Requires: wp-cli, rsync, ssh, gzip (for DB dump compression)
#
# What it does
#   1) Verifies WP on source and destination
#   2) Enables maintenance mode on both
#   3) Exports DB on source (timestamped), transfers to destination (/db-imports)
#      - Imports the DB on destination by default (--no-import-db to skip)
#   4) Backs up the destination wp-content (timestamped) then replaces it via rsync
#      - Transfers the entire wp-content directory (no excludes)
#   5) Disables maintenance mode on both
#
# Safe by default:
#   - No chmod/chown
#   - Destination wp-content is preserved with a timestamped backup
#   - No --delete
#   - Dry-run supported for rsync; DB step is previewed in dry-run
# -------------------------------------------------------------------

# -------------------
# Defaults / Settings
# -------------------
DEST_HOST=""                 # REQUIRED (push mode): user@dest.example.com
DEST_ROOT=""                 # REQUIRED (push mode): absolute WP root on destination (e.g., /var/www/site)
DUPLICATOR_ARCHIVE=""        # REQUIRED (Duplicator mode): path to Duplicator .zip backup
MIGRATION_MODE=""            # Detected: "push" or "duplicator"

# Use a single-element -o form to avoid dangling -o errors if mis-expanded
SSH_OPTS=(-oStrictHostKeyChecking=accept-new)
SSH_CONTROL_ACTIVE=false
SSH_CONTROL_DIR=""
SSH_CONTROL_PATH=""

DRY_RUN=false
IMPORT_DB=true              # Automatically import DB on destination after transfer (disable with --no-import-db)
GZIP_DB=true                # Compress DB dump during transfer
MAINTENANCE_ALWAYS=true     # Always enable maintenance mode during migration
MAINTENANCE_SOURCE=true     # Allow skipping maintenance mode on the source (--no-maint-source)

# Duplicator mode variables
DUPLICATOR_EXTRACT_DIR=""    # Temporary extraction directory
DUPLICATOR_DB_FILE=""        # Detected database file path
DUPLICATOR_WP_CONTENT=""     # Detected wp-content directory path
ORIGINAL_DEST_HOME_URL=""    # Captured before import
ORIGINAL_DEST_SITE_URL=""    # Captured before import

LOG_DIR="./logs"
LOG_FILE="/dev/null"
EXTRA_RSYNC_OPTS=()         # Add via --rsync-opt

MAINT_LOCAL_ACTIVE=false
MAINT_REMOTE_ACTIVE=false
MAINT_REMOTE_HOST=""
MAINT_REMOTE_ROOT=""
REDIS_FLUSH_AVAILABLE=false
SOURCE_HOME_URL=""
SOURCE_SITE_URL=""
DEST_HOME_URL=""
DEST_SITE_URL=""
SOURCE_DISPLAY_URL=""
DEST_DISPLAY_URL=""
SOURCE_HOSTNAME=""
DEST_HOSTNAME=""
DEST_HOME_OVERRIDE=""
DEST_SITE_OVERRIDE=""
DEST_DOMAIN_OVERRIDE=""
DEST_DOMAIN_CANON=""
SEARCH_REPLACE_ARGS=()
SEARCH_REPLACE_FLAGS=(--skip-columns=guid --report-changed-only)
URL_ALIGNMENT_REQUIRED=false

# -------------
# CLI & Helpers
# -------------
err() { printf "ERROR: %s\n" "$*" >&2; exit 1; }
needs() { command -v "$1" >/dev/null 2>&1 || err "Missing dependency: $1"; }

validate_url() {
  local url="$1" flag_name="$2"
  # Basic URL validation: must start with http:// or https://
  if [[ ! "$url" =~ ^https?:// ]]; then
    err "$flag_name must be a valid URL starting with http:// or https:// (got: $url)"
  fi
  # Ensure URL has a domain part after protocol
  if [[ ! "$url" =~ ^https?://[^/]+ ]]; then
    err "$flag_name must include a domain name (got: $url)"
  fi
}

log() {
  printf "%s %s\n" "$(date '+%F %T')" "$*" | tee -a "$LOG_FILE"
}

wp_local() { wp --path="$PWD" "$@"; }

# Build a safe "ssh ..." string for rsync -e
ssh_cmd_string() {
  printf 'ssh'
  for opt in "${SSH_OPTS[@]}"; do
    printf ' %q' "$opt"
  done
}

# Run an arbitrary command over SSH (use array expansion)
ssh_run() {
  local host="$1"; shift
  # shellcheck disable=SC2029  # Intentional client-side expansion with proper quoting
  ssh "${SSH_OPTS[@]}" "$host" "$@"
}

# Robust remote WP-CLI runner that preserves arguments exactly
wp_remote() {
  local host="$1" root="$2"; shift 2
  local root_quoted cmd_quoted
  printf -v root_quoted "%q" "$root"
  local cmd=(wp --skip-plugins --skip-themes "$@")
  printf -v cmd_quoted "%q " "${cmd[@]}"
  # shellcheck disable=SC2029  # Intentional client-side expansion; variables are quoted via printf %q
  ssh "${SSH_OPTS[@]}" "$host" "bash -lc 'cd $root_quoted && ${cmd_quoted% }'"
}

# Run remote WP-CLI without skipping plugins/themes (needed for plugin-provided commands)
wp_remote_full() {
  local host="$1" root="$2"; shift 2
  local root_quoted cmd_quoted
  printf -v root_quoted "%q" "$root"
  local cmd=(wp "$@")
  printf -v cmd_quoted "%q " "${cmd[@]}"
  # shellcheck disable=SC2029  # Intentional client-side expansion; variables are quoted via printf %q
  ssh "${SSH_OPTS[@]}" "$host" "bash -lc 'cd $root_quoted && ${cmd_quoted% }'"
}

wp_remote_has_command() {
  local host="$1" root="$2" command="$3"
  if wp_remote_full "$host" "$root" cli has-command "$command" >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

add_search_replace_pair() {
  local source_value="$1" dest_value="$2"

  [[ -z "$source_value" || -z "$dest_value" ]] && return 0
  [[ "$source_value" == "$dest_value" ]] && return 0

  local idx
  for ((idx=0; idx<${#SEARCH_REPLACE_ARGS[@]}; idx+=2)); do
    if [[ "${SEARCH_REPLACE_ARGS[idx]}" == "$source_value" && "${SEARCH_REPLACE_ARGS[idx+1]}" == "$dest_value" ]]; then
      return 0
    fi
  done

  SEARCH_REPLACE_ARGS+=("$source_value" "$dest_value")
}

json_escape_slashes() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\//\\/}"
  printf '%s' "$value"
}

url_host_only() {
  local value="$1"
  [[ -z "$value" ]] && return 0
  value="$(printf '%s\n' "$value" | sed -E 's#^[a-zA-Z][a-zA-Z0-9+.-]*://##; s#^//##; s#/.*$##')"
  printf '%s' "$value"
}

add_url_alignment_variations() {
  local source_value="$1" dest_value="$2"
  [[ -z "$source_value" || -z "$dest_value" ]] && return 0

  add_search_replace_pair "$source_value" "$dest_value"

  local source_trimmed="$source_value" dest_trimmed="$dest_value"
  [[ "$source_trimmed" == */ ]] && source_trimmed="${source_trimmed%/}"
  [[ "$dest_trimmed" == */ ]] && dest_trimmed="${dest_trimmed%/}"

  add_search_replace_pair "$source_trimmed" "$dest_trimmed"
  add_search_replace_pair "${source_trimmed}/" "${dest_trimmed}/"

  local source_json dest_json
  source_json="$(json_escape_slashes "$source_value")"
  dest_json="$(json_escape_slashes "$dest_value")"
  add_search_replace_pair "$source_json" "$dest_json"

  local source_trim_json dest_trim_json
  source_trim_json="$(json_escape_slashes "$source_trimmed")"
  dest_trim_json="$(json_escape_slashes "$dest_trimmed")"
  add_search_replace_pair "$source_trim_json" "$dest_trim_json"
  add_search_replace_pair "${source_trim_json}\/" "${dest_trim_json}\/"
}

cleanup_ssh_control() {
  $SSH_CONTROL_ACTIVE || return 0
  [[ -n "$SSH_CONTROL_PATH" ]] || return 0
  ssh -S "$SSH_CONTROL_PATH" -O exit "$DEST_HOST" >/dev/null 2>&1 || true
  rm -f "$SSH_CONTROL_PATH" >/dev/null 2>&1 || true
  if [[ -n "$SSH_CONTROL_DIR" ]]; then
    rmdir "$SSH_CONTROL_DIR" >/dev/null 2>&1 || true
  fi
  SSH_CONTROL_ACTIVE=false
}

setup_ssh_control() {
  $SSH_CONTROL_ACTIVE && return 0
  SSH_CONTROL_DIR="$(mktemp -d "${TMPDIR:-/tmp}/wp-migrate-ssh-XXXXXX")"
  SSH_CONTROL_PATH="$SSH_CONTROL_DIR/socket"
  SSH_OPTS+=("-oControlMaster=auto" "-oControlPersist=600" "-oControlPath=$SSH_CONTROL_PATH")
  SSH_CONTROL_ACTIVE=true
  log "Reusing SSH connection with ControlMaster (password prompt should appear once)."
}

exit_cleanup() {
  local status=$?
  trap - EXIT
  set +e
  maintenance_cleanup
  cleanup_ssh_control
  if [[ "$MIGRATION_MODE" == "duplicator" ]]; then
    # Only cleanup on success; keep files on failure for debugging
    if [[ $status -eq 0 ]]; then
      cleanup_duplicator_temp
    elif [[ -n "$DUPLICATOR_EXTRACT_DIR" && -d "$DUPLICATOR_EXTRACT_DIR" ]]; then
      log "Keeping extraction directory for debugging: $DUPLICATOR_EXTRACT_DIR"
    fi
  fi
  set -e
  exit "$status"
}

trap 'exit_cleanup' EXIT

discover_wp_content_local() { wp_local eval 'echo WP_CONTENT_DIR;'; }

discover_wp_content_remote() {
  local host="$1" root="$2"
  # Use wp_remote so quoted args survive
  wp_remote "$host" "$root" eval 'echo WP_CONTENT_DIR;'
}

check_disk_space_for_duplicator() {
  local archive_path="$1"
  local archive_size_bytes
  local available_bytes
  local required_bytes

  archive_size_bytes=$(stat -f%z "$archive_path" 2>/dev/null || stat -c%s "$archive_path" 2>/dev/null)
  [[ -n "$archive_size_bytes" ]] || err "Unable to determine archive size: $archive_path"

  # Need 3x archive size: 1x for archive, 1x for extraction, 1x buffer
  required_bytes=$((archive_size_bytes * 3))

  # Check available space in current directory
  available_bytes=$(df -P . | awk 'NR==2 {print $4 * 1024}')

  local archive_size_mb=$((archive_size_bytes / 1024 / 1024))
  local required_mb=$((required_bytes / 1024 / 1024))
  local available_mb=$((available_bytes / 1024 / 1024))

  log "Disk space check:"
  log "  Archive size: ${archive_size_mb}MB"
  log "  Required: ${required_mb}MB (3x archive size)"
  log "  Available: ${available_mb}MB"

  if [[ $available_bytes -lt $required_bytes ]]; then
    err "Insufficient disk space. Need ${required_mb}MB but only ${available_mb}MB available.
Archive: ${archive_size_mb}MB
Required: ${required_mb}MB (3x for archive + extraction + buffer)
Available: ${available_mb}MB

Free up space or move the archive to a location with more available space."
  fi

  log "Disk space check: PASSED"
}

extract_duplicator_archive() {
  local archive_path="$1"

  if $DRY_RUN; then
    log "[dry-run] Would extract archive to temporary directory"
    DUPLICATOR_EXTRACT_DIR="/tmp/wp-migrate-duplicator-XXXXXX-dryrun"
    return 0
  fi

  DUPLICATOR_EXTRACT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/wp-migrate-duplicator-XXXXXX")"
  log "Extracting archive to: $DUPLICATOR_EXTRACT_DIR"

  if ! unzip -q "$archive_path" -d "$DUPLICATOR_EXTRACT_DIR"; then
    rm -rf "$DUPLICATOR_EXTRACT_DIR"
    err "Failed to extract Duplicator archive: $archive_path"
  fi

  log "Archive extracted successfully"
}

find_duplicator_database() {
  local extract_dir="$1"

  if $DRY_RUN; then
    log "[dry-run] Would search for database file: dup-installer/dup-database__*.sql"
    DUPLICATOR_DB_FILE="$extract_dir/dup-installer/dup-database__example.sql"
    return 0
  fi

  # Look for database file in dup-installer directory
  local db_file
  db_file=$(find "$extract_dir" -type f -path "*/dup-installer/dup-database__*.sql" | head -1)

  if [[ -z "$db_file" ]]; then
    err "Unable to locate database file in Duplicator archive.
Expected path: dup-installer/dup-database__*.sql
Archive extracted to: $extract_dir

Please verify this is a valid Duplicator backup archive."
  fi

  DUPLICATOR_DB_FILE="$db_file"
  log "Found database file: $(basename "$DUPLICATOR_DB_FILE")"
}

find_duplicator_wp_content() {
  local extract_dir="$1"

  if $DRY_RUN; then
    log "[dry-run] Would auto-detect wp-content directory"
    DUPLICATOR_WP_CONTENT="$extract_dir/wordpress/core/6.8.3/wp-content"
    return 0
  fi

  # Find all wp-content directories
  local candidates=()
  while IFS= read -r -d '' dir; do
    candidates+=("$dir")
  done < <(find "$extract_dir" -type d -name "wp-content" -print0)

  if [[ ${#candidates[@]} -eq 0 ]]; then
    err "Unable to locate wp-content directory in Duplicator archive.
Archive extracted to: $extract_dir

Please verify this is a valid Duplicator backup archive."
  fi

  # Score each candidate by presence of standard subdirectories
  local best_dir="" best_score=0
  for dir in "${candidates[@]}"; do
    local score=0
    [[ -d "$dir/plugins" ]] && score=$((score + 1))
    [[ -d "$dir/themes" ]] && score=$((score + 1))
    [[ -d "$dir/uploads" ]] && score=$((score + 1))

    if [[ $score -gt $best_score ]]; then
      best_score=$score
      best_dir="$dir"
    fi
  done

  if [[ -z "$best_dir" ]]; then
    log "WARNING: Found wp-content directories but none with standard subdirectories."
    log "Using first candidate: ${candidates[0]}"
    best_dir="${candidates[0]}"
  fi

  DUPLICATOR_WP_CONTENT="$best_dir"
  log "Found wp-content directory: ${DUPLICATOR_WP_CONTENT#"$extract_dir"/}"
  log "  Contains: plugins=$([ -d "$DUPLICATOR_WP_CONTENT/plugins" ] && echo "YES" || echo "NO") themes=$([ -d "$DUPLICATOR_WP_CONTENT/themes" ] && echo "YES" || echo "NO") uploads=$([ -d "$DUPLICATOR_WP_CONTENT/uploads" ] && echo "YES" || echo "NO")"
}

cleanup_duplicator_temp() {
  [[ -z "$DUPLICATOR_EXTRACT_DIR" ]] && return 0
  [[ ! -d "$DUPLICATOR_EXTRACT_DIR" ]] && return 0

  if $DRY_RUN; then
    log "[dry-run] Would remove temporary extraction directory"
    return 0
  fi

  log "Cleaning up temporary extraction directory..."
  rm -rf "$DUPLICATOR_EXTRACT_DIR"
}

backup_remote_wp_content() {
  local host="$1" path="$2" stamp="$3"
  local backup_path="${path%/}.backup-$stamp"

  if $DRY_RUN; then
    log "[dry-run] Would move $path to $backup_path on destination."
    printf "%s" "$backup_path"
  else
    if ssh_run "$host" "[ -e \"$path\" ]"; then
      log "Backing up destination wp-content to: $backup_path"
      ssh_run "$host" "mv \"$path\" \"$backup_path\""
      printf "%s" "$backup_path"
    else
      log "Destination wp-content not found; skipping backup step."
    fi
  fi
}

maint_local()  {
  local onoff="$1" status=0
  $MAINTENANCE_ALWAYS || return 0
  $MAINTENANCE_SOURCE || return 0
  if [[ "$onoff" == "on" ]]; then
    wp_local maintenance-mode activate >/dev/null
    status=$?
    if (( status == 0 )); then
      MAINT_LOCAL_ACTIVE=true
    fi
  else
    wp_local maintenance-mode deactivate >/dev/null
    status=$?
    if (( status == 0 )); then
      MAINT_LOCAL_ACTIVE=false
    fi
  fi
  return $status
}

maint_remote() {
  local host="$1" root="$2" onoff="$3" status
  $MAINTENANCE_ALWAYS || return 0
  if [[ "$onoff" == "on" ]]; then
    wp_remote "$host" "$root" maintenance-mode activate >/dev/null
    status=$?
    if (( status == 0 )); then
      MAINT_REMOTE_ACTIVE=true
      MAINT_REMOTE_HOST="$host"
      MAINT_REMOTE_ROOT="$root"
    fi
  else
    wp_remote "$host" "$root" maintenance-mode deactivate >/dev/null
    status=$?
    if (( status == 0 )); then
      MAINT_REMOTE_ACTIVE=false
      MAINT_REMOTE_HOST=""
      MAINT_REMOTE_ROOT=""
    fi
  fi
  return "${status:-0}"
}

maintenance_cleanup() {
  $MAINTENANCE_ALWAYS || return 0

  local had_failure=false

  if $MAINT_REMOTE_ACTIVE && [[ -n "$MAINT_REMOTE_HOST" && -n "$MAINT_REMOTE_ROOT" ]]; then
    if ! maint_remote "$MAINT_REMOTE_HOST" "$MAINT_REMOTE_ROOT" off; then
      had_failure=true
      log "WARNING: Failed to disable maintenance mode on destination during cleanup."
    fi
  fi

  if $MAINT_LOCAL_ACTIVE; then
    if ! maint_local off; then
      had_failure=true
      log "WARNING: Failed to disable maintenance mode on source during cleanup."
    fi
  fi

  $had_failure && return 1 || return 0
}

print_version() {
  local version="unknown"
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

  # Try to get version from git tag
  if command -v git >/dev/null 2>&1 && [[ -d "$script_dir/.git" ]]; then
    version=$(git -C "$script_dir" describe --tags --always 2>/dev/null || echo "unknown")
  fi

  # If no git tag, try to extract from CHANGELOG.md
  if [[ "$version" == "unknown" && -f "$script_dir/CHANGELOG.md" ]]; then
    # Look for the first version heading like ## [X.Y.Z]
    version=$(grep -m 1 "^## \[" "$script_dir/CHANGELOG.md" | sed -E 's/^## \[([^]]+)\].*/\1/' || echo "unknown")
    [[ "$version" == "Unreleased" ]] && version="dev (unreleased)"
  fi

  printf "wp-migrate.sh version %s\n" "$version"
}

print_usage() {
  cat <<USAGE
Usage:

PUSH MODE (run on SOURCE WP root):
  $(basename "$0") --dest-host <user@host> --dest-root </abs/path> [options]

DUPLICATOR MODE (run on DESTINATION WP root):
  $(basename "$0") --duplicator-archive </path/to/backup.zip> [options]

Required (choose one mode):
  --dest-host <user@dest.example.com>
  --dest-root </absolute/path/to/destination/wp-root>
      Push mode: migrate from current host to destination via SSH

  --duplicator-archive </path/to/backup.zip>
      Duplicator mode: import Duplicator backup archive to current host
      (mutually exclusive with --dest-host)

Options:
  --dry-run                 Preview rsync; DB export/transfer is also previewed (no dump created)
  --import-db               (Deprecated) Explicitly import the DB on destination (default behavior)
  --no-import-db            Skip importing the DB on destination after transfer
  --no-gzip                 Don't gzip the DB dump (default is gzip on, push mode only)
  --no-maint-source         Skip enabling maintenance mode on the source site (push mode only)
  --dest-domain '<host>'    Override destination domain (push mode only)
  --dest-home-url '<url>'   Force the destination home URL used for replacements (push mode only)
  --dest-site-url '<url>'   Force the destination site URL used for replacements (push mode only)
  --rsync-opt '<opt>'       Add an rsync option (can be repeated, push mode only)
  --ssh-opt '<opt>'         Add an SSH -o option (e.g., ProxyJump=bastion). Can be repeated. (push mode only)
  --version                 Show version information
  --help                    Show this help

Examples (push mode):
  $(basename "$0") --dest-host wp@dest --dest-root /var/www/site
  $(basename "$0") --dest-host wp@dest --dest-root /var/www/site --no-import-db

Examples (Duplicator mode):
  $(basename "$0") --duplicator-archive /path/to/backup_20251009.zip
  $(basename "$0") --duplicator-archive /backups/site.zip --dry-run
USAGE
}

# -------------
# Parse args
# -------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dest-host) DEST_HOST="${2:-}"; shift 2 ;;
    --dest-root) DEST_ROOT="${2:-}"; shift 2 ;;
    --duplicator-archive) DUPLICATOR_ARCHIVE="${2:-}"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    --import-db) IMPORT_DB=true; shift ;;
    --no-import-db) IMPORT_DB=false; shift ;;
    --no-gzip) GZIP_DB=false; shift ;;
    --no-maint-source) MAINTENANCE_SOURCE=false; shift ;;
    --rsync-opt) EXTRA_RSYNC_OPTS+=("${2:-}"); shift 2 ;;
    --ssh-opt)
      val="${2:-}"; shift 2
      [[ -n "$val" ]] || err "--ssh-opt requires a value, e.g., ProxyJump=bastion"
      if [[ "$val" == -o* ]]; then
        SSH_OPTS+=("$val")
      else
        # Store as two tokens: -o and the value, so ssh sees "-o value"
        SSH_OPTS+=("-o" "$val")
      fi
      ;;
    --dest-home-url)
      DEST_HOME_OVERRIDE="${2:-}"; shift 2
      [[ -n "$DEST_HOME_OVERRIDE" ]] || err "--dest-home-url requires a value (e.g., https://staging.example.com)"
      validate_url "$DEST_HOME_OVERRIDE" "--dest-home-url"
      ;;
    --dest-site-url)
      DEST_SITE_OVERRIDE="${2:-}"; shift 2
      [[ -n "$DEST_SITE_OVERRIDE" ]] || err "--dest-site-url requires a value (e.g., https://staging.example.com)"
      validate_url "$DEST_SITE_OVERRIDE" "--dest-site-url"
      ;;
    --dest-domain)
      DEST_DOMAIN_OVERRIDE="${2:-}"; shift 2
      [[ -n "$DEST_DOMAIN_OVERRIDE" ]] || err "--dest-domain requires a hostname or URL"
      ;;
    --version|-v) print_version; exit 0 ;;
    --help|-h) print_usage; exit 0 ;;
    *) err "Unknown argument: $1 (see --help)";;
  esac
done

if [[ -n "$DEST_DOMAIN_OVERRIDE" ]]; then
  if [[ "$DEST_DOMAIN_OVERRIDE" == *"://"* ]]; then
    DEST_DOMAIN_CANON="$DEST_DOMAIN_OVERRIDE"
  else
    DEST_DOMAIN_CANON="https://$DEST_DOMAIN_OVERRIDE"
  fi
  [[ -z "$DEST_HOME_OVERRIDE" ]] && DEST_HOME_OVERRIDE="$DEST_DOMAIN_CANON"
  [[ -z "$DEST_SITE_OVERRIDE" ]] && DEST_SITE_OVERRIDE="$DEST_DOMAIN_CANON"
fi

# --------------------
# Detect migration mode
# --------------------
if [[ -n "$DUPLICATOR_ARCHIVE" && ( -n "$DEST_HOST" || -n "$DEST_ROOT" ) ]]; then
  err "--duplicator-archive is mutually exclusive with --dest-host/--dest-root.
Choose one mode:
  Push mode: --dest-host and --dest-root
  Duplicator mode: --duplicator-archive"
fi

if [[ -n "$DUPLICATOR_ARCHIVE" ]]; then
  MIGRATION_MODE="duplicator"
elif [[ -n "$DEST_HOST" || -n "$DEST_ROOT" ]]; then
  MIGRATION_MODE="push"
else
  err "No migration mode specified. Choose one:
  Push mode: --dest-host <user@host> --dest-root </path>
  Duplicator mode: --duplicator-archive </path/to/backup.zip>
Run --help for more information."
fi

# ----------
# Preflight
# ----------
[[ -f "./wp-config.php" ]] || err "Run this from a WordPress root directory (wp-config.php not found)."

if [[ "$MIGRATION_MODE" == "push" ]]; then
  [[ -n "$DEST_HOST" && -n "$DEST_ROOT" ]] || err "Push mode requires both --dest-host and --dest-root."
elif [[ "$MIGRATION_MODE" == "duplicator" ]]; then
  [[ -n "$DUPLICATOR_ARCHIVE" ]] || err "Duplicator mode requires --duplicator-archive."

  # Validate Duplicator archive
  [[ -f "$DUPLICATOR_ARCHIVE" ]] || err "Duplicator archive not found: $DUPLICATOR_ARCHIVE"

  # Check if it's a zip file
  if ! file -b "$DUPLICATOR_ARCHIVE" 2>/dev/null | grep -qi "zip"; then
    err "Duplicator archive must be a ZIP file (got: $DUPLICATOR_ARCHIVE)"
  fi

  # Validate push-mode-only flags aren't used in Duplicator mode
  if [[ -n "$DEST_HOME_OVERRIDE" || -n "$DEST_SITE_OVERRIDE" || -n "$DEST_DOMAIN_OVERRIDE" ]]; then
    err "--dest-home-url, --dest-site-url, and --dest-domain are only valid in push mode."
  fi
  if [[ ${#EXTRA_RSYNC_OPTS[@]} -gt 0 ]]; then
    err "--rsync-opt is only valid in push mode."
  fi
  if ! $MAINTENANCE_SOURCE; then
    err "--no-maint-source is only valid in push mode."
  fi
  if ! $GZIP_DB; then
    err "--no-gzip is only valid in push mode."
  fi
  if [[ ${#SSH_OPTS[@]} -gt 1 ]]; then  # More than default -oStrictHostKeyChecking
    err "--ssh-opt is only valid in push mode."
  fi
fi

needs wp

if [[ "$MIGRATION_MODE" == "push" ]]; then
  needs rsync
  needs ssh
  needs gzip
elif [[ "$MIGRATION_MODE" == "duplicator" ]]; then
  needs unzip
  needs file
fi

STAMP="$(date +%Y%m%d-%H%M%S)"
if $DRY_RUN; then
  LOG_FILE="/dev/null"
  if [[ "$MIGRATION_MODE" == "push" ]]; then
    log "Starting push migration (dry-run preview; no log file will be written)."
  else
    log "Starting Duplicator import (dry-run preview; no log file will be written)."
  fi
else
  mkdir -p "$LOG_DIR"
  if [[ "$MIGRATION_MODE" == "push" ]]; then
    LOG_FILE="$LOG_DIR/migrate-wpcontent-push-$STAMP.log"
    log "Starting push migration. Log: $LOG_FILE"
  else
    LOG_FILE="$LOG_DIR/migrate-duplicator-import-$STAMP.log"
    log "Starting Duplicator import. Log: $LOG_FILE"
  fi
fi

if [[ "$MIGRATION_MODE" == "push" ]]; then
  setup_ssh_control

  # Test SSH connectivity
  log "Testing SSH connection to $DEST_HOST..."
  if ! ssh_run "$DEST_HOST" "echo 'SSH connection successful'" >/dev/null 2>&1; then
    err "Cannot connect to $DEST_HOST via SSH. Check:
  - Host is reachable
  - SSH key authentication is configured
  - Firewall allows SSH connections
  - Hostname/IP is correct"
  fi
  log "SSH connection to $DEST_HOST verified."
fi

# Verify WP installs
if [[ "$MIGRATION_MODE" == "push" ]]; then
  log "Verifying SOURCE WordPress at: $PWD"
  wp_local core is-installed || err "Source WordPress not detected."

  log "Verifying DEST WordPress at: $DEST_HOST:$DEST_ROOT"
  wp_remote "$DEST_HOST" "$DEST_ROOT" core is-installed || err "Destination WordPress not detected."
elif [[ "$MIGRATION_MODE" == "duplicator" ]]; then
  log "Verifying DEST WordPress at: $PWD"
  wp_local core is-installed || err "Destination WordPress not detected."
fi

# ==================================================================================
# PUSH MODE WORKFLOW
# ==================================================================================
if [[ "$MIGRATION_MODE" == "push" ]]; then

SOURCE_DB_PREFIX="$(wp_local db prefix)"
DEST_DB_PREFIX="$(wp_remote "$DEST_HOST" "$DEST_ROOT" db prefix)"
log "Source DB prefix: $SOURCE_DB_PREFIX"
log "Dest   DB prefix: $DEST_DB_PREFIX"

SOURCE_HOME_URL="$(wp_local eval "echo get_option(\"home\");")"
SOURCE_SITE_URL="$(wp_local eval "echo get_option(\"siteurl\");")"
DEST_HOME_URL="$(wp_remote "$DEST_HOST" "$DEST_ROOT" eval "echo get_option(\"home\");")"
DEST_SITE_URL="$(wp_remote "$DEST_HOST" "$DEST_ROOT" eval "echo get_option(\"siteurl\");")"

if [[ -n "$DEST_HOME_OVERRIDE" ]]; then
  log "Using --dest-home-url override: $DEST_HOME_OVERRIDE"
  DEST_HOME_URL="$DEST_HOME_OVERRIDE"
fi
if [[ -n "$DEST_SITE_OVERRIDE" ]]; then
  log "Using --dest-site-url override: $DEST_SITE_OVERRIDE"
  DEST_SITE_URL="$DEST_SITE_OVERRIDE"
fi

SOURCE_DISPLAY_URL="$SOURCE_HOME_URL"
if [[ -z "$SOURCE_DISPLAY_URL" ]]; then
  SOURCE_DISPLAY_URL="$SOURCE_SITE_URL"
fi

DEST_DISPLAY_URL="$DEST_HOME_URL"
if [[ -z "$DEST_DISPLAY_URL" ]]; then
  DEST_DISPLAY_URL="$DEST_SITE_URL"
fi

if [[ -n "$SOURCE_DISPLAY_URL" ]]; then
  log "Source primary URL: $SOURCE_DISPLAY_URL"
else
  log "Source primary URL could not be determined."
fi

if [[ -n "$DEST_DISPLAY_URL" ]]; then
  log "Dest   primary URL: $DEST_DISPLAY_URL"
else
  log "Dest   primary URL could not be determined."
fi

add_url_alignment_variations "$SOURCE_HOME_URL" "$DEST_HOME_URL"
add_url_alignment_variations "$SOURCE_SITE_URL" "$DEST_SITE_URL"
SOURCE_HOSTNAME="$(url_host_only "$SOURCE_DISPLAY_URL")"
DEST_HOSTNAME="$(url_host_only "$DEST_DISPLAY_URL")"
if [[ -n "$SOURCE_HOSTNAME" && -n "$DEST_HOSTNAME" ]]; then
  add_url_alignment_variations "$SOURCE_HOSTNAME" "$DEST_HOSTNAME"
  add_url_alignment_variations "//$SOURCE_HOSTNAME" "//$DEST_HOSTNAME"
fi
if [[ ${#SEARCH_REPLACE_ARGS[@]} -gt 0 ]]; then
  URL_ALIGNMENT_REQUIRED=true
  for ((idx=0; idx<${#SEARCH_REPLACE_ARGS[@]}; idx+=2)); do
    log "Detected URL mismatch (align after import): ${SEARCH_REPLACE_ARGS[idx]} -> ${SEARCH_REPLACE_ARGS[idx+1]}"
  done
else
  if [[ -n "$SOURCE_DISPLAY_URL" && -n "$DEST_DISPLAY_URL" ]]; then
    log "Source and destination URLs already aligned."
  else
    log "Skipping URL alignment check: missing site URL on source or destination."
  fi
fi

if wp_remote "$DEST_HOST" "$DEST_ROOT" core is-installed --network >/dev/null 2>&1; then
  SEARCH_REPLACE_FLAGS+=(--network)
fi

if wp_remote_has_command "$DEST_HOST" "$DEST_ROOT" redis; then
  REDIS_FLUSH_AVAILABLE=true
fi

if $GZIP_DB && $IMPORT_DB; then
  if ! ssh_run "$DEST_HOST" "command -v gzip >/dev/null 2>&1"; then
    err "Destination is missing gzip. Install gzip or re-run with --no-gzip to import without compression."
  fi
fi

# Discover wp-content paths
SRC_WP_CONTENT="$(discover_wp_content_local)"
DST_WP_CONTENT="$(discover_wp_content_remote "$DEST_HOST" "$DEST_ROOT")"
log "Source WP_CONTENT_DIR: $SRC_WP_CONTENT"
log "Dest   WP_CONTENT_DIR: $DST_WP_CONTENT"

# Size check (approx)
SRC_SIZE=$(du -sh "$SRC_WP_CONTENT" 2>/dev/null | cut -f1 || echo "unknown")
DST_FREE=$(ssh_run "$DEST_HOST" "df -h \"$DST_WP_CONTENT\" | awk 'NR==2{print \$4}'" || echo "unknown")
log "Approx source wp-content size: $SRC_SIZE"
log "Approx destination free space: $DST_FREE"

# Maintenance ON
log "Enabling maintenance mode..."
if $DRY_RUN; then
  if $MAINTENANCE_SOURCE; then
    log "[dry-run] Would enable maintenance mode on source."
  else
    log "[dry-run] Skipping maintenance mode on source (--no-maint-source)."
  fi
  log "[dry-run] Would enable maintenance mode on destination."
else
  if $MAINTENANCE_SOURCE; then
    maint_local on
  else
    log "Skipping maintenance mode on source (--no-maint-source)."
  fi
  maint_remote "$DEST_HOST" "$DEST_ROOT" on
fi

# -------------------------
# DB export & transfer step
# -------------------------
SITE_URL="$(wp_local option get home || wp_local option get siteurl || echo site)"
SITE_TAG="$(printf "%s" "$SITE_URL" | sed -E 's#https?://##; s#/.*$##; s#[^A-Za-z0-9._-]#_#g')"
DUMP_BASENAME="db_${SITE_TAG}_${STAMP}.sql"
DUMP_LOCAL="db-dumps/${DUMP_BASENAME}"
DUMP_LOCAL_GZ="${DUMP_LOCAL}.gz"
DEST_IMPORT_DIR="${DEST_ROOT%/}/db-imports"

if $DRY_RUN; then
  log "[dry-run] Would export DB to: $DUMP_LOCAL (gzip: $GZIP_DB)"
  log "[dry-run] Would create dest dir: $DEST_IMPORT_DIR and transfer dump"
  if $IMPORT_DB; then
    log "[dry-run] Would import DB on destination after transfer."
  else
    log "[dry-run] Would leave DB dump ready on destination (not imported)."
  fi
  if [[ "$SOURCE_DB_PREFIX" != "$DEST_DB_PREFIX" ]]; then
    if $IMPORT_DB; then
      log "[dry-run] Would update destination table prefix from '$DEST_DB_PREFIX' to '$SOURCE_DB_PREFIX'."
    else
      log "[dry-run] Destination table prefix differs ($DEST_DB_PREFIX -> $SOURCE_DB_PREFIX) but would remain unchanged because --no-import-db is set."
    fi
  fi
  if $URL_ALIGNMENT_REQUIRED; then
    if $IMPORT_DB; then
      for ((idx=0; idx<${#SEARCH_REPLACE_ARGS[@]}; idx+=2)); do
        log "[dry-run] Would run wp search-replace '${SEARCH_REPLACE_ARGS[idx]}' '${SEARCH_REPLACE_ARGS[idx+1]}' on destination."
      done
    else
      log "[dry-run] Source and destination URLs differ but automatic alignment is skipped because --no-import-db is set."
    fi
  fi
else
  mkdir -p "db-dumps"
  log "Exporting DB on source..."
  if $GZIP_DB; then
    wp_local db export - --add-drop-table | gzip -c > "$DUMP_LOCAL_GZ"
    DUMP_TO_SEND="$DUMP_LOCAL_GZ"
  else
    wp_local db export "$DUMP_LOCAL" --add-drop-table
    DUMP_TO_SEND="$DUMP_LOCAL"
  fi
  log "DB dump created: $DUMP_TO_SEND"

  log "Preparing destination import dir: $DEST_IMPORT_DIR"
  ssh_run "$DEST_HOST" "mkdir -p \"$DEST_IMPORT_DIR\""

  log "Transferring DB dump to destination..."
  ssh_cmd_db="$(ssh_cmd_string)"
  rsync -ah --info=stats2 --info=progress2 --partial -e "$ssh_cmd_db" \
    "$DUMP_TO_SEND" "$DEST_HOST":"$DEST_IMPORT_DIR"/ | tee -a "$LOG_FILE"

  if $IMPORT_DB; then
    DUMP_NAME_ON_DEST="$(basename "$DUMP_TO_SEND")"
    DEST_DUMP_PATH="$DEST_IMPORT_DIR/$DUMP_NAME_ON_DEST"
    if $GZIP_DB; then
      printf -v DEST_DUMP_PATH_QUOTED "%q" "$DEST_DUMP_PATH"
      TEMP_SQL_PATH="${DEST_DUMP_PATH%.gz}"
      printf -v TEMP_SQL_PATH_QUOTED "%q" "$TEMP_SQL_PATH"
      log "Decompressing DB dump on destination for import..."
      ssh_run "$DEST_HOST" "gzip -dc $DEST_DUMP_PATH_QUOTED > $TEMP_SQL_PATH_QUOTED"
      DEST_DUMP_PATH="$TEMP_SQL_PATH"
    fi

    log "Importing DB on destination: $DEST_DUMP_PATH"
    wp_remote "$DEST_HOST" "$DEST_ROOT" db import "$DEST_DUMP_PATH"

    if $GZIP_DB; then
      log "Removing temporary decompressed DB dump on destination."
      ssh_run "$DEST_HOST" "rm -f $TEMP_SQL_PATH_QUOTED"
    fi

    if [[ "$SOURCE_DB_PREFIX" != "$DEST_DB_PREFIX" ]]; then
      log "Updating destination table prefix: $DEST_DB_PREFIX -> $SOURCE_DB_PREFIX"
      wp_remote "$DEST_HOST" "$DEST_ROOT" config set table_prefix "$SOURCE_DB_PREFIX" --type=variable
      DEST_DB_PREFIX="$SOURCE_DB_PREFIX"
    fi

    if $URL_ALIGNMENT_REQUIRED; then
      log "Aligning destination URLs via wp search-replace."
      if ! wp_remote "$DEST_HOST" "$DEST_ROOT" search-replace "${SEARCH_REPLACE_ARGS[@]}" "${SEARCH_REPLACE_FLAGS[@]}"; then
        log "WARNING: wp search-replace failed; destination URLs may still reference source values."
      fi
      if [[ -n "$DEST_HOME_URL" ]]; then
        log "Ensuring destination home option remains: $DEST_HOME_URL"
        wp_remote "$DEST_HOST" "$DEST_ROOT" option update home "$DEST_HOME_URL" >/dev/null
      fi
      if [[ -n "$DEST_SITE_URL" ]]; then
        log "Ensuring destination siteurl option remains: $DEST_SITE_URL"
        wp_remote "$DEST_HOST" "$DEST_ROOT" option update siteurl "$DEST_SITE_URL" >/dev/null
      fi
    fi
  else
    log "DB dump ready on destination (not imported): $DEST_IMPORT_DIR/$(basename "$DUMP_TO_SEND")"
    if $URL_ALIGNMENT_REQUIRED; then
      for ((idx=0; idx<${#SEARCH_REPLACE_ARGS[@]}; idx+=2)); do
        log "NOTE: After importing manually, replace '${SEARCH_REPLACE_ARGS[idx]}' with '${SEARCH_REPLACE_ARGS[idx+1]}' on the destination database."
      done
    fi
  fi
fi

# -------------------------------
# Backup destination wp-content
# -------------------------------
DST_WP_CONTENT_BACKUP="$(backup_remote_wp_content "$DEST_HOST" "$DST_WP_CONTENT" "$STAMP")"

# ---------------------
# Build rsync options
# ---------------------
RS_OPTS=( -a -h -z --info=stats2 --partial --links --prune-empty-dirs --no-perms --no-owner --no-group )
# Add progress indicator for real runs (shows current file being transferred)
$DRY_RUN || RS_OPTS+=( --info=progress2 )
$DRY_RUN && RS_OPTS+=( -n --itemize-changes )

# Exclude object-cache.php drop-in to prevent caching infrastructure incompatibility
# Use root-anchored path (/) to only exclude wp-content/object-cache.php, not plugin files
RS_OPTS+=( --exclude=/object-cache.php )
log "Excluding object-cache.php drop-in from transfer (preserves destination caching setup)"

# Extra rsync opts
if [[ ${#EXTRA_RSYNC_OPTS[@]} -gt 0 ]]; then
  RS_OPTS+=( "${EXTRA_RSYNC_OPTS[@]}" )
fi

log "Rsync options: ${RS_OPTS[*]}"

# -------------------------
# Transfer wp-content (push)
# -------------------------
log "Pushing $SRC_WP_CONTENT -> $DEST_HOST:$DST_WP_CONTENT"
ssh_cmd_content="$(ssh_cmd_string)"
rsync "${RS_OPTS[@]}" -e "$ssh_cmd_content" \
  "$SRC_WP_CONTENT"/ \
  "$DEST_HOST":"$DST_WP_CONTENT"/ | tee -a "$LOG_FILE"

# Report backup location if applicable
if [[ -n "$DST_WP_CONTENT_BACKUP" ]]; then
  if $DRY_RUN; then
    log "[dry-run] Destination wp-content would be backed up to: $DST_WP_CONTENT_BACKUP"
  else
    log "Destination wp-content backed up to: $DST_WP_CONTENT_BACKUP"
  fi
fi

# Maintenance OFF
log "Disabling maintenance mode..."
if $DRY_RUN; then
  log "[dry-run] Would disable maintenance mode on destination."
  if $MAINTENANCE_SOURCE; then
    log "[dry-run] Would disable maintenance mode on source."
  else
    log "[dry-run] Source maintenance mode was skipped; nothing to disable."
  fi
else
  maint_remote "$DEST_HOST" "$DEST_ROOT" off
  if $MAINTENANCE_SOURCE; then
    maint_local off
  else
    log "Source maintenance mode was skipped; nothing to disable."
  fi
fi

if $DRY_RUN; then
  log "[dry-run] Migration preview complete."
  REMOTE_DUMP_NAME="$(basename "${DUMP_LOCAL}${GZIP_DB:+.gz}")"
  log "[dry-run] DB file would be placed at: $DEST_IMPORT_DIR/$REMOTE_DUMP_NAME"
  if $IMPORT_DB; then
    log "[dry-run] NOTE: DB would be imported automatically during a real run."
  else
    if $GZIP_DB; then
      REMOTE_SQL_NAME="${REMOTE_DUMP_NAME%.gz}"
      log "[dry-run] NOTE: Import would be skipped (--no-import-db). To import later on destination:
  cd \"$DEST_ROOT\" && gzip -dc \"$DEST_IMPORT_DIR/$REMOTE_DUMP_NAME\" > \"$DEST_IMPORT_DIR/$REMOTE_SQL_NAME\" && wp db import \"$DEST_IMPORT_DIR/$REMOTE_SQL_NAME\" && rm \"$DEST_IMPORT_DIR/$REMOTE_SQL_NAME\""
    else
      log "[dry-run] NOTE: Import would be skipped (--no-import-db). To import later on destination:
  cd \"$DEST_ROOT\" && wp db import \"$DEST_IMPORT_DIR/$REMOTE_DUMP_NAME\""
    fi
  fi
  if $REDIS_FLUSH_AVAILABLE; then
    log "[dry-run] Would flush Object Cache Pro cache via: wp redis flush"
  else
    log "[dry-run] Skipping Object Cache Pro cache flush; wp redis command not available."
  fi
else
  log "Migration complete."
  REMOTE_DUMP_NAME="$(basename "${DUMP_LOCAL}${GZIP_DB:+.gz}")"
  log "DB file on destination: $DEST_IMPORT_DIR/$REMOTE_DUMP_NAME"

  # Log rollback instructions if backup exists
  if [[ -n "$DST_WP_CONTENT_BACKUP" ]]; then
    log ""
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log "ROLLBACK INSTRUCTIONS (if needed):"
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log "To restore the previous wp-content on destination:"
    log "  ssh $DEST_HOST \"rm -rf '$DST_WP_CONTENT' && mv '$DST_WP_CONTENT_BACKUP' '$DST_WP_CONTENT'\""
    log ""
    log "Backup location on destination: $DST_WP_CONTENT_BACKUP"
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log ""
  fi

  if ! $IMPORT_DB; then
    if $GZIP_DB; then
      REMOTE_SQL_NAME="${REMOTE_DUMP_NAME%.gz}"
      log "NOTE: Import was skipped (--no-import-db). To import later on destination:
  cd \"$DEST_ROOT\" && gzip -dc \"$DEST_IMPORT_DIR/$REMOTE_DUMP_NAME\" > \"$DEST_IMPORT_DIR/$REMOTE_SQL_NAME\" && wp db import \"$DEST_IMPORT_DIR/$REMOTE_SQL_NAME\" && rm \"$DEST_IMPORT_DIR/$REMOTE_SQL_NAME\""
    else
      log "NOTE: Import was skipped (--no-import-db). To import later on destination:
  cd \"$DEST_ROOT\" && wp db import \"$DEST_IMPORT_DIR/$REMOTE_DUMP_NAME\""
    fi
  fi
  if $REDIS_FLUSH_AVAILABLE; then
    log "Flushing Object Cache Pro cache on destination..."
    if ! wp_remote_full "$DEST_HOST" "$DEST_ROOT" redis flush; then
      log "WARNING: Failed to flush Object Cache Pro cache via wp redis flush."
    fi
  else
    log "Skipping Object Cache Pro cache flush; wp redis command not available."
  fi
fi

# End of push mode workflow
fi

# ==================================================================================
# DUPLICATOR MODE WORKFLOW
# ==================================================================================
if [[ "$MIGRATION_MODE" == "duplicator" ]]; then

log "Archive: $DUPLICATOR_ARCHIVE"

# Phase 0: Capture destination URLs BEFORE any operations
log "Capturing current destination URLs..."
ORIGINAL_DEST_HOME_URL="$(wp_local option get home)"
ORIGINAL_DEST_SITE_URL="$(wp_local option get siteurl)"
log "Current site home: $ORIGINAL_DEST_HOME_URL"
log "Current site URL: $ORIGINAL_DEST_SITE_URL"

# Phase 1: Disk space check
check_disk_space_for_duplicator "$DUPLICATOR_ARCHIVE"

# Phase 2: Extract archive
extract_duplicator_archive "$DUPLICATOR_ARCHIVE"

# Phase 3: Discover database and wp-content
find_duplicator_database "$DUPLICATOR_EXTRACT_DIR"
find_duplicator_wp_content "$DUPLICATOR_EXTRACT_DIR"

# Phase 4: Enable maintenance mode
log "Enabling maintenance mode on destination..."
if $DRY_RUN; then
  log "[dry-run] Would enable maintenance mode on destination."
else
  wp_local maintenance-mode activate >/dev/null || err "Failed to enable maintenance mode"
  MAINT_LOCAL_ACTIVE=true
fi

# Phase 5: Backup current database
if $DRY_RUN; then
  log "[dry-run] Would backup current database to: db-backups/pre-duplicator-backup_${STAMP}.sql.gz"
else
  mkdir -p "db-backups"
  BACKUP_DB_FILE="db-backups/pre-duplicator-backup_${STAMP}.sql.gz"
  log "Backing up current database to: $BACKUP_DB_FILE"
  wp_local db export - | gzip > "$BACKUP_DB_FILE"
  log "Database backup created: $BACKUP_DB_FILE"
fi

# Phase 6: Backup current wp-content
DEST_WP_CONTENT="$(discover_wp_content_local)"
log "Destination WP_CONTENT_DIR: $DEST_WP_CONTENT"

if $DRY_RUN; then
  DEST_WP_CONTENT_BACKUP="${DEST_WP_CONTENT}.backup-${STAMP}"
  log "[dry-run] Would backup current wp-content to: $DEST_WP_CONTENT_BACKUP"
else
  DEST_WP_CONTENT_BACKUP="${DEST_WP_CONTENT}.backup-${STAMP}"
  log "Backing up current wp-content to: $DEST_WP_CONTENT_BACKUP"
  cp -a "$DEST_WP_CONTENT" "$DEST_WP_CONTENT_BACKUP"
  log "wp-content backup created: $DEST_WP_CONTENT_BACKUP"
fi

# Phase 7: Import database
if $DRY_RUN; then
  log "[dry-run] Would reset database to clean state"
  log "[dry-run] Would import database from: $(basename "$DUPLICATOR_DB_FILE")"
  log "[dry-run] Would detect and align table prefix if needed"
else
  log "Importing database from: $(basename "$DUPLICATOR_DB_FILE")"

  # Get current destination prefix before import
  DEST_DB_PREFIX_BEFORE="$(wp_local db prefix)"
  log "Current wp-config.php table prefix: $DEST_DB_PREFIX_BEFORE"

  # Reset database to clean state to prevent duplicate key errors
  log "Resetting database to clean state..."
  wp_local db reset --yes
  log "Database reset complete"

  # Import the database
  wp_local db import "$DUPLICATOR_DB_FILE"
  log "Database imported successfully"

  # Detect the prefix from the imported database
  # Strategy: Find a prefix that exists for ALL core WordPress tables (options, posts, users)
  # This ensures we identify the actual WordPress prefix, not plugin tables like wp_statistics_options
  IMPORTED_DB_PREFIX=""

  # Get all tables from the database
  all_tables=$(wp_local db query "SHOW TABLES" --skip-column-names 2>/dev/null)

  if [[ -n "$all_tables" ]]; then
    # Define core WordPress table suffixes that must all exist
    core_suffixes=("options" "posts" "users")

    # Extract all potential prefixes by looking at tables ending in "options"
    # A table like "wp_options" gives prefix "wp_", "my_site_options" gives "my_site_"
    while IFS= read -r table; do
      # Check if this table ends with "_options"
      if [[ "$table" == *_options ]]; then
        # Extract the potential prefix (everything before "_options")
        potential_prefix="${table%_options}_"

        # Skip obvious plugin tables (have text between what looks like a prefix and "options")
        # e.g., "wp_statistics_options" has "statistics_options" after "wp_"
        # We want to find cases where prefix + suffix = tablename for CORE tables

        # Verify this prefix exists for ALL core WordPress tables
        prefix_valid=true
        for suffix in "${core_suffixes[@]}"; do
          expected_table="${potential_prefix}${suffix}"
          # Check if this expected core table exists in our table list
          if ! echo "$all_tables" | grep -q "^${expected_table}$"; then
            prefix_valid=false
            break
          fi
        done

        # If all core tables exist with this prefix, we found it
        if $prefix_valid; then
          IMPORTED_DB_PREFIX="$potential_prefix"
          log "Detected imported database prefix: $IMPORTED_DB_PREFIX"
          log "  Verified core tables: ${IMPORTED_DB_PREFIX}options, ${IMPORTED_DB_PREFIX}posts, ${IMPORTED_DB_PREFIX}users"
          break
        fi
      fi
    done <<< "$all_tables"
  fi

  if [[ -n "$IMPORTED_DB_PREFIX" ]]; then
    # If the imported prefix differs from wp-config.php, update wp-config.php
    if [[ "$IMPORTED_DB_PREFIX" != "$DEST_DB_PREFIX_BEFORE" ]]; then
      log "Updating wp-config.php table prefix: $DEST_DB_PREFIX_BEFORE -> $IMPORTED_DB_PREFIX"
      wp_local config set table_prefix "$IMPORTED_DB_PREFIX" --type=variable
      log "Table prefix updated successfully"
    else
      log "Table prefix matches wp-config.php; no update needed"
    fi
  else
    log "WARNING: Could not detect table prefix from imported database; assuming it matches wp-config.php"
  fi
fi

# Phase 8: Get imported URLs and perform search-replace
if $DRY_RUN; then
  log "[dry-run] Would detect imported URLs and replace with destination URLs"
  log "[dry-run]   Replace: <imported-home-url> -> $ORIGINAL_DEST_HOME_URL"
  log "[dry-run]   Replace: <imported-site-url> -> $ORIGINAL_DEST_SITE_URL"
else
  log "Detecting imported URLs..."
  IMPORTED_HOME_URL="$(wp_local option get home)"
  IMPORTED_SITE_URL="$(wp_local option get siteurl)"
  log "Imported home URL: $IMPORTED_HOME_URL"
  log "Imported site URL: $IMPORTED_SITE_URL"

  if [[ "$IMPORTED_HOME_URL" != "$ORIGINAL_DEST_HOME_URL" || "$IMPORTED_SITE_URL" != "$ORIGINAL_DEST_SITE_URL" ]]; then
    log "Aligning URLs to destination via wp search-replace..."

    # Build search-replace arguments
    SEARCH_REPLACE_ARGS=()
    add_url_alignment_variations "$IMPORTED_HOME_URL" "$ORIGINAL_DEST_HOME_URL"
    add_url_alignment_variations "$IMPORTED_SITE_URL" "$ORIGINAL_DEST_SITE_URL"

    IMPORTED_HOSTNAME="$(url_host_only "$IMPORTED_HOME_URL")"
    DEST_HOSTNAME="$(url_host_only "$ORIGINAL_DEST_HOME_URL")"
    if [[ -n "$IMPORTED_HOSTNAME" && -n "$DEST_HOSTNAME" ]]; then
      add_url_alignment_variations "$IMPORTED_HOSTNAME" "$DEST_HOSTNAME"
      add_url_alignment_variations "//$IMPORTED_HOSTNAME" "//$DEST_HOSTNAME"
    fi

    # Check for multisite
    if wp_local core is-installed --network >/dev/null 2>&1; then
      SEARCH_REPLACE_FLAGS+=(--network)
    fi

    # Perform search-replace
    if ! wp_local search-replace "${SEARCH_REPLACE_ARGS[@]}" "${SEARCH_REPLACE_FLAGS[@]}"; then
      log "WARNING: wp search-replace failed; some URLs may still reference the imported site."
    fi

    # Ensure destination URLs are set correctly
    log "Ensuring destination URLs are set correctly..."
    wp_local option update home "$ORIGINAL_DEST_HOME_URL" >/dev/null
    wp_local option update siteurl "$ORIGINAL_DEST_SITE_URL" >/dev/null
  else
    log "Imported URLs match destination URLs; no replacement needed."
  fi
fi

# Phase 9: Replace wp-content
if $DRY_RUN; then
  log "[dry-run] Would replace wp-content with archive contents"
  log "[dry-run]   Source: $DUPLICATOR_WP_CONTENT"
  log "[dry-run]   Destination: $DEST_WP_CONTENT"
  log "[dry-run] Would exclude object-cache.php from archive (preserves destination caching setup)"
else
  log "Replacing wp-content with archive contents..."
  log "  Source: ${DUPLICATOR_WP_CONTENT#"$DUPLICATOR_EXTRACT_DIR"/}"
  log "  Destination: $DEST_WP_CONTENT"

  # Remove existing wp-content and replace
  rm -rf "$DEST_WP_CONTENT"
  cp -a "$DUPLICATOR_WP_CONTENT" "$DEST_WP_CONTENT"
  log "wp-content replaced successfully"

  # Remove object-cache.php from imported wp-content to prevent caching infrastructure incompatibility
  if [[ -f "$DEST_WP_CONTENT/object-cache.php" ]]; then
    log "Removing object-cache.php from imported wp-content (preserves destination caching setup)"
    rm -f "$DEST_WP_CONTENT/object-cache.php"
  fi
fi

# Phase 10: Flush cache if available
if wp_local cli has-command redis >/dev/null 2>&1; then
  if $DRY_RUN; then
    log "[dry-run] Would flush Object Cache Pro cache via: wp redis flush"
  else
    log "Flushing Object Cache Pro cache..."
    if ! wp_local redis flush; then
      log "WARNING: Failed to flush Object Cache Pro cache via wp redis flush."
    fi
  fi
else
  log "Skipping Object Cache Pro cache flush; wp redis command not available."
fi

# Phase 11: Disable maintenance mode
log "Disabling maintenance mode..."
if $DRY_RUN; then
  log "[dry-run] Would disable maintenance mode on destination."
else
  wp_local maintenance-mode deactivate >/dev/null || log "WARNING: Failed to disable maintenance mode"
  MAINT_LOCAL_ACTIVE=false
fi

# Phase 12: Report completion and rollback instructions
if $DRY_RUN; then
  log "[dry-run] Duplicator import preview complete."
else
  log "Duplicator import complete."
  log ""
  log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  log "ROLLBACK INSTRUCTIONS (if needed):"
  log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  log "1. Restore database:"
  log "   wp db import <(gunzip -c $BACKUP_DB_FILE)"
  log ""
  log "2. Restore wp-content:"
  log "   rm -rf $DEST_WP_CONTENT"
  log "   mv $DEST_WP_CONTENT_BACKUP $DEST_WP_CONTENT"
  log ""
  log "Backups created:"
  log "  Database: $BACKUP_DB_FILE"
  log "  wp-content: $DEST_WP_CONTENT_BACKUP"
  log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  log ""
fi

# End of Duplicator mode workflow
fi
