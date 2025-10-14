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
