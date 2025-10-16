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
# -------------
# Core Utilities
# -------------

# Verbosity control flags (set by argument parser)
VERBOSE=false
TRACE_MODE=false

err() { printf "ERROR: %s\n" "$*" >&2; exit 1; }

# Get installation instructions for a missing dependency
# Usage: get_install_instructions <command_name>
# Returns: Installation instructions text
get_install_instructions() {
  local cmd="$1"
  case "$cmd" in
    wp)
      cat << 'INSTRUCTIONS'
  # WP-CLI (WordPress command-line tool)
  # macOS: brew install wp-cli
  # Linux: curl -O https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar && chmod +x wp-cli.phar && sudo mv wp-cli.phar /usr/local/bin/wp
  # Verify: wp --version
INSTRUCTIONS
      ;;
    rsync)
      cat << 'INSTRUCTIONS'
  # rsync (file synchronization tool)
  # macOS: brew install rsync (or use built-in)
  # Debian/Ubuntu: sudo apt-get install rsync
  # RHEL/CentOS: sudo yum install rsync
  # Verify: rsync --version
INSTRUCTIONS
      ;;
    ssh)
      cat << 'INSTRUCTIONS'
  # SSH client
  # macOS: built-in (check with: which ssh)
  # Debian/Ubuntu: sudo apt-get install openssh-client
  # RHEL/CentOS: sudo yum install openssh-clients
  # Verify: ssh -V
INSTRUCTIONS
      ;;
    gzip)
      cat << 'INSTRUCTIONS'
  # gzip (compression tool)
  # Usually pre-installed on most systems
  # macOS: built-in
  # Debian/Ubuntu: sudo apt-get install gzip
  # RHEL/CentOS: sudo yum install gzip
  # Verify: gzip --version
INSTRUCTIONS
      ;;
    unzip)
      cat << 'INSTRUCTIONS'
  # unzip (archive extraction tool for ZIP files)
  # macOS: brew install unzip (or use built-in)
  # Debian/Ubuntu: sudo apt-get install unzip
  # RHEL/CentOS: sudo yum install unzip
  # Verify: unzip -v
INSTRUCTIONS
      ;;
    tar)
      cat << 'INSTRUCTIONS'
  # tar (archive tool)
  # Usually pre-installed on most systems
  # macOS: built-in
  # Debian/Ubuntu: sudo apt-get install tar
  # RHEL/CentOS: sudo yum install tar
  # Verify: tar --version
INSTRUCTIONS
      ;;
    file)
      cat << 'INSTRUCTIONS'
  # file (file type detection tool)
  # macOS: brew install file (or use built-in)
  # Debian/Ubuntu: sudo apt-get install file
  # RHEL/CentOS: sudo yum install file
  # Verify: file --version
INSTRUCTIONS
      ;;
    *)
      cat << INSTRUCTIONS
  # Generic installation:
  # Check your system's package manager
  # macOS: brew install $cmd
  # Debian/Ubuntu: sudo apt-get install $cmd
  # RHEL/CentOS: sudo yum install $cmd
INSTRUCTIONS
      ;;
  esac
}

needs() {
  local cmd="$1"
  log_verbose "Checking for required dependency: $cmd"
  if command -v "$cmd" >/dev/null 2>&1; then
    local cmd_path
    cmd_path=$(command -v "$cmd")
    log_verbose "  ✓ Found: $cmd_path"
    return 0
  else
    err "Missing required dependency: $cmd

This command is required for migration to work.

Installation instructions:
$(get_install_instructions "$cmd")

After installation, verify with:
  which $cmd && $cmd --version"
  fi
}

validate_url() {
  local url="$1" flag_name="$2"
  # Basic URL validation: must start with http:// or https://
  if [[ ! "$url" =~ ^https?:// ]]; then
    err "$flag_name must be a valid URL starting with http:// or https://

Invalid URL: $url

Common mistakes:
  • Missing protocol: use http://example.com (not example.com)
  • Wrong protocol: use http:// or https:// (not ftp:// or file://)

Examples:
  $flag_name http://example.com
  $flag_name https://staging.example.com
  $flag_name https://example.com/subdir"
  fi
  # Ensure URL has a domain part after protocol
  if [[ ! "$url" =~ ^https?://[^/]+ ]]; then
    err "$flag_name must include a domain name after the protocol.

Invalid URL: $url

The URL must have a domain name after http:// or https://

Examples:
  ✓ Correct: http://example.com
  ✓ Correct: https://staging.example.com/wordpress
  ✗ Wrong: http://
  ✗ Wrong: https:///path"
  fi
}

log() {
  # Write to stderr to prevent contaminating command substitutions
  # This ensures log output doesn't interfere with captured return values
  printf "%s %s\n" "$(date '+%F %T')" "$*" | tee -a "$LOG_FILE" >&2
}

log_warning() {
  # Yellow text for warnings (non-critical issues that don't stop migration)
  # Write to stderr to prevent contaminating command substitutions
  local yellow='\033[1;33m'
  local reset='\033[0m'
  local timestamp
  local plain_msg
  timestamp="$(date '+%F %T')"
  plain_msg="$timestamp WARNING: $*"

  # Always write plain text to log file
  printf "%s\n" "$plain_msg" >> "$LOG_FILE"

  # Write colored output to stderr (check fd 2, not fd 1)
  if [[ -t 2 ]]; then
    printf "%s ${yellow}WARNING:${reset} %s\n" "$timestamp" "$*" >&2
  else
    # Non-interactive, just echo the plain message to stderr
    printf "%s\n" "$plain_msg" >&2
  fi
}

log_verbose() {
  # Only log if --verbose flag is set
  # Uses same format as log() for consistency
  if $VERBOSE; then
    log "$@"
  fi
}

log_trace() {
  # Logs command execution traces when --trace flag is set
  # Uses cyan color to distinguish from regular logs
  # CRITICAL: Write to stderr to prevent contaminating command substitutions
  # Without this, trace output gets captured in variables like SOURCE_DB_PREFIX="$(wp_local ...)"
  if $TRACE_MODE; then
    local cyan='\033[0;36m'
    local reset='\033[0m'
    local timestamp
    local plain_msg
    timestamp="$(date '+%F %T')"
    plain_msg="$timestamp + $*"

    # Always write plain text to log file
    printf "%s\n" "$plain_msg" >> "$LOG_FILE"

    # Write colored output to stderr (check fd 2, not fd 1)
    if [[ -t 2 ]]; then
      printf "%s ${cyan}+${reset} %s\n" "$timestamp" "$*" >&2
    else
      # Non-interactive, write plain message to stderr
      printf "%s\n" "$plain_msg" >&2
    fi
  fi
}
# -----------------------------
# Archive Adapter Base Functions
# -----------------------------
# Shared helper functions available to all adapters

# Score a directory based on WordPress structure
# Returns: score (0-3 based on plugins, themes, uploads subdirectories present)
adapter_base_score_wp_content() {
  local dir="$1" score=0
  [[ -d "$dir/plugins" ]] && score=$((score + 1))
  [[ -d "$dir/themes" ]] && score=$((score + 1))
  [[ -d "$dir/uploads" ]] && score=$((score + 1))
  echo "$score"
}

# Find best wp-content directory by scoring all candidates
# Usage: adapter_base_find_best_wp_content <extract_dir>
# Returns: path to best wp-content directory, or empty string if none found
adapter_base_find_best_wp_content() {
  local extract_dir="$1"
  local candidates=()
  local best_dir="" best_score=0

  # Find all wp-content directories
  while IFS= read -r -d '' dir; do
    candidates+=("$dir")
  done < <(find "$extract_dir" -type d -name "wp-content" -print0 2>/dev/null)

  [[ ${#candidates[@]} -eq 0 ]] && return 1

  # Score each candidate
  for dir in "${candidates[@]}"; do
    local score
    score=$(adapter_base_score_wp_content "$dir")
    if [[ $score -gt $best_score ]]; then
      best_score=$score
      best_dir="$dir"
    fi
  done

  # Return best match, or first candidate if all scored 0
  if [[ -n "$best_dir" ]]; then
    echo "$best_dir"
    return 0
  else
    echo "${candidates[0]}"
    return 0
  fi
}

# Check if archive contains a file matching a pattern
# Usage: adapter_base_archive_contains <archive_path> <pattern>
# Returns: 0 if pattern found, 1 if not found
adapter_base_archive_contains() {
  local archive="$1" pattern="$2"
  local archive_type

  archive_type=$(adapter_base_get_archive_type "$archive")

  if [[ "$archive_type" == "zip" ]]; then
    unzip -l "$archive" 2>/dev/null | grep -q "$pattern" && return 0
  elif [[ "$archive_type" == "tar.gz" ]]; then
    # Gzip-compressed tar: use -z flag
    tar -tzf "$archive" 2>/dev/null | grep -q "$pattern" && return 0
  elif [[ "$archive_type" == "tar" ]]; then
    # Uncompressed tar: no compression flag
    tar -tf "$archive" 2>/dev/null | grep -q "$pattern" && return 0
  fi

  return 1
}

# Get archive file type (zip, tar, tar.gz, etc.)
# Usage: adapter_base_get_archive_type <archive_path>
# Returns: "zip" | "tar" | "tar.gz" | "unknown"
adapter_base_get_archive_type() {
  local archive="$1"
  local file_output

  file_output=$(file -b "$archive" 2>/dev/null | tr '[:upper:]' '[:lower:]')

  if [[ "$file_output" == *"zip"* ]]; then
    echo "zip"
  elif [[ "$file_output" == *"gzip"* ]] || [[ "$file_output" == *"compressed"* ]]; then
    echo "tar.gz"
  elif [[ "$file_output" == *"tar"* ]]; then
    echo "tar"
  else
    echo "unknown"
  fi
}
# -----------------------
# Duplicator Archive Adapter
# -----------------------
# Handles Duplicator Pro/Lite backup archives (.zip format)
#
# Archive Structure:
#   - Format: ZIP
#   - Database: dup-installer/dup-database__*.sql
#   - wp-content: Auto-detected via directory scoring
#   - Signature files: installer.php, archive.json (optional)

# Validate if this archive is a Duplicator backup
# Usage: adapter_duplicator_validate <archive_path>
# Returns: 0 if valid Duplicator archive, 1 otherwise
adapter_duplicator_validate() {
  local archive="$1"

  # Check file exists
  [[ -f "$archive" ]] || return 1

  # Check if it's a ZIP file
  local archive_type
  archive_type=$(adapter_base_get_archive_type "$archive")
  [[ "$archive_type" == "zip" ]] || return 1

  # Check for Duplicator signature file (installer.php)
  if adapter_base_archive_contains "$archive" "installer.php"; then
    return 0
  fi

  # Fallback: Check for database file pattern
  if adapter_base_archive_contains "$archive" "dup-installer/dup-database__"; then
    return 0
  fi

  return 1
}

# Extract Duplicator archive
# Usage: adapter_duplicator_extract <archive_path> <dest_dir>
# Returns: 0 on success, 1 on failure
adapter_duplicator_extract() {
  local archive="$1" dest="$2"

  log_trace "unzip -q \"$archive\" -d \"$dest\""
  if ! unzip -q "$archive" -d "$dest" 2>/dev/null; then
    return 1
  fi

  return 0
}

# Find database file in extracted Duplicator archive
# Usage: adapter_duplicator_find_database <extract_dir>
# Returns: 0 and echoes path if found, 1 if not found
adapter_duplicator_find_database() {
  local extract_dir="$1"
  local db_file

  # Look for database file in dup-installer directory
  db_file=$(find "$extract_dir" -type f -path "*/dup-installer/dup-database__*.sql" 2>/dev/null | head -1)

  if [[ -z "$db_file" ]]; then
    return 1
  fi

  echo "$db_file"
  return 0
}

# Find wp-content directory in extracted Duplicator archive
# Usage: adapter_duplicator_find_content <extract_dir>
# Returns: 0 and echoes path if found, 1 if not found
adapter_duplicator_find_content() {
  local extract_dir="$1"
  local wp_content_dir

  # Use base helper to find best wp-content directory
  wp_content_dir=$(adapter_base_find_best_wp_content "$extract_dir")

  if [[ -z "$wp_content_dir" ]]; then
    return 1
  fi

  echo "$wp_content_dir"
  return 0
}

# Get human-readable format name
# Usage: adapter_duplicator_get_name
# Returns: Format name string
adapter_duplicator_get_name() {
  echo "Duplicator"
}

# Get required dependencies for this adapter
# Usage: adapter_duplicator_get_dependencies
# Returns: Space-separated list of required commands
adapter_duplicator_get_dependencies() {
  echo "unzip file"
}
# -----------------------
# Jetpack Backup Archive Adapter
# -----------------------
# Handles Jetpack Backup archives (ZIP or TAR.GZ format, or extracted directory)
#
# Archive Structure:
#   - Format: ZIP, TAR.GZ, or already-extracted directory
#   - Database: sql/*.sql (multiple files, one per table)
#   - wp-content: wp-content/ at root level
#   - Metadata: meta.json (contains WordPress version, plugins, themes)
#   - Config: wp-config.php at root level
#
# Table prefix detection: Extracted from sql/ filenames (e.g., wp_options.sql → wp_)

# Validate if this archive is a Jetpack backup
# Usage: adapter_jetpack_validate <archive_path>
# Returns: 0 if valid Jetpack archive, 1 otherwise
adapter_jetpack_validate() {
  local archive="$1"

  # Handle both archives and extracted directories
  if [[ -d "$archive" ]]; then
    # Already extracted directory
    [[ -d "$archive/sql" ]] || return 1
    [[ -f "$archive/meta.json" ]] || return 1
    [[ -d "$archive/wp-content" ]] || return 1
    return 0
  fi

  # Check file exists
  [[ -f "$archive" ]] || return 1

  # Check if it's a supported archive format
  local archive_type
  archive_type=$(adapter_base_get_archive_type "$archive")
  [[ "$archive_type" == "zip" || "$archive_type" == "tar.gz" || "$archive_type" == "tar" ]] || return 1

  # Check for Jetpack signature: meta.json + sql/ directory
  if adapter_base_archive_contains "$archive" "meta.json"; then
    if adapter_base_archive_contains "$archive" "sql/wp_options.sql"; then
      return 0
    fi
  fi

  return 1
}

# Extract Jetpack archive
# Usage: adapter_jetpack_extract <archive_path> <dest_dir>
# Returns: 0 on success, 1 on failure
adapter_jetpack_extract() {
  local archive="$1" dest="$2"

  # If already a directory, copy it (include hidden files with trailing /.)
  if [[ -d "$archive" ]]; then
    log_trace "cp -a \"$archive\"/. \"$dest\"/"
    if ! cp -a "$archive"/. "$dest"/ 2>/dev/null; then
      return 1
    fi
    return 0
  fi

  # Extract based on archive type
  local archive_type
  archive_type=$(adapter_base_get_archive_type "$archive")

  if [[ "$archive_type" == "zip" ]]; then
    log_trace "unzip -q \"$archive\" -d \"$dest\""
    if ! unzip -q "$archive" -d "$dest" 2>/dev/null; then
      return 1
    fi
  elif [[ "$archive_type" == "tar.gz" ]]; then
    log_trace "tar -xzf \"$archive\" -C \"$dest\""
    if ! tar -xzf "$archive" -C "$dest" 2>/dev/null; then
      return 1
    fi
  elif [[ "$archive_type" == "tar" ]]; then
    log_trace "tar -xf \"$archive\" -C \"$dest\""
    if ! tar -xf "$archive" -C "$dest" 2>/dev/null; then
      return 1
    fi
  else
    return 1
  fi

  return 0
}

# Find database files in extracted Jetpack archive and consolidate them
# Usage: adapter_jetpack_find_database <extract_dir>
# Returns: 0 and echoes path to consolidated database file if found, 1 if not found
adapter_jetpack_find_database() {
  local extract_dir="$1"
  local sql_dir

  # Look for sql/ directory
  sql_dir=$(find "$extract_dir" -type d -name "sql" 2>/dev/null | head -1)

  if [[ -z "$sql_dir" ]]; then
    return 1
  fi

  # Verify it contains SQL files
  local sql_count
  sql_count=$(find "$sql_dir" -type f -name "*.sql" 2>/dev/null | wc -l)
  if [[ $sql_count -lt 5 ]]; then
    return 1
  fi

  # Consolidate all SQL files into a single database dump
  local consolidated_file="$extract_dir/jetpack-database-consolidated.sql"
  if ! adapter_jetpack_consolidate_database "$sql_dir" "$consolidated_file"; then
    return 1
  fi

  echo "$consolidated_file"
  return 0
}

# Find wp-content directory in extracted Jetpack archive
# Usage: adapter_jetpack_find_content <extract_dir>
# Returns: 0 and echoes path if found, 1 if not found
adapter_jetpack_find_content() {
  local extract_dir="$1"
  local wp_content_dir

  # Jetpack stores wp-content at root level of backup
  # Try direct path first
  if [[ -d "$extract_dir/wp-content" ]]; then
    wp_content_dir="$extract_dir/wp-content"
  else
    # Fallback: Use base helper to find best wp-content directory
    wp_content_dir=$(adapter_base_find_best_wp_content "$extract_dir")
  fi

  if [[ -z "$wp_content_dir" ]]; then
    return 1
  fi

  echo "$wp_content_dir"
  return 0
}

# Detect table prefix from Jetpack SQL filenames
# Usage: adapter_jetpack_detect_prefix <sql_dir>
# Returns: 0 and echoes prefix if detected, 1 if not found
adapter_jetpack_detect_prefix() {
  local sql_dir="$1"

  # Look for options table SQL file (e.g., wp_options.sql, prefix_options.sql)
  local options_file
  options_file=$(find "$sql_dir" -type f -name "*_options.sql" 2>/dev/null | head -1)

  if [[ -z "$options_file" ]]; then
    return 1
  fi

  # Extract prefix from filename: /path/to/wp_options.sql → wp_
  local filename
  filename=$(basename "$options_file")
  local prefix="${filename%_options.sql}_"

  if [[ -z "$prefix" || "$prefix" == "_" ]]; then
    return 1
  fi

  echo "$prefix"
  return 0
}

# Consolidate Jetpack SQL files into single database dump
# Usage: adapter_jetpack_consolidate_database <sql_dir> <output_file>
# Returns: 0 on success, 1 on failure
adapter_jetpack_consolidate_database() {
  local sql_dir="$1" output_file="$2"

  # Find all SQL files and concatenate them (Bash 3.2 + BSD compatible)
  # Collect files into array, then sort (BSD sort doesn't support -z)
  local sql_files=()
  while IFS= read -r -d '' file; do
    sql_files+=("$file")
  done < <(find "$sql_dir" -type f -name "*.sql" -print0 2>/dev/null)

  if [[ ${#sql_files[@]} -eq 0 ]]; then
    return 1
  fi

  # Sort the array using Bash built-in sorting (works on all platforms)
  # Read sorted output back into array (ShellCheck compliant)
  local sorted_files
  sorted_files=$(printf '%s\n' "${sql_files[@]}" | sort)
  sql_files=()
  while IFS= read -r file; do
    sql_files+=("$file")
  done <<<"$sorted_files"

  # Concatenate all SQL files into output file
  : > "$output_file"  # Create/truncate output file
  for sql_file in "${sql_files[@]}"; do
    cat "$sql_file" >> "$output_file"
    echo "" >> "$output_file"  # Add newline between files
  done

  return 0
}

# Get human-readable format name
# Usage: adapter_jetpack_get_name
# Returns: Format name string
adapter_jetpack_get_name() {
  echo "Jetpack Backup"
}

# Get required dependencies for this adapter
# Usage: adapter_jetpack_get_dependencies
# Returns: Space-separated list of required commands
adapter_jetpack_get_dependencies() {
  echo "unzip tar file"
}
# -----------------------
# Solid Backups (Legacy) Archive Adapter
# -----------------------
# Handles Solid Backups (formerly BackupBuddy/iThemes Backup) archives (.zip format)
#
# Archive Structure:
#   - Format: ZIP containing full WordPress directory
#   - Database: wp-content/uploads/backupbuddy_temp/{BACKUP_ID}/wp_*.sql (multiple files, one per table)
#   - wp-content: Standard wp-content/ directory at root
#   - Signature files: importbuddy.php, backupbuddy_dat.php in backupbuddy_temp/{BACKUP_ID}/
#   - Backup ID: Random hash in root folder name (e.g., backup-xxx-05ec9s386h)

# Validate if this archive is a Solid Backups backup
# Usage: adapter_solidbackups_validate <archive_path>
# Returns: 0 if valid Solid Backups archive, 1 otherwise
adapter_solidbackups_validate() {
  local archive="$1"

  # Handle both archives and extracted directories
  if [[ -d "$archive" ]]; then
    # Already extracted directory - check for backupbuddy_temp structure
    if [[ -d "$archive/wp-content/uploads/backupbuddy_temp" ]]; then
      # Look for importbuddy.php signature file in any subdirectory
      if find "$archive/wp-content/uploads/backupbuddy_temp" -maxdepth 2 -type f -name "importbuddy.php" 2>/dev/null | grep -q .; then
        return 0
      fi
      # Fallback: Check for backupbuddy_dat.php (importbuddy is often downloaded separately)
      if find "$archive/wp-content/uploads/backupbuddy_temp" -maxdepth 2 -type f -name "backupbuddy_dat.php" 2>/dev/null | grep -q .; then
        return 0
      fi
    fi
    return 1
  fi

  # Check file exists
  [[ -f "$archive" ]] || return 1

  # Check if it's a ZIP file
  local archive_type
  archive_type=$(adapter_base_get_archive_type "$archive")
  [[ "$archive_type" == "zip" ]] || return 1

  # Check for Solid Backups signature: importbuddy.php in backupbuddy_temp
  if adapter_base_archive_contains "$archive" "backupbuddy_temp.*importbuddy.php"; then
    return 0
  fi

  # Fallback: Check for backupbuddy_dat.php
  if adapter_base_archive_contains "$archive" "backupbuddy_temp.*backupbuddy_dat.php"; then
    return 0
  fi

  return 1
}

# Extract Solid Backups archive
# Usage: adapter_solidbackups_extract <archive_path> <dest_dir>
# Returns: 0 on success, 1 on failure
adapter_solidbackups_extract() {
  local archive="$1" dest="$2"

  # If already a directory, copy it (include hidden files with trailing /.)
  if [[ -d "$archive" ]]; then
    log_trace "cp -a \"$archive\"/. \"$dest\"/"
    if ! cp -a "$archive"/. "$dest"/ 2>/dev/null; then
      return 1
    fi
    return 0
  fi

  # Extract ZIP archive
  log_trace "unzip -q \"$archive\" -d \"$dest\""
  if ! unzip -q "$archive" -d "$dest" 2>/dev/null; then
    return 1
  fi

  return 0
}

# Find database files in extracted Solid Backups archive and consolidate them
# Usage: adapter_solidbackups_find_database <extract_dir>
# Returns: 0 and echoes path to consolidated database file if found, 1 if not found
adapter_solidbackups_find_database() {
  local extract_dir="$1"
  local backupbuddy_temp_dir

  # Look for backupbuddy_temp directory
  backupbuddy_temp_dir=$(find "$extract_dir" -type d -path "*/wp-content/uploads/backupbuddy_temp" 2>/dev/null | head -1)

  if [[ -z "$backupbuddy_temp_dir" ]]; then
    return 1
  fi

  # Find the backup ID directory (contains importbuddy.php and SQL files)
  local backup_id_dir
  backup_id_dir=$(find "$backupbuddy_temp_dir" -maxdepth 1 -type d ! -path "$backupbuddy_temp_dir" 2>/dev/null | head -1)

  if [[ -z "$backup_id_dir" ]]; then
    return 1
  fi

  # Verify it contains SQL files (use *.sql to support custom table prefixes)
  local sql_count
  sql_count=$(find "$backup_id_dir" -maxdepth 1 -type f -name "*.sql" 2>/dev/null | wc -l)
  if [[ $sql_count -lt 5 ]]; then
    return 1
  fi

  # Consolidate all SQL files into a single database dump
  local consolidated_file="$extract_dir/solidbackups-database-consolidated.sql"
  if ! adapter_solidbackups_consolidate_database "$backup_id_dir" "$consolidated_file"; then
    return 1
  fi

  echo "$consolidated_file"
  return 0
}

# Find wp-content directory in extracted Solid Backups archive
# Usage: adapter_solidbackups_find_content <extract_dir>
# Returns: 0 and echoes path if found, 1 if not found
adapter_solidbackups_find_content() {
  local extract_dir="$1"
  local wp_content_dir

  # Solid Backups stores wp-content at root level of extracted WordPress
  # Try direct path first
  if [[ -d "$extract_dir/wp-content" ]]; then
    wp_content_dir="$extract_dir/wp-content"
  else
    # Fallback: Use base helper to find best wp-content directory
    wp_content_dir=$(adapter_base_find_best_wp_content "$extract_dir")
  fi

  if [[ -z "$wp_content_dir" ]]; then
    return 1
  fi

  echo "$wp_content_dir"
  return 0
}

# Consolidate Solid Backups SQL files into single database dump
# Usage: adapter_solidbackups_consolidate_database <sql_dir> <output_file>
# Returns: 0 on success, 1 on failure
adapter_solidbackups_consolidate_database() {
  local sql_dir="$1" output_file="$2"

  # Find all SQL files and concatenate them (Bash 3.2 + BSD compatible)
  # Use *.sql pattern to support custom table prefixes (e.g., abc123_options.sql)
  # Collect files into array, then sort (BSD sort doesn't support -z)
  local sql_files=()
  while IFS= read -r -d '' file; do
    sql_files+=("$file")
  done < <(find "$sql_dir" -maxdepth 1 -type f -name "*.sql" -print0 2>/dev/null)

  if [[ ${#sql_files[@]} -eq 0 ]]; then
    return 1
  fi

  # Sort the array using Bash built-in sorting (works on all platforms)
  # Read sorted output back into array (ShellCheck compliant)
  local sorted_files
  sorted_files=$(printf '%s\n' "${sql_files[@]}" | sort)
  sql_files=()
  while IFS= read -r file; do
    sql_files+=("$file")
  done <<<"$sorted_files"

  # Concatenate all SQL files into output file
  : > "$output_file"  # Create/truncate output file
  for sql_file in "${sql_files[@]}"; do
    cat "$sql_file" >> "$output_file"
    echo "" >> "$output_file"  # Add newline between files
  done

  return 0
}

# Get human-readable format name
# Usage: adapter_solidbackups_get_name
# Returns: Format name string
adapter_solidbackups_get_name() {
  echo "Solid Backups"
}

# Get required dependencies for this adapter
# Usage: adapter_solidbackups_get_dependencies
# Returns: Space-separated list of required commands
adapter_solidbackups_get_dependencies() {
  echo "unzip file"
}
wp_local() {
  log_trace "wp --path=\"$PWD\" $*"
  wp --path="$PWD" "$@"
}

# ========================================
# Archive Adapter System
# ========================================

# List of available adapters (add new adapters here)
AVAILABLE_ADAPTERS=("duplicator" "jetpack" "solidbackups")

# Verify adapter exists (adapter functions already loaded in built script)
# Usage: load_adapter <adapter_name>
# Returns: 0 if adapter functions exist, 1 if not found
load_adapter() {
  local adapter_name="$1"

  # In the built script, all adapter functions are already defined via concatenation
  # Just verify the adapter's validate function exists
  if declare -f "adapter_${adapter_name}_validate" >/dev/null 2>&1; then
    return 0
  fi

  return 1
}

# Detect which adapter can handle the given archive
# Usage: detect_adapter <archive_path>
# Returns: echoes adapter name if detected, returns 1 if no match
detect_adapter() {
  local archive="$1"
  local adapter

  log_verbose "Detecting archive format for: $(basename "$archive")"

  # Try each available adapter's validate function (already loaded in built script)
  for adapter in "${AVAILABLE_ADAPTERS[@]}"; do
    log_verbose "  Testing: ${adapter} adapter..."
    # Call the adapter's validate function
    if "adapter_${adapter}_validate" "$archive" 2>/dev/null; then
      log_verbose "    ✓ Matched ${adapter} format"
      echo "$adapter"
      return 0
    else
      log_verbose "    ✗ Not a ${adapter} archive"
    fi
  done

  return 1
}

# Wrapper functions that call the appropriate adapter function
# These provide a consistent interface regardless of which adapter is loaded

extract_archive() {
  local archive="$1" dest="$2"
  "adapter_${ARCHIVE_ADAPTER}_extract" "$archive" "$dest"
}

find_archive_database() {
  local extract_dir="$1"
  "adapter_${ARCHIVE_ADAPTER}_find_database" "$extract_dir"
}

find_archive_wp_content() {
  local extract_dir="$1"
  "adapter_${ARCHIVE_ADAPTER}_find_content" "$extract_dir"
}

get_archive_format_name() {
  "adapter_${ARCHIVE_ADAPTER}_get_name"
}

# Check and verify required dependencies for an adapter
# Usage: check_adapter_dependencies <adapter_name>
# Returns: 0 if all dependencies available, 1 otherwise
check_adapter_dependencies() {
  local adapter="$1"

  # Check if adapter has a dependencies function
  if declare -f "adapter_${adapter}_get_dependencies" >/dev/null 2>&1; then
    local deps
    deps=$("adapter_${adapter}_get_dependencies")

    # Check each dependency
    local dep
    for dep in $deps; do
      if ! command -v "$dep" >/dev/null 2>&1; then
        err "Missing dependency for $adapter adapter: $dep"
        # shellcheck disable=SC2317  # err() exits script, but shellcheck doesn't know
        return 1
      fi
    done
  fi

  return 0
}

# ========================================
# End Archive Adapter System
# ========================================

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
  log_trace "ssh ${SSH_OPTS[*]} $host $*"
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
  log_trace "ssh ${SSH_OPTS[*]} $host \"bash -lc 'cd $root_quoted && ${cmd_quoted% }'\""
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
  if [[ "$MIGRATION_MODE" == "archive" ]]; then
    # Only cleanup on success; keep files on failure for debugging
    if [[ $status -eq 0 ]]; then
      cleanup_archive_temp
    elif [[ -n "$ARCHIVE_EXTRACT_DIR" && -d "$ARCHIVE_EXTRACT_DIR" ]]; then
      log "Keeping extraction directory for debugging: $ARCHIVE_EXTRACT_DIR"
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

check_disk_space_for_archive() {
  local archive_path="$1"
  local archive_size_bytes
  local available_bytes
  local required_bytes

  log_verbose "Calculating archive size..."
  archive_size_bytes=$(stat -f%z "$archive_path" 2>/dev/null || stat -c%s "$archive_path" 2>/dev/null)
  [[ -n "$archive_size_bytes" ]] || err "Unable to determine archive size: $archive_path

Next steps:
  1. Verify file exists and is readable:
       ls -lh \"$archive_path\"
  2. Check file permissions:
       stat \"$archive_path\"
  3. Ensure you have read access to the file"

  # Need 3x archive size: 1x for archive, 1x for extraction, 1x buffer
  required_bytes=$((archive_size_bytes * 3))
  log_verbose "  Archive size: $archive_size_bytes bytes"
  log_verbose "  Required space: $required_bytes bytes (3x multiplier for safe extraction)"

  # Check available space in current directory
  log_verbose "Checking available disk space..."
  available_bytes=$(df -P . | awk 'NR==2 {print $4 * 1024}')
  log_verbose "  Available: $available_bytes bytes"

  local archive_size_mb=$((archive_size_bytes / 1024 / 1024))
  local required_mb=$((required_bytes / 1024 / 1024))
  local available_mb=$((available_bytes / 1024 / 1024))

  log "Disk space check:"
  log "  Archive size: ${archive_size_mb}MB"
  log "  Required: ${required_mb}MB (3x archive size)"
  log "  Available: ${available_mb}MB"

  if [[ $available_bytes -lt $required_bytes ]]; then
    err "Insufficient disk space for archive extraction.

Archive size: ${archive_size_mb}MB
Required space: ${required_mb}MB (3x archive size for safe extraction)
Available space: ${available_mb}MB
Shortfall: $((required_mb - available_mb))MB

Why 3x? Archive extraction needs:
  1. Original archive (${archive_size_mb}MB)
  2. Extracted files (${archive_size_mb}MB)
  3. Safety buffer (${archive_size_mb}MB)

Next steps:
  1. Free up disk space:
       df -h .
       # Delete old backups, logs, or temporary files
  2. Move archive to a location with more space:
       # Check space on other volumes/partitions
       df -h
  3. Use a smaller working directory (if archive is very large):
       export TMPDIR=/path/to/large/volume
  4. Clean up WordPress uploads or other large files temporarily"
  fi

  log "Disk space check: PASSED"
}

extract_archive_to_temp() {
  local archive_path="$1"

  if $DRY_RUN; then
    log "[dry-run] Would extract archive to temporary directory"
    ARCHIVE_EXTRACT_DIR="/tmp/wp-migrate-archive-XXXXXX-dryrun"
    return 0
  fi

  ARCHIVE_EXTRACT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/wp-migrate-archive-XXXXXX")"
  log "Extracting archive to: $ARCHIVE_EXTRACT_DIR"

  # Use the adapter's extract function
  if ! extract_archive "$archive_path" "$ARCHIVE_EXTRACT_DIR"; then
    rm -rf "$ARCHIVE_EXTRACT_DIR"
    local format_name
    format_name=$(get_archive_format_name)
    err "Failed to extract $format_name archive: $archive_path

Possible causes:
  • Archive file is corrupted
  • Incorrect archive format (try --archive-type to force format)
  • Insufficient disk space during extraction
  • Missing extraction tools (unzip, tar, gzip)

Next steps:
  1. Verify archive integrity:
       file \"$archive_path\"
       # For ZIP: unzip -t \"$archive_path\"
       # For tar.gz: tar -tzf \"$archive_path\" >/dev/null
  2. Check available disk space:
       df -h .
  3. Verify extraction tools are installed:
       which unzip tar gzip
  4. Try extracting manually to see detailed error:
       unzip -t \"$archive_path\"  # for ZIP
       tar -xzf \"$archive_path\"  # for tar.gz
  5. If format detection failed, specify type explicitly:
       --archive-type duplicator  # or jetpack"
  fi

  log "Archive extracted successfully"
}

find_archive_database_file() {
  local extract_dir="$1"

  if $DRY_RUN; then
    log "[dry-run] Would search for database file using $(get_archive_format_name) adapter"
    ARCHIVE_DB_FILE="$extract_dir/database-example.sql"
    return 0
  fi

  # Use the adapter's find database function
  # Capture exit status to prevent set -e from killing script before error message
  local db_file
  if ! db_file=$(find_archive_database "$extract_dir"); then
    local format_name
    format_name=$(get_archive_format_name)
    err "Unable to locate database file in $format_name archive.

Archive extracted to: $extract_dir

Expected database file patterns for $format_name:
$([ "$format_name" = "Duplicator" ] && echo "  • dup-installer/dup-database__*.sql")
$([ "$format_name" = "Jetpack Backup" ] && echo "  • sql/*.sql (multiple files)")
$([ "$format_name" = "Solid Backups" ] && echo "  • wp-content/uploads/backupbuddy_temp/*/*.sql")

Next steps:
  1. Inspect extracted archive contents:
       ls -laR \"$extract_dir\"
  2. Look for SQL files manually:
       find \"$extract_dir\" -name \"*.sql\" -type f
  3. Verify this is a complete $format_name backup (not partial)
  4. If using wrong adapter, try specifying format:
       --archive-type duplicator
       --archive-type jetpack
       --archive-type solidbackups
  5. Check if archive was created correctly by backup plugin"
  fi

  if [[ -z "$db_file" ]]; then
    local format_name
    format_name=$(get_archive_format_name)
    err "Unable to locate database file in $format_name archive.

Archive extracted to: $extract_dir

Database file search returned empty result. This may indicate:
  • Incomplete backup archive
  • Corrupted archive structure
  • Wrong archive adapter for this backup format

Next steps:
  1. Search for SQL files manually:
       find \"$extract_dir\" -name \"*.sql\"
  2. Verify archive completeness"
  fi

  ARCHIVE_DB_FILE="$db_file"
  log "Found database file: $(basename "$ARCHIVE_DB_FILE")"
}

find_archive_wp_content_dir() {
  local extract_dir="$1"

  if $DRY_RUN; then
    log "[dry-run] Would auto-detect wp-content directory using $(get_archive_format_name) adapter"
    ARCHIVE_WP_CONTENT="$extract_dir/wp-content"
    return 0
  fi

  # Use the adapter's find wp-content function
  # Capture exit status to prevent set -e from killing script before error message
  local wp_content_dir
  if ! wp_content_dir=$(find_archive_wp_content "$extract_dir"); then
    local format_name
    format_name=$(get_archive_format_name)
    err "Unable to locate wp-content directory in $format_name archive.

Archive extracted to: $extract_dir

wp-content should contain subdirectories like:
  • plugins/
  • themes/
  • uploads/

Next steps:
  1. Inspect extracted archive structure:
       ls -laR \"$extract_dir\"
  2. Look for wp-content manually:
       find \"$extract_dir\" -type d -name \"wp-content\"
  3. Verify this is a complete WordPress backup
  4. If backup only contains database, you may need to migrate wp-content separately:
       # Use push mode to sync wp-content from another server
  5. Check if archive was created correctly by backup plugin"
  fi

  if [[ -z "$wp_content_dir" ]]; then
    local format_name
    format_name=$(get_archive_format_name)
    err "Unable to locate wp-content directory in $format_name archive.

Archive extracted to: $extract_dir

wp-content directory search returned empty result. This may indicate:
  • Database-only backup (no files included)
  • Incomplete backup archive
  • Non-standard WordPress directory structure

Next steps:
  1. Search for common WordPress directories:
       find \"$extract_dir\" -type d -name \"plugins\" -o -name \"themes\" -o -name \"uploads\"
  2. If this is a database-only backup, skip --archive mode and use push mode instead
  3. Contact backup plugin support if structure is unexpected"
  fi

  ARCHIVE_WP_CONTENT="$wp_content_dir"
  log "Found wp-content directory: ${ARCHIVE_WP_CONTENT#"$extract_dir"/}"
  log "  Contains: plugins=$([ -d "$ARCHIVE_WP_CONTENT/plugins" ] && echo "YES" || echo "NO") themes=$([ -d "$ARCHIVE_WP_CONTENT/themes" ] && echo "YES" || echo "NO") uploads=$([ -d "$ARCHIVE_WP_CONTENT/uploads" ] && echo "YES" || echo "NO")"
}

cleanup_archive_temp() {
  [[ -z "$ARCHIVE_EXTRACT_DIR" ]] && return 0
  [[ ! -d "$ARCHIVE_EXTRACT_DIR" ]] && return 0

  if $DRY_RUN; then
    log "[dry-run] Would remove temporary extraction directory"
    return 0
  fi

  log "Cleaning up temporary extraction directory..."
  if ! rm -rf "$ARCHIVE_EXTRACT_DIR" 2>/dev/null; then
    log_warning "Failed to remove temporary extraction directory: $ARCHIVE_EXTRACT_DIR. You may need to manually delete it."
  fi
}

# Compute array difference: items in arr1 NOT in arr2
# Usage: array_diff result_var arr1_name arr2_name
# Note: Bash 3.2 compatible (no namerefs)
array_diff() {
  local result_var="$1"
  local arr1_name="$2"
  local arr2_name="$3"

  # Clear result array
  eval "$result_var=()"

  local item found check

  # Get array1 elements via eval (shellcheck can't track dynamic assignment)
  eval "local arr1_items=(\"\${${arr1_name}[@]}\")"
  eval "local arr2_items=(\"\${${arr2_name}[@]}\")"

  # For each item in arr1, check if it exists in arr2
  # shellcheck disable=SC2154  # arr1_items/arr2_items assigned via eval
  for item in "${arr1_items[@]}"; do
    found=false
    for check in "${arr2_items[@]}"; do
      if [[ "$item" == "$check" ]]; then
        found=true
        break
      fi
    done

    # If not found in arr2, add to result
    if ! $found; then
      eval "$result_var+=(\"\$item\")"
    fi
  done
}

# Detect plugins on destination (before migration)
detect_dest_plugins_push() {
  local host="$1" root="$2"
  if $DRY_RUN; then
    log "[dry-run] Would detect destination plugins via wp plugin list"
    return 0
  fi

  local plugins_csv plugin
  plugins_csv=$(wp_remote "$host" "$root" plugin list --field=name --format=csv 2>/dev/null || echo "")
  if [[ -n "$plugins_csv" ]]; then
    DEST_PLUGINS_BEFORE=()
    while IFS= read -r plugin; do
      [[ -n "$plugin" ]] && DEST_PLUGINS_BEFORE+=("$plugin")
    done < <(echo "$plugins_csv" | tr ',' '\n')
  fi
}

# Detect themes on destination (before migration)
detect_dest_themes_push() {
  local host="$1" root="$2"
  if $DRY_RUN; then
    log "[dry-run] Would detect destination themes via wp theme list"
    return 0
  fi

  local themes_csv theme
  themes_csv=$(wp_remote "$host" "$root" theme list --field=name --format=csv 2>/dev/null || echo "")
  if [[ -n "$themes_csv" ]]; then
    DEST_THEMES_BEFORE=()
    while IFS= read -r theme; do
      [[ -n "$theme" ]] && DEST_THEMES_BEFORE+=("$theme")
    done < <(echo "$themes_csv" | tr ',' '\n')
  fi
}

# Detect plugins in source (push mode)
detect_source_plugins() {
  if $DRY_RUN; then
    log "[dry-run] Would detect source plugins via wp plugin list"
    return 0
  fi

  local plugins_csv plugin
  plugins_csv=$(wp_local plugin list --field=name --format=csv 2>/dev/null || echo "")
  if [[ -n "$plugins_csv" ]]; then
    SOURCE_PLUGINS=()
    while IFS= read -r plugin; do
      [[ -n "$plugin" ]] && SOURCE_PLUGINS+=("$plugin")
    done < <(echo "$plugins_csv" | tr ',' '\n')
  fi
}

# Detect themes in source (push mode)
detect_source_themes() {
  if $DRY_RUN; then
    log "[dry-run] Would detect source themes via wp theme list"
    return 0
  fi

  local themes_csv theme
  themes_csv=$(wp_local theme list --field=name --format=csv 2>/dev/null || echo "")
  if [[ -n "$themes_csv" ]]; then
    SOURCE_THEMES=()
    while IFS= read -r theme; do
      [[ -n "$theme" ]] && SOURCE_THEMES+=("$theme")
    done < <(echo "$themes_csv" | tr ',' '\n')
  fi
}

# Detect plugins on destination (duplicator mode - before migration)
detect_dest_plugins_local() {
  if $DRY_RUN; then
    log "[dry-run] Would detect destination plugins via wp plugin list"
    return 0
  fi

  local plugins_csv plugin
  plugins_csv=$(wp_local plugin list --field=name --format=csv 2>/dev/null || echo "")
  if [[ -n "$plugins_csv" ]]; then
    DEST_PLUGINS_BEFORE=()
    while IFS= read -r plugin; do
      [[ -n "$plugin" ]] && DEST_PLUGINS_BEFORE+=("$plugin")
    done < <(echo "$plugins_csv" | tr ',' '\n')
  fi
}

# Detect themes on destination (duplicator mode - before migration)
detect_dest_themes_local() {
  if $DRY_RUN; then
    log "[dry-run] Would detect destination themes via wp theme list"
    return 0
  fi

  local themes_csv theme
  themes_csv=$(wp_local theme list --field=name --format=csv 2>/dev/null || echo "")
  if [[ -n "$themes_csv" ]]; then
    DEST_THEMES_BEFORE=()
    while IFS= read -r theme; do
      [[ -n "$theme" ]] && DEST_THEMES_BEFORE+=("$theme")
    done < <(echo "$themes_csv" | tr ',' '\n')
  fi
}

# Detect plugins in archive (duplicator mode)
detect_archive_plugins() {
  local wp_content_path="$1"
  if $DRY_RUN; then
    log "[dry-run] Would scan archive for plugins"
    return 0
  fi

  if [[ ! -d "$wp_content_path/plugins" ]]; then
    return 0
  fi

  local plugin
  while IFS= read -r -d '' plugin_dir; do
    plugin=$(basename "$plugin_dir")
    SOURCE_PLUGINS+=("$plugin")
  done < <(find "$wp_content_path/plugins" -maxdepth 1 -mindepth 1 -type d -print0)
}

# Detect themes in archive (duplicator mode)
detect_archive_themes() {
  local wp_content_path="$1"
  if $DRY_RUN; then
    log "[dry-run] Would scan archive for themes"
    return 0
  fi

  if [[ ! -d "$wp_content_path/themes" ]]; then
    return 0
  fi

  local theme
  while IFS= read -r -d '' theme_dir; do
    theme=$(basename "$theme_dir")
    SOURCE_THEMES+=("$theme")
  done < <(find "$wp_content_path/themes" -maxdepth 1 -mindepth 1 -type d -print0)
}

# Restore unique destination plugins/themes (push mode)
restore_dest_content_push() {
  local host="$1" root="$2" backup_path="$3"

  if [[ ${#UNIQUE_DEST_PLUGINS[@]} -eq 0 && ${#UNIQUE_DEST_THEMES[@]} -eq 0 ]]; then
    return 0
  fi

  log "Restoring destination plugins/themes not in source..."

  # Restore plugins
  if [[ ${#UNIQUE_DEST_PLUGINS[@]} -gt 0 ]]; then
    log "  Restoring ${#UNIQUE_DEST_PLUGINS[@]} unique destination plugin(s)..."
    for plugin in "${UNIQUE_DEST_PLUGINS[@]}"; do
      if $DRY_RUN; then
        log "[dry-run]   Would restore plugin: $plugin"
      else
        log "    Restoring plugin: $plugin"
        ssh_run "$host" "cp -a \"$backup_path/plugins/$plugin\" \"$(discover_wp_content_remote "$host" "$root")/plugins/\" 2>/dev/null" || {
          log_warning "Failed to restore plugin: $plugin"
        }
      fi
    done

    # Deactivate restored plugins
    if ! $DRY_RUN; then
      log "  Deactivating restored plugins..."
      for plugin in "${UNIQUE_DEST_PLUGINS[@]}"; do
        if wp_remote "$host" "$root" plugin deactivate "$plugin" 2>/dev/null; then
          log "    Deactivated: $plugin"
        else
          log_warning "Could not deactivate plugin: $plugin"
        fi
      done
    fi
  fi

  # Restore themes
  if [[ ${#UNIQUE_DEST_THEMES[@]} -gt 0 ]]; then
    log "  Restoring ${#UNIQUE_DEST_THEMES[@]} unique destination theme(s)..."
    for theme in "${UNIQUE_DEST_THEMES[@]}"; do
      if $DRY_RUN; then
        log "[dry-run]   Would restore theme: $theme"
      else
        log "    Restoring theme: $theme"
        ssh_run "$host" "cp -a \"$backup_path/themes/$theme\" \"$(discover_wp_content_remote "$host" "$root")/themes/\" 2>/dev/null" || {
          log_warning "Failed to restore theme: $theme"
        }
      fi
    done
  fi
}

# Restore unique destination plugins/themes (duplicator mode)
restore_dest_content_local() {
  local backup_path="$1"

  if [[ ${#UNIQUE_DEST_PLUGINS[@]} -eq 0 && ${#UNIQUE_DEST_THEMES[@]} -eq 0 ]]; then
    return 0
  fi

  log "Restoring destination plugins/themes not in source..."

  # Restore plugins
  if [[ ${#UNIQUE_DEST_PLUGINS[@]} -gt 0 ]]; then
    log "  Restoring ${#UNIQUE_DEST_PLUGINS[@]} unique destination plugin(s)..."
    for plugin in "${UNIQUE_DEST_PLUGINS[@]}"; do
      if $DRY_RUN; then
        log "[dry-run]   Would restore plugin: $plugin"
      else
        log "    Restoring plugin: $plugin"
        cp -a "$backup_path/plugins/$plugin" "$DEST_WP_CONTENT/plugins/" 2>/dev/null || {
          log_warning "Failed to restore plugin: $plugin"
        }
      fi
    done

    # Deactivate restored plugins
    if ! $DRY_RUN; then
      log "  Deactivating restored plugins..."
      for plugin in "${UNIQUE_DEST_PLUGINS[@]}"; do
        if wp_local plugin deactivate "$plugin" 2>/dev/null; then
          log "    Deactivated: $plugin"
        else
          log_warning "Could not deactivate plugin: $plugin"
        fi
      done
    fi
  fi

  # Restore themes
  if [[ ${#UNIQUE_DEST_THEMES[@]} -gt 0 ]]; then
    log "  Restoring ${#UNIQUE_DEST_THEMES[@]} unique destination theme(s)..."
    for theme in "${UNIQUE_DEST_THEMES[@]}"; do
      if $DRY_RUN; then
        log "[dry-run]   Would restore theme: $theme"
      else
        log "    Restoring theme: $theme"
        cp -a "$backup_path/themes/$theme" "$DEST_WP_CONTENT/themes/" 2>/dev/null || {
          log_warning "Failed to restore theme: $theme"
        }
      fi
    done
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

ARCHIVE MODE (run on DESTINATION WP root):
  $(basename "$0") --archive </path/to/backup> [options]

Required (choose one mode):
  --dest-host <user@dest.example.com>
  --dest-root </absolute/path/to/destination/wp-root>
      Push mode: migrate from current host to destination via SSH

  --archive </path/to/backup>
      Archive mode: import backup archive to current host
      Supported formats: Duplicator, Jetpack Backup, Solid Backups/BackupBuddy
      (mutually exclusive with --dest-host)

  --archive-type <type>
      Optional: Specify archive format (duplicator, jetpack, solidbackups)
      If not specified, format will be auto-detected

  --duplicator-archive </path/to/backup.zip>
      Deprecated: Use --archive instead (backward compatibility maintained)

Options:
  --dry-run                 Preview rsync; DB export/transfer is also previewed (no dump created)
  --verbose                 Show additional details (dependency checks, command construction, detection process)
  --trace                   Show every command before execution (implies --verbose). Useful for debugging and reproducing issues.
  --import-db               (Deprecated) Explicitly import the DB on destination (default behavior)
  --no-import-db            Skip importing the DB on destination after transfer
  --no-search-replace       Skip URL search-replace after DB import (useful when destination domain should remain unchanged)
  --no-gzip                 Don't gzip the DB dump (default is gzip on, push mode only)
  --no-maint-source         Skip enabling maintenance mode on the source site (push mode only)
  --stellarsites            Enable StellarSites compatibility mode (preserves protected mu-plugins, auto-enables --preserve-dest-plugins)
  --preserve-dest-plugins   Preserve destination plugins/themes not in source (restored but deactivated after migration)
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

Examples (archive mode):
  $(basename "$0") --archive /path/to/backup_20251009.zip
  $(basename "$0") --archive /backups/site.zip --dry-run
  $(basename "$0") --archive /backups/site.zip --stellarsites
  $(basename "$0") --archive /backups/site.tar.gz --archive-type jetpack
USAGE
}

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
