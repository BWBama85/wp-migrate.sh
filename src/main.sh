# -------------
# Parse args
# -------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dest-host) DEST_HOST="${2:-}"; shift 2 ;;
    --dest-root) DEST_ROOT="${2:-}"; shift 2 ;;
    --archive) ARCHIVE_FILE="${2:-}"; shift 2 ;;
    --archive-type) ARCHIVE_TYPE="${2:-}"; shift 2 ;;
    --duplicator-archive)
      # Backward compatibility: treat as --archive with duplicator type
      ARCHIVE_FILE="${2:-}"
      ARCHIVE_TYPE="duplicator"
      shift 2
      ;;
    --dry-run) DRY_RUN=true; shift ;;
    --verbose) VERBOSE=true; shift ;;
    --trace) TRACE_MODE=true; VERBOSE=true; shift ;;
    --import-db) IMPORT_DB=true; shift ;;
    --no-import-db) IMPORT_DB=false; shift ;;
    --no-search-replace) SEARCH_REPLACE=false; shift ;;
    --no-gzip) GZIP_DB=false; shift ;;
    --no-maint-source) MAINTENANCE_SOURCE=false; shift ;;
    --stellarsites) STELLARSITES_MODE=true; PRESERVE_DEST_PLUGINS=true; shift ;;
    --preserve-dest-plugins) PRESERVE_DEST_PLUGINS=true; shift ;;
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
    *) err "Unknown argument: $1

Next steps:
  1. Run: ./wp-migrate.sh --help
  2. Check for typos in flag names (--dest-host, --archive, etc.)
  3. Ensure flags use = syntax: --flag=value OR space syntax: --flag value";;
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
if [[ -n "$ARCHIVE_FILE" && ( -n "$DEST_HOST" || -n "$DEST_ROOT" ) ]]; then
  err "--archive is mutually exclusive with --dest-host/--dest-root.

You cannot use both push mode and archive mode simultaneously.

Choose one mode:
  • Push mode (migrate via SSH):
      ./wp-migrate.sh --dest-host user@host --dest-root /path

  • Archive mode (import backup):
      ./wp-migrate.sh --archive /path/to/backup.zip

Run ./wp-migrate.sh --help for more examples."
fi

if [[ -n "$ARCHIVE_FILE" ]]; then
  MIGRATION_MODE="archive"

  # Note: Adapter files are already concatenated into the built script by Makefile
  # No dynamic sourcing needed - all adapter code is already loaded

  # Check basic tools needed for adapter detection before calling validate functions
  # This prevents cryptic "command not found" errors during detection with set -e
  if ! command -v file >/dev/null 2>&1; then
    err "Missing required tool for archive detection: file
Please install the 'file' package (e.g., apt-get install file)"
  fi

  # Check for archive tools needed by available adapters
  # Duplicator requires unzip, Jetpack requires tar
  if ! command -v unzip >/dev/null 2>&1; then
    err "Missing required tool for archive detection: unzip
Duplicator archives require unzip.
Please install unzip (e.g., apt-get install unzip or brew install unzip)"
  fi

  if ! command -v tar >/dev/null 2>&1; then
    err "Missing required tool for archive detection: tar
Jetpack Backup archives require tar.
Please install tar (usually pre-installed; check your system)"
  fi

  # Detect or load adapter
  if [[ -n "$ARCHIVE_TYPE" ]]; then
    # User specified adapter type explicitly
    if ! load_adapter "$ARCHIVE_TYPE"; then
      err "Unknown archive type: $ARCHIVE_TYPE

Available archive types: ${AVAILABLE_ADAPTERS[*]}

Next steps:
  1. Check for typos in --archive-type value
  2. Use one of the supported types:
       --archive-type duplicator   # For Duplicator Pro/Lite backups
       --archive-type jetpack      # For Jetpack Backup archives
       --archive-type solidbackups # For Solid Backups/BackupBuddy archives
  3. Or remove --archive-type to auto-detect format"
    fi
    ARCHIVE_ADAPTER="$ARCHIVE_TYPE"
  else
    # Auto-detect adapter from archive
    ARCHIVE_ADAPTER=$(detect_adapter "$ARCHIVE_FILE")
    if [[ -z "$ARCHIVE_ADAPTER" ]]; then
      err "Unable to auto-detect archive format for: $ARCHIVE_FILE

The archive doesn't match any known backup plugin format.

Supported formats:
  • Duplicator Pro/Lite (.zip with installer.php)
  • Jetpack Backup (.tar.gz or .zip with sql/ directory)
  • Solid Backups/BackupBuddy (.zip with backupbuddy_temp/ directory)

Next steps:
  1. Verify this is a valid WordPress backup archive:
       file \"$ARCHIVE_FILE\"
  2. Check which backup plugin created this archive
  3. Try specifying the format explicitly:
       --archive \"$ARCHIVE_FILE\" --archive-type duplicator
       --archive \"$ARCHIVE_FILE\" --archive-type jetpack
       --archive \"$ARCHIVE_FILE\" --archive-type solidbackups
  4. If using an unsupported backup plugin, you may need to:
       • Extract the archive manually
       • Import database via wp db import
       • Sync wp-content via push mode from another server

Available types: ${AVAILABLE_ADAPTERS[*]}"
    fi
  fi

  log "Archive format: $(get_archive_format_name)"

elif [[ -n "$DEST_HOST" || -n "$DEST_ROOT" ]]; then
  MIGRATION_MODE="push"
else
  err "No migration mode specified. You must choose either push mode or archive mode.

Push mode (migrate to remote server via SSH):
  ./wp-migrate.sh --dest-host user@host --dest-root /var/www/site

Archive mode (import local backup):
  ./wp-migrate.sh --archive /path/to/backup.zip

Next steps:
  1. Run: ./wp-migrate.sh --help
  2. Choose which mode suits your use case
  3. Run with appropriate flags"
fi

# ----------
# Preflight
# ----------
[[ -f "./wp-config.php" ]] || err "WordPress installation not detected. wp-config.php not found in current directory.

Current directory: $PWD

Next steps:
  1. Verify you're in the WordPress root directory:
       ls -la wp-config.php
  2. If wp-config.php exists elsewhere, cd to that directory first
  3. For push mode: Run from SOURCE WordPress root
  4. For archive mode: Run from DESTINATION WordPress root"

if [[ "$MIGRATION_MODE" == "push" ]]; then
  [[ -n "$DEST_HOST" && -n "$DEST_ROOT" ]] || err "Push mode requires both --dest-host and --dest-root flags.

Missing: $([ -z "$DEST_HOST" ] && echo "--dest-host")$([ -z "$DEST_HOST" ] && [ -z "$DEST_ROOT" ] && echo " and ")$([ -z "$DEST_ROOT" ] && echo "--dest-root")

Correct usage:
  ./wp-migrate.sh --dest-host user@remote.server --dest-root /var/www/html

Example:
  ./wp-migrate.sh --dest-host wp@example.com --dest-root /home/wp/public_html"
elif [[ "$MIGRATION_MODE" == "archive" ]]; then
  [[ -n "$ARCHIVE_FILE" ]] || err "Archive mode requires --archive."

  # Validate archive file exists
  [[ -f "$ARCHIVE_FILE" ]] || err "Archive file not found: $ARCHIVE_FILE

Next steps:
  1. Verify the file path is correct:
       ls -lh \"$ARCHIVE_FILE\"
  2. Check for typos in the path
  3. Ensure you have read permissions:
       ls -l \"$(dirname "$ARCHIVE_FILE")\"
  4. Try using an absolute path instead of relative path"

  # Validate push-mode-only flags aren't used in archive mode
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
elif [[ "$MIGRATION_MODE" == "archive" ]]; then
  # Check adapter-specific dependencies
  check_adapter_dependencies "$ARCHIVE_ADAPTER"
fi

STAMP="$(date +%Y%m%d-%H%M%S)"
if $DRY_RUN; then
  LOG_FILE="/dev/null"
  if [[ "$MIGRATION_MODE" == "push" ]]; then
    log "Starting push migration (dry-run preview; no log file will be written)."
  else
    log "Starting archive import (dry-run preview; no log file will be written)."
  fi
else
  mkdir -p "$LOG_DIR"
  if [[ "$MIGRATION_MODE" == "push" ]]; then
    LOG_FILE="$LOG_DIR/migrate-wpcontent-push-$STAMP.log"
    log "Starting push migration. Log: $LOG_FILE"
  else
    LOG_FILE="$LOG_DIR/migrate-archive-import-$STAMP.log"
    log "Starting archive import. Log: $LOG_FILE"
  fi
fi

if [[ "$MIGRATION_MODE" == "push" ]]; then
  setup_ssh_control

  # Test SSH connectivity
  log "Testing SSH connection to $DEST_HOST..."
  if ! ssh_run "$DEST_HOST" "echo 'SSH connection successful'" >/dev/null 2>&1; then
    err "Cannot connect to $DEST_HOST via SSH.

Common causes:
  • Host is unreachable (network/DNS issue)
  • SSH key authentication not configured
  • Wrong username or hostname
  • Firewall blocking SSH (port 22)
  • SSH service not running on remote host

Next steps:
  1. Test basic connectivity:
       ping ${DEST_HOST##*@}
  2. Test SSH connection manually:
       ssh $DEST_HOST \"echo 'Connection test'\"
  3. Verify SSH key is added to remote authorized_keys:
       ssh-copy-id $DEST_HOST
  4. Check SSH config and permissions:
       ls -la ~/.ssh/
  5. Try with verbose SSH output:
       ssh -vvv $DEST_HOST

If using a bastion/jump host, add --ssh-opt:
  --ssh-opt ProxyJump=bastion.example.com"
  fi
  log "SSH connection to $DEST_HOST verified."
fi

# Verify WP installs
if [[ "$MIGRATION_MODE" == "push" ]]; then
  log "Verifying SOURCE WordPress at: $PWD"
  wp_local core is-installed || err "Source WordPress not detected at: $PWD

Next steps:
  1. Verify WordPress is installed:
       wp core version
  2. Check wp-config.php has correct database credentials:
       wp db check
  3. Ensure WP-CLI can connect to database:
       wp db query \"SELECT COUNT(*) FROM wp_options\"
  4. Verify you're in the WordPress root directory:
       ls -la wp-config.php wp-content/"

  log "Verifying DEST WordPress at: $DEST_HOST:$DEST_ROOT"
  wp_remote "$DEST_HOST" "$DEST_ROOT" core is-installed || err "Destination WordPress not detected at: $DEST_HOST:$DEST_ROOT

Next steps:
  1. Verify WordPress is installed on destination:
       ssh $DEST_HOST \"cd $DEST_ROOT && wp core version\"
  2. Check destination wp-config.php exists:
       ssh $DEST_HOST \"ls -la $DEST_ROOT/wp-config.php\"
  3. Verify database connection on destination:
       ssh $DEST_HOST \"cd $DEST_ROOT && wp db check\"
  4. Ensure WP-CLI is installed on destination:
       ssh $DEST_HOST \"which wp && wp --version\""
elif [[ "$MIGRATION_MODE" == "archive" ]]; then
  log "Verifying DEST WordPress at: $PWD"
  wp_local core is-installed || err "Destination WordPress not detected at: $PWD

Archive mode requires an existing WordPress installation at the destination.

Next steps:
  1. Verify WordPress is installed:
       wp core version
  2. Check database connection:
       wp db check
  3. If WordPress is not installed, install it first:
       wp core download
       wp config create --dbname=DB --dbuser=USER --dbpass=PASS
       wp core install --url=http://example.com --title=Site --admin_user=admin
  4. Then re-run the archive import"
fi

# ==================================================================================
# PUSH MODE WORKFLOW
# ==================================================================================
if [[ "$MIGRATION_MODE" == "push" ]]; then

log_verbose "Detecting source database prefix..."
SOURCE_DB_PREFIX="$(wp_local db prefix)"
log "Source DB prefix: $SOURCE_DB_PREFIX"

log_verbose "Detecting destination database prefix..."
DEST_DB_PREFIX="$(wp_remote "$DEST_HOST" "$DEST_ROOT" db prefix)"
log "Dest   DB prefix: $DEST_DB_PREFIX"

log_verbose "Detecting WordPress URLs..."
SOURCE_HOME_URL="$(wp_local eval "echo get_option(\"home\");")"
SOURCE_SITE_URL="$(wp_local eval "echo get_option(\"siteurl\");")"
log_verbose "  Source home: $SOURCE_HOME_URL"
log_verbose "  Source site: $SOURCE_SITE_URL"

DEST_HOME_URL="$(wp_remote "$DEST_HOST" "$DEST_ROOT" eval "echo get_option(\"home\");")"
DEST_SITE_URL="$(wp_remote "$DEST_HOST" "$DEST_ROOT" eval "echo get_option(\"siteurl\");")"
log_verbose "  Dest home: $DEST_HOME_URL"
log_verbose "  Dest site: $DEST_SITE_URL"

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

log_verbose "Checking for WordPress multisite..."
if wp_remote "$DEST_HOST" "$DEST_ROOT" core is-installed --network >/dev/null 2>&1; then
  SEARCH_REPLACE_FLAGS+=(--network)
  log_verbose "  ✓ Multisite detected (will use --network flag for search-replace)"
else
  log_verbose "  Single-site installation"
fi

log_verbose "Checking for Redis object cache support..."
if wp_remote_has_command "$DEST_HOST" "$DEST_ROOT" redis; then
  REDIS_FLUSH_AVAILABLE=true
  log_verbose "  ✓ Redis CLI available (will flush cache after migration)"
else
  log_verbose "  Redis not available (skipping cache flush)"
fi

if $GZIP_DB && $IMPORT_DB; then
  if ! ssh_run "$DEST_HOST" "command -v gzip >/dev/null 2>&1"; then
    err "Destination server is missing gzip command.

The database dump will be compressed with gzip, but the destination cannot decompress it.

Solutions:
  1. Install gzip on destination server:
       ssh $DEST_HOST \"sudo apt-get install gzip\"  # Debian/Ubuntu
       ssh $DEST_HOST \"sudo yum install gzip\"      # RHEL/CentOS
  2. Or skip compression by adding flag:
       --no-gzip

Note: Compression reduces transfer time but requires gzip on both ends."
  fi
fi

# Discover wp-content paths
log_verbose "Discovering wp-content directories..."
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
      DEST_DB_PREFIX_BEFORE="$DEST_DB_PREFIX"
      log "Updating destination table prefix: $DEST_DB_PREFIX -> $SOURCE_DB_PREFIX"
      log_verbose "  Attempting wp config set..."
      wp_remote "$DEST_HOST" "$DEST_ROOT" config set table_prefix "$SOURCE_DB_PREFIX" --type=variable

      # Verify the update worked (wp config set has bugs with values starting with underscores)
      log_verbose "  Verifying table prefix was written correctly..."
      ACTUAL_PREFIX="$(wp_remote "$DEST_HOST" "$DEST_ROOT" db prefix 2>/dev/null || echo "")"
      if [[ "$ACTUAL_PREFIX" != "$SOURCE_DB_PREFIX" ]]; then
        log "WARNING: wp config set failed to write correct prefix (wrote '$ACTUAL_PREFIX' instead of '$SOURCE_DB_PREFIX')"
        log "Falling back to direct wp-config.php edit via sed..."
        log_verbose "  Using sed to directly edit wp-config.php..."

        # Fallback: Use sed to directly update wp-config.php on remote
        # This handles edge cases like prefixes with leading underscores that wp config set mishandles
        ssh_run "$DEST_HOST" "cd \"$DEST_ROOT\" && sed -i.bak \"s/^\(\\\$table_prefix[[:space:]]*=[[:space:]]*\)['\\\"][^'\\\"]*['\\\"];/\1'${SOURCE_DB_PREFIX}';/\" wp-config.php"

        # Verify sed worked
        ACTUAL_PREFIX="$(wp_remote "$DEST_HOST" "$DEST_ROOT" db prefix 2>/dev/null || echo "")"
        if [[ "$ACTUAL_PREFIX" == "$SOURCE_DB_PREFIX" ]]; then
          log "Table prefix updated successfully via sed"
          ssh_run "$DEST_HOST" "cd \"$DEST_ROOT\" && rm -f wp-config.php.bak"
        else
          log "ERROR: Failed to update table prefix. Manual intervention required."
          log "  Expected: $SOURCE_DB_PREFIX"
          log "  Actual: $ACTUAL_PREFIX"
          ssh_run "$DEST_HOST" "cd \"$DEST_ROOT\" && mv wp-config.php.bak wp-config.php 2>/dev/null"
          err "Cannot proceed with wrong table prefix in wp-config.php. Migration aborted.

Problem: Failed to update table prefix from '$DEST_DB_PREFIX' to '$SOURCE_DB_PREFIX'

This is a critical error because the database tables use prefix '$SOURCE_DB_PREFIX' but
wp-config.php still has '$DEST_DB_PREFIX', causing WordPress to fail.

Next steps:
  1. Manually update wp-config.php on destination:
       ssh $DEST_HOST \"vi $DEST_ROOT/wp-config.php\"
       # Change: \\\$table_prefix = '$DEST_DB_PREFIX';
       # To:     \\\$table_prefix = '$SOURCE_DB_PREFIX';
  2. Verify the update worked:
       ssh $DEST_HOST \"cd $DEST_ROOT && wp db prefix\"
       # Should output: $SOURCE_DB_PREFIX
  3. Re-run the migration script

The wp-config.php has been restored to its original state for safety."
        fi
      else
        log "Table prefix updated successfully"
      fi

      DEST_DB_PREFIX="$SOURCE_DB_PREFIX"
    fi

    if $URL_ALIGNMENT_REQUIRED; then
      if ! $SEARCH_REPLACE; then
        log "Skipping URL alignment (--no-search-replace flag set)"
        log "NOTE: Source and destination URLs differ but search-replace was skipped:"
        log "  Source:      $SOURCE_DISPLAY_URL"
        log "  Destination: $DEST_DISPLAY_URL"
      else
        log "Aligning destination URLs via wp search-replace..."
        log "Running $((${#SEARCH_REPLACE_ARGS[@]}/2)) search-replace operations"

        # Run search-replace for each old/new pair separately
        # wp search-replace only accepts ONE pair per command
        for ((i=0; i<${#SEARCH_REPLACE_ARGS[@]}; i+=2)); do
          old="${SEARCH_REPLACE_ARGS[i]}"
          new="${SEARCH_REPLACE_ARGS[i+1]}"
          log "  Replacing: $old -> $new"
          if ! wp_remote "$DEST_HOST" "$DEST_ROOT" search-replace "$old" "$new" "${SEARCH_REPLACE_FLAGS[@]}"; then
            log "  WARNING: search-replace failed for: $old -> $new"
          fi
        done

        if [[ -n "$DEST_HOME_URL" ]]; then
          log "Ensuring destination home option remains: $DEST_HOME_URL"
          wp_remote "$DEST_HOST" "$DEST_ROOT" option update home "$DEST_HOME_URL" >/dev/null
        fi
        if [[ -n "$DEST_SITE_URL" ]]; then
          log "Ensuring destination siteurl option remains: $DEST_SITE_URL"
          wp_remote "$DEST_HOST" "$DEST_ROOT" option update siteurl "$DEST_SITE_URL" >/dev/null
        fi
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

# ---------------------------------------------------------
# Detect plugins/themes (if preserving destination content)
# IMPORTANT: Must happen BEFORE backup (backup uses mv, making wp-content unavailable)
# ---------------------------------------------------------
if $PRESERVE_DEST_PLUGINS; then
  log "Detecting plugins/themes for preservation..."

  log_verbose "  Scanning destination plugins/themes..."
  # Get destination plugins/themes (before migration)
  detect_dest_plugins_push "$DEST_HOST" "$DEST_ROOT"
  detect_dest_themes_push "$DEST_HOST" "$DEST_ROOT"
  log_verbose "    Found ${#DEST_PLUGINS_BEFORE[@]} destination plugins, ${#DEST_THEMES_BEFORE[@]} themes"

  log_verbose "  Scanning source plugins/themes..."
  # Get source plugins/themes
  detect_source_plugins
  detect_source_themes
  log_verbose "    Found ${#SOURCE_PLUGINS[@]} source plugins, ${#SOURCE_THEMES[@]} themes"

  log_verbose "  Computing unique destination items (not in source)..."
  # Compute unique destination items (not in source)
  array_diff UNIQUE_DEST_PLUGINS DEST_PLUGINS_BEFORE[@] SOURCE_PLUGINS[@]
  array_diff UNIQUE_DEST_THEMES DEST_THEMES_BEFORE[@] SOURCE_THEMES[@]

  if ! $DRY_RUN; then
    log "  Destination has ${#DEST_PLUGINS_BEFORE[@]} plugin(s), source has ${#SOURCE_PLUGINS[@]} plugin(s)"
    log "  Unique to destination: ${#UNIQUE_DEST_PLUGINS[@]} plugin(s)"

    log "  Destination has ${#DEST_THEMES_BEFORE[@]} theme(s), source has ${#SOURCE_THEMES[@]} theme(s)"
    log "  Unique to destination: ${#UNIQUE_DEST_THEMES[@]} theme(s)"

    if [[ ${#UNIQUE_DEST_PLUGINS[@]} -gt 0 ]]; then
      log "  Plugins to preserve: ${UNIQUE_DEST_PLUGINS[*]}"
    fi

    if [[ ${#UNIQUE_DEST_THEMES[@]} -gt 0 ]]; then
      log "  Themes to preserve: ${UNIQUE_DEST_THEMES[*]}"
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
log_verbose "Building rsync options..."
RS_OPTS=( -a -h -z --info=stats2 --partial --links --prune-empty-dirs --no-perms --no-owner --no-group )
# Add progress indicator for real runs (shows current file being transferred)
if $DRY_RUN; then
  RS_OPTS+=( -n --itemize-changes )
  log_verbose "  Dry-run mode: added -n --itemize-changes"
else
  RS_OPTS+=( --info=progress2 )
  log_verbose "  Live mode: added --info=progress2"
fi

# Exclude object-cache.php drop-in to prevent caching infrastructure incompatibility
# Use root-anchored path (/) to only exclude wp-content/object-cache.php, not plugin files
RS_OPTS+=( --exclude=/object-cache.php )
log "Excluding object-cache.php drop-in from transfer (preserves destination caching setup)"

# Extra rsync opts
if [[ ${#EXTRA_RSYNC_OPTS[@]} -gt 0 ]]; then
  RS_OPTS+=( "${EXTRA_RSYNC_OPTS[@]}" )
  log_verbose "  Added ${#EXTRA_RSYNC_OPTS[@]} custom rsync option(s): ${EXTRA_RSYNC_OPTS[*]}"
fi

log "Rsync options: ${RS_OPTS[*]}"

# -------------------------
# Transfer wp-content (push)
# -------------------------
log "Pushing $SRC_WP_CONTENT -> $DEST_HOST:$DST_WP_CONTENT"
ssh_cmd_content="$(ssh_cmd_string)"
log_trace "rsync ${RS_OPTS[*]} -e \"$ssh_cmd_content\" $SRC_WP_CONTENT/ $DEST_HOST:$DST_WP_CONTENT/"
rsync "${RS_OPTS[@]}" -e "$ssh_cmd_content" \
  "$SRC_WP_CONTENT"/ \
  "$DEST_HOST":"$DST_WP_CONTENT"/ | tee -a "$LOG_FILE"

# Restore unique destination plugins/themes (if preserving)
if $PRESERVE_DEST_PLUGINS && [[ -n "$DST_WP_CONTENT_BACKUP" ]]; then
  restore_dest_content_push "$DEST_HOST" "$DEST_ROOT" "$DST_WP_CONTENT_BACKUP"
fi

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

    # Add prefix rollback note if we changed it
    if [[ -n "$DEST_DB_PREFIX_BEFORE" ]]; then
      log ""
      log "NOTE: If restoring database from backup, also restore table prefix:"
      log "  ssh $DEST_HOST \"cd '$DEST_ROOT' && wp config set table_prefix '$DEST_DB_PREFIX_BEFORE' --type=variable\""
    fi

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
      log_warning "Failed to flush Object Cache Pro cache via wp redis flush. Cache may be stale."
    fi
  else
    log "Skipping Object Cache Pro cache flush; wp redis command not available."
  fi
fi

# End of push mode workflow
fi

# ==================================================================================
# ARCHIVE MODE WORKFLOW
# ==================================================================================
if [[ "$MIGRATION_MODE" == "archive" ]]; then

log "Archive: $ARCHIVE_FILE"

# Phase 0: Capture destination URLs BEFORE any operations
log "Capturing current destination URLs..."
ORIGINAL_DEST_HOME_URL="$(wp_local option get home)"
ORIGINAL_DEST_SITE_URL="$(wp_local option get siteurl)"
log "Current site home: $ORIGINAL_DEST_HOME_URL"
log "Current site URL: $ORIGINAL_DEST_SITE_URL"

# Phase 1: Disk space check
check_disk_space_for_archive "$ARCHIVE_FILE"

# Phase 2: Extract archive
extract_archive_to_temp "$ARCHIVE_FILE"

# Phase 3: Discover database and wp-content
find_archive_database_file "$ARCHIVE_EXTRACT_DIR"
find_archive_wp_content_dir "$ARCHIVE_EXTRACT_DIR"

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
  log "[dry-run] Would backup current database to: db-backups/pre-archive-backup_${STAMP}.sql.gz"
else
  mkdir -p "db-backups"
  BACKUP_DB_FILE="db-backups/pre-archive-backup_${STAMP}.sql.gz"
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
  log_trace "cp -a \"$DEST_WP_CONTENT\" \"$DEST_WP_CONTENT_BACKUP\""
  cp -a "$DEST_WP_CONTENT" "$DEST_WP_CONTENT_BACKUP"
  log "wp-content backup created: $DEST_WP_CONTENT_BACKUP"
fi

# Phase 6b: Detect plugins/themes (if preserving destination content)
if $PRESERVE_DEST_PLUGINS; then
  log "Detecting plugins/themes for preservation..."

  log_verbose "  Scanning destination plugins/themes..."
  # Get destination plugins/themes (before migration)
  detect_dest_plugins_local
  detect_dest_themes_local
  log_verbose "    Found ${#DEST_PLUGINS_BEFORE[@]} destination plugins, ${#DEST_THEMES_BEFORE[@]} themes"

  log_verbose "  Scanning archive plugins/themes..."
  # Get archive plugins/themes
  detect_archive_plugins "$ARCHIVE_WP_CONTENT"
  detect_archive_themes "$ARCHIVE_WP_CONTENT"
  log_verbose "    Found ${#SOURCE_PLUGINS[@]} archive plugins, ${#SOURCE_THEMES[@]} themes"

  log_verbose "  Computing unique destination items (not in archive)..."
  # Compute unique destination items (not in source/archive)
  array_diff UNIQUE_DEST_PLUGINS DEST_PLUGINS_BEFORE[@] SOURCE_PLUGINS[@]
  array_diff UNIQUE_DEST_THEMES DEST_THEMES_BEFORE[@] SOURCE_THEMES[@]

  if ! $DRY_RUN; then
    log "  Destination has ${#DEST_PLUGINS_BEFORE[@]} plugin(s), archive has ${#SOURCE_PLUGINS[@]} plugin(s)"
    log "  Unique to destination: ${#UNIQUE_DEST_PLUGINS[@]} plugin(s)"

    log "  Destination has ${#DEST_THEMES_BEFORE[@]} theme(s), archive has ${#SOURCE_THEMES[@]} theme(s)"
    log "  Unique to destination: ${#UNIQUE_DEST_THEMES[@]} theme(s)"

    if [[ ${#UNIQUE_DEST_PLUGINS[@]} -gt 0 ]]; then
      log "  Plugins to preserve: ${UNIQUE_DEST_PLUGINS[*]}"
    fi

    if [[ ${#UNIQUE_DEST_THEMES[@]} -gt 0 ]]; then
      log "  Themes to preserve: ${UNIQUE_DEST_THEMES[*]}"
    fi
  fi
fi

# Phase 7: Import database
if $DRY_RUN; then
  log "[dry-run] Would reset database to clean state"
  log "[dry-run] Would import database from: $(basename "$ARCHIVE_DB_FILE")"
  log "[dry-run] Would detect and align table prefix if needed"
else
  log "Importing database from: $(basename "$ARCHIVE_DB_FILE")"

  # Get current destination prefix before import
  DEST_DB_PREFIX_BEFORE="$(wp_local db prefix)"
  log "Current wp-config.php table prefix: $DEST_DB_PREFIX_BEFORE"

  # Reset database to clean state to prevent duplicate key errors
  log "Resetting database to clean state..."

  # Count tables before reset
  tables_before=$(wp_local db query "SHOW TABLES" --skip-column-names 2>/dev/null | wc -l)
  log "  Tables before reset: $tables_before"

  # Attempt reset - allow failure without aborting script (set -e)
  # Run command and capture exit code before set -e can abort
  wp_local db reset --yes 2>&1 | tee -a "$LOG_FILE" || reset_exit_code=$?

  # If not set (command succeeded), set to 0
  : "${reset_exit_code:=0}"

  if [[ $reset_exit_code -ne 0 ]]; then
    log "WARNING: wp db reset command failed (exit code: $reset_exit_code)"
    log "This may indicate WP-CLI issues or permissions problems"
    log "Will attempt manual table drop..."
  fi

  # Verify reset actually worked by checking table count
  # This catches both: command failures AND silent failures where command succeeds but tables remain
  tables_after=$(wp_local db query "SHOW TABLES" --skip-column-names 2>/dev/null | wc -l)
  log "  Tables after reset: $tables_after"

  if [[ $tables_after -gt 0 ]]; then
    log "Database reset incomplete - $tables_after tables still exist"
    log "Attempting manual table drop..."

    # Manual fallback: Get list of tables and drop each one
    # Use process substitution to avoid subshell issues with while-read
    while IFS= read -r table; do
      if [[ -n "$table" ]]; then
        log "  Dropping table: $table"
        wp_local db query "DROP TABLE IF EXISTS \`$table\`" 2>/dev/null || {
          log "    WARNING: Could not drop $table"
        }
      fi
    done < <(wp_local db query "SHOW TABLES" --skip-column-names 2>/dev/null)

    # Verify again
    tables_final=$(wp_local db query "SHOW TABLES" --skip-column-names 2>/dev/null | wc -l)
    if [[ $tables_final -gt 0 ]]; then
      log "ERROR: Could not reset database. $tables_final tables remain."
      log "Please manually reset the database or check database permissions."
      exit 1
    fi
    log "Manual table drop successful"
  fi

  log "Database reset complete (all tables dropped)"

  # Import the database
  wp_local db import "$ARCHIVE_DB_FILE"
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

      # Verify the update worked (wp config set has bugs with values starting with underscores)
      ACTUAL_PREFIX="$(wp_local db prefix 2>/dev/null || echo "")"
      if [[ "$ACTUAL_PREFIX" != "$IMPORTED_DB_PREFIX" ]]; then
        log "WARNING: wp config set failed to write correct prefix (wrote '$ACTUAL_PREFIX' instead of '$IMPORTED_DB_PREFIX')"
        log "Falling back to direct wp-config.php edit via sed..."

        # Fallback: Use sed to directly update wp-config.php
        # This handles edge cases like prefixes with leading underscores that wp config set mishandles
        if sed -i.bak "s/^\(\$table_prefix[[:space:]]*=[[:space:]]*\)['\"][^'\"]*['\"];/\1'${IMPORTED_DB_PREFIX}';/" wp-config.php; then
          # Verify sed worked
          ACTUAL_PREFIX="$(wp_local db prefix 2>/dev/null || echo "")"
          if [[ "$ACTUAL_PREFIX" == "$IMPORTED_DB_PREFIX" ]]; then
            log "Table prefix updated successfully via sed"
            rm -f wp-config.php.bak
          else
            log "ERROR: Failed to update table prefix. Manual intervention required."
            log "  Expected: $IMPORTED_DB_PREFIX"
            log "  Actual: $ACTUAL_PREFIX"
            mv wp-config.php.bak wp-config.php 2>/dev/null
            err "Cannot proceed with wrong table prefix in wp-config.php. Migration aborted.

Problem: Failed to update table prefix to '$IMPORTED_DB_PREFIX'

This is a critical error because the imported database tables use prefix '$IMPORTED_DB_PREFIX' but
wp-config.php has a different prefix, causing WordPress to fail.

Next steps:
  1. Manually update wp-config.php:
       vi $PWD/wp-config.php
       # Change \\\$table_prefix line to: \\\$table_prefix = '$IMPORTED_DB_PREFIX';
  2. Verify the update worked:
       wp db prefix
       # Should output: $IMPORTED_DB_PREFIX
  3. Re-run the archive import

The wp-config.php has been restored to its original state for safety."
          fi
        else
          log "ERROR: sed command failed to update wp-config.php"
          err "Cannot proceed with wrong table prefix in wp-config.php. Migration aborted.

Problem: sed command failed to update wp-config.php

This usually happens due to:
  • File permissions (wp-config.php not writable)
  • Unusual table_prefix line format in wp-config.php
  • SELinux or other security restrictions

Next steps:
  1. Check wp-config.php permissions:
       ls -la $PWD/wp-config.php
  2. Manually update the table prefix:
       vi $PWD/wp-config.php
       # Find line: \\\$table_prefix = 'something';
       # Change to: \\\$table_prefix = '$IMPORTED_DB_PREFIX';
  3. Verify the change:
       wp db prefix
  4. Re-run the archive import"
        fi
      else
        log "Table prefix updated successfully"
      fi
    else
      log "Table prefix matches wp-config.php; no update needed"
    fi
  else
    log "Could not detect table prefix by scanning tables; assuming it matches wp-config.php: $DEST_DB_PREFIX_BEFORE"
    IMPORTED_DB_PREFIX="$DEST_DB_PREFIX_BEFORE"

    # Verify the assumption by trying to read from options table
    if ! wp_local db query "SELECT COUNT(*) FROM \`${IMPORTED_DB_PREFIX}options\`" --skip-column-names >/dev/null 2>&1; then
      err "Table prefix detection failed and assumption was incorrect.

Assumed prefix: $DEST_DB_PREFIX_BEFORE
Could not find table: ${DEST_DB_PREFIX_BEFORE}options

The imported database appears to be corrupt, incomplete, or uses a non-standard structure.

Next steps:
  1. Check what tables were actually imported:
       wp db query \"SHOW TABLES\"
  2. Look for core WordPress tables (options, posts, users):
       wp db query \"SHOW TABLES\" | grep -E '(options|posts|users)'
  3. If tables exist with different prefix, note the prefix and update wp-config.php:
       # Example: if you see 'custom_prefix_options' instead of 'wp_options'
       vi wp-config.php
       # Set: \\\$table_prefix = 'custom_prefix_';
  4. Verify this is a complete WordPress database backup:
       # Check archive contents or contact backup plugin support
  5. If database import was interrupted, restore backup and retry:
       wp db import <(gunzip -c db-backups/pre-archive-backup_*.sql.gz)"
    fi

    log "Verified: ${IMPORTED_DB_PREFIX}options table is accessible"
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
    if ! $SEARCH_REPLACE; then
      log "Skipping URL alignment (--no-search-replace flag set)"
      log "NOTE: Imported and destination URLs differ but search-replace was skipped:"
      log "  Imported home_url:    $IMPORTED_HOME_URL"
      log "  Destination home_url: $ORIGINAL_DEST_HOME_URL"
      log "  Imported site_url:    $IMPORTED_SITE_URL"
      log "  Destination site_url: $ORIGINAL_DEST_SITE_URL"
    else
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
      log_verbose "Checking for WordPress multisite..."
      if wp_local core is-installed --network >/dev/null 2>&1; then
        SEARCH_REPLACE_FLAGS+=(--network)
        log_verbose "  ✓ Multisite detected (will use --network flag for search-replace)"
      else
        log_verbose "  Single-site installation"
      fi

      # Perform search-replace
      log "Running $((${#SEARCH_REPLACE_ARGS[@]}/2)) search-replace operations..."

      # Run search-replace for each old/new pair separately
      # wp search-replace only accepts ONE pair per command
      for ((i=0; i<${#SEARCH_REPLACE_ARGS[@]}; i+=2)); do
        old="${SEARCH_REPLACE_ARGS[i]}"
        new="${SEARCH_REPLACE_ARGS[i+1]}"
        log "  Replacing: $old -> $new"
        if ! wp_local search-replace "$old" "$new" "${SEARCH_REPLACE_FLAGS[@]}"; then
          log "  WARNING: search-replace failed for: $old -> $new"
        fi
      done

      # Ensure destination URLs are set correctly
      log "Ensuring destination URLs are set correctly..."
      wp_local option update home "$ORIGINAL_DEST_HOME_URL" >/dev/null
      wp_local option update siteurl "$ORIGINAL_DEST_SITE_URL" >/dev/null
    fi
  else
    log "Imported URLs match destination URLs; no replacement needed."
  fi
fi

# Phase 9: Replace wp-content
if $DRY_RUN; then
  log "[dry-run] Would replace wp-content with archive contents"
  log "[dry-run]   Source: $ARCHIVE_WP_CONTENT"
  log "[dry-run]   Destination: $DEST_WP_CONTENT"
  log "[dry-run] Would exclude object-cache.php from archive (preserves destination caching setup)"
else
  log "Replacing wp-content with archive contents..."
  log "  Source: ${ARCHIVE_WP_CONTENT#"$ARCHIVE_EXTRACT_DIR"/}"
  log "  Destination: $DEST_WP_CONTENT"

  # Build rsync command with appropriate options
  # Always use --delete to ensure destination matches archive (removes stale files)
  log_verbose "Building rsync options for archive sync..."
  RSYNC_OPTS=(-a --delete)
  log_verbose "  Base options: -a --delete"

  # Use root-anchored exclusions (leading /) to only match files at wp-content root
  # Without /, rsync would exclude these filenames at ANY depth (e.g., plugins/foo/object-cache.php)
  RSYNC_EXCLUDES=(--exclude=/object-cache.php)
  log_verbose "  Excluding: object-cache.php (preserves destination caching)"

  if $STELLARSITES_MODE; then
    # StellarSites mode: Exclude mu-plugins directory AND loader file (both at root)
    # Managed hosts ship mu-plugins.php to bootstrap their protected mu-plugins
    # Must exclude both the directory and the loader, or --delete will remove the loader
    RSYNC_EXCLUDES+=(--exclude=/mu-plugins/ --exclude=/mu-plugins.php)
    log "StellarSites mode: Preserving destination mu-plugins directory and loader"
    log_verbose "  Excluding: mu-plugins/ mu-plugins.php (StellarSites protected files)"
  fi

  # Sync wp-content from archive to destination
  # Excluded items (mu-plugins, object-cache.php) are preserved in destination
  log_trace "rsync ${RSYNC_OPTS[*]} ${RSYNC_EXCLUDES[*]} $ARCHIVE_WP_CONTENT/ $DEST_WP_CONTENT/"
  rsync "${RSYNC_OPTS[@]}" "${RSYNC_EXCLUDES[@]}" \
    "$ARCHIVE_WP_CONTENT/" "$DEST_WP_CONTENT/" | tee -a "$LOG_FILE"

  log "wp-content synced successfully (object-cache.php excluded to preserve destination caching)"

  # Restore unique destination plugins/themes (if preserving)
  if $PRESERVE_DEST_PLUGINS; then
    restore_dest_content_local "$DEST_WP_CONTENT_BACKUP"
  fi
fi

# Phase 10: Flush cache if available
log_verbose "Checking for Redis object cache support..."
if wp_local cli has-command redis >/dev/null 2>&1; then
  log_verbose "  ✓ Redis CLI available (flushing cache)"
  if $DRY_RUN; then
    log "[dry-run] Would flush Object Cache Pro cache via: wp redis flush"
  else
    log "Flushing Object Cache Pro cache..."
    if ! wp_local redis flush; then
      log_warning "Failed to flush Object Cache Pro cache via wp redis flush. Cache may be stale."
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
  log "[dry-run] Archive import preview complete."
else
  log "Archive import complete."
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

  # Add prefix rollback instruction if we changed it
  if [[ -n "$IMPORTED_DB_PREFIX" && "$IMPORTED_DB_PREFIX" != "$DEST_DB_PREFIX_BEFORE" ]]; then
    log ""
    log "3. Restore table prefix in wp-config.php:"
    log "   wp config set table_prefix \"$DEST_DB_PREFIX_BEFORE\" --type=variable"
  fi

  log ""
  log "Backups created:"
  log "  Database: $BACKUP_DB_FILE"
  log "  wp-content: $DEST_WP_CONTENT_BACKUP"
  log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  log ""
fi

# End of archive mode workflow
fi
