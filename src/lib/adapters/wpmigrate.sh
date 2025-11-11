# shellcheck shell=bash
# -----------------------
# wp-migrate Backup Adapter
# -----------------------
# Handles wp-migrate native backup archives (.zip format)
#
# Archive Structure:
#   - Format: ZIP
#   - Metadata: wpmigrate-backup.json (signature file)
#   - Database: database.sql
#   - wp-content: wp-content/ directory

# Validate if this archive is a wp-migrate backup
# Usage: adapter_wpmigrate_validate <archive_path>
# Returns: 0 if valid wp-migrate archive, 1 otherwise
# Sets: ADAPTER_VALIDATION_ERRORS array with failure reasons on error
adapter_wpmigrate_validate() {
  local archive="$1"
  local errors=()

  # Check file exists
  if [[ ! -f "$archive" ]]; then
    errors+=("File does not exist")
    ADAPTER_VALIDATION_ERRORS+=("wp-migrate: ${errors[*]}")
    return 1
  fi

  # Check if it's a ZIP file
  local archive_type
  archive_type=$(adapter_base_get_archive_type "$archive")
  if [[ "$archive_type" != "zip" ]]; then
    errors+=("Not a ZIP archive (found: $archive_type)")
    ADAPTER_VALIDATION_ERRORS+=("wp-migrate: ${errors[*]}")
    return 1
  fi

  # Check for wp-migrate signature file (wpmigrate-backup.json)
  if ! adapter_base_archive_contains "$archive" "wpmigrate-backup.json"; then
    errors+=("Missing wpmigrate-backup.json signature file")
    ADAPTER_VALIDATION_ERRORS+=("wp-migrate: ${errors[*]}")
    return 1
  fi

  # Validate JSON structure
  if ! unzip -p "$archive" "wpmigrate-backup.json" 2>/dev/null | jq -e '.format_version' >/dev/null 2>&1; then
    errors+=("Invalid or missing format_version in metadata")
    ADAPTER_VALIDATION_ERRORS+=("wp-migrate: ${errors[*]}")
    return 1
  fi

  return 0
}

# Extract wp-migrate archive
# Usage: adapter_wpmigrate_extract <archive_path> <dest_dir>
# Returns: 0 on success, 1 on failure
adapter_wpmigrate_extract() {
  local archive="$1" dest="$2"

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

# Find database file in extracted wp-migrate archive
# Usage: adapter_wpmigrate_find_database <extract_dir>
# Returns: 0 and echoes path if found, 1 if not found
adapter_wpmigrate_find_database() {
  local extract_dir="$1"
  local db_file="$extract_dir/database.sql"

  if [[ ! -f "$db_file" ]]; then
    return 1
  fi

  echo "$db_file"
  return 0
}

# Find wp-content directory in extracted wp-migrate archive
# Usage: adapter_wpmigrate_find_content <extract_dir>
# Returns: 0 and echoes path if found, 1 if not found
adapter_wpmigrate_find_content() {
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
# Usage: adapter_wpmigrate_get_name
# Returns: Format name string
adapter_wpmigrate_get_name() {
  echo "wp-migrate Backup"
}

# Get required dependencies for this adapter
# Usage: adapter_wpmigrate_get_dependencies
# Returns: Space-separated list of required commands
adapter_wpmigrate_get_dependencies() {
  echo "unzip file jq"
}
