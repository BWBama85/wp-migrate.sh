# Local Backup Mode Design

**Date:** 2025-11-11
**Feature:** Local backup mode for `--create-backup`
**Version:** 1.0

## Overview

Enhance the `--create-backup` feature to support local WordPress backups without requiring SSH. Users can run `./wp-migrate.sh --create-backup` directly from a WordPress directory to create a backup of the local installation.

## Problem Statement

Current backup creation (v2.8.0) always requires `--source-host` and `--source-root`, forcing users to set up SSH even when backing up a local WordPress site. This is unnecessarily complex for the common use case of backing up a local development environment or a WordPress installation on the same server where wp-migrate.sh runs.

## User Workflows

### New: Local Backup Mode
```bash
# Simplest case: run from WordPress root directory
cd /var/www/mysite
./wp-migrate.sh --create-backup

# With explicit path
./wp-migrate.sh --create-backup --source-root /var/www/mysite
```

### Existing: Remote Backup Mode (unchanged)
```bash
./wp-migrate.sh --create-backup \
                --source-host user@remote.com \
                --source-root /var/www/html
```

## Requirements

1. Support local backup creation without SSH configuration
2. Default to current directory when `--source-root` not provided
3. Maintain full backwards compatibility with remote backup mode
4. Produce identical archive format (compatible with existing `--archive` import)
5. Provide clear error messages distinguishing local vs remote context

## Architecture

### Mode Detection

Mode is determined by presence of `--source-host` flag:

- **No `--source-host`**: Local backup mode
  - `--source-root` optional (defaults to `pwd`)
  - No SSH operations
  - Direct wp-cli and file system access

- **With `--source-host`**: Remote backup mode (existing behavior)
  - `--source-root` required
  - All operations via SSH
  - Existing implementation unchanged

### Implementation Approach: Separate Functions

**Chosen:** Create separate `create_backup_local()` function alongside existing `create_backup()` (remote).

**Rationale:**
- Clean separation of concerns (local vs SSH execution contexts)
- No conditional branching complexity within functions
- Matches existing codebase pattern (separate mode handlers)
- Easier to test and debug
- Acceptable code duplication given different execution contexts

**Shared Components:**
- `sanitize_domain_for_filename()` - domain sanitization
- `calculate_backup_size()` - needs local variant without SSH
- Metadata JSON generation logic
- Exclusion patterns array

## Detailed Design

### Mode Detection Logic (src/main.sh)

```bash
elif $CREATE_BACKUP; then
  if [[ -z "$SOURCE_HOST" ]]; then
    # Local backup mode
    MIGRATION_MODE="backup-local"
    log "Local backup mode enabled"

    # Default to current directory if not specified
    if [[ -z "$SOURCE_ROOT" ]]; then
      SOURCE_ROOT="$(pwd)"
    else
      # Convert to absolute path
      SOURCE_ROOT="$(cd "$SOURCE_ROOT" && pwd)" || err "Invalid path: $SOURCE_ROOT"
    fi

    # Local backup is mutually exclusive with --dest-host
    [[ -n "$DEST_HOST" ]] && err "--create-backup (local) is mutually exclusive with --dest-host"

  else
    # Remote backup mode (existing)
    MIGRATION_MODE="backup-remote"
    log "Remote backup mode enabled"

    # Both --source-host and --source-root required
    [[ -z "$SOURCE_ROOT" ]] && err "--create-backup with --source-host requires --source-root"
  fi

  # Mutual exclusivity with archive mode (applies to both local and remote)
  [[ -n "$ARCHIVE_FILE" ]] && err "--create-backup is mutually exclusive with --archive"
fi
```

### Function Routing (src/main.sh)

```bash
# Execute migration based on mode
case "$MIGRATION_MODE" in
  push)
    migrate
    ;;
  archive)
    import_archive
    ;;
  rollback)
    rollback_migration
    ;;
  backup-local)
    create_backup_local  # New function
    ;;
  backup-remote)
    create_backup  # Existing function (renamed for clarity)
    ;;
esac
```

### New Function: create_backup_local() (src/lib/functions.sh)

```bash
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

  # Create backup directory
  local backup_dir="$HOME/wp-migrate-backups"
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
  table_count=$(wp db tables --format=count --path="$source_root" 2>/dev/null || echo "0")

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
  "wp_migrate_version": "$(grep '^VERSION=' "$0" | cut -d'"' -f2)",
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
```

### New Helper: calculate_backup_size_local() (src/lib/functions.sh)

```bash
# Calculate required disk space for local backup
# Usage: calculate_backup_size_local <wordpress_root>
# Returns: Required space in KB (with 50% buffer)
calculate_backup_size_local() {
  local root="$1"
  local db_size wp_content_size

  # Get database size via wp-cli (sum all table sizes from CSV)
  local db_size_bytes
  db_size_bytes=$(wp db size --format=csv --path="$root" 2>/dev/null | tail -n +2 | awk -F',' '{
    gsub(/"/,"",$2);
    if (match($2, /([0-9.]+) *([KMGT]?i?B)/, arr)) {
      value = arr[1];
      unit = arr[2];

      # Convert to bytes based on unit
      if (unit == "B")        multiplier = 1;
      else if (unit == "KB")  multiplier = 1024;
      else if (unit == "MB")  multiplier = 1024*1024;
      else if (unit == "GB")  multiplier = 1024*1024*1024;
      else if (unit == "TB")  multiplier = 1024*1024*1024*1024;
      # Binary IEC units
      else if (unit == "KiB") multiplier = 1024;
      else if (unit == "MiB") multiplier = 1024*1024;
      else if (unit == "GiB") multiplier = 1024*1024*1024;
      else if (unit == "TiB") multiplier = 1024*1024*1024*1024;
      else                    multiplier = 1;

      sum += value * multiplier;
    }
  } END {print int(sum)}' || echo "0")

  db_size=$((db_size_bytes / 1024))

  # Get wp-content size (excluding cache, logs, etc.)
  wp_content_size=$(du -sk "$root/wp-content" \
    --exclude='cache' \
    --exclude='*/cache' \
    --exclude='*.log' 2>/dev/null | awk '{print $1}' || echo "0")

  # Add 50% buffer for compression overhead and safety margin
  local total=$((db_size + wp_content_size))
  local with_buffer=$((total + total / 2))

  echo "$with_buffer"
}
```

## Error Handling

### Validation Errors
- **WordPress not found**: Clear message about wp-config.php location
- **wp-cli missing**: Installation instructions with curl command
- **WordPress not functional**: Guidance to check database connection
- **Insufficient disk space**: Show required vs available space

### Mutual Exclusivity
- Local backup mode (`--create-backup` without `--source-host`) cannot use `--dest-host`
- Both modes cannot use `--archive` (existing check)

### Edge Cases
- **Relative path in `--source-root`**: Convert to absolute with `cd && pwd`
- **Backup directory doesn't exist**: Create with `mkdir -p`
- **Site URL detection fails**: Fall back to "localhost"
- **Temp directory cleanup**: Use trap to ensure cleanup even on failure

## Testing Strategy

### Manual Test Cases
1. **Local backup from WordPress root:**
   ```bash
   cd /var/www/wordpress
   ./wp-migrate.sh --create-backup
   ```

2. **Local backup with explicit path:**
   ```bash
   ./wp-migrate.sh --create-backup --source-root /var/www/wordpress
   ```

3. **Remote backup (verify unchanged):**
   ```bash
   ./wp-migrate.sh --create-backup --source-host user@host --source-root /path
   ```

4. **Import local backup:**
   ```bash
   ./wp-migrate.sh --archive ~/wp-migrate-backups/backup.zip
   ```

5. **Error conditions:**
   - Run from non-WordPress directory
   - Run without wp-cli installed
   - Run with insufficient disk space

### CI Validation
- ShellCheck linting (automatic)
- Build validation (automatic)
- Archive format compatibility test

## Documentation Updates

### README.md
- Add "Local Backup Mode" section before "Backup Creation Mode"
- Show simplest example first (local without flags)
- Clarify `--source-host` determines mode

### CHANGELOG.md
```markdown
## [Unreleased]

### Added

- **Local backup mode**: Run `--create-backup` without `--source-host` to back up local WordPress installations
  - Defaults to current directory when run from WordPress root
  - Optional `--source-root` to specify different local path
  - No SSH configuration required for local backups
  - Produces same archive format as remote backups
```

### Help Text (src/main.sh)
Update `print_usage()` to show both modes:
```
--create-backup        Create a WordPress backup

  Local mode (no SSH):
    ./wp-migrate.sh --create-backup

  Remote mode (via SSH):
    ./wp-migrate.sh --create-backup \
                    --source-host user@remote.com \
                    --source-root /var/www/html
```

## Backwards Compatibility

**No breaking changes:**
- Existing remote backup workflows work identically
- `--source-host` presence determines mode (same flag behavior)
- Archive format unchanged (both modes produce compatible ZIPs)
- Existing `create_backup()` function renamed but logic unchanged

## Implementation Checklist

- [ ] Add mode detection logic to src/main.sh
- [ ] Rename existing `create_backup()` to clarify it's remote mode
- [ ] Implement `create_backup_local()` function
- [ ] Implement `calculate_backup_size_local()` helper
- [ ] Update function routing in src/main.sh
- [ ] Update print_usage() help text
- [ ] Update README.md with local backup examples
- [ ] Update CHANGELOG.md
- [ ] Build and validate with ShellCheck
- [ ] Manual testing of all scenarios
- [ ] Commit and create PR

## Future Enhancements (Out of Scope)

- Progress indicators for local backup operations
- Configurable backup output directory (currently hardcoded to ~/wp-migrate-backups)
- Support for multisite local backups
- Parallel compression for faster archive creation
