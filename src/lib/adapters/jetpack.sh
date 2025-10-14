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
    if ! cp -a "$archive"/. "$dest"/ 2>/dev/null; then
      return 1
    fi
    return 0
  fi

  # Extract based on archive type
  local archive_type
  archive_type=$(adapter_base_get_archive_type "$archive")

  if [[ "$archive_type" == "zip" ]]; then
    if ! unzip -q "$archive" -d "$dest" 2>/dev/null; then
      return 1
    fi
  elif [[ "$archive_type" == "tar.gz" ]]; then
    if ! tar -xzf "$archive" -C "$dest" 2>/dev/null; then
      return 1
    fi
  elif [[ "$archive_type" == "tar" ]]; then
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
