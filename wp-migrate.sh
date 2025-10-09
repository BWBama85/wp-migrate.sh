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
DEST_HOST=""                 # REQUIRED: user@dest.example.com
DEST_ROOT=""                 # REQUIRED: absolute WP root on destination (e.g., /var/www/site)
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
  ssh "${SSH_OPTS[@]}" "$host" "$@"
}

# Robust remote WP-CLI runner that preserves arguments exactly
wp_remote() {
  local host="$1" root="$2"; shift 2
  local root_quoted cmd_quoted
  printf -v root_quoted "%q" "$root"
  local cmd=(wp --skip-plugins --skip-themes "$@")
  printf -v cmd_quoted "%q " "${cmd[@]}"
  ssh "${SSH_OPTS[@]}" "$host" "bash -lc 'cd $root_quoted && ${cmd_quoted% }'"
}

# Run remote WP-CLI without skipping plugins/themes (needed for plugin-provided commands)
wp_remote_full() {
  local host="$1" root="$2"; shift 2
  local root_quoted cmd_quoted
  printf -v root_quoted "%q" "$root"
  local cmd=(wp "$@")
  printf -v cmd_quoted "%q " "${cmd[@]}"
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

print_usage() {
  cat <<USAGE
Usage (run on SOURCE WP root):
  $(basename "$0") --dest-host <user@host> --dest-root </abs/path> [options]

Required:
  --dest-host <user@dest.example.com>
  --dest-root </absolute/path/to/destination/wp-root>

Options:
  --dry-run                 Preview rsync; DB export/transfer is also previewed (no dump created)
  --import-db               (Deprecated) Explicitly import the DB on destination (default behavior)
  --no-import-db            Skip importing the DB on destination after transfer
  --no-gzip                 Don't gzip the DB dump (default is gzip on)
  --no-maint-source         Skip enabling maintenance mode on the source site
  --dest-domain '<host>'    Override destination domain (assigns https://<host> to home/site URLs unless other overrides supplied)
  --dest-home-url '<url>'   Force the destination home URL used for replacements
  --dest-site-url '<url>'   Force the destination site URL used for replacements
  --rsync-opt '<opt>'       Add an rsync option (can be repeated)
  --ssh-opt '<opt>'         Add an SSH -o option (e.g., ProxyJump=bastion). Can be repeated.
  --help                    Show this help

Examples:
  $(basename "$0") --dest-host wp@dest --dest-root /var/www/site
  $(basename "$0") --dest-host wp@dest --dest-root /var/www/site --no-import-db
USAGE
}

# -------------
# Parse args
# -------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dest-host) DEST_HOST="${2:-}"; shift 2 ;;
    --dest-root) DEST_ROOT="${2:-}"; shift 2 ;;
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

# ----------
# Preflight
# ----------
[[ -f "./wp-config.php" ]] || err "Run this from the SOURCE WordPress root (wp-config.php not found)."
[[ -n "$DEST_HOST" && -n "$DEST_ROOT" ]] || err "--dest-host and --dest-root are required."

needs wp
needs rsync
needs ssh
needs gzip

STAMP="$(date +%Y%m%d-%H%M%S)"
if $DRY_RUN; then
  LOG_FILE="/dev/null"
  log "Starting push migration (dry-run preview; no log file will be written)."
else
  mkdir -p "$LOG_DIR"
  LOG_FILE="$LOG_DIR/migrate-wpcontent-push-$STAMP.log"
  log "Starting push migration. Log: $LOG_FILE"
fi

setup_ssh_control

# Verify WP installs
log "Verifying SOURCE WordPress at: $PWD"
wp_local core is-installed || err "Source WordPress not detected."

log "Verifying DEST WordPress at: $DEST_HOST:$DEST_ROOT"
wp_remote "$DEST_HOST" "$DEST_ROOT" core is-installed || err "Destination WordPress not detected."

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
  rsync -ah --info=stats2 --partial -e "$ssh_cmd_db" \
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
$DRY_RUN && RS_OPTS+=( -n --itemize-changes )

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
