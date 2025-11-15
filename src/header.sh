#!/usr/bin/env bash
set -Eeuo pipefail

VERSION="2.10.0"  # wp-migrate version

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
ARCHIVE_FILE=""              # REQUIRED (archive mode): path to backup archive file
ARCHIVE_TYPE=""              # OPTIONAL (archive mode): adapter name override (duplicator, jetpack, etc.)
MIGRATION_MODE=""            # Detected: "push", "archive", or "rollback"
ROLLBACK_MODE=false          # Enable rollback mode (--rollback flag)
ROLLBACK_BACKUP_PATH=""      # Optional: Explicitly specify backup to restore
# shellcheck disable=SC2034  # Used in main.sh for backup mode
CREATE_BACKUP=false          # Enable backup creation mode (--create-backup flag)
# shellcheck disable=SC2034  # Used in main.sh for backup mode
SOURCE_HOST=""               # Source server SSH connection string (user@host)
# shellcheck disable=SC2034  # Used in main.sh for backup mode
SOURCE_ROOT=""               # Absolute path to WordPress root on source server
# shellcheck disable=SC2034  # Used in functions.sh for backup mode
BACKUP_OUTPUT_DIR="\$HOME/wp-migrate-backups"  # Directory on source server for backups (expands remotely)

# Use a single-element -o form to avoid dangling -o errors if mis-expanded
SSH_OPTS=(-oStrictHostKeyChecking=accept-new)
SSH_CONTROL_ACTIVE=false
SSH_CONTROL_DIR=""
SSH_CONTROL_PATH=""

DRY_RUN=false
QUIET_MODE=false            # Suppress progress indicators (--quiet flag)
YES_MODE=false              # Skip confirmation prompts (--yes flag)
IMPORT_DB=true              # Automatically import DB on destination after transfer (disable with --no-import-db)
SEARCH_REPLACE=true         # Automatically perform URL search-replace after DB import (disable with --no-search-replace)
GZIP_DB=true                # Compress DB dump during transfer
MAINTENANCE_ALWAYS=true     # Always enable maintenance mode during migration
MAINTENANCE_SOURCE=true     # Allow skipping maintenance mode on the source (--no-maint-source)
STELLARSITES_MODE=false     # Enable StellarSites compatibility (preserves protected mu-plugins)
PRESERVE_DEST_PLUGINS=false # Preserve destination plugins/themes not in source (auto-enabled with --stellarsites)

# Plugin/theme preservation tracking
DEST_PLUGINS_BEFORE=()      # Plugins on destination before migration
DEST_THEMES_BEFORE=()       # Themes on destination before migration
SOURCE_PLUGINS=()           # Plugins in source (push) or archive (duplicator)
SOURCE_THEMES=()            # Themes in source (push) or archive (duplicator)
UNIQUE_DEST_PLUGINS=()      # Plugins unique to destination (to be restored)
UNIQUE_DEST_THEMES=()       # Themes unique to destination (to be restored)
FILTERED_DROPINS=()         # Drop-ins filtered from plugin preservation
FILTERED_MANAGED_PLUGINS=() # Managed plugins filtered in StellarSites mode

# Archive mode variables
ARCHIVE_ADAPTER=""           # Detected adapter name (duplicator, jetpack, etc.)
ARCHIVE_EXTRACT_DIR=""       # Temporary extraction directory
ARCHIVE_DB_FILE=""           # Detected database file path
ARCHIVE_WP_CONTENT=""        # Detected wp-content directory path
ORIGINAL_DEST_HOME_URL=""    # Captured before import (archive mode)
ORIGINAL_DEST_SITE_URL=""    # Captured before import (archive mode)

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
