# -----------------------
# Solid Backups NextGen Archive Adapter
# -----------------------
# Handles Solid Backups NextGen archives (.zip format)
# This is the NEW version of Solid Backups - a complete rewrite from Solid Backups Legacy
#
# Archive Structure:
#   - Format: ZIP containing organized WordPress backup
#   - Database: data/{PREFIX}_*.sql (multiple files, one per table, in dedicated data/ directory)
#   - Files: files/ directory containing WordPress installation
#   - wp-content: files/wp-content/ OR files/subdomains/{site}/wp-content/
#   - Metadata: meta/started.txt, meta/wpversion.txt
#   - NO signature files (importbuddy.php, backupbuddy_dat.php do NOT exist in NextGen)
#   - Prefix: Random hash prefix (e.g., tkI5z3G_options.sql)
#
# Key Differences from Legacy:
#   - Database in top-level data/ directory instead of wp-content/uploads/backupbuddy_temp/
#   - Files in top-level files/ directory instead of root
#   - Metadata in dedicated meta/ directory
#   - NO importbuddy.php or backupbuddy_dat.php signature files
#   - Multisite support with files/subdomains/ structure

# Validate if this archive is a Solid Backups NextGen backup
# Usage: adapter_solidbackups_nextgen_validate <archive_path>
# Returns: 0 if valid Solid Backups NextGen archive, 1 otherwise
# Sets: ADAPTER_VALIDATION_ERRORS array with failure reasons on error
adapter_solidbackups_nextgen_validate() {
  local archive="$1"
  local errors=()

  # Handle both archives and extracted directories
  if [[ -d "$archive" ]]; then
    # Already extracted directory - check for NextGen structure

    # Check for data/ directory (required - contains database files)
    if [[ ! -d "$archive/data" ]]; then
      errors+=("Missing data/ directory (NextGen stores database here)")
      ADAPTER_VALIDATION_ERRORS+=("Solid Backups NextGen: ${errors[*]}")
      return 1
    fi

    # Check for files/ directory (required - contains WordPress files)
    if [[ ! -d "$archive/files" ]]; then
      errors+=("Missing files/ directory (NextGen stores WordPress files here)")
      ADAPTER_VALIDATION_ERRORS+=("Solid Backups NextGen: ${errors[*]}")
      return 1
    fi

    # Verify data/ contains SQL files
    local sql_count
    sql_count=$(find "$archive/data" -maxdepth 1 -type f -name "*.sql" 2>/dev/null | wc -l)
    if [[ $sql_count -lt 5 ]]; then
      errors+=("data/ directory contains insufficient SQL files (found: $sql_count, need: 5+)")
      ADAPTER_VALIDATION_ERRORS+=("Solid Backups NextGen: ${errors[*]}")
      return 1
    fi

    # Optional: Check for meta/ directory (nice to have but not required for validation)
    if [[ -d "$archive/meta" ]]; then
      log_verbose "  Found meta/ directory with backup metadata"
    fi

    return 0
  fi

  # Check file exists
  if [[ ! -f "$archive" ]]; then
    errors+=("File does not exist")
    ADAPTER_VALIDATION_ERRORS+=("Solid Backups NextGen: ${errors[*]}")
    return 1
  fi

  # Check if it's a ZIP file
  local archive_type
  archive_type=$(adapter_base_get_archive_type "$archive")
  if [[ "$archive_type" != "zip" ]]; then
    errors+=("Not a ZIP archive (found: $archive_type)")
    ADAPTER_VALIDATION_ERRORS+=("Solid Backups NextGen: ${errors[*]}")
    return 1
  fi

  # Check for NextGen signature: data/ directory with SQL files
  # Check for data/ directory first
  if ! adapter_base_archive_contains "$archive" "data/"; then
    errors+=("Missing data/ directory")
    ADAPTER_VALIDATION_ERRORS+=("Solid Backups NextGen: ${errors[*]}")
    return 1
  fi

  # Check for files/ directory
  if ! adapter_base_archive_contains "$archive" "files/"; then
    errors+=("Missing files/ directory")
    ADAPTER_VALIDATION_ERRORS+=("Solid Backups NextGen: ${errors[*]}")
    return 1
  fi

  # Check for SQL files in data/ directory
  # Look for core WordPress table patterns (options, posts, users)
  if ! adapter_base_archive_contains "$archive" "data/.*_options\.sql"; then
    errors+=("Missing database files in data/ directory (expected: *_options.sql)")
    ADAPTER_VALIDATION_ERRORS+=("Solid Backups NextGen: ${errors[*]}")
    return 1
  fi

  # Success - this is a valid Solid Backups NextGen archive
  return 0
}

# Extract Solid Backups NextGen archive
# Usage: adapter_solidbackups_nextgen_extract <archive_path> <dest_dir>
# Returns: 0 on success, 1 on failure
adapter_solidbackups_nextgen_extract() {
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

# Find database files in extracted Solid Backups NextGen archive and consolidate them
# Usage: adapter_solidbackups_nextgen_find_database <extract_dir>
# Returns: 0 and echoes path to consolidated database file if found, 1 if not found
adapter_solidbackups_nextgen_find_database() {
  local extract_dir="$1"
  local data_dir
  local candidate_dirs=()

  # NextGen stores database files in top-level data/ directory
  # Collect ALL data/ directories and iterate through them (WordPress core and plugins
  # have data/ dirs too: wp-includes/ID3/data, jetpack/tests/data, etc.)
  while IFS= read -r -d '' dir; do
    candidate_dirs+=("$dir")
  done < <(find "$extract_dir" -type d -name "data" -print0 2>/dev/null)

  if [[ ${#candidate_dirs[@]} -eq 0 ]]; then
    log_verbose "  No data/ directory found in archive"
    return 1
  fi

  log_verbose "  Found ${#candidate_dirs[@]} data/ directory candidate(s), checking each..."

  # Try each candidate directory (prioritize shallowest path first)
  # Sort by path depth (fewest slashes = shallowest = most likely to be correct)
  local sorted_candidates
  sorted_candidates=$(printf '%s\n' "${candidate_dirs[@]}" | awk '{ print length(gsub(/\//, "/")) " " $0 }' | sort -n | cut -d' ' -f2-)

  local candidate
  while IFS= read -r candidate; do
    [[ -z "$candidate" ]] && continue

    log_verbose "    Checking: $candidate"

    # Verify it contains SQL files (use *.sql to support custom table prefixes)
    local sql_count
    sql_count=$(find "$candidate" -maxdepth 1 -type f -name "*.sql" 2>/dev/null | wc -l)

    log_verbose "      Found $sql_count SQL files"

    if [[ $sql_count -ge 5 ]]; then
      # Found valid data/ directory with sufficient SQL files
      data_dir="$candidate"
      log_verbose "      ✓ Valid NextGen data/ directory (${sql_count} SQL files)"
      break
    else
      log_verbose "      ✗ Insufficient SQL files (need at least 5 core WordPress tables)"
    fi
  done <<<"$sorted_candidates"

  # Check if we found a valid data/ directory
  if [[ -z "$data_dir" ]]; then
    log_verbose "  No valid data/ directory found with sufficient SQL files"
    return 1
  fi

  # Consolidate all SQL files into a single database dump
  local consolidated_file="$extract_dir/solidbackups-nextgen-database-consolidated.sql"
  if ! adapter_solidbackups_nextgen_consolidate_database "$data_dir" "$consolidated_file"; then
    log_verbose "  Failed to consolidate SQL files"
    return 1
  fi

  log_verbose "  Database consolidated successfully from: $data_dir"
  echo "$consolidated_file"
  return 0
}

# Find wp-content directory in extracted Solid Backups NextGen archive
# Usage: adapter_solidbackups_nextgen_find_content <extract_dir>
# Returns: 0 and echoes path if found, 1 if not found
adapter_solidbackups_nextgen_find_content() {
  local extract_dir="$1"
  local wp_content_dir
  local candidate_dirs=()

  # NextGen stores files in top-level files/ directory
  # Collect ALL files/ directories and iterate through them (plugins may have
  # nested files/ dirs in their backup/test data)
  while IFS= read -r -d '' dir; do
    candidate_dirs+=("$dir")
  done < <(find "$extract_dir" -type d -name "files" -print0 2>/dev/null)

  if [[ ${#candidate_dirs[@]} -eq 0 ]]; then
    log_verbose "  No files/ directory found in archive"
    return 1
  fi

  log_verbose "  Found ${#candidate_dirs[@]} files/ directory candidate(s), checking each..."

  # Try each candidate directory (prioritize shallowest path first)
  # Sort by path depth (fewest slashes = shallowest = most likely to be correct)
  local sorted_candidates
  sorted_candidates=$(printf '%s\n' "${candidate_dirs[@]}" | awk '{ print length(gsub(/\//, "/")) " " $0 }' | sort -n | cut -d' ' -f2-)

  local candidate
  while IFS= read -r candidate; do
    [[ -z "$candidate" ]] && continue

    log_verbose "    Checking: $candidate"

    # Look for wp-content in several possible locations:
    # 1. files/wp-content/ (single site at root)
    # 2. files/subdomains/{site}/wp-content/ (multisite installation)

    # Try direct path first (single site)
    if [[ -d "$candidate/wp-content" ]]; then
      local score
      score=$(adapter_base_score_wp_content "$candidate/wp-content")
      log_verbose "      Found wp-content/ (score: $score)"

      if [[ $score -gt 0 ]]; then
        wp_content_dir="$candidate/wp-content"
        log_verbose "      ✓ Valid wp-content directory"
        break
      else
        log_verbose "      ✗ wp-content lacks plugins/themes/uploads"
      fi
    # Try subdomains structure (multisite)
    elif [[ -d "$candidate/subdomains" ]]; then
      log_verbose "      Found subdomains/ directory (multisite backup)"

      # Find the best subdomain wp-content using scoring
      local best_content="" best_score=0
      while IFS= read -r -d '' content_dir; do
        local score
        score=$(adapter_base_score_wp_content "$content_dir")
        log_verbose "        Checking: $content_dir (score: $score)"
        if [[ $score -gt $best_score ]]; then
          best_score=$score
          best_content="$content_dir"
        fi
      done < <(find "$candidate/subdomains" -type d -name "wp-content" -print0 2>/dev/null)

      if [[ -n "$best_content" && $best_score -gt 0 ]]; then
        wp_content_dir="$best_content"
        log_verbose "      ✓ Valid wp-content in multisite: $wp_content_dir (score: $best_score)"
        break
      else
        log_verbose "      ✗ No valid wp-content in subdomains/"
      fi
    else
      log_verbose "      ✗ No wp-content/ or subdomains/ structure"
    fi
  done <<<"$sorted_candidates"

  # Fallback: Use base helper to search across all candidates
  if [[ -z "$wp_content_dir" ]]; then
    log_verbose "  Using fallback search across all files/ candidates..."
    for candidate in "${candidate_dirs[@]}"; do
      local found
      found=$(adapter_base_find_best_wp_content "$candidate")
      if [[ -n "$found" ]]; then
        wp_content_dir="$found"
        log_verbose "    ✓ Found via fallback: $wp_content_dir"
        break
      fi
    done
  fi

  if [[ -z "$wp_content_dir" ]]; then
    log_verbose "  No wp-content directory found in any files/ candidate"
    return 1
  fi

  log_verbose "  Final wp-content location: $wp_content_dir"
  echo "$wp_content_dir"
  return 0
}

# Consolidate Solid Backups NextGen SQL files into single database dump
# Usage: adapter_solidbackups_nextgen_consolidate_database <sql_dir> <output_file>
# Returns: 0 on success, 1 on failure
adapter_solidbackups_nextgen_consolidate_database() {
  local sql_dir="$1" output_file="$2"

  log_verbose "  Consolidating SQL files from: $sql_dir"

  # Find all SQL files and concatenate them (Bash 3.2 + BSD compatible)
  # Use *.sql pattern to support custom table prefixes (e.g., tkI5z3G_options.sql)
  # Collect files into array, then sort (BSD sort doesn't support -z)
  local sql_files=()
  while IFS= read -r -d '' file; do
    sql_files+=("$file")
  done < <(find "$sql_dir" -maxdepth 1 -type f -name "*.sql" -print0 2>/dev/null)

  if [[ ${#sql_files[@]} -eq 0 ]]; then
    log_verbose "  No SQL files found in $sql_dir"
    return 1
  fi

  log_verbose "  Found ${#sql_files[@]} SQL files to consolidate"

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
    log_verbose "    Adding: $(basename "$sql_file")"
    cat "$sql_file" >> "$output_file"
    echo "" >> "$output_file"  # Add newline between files
  done

  log_verbose "  Consolidation complete: $output_file"
  return 0
}

# Get human-readable format name
# Usage: adapter_solidbackups_nextgen_get_name
# Returns: Format name string
adapter_solidbackups_nextgen_get_name() {
  echo "Solid Backups NextGen"
}

# Get required dependencies for this adapter
# Usage: adapter_solidbackups_nextgen_get_dependencies
# Returns: Space-separated list of required commands
adapter_solidbackups_nextgen_get_dependencies() {
  echo "unzip file"
}
