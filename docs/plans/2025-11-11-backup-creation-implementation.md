# Backup Creation Feature Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add `--create-backup` flag to create WordPress backups on source servers via SSH in a format compatible with `--archive` import mode.

**Architecture:** New "backup mode" that connects to source server via SSH, exports database + wp-content with exclusions, creates timestamped ZIP with metadata JSON, stores in `~/wp-migrate-backups/`. New adapter (`wpmigrate`) validates/imports these backups.

**Tech Stack:** Bash, wp-cli (remote), rsync, zip, jq (for JSON validation)

---

## Task 1: Create wp-migrate Adapter Foundation

**Files:**
- Create: `src/lib/adapters/wpmigrate.sh`

### Step 1: Create adapter file with header and validate function

**Create file:** `src/lib/adapters/wpmigrate.sh`

```bash
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
```

### Step 2: Add extract function

**Append to:** `src/lib/adapters/wpmigrate.sh`

```bash

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
```

### Step 3: Add database and wp-content finder functions

**Append to:** `src/lib/adapters/wpmigrate.sh`

```bash

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
```

### Step 4: Add metadata and dependency functions

**Append to:** `src/lib/adapters/wpmigrate.sh`

```bash

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
```

### Step 5: Verify shellcheck passes on adapter

Run: `shellcheck src/lib/adapters/wpmigrate.sh`
Expected: No errors

### Step 6: Commit adapter foundation

```bash
git add src/lib/adapters/wpmigrate.sh
git commit -m "feat: add wpmigrate archive adapter foundation

Implements validation, extraction, and content detection for wp-migrate
native backup format. Validates presence of wpmigrate-backup.json
signature file with format_version field.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## Task 2: Register Adapter and Update Build System

**Files:**
- Modify: `src/lib/functions.sh:11`
- Modify: `Makefile:22-45`

### Step 1: Register wpmigrate adapter (first position)

**Edit:** `src/lib/functions.sh` line 11

**Change:**
```bash
AVAILABLE_ADAPTERS=("duplicator" "jetpack" "solidbackups" "solidbackups_nextgen")
```

**To:**
```bash
AVAILABLE_ADAPTERS=("wpmigrate" "duplicator" "jetpack" "solidbackups" "solidbackups_nextgen")
```

### Step 2: Update Makefile test target to include wpmigrate adapter

**Edit:** `Makefile` line 22 (in test target, after base.sh)

**Add line:**
```makefile
	     src/lib/adapters/wpmigrate.sh \
```

**Full section should be:**
```makefile
	@cat src/header.sh \
	     src/lib/core.sh \
	     src/lib/adapters/base.sh \
	     src/lib/adapters/wpmigrate.sh \
	     src/lib/adapters/duplicator.sh \
	     src/lib/adapters/jetpack.sh \
	     src/lib/adapters/solidbackups.sh \
	     src/lib/adapters/solidbackups_nextgen.sh \
	     src/lib/functions.sh \
	     src/main.sh > dist/wp-migrate-temp.sh
```

### Step 3: Update Makefile build target to include wpmigrate adapter

**Edit:** `Makefile` line 40 (in build target, after base.sh)

**Add line:**
```makefile
	     src/lib/adapters/wpmigrate.sh \
```

**Full section should be:**
```makefile
	@cat src/header.sh \
	     src/lib/core.sh \
	     src/lib/adapters/base.sh \
	     src/lib/adapters/wpmigrate.sh \
	     src/lib/adapters/duplicator.sh \
	     src/lib/adapters/jetpack.sh \
	     src/lib/adapters/solidbackups.sh \
	     src/lib/adapters/solidbackups_nextgen.sh \
	     src/lib/functions.sh \
	     src/main.sh > dist/wp-migrate.sh
```

### Step 4: Verify build works

Run: `make build`
Expected: Build succeeds with "✓ Built: dist/wp-migrate.sh"

### Step 5: Commit registration changes

```bash
git add src/lib/functions.sh Makefile
git commit -m "feat: register wpmigrate adapter in build system

Add wpmigrate to AVAILABLE_ADAPTERS (first position for fastest
detection) and update Makefile to include adapter in build process.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## Task 3: Add Backup Creation Variables and Helper Functions

**Files:**
- Modify: `src/header.sh:31-35` (add variables)
- Modify: `src/lib/functions.sh` (add helper functions after adapter system section)

### Step 1: Add backup mode variables to header

**Edit:** `src/header.sh` after line 35 (after ROLLBACK_BACKUP_PATH)

**Add:**
```bash
CREATE_BACKUP=false          # Enable backup creation mode (--create-backup flag)
SOURCE_HOST=""               # Source server SSH connection string (user@host)
SOURCE_ROOT=""               # Absolute path to WordPress root on source server
BACKUP_OUTPUT_DIR="~/wp-migrate-backups"  # Directory on source server for backups
```

### Step 2: Add domain sanitization helper function

**Edit:** `src/lib/functions.sh` after the adapter system section (after line ~98)

**Add:**
```bash

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
```

### Step 3: Add disk space calculation helper

**Append to backup helpers section:**

```bash

# Calculate estimated backup size on source server
# Usage: calculate_backup_size <source_host> <source_root>
# Returns: echoes size in KB
calculate_backup_size() {
  local host="$1" root="$2"
  local db_size wp_content_size

  # Get database size via wp-cli
  db_size=$(ssh "${SSH_OPTS[@]}" "$host" "cd '$root' && wp db size --format=csv --path='$root'" | tail -1 | cut -d',' -f2 || echo "0")

  # Get wp-content size (excluding cache, logs, etc.)
  wp_content_size=$(ssh "${SSH_OPTS[@]}" "$host" "du -sk '$root/wp-content' --exclude='cache' --exclude='*/cache' --exclude='*.log' 2>/dev/null" | awk '{print $1}' || echo "0")

  # Add 50% buffer for zip compression overhead
  local total=$((db_size + wp_content_size))
  local with_buffer=$((total + total / 2))

  echo "$with_buffer"
}
```

### Step 4: Add backup directory creation helper

**Append to backup helpers section:**

```bash

# Create backup directory on source server
# Usage: create_backup_directory <source_host> <backup_dir>
# Returns: 0 on success, 1 on failure
create_backup_directory() {
  local host="$1" backup_dir="$2"

  log_verbose "Creating backup directory: $backup_dir"

  if ! ssh "${SSH_OPTS[@]}" "$host" "mkdir -p '$backup_dir'" 2>/dev/null; then
    err "Failed to create backup directory: $backup_dir"
    return 1
  fi

  return 0
}
```

### Step 5: Verify shellcheck passes

Run: `make test`
Expected: "✓ Shellcheck passed"

### Step 6: Commit helper functions

```bash
git add src/header.sh src/lib/functions.sh
git commit -m "feat: add backup creation variables and helper functions

Add CREATE_BACKUP, SOURCE_HOST, SOURCE_ROOT variables. Implement helpers
for domain sanitization, disk space calculation, and backup directory
creation on remote servers.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## Task 4: Implement Core Backup Creation Logic

**Files:**
- Modify: `src/lib/functions.sh` (add main backup function)

### Step 1: Add metadata generation function

**Append to backup helpers section in:** `src/lib/functions.sh`

```bash

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
```

### Step 2: Add main backup creation function (part 1: setup and validation)

**Append to backup helpers section:**

```bash

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
  if ! ssh "${SSH_OPTS[@]}" "$source_host" "true" 2>/dev/null; then
    err "Cannot connect to source host: $source_host

Verify:
  1. SSH access is configured
  2. Host is reachable
  3. Credentials are correct"
  fi

  # Verify WordPress installation exists
  log_verbose "Verifying WordPress installation..."
  if ! ssh "${SSH_OPTS[@]}" "$source_host" "test -f '$source_root/wp-config.php'" 2>/dev/null; then
    err "WordPress installation not found at: $source_root

wp-config.php does not exist.

Verify:
  1. Path is correct
  2. WordPress is installed at this location"
  fi

  # Verify wp-cli is available
  log_verbose "Checking for wp-cli..."
  if ! ssh "${SSH_OPTS[@]}" "$source_host" "command -v wp" 2>/dev/null; then
    err "wp-cli not found on source server

wp-cli is required for database export.

Install wp-cli:
  curl -O https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
  chmod +x wp-cli.phar
  sudo mv wp-cli.phar /usr/local/bin/wp"
  fi

  # Check disk space
  log_verbose "Checking available disk space..."
  local required_space available_space
  required_space=$(calculate_backup_size "$source_host" "$source_root")
  available_space=$(ssh "${SSH_OPTS[@]}" "$source_host" "df -P ~ | tail -1 | awk '{print \$4}'")

  if [[ $available_space -lt $required_space ]]; then
    err "Insufficient disk space on source server

Required: ${required_space}KB (estimated)
Available: ${available_space}KB

Free up space or use a different backup location."
  fi

  log_verbose "Disk space check passed (required: ${required_space}KB, available: ${available_space}KB)"
```

### Step 3: Add main backup creation function (part 2: execution)

**Append to the create_backup function (continuation):**

```bash

  # Create backup directory
  local backup_dir="$BACKUP_OUTPUT_DIR"
  create_backup_directory "$source_host" "$backup_dir"

  # Generate backup filename
  local site_url table_count sanitized_domain timestamp backup_filename
  site_url=$(ssh "${SSH_OPTS[@]}" "$source_host" "cd '$source_root' && wp option get siteurl --path='$source_root'" 2>/dev/null)
  table_count=$(ssh "${SSH_OPTS[@]}" "$source_host" "cd '$source_root' && wp db tables --path='$source_root' | wc -l" 2>/dev/null | tr -d ' ')
  sanitized_domain=$(sanitize_domain_for_filename "$site_url")
  timestamp=$(date -u +%Y-%m-%d-%H%M%S)
  backup_filename="${sanitized_domain}-${timestamp}.zip"

  log "Backup filename: $backup_filename"

  # Create temp directory on source server
  local temp_dir
  temp_dir=$(ssh "${SSH_OPTS[@]}" "$source_host" "mktemp -d /tmp/wp-migrate-backup-XXXXX" 2>/dev/null)

  if [[ -z "$temp_dir" ]]; then
    err "Failed to create temporary directory on source server"
  fi

  log_verbose "Created temp directory: $temp_dir"

  # Export database
  log "Exporting database..."
  if ! ssh "${SSH_OPTS[@]}" "$source_host" "cd '$source_root' && wp db export '$temp_dir/database.sql' --path='$source_root'" 2>/dev/null; then
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
  if ! ssh "${SSH_OPTS[@]}" "$source_host" "rsync -a --exclude='cache/' --exclude='*/cache/' --exclude='object-cache.php' --exclude='advanced-cache.php' --exclude='debug.log' --exclude='*.log' '$source_root/wp-content/' '$temp_dir/wp-content/'" 2>/dev/null; then
    ssh "${SSH_OPTS[@]}" "$source_host" "rm -rf '$temp_dir'" 2>/dev/null
    err "Failed to sync wp-content"
  fi

  log_verbose "wp-content synced successfully"

  # Create zip archive
  log "Creating archive..."
  if ! ssh "${SSH_OPTS[@]}" "$source_host" "cd '$temp_dir' && zip -r '$backup_dir/$backup_filename' ." >/dev/null 2>&1; then
    ssh "${SSH_OPTS[@]}" "$source_host" "rm -rf '$temp_dir'" 2>/dev/null
    err "Failed to create zip archive"
  fi

  log_verbose "Archive created successfully"

  # Clean up temp directory
  ssh "${SSH_OPTS[@]}" "$source_host" "rm -rf '$temp_dir'" 2>/dev/null

  # Report success
  local full_backup_path="$backup_dir/$backup_filename"
  log ""
  log "✓ Backup created successfully"
  log ""
  log "Backup location: $full_backup_path"
  log "Source URL: $site_url"
  log "Database tables: $table_count"
  log ""
  log "To import this backup on another server:"
  log "  ./wp-migrate.sh --archive $full_backup_path"
  log ""

  return 0
}
```

### Step 4: Verify shellcheck passes

Run: `make test`
Expected: "✓ Shellcheck passed"

### Step 5: Commit backup creation logic

```bash
git add src/lib/functions.sh
git commit -m "feat: implement core backup creation logic

Add create_backup() function that orchestrates database export,
wp-content sync with exclusions, metadata generation, and zip archive
creation on remote source server. Includes validation for SSH
connectivity, wp-cli availability, and disk space.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## Task 5: Add Argument Parsing and Mode Detection

**Files:**
- Modify: `src/main.sh:8` (add --create-backup flag)
- Modify: `src/main.sh:30-33` (add --source-host and --source-root flags)
- Modify: `src/main.sh:79-92` (add backup mode detection)

### Step 1: Add --create-backup flag to argument parser

**Edit:** `src/main.sh` after line 8 (after --archive-type)

**Add:**
```bash
    --create-backup) CREATE_BACKUP=true; shift ;;
```

### Step 2: Add --source-host and --source-root flags

**Edit:** `src/main.sh` after line 29 (after --preserve-dest-plugins)

**Add:**
```bash
    --source-host) SOURCE_HOST="${2:-}"; shift 2 ;;
    --source-root) SOURCE_ROOT="${2:-}"; shift 2 ;;
```

### Step 3: Add backup mode detection logic

**Edit:** `src/main.sh` after the rollback mode detection block (around line 108, before archive mode check)

**Insert between rollback and archive mode blocks:**

```bash
elif $CREATE_BACKUP; then
  MIGRATION_MODE="backup"
  log "Backup creation mode enabled"

  # Validate required parameters
  [[ -n "$SOURCE_HOST" ]] || err "--create-backup requires --source-host

Example:
  ./wp-migrate.sh --source-host user@source.example.com \\
                  --source-root /var/www/html \\
                  --create-backup"

  [[ -n "$SOURCE_ROOT" ]] || err "--create-backup requires --source-root

Example:
  ./wp-migrate.sh --source-host user@source.example.com \\
                  --source-root /var/www/html \\
                  --create-backup"

  # Backup mode is mutually exclusive with other modes
  if [[ -n "$ARCHIVE_FILE" ]]; then
    err "--create-backup is mutually exclusive with --archive

You cannot create a backup and import one simultaneously.

Choose one:
  • Create backup: ./wp-migrate.sh --source-host ... --create-backup
  • Import backup: ./wp-migrate.sh --archive /path/to/backup.zip"
  fi

  if [[ -n "$DEST_HOST" ]]; then
    err "--create-backup is mutually exclusive with --dest-host

You cannot create a backup and push to destination simultaneously.

Choose one:
  • Create backup: ./wp-migrate.sh --source-host ... --create-backup
  • Push migration: ./wp-migrate.sh --dest-host ... --dest-root ..."
  fi

```

### Step 4: Add backup mode execution at end of main.sh

**Edit:** `src/main.sh` - find the main execution section (search for where MIGRATION_MODE is checked)

Near the end of the file, after the archive mode execution, add:

```bash
# Execute backup mode
if [[ "$MIGRATION_MODE" == "backup" ]]; then
  if $DRY_RUN; then
    log "=== DRY RUN MODE ==="
    log "Would create backup with:"
    log "  Source: $SOURCE_HOST:$SOURCE_ROOT"
    log "  Destination: $BACKUP_OUTPUT_DIR/<domain>-<timestamp>.zip"
    log ""
    log "Validation checks that would run:"
    log "  ✓ SSH connectivity to $SOURCE_HOST"
    log "  ✓ WordPress installation at $SOURCE_ROOT"
    log "  ✓ wp-cli availability"
    log "  ✓ Disk space requirements"
    log ""
    log "No backup created (dry-run mode)"
    exit 0
  fi

  create_backup
  exit 0
fi
```

### Step 5: Verify shellcheck passes

Run: `make test`
Expected: "✓ Shellcheck passed"

### Step 6: Commit argument parsing

```bash
git add src/main.sh
git commit -m "feat: add backup mode argument parsing and execution

Add --create-backup, --source-host, and --source-root flags. Implement
backup mode detection with validation for required parameters and mutual
exclusivity with other modes. Add dry-run support for backup mode.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## Task 6: Update Documentation

**Files:**
- Modify: `README.md` (add --create-backup usage)
- Modify: `CHANGELOG.md` (add feature entry)
- Modify: `src/lib/adapters/README.md` (document wpmigrate adapter)

### Step 1: Add backup creation section to README

**Edit:** `README.md` - add new section after "Archive Mode" section

**Add:**

```markdown
### Backup Creation Mode

Create a backup on a source WordPress server via SSH. The backup is stored on the source server and can later be imported using archive mode.

```bash
./wp-migrate.sh --source-host user@source.example.com \
                --source-root /var/www/html \
                --create-backup
```

**Features:**
- Creates timestamped ZIP archive on source server
- Includes database dump and wp-content directory
- Automatically excludes cache directories, object cache files, and debug logs
- Stores backup in `~/wp-migrate-backups/` on source server
- Compatible with `--archive` import mode

**Backup location:** `~/wp-migrate-backups/{domain}-{YYYY-MM-DD-HHMMSS}.zip`

**Example workflow:**
```bash
# Step 1: Create backup on source
./wp-migrate.sh --source-host user@source.example.com \
                --source-root /var/www/html \
                --create-backup

# Output: Backup created: ~/wp-migrate-backups/example-com-2025-11-11-143022.zip

# Step 2: Download backup (manual step)
scp user@source.example.com:~/wp-migrate-backups/example-com-2025-11-11-143022.zip .

# Step 3: Import on destination
./wp-migrate.sh --archive example-com-2025-11-11-143022.zip
```

**Dry-run preview:**
```bash
./wp-migrate.sh --source-host user@source.example.com \
                --source-root /var/www/html \
                --create-backup --dry-run
```
```

### Step 2: Update CHANGELOG.md

**Edit:** `CHANGELOG.md` - add entry under `[Unreleased]` section

**Add:**

```markdown
### Added

- **Backup creation mode**: New `--create-backup` flag creates WordPress backups on source servers via SSH
  - Stores backups in `~/wp-migrate-backups/` with timestamped filenames
  - Includes database dump and wp-content directory
  - Automatically excludes cache directories, object cache files, and debug logs
  - Backups compatible with existing `--archive` import mode
- **wp-migrate adapter**: New native archive format with JSON metadata
  - Validates backups via `wpmigrate-backup.json` signature file
  - Simple structure: metadata, database.sql, wp-content/
  - First in adapter detection order for fastest validation
- **Backup creation flags**:
  - `--source-host`: SSH connection to source server
  - `--source-root`: WordPress root path on source server
  - `--create-backup`: Enable backup creation mode
```

### Step 3: Document wpmigrate adapter

**Edit:** `src/lib/adapters/README.md` - add section for wpmigrate adapter

**Add section after existing adapter documentation:**

```markdown
## wp-migrate Backup

**Format:** Native wp-migrate backup format
**Extension:** .zip
**Adapter:** `wpmigrate`

### Archive Structure

```
backup-name-2025-11-11-143022.zip
├── wpmigrate-backup.json     # Metadata (signature file)
├── database.sql              # Full database dump
└── wp-content/               # Filtered WordPress content
    ├── plugins/
    ├── themes/
    └── uploads/
```

### Metadata File

The `wpmigrate-backup.json` file serves as both signature and metadata:

```json
{
  "format_version": "1.0",
  "created_at": "2025-11-11T14:30:22Z",
  "wp_migrate_version": "2.7.0",
  "source_url": "https://example.com",
  "database_tables": 23,
  "exclusions": [
    "wp-content/cache/",
    "wp-content/*/cache/",
    "wp-content/object-cache.php",
    "wp-content/advanced-cache.php",
    "wp-content/debug.log",
    "wp-content/*.log"
  ]
}
```

### Validation

1. Must be ZIP format
2. Must contain `wpmigrate-backup.json` at root
3. JSON must be valid and contain `format_version` field

### Creation

Created via `--create-backup` flag:

```bash
./wp-migrate.sh --source-host user@source.example.com \
                --source-root /var/www/html \
                --create-backup
```

### Dependencies

- `unzip` - Archive extraction
- `file` - Archive type detection
- `jq` - JSON validation

### Design Rationale

- **Simple structure**: Single SQL file, straightforward directory layout
- **Metadata-driven**: JSON enables versioning and future enhancements
- **Purpose-built**: Explicitly wp-migrate format (not masquerading as another tool)
- **First-class support**: First in adapter detection order
```

### Step 4: Commit documentation updates

```bash
git add README.md CHANGELOG.md src/lib/adapters/README.md
git commit -m "docs: add backup creation feature documentation

Document --create-backup flag usage, workflow examples, and wp-migrate
native archive format specification. Add CHANGELOG entry for v2.8.0.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## Task 7: Build and Test

**Files:**
- Run: `make build`
- Test: Manual validation

### Step 1: Build the final script

Run: `make build`
Expected:
```
Building temporary file for shellcheck...
Running shellcheck on complete script...
✓ Shellcheck passed
Building wp-migrate.sh...
✓ Built: dist/wp-migrate.sh
✓ Copied: ./wp-migrate.sh (repo root)
✓ Checksum: wp-migrate.sh.sha256

Build complete!
```

### Step 2: Test adapter validation with mock archive

**Create test fixture:**

```bash
# Create test backup structure
mkdir -p /tmp/test-wpmigrate-backup/wp-content
echo '{"format_version": "1.0"}' > /tmp/test-wpmigrate-backup/wpmigrate-backup.json
touch /tmp/test-wpmigrate-backup/database.sql
cd /tmp/test-wpmigrate-backup && zip -r /tmp/test-backup.zip .
```

**Test adapter detection:**

```bash
# Should detect as wpmigrate format
./wp-migrate.sh --archive /tmp/test-backup.zip --dry-run --verbose
```

Expected output should include: "Matched wpmigrate format"

### Step 3: Test --create-backup dry-run

```bash
./wp-migrate.sh --source-host example@example.com \
                --source-root /var/www/html \
                --create-backup --dry-run
```

Expected: Shows dry-run preview without errors

### Step 4: Test argument validation

```bash
# Should error: missing --source-host
./wp-migrate.sh --source-root /var/www/html --create-backup

# Should error: missing --source-root
./wp-migrate.sh --source-host user@host --create-backup

# Should error: mutually exclusive with --archive
./wp-migrate.sh --source-host user@host --source-root /var/www/html \
                --create-backup --archive /path/to/backup.zip
```

Expected: Each command shows appropriate error message

### Step 5: Verify help output includes new flags

Run: `./wp-migrate.sh --help | grep -E "(create-backup|source-host|source-root)"`

Expected: Shows documentation for new flags

### Step 6: Commit build artifacts

```bash
git add wp-migrate.sh wp-migrate.sh.sha256 dist/wp-migrate.sh
git commit -m "build: regenerate wp-migrate.sh with backup creation feature

Include wpmigrate adapter, backup creation logic, and new argument
flags in built distribution script.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## Task 8: Update Help Text and Version

**Files:**
- Modify: `src/lib/core.sh` (update print_usage function)
- Modify: `src/header.sh` (update VERSION if needed)

### Step 1: Add backup creation to help text

**Edit:** `src/lib/core.sh` - find `print_usage()` function

**Add backup creation section:**

```bash
  cat <<EOF
...existing help text...

BACKUP CREATION MODE:
  Create WordPress backup on source server via SSH

  Required:
    --source-host HOST       SSH connection string (user@hostname)
    --source-root PATH       Absolute path to WordPress root on source
    --create-backup          Enable backup creation mode

  Example:
    ./wp-migrate.sh --source-host user@source.example.com \\
                    --source-root /var/www/html \\
                    --create-backup

  Output: Creates ~/wp-migrate-backups/{domain}-{timestamp}.zip

...rest of help text...
EOF
```

### Step 2: Rebuild after help text changes

Run: `make build`

### Step 3: Verify help output looks correct

Run: `./wp-migrate.sh --help | less`

Expected: Backup creation section appears with proper formatting

### Step 4: Commit help text updates

```bash
git add src/lib/core.sh wp-migrate.sh dist/wp-migrate.sh
git commit -m "docs: add backup creation mode to help text

Update print_usage() function to document --create-backup,
--source-host, and --source-root flags with usage examples.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## Post-Implementation Checklist

After completing all tasks:

- [ ] All commits follow conventional commit format
- [ ] ShellCheck passes on built script
- [ ] `make build` succeeds without errors
- [ ] `--help` output includes new flags
- [ ] Dry-run mode works for backup creation
- [ ] Adapter validates wp-migrate format correctly
- [ ] CHANGELOG.md updated with feature entry
- [ ] README.md includes backup creation usage
- [ ] No TODO/FIXME comments left in code

## Manual Testing (requires real WordPress installation)

After implementation, test with real WordPress site:

1. **Create backup on source server:**
   ```bash
   ./wp-migrate.sh --source-host user@source.example.com \
                   --source-root /var/www/html \
                   --create-backup --verbose
   ```

2. **Verify backup file exists:**
   ```bash
   ssh user@source.example.com "ls -lh ~/wp-migrate-backups/"
   ```

3. **Download and inspect backup:**
   ```bash
   scp user@source.example.com:~/wp-migrate-backups/example-com-*.zip .
   unzip -l example-com-*.zip
   # Should see: wpmigrate-backup.json, database.sql, wp-content/
   ```

4. **Import backup on destination:**
   ```bash
   ./wp-migrate.sh --archive example-com-*.zip --verbose
   ```

5. **Verify imported site works:**
   - Check site loads in browser
   - Verify URLs updated correctly
   - Test admin login
   - Check content appears correct

## Known Limitations

- No automatic download (user must manually scp backup)
- No progress bars for database export (wp-cli limitation)
- Requires wp-cli on source server
- Backup stored on source server only (no off-site storage)
- No incremental backup support
- No backup verification/integrity checks

## Future Enhancements (Out of Scope)

- Automatic backup download to local machine
- Custom exclusion patterns via flag
- Backup rotation/retention policies
- Incremental backups
- Compression level options
- Backup encryption
- Off-site storage (S3, etc.)
