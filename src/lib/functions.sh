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
  # Maintenance cleanup is non-critical - don't let it affect exit status
  maintenance_cleanup || true
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
  if ! rm -rf "$DUPLICATOR_EXTRACT_DIR" 2>/dev/null; then
    log_warning "Failed to remove temporary extraction directory: $DUPLICATOR_EXTRACT_DIR. You may need to manually delete it."
  fi
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
      log_warning "Failed to disable maintenance mode on destination during cleanup. You may need to manually remove the .maintenance file."
    fi
  fi

  if $MAINT_LOCAL_ACTIVE; then
    if ! maint_local off; then
      had_failure=true
      log_warning "Failed to disable maintenance mode on source during cleanup. You may need to manually remove the .maintenance file."
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
  --stellarsites            Enable StellarSites compatibility mode (preserves protected mu-plugins, Duplicator mode only)
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
  $(basename "$0") --duplicator-archive /backups/site.zip --stellarsites
USAGE
}

