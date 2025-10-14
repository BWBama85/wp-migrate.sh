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
ARCHIVE_FILE=""              # REQUIRED (archive mode): path to backup archive file
ARCHIVE_TYPE=""              # OPTIONAL (archive mode): adapter name override (duplicator, jetpack, etc.)
MIGRATION_MODE=""            # Detected: "push" or "archive"

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
STELLARSITES_MODE=false     # Enable StellarSites compatibility (preserves protected mu-plugins)

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
