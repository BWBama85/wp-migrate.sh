# -------------
# Parse args
# -------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dest-host) DEST_HOST="${2:-}"; shift 2 ;;
    --dest-root) DEST_ROOT="${2:-}"; shift 2 ;;
    --archive) ARCHIVE_FILE="${2:-}"; shift 2 ;;
    --archive-type) ARCHIVE_TYPE="${2:-}"; shift 2 ;;
    --create-backup) CREATE_BACKUP=true; shift ;;
    --duplicator-archive)
      # Backward compatibility: treat as --archive with duplicator type
      ARCHIVE_FILE="${2:-}"
      ARCHIVE_TYPE="duplicator"
      shift 2
      ;;
    --dry-run) DRY_RUN=true; shift ;;
    --quiet) QUIET_MODE=true; shift ;;
    --yes) YES_MODE=true; shift ;;
    --rollback) ROLLBACK_MODE=true; shift ;;
    --rollback-backup) ROLLBACK_BACKUP_PATH="${2:-}"; shift 2 ;;
    --verbose) VERBOSE=true; shift ;;
    --trace) TRACE_MODE=true; VERBOSE=true; shift ;;
    --import-db) IMPORT_DB=true; shift ;;
    --no-import-db) IMPORT_DB=false; shift ;;
    --no-search-replace) SEARCH_REPLACE=false; shift ;;
    --no-gzip) GZIP_DB=false; shift ;;
    --no-maint-source) MAINTENANCE_SOURCE=false; shift ;;
    --stellarsites) STELLARSITES_MODE=true; PRESERVE_DEST_PLUGINS=true; shift ;;
    --preserve-dest-plugins) PRESERVE_DEST_PLUGINS=true; shift ;;
    --source-host) SOURCE_HOST="${2:-}"; shift 2 ;;
    --source-root) SOURCE_ROOT="${2:-}"; shift 2 ;;
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

if $ROLLBACK_MODE; then
  MIGRATION_MODE="rollback"
  log "Rollback mode enabled"

  # Rollback mode requires running from WordPress root
  [[ -f "./wp-config.php" ]] || err "WordPress installation not detected. wp-config.php not found in current directory.

Current directory: $PWD

Rollback mode must be run from the WordPress root directory.

Next steps:
  1. Navigate to your WordPress root: cd /var/www/html
  2. Verify wp-config.php exists: ls -la wp-config.php
  3. Run rollback again from the correct directory"

elif $CREATE_BACKUP; then
  # Backup mode is mutually exclusive with archive mode
  if [[ -n "$ARCHIVE_FILE" ]]; then
    err "--create-backup is mutually exclusive with --archive

You cannot create a backup and import one simultaneously.

Choose one:
  • Create backup: ./wp-migrate.sh --create-backup
  • Import backup: ./wp-migrate.sh --archive /path/to/backup.zip"
  fi

  # Detect local vs remote backup mode based on --source-host presence
  if [[ -z "$SOURCE_HOST" ]]; then
    # Local backup mode
    MIGRATION_MODE="backup-local"
    log "Local backup mode enabled"

    # Default to current directory if --source-root not specified
    if [[ -z "$SOURCE_ROOT" ]]; then
      SOURCE_ROOT="$(pwd)"
    else
      # Convert to absolute path
      SOURCE_ROOT="$(cd "$SOURCE_ROOT" 2>/dev/null && pwd)" || err "Invalid path: $SOURCE_ROOT

The specified --source-root does not exist or is not accessible."
    fi

    # Local backup is mutually exclusive with --dest-host
    if [[ -n "$DEST_HOST" ]]; then
      err "--create-backup (local mode) is mutually exclusive with --dest-host

You cannot create a local backup and push to destination simultaneously.

Choose one:
  • Create local backup: ./wp-migrate.sh --create-backup
  • Push migration: ./wp-migrate.sh --dest-host ... --dest-root ..."
    fi

  else
    # Remote backup mode
    MIGRATION_MODE="backup-remote"
    log "Remote backup mode enabled"

    # Both --source-host and --source-root required for remote mode
    [[ -n "$SOURCE_ROOT" ]] || err "--create-backup with --source-host requires --source-root

Example:
  ./wp-migrate.sh --source-host user@source.example.com \\
                  --source-root /var/www/html \\
                  --create-backup"

    # Remote backup is mutually exclusive with --dest-host
    if [[ -n "$DEST_HOST" ]]; then
      err "--create-backup (remote mode) is mutually exclusive with --dest-host

You cannot create a backup and push to destination simultaneously.

Choose one:
  • Create remote backup: ./wp-migrate.sh --source-host ... --create-backup
  • Push migration: ./wp-migrate.sh --dest-host ... --dest-root ..."
    fi
  fi

elif [[ -n "$ARCHIVE_FILE" ]]; then
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
       --archive-type duplicator           # For Duplicator Pro/Lite backups
       --archive-type jetpack              # For Jetpack Backup archives
       --archive-type solidbackups         # For Solid Backups Legacy (BackupBuddy)
       --archive-type solidbackups_nextgen # For Solid Backups NextGen
  3. Or remove --archive-type to auto-detect format"
    fi
    ARCHIVE_ADAPTER="$ARCHIVE_TYPE"
  else
    # Auto-detect adapter from archive
    # Reset validation errors before detection
    ADAPTER_VALIDATION_ERRORS=()
    ARCHIVE_ADAPTER=$(detect_adapter "$ARCHIVE_FILE")
    if [[ -z "$ARCHIVE_ADAPTER" ]]; then
      # Build detailed error message with validation failures
      detailed_errors=""
      if [[ ${#ADAPTER_VALIDATION_ERRORS[@]} -gt 0 ]]; then
        detailed_errors="

Validation failures:"
        for error in "${ADAPTER_VALIDATION_ERRORS[@]}"; do
          detailed_errors+="
  ✗ $error"
        done
      fi

      err "Unable to auto-detect archive format for: $ARCHIVE_FILE

The archive doesn't match any known backup plugin format.${detailed_errors}

Supported formats:
  • Duplicator Pro/Lite (.zip with installer.php)
  • Jetpack Backup (.tar.gz or .zip with sql/ directory)
  • Solid Backups Legacy (.zip with backupbuddy_temp/ directory)
  • Solid Backups NextGen (.zip with data/ and files/ directories)

Next steps:
  1. Verify this is a valid WordPress backup archive:
       file \"$ARCHIVE_FILE\"
  2. Check which backup plugin created this archive
  3. Try specifying the format explicitly:
       --archive \"$ARCHIVE_FILE\" --archive-type duplicator
       --archive \"$ARCHIVE_FILE\" --archive-type jetpack
       --archive \"$ARCHIVE_FILE\" --archive-type solidbackups
       --archive \"$ARCHIVE_FILE\" --archive-type solidbackups_nextgen
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
# Only check for local wp-config.php in modes that operate on local WordPress
if [[ "$MIGRATION_MODE" == "push" || "$MIGRATION_MODE" == "archive" ]]; then
  [[ -f "./wp-config.php" ]] || err "WordPress installation not detected. wp-config.php not found in current directory.

Current directory: $PWD

Next steps:
  1. Verify you're in the WordPress root directory:
       ls -la wp-config.php
  2. If wp-config.php exists elsewhere, cd to that directory first
  3. For push mode: Run from SOURCE WordPress root
  4. For archive mode: Run from DESTINATION WordPress root"
fi

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

# Only check for wp-cli in modes that operate on local WordPress
if [[ "$MIGRATION_MODE" == "push" || "$MIGRATION_MODE" == "archive" ]]; then
  needs wp
fi

if [[ "$MIGRATION_MODE" == "push" ]]; then
  needs rsync
  needs ssh
  needs gzip
elif [[ "$MIGRATION_MODE" == "archive" ]]; then
  # Check adapter-specific dependencies
  check_adapter_dependencies "$ARCHIVE_ADAPTER"
elif [[ "$MIGRATION_MODE" == "backup-remote" ]]; then
  needs ssh
elif [[ "$MIGRATION_MODE" == "backup-local" ]]; then
  # Local backup mode has no SSH dependency
  :
fi

STAMP="$(date +%Y%m%d-%H%M%S)"
if $DRY_RUN; then
  LOG_FILE="/dev/null"
  if [[ "$MIGRATION_MODE" == "push" ]]; then
    log "Starting push migration (dry-run preview; no log file will be written)."
  elif [[ "$MIGRATION_MODE" == "backup-local" ]]; then
    log "Starting local backup creation (dry-run preview; no log file will be written)."
  elif [[ "$MIGRATION_MODE" == "backup-remote" ]]; then
    log "Starting remote backup creation (dry-run preview; no log file will be written)."
  else
    log "Starting archive import (dry-run preview; no log file will be written)."
  fi
else
  mkdir -p "$LOG_DIR"

  # SAFETY: Rotate old log files to prevent indefinite growth (Issue #88-9)
  # Keep only the most recent 20 log files, delete older ones
  # This prevents the logs directory from consuming excessive disk space over time
  if [[ -d "$LOG_DIR" ]]; then
    # Count existing log files
    log_count=$(find "$LOG_DIR" -type f -name "migrate-*.log" 2>/dev/null | wc -l)

    # Only rotate if we have more than 20 logs
    if [[ $log_count -gt 20 ]]; then
      # Delete all but the 20 most recent log files (sort by modification time)
      find "$LOG_DIR" -type f -name "migrate-*.log" -print0 2>/dev/null | \
        xargs -0 ls -t 2>/dev/null | \
        tail -n +21 | \
        xargs rm -f 2>/dev/null || true
    fi
  fi

  if [[ "$MIGRATION_MODE" == "push" ]]; then
    LOG_FILE="$LOG_DIR/migrate-wpcontent-push-$STAMP.log"
    log "Starting push migration. Log: $LOG_FILE"
  elif [[ "$MIGRATION_MODE" == "backup-local" ]]; then
    LOG_FILE="$LOG_DIR/migrate-backup-local-$STAMP.log"
    log "Starting local backup creation. Log: $LOG_FILE"
  elif [[ "$MIGRATION_MODE" == "backup-remote" ]]; then
    LOG_FILE="$LOG_DIR/migrate-backup-remote-$STAMP.log"
    log "Starting remote backup creation. Log: $LOG_FILE"
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

# SAFETY: Validate wp-content paths before use (Issue #122)
if [[ -z "$SRC_WP_CONTENT" ]]; then
  err "Failed to discover source wp-content directory

WP-CLI did not return a valid wp-content path. Possible causes:
  - WordPress not properly installed
  - WP-CLI not found or misconfigured
  - Custom WordPress directory structure
  - PHP errors preventing WP-CLI execution

Try running manually:
  wp eval 'echo WP_CONTENT_DIR;'

If this fails, verify WordPress installation is functional."
fi

if [[ ! -d "$SRC_WP_CONTENT" ]]; then
  err "Source wp-content path is not a directory: $SRC_WP_CONTENT

Path discovered but does not exist or is not a directory.

Check filesystem:
  ls -ld \"$SRC_WP_CONTENT\" 2>&1"
fi

if [[ -z "$DST_WP_CONTENT" ]]; then
  err "Failed to discover destination wp-content directory

WP-CLI did not return a valid wp-content path on remote host. Possible causes:
  - WordPress not properly installed on destination
  - WP-CLI not found or misconfigured on destination
  - Custom WordPress directory structure
  - PHP errors preventing WP-CLI execution

Try running manually:
  ssh $DEST_HOST 'cd $DEST_ROOT && wp eval \"echo WP_CONTENT_DIR;\"'

If this fails, verify WordPress installation on destination is functional."
fi

# Validate destination wp-content exists and is writable (remote checks via SSH)
if ! ssh_run "$DEST_HOST" "test -d \"$DST_WP_CONTENT\""; then
  err "Destination wp-content path is not a directory: $DST_WP_CONTENT

Path discovered but does not exist or is not a directory on remote host.

Check filesystem:
  ssh $DEST_HOST \"ls -ld '$DST_WP_CONTENT'\" 2>&1"
fi

if ! ssh_run "$DEST_HOST" "test -w \"$DST_WP_CONTENT\""; then
  err "Destination wp-content directory is not writable: $DST_WP_CONTENT

Migration requires write access to wp-content directory on destination.

Check permissions:
  ssh $DEST_HOST \"ls -ld '$DST_WP_CONTENT'\"

Fix permissions (if appropriate):
  ssh $DEST_HOST \"sudo chown -R \\\$(whoami) '$DST_WP_CONTENT'\"
  # or
  ssh $DEST_HOST \"sudo chmod -R u+w '$DST_WP_CONTENT'\""
fi

# Size check (approx)
SRC_SIZE=$(du -sh "$SRC_WP_CONTENT" 2>/dev/null | cut -f1 || echo "unknown")
DST_FREE=$(ssh_run "$DEST_HOST" "df -h \"$DST_WP_CONTENT\" | awk 'NR==2{print \$4}'" || echo "unknown")
log "Approx source wp-content size: $SRC_SIZE"
log "Approx destination free space: $DST_FREE"

# ---------------------------------------------------------
# Detect plugins/themes for preservation (before preview)
# IMPORTANT: Must happen BEFORE preview so we can show accurate operations list
# ---------------------------------------------------------
if $PRESERVE_DEST_PLUGINS; then
  log "Detecting plugins/themes for preservation..."

  log_verbose "  Scanning destination plugins/themes..."
  # Get destination plugins/themes (before migration)
  detect_dest_plugins_push "$DEST_HOST" "$DEST_ROOT"
  detect_dest_themes_push "$DEST_HOST" "$DEST_ROOT"

  # Log filtered plugins
  if [[ ${#FILTERED_DROPINS[@]} -gt 0 ]]; then
    log "Filtered drop-ins from preservation: ${FILTERED_DROPINS[*]}"
  fi

  if [[ ${#FILTERED_MANAGED_PLUGINS[@]} -gt 0 ]]; then
    log "Filtered managed plugins from preservation: ${FILTERED_MANAGED_PLUGINS[*]}"
  fi

  log_verbose "    Found ${#DEST_PLUGINS_BEFORE[@]} destination plugins, ${#DEST_THEMES_BEFORE[@]} themes"

  log_verbose "  Scanning source plugins/themes..."
  # Get source plugins/themes
  detect_source_plugins
  detect_source_themes
  log_verbose "    Found ${#SOURCE_PLUGINS[@]} source plugins, ${#SOURCE_THEMES[@]} themes"

  log_verbose "  Computing unique destination items (not in source)..."
  # Compute unique destination items (not in source)
  array_diff UNIQUE_DEST_PLUGINS DEST_PLUGINS_BEFORE SOURCE_PLUGINS
  array_diff UNIQUE_DEST_THEMES DEST_THEMES_BEFORE SOURCE_THEMES

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

# Migration preview and confirmation
show_migration_preview

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
      if ! $SEARCH_REPLACE; then
        log "[dry-run] Would skip bulk search-replace (--no-search-replace flag set)"
        log "[dry-run] Would update home and siteurl options only to destination URLs"
        log "[dry-run] WARNING: Other URLs in content/metadata would remain unchanged"
      else
        for ((idx=0; idx<${#SEARCH_REPLACE_ARGS[@]}; idx+=2)); do
          log "[dry-run] Would run wp search-replace '${SEARCH_REPLACE_ARGS[idx]}' '${SEARCH_REPLACE_ARGS[idx+1]}' on destination."
        done
      fi
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

  # Build rsync options with version-compatible flags
  db_rsync_opts=(-ah --partial)
  db_stats_opt=$(get_rsync_stats_opts)
  db_progress_opt=$(get_rsync_progress_opts)
  [[ -n "$db_stats_opt" ]] && db_rsync_opts+=("$db_stats_opt")
  [[ -n "$db_progress_opt" ]] && db_rsync_opts+=("$db_progress_opt")

  rsync "${db_rsync_opts[@]}" -e "$ssh_cmd_db" \
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
        log "Skipping bulk search-replace (--no-search-replace flag set)"
        log "Setting home and siteurl options only..."

        if [[ -n "$DEST_HOME_URL" ]]; then
          wp_remote "$DEST_HOST" "$DEST_ROOT" option update home "$DEST_HOME_URL" >/dev/null
        fi
        if [[ -n "$DEST_SITE_URL" ]]; then
          wp_remote "$DEST_HOST" "$DEST_ROOT" option update siteurl "$DEST_SITE_URL" >/dev/null
        fi

        log "WARNING: Only home and siteurl options were updated to destination URLs."
        log "         Other URLs in post content, metadata, and options remain unchanged."
        log "         If needed, run manual search-replace: wp search-replace '$SOURCE_DISPLAY_URL' '$DEST_DISPLAY_URL'"
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

# -------------------------------
# Backup destination wp-content
# -------------------------------
# Note: Plugin/theme detection already happened before preview (line ~507)
DST_WP_CONTENT_BACKUP="$(backup_remote_wp_content "$DEST_HOST" "$DST_WP_CONTENT" "$STAMP")"

# ---------------------
# Build rsync options
# ---------------------
log_verbose "Building rsync options..."

# Detect rsync capabilities (macOS openrsync lacks --info= options)
rsync_stats_opt=$(get_rsync_stats_opts)
rsync_progress_opt=$(get_rsync_progress_opts)

RS_OPTS=( -a -h -z --partial --links --prune-empty-dirs --no-perms --no-owner --no-group )
if [[ -n "$rsync_stats_opt" ]]; then
  RS_OPTS+=( "$rsync_stats_opt" )
fi

# Add progress indicator for real runs (shows current file being transferred)
if $DRY_RUN; then
  RS_OPTS+=( -n --itemize-changes )
  log_verbose "  Dry-run mode: added -n --itemize-changes"
else
  RS_OPTS+=( "$rsync_progress_opt" )
  log_verbose "  Live mode: added $rsync_progress_opt"
fi

# Exclude object-cache.php drop-in to prevent caching infrastructure incompatibility
# Use root-anchored path (/) to only exclude wp-content/object-cache.php, not plugin files
RS_OPTS+=( --exclude=/object-cache.php )
log "Excluding object-cache.php drop-in from transfer (preserves destination caching setup)"

# StellarSites mode: Exclude mu-plugins directory and loader file
if $STELLARSITES_MODE; then
  # Managed hosts ship mu-plugins.php to bootstrap their protected mu-plugins
  # Must exclude both the directory and the loader, or rsync will overwrite the loader
  RS_OPTS+=(--exclude=/mu-plugins/ --exclude=/mu-plugins.php)
  log "StellarSites mode: Preserving destination mu-plugins directory and loader"
  log_verbose "  Excluding: mu-plugins/ mu-plugins.php (StellarSites protected files)"
fi

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

# Restore excluded mu-plugins from backup (StellarSites mode)
if $STELLARSITES_MODE && [[ -n "$DST_WP_CONTENT_BACKUP" ]]; then
  if $DRY_RUN; then
    log "[dry-run] Would restore mu-plugins/ and mu-plugins.php from backup"
  else
    log "Restoring excluded mu-plugins from backup..."
    log_verbose "  Copying mu-plugins/ from $DST_WP_CONTENT_BACKUP"

    # Restore mu-plugins directory if it exists in backup
    if ssh_run "$DEST_HOST" "[ -d \"$DST_WP_CONTENT_BACKUP/mu-plugins\" ]"; then
      if ssh_run "$DEST_HOST" "cp -a \"$DST_WP_CONTENT_BACKUP/mu-plugins\" \"$DST_WP_CONTENT/\""; then
        log "  Restored: mu-plugins/"
      else
        log_warning "Failed to restore mu-plugins directory from backup"
      fi
    fi

    # Restore mu-plugins.php loader if it exists in backup
    if ssh_run "$DEST_HOST" "[ -f \"$DST_WP_CONTENT_BACKUP/mu-plugins.php\" ]"; then
      if ssh_run "$DEST_HOST" "cp -a \"$DST_WP_CONTENT_BACKUP/mu-plugins.php\" \"$DST_WP_CONTENT/\""; then
        log "  Restored: mu-plugins.php"
      else
        log_warning "Failed to restore mu-plugins.php from backup"
      fi
    fi
  fi
fi

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
# ROLLBACK MODE WORKFLOW
# ==================================================================================
if [[ "$MIGRATION_MODE" == "rollback" ]]; then

log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log "ROLLBACK MODE"
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Find backups
if [[ -n "$ROLLBACK_BACKUP_PATH" ]]; then
  log "Using explicitly specified backup: $ROLLBACK_BACKUP_PATH"
  DB_BACKUP="$ROLLBACK_BACKUP_PATH"
  WP_CONTENT_BACKUP=""
else
  log "Searching for latest backups..."
  backup_info=$(find_latest_backup)

  if [[ -z "$backup_info" ]]; then
    err "No backups found.

Rollback requires backups created by wp-migrate.sh during a previous migration.

Expected backup locations:
  • Database: db-backups/pre-archive-backup_*.sql.gz
  • wp-content: wp-content.backup-*

Next steps:
  1. Verify you're in the correct WordPress root directory
  2. Check if backups exist:
       ls -la db-backups/
       ls -la wp-content.backup-*
  3. If backups were moved, specify explicitly:
       ./wp-migrate.sh --rollback --rollback-backup /path/to/backup.sql.gz"
  fi

  # Parse backup info
  IFS='|' read -r DB_BACKUP WP_CONTENT_BACKUP <<< "$backup_info"

  log "Found backups:"
  if [[ -n "$DB_BACKUP" ]]; then
    log "  Database: $DB_BACKUP"
  else
    log "  Database: None found"
  fi

  if [[ -n "$WP_CONTENT_BACKUP" ]]; then
    log "  wp-content: $WP_CONTENT_BACKUP"
  else
    log "  wp-content: None found"
  fi
fi

# Perform rollback
rollback_migration "$DB_BACKUP" "$WP_CONTENT_BACKUP"

# Done
exit 0

# ==================================================================================
# ARCHIVE MODE WORKFLOW
# ==================================================================================
elif [[ "$MIGRATION_MODE" == "archive" ]]; then

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

# Phase 3: Discover database and wp-content from archive
find_archive_database_file "$ARCHIVE_EXTRACT_DIR"
find_archive_wp_content_dir "$ARCHIVE_EXTRACT_DIR"

# Phase 3b: Discover destination wp-content path (needed for preview)
DEST_WP_CONTENT="$(discover_wp_content_local)"

# SAFETY: Validate wp-content path before use (Issue #88-6)
if [[ -z "$DEST_WP_CONTENT" ]]; then
  err "Failed to discover wp-content directory

WP-CLI did not return a valid wp-content path. Possible causes:
  - WordPress not properly installed
  - WP-CLI configuration error
  - Custom WordPress directory structure

Try running manually:
  wp eval 'echo WP_CONTENT_DIR;'

If this fails, verify WordPress installation is functional."
fi

if [[ ! -d "$DEST_WP_CONTENT" ]]; then
  err "wp-content path is not a directory: $DEST_WP_CONTENT

Path discovered but does not exist or is not a directory.

Current path: $DEST_WP_CONTENT
Check filesystem:
  ls -ld \"$DEST_WP_CONTENT\" 2>&1"
fi

if [[ ! -w "$DEST_WP_CONTENT" ]]; then
  err "wp-content directory is not writable: $DEST_WP_CONTENT

Migration requires write access to wp-content directory.

Check permissions:
  ls -ld \"$DEST_WP_CONTENT\"

Fix permissions:
  sudo chown -R \$(whoami) \"$DEST_WP_CONTENT\"
  # or
  sudo chmod -R u+w \"$DEST_WP_CONTENT\""
fi

log "Destination WP_CONTENT_DIR: $DEST_WP_CONTENT"

# Phase 3c: Detect plugins/themes for preservation (before preview)
# IMPORTANT: Must happen BEFORE preview so we can show accurate operations list
if $PRESERVE_DEST_PLUGINS; then
  log "Detecting plugins/themes for preservation..."

  log_verbose "  Scanning destination plugins/themes..."
  # Get destination plugins/themes (before migration)
  detect_dest_plugins_local
  detect_dest_themes_local

  # Log filtered plugins
  if [[ ${#FILTERED_DROPINS[@]} -gt 0 ]]; then
    log "Filtered drop-ins from preservation: ${FILTERED_DROPINS[*]}"
  fi

  if [[ ${#FILTERED_MANAGED_PLUGINS[@]} -gt 0 ]]; then
    log "Filtered managed plugins from preservation: ${FILTERED_MANAGED_PLUGINS[*]}"
  fi

  log_verbose "    Found ${#DEST_PLUGINS_BEFORE[@]} destination plugins, ${#DEST_THEMES_BEFORE[@]} themes"

  log_verbose "  Scanning archive plugins/themes..."
  # Get archive plugins/themes
  detect_archive_plugins "$ARCHIVE_WP_CONTENT"
  detect_archive_themes "$ARCHIVE_WP_CONTENT"
  log_verbose "    Found ${#SOURCE_PLUGINS[@]} archive plugins, ${#SOURCE_THEMES[@]} themes"

  log_verbose "  Computing unique destination items (not in archive)..."
  # Compute unique destination items (not in source/archive)
  array_diff UNIQUE_DEST_PLUGINS DEST_PLUGINS_BEFORE SOURCE_PLUGINS
  array_diff UNIQUE_DEST_THEMES DEST_THEMES_BEFORE SOURCE_THEMES

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

# Migration preview and confirmation
show_migration_preview

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
# Note: DEST_WP_CONTENT already discovered before preview (phase 3b)
if $DRY_RUN; then
  DEST_WP_CONTENT_BACKUP="${DEST_WP_CONTENT}.backup-${STAMP}"
  log "[dry-run] Would backup current wp-content to: $DEST_WP_CONTENT_BACKUP"
else
  DEST_WP_CONTENT_BACKUP="${DEST_WP_CONTENT}.backup-${STAMP}"
  log "Backing up current wp-content to: $DEST_WP_CONTENT_BACKUP"
  log_trace "cp -a \"$DEST_WP_CONTENT\" \"$DEST_WP_CONTENT_BACKUP\""

  # SAFETY: Verify backup succeeds before destructive operations (Issue #85)
  if ! cp -a "$DEST_WP_CONTENT" "$DEST_WP_CONTENT_BACKUP"; then
    err "Failed to backup wp-content directory. Cannot proceed safely.

The wp-content backup is critical for rollback if migration fails.
Without a valid backup, data loss is permanent.

Common causes:
  - Insufficient disk space (check: df -h)
  - Permission denied (check: ls -ld \"$(dirname "$DEST_WP_CONTENT")\")
  - I/O errors (check: dmesg | tail)
  - SELinux/AppArmor restrictions

Current disk space:
$(df -h "$DEST_WP_CONTENT" 2>/dev/null || echo "  Unable to check disk space")

Migration aborted to prevent data loss."
  fi

  # Verify backup directory actually exists
  if [[ ! -d "$DEST_WP_CONTENT_BACKUP" ]]; then
    err "Backup directory was not created: $DEST_WP_CONTENT_BACKUP

The cp command reported success but backup directory doesn't exist.
This indicates a system-level problem. Migration aborted."
  fi

  # Verify backup has content (not empty directory)
  backup_file_count=$(find "$DEST_WP_CONTENT_BACKUP" -type f 2>/dev/null | wc -l)
  if [[ $backup_file_count -eq 0 ]]; then
    log_warning "wp-content backup appears empty (0 files). This may be normal if wp-content was empty."
  fi

  log "wp-content backup created: $DEST_WP_CONTENT_BACKUP ($backup_file_count files)"
fi

# Phase 7: Import database
# Note: Plugin/theme detection already happened before preview (phase 3c)
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

  # SAFETY: Create emergency database snapshot before destructive operations
  # This provides atomicity - if import fails, we can restore from snapshot
  # The exit_cleanup() function will auto-restore on failure
  EMERGENCY_DB_SNAPSHOT="${TMPDIR:-/tmp}/wp-migrate-emergency-snapshot-${STAMP}.sql"
  log "Creating emergency database snapshot (safety backup)..."
  if ! wp_local db export "$EMERGENCY_DB_SNAPSHOT" 2>&1 | tee -a "$LOG_FILE"; then
    log_warning "Could not create emergency snapshot. Proceeding without safety backup."
    log_warning "Database reset will NOT be atomic - recovery may be manual if script crashes."
    EMERGENCY_DB_SNAPSHOT=""
  else
    log_verbose "Emergency snapshot created: $EMERGENCY_DB_SNAPSHOT"
  fi

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
        # SECURITY: Prevent shell injection by passing SQL via stdin (Issue #83)
        # printf receives table name as argument (no shell interpretation)
        # Output goes to wp_local via pipe (never through variable expansion)
        # This prevents bash from interpreting backticks, $(...), quotes, etc.
        # shellcheck disable=SC2016  # Backticks are SQL identifier quotes, not bash command substitution
        if ! printf 'DROP TABLE IF EXISTS `%s`;' "$table" | wp_local db query 2>/dev/null; then
          log "    WARNING: Could not drop $table"
        fi
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
  log "Importing database (this may take a few minutes for large databases)..."

  # SAFETY: Verify file exists before attempting file size operations (Issue #86)
  # In dry-run mode, ARCHIVE_DB_FILE may be set to non-existent placeholder path
  if [[ ! -f "$ARCHIVE_DB_FILE" ]]; then
    err "Database file not found: $ARCHIVE_DB_FILE

This should not happen in normal operation. Possible causes:
  - Archive extraction failed silently
  - File was deleted between extraction and import
  - Incorrect archive format detected

Archive directory: $(dirname "$ARCHIVE_DB_FILE")
Contents:
$(ls -la "$(dirname "$ARCHIVE_DB_FILE")" 2>&1 || echo "Unable to list directory")"
  fi

  # SAFETY: Check exit status and verify import succeeded (Issue #87-4)
  import_exit_code=0
  if ! $QUIET_MODE && has_pv && [[ -t 1 ]]; then
    # Show progress with pv
    DB_SIZE=$(stat -f%z "$ARCHIVE_DB_FILE" 2>/dev/null || stat -c%s "$ARCHIVE_DB_FILE" 2>/dev/null)
    pv -N "Database import" -s "$DB_SIZE" "$ARCHIVE_DB_FILE" | wp_local db import - || import_exit_code=$?
  else
    wp_local db import "$ARCHIVE_DB_FILE" || import_exit_code=$?
  fi

  # Check import command exit status
  if [[ $import_exit_code -ne 0 ]]; then
    err "Database import failed (exit code: $import_exit_code)

WP-CLI reported an error during import. Possible causes:
  - Corrupted SQL file
  - Invalid SQL syntax in backup
  - Database connection issues
  - Insufficient database permissions

AUTOMATIC ROLLBACK: The script will now restore your original database
from the emergency snapshot taken before migration began.

If automatic restore fails, the snapshot will be preserved at:
  $EMERGENCY_DB_SNAPSHOT"
  fi

  # Verify import actually created tables
  imported_tables=$(wp_local db query "SHOW TABLES" --skip-column-names 2>/dev/null | wc -l)
  if [[ $imported_tables -eq 0 ]]; then
    err "Database import produced no tables

Import command succeeded but database is empty. Possible causes:
  - SQL file contains no CREATE TABLE statements
  - Wrong database selected
  - SQL file is empty or corrupted

Archive database file: $ARCHIVE_DB_FILE
File size: $(stat -f%z "$ARCHIVE_DB_FILE" 2>/dev/null || stat -c%s "$ARCHIVE_DB_FILE" 2>/dev/null) bytes

AUTOMATIC ROLLBACK: The script will now restore your original database
from the emergency snapshot taken before migration began.

If automatic restore fails, the snapshot will be preserved at:
  $EMERGENCY_DB_SNAPSHOT"
  fi

  log "Database imported successfully ($imported_tables tables)"

  # SAFETY: Import succeeded - clean up emergency snapshot
  if [[ -n "$EMERGENCY_DB_SNAPSHOT" && -f "$EMERGENCY_DB_SNAPSHOT" ]]; then
    log_verbose "Cleaning up emergency snapshot (no longer needed)"
    rm -f "$EMERGENCY_DB_SNAPSHOT"
    EMERGENCY_DB_SNAPSHOT=""
  fi

  # Detect the prefix from the imported database
  # Strategy: Find a prefix that exists for ALL core WordPress tables (options, posts, users)
  # This ensures we identify the actual WordPress prefix, not plugin tables like wp_statistics_options
  IMPORTED_DB_PREFIX=""

  # Get all tables from the database
  all_tables=$(wp_local db query "SHOW TABLES" --skip-column-names 2>/dev/null)

  if [[ -n "$all_tables" ]]; then
    # Define core WordPress table suffixes that must all exist
    core_suffixes=("options" "posts" "users")

    # SAFETY: Collect ALL valid WordPress prefixes to detect multiple installations (Issue #84)
    all_valid_prefixes=()

    # Extract all potential prefixes by looking at tables ending in "options"
    # A table like "wp_options" gives prefix "wp_", "my_site_options" gives "my_site_"
    # SAFETY: Handle edge cases (Issue #87-5):
    #   - Empty prefix: "options" → ""
    #   - Leading underscores: "_wp_options" → "_wp_"
    #   - Numeric prefixes: "123_wp_options" → "123_wp_"
    while IFS= read -r table; do
      potential_prefix=""

      # Handle two patterns:
      # 1. Standard: ends with "_options" (has underscore separator)
      # 2. Empty prefix: exact match "options" (rare but valid)
      if [[ "$table" == *_options ]]; then
        # Extract the potential prefix (everything before "_options")
        potential_prefix="${table%_options}_"
      elif [[ "$table" == "options" ]]; then
        # Empty prefix case (no underscore separator)
        potential_prefix=""
      else
        # Table doesn't end in "options" - skip it
        continue
      fi

      # Verify this prefix exists for ALL core WordPress tables
      prefix_valid=true
      for suffix in "${core_suffixes[@]}"; do
        if [[ -z "$potential_prefix" ]]; then
          # Empty prefix case: look for exact table names
          expected_table="$suffix"
        else
          # Standard case: prefix + suffix
          expected_table="${potential_prefix}${suffix}"
        fi

        # Check if this expected core table exists in our table list
        if ! echo "$all_tables" | grep -q "^${expected_table}$"; then
          prefix_valid=false
          break
        fi
      done

      # If all core tables exist with this prefix, collect it
      if $prefix_valid; then
        all_valid_prefixes+=("$potential_prefix")
      fi
    done <<< "$all_tables"

    # SAFETY: Check if multiple WordPress installations detected (Issue #84)
    if [[ ${#all_valid_prefixes[@]} -gt 1 ]]; then
      # Multiple prefixes found - check if this is a multisite network
      # WordPress multisite has wp_blogs and wp_sitemeta tables (only in base prefix)
      # Additional sites have wp_2_, wp_3_, etc. prefixes with their own core tables

      # Get the shortest prefix (likely the base site in multisite)
      base_prefix=$(printf '%s\n' "${all_valid_prefixes[@]}" | awk '{ print length, $0 }' | sort -n | head -1 | cut -d' ' -f2-)

      # Check for multisite indicator tables
      # Note: Prefixes stored with trailing underscore (e.g., "wp_"), so we need to
      # handle concatenation carefully to avoid double underscores
      is_multisite=false
      if [[ -z "$base_prefix" ]]; then
        # Empty prefix case: look for "blogs" and "sitemeta" directly
        if echo "$all_tables" | grep -q "^blogs$" && \
           echo "$all_tables" | grep -q "^sitemeta$"; then
          is_multisite=true
        fi
      else
        # Non-empty prefix: strip trailing underscore before checking
        # (prefix is stored as "wp_", but table is "wp_blogs", not "wp__blogs")
        prefix_without_underscore="${base_prefix%_}"
        if echo "$all_tables" | grep -q "^${prefix_without_underscore}_blogs$" && \
           echo "$all_tables" | grep -q "^${prefix_without_underscore}_sitemeta$"; then
          is_multisite=true
        fi
      fi

      if $is_multisite; then
        log "Detected WordPress multisite network with ${#all_valid_prefixes[@]} sites"
        log "  Base prefix: $base_prefix"
        log "  Site prefixes: ${all_valid_prefixes[*]}"
      fi

      if ! $is_multisite; then
        err "Multiple WordPress installations detected in the same database!

Found ${#all_valid_prefixes[@]} complete WordPress installations:
$(printf '  - %s\n' "${all_valid_prefixes[@]}")

This creates ambiguity about which WordPress installation to use.
Using the wrong prefix will cause data corruption or complete site failure.

Common causes:
  - Staging + Production in same database
  - Multiple test environments
  - Shared hosting with multiple sites

Cannot auto-detect prefix safely. Migration aborted.

NEXT STEPS:
  1. Export a clean archive with only ONE WordPress installation
  2. Use separate databases for staging/production
  3. Or manually specify which tables to include in the archive

NOTE: If this is a WordPress multisite network, ensure wp_blogs and
      wp_sitemeta tables are present in the archive."
      fi

      # For multisite, use the base prefix
      IMPORTED_DB_PREFIX="$base_prefix"
      log "Detected imported database prefix: $IMPORTED_DB_PREFIX"
    elif [[ ${#all_valid_prefixes[@]} -eq 1 ]]; then
      IMPORTED_DB_PREFIX="${all_valid_prefixes[0]}"
      log "Detected imported database prefix: $IMPORTED_DB_PREFIX"
      log "  Verified core tables: ${IMPORTED_DB_PREFIX}options, ${IMPORTED_DB_PREFIX}posts, ${IMPORTED_DB_PREFIX}users"
    fi
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
  if ! $SEARCH_REPLACE; then
    log "[dry-run] Would skip bulk search-replace (--no-search-replace flag set)"
    log "[dry-run] Would update home and siteurl options only to destination URLs"
    log "[dry-run] WARNING: Other URLs in content/metadata would remain unchanged"
  else
    log "[dry-run] Would detect imported URLs and replace with destination URLs"
    log "[dry-run]   Replace: <imported-home-url> -> $ORIGINAL_DEST_HOME_URL"
    log "[dry-run]   Replace: <imported-site-url> -> $ORIGINAL_DEST_SITE_URL"
  fi
else
  log "Detecting imported URLs..."
  IMPORTED_HOME_URL="$(wp_local option get home)"
  IMPORTED_SITE_URL="$(wp_local option get siteurl)"
  log "Imported home URL: $IMPORTED_HOME_URL"
  log "Imported site URL: $IMPORTED_SITE_URL"

  if [[ "$IMPORTED_HOME_URL" != "$ORIGINAL_DEST_HOME_URL" || "$IMPORTED_SITE_URL" != "$ORIGINAL_DEST_SITE_URL" ]]; then
    if ! $SEARCH_REPLACE; then
      log "Skipping bulk search-replace (--no-search-replace flag set)"
      log "Setting home and siteurl options only..."

      wp_local option update home "$ORIGINAL_DEST_HOME_URL" >/dev/null
      wp_local option update siteurl "$ORIGINAL_DEST_SITE_URL" >/dev/null

      log "WARNING: Only home and siteurl options were updated to destination URLs."
      log "         Other URLs in post content, metadata, and options remain unchanged."
      log "         If needed, run manual search-replace: wp search-replace '$IMPORTED_HOME_URL' '$ORIGINAL_DEST_HOME_URL'"
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
    log "Imported URLs match destination URLs in options table."

    # SAFETY: Verify post content doesn't contain mismatched URLs (Issue #88-5)
    # Even if options table URLs match, post content might have old URLs
    log_verbose "Verifying post content for URL consistency..."

    # Sample post content to check for common URL patterns that might indicate old URLs
    # Check for protocol-less URLs (//), http/https URLs in guid and post_content
    # We use a small LIMIT to make this check fast (don't scan entire database)
    sample_urls=$(wp_local db query "
      SELECT DISTINCT
        SUBSTRING_INDEX(SUBSTRING_INDEX(post_content, '://', 2), '/', 1) as url_fragment
      FROM ${IMPORTED_DB_PREFIX}posts
      WHERE post_content LIKE '%://%'
      LIMIT 100
    " --skip-column-names 2>/dev/null | grep -v '^$' | head -20 || true)

    # Check if any sampled URLs contain hostnames different from destination
    dest_hostname="$(url_host_only "$ORIGINAL_DEST_HOME_URL")"

    if [[ -n "$sample_urls" && -n "$dest_hostname" ]]; then
      found_mismatch=false
      mismatched_urls=()

      while IFS= read -r url_fragment; do
        # Skip empty lines
        [[ -z "$url_fragment" ]] && continue

        # Extract hostname from fragment (remove protocol if present)
        hostname="${url_fragment#http}"
        hostname="${hostname#s}"
        hostname="${hostname#://}"

        # Check if this hostname differs from destination
        if [[ "$hostname" != "$dest_hostname" && "$hostname" != "localhost"* ]]; then
          found_mismatch=true
          mismatched_urls+=("$hostname")
        fi
      done <<< "$sample_urls"

      if $found_mismatch; then
        log "WARNING: Post content may contain URLs from different domain(s):"
        printf '  • %s\n' "${mismatched_urls[@]}" | sort -u
        log ""
        log "This might indicate:"
        log "  - Archive contains mixed content from multiple environments"
        log "  - Embedded media/links from external sources (this is normal)"
        log "  - Incomplete URL replacement in source archive"
        log ""
        log "To fix potential issues, run manual search-replace:"
        for mismatch in $(printf '%s\n' "${mismatched_urls[@]}" | sort -u | head -3); do
          log "  wp search-replace 'http://$mismatch' '$ORIGINAL_DEST_HOME_URL' --dry-run"
        done
      else
        log_verbose "  ✓ Post content URLs appear consistent with destination"
      fi
    fi

    log "No URL replacement performed (URLs already aligned)."
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

  # Detect rsync capabilities (macOS openrsync lacks --info=progress2)
  rsync_progress_opt=$(get_rsync_progress_opts)

  RSYNC_OPTS=(-a --delete "$rsync_progress_opt")
  log_verbose "  Base options: -a --delete $rsync_progress_opt"

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

  # Verify source directory exists and has content before rsync
  if [[ ! -d "$ARCHIVE_WP_CONTENT" ]]; then
    err "CRITICAL: Archive wp-content directory no longer exists: $ARCHIVE_WP_CONTENT

The extracted wp-content directory was deleted or moved before rsync could run.
This may indicate:
  • macOS cleaned up the temp directory
  • Another process modified the extraction directory
  • Disk space issues caused cleanup

The database has been imported but wp-content was NOT synced.
To recover, restore from the backup: $DEST_WP_CONTENT_BACKUP"
  fi

  source_file_count=$(find "$ARCHIVE_WP_CONTENT" -type f 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$source_file_count" -lt 10 ]]; then
    err "CRITICAL: Archive wp-content directory appears empty or nearly empty ($source_file_count files)

Expected thousands of files but found very few. This may indicate:
  • Extraction failed silently
  • Archive was corrupted
  • Temp directory was partially cleaned

The database has been imported but wp-content was NOT synced.
To recover, restore from the backup: $DEST_WP_CONTENT_BACKUP"
  fi

  log_verbose "  Source file count: $source_file_count"
  log_trace "rsync ${RSYNC_OPTS[*]} ${RSYNC_EXCLUDES[*]} $ARCHIVE_WP_CONTENT/ $DEST_WP_CONTENT/"

  # Run rsync and capture exit status
  # Note: pipefail doesn't help here because tee always succeeds
  # Use PIPESTATUS to check rsync's actual exit code
  rsync "${RSYNC_OPTS[@]}" "${RSYNC_EXCLUDES[@]}" \
    "$ARCHIVE_WP_CONTENT/" "$DEST_WP_CONTENT/" 2>&1 | tee -a "$LOG_FILE"
  rsync_status=${PIPESTATUS[0]}

  if [[ $rsync_status -ne 0 ]]; then
    err "rsync failed (exit code $rsync_status) to sync wp-content from archive.

The database has been imported but wp-content sync failed.
To recover, restore from the backup: $DEST_WP_CONTENT_BACKUP"
  fi

  log "wp-content synced successfully (object-cache.php excluded to preserve destination caching)"

  # Restore unique destination plugins/themes (if preserving)
  if $PRESERVE_DEST_PLUGINS; then
    restore_dest_content_local "$DEST_WP_CONTENT_BACKUP"
  fi
fi

# Phase 10: Flush cache if available
log_verbose "Checking for Redis object cache support..."
if wp_local_full cli has-command redis >/dev/null 2>&1; then
  log_verbose "  ✓ Redis CLI available (flushing cache)"
  if $DRY_RUN; then
    log "[dry-run] Would flush Object Cache Pro cache via: wp redis flush"
  else
    log "Flushing Object Cache Pro cache..."
    if ! wp_local_full redis flush; then
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

# ==================================================================================
# BACKUP MODE WORKFLOW
# ==================================================================================
# Execute backup mode (local or remote)
if [[ "$MIGRATION_MODE" == "backup-local" ]]; then
  if $DRY_RUN; then
    log "=== DRY RUN MODE ==="
    log "Would create local backup with:"
    log "  Source: $SOURCE_ROOT"
    log "  Destination: ~/wp-migrate-backups/<domain>-<timestamp>.zip"
    log ""
    log "Validation checks that would run:"
    log "  ✓ WordPress installation at $SOURCE_ROOT"
    log "  ✓ wp-cli availability"
    log "  ✓ Disk space requirements"
    log ""
    log "No backup created (dry-run mode)"
    exit 0
  fi

  create_backup_local
  exit 0

elif [[ "$MIGRATION_MODE" == "backup-remote" ]]; then
  if $DRY_RUN; then
    log "=== DRY RUN MODE ==="
    log "Would create remote backup with:"
    log "  Source: $SOURCE_HOST:$SOURCE_ROOT"
    log "  Destination: $BACKUP_OUTPUT_DIR/<domain>-<timestamp>.zip"
    log ""
    log "Validation checks that would run:"
    log "  ✓ SSH connectivity to $SOURCE_HOST"
    log "  ✓ WordPress installation at $SOURCE_ROOT"
    log "  ✓ wp-cli availability"
    log "  ✓ Disk space requirements"
    log ""
    log "No backup created (dry-run mode)"
    exit 0
  fi

  create_backup
  exit 0
fi
