# -----------------------------
# Archive Adapter Base Functions
# -----------------------------
# Shared helper functions available to all adapters

# Global variable to store detailed validation failure reasons
ADAPTER_VALIDATION_ERRORS=()

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

  # Temporarily disable pipefail to avoid SIGPIPE (141) errors
  # when grep -q exits early, causing unzip/tar to receive SIGPIPE
  # Use trap to ensure restoration even on early exit (Issue #88-3)
  local pipefail_was_set=false
  if [[ "$SHELLOPTS" =~ pipefail ]]; then
    pipefail_was_set=true
    set +o pipefail
    # Ensure pipefail is restored on function exit (normal or error)
    # Use parameter expansion to handle set -u (unbound variable check)
    trap '[[ "${pipefail_was_set:-false}" == true ]] && set -o pipefail' RETURN
  fi

  if [[ "$archive_type" == "zip" ]]; then
    if unzip -l "$archive" 2>/dev/null | grep -q "$pattern"; then
      return 0
    fi
  elif [[ "$archive_type" == "tar.gz" ]]; then
    # Gzip-compressed tar: use -z flag
    if tar -tzf "$archive" 2>/dev/null | grep -q "$pattern"; then
      return 0
    fi
  elif [[ "$archive_type" == "tar" ]]; then
    # Uncompressed tar: no compression flag
    if tar -tf "$archive" 2>/dev/null | grep -q "$pattern"; then
      return 0
    fi
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

  # Check gzip/compressed BEFORE zip (since "gzip" contains "zip" substring)
  if [[ "$file_output" == *"gzip"* ]] || [[ "$file_output" == *"compressed"* ]]; then
    echo "tar.gz"
  elif [[ "$file_output" == *"zip"* ]]; then
    echo "zip"
  elif [[ "$file_output" == *"tar"* ]]; then
    echo "tar"
  else
    echo "unknown"
  fi
}

# Extract a ZIP archive with progress feedback for large files
# Usage: adapter_base_extract_zip <archive_path> <dest_dir>
# Returns: 0 on success, 1 on failure
# Note: For archives >500MB, logs a message about expected duration
adapter_base_extract_zip() {
  local archive="$1" dest="$2"
  local archive_size start_time

  archive_size=$(stat -f%z "$archive" 2>/dev/null || stat -c%s "$archive" 2>/dev/null)
  local archive_mb=$((archive_size / 1024 / 1024))

  # Try bsdtar with progress if available (supports stdin for progress bar)
  if ! $QUIET_MODE && has_pv && [[ -t 1 ]] && command -v bsdtar >/dev/null 2>&1; then
    log_trace "pv \"$archive\" | bsdtar -xf - -C \"$dest\""
    if ! pv -N "Extracting archive" -s "$archive_size" "$archive" | bsdtar -xf - -C "$dest" 2>/dev/null; then
      return 1
    fi
  else
    # Fallback to unzip
    # Show file-by-file progress when:
    #   - --verbose or --trace is enabled (user wants to see details)
    #   - Large archives (>500MB) without quiet mode
    start_time=$(date +%s)
    # -o: overwrite without prompting (archives may contain duplicates)
    if $VERBOSE || $TRACE_MODE || { [[ $archive_mb -gt 500 ]] && ! $QUIET_MODE; }; then
      if [[ $archive_mb -gt 500 ]]; then
        log "Extracting ${archive_mb}MB archive (this may take several minutes)..."
      fi
      log_trace "unzip -o \"$archive\" -d \"$dest\""
      # Show file-by-file progress (no -q flag)
      if ! unzip -o "$archive" -d "$dest"; then
        return 1
      fi
    else
      # Small archives in non-verbose mode: use quiet mode
      log_trace "unzip -oq \"$archive\" -d \"$dest\""
      if ! unzip -oq "$archive" -d "$dest" 2>/dev/null; then
        return 1
      fi
    fi
    local end_time elapsed_min
    end_time=$(date +%s)
    elapsed_min=$(( (end_time - start_time) / 60 ))
    if [[ $elapsed_min -gt 0 ]]; then
      log_verbose "Extraction completed in ${elapsed_min} minute(s)"
    fi
  fi

  return 0
}

# Extract a TAR.GZ archive with progress feedback for large files
# Usage: adapter_base_extract_tar_gz <archive_path> <dest_dir>
# Returns: 0 on success, 1 on failure
adapter_base_extract_tar_gz() {
  local archive="$1" dest="$2"
  local archive_size start_time

  archive_size=$(stat -f%z "$archive" 2>/dev/null || stat -c%s "$archive" 2>/dev/null)
  local archive_mb=$((archive_size / 1024 / 1024))

  # Try pv with progress if available
  if ! $QUIET_MODE && has_pv && [[ -t 1 ]]; then
    log_trace "pv \"$archive\" | tar -xzf - -C \"$dest\""
    if ! pv -N "Extracting archive" -s "$archive_size" "$archive" | tar -xzf - -C "$dest" 2>/dev/null; then
      return 1
    fi
  else
    # Fallback to plain tar
    # Show file-by-file progress when --verbose or --trace is enabled, or for large archives
    start_time=$(date +%s)
    if $VERBOSE || $TRACE_MODE || { [[ $archive_mb -gt 500 ]] && ! $QUIET_MODE; }; then
      if [[ $archive_mb -gt 500 ]]; then
        log "Extracting ${archive_mb}MB archive (this may take several minutes)..."
      fi
      log_trace "tar -xzvf \"$archive\" -C \"$dest\""
      if ! tar -xzvf "$archive" -C "$dest"; then
        return 1
      fi
    else
      log_trace "tar -xzf \"$archive\" -C \"$dest\""
      if ! tar -xzf "$archive" -C "$dest" 2>/dev/null; then
        return 1
      fi
    fi
    local end_time elapsed_min
    end_time=$(date +%s)
    elapsed_min=$(( (end_time - start_time) / 60 ))
    if [[ $elapsed_min -gt 0 ]]; then
      log_verbose "Extraction completed in ${elapsed_min} minute(s)"
    fi
  fi

  return 0
}

# Extract an uncompressed TAR archive with progress feedback for large files
# Usage: adapter_base_extract_tar <archive_path> <dest_dir>
# Returns: 0 on success, 1 on failure
adapter_base_extract_tar() {
  local archive="$1" dest="$2"
  local archive_size start_time

  archive_size=$(stat -f%z "$archive" 2>/dev/null || stat -c%s "$archive" 2>/dev/null)
  local archive_mb=$((archive_size / 1024 / 1024))

  # Try pv with progress if available
  if ! $QUIET_MODE && has_pv && [[ -t 1 ]]; then
    log_trace "pv \"$archive\" | tar -xf - -C \"$dest\""
    if ! pv -N "Extracting archive" -s "$archive_size" "$archive" | tar -xf - -C "$dest" 2>/dev/null; then
      return 1
    fi
  else
    # Fallback to plain tar
    # Show file-by-file progress when --verbose or --trace is enabled, or for large archives
    start_time=$(date +%s)
    if $VERBOSE || $TRACE_MODE || { [[ $archive_mb -gt 500 ]] && ! $QUIET_MODE; }; then
      if [[ $archive_mb -gt 500 ]]; then
        log "Extracting ${archive_mb}MB archive (this may take several minutes)..."
      fi
      log_trace "tar -xvf \"$archive\" -C \"$dest\""
      if ! tar -xvf "$archive" -C "$dest"; then
        return 1
      fi
    else
      log_trace "tar -xf \"$archive\" -C \"$dest\""
      if ! tar -xf "$archive" -C "$dest" 2>/dev/null; then
        return 1
      fi
    fi
    local end_time elapsed_min
    end_time=$(date +%s)
    elapsed_min=$(( (end_time - start_time) / 60 ))
    if [[ $elapsed_min -gt 0 ]]; then
      log_verbose "Extraction completed in ${elapsed_min} minute(s)"
    fi
  fi

  return 0
}

# Consolidate multiple SQL files into a single database dump
# Usage: adapter_base_consolidate_database <sql_dir> <output_file> [maxdepth] [verbose]
# Args:
#   sql_dir: Directory containing SQL files to consolidate
#   output_file: Path to output consolidated SQL file
#   maxdepth: Optional max depth for find (default: no limit)
#   verbose: Optional flag "verbose" to enable logging (default: silent)
# Returns: 0 on success, 1 on failure
# Note: This function extracts common SQL consolidation logic used by multiple adapters
#       (Issue #88-1: Code deduplication)
adapter_base_consolidate_database() {
  local sql_dir="$1" output_file="$2" maxdepth="$3" verbose_flag="$4"
  local enable_verbose=false

  # Check if verbose mode enabled
  [[ "$verbose_flag" == "verbose" ]] && enable_verbose=true

  $enable_verbose && log_verbose "  Consolidating SQL files from: $sql_dir"

  # Build find command with optional maxdepth
  local find_cmd="find \"$sql_dir\""
  [[ -n "$maxdepth" ]] && find_cmd="$find_cmd -maxdepth $maxdepth"
  find_cmd="$find_cmd -type f -name \"*.sql\" -print0 2>/dev/null"

  # Find all SQL files and concatenate them (Bash 3.2 + BSD compatible)
  # Collect files into array, then sort (BSD sort doesn't support -z)
  local sql_files=()
  while IFS= read -r -d '' file; do
    sql_files+=("$file")
  done < <(eval "$find_cmd")

  if [[ ${#sql_files[@]} -eq 0 ]]; then
    $enable_verbose && log_verbose "  No SQL files found in $sql_dir"
    return 1
  fi

  $enable_verbose && log_verbose "  Found ${#sql_files[@]} SQL files to consolidate"

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
    $enable_verbose && log_verbose "    Adding: $(basename "$sql_file")"
    cat "$sql_file" >> "$output_file"
    echo "" >> "$output_file"  # Add newline between files
  done

  $enable_verbose && log_verbose "  Consolidation complete: $output_file"
  return 0
}
