wp_local() {
  log_trace "wp --skip-plugins --skip-themes --path=\"$PWD\" $*"
  wp --skip-plugins --skip-themes --path="$PWD" "$@"
}

# Run local WP-CLI without skipping plugins/themes (needed for plugin-provided commands)
wp_local_full() {
  log_trace "wp --path=\"$PWD\" $*"
  wp --path="$PWD" "$@"
}

# ========================================
# Archive Adapter System
# ========================================

# List of available adapters (add new adapters here)
AVAILABLE_ADAPTERS=("wpmigrate" "duplicator" "jetpack" "solidbackups" "solidbackups_nextgen")

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

# SECURITY: Validate archive contents before extraction (Zip Slip protection)
# Checks for path traversal attempts, absolute paths, and symlinks
# Usage: validate_archive_paths <archive_path>
# Returns: 0 if safe, 1 if dangerous paths found
validate_archive_paths() {
  local archive="$1"
  local entry dangerous_found=false

  log_verbose "Validating archive for path traversal attempts..."

  # Detect archive type
  local archive_type=""
  if [[ "$archive" =~ \.zip$ ]] || unzip -l "$archive" >/dev/null 2>&1; then
    archive_type="zip"
  elif [[ "$archive" =~ \.(tar\.gz|tgz)$ ]] || tar -tzf "$archive" >/dev/null 2>&1; then
    archive_type="tar"
  else
    log_warning "Could not detect archive type for security validation"
    return 0  # Proceed but log warning
  fi

  # List archive contents and check each entry
  if [[ "$archive_type" == "zip" ]]; then
    while IFS= read -r entry; do
      # Check for absolute paths (start with /)
      if [[ "$entry" =~ ^/ ]]; then
        log_warning "SECURITY: Archive contains absolute path: $entry"
        dangerous_found=true
      fi

      # Check for parent directory references (..)
      if [[ "$entry" =~ \.\. ]]; then
        log_warning "SECURITY: Archive contains parent directory reference: $entry"
        dangerous_found=true
      fi

      # Check for paths that would escape (crude but effective)
      if [[ "$entry" =~ ^\.\./ ]] || [[ "$entry" =~ /\.\./ ]] || [[ "$entry" =~ /\.\.$ ]]; then
        log_warning "SECURITY: Archive contains path traversal attempt: $entry"
        dangerous_found=true
      fi
    done < <(unzip -l "$archive" 2>/dev/null | awk 'NR>3 {if ($1 ~ /^-+$/) exit; if (NF >= 4) {for(i=4;i<=NF;i++) printf "%s%s", $i, (i<NF?" ":""); print ""}}')
  elif [[ "$archive_type" == "tar" ]]; then
    while IFS= read -r entry; do
      # Check for absolute paths
      if [[ "$entry" =~ ^/ ]]; then
        log_warning "SECURITY: Archive contains absolute path: $entry"
        dangerous_found=true
      fi

      # Check for parent directory references
      if [[ "$entry" =~ \.\. ]]; then
        log_warning "SECURITY: Archive contains parent directory reference: $entry"
        dangerous_found=true
      fi

      # Check for path traversal
      if [[ "$entry" =~ ^\.\./ ]] || [[ "$entry" =~ /\.\./ ]] || [[ "$entry" =~ /\.\.$ ]]; then
        log_warning "SECURITY: Archive contains path traversal attempt: $entry"
        dangerous_found=true
      fi
    done < <(tar -tzf "$archive" 2>/dev/null)
  fi

  if $dangerous_found; then
    return 1
  fi

  return 0
}

extract_archive() {
  local archive="$1" dest="$2"

  # SECURITY: Validate archive paths before extraction
  if ! validate_archive_paths "$archive"; then
    err "Archive failed security validation (Zip Slip protection).

This archive contains files with dangerous paths that could write outside
the extraction directory. This is a security risk and could be:
  • A malicious archive designed to exploit path traversal (Zip Slip attack)
  • A corrupted archive with invalid file paths
  • An archive incorrectly created with absolute paths or ../ components

Dangerous path patterns detected:
  • Absolute paths (starting with /)
  • Parent directory references (../)
  • Path traversal attempts

For security, this archive cannot be used. If you trust the source:
  1. Verify the archive is from a legitimate backup
  2. Re-create the archive with proper relative paths only
  3. Ensure NO ../ components exist in any file paths
  4. Use a trusted backup plugin that creates secure archives

Common causes:
  • Archive created with 'cd / && tar' (captures absolute paths)
  • Archive created including parent directories
  • Manually crafted malicious archive"
  fi

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

# ========================================
# Backup Creation Helpers
# ========================================

# Sanitize domain name for use in filename
# Usage: sanitize_domain_for_filename <domain>
# Returns: echoes sanitized domain (dots/slashes → dashes)
sanitize_domain_for_filename() {
  local domain="$1"
  # Remove protocol if present
  domain="${domain#http://}"
  domain="${domain#https://}"
  # Remove trailing slashes
  domain="${domain%/}"
  # Replace dots and slashes with dashes
  echo "$domain" | tr './' '--'
}

# Calculate estimated backup size on source server
# Usage: calculate_backup_size <source_host> <source_root>
# Returns: echoes size in KB
calculate_backup_size() {
  local host="$1" root="$2"
  local db_size wp_content_size

  # Get database size via wp-cli (sum all table sizes from CSV, convert bytes to KB)
  # CSV format: Name,Size,Index,Engine where Size is quoted with units like "5865472 B", "5.7 MB", etc.
  local db_size_bytes
  # shellcheck disable=SC2029  # Intentional client-side expansion with proper quoting
  db_size_bytes=$(ssh "${SSH_OPTS[@]}" "$host" "cd '$root' && wp db size --format=csv --path='$root'" | tail -n +2 | awk -F',' '{
    gsub(/"/,"",$2);                                    # Remove quotes
    if (match($2, /([0-9.]+) *([KMGT]?i?B)/, arr)) {   # Parse number and unit (supports both decimal and binary units)
      value = arr[1];
      unit = arr[2];

      # Convert to bytes based on unit (decimal SI units)
      if (unit == "B")        multiplier = 1;
      else if (unit == "KB")  multiplier = 1024;
      else if (unit == "MB")  multiplier = 1024*1024;
      else if (unit == "GB")  multiplier = 1024*1024*1024;
      else if (unit == "TB")  multiplier = 1024*1024*1024*1024;
      # Binary IEC units (KiB, MiB, GiB, TiB)
      else if (unit == "KiB") multiplier = 1024;
      else if (unit == "MiB") multiplier = 1024*1024;
      else if (unit == "GiB") multiplier = 1024*1024*1024;
      else if (unit == "TiB") multiplier = 1024*1024*1024*1024;
      else                    multiplier = 1;          # Default to bytes

      sum += value * multiplier;
    }
  } END {print int(sum)}' || echo "0")

  # Convert bytes to KB for consistent units with du -sk
  db_size=$((db_size_bytes / 1024))

  # Get wp-content size (excluding cache, logs, etc.)
  # shellcheck disable=SC2029  # Intentional client-side expansion with proper quoting
  wp_content_size=$(ssh "${SSH_OPTS[@]}" "$host" "du -sk '$root/wp-content' --exclude='cache' --exclude='*/cache' --exclude='*.log' 2>/dev/null" | awk '{print $1}' || echo "0")

  # Add 50% buffer for zip compression overhead
  local total=$((db_size + wp_content_size))
  local with_buffer=$((total + total / 2))

  echo "$with_buffer"
}

# Calculate estimated backup size for local WordPress installation
# Usage: calculate_backup_size_local <wordpress_root>
# Returns: echoes size in KB
calculate_backup_size_local() {
  local root="$1"
  local db_size wp_content_size

  # Get database size via wp-cli (sum all table sizes from CSV, convert bytes to KB)
  # CSV format: Name,Size,Index,Engine where Size is quoted with units like "5865472 B", "5.7 MB", etc.
  local db_size_bytes
  db_size_bytes=$(wp db size --format=csv --path="$root" 2>/dev/null | tail -n +2 | awk -F',' '{
    gsub(/"/,"",$2);                                    # Remove quotes
    if (match($2, /([0-9.]+) *([KMGT]?i?B)/, arr)) {   # Parse number and unit (supports both decimal and binary units)
      value = arr[1];
      unit = arr[2];

      # Convert to bytes based on unit (decimal SI units)
      if (unit == "B")        multiplier = 1;
      else if (unit == "KB")  multiplier = 1024;
      else if (unit == "MB")  multiplier = 1024*1024;
      else if (unit == "GB")  multiplier = 1024*1024*1024;
      else if (unit == "TB")  multiplier = 1024*1024*1024*1024;
      # Binary IEC units (KiB, MiB, GiB, TiB)
      else if (unit == "KiB") multiplier = 1024;
      else if (unit == "MiB") multiplier = 1024*1024;
      else if (unit == "GiB") multiplier = 1024*1024*1024;
      else if (unit == "TiB") multiplier = 1024*1024*1024*1024;
      else                    multiplier = 1;          # Default to bytes

      sum += value * multiplier;
    }
  } END {print int(sum)}' || echo "0")

  # Convert bytes to KB for consistent units with du -sk
  db_size=$((db_size_bytes / 1024))

  # Get wp-content size (excluding cache, logs, etc.)
  # Use find for portability (BSD du doesn't support --exclude)
  wp_content_size=$(find "$root/wp-content" -type f ! -path '*/cache/*' ! -name '*.log' -ls 2>/dev/null | awk '{sum += $7} END {print int(sum/1024)}')
  [[ -z "$wp_content_size" ]] && wp_content_size="0"

  # Add 50% buffer for zip compression overhead
  local total=$((db_size + wp_content_size))
  local with_buffer=$((total + total / 2))

  echo "$with_buffer"
}

# Create backup directory on source server
# Usage: create_backup_directory <source_host> <backup_dir>
# Returns: 0 on success, 1 on failure
create_backup_directory() {
  local host="$1" backup_dir="$2"

  log_verbose "Creating backup directory: $backup_dir"

  # shellcheck disable=SC2029  # Intentional client-side expansion; $HOME expands remotely
  if ! ssh "${SSH_OPTS[@]}" "$host" "mkdir -p $backup_dir" 2>/dev/null; then
    err "Failed to create backup directory: $backup_dir"
    # shellcheck disable=SC2317  # err() exits script, but shellcheck doesn't know
    return 1
  fi

  return 0
}

# Generate wpmigrate-backup.json metadata file
# Usage: generate_backup_metadata <temp_dir> <source_url> <table_count>
# Returns: 0 on success
generate_backup_metadata() {
  local temp_dir="$1" source_url="$2" table_count="$3"
  local metadata_file="$temp_dir/wpmigrate-backup.json"
  local timestamp
  timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  cat > "$metadata_file" <<EOF
{
  "format_version": "1.0",
  "created_at": "$timestamp",
  "wp_migrate_version": "$VERSION",
  "source_url": "$source_url",
  "database_tables": $table_count,
  "exclusions": [
    "wp-content/cache/",
    "wp-content/*/cache/",
    "wp-content/object-cache.php",
    "wp-content/advanced-cache.php",
    "wp-content/debug.log",
    "wp-content/*.log"
  ]
}
EOF

  return 0
}

# Create backup on source server
# Usage: create_backup
# Returns: 0 on success, exits on failure
create_backup() {
  local source_host="$SOURCE_HOST"
  local source_root="$SOURCE_ROOT"

  log "Creating backup on source server: $source_host"
  log "WordPress root: $source_root"

  # Validate SSH connectivity
  log_verbose "Testing SSH connection..."
  # shellcheck disable=SC2029  # Intentional client-side expansion with proper quoting
  if ! ssh "${SSH_OPTS[@]}" "$source_host" "true" 2>/dev/null; then
    err "Cannot connect to source host: $source_host

Verify:
  1. SSH access is configured
  2. Host is reachable
  3. Credentials are correct"
  fi

  # Verify WordPress installation exists
  log_verbose "Verifying WordPress installation..."
  # shellcheck disable=SC2029  # Intentional client-side expansion with proper quoting
  if ! ssh "${SSH_OPTS[@]}" "$source_host" "test -f '$source_root/wp-config.php'" 2>/dev/null; then
    err "WordPress installation not found at: $source_root

wp-config.php does not exist.

Verify:
  1. Path is correct
  2. WordPress is installed at this location"
  fi

  # Verify wp-cli is available
  log_verbose "Checking for wp-cli..."
  # shellcheck disable=SC2029  # Intentional client-side expansion with proper quoting
  if ! ssh "${SSH_OPTS[@]}" "$source_host" "command -v wp" 2>/dev/null; then
    err "wp-cli not found on source server

wp-cli is required for database export.

Install wp-cli:
  curl -O https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
  chmod +x wp-cli.phar
  sudo mv wp-cli.phar /usr/local/bin/wp"
  fi

  # Create backup directory first (needed for disk space check)
  local backup_dir="$BACKUP_OUTPUT_DIR"
  create_backup_directory "$source_host" "$backup_dir"

  # Check disk space on the filesystem where backups will be stored
  log_verbose "Checking available disk space..."
  local required_space available_space
  required_space=$(calculate_backup_size "$source_host" "$source_root")
  # shellcheck disable=SC2029  # Intentional client-side expansion; check actual backup directory
  available_space=$(ssh "${SSH_OPTS[@]}" "$source_host" "df -P $backup_dir | tail -1 | awk '{print \$4}'")

  if [[ $available_space -lt $required_space ]]; then
    err "Insufficient disk space on source server

Required: ${required_space}KB (estimated)
Available: ${available_space}KB
Backup directory: $backup_dir

Free up space or use a different backup location."
  fi

  log_verbose "Disk space check passed (required: ${required_space}KB, available: ${available_space}KB)"

  # Generate backup filename
  local site_url table_count sanitized_domain timestamp backup_filename
  # shellcheck disable=SC2029  # Intentional client-side expansion with proper quoting
  site_url=$(ssh "${SSH_OPTS[@]}" "$source_host" "cd '$source_root' && wp option get siteurl --path='$source_root'" 2>/dev/null)
  # shellcheck disable=SC2029  # Intentional client-side expansion with proper quoting
  table_count=$(ssh "${SSH_OPTS[@]}" "$source_host" "cd '$source_root' && wp db tables --path='$source_root' | wc -l" 2>/dev/null | tr -d ' ')
  sanitized_domain=$(sanitize_domain_for_filename "$site_url")
  timestamp=$(date -u +%Y-%m-%d-%H%M%S)
  backup_filename="${sanitized_domain}-${timestamp}.zip"

  log "Backup filename: $backup_filename"

  # Create temp directory on source server
  local temp_dir
  # shellcheck disable=SC2029  # Intentional client-side expansion with proper quoting
  temp_dir=$(ssh "${SSH_OPTS[@]}" "$source_host" "mktemp -d /tmp/wp-migrate-backup-XXXXX" 2>/dev/null)

  if [[ -z "$temp_dir" ]]; then
    err "Failed to create temporary directory on source server"
  fi

  log_verbose "Created temp directory: $temp_dir"

  # Export database
  log "Exporting database..."
  # shellcheck disable=SC2029  # Intentional client-side expansion with proper quoting
  if ! ssh "${SSH_OPTS[@]}" "$source_host" "cd '$source_root' && wp db export '$temp_dir/database.sql' --path='$source_root'" 2>/dev/null; then
    # shellcheck disable=SC2029  # Intentional client-side expansion with proper quoting
    ssh "${SSH_OPTS[@]}" "$source_host" "rm -rf '$temp_dir'" 2>/dev/null
    err "Failed to export database"
  fi

  log_verbose "Database exported successfully"

  # Create metadata file
  log_verbose "Generating metadata..."
  # We'll generate this locally and transfer it
  local local_temp_meta
  local_temp_meta=$(mktemp)
  cat > "$local_temp_meta" <<EOF
{
  "format_version": "1.0",
  "created_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "wp_migrate_version": "$VERSION",
  "source_url": "$site_url",
  "database_tables": $table_count,
  "exclusions": [
    "wp-content/cache/",
    "wp-content/*/cache/",
    "wp-content/object-cache.php",
    "wp-content/advanced-cache.php",
    "wp-content/debug.log",
    "wp-content/*.log"
  ]
}
EOF

  scp "${SSH_OPTS[@]}" "$local_temp_meta" "$source_host:$temp_dir/wpmigrate-backup.json" >/dev/null 2>&1
  rm -f "$local_temp_meta"

  # Sync wp-content with exclusions
  log "Syncing wp-content..."
  # shellcheck disable=SC2029  # Intentional client-side expansion with proper quoting
  if ! ssh "${SSH_OPTS[@]}" "$source_host" "rsync -a --exclude='cache/' --exclude='*/cache/' --exclude='object-cache.php' --exclude='advanced-cache.php' --exclude='debug.log' --exclude='*.log' '$source_root/wp-content/' '$temp_dir/wp-content/'" 2>/dev/null; then
    # shellcheck disable=SC2029  # Intentional client-side expansion with proper quoting
    ssh "${SSH_OPTS[@]}" "$source_host" "rm -rf '$temp_dir'" 2>/dev/null
    err "Failed to sync wp-content"
  fi

  log_verbose "wp-content synced successfully"

  # Create zip archive
  log "Creating archive..."
  # shellcheck disable=SC2029  # Intentional client-side expansion; $HOME expands remotely in backup_dir
  if ! ssh "${SSH_OPTS[@]}" "$source_host" "cd '$temp_dir' && zip -r $backup_dir/'$backup_filename' ." >/dev/null 2>&1; then
    # shellcheck disable=SC2029  # Intentional client-side expansion with proper quoting
    ssh "${SSH_OPTS[@]}" "$source_host" "rm -rf '$temp_dir'" 2>/dev/null
    err "Failed to create zip archive"
  fi

  log_verbose "Archive created successfully"

  # Clean up temp directory
  # shellcheck disable=SC2029  # Intentional client-side expansion with proper quoting
  ssh "${SSH_OPTS[@]}" "$source_host" "rm -rf '$temp_dir'" 2>/dev/null

  # Report success
  local full_backup_path="$backup_dir/$backup_filename"
  # Replace literal $HOME with ~ for user-friendly display
  local display_path="${full_backup_path//\$HOME/~}"
  log ""
  log "✓ Backup created successfully"
  log ""
  log "Backup location: $display_path"
  log "Source URL: $site_url"
  log "Database tables: $table_count"
  log ""
  log "To import this backup on another server:"
  log "  ./wp-migrate.sh --archive $display_path"
  log ""

  return 0
}

# Create backup of local WordPress installation
# Usage: create_backup_local
# Returns: 0 on success, exits on failure
create_backup_local() {
  local source_root="$SOURCE_ROOT"

  log "Creating local backup"
  log "WordPress root: $source_root"

  # 1. VALIDATION

  # Verify WordPress installation exists
  log_verbose "Verifying WordPress installation..."
  [[ -f "$source_root/wp-config.php" ]] || err "WordPress installation not found at: $source_root

wp-config.php does not exist.

Verify:
  1. Path is correct
  2. WordPress is installed at this location"

  # Verify wp-cli is available
  log_verbose "Checking for wp-cli..."
  command -v wp >/dev/null 2>&1 || err "wp-cli not found

wp-cli is required for database export.

Install wp-cli:
  curl -O https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
  chmod +x wp-cli.phar
  sudo mv wp-cli.phar /usr/local/bin/wp"

  # Verify WordPress is functional
  log_verbose "Verifying WordPress installation..."
  if ! wp core is-installed --path="$source_root" 2>/dev/null; then
    err "WordPress verification failed

wp core is-installed returned an error.

Verify:
  1. WordPress is properly installed
  2. Database connection is configured
  3. wp-config.php is valid"
  fi

  # 2. PREPARE BACKUP

  # Create backup directory (expand $HOME locally for local mode)
  local backup_dir
  backup_dir=$(eval echo "$BACKUP_OUTPUT_DIR")
  mkdir -p "$backup_dir" || err "Failed to create backup directory: $backup_dir"

  # Get site information
  local site_url
  site_url=$(wp option get siteurl --path="$source_root" 2>/dev/null || echo "localhost")

  local domain
  domain=$(sanitize_domain_for_filename "$site_url")

  local timestamp
  timestamp=$(date +%Y-%m-%d-%H%M%S)

  local backup_filename="${domain}-${timestamp}.zip"
  local backup_file="$backup_dir/$backup_filename"

  # Get table count
  local table_count
  table_count=$(wp db tables --path="$source_root" 2>/dev/null | wc -l | tr -d ' ')

  log "Site URL: $site_url"
  log "Database tables: $table_count"

  # 3. DISK SPACE CHECK

  log_verbose "Calculating backup size..."
  local required_space
  required_space=$(calculate_backup_size_local "$source_root")

  log_verbose "Checking available disk space..."
  local available_space
  available_space=$(df -P "$backup_dir" | tail -1 | awk '{print $4}')

  if [[ $available_space -lt $required_space ]]; then
    err "Insufficient disk space for backup

Required: ${required_space}KB
Available: ${available_space}KB
Location: $backup_dir"
  fi

  log_verbose "Disk space check passed (required: ${required_space}KB, available: ${available_space}KB)"

  # 4. CREATE BACKUP

  # Create temp directory for staging
  local temp_dir
  temp_dir=$(mktemp -d) || err "Failed to create temporary directory"

  # Ensure cleanup on exit
  # shellcheck disable=SC2064  # temp_dir is fixed at trap time, this expansion is intentional
  trap "rm -rf '$temp_dir'" EXIT

  # Export database
  log "Exporting database..."
  if ! wp db export "$temp_dir/database.sql" --path="$source_root" 2>/dev/null; then
    err "Database export failed

Verify:
  1. Database connection is working
  2. User has export permissions
  3. Adequate disk space in temp directory"
  fi

  # Generate metadata
  log_verbose "Generating metadata..."
  cat > "$temp_dir/wpmigrate-backup.json" <<EOF
{
  "format_version": "1.0",
  "created_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "wp_migrate_version": "$VERSION",
  "source_url": "$site_url",
  "database_tables": $table_count,
  "backup_mode": "local",
  "exclusions": [
    "wp-content/cache",
    "wp-content/*/cache",
    "wp-content/object-cache.php",
    "wp-content/advanced-cache.php",
    "wp-content/debug.log",
    "wp-content/**/*.log"
  ]
}
EOF

  # Copy wp-content with exclusions
  log "Copying wp-content directory..."
  rsync -a \
    --exclude='cache/' \
    --exclude='*/cache/' \
    --exclude='object-cache.php' \
    --exclude='advanced-cache.php' \
    --exclude='debug.log' \
    --exclude='*.log' \
    "$source_root/wp-content/" "$temp_dir/wp-content/" || err "Failed to copy wp-content directory"

  # Create ZIP archive
  log "Creating archive..."
  (cd "$temp_dir" && zip -r -q "$backup_file" .) || err "Failed to create archive"

  log_verbose "Archive created successfully"

  # Clean up temp directory (trap will also handle this)
  rm -rf "$temp_dir"
  trap - EXIT

  # 5. REPORT SUCCESS

  local display_path="${backup_file/#$HOME/~}"
  log ""
  log "✓ Backup created successfully"
  log ""
  log "Backup location: $display_path"
  log "Source URL: $site_url"
  log "Database tables: $table_count"
  log ""
  log "To import this backup on another server:"
  log "  ./wp-migrate.sh --archive $display_path"
  log ""

  return 0
}

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

  # SAFETY: Emergency database restore on failure (Issue #82)
  # If script failed during database operations and we have a snapshot, restore it
  if [[ $status -ne 0 && -f "${EMERGENCY_DB_SNAPSHOT:-}" ]]; then
    echo "EMERGENCY: Script failed during database operations. Restoring from snapshot..."
    wp_local db reset --yes 2>/dev/null || true
    if wp_local db import "$EMERGENCY_DB_SNAPSHOT" 2>/dev/null; then
      echo "Emergency database restore successful"
      rm -f "$EMERGENCY_DB_SNAPSHOT" 2>/dev/null || true
    else
      echo "WARNING: Emergency database restore failed - manual recovery may be needed"
      echo "Snapshot file preserved at: $EMERGENCY_DB_SNAPSHOT"
    fi
  fi

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

  # SECURITY: Validate extracted files don't escape extraction directory (Zip Slip protection)
  log_verbose "Validating extracted file paths..."
  local extracted_file realpath_result validation_failed=false
  while IFS= read -r -d '' extracted_file; do
    # Get absolute path, following symlinks
    if ! realpath_result=$(readlink -f "$extracted_file" 2>/dev/null); then
      # readlink -f might fail on macOS, try realpath
      if ! realpath_result=$(realpath "$extracted_file" 2>/dev/null); then
        log_warning "Could not resolve path for: $extracted_file"
        continue
      fi
    fi

    # Check if resolved path is within extraction directory
    if [[ "$realpath_result" != "$ARCHIVE_EXTRACT_DIR"* ]]; then
      log_warning "SECURITY: Archive contains path outside extraction directory: $extracted_file"
      validation_failed=true
    fi
  done < <(find "$ARCHIVE_EXTRACT_DIR" -print0 2>/dev/null)

  if $validation_failed; then
    rm -rf "$ARCHIVE_EXTRACT_DIR"
    err "Archive extraction failed security validation.

This archive contains files with paths that would write outside the extraction
directory (potential Zip Slip attack). This could be:
  • A malicious archive designed to exploit path traversal
  • A corrupted archive with invalid file paths
  • An archive created with absolute paths or ../ components

For security, this archive cannot be used. If you trust the source:
  1. Verify the archive integrity
  2. Re-create the archive ensuring relative paths only
  3. Ensure no ../ components in file paths"
  fi

  log "Archive extracted successfully"
}

find_archive_database_file() {
  local extract_dir="$1"

  # SAFETY: Even in dry-run mode, do real database file detection (Issue #86)
  # This allows preview to show accurate information and prevents crashes
  # from fake file paths being used in file size operations
  if $DRY_RUN; then
    log "[dry-run] Searching for database file using $(get_archive_format_name) adapter (preview only)"
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
$([ "$format_name" = "Solid Backups NextGen" ] && echo "  • data/*_*.sql (multiple files, one per table)")

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
       --archive-type solidbackups_nextgen
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

  # SAFETY: Even in dry-run mode, do real wp-content detection (Issue #86)
  # This allows preview to show accurate information and prevents crashes
  # from fake directory paths being used in file size operations
  if $DRY_RUN; then
    log "[dry-run] Auto-detecting wp-content directory using $(get_archive_format_name) adapter (preview only)"
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
$([ "$format_name" = "Solid Backups NextGen" ] && echo "
For Solid Backups NextGen, wp-content is typically in:
  • files/wp-content/ (single site)
  • files/subdomains/{site}/wp-content/ (multisite)")

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

# Check if a plugin should be excluded from preservation logic
# Returns 0 (true) if should exclude, 1 (false) if should preserve
should_exclude_plugin() {
  local plugin="$1"

  # WordPress drop-ins (not actual plugins)
  local dropins=("advanced-cache.php" "db.php" "db-error.php")
  for dropin in "${dropins[@]}"; do
    if [[ "$plugin" == "$dropin" ]]; then
      FILTERED_DROPINS+=("$plugin")
      return 0
    fi
  done

  # StellarSites managed plugins (when in StellarSites mode)
  if $STELLARSITES_MODE; then
    local managed_plugins=("stellarsites-cloud")
    for managed in "${managed_plugins[@]}"; do
      if [[ "$plugin" == "$managed" ]]; then
        FILTERED_MANAGED_PLUGINS+=("$plugin")
        return 0
      fi
    done
  fi

  return 1  # Don't exclude - preserve this plugin
}

# Detect plugins on destination (before migration)
detect_dest_plugins_push() {
  local host="$1" root="$2"
  if $DRY_RUN; then
    log "[dry-run] Detecting destination plugins (read-only operation)..."
  fi

  local plugins_csv plugin
  plugins_csv=$(wp_remote "$host" "$root" plugin list --field=name --format=csv 2>/dev/null || echo "")
  if [[ -n "$plugins_csv" ]]; then
    DEST_PLUGINS_BEFORE=()
    # Clear filtering tracking arrays
    FILTERED_DROPINS=()
    FILTERED_MANAGED_PLUGINS=()

    while IFS= read -r plugin; do
      if [[ -n "$plugin" ]] && ! should_exclude_plugin "$plugin"; then
        DEST_PLUGINS_BEFORE+=("$plugin")
      fi
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
    log "[dry-run] Detecting destination plugins (read-only operation)..."
  fi

  local plugins_csv plugin
  plugins_csv=$(wp_local plugin list --field=name --format=csv 2>/dev/null || echo "")
  if [[ -n "$plugins_csv" ]]; then
    DEST_PLUGINS_BEFORE=()
    # Clear filtering tracking arrays
    FILTERED_DROPINS=()
    FILTERED_MANAGED_PLUGINS=()

    while IFS= read -r plugin; do
      if [[ -n "$plugin" ]] && ! should_exclude_plugin "$plugin"; then
        DEST_PLUGINS_BEFORE+=("$plugin")
      fi
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

# ========================================
# Progress Indicator System
# ========================================

# Check if pv is available for progress monitoring
has_pv() {
  command -v pv >/dev/null 2>&1
}

# Wrap a command with progress indicator if pv is available
# Usage: run_with_progress <description> <command...>
# Example: run_with_progress "Extracting archive" unzip -q archive.zip -d dest/
run_with_progress() {
  local description="$1"
  shift

  # If --quiet flag is set, suppress progress output
  if $QUIET_MODE; then
    "$@"
    return $?
  fi

  log "$description..."

  # If pv is available and we're in an interactive terminal, use it for progress
  if has_pv && [[ -t 1 ]]; then
    # pv will show progress bar
    "$@" 2>&1 | pv -N "$description" -l -s 1000 >/dev/null
    return "${PIPESTATUS[0]}"
  else
    # Fallback: just run the command and show completion message
    if "$@"; then
      log "  ✓ $description complete"
      return 0
    else
      local exit_code=$?
      log "  ✗ $description failed (exit code: $exit_code)"
      return $exit_code
    fi
  fi
}

# Pipe data through pv with progress indicator
# Usage: cat file | pipe_progress "Description" | consumer
# Or: pipe_progress "Description" size_in_bytes < file > output
pipe_progress() {
  local description="$1"
  local size="${2:-}"

  # If --quiet flag is set, just pass through
  if $QUIET_MODE; then
    cat
    return 0
  fi

  # If pv is available and we're in an interactive terminal, use it
  if has_pv && [[ -t 2 ]]; then
    if [[ -n "$size" ]]; then
      pv -N "$description" -s "$size"
    else
      pv -N "$description" -l
    fi
  else
    # Fallback: just pass through without progress
    cat
  fi
}

# ========================================
# Rollback System
# ========================================

# Find the latest backup created by wp-migrate.sh
# Returns: echoes backup info as "db_path|wp_content_path" or empty if none found
find_latest_backup() {
  local db_backup="" wp_content_backup=""

  # Find latest database backup in db-backups/
  if [[ -d "db-backups" ]]; then
    db_backup=$(find db-backups -name "pre-archive-backup_*.sql.gz" -type f 2>/dev/null | sort -r | head -1)
  fi

  # Find latest wp-content backup (matches pattern: wp-content.backup-TIMESTAMP)
  local wp_content_path
  wp_content_path=$(wp_local eval 'echo WP_CONTENT_DIR;' 2>/dev/null)
  if [[ -n "$wp_content_path" ]]; then
    wp_content_backup=$(find "$(dirname "$wp_content_path")" -maxdepth 1 -type d -name "$(basename "$wp_content_path").backup-*" 2>/dev/null | sort -r | head -1)
  fi

  # Return both paths
  if [[ -n "$db_backup" || -n "$wp_content_backup" ]]; then
    echo "${db_backup:-}|${wp_content_backup:-}"
    return 0
  fi

  return 1
}

# Rollback to a previous backup
# Usage: rollback_migration <db_backup_path> <wp_content_backup_path>
rollback_migration() {
  local db_backup="$1"
  local wp_content_backup="$2"
  local wp_content_path

  wp_content_path=$(wp_local eval 'echo WP_CONTENT_DIR;' 2>/dev/null)

  log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  log "ROLLBACK PLAN"
  log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  if [[ -n "$db_backup" ]]; then
    log "Database: Restore from $(basename "$db_backup")"
  else
    log "Database: No backup found (will skip)"
  fi

  if [[ -n "$wp_content_backup" ]]; then
    log "wp-content: Restore from $(basename "$wp_content_backup")"
  else
    log "wp-content: No backup found (will skip)"
  fi

  log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  if $DRY_RUN; then
    log "[dry-run] Would perform rollback (no changes made)"
    return 0
  fi

  # Confirmation prompt (skip if --yes flag is set)
  if ! $YES_MODE; then
    # Detect non-interactive stdin (CI/cron/piped input)
    if [[ ! -t 0 ]]; then
      err "Interactive confirmation required but stdin is not a terminal.

This rollback requires user confirmation before proceeding.

Running in non-interactive context (CI/cron/pipeline) detected.

Solutions:
  1. Add --yes flag to skip confirmation (recommended for automation):
       ./wp-migrate.sh --rollback --yes

  2. Use --dry-run to preview without confirmation:
       ./wp-migrate.sh --rollback --dry-run

Note: Earlier versions ran without confirmation. To restore that behavior,
add --yes to your automation scripts."
    fi

    log ""
    log "⚠️  WARNING: This will replace your current site with the backup."
    log ""
    read -p "Are you sure you want to proceed with rollback? (yes/no): " -r
    echo
    if [[ ! "$REPLY" =~ ^[Yy][Ee][Ss]$ ]]; then
      log "Rollback cancelled by user."
      exit 0
    fi
  else
    log "Skipping confirmation prompt (--yes flag set)"
  fi

  # Rollback database
  if [[ -n "$db_backup" && -f "$db_backup" ]]; then
    log "Restoring database from backup..."
    if gunzip -c "$db_backup" | wp_local db import -; then
      log "✓ Database restored successfully"
    else
      err "Failed to restore database from: $db_backup

The database import failed. Your current database may be in an inconsistent state.

Next steps:
  1. Try importing manually:
       wp db import <(gunzip -c $db_backup)
  2. Check database credentials in wp-config.php
  3. Verify MySQL is running and accessible"
    fi
  fi

  # Rollback wp-content
  if [[ -n "$wp_content_backup" && -d "$wp_content_backup" ]]; then
    log "Restoring wp-content from backup..."
    if [[ -d "$wp_content_path" ]]; then
      log "  Removing current wp-content..."
      rm -rf "$wp_content_path"
    fi
    log "  Restoring from backup..."
    if mv "$wp_content_backup" "$wp_content_path"; then
      log "✓ wp-content restored successfully"
    else
      err "Failed to restore wp-content from: $wp_content_backup

The wp-content restore failed.

Next steps:
  1. Try restoring manually:
       rm -rf $wp_content_path
       mv $wp_content_backup $wp_content_path
  2. Check file permissions
  3. Verify disk space"
    fi
  fi

  log ""
  log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  log "✓ Rollback completed successfully"
  log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# ========================================
# Migration Preview System
# ========================================

# Display migration summary and confirmation prompt
# Usage: show_migration_preview
show_migration_preview() {
  log ""
  log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  log "MIGRATION PREVIEW"
  log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  if [[ "$MIGRATION_MODE" == "push" ]]; then
    show_push_mode_preview
  elif [[ "$MIGRATION_MODE" == "archive" ]]; then
    show_archive_mode_preview
  fi

  log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  # Skip confirmation if --dry-run or --yes is set
  if $DRY_RUN; then
    log "[dry-run] Skipping confirmation prompt (dry-run mode)"
    return 0
  fi

  if $YES_MODE; then
    log "Proceeding with migration (--yes flag set)"
    log ""
    return 0
  fi

  # Detect non-interactive stdin (CI/cron/piped input)
  if [[ ! -t 0 ]]; then
    err "Interactive confirmation required but stdin is not a terminal.

This migration requires user confirmation before proceeding.

Running in non-interactive context (CI/cron/pipeline) detected.

Solutions:
  1. Add --yes flag to skip confirmation (recommended for automation):
       ./wp-migrate.sh [options] --yes

  2. Use --dry-run to preview without confirmation:
       ./wp-migrate.sh [options] --dry-run

Note: Earlier versions ran without confirmation. To restore that behavior,
add --yes to your automation scripts."
  fi

  # Confirmation prompt
  log ""
  read -p "Proceed with migration? [y/N]: " -r
  echo
  if [[ ! "$REPLY" =~ ^[Yy]$ ]]; then
    log "Migration cancelled by user."
    exit 0
  fi
  log ""
}

# Display push mode migration preview
show_push_mode_preview() {
  log "Mode: PUSH (source → destination via SSH)"
  log ""
  log "Source:"
  log "  Location: $(hostname):$PWD"
  if [[ -n "$SOURCE_DISPLAY_URL" ]]; then
    log "  URL: $SOURCE_DISPLAY_URL"
  fi
  log "  wp-content: $SRC_WP_CONTENT ($SRC_SIZE)"
  log ""
  log "Destination:"
  log "  Location: $DEST_HOST:$DEST_ROOT"
  if [[ -n "$DEST_DISPLAY_URL" ]]; then
    log "  URL: $DEST_DISPLAY_URL"
  fi
  log "  wp-content: $DST_WP_CONTENT"
  log "  Free space: $DST_FREE"
  log ""
  log "Operations:"
  log "  • Export database from source"
  if $GZIP_DB; then
    log "  • Transfer database to destination (gzipped)"
  else
    log "  • Transfer database to destination (uncompressed)"
  fi
  if $IMPORT_DB; then
    log "  • Import database on destination"
    if $URL_ALIGNMENT_REQUIRED; then
      if $SEARCH_REPLACE; then
        log "  • Run search-replace for URL alignment"
      else
        log "  • Update home/siteurl only (--no-search-replace)"
      fi
    fi
  else
    log "  • Skip database import (--no-import-db)"
  fi
  log "  • Backup destination wp-content"
  log "  • Sync wp-content from source to destination"
  if $PRESERVE_DEST_PLUGINS && [[ ${#UNIQUE_DEST_PLUGINS[@]} -gt 0 || ${#UNIQUE_DEST_THEMES[@]} -gt 0 ]]; then
    log "  • Restore unique destination plugins/themes"
  fi
  log ""
  log "Maintenance mode: "
  if $MAINTENANCE_SOURCE; then
    log "  Source: YES"
  else
    log "  Source: NO (--no-maint-source)"
  fi
  log "  Destination: YES"
}

# Display archive mode migration preview
show_archive_mode_preview() {
  local archive_size db_size wp_content_size wp_content_count

  # Get archive size
  archive_size=$(du -sh "$ARCHIVE_FILE" 2>/dev/null | cut -f1 || echo "unknown")

  # Get database size (if already extracted)
  if [[ -n "$ARCHIVE_DB_FILE" && -f "$ARCHIVE_DB_FILE" ]]; then
    db_size=$(du -sh "$ARCHIVE_DB_FILE" 2>/dev/null | cut -f1 || echo "unknown")
  else
    db_size="unknown"
  fi

  # Get wp-content size and file count (if already extracted)
  if [[ -n "$ARCHIVE_WP_CONTENT" && -d "$ARCHIVE_WP_CONTENT" ]]; then
    wp_content_size=$(du -sh "$ARCHIVE_WP_CONTENT" 2>/dev/null | cut -f1 || echo "unknown")
    wp_content_count=$(find "$ARCHIVE_WP_CONTENT" -type f 2>/dev/null | wc -l | tr -d ' ' || echo "unknown")
  else
    wp_content_size="unknown"
    wp_content_count="unknown"
  fi

  log "Mode: ARCHIVE (import backup to current site)"
  log ""
  log "Archive:"
  log "  File: $(basename "$ARCHIVE_FILE")"
  log "  Format: $(get_archive_format_name)"
  log "  Size: $archive_size"
  log ""
  log "Archive Contents:"
  log "  Database: $db_size"
  log "  wp-content: $wp_content_size ($wp_content_count files)"
  log ""
  log "Destination:"
  log "  Location: $(hostname):$PWD"
  if [[ -n "$ORIGINAL_DEST_HOME_URL" ]]; then
    log "  Current URL: $ORIGINAL_DEST_HOME_URL"
  fi
  log ""
  log "Operations:"
  log "  • Backup current database → db-backups/pre-archive-backup_${STAMP}.sql.gz"
  log "  • Backup current wp-content → $(basename "${DEST_WP_CONTENT:-wp-content}").backup-${STAMP}"
  if $IMPORT_DB; then
    log "  • Import database from archive"
    log "  • Restore original URLs (prevent archive URLs from leaking)"
  else
    log "  • Skip database import (--no-import-db)"
  fi
  log "  • Replace wp-content with archive content"
  if $PRESERVE_DEST_PLUGINS && [[ ${#UNIQUE_DEST_PLUGINS[@]} -gt 0 || ${#UNIQUE_DEST_THEMES[@]} -gt 0 ]]; then
    log "  • Restore unique destination plugins/themes"
  fi
  log ""
  log "Maintenance mode: YES"
}

print_usage() {
  cat <<USAGE
Usage:

PUSH MODE (run on SOURCE WP root):
  $(basename "$0") --dest-host <user@host> --dest-root </abs/path> [options]

ARCHIVE MODE (run on DESTINATION WP root):
  $(basename "$0") --archive </path/to/backup> [options]

ROLLBACK MODE (run on DESTINATION WP root):
  $(basename "$0") --rollback [--rollback-backup </path/to/backup>]

BACKUP CREATION MODE (run from WordPress root OR via SSH):
  Local:  $(basename "$0") --create-backup [--source-root </abs/path>]
  Remote: $(basename "$0") --source-host <user@host> --source-root </abs/path> --create-backup

Required (choose one mode):
  --dest-host <user@dest.example.com>
  --dest-root </absolute/path/to/destination/wp-root>
      Push mode: migrate from current host to destination via SSH

  --archive </path/to/backup>
      Archive mode: import backup archive to current host
      Supported formats: Duplicator, Jetpack Backup, Solid Backups Legacy, Solid Backups NextGen
      (mutually exclusive with --dest-host)

  --archive-type <type>
      Optional: Specify archive format (duplicator, jetpack, solidbackups, solidbackups_nextgen)
      If not specified, format will be auto-detected

  --duplicator-archive </path/to/backup.zip>
      Deprecated: Use --archive instead (backward compatibility maintained)

  --rollback
      Rollback mode: restore from backups created during previous migration
      Automatically finds latest backup or use --rollback-backup to specify

  --rollback-backup </path/to/backup.sql.gz>
      Optional: Explicitly specify which database backup to restore
      (only used with --rollback)

  --create-backup
      Backup creation mode: create WordPress backup locally or remotely
      Local mode: Run from WordPress root (no SSH required)
      Remote mode: Specify --source-host for SSH-based backup
      Creates timestamped ZIP archive with database and wp-content
      (mutually exclusive with --dest-host and --archive)

  --source-host <user@source.example.com>
      SSH connection string for remote backup creation
      When specified with --create-backup, enables remote backup mode
      When omitted with --create-backup, uses local backup mode

  --source-root </absolute/path/to/wordpress>
      Absolute path to WordPress root
      Local backup: Optional, defaults to current directory
      Remote backup: Required when using --source-host

Options:
  --dry-run                 Preview rsync; DB export/transfer is also previewed (no dump created)
  --quiet                   Suppress progress indicators for long-running operations (useful for non-interactive scripts)
  --yes                     Skip confirmation prompts (useful for automation)
  --verbose                 Show additional details (dependency checks, command construction, detection process)
  --trace                   Show every command before execution (implies --verbose). Useful for debugging and reproducing issues.
  --import-db               (Deprecated) Explicitly import the DB on destination (default behavior)
  --no-import-db            Skip importing the DB on destination after transfer
  --no-search-replace       Skip bulk search-replace but still update home/siteurl options (faster migrations when URL replacement in content is not needed)
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
  $(basename "$0") --dest-host wp@dest --dest-root /var/www/site --yes

Examples (archive mode):
  $(basename "$0") --archive /path/to/backup_20251009.zip
  $(basename "$0") --archive /backups/site.zip --dry-run
  $(basename "$0") --archive /backups/site.zip --stellarsites
  $(basename "$0") --archive /backups/site.tar.gz --archive-type jetpack --yes

Examples (rollback mode):
  $(basename "$0") --rollback
  $(basename "$0") --rollback --dry-run
  $(basename "$0") --rollback --rollback-backup /path/to/specific/backup.sql.gz
  $(basename "$0") --rollback --yes

Examples (backup creation mode):
  $(basename "$0") --source-host user@source.example.com --source-root /var/www/html --create-backup
  $(basename "$0") --source-host user@source.example.com --source-root /var/www/html --create-backup --dry-run
  $(basename "$0") --source-host user@source.example.com --source-root /var/www/html --create-backup --verbose

NOTES:
  - All WP-CLI commands skip loading plugins and themes for reliability
  - This prevents plugin errors from breaking migrations or rollbacks
  - Migration operations use low-level database and filesystem commands
  - If you need WP-CLI with plugins loaded, use 'wp' command directly

USAGE
}

