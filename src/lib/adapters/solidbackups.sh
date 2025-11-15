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
# Sets: ADAPTER_VALIDATION_ERRORS array with failure reasons on error
adapter_solidbackups_validate() {
  local archive="$1"
  local errors=()

  # Handle both archives and extracted directories
  if [[ -d "$archive" ]]; then
    # Already extracted directory - check for backupbuddy_temp structure
    if [[ ! -d "$archive/wp-content/uploads/backupbuddy_temp" ]]; then
      errors+=("Extracted dir missing wp-content/uploads/backupbuddy_temp/")
      ADAPTER_VALIDATION_ERRORS+=("Solid Backups: ${errors[*]}")
      return 1
    fi

    # Look for importbuddy.php signature file in any subdirectory
    if find "$archive/wp-content/uploads/backupbuddy_temp" -maxdepth 2 -type f -name "importbuddy.php" 2>/dev/null | grep -q .; then
      return 0
    fi

    # Fallback: Check for backupbuddy_dat.php (importbuddy is often downloaded separately)
    if find "$archive/wp-content/uploads/backupbuddy_temp" -maxdepth 2 -type f -name "backupbuddy_dat.php" 2>/dev/null | grep -q .; then
      return 0
    fi

    errors+=("Missing importbuddy.php or backupbuddy_dat.php in backupbuddy_temp/")
    ADAPTER_VALIDATION_ERRORS+=("Solid Backups: ${errors[*]}")
    return 1
  fi

  # Check file exists
  if [[ ! -f "$archive" ]]; then
    errors+=("File does not exist")
    ADAPTER_VALIDATION_ERRORS+=("Solid Backups: ${errors[*]}")
    return 1
  fi

  # Check if it's a ZIP file
  local archive_type
  archive_type=$(adapter_base_get_archive_type "$archive")
  if [[ "$archive_type" != "zip" ]]; then
    errors+=("Not a ZIP archive (found: $archive_type)")
    ADAPTER_VALIDATION_ERRORS+=("Solid Backups: ${errors[*]}")
    return 1
  fi

  # Check for Solid Backups signature: importbuddy.php in backupbuddy_temp
  if adapter_base_archive_contains "$archive" "backupbuddy_temp.*importbuddy.php"; then
    return 0
  fi

  # Fallback: Check for backupbuddy_dat.php
  if adapter_base_archive_contains "$archive" "backupbuddy_temp.*backupbuddy_dat.php"; then
    return 0
  fi

  errors+=("Missing backupbuddy_temp/ with importbuddy.php or backupbuddy_dat.php")
  ADAPTER_VALIDATION_ERRORS+=("Solid Backups: ${errors[*]}")
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
  # Try bsdtar with progress if available (supports stdin)
  if ! $QUIET_MODE && has_pv && [[ -t 1 ]] && command -v bsdtar >/dev/null 2>&1; then
    log_trace "pv \"$archive\" | bsdtar -xf - -C \"$dest\""
    local archive_size
    archive_size=$(stat -f%z "$archive" 2>/dev/null || stat -c%s "$archive" 2>/dev/null)
    if ! pv -N "Extracting archive" -s "$archive_size" "$archive" | bsdtar -xf - -C "$dest" 2>/dev/null; then
      return 1
    fi
  else
    # Fallback to unzip (no progress - unzip doesn't support stdin)
    log_trace "unzip -q \"$archive\" -d \"$dest\""
    if ! unzip -q "$archive" -d "$dest" 2>/dev/null; then
      return 1
    fi
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
# Note: Delegates to shared adapter_base_consolidate_database (Issue #88-1)
adapter_solidbackups_consolidate_database() {
  local sql_dir="$1" output_file="$2"

  # Use shared consolidation function (maxdepth 1, no verbose logging)
  adapter_base_consolidate_database "$sql_dir" "$output_file" "1"
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
