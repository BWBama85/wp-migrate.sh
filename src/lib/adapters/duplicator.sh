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
# Sets: ADAPTER_VALIDATION_ERRORS array with failure reasons on error
adapter_duplicator_validate() {
  local archive="$1"
  local errors=()

  # Check file exists
  if [[ ! -f "$archive" ]]; then
    errors+=("File does not exist")
    ADAPTER_VALIDATION_ERRORS+=("Duplicator: ${errors[*]}")
    return 1
  fi

  # Check if it's a ZIP file
  local archive_type
  archive_type=$(adapter_base_get_archive_type "$archive")
  if [[ "$archive_type" != "zip" ]]; then
    errors+=("Not a ZIP archive (found: $archive_type)")
    ADAPTER_VALIDATION_ERRORS+=("Duplicator: ${errors[*]}")
    return 1
  fi

  # Check for Duplicator signature file (installer.php)
  if adapter_base_archive_contains "$archive" "installer.php"; then
    return 0
  fi

  # Fallback: Check for database file pattern
  if adapter_base_archive_contains "$archive" "dup-installer/dup-database__"; then
    return 0
  fi

  errors+=("Missing installer.php and dup-installer/dup-database__ pattern")
  ADAPTER_VALIDATION_ERRORS+=("Duplicator: ${errors[*]}")
  return 1
}

# Extract Duplicator archive
# Usage: adapter_duplicator_extract <archive_path> <dest_dir>
# Returns: 0 on success, 1 on failure
# Note: Security validation is performed by validate_archive_paths() before extraction
adapter_duplicator_extract() {
  local archive="$1" dest="$2"
  adapter_base_extract_zip "$archive" "$dest"
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
