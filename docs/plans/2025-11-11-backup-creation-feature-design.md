# Backup Creation Feature Design

**Date:** 2025-11-11
**Feature:** `--create-backup` flag for wp-migrate.sh
**Version:** 1.0

## Overview

Add a new backup mode to wp-migrate.sh that creates WordPress backups on source servers via SSH. These backups are immediately compatible with the existing `--archive` import mode, enabling a two-step migration workflow: create backup on source, import backup on destination.

## User Workflow

```bash
# Step 1: Create backup on source server
./wp-migrate.sh --source-host user@source.example.com \
                --source-root /var/www/site \
                --create-backup

# Output: "Backup created: /home/user/wp-migrate-backups/example-com-2025-11-11-143022.zip"

# Step 2: Import backup on destination server
./wp-migrate.sh --archive ~/wp-migrate-backups/example-com-2025-11-11-143022.zip
```

## Requirements

1. Create backups on source server via SSH (no local WordPress required)
2. Store backups on source server only (no automatic download)
3. Include: database dump + wp-content directory
4. Exclude: cache directories, object cache files, debug logs
5. Archive format compatible with existing `--archive` import mode
6. Storage location: `~/wp-migrate-backups/{sanitized-domain}-{timestamp}.zip`

## Architecture

### Components

1. **Backup creation logic** (`src/lib/functions.sh`)
   - New function: `create_backup()`
   - Orchestrates database export, wp-content sync, metadata generation, archive creation

2. **New adapter** (`src/lib/adapters/wpmigrate.sh`)
   - Validates and imports wp-migrate format archives
   - Implements standard adapter interface (validate, extract, find_database, find_content)

3. **Argument handling** (`src/main.sh`)
   - Detects `--create-backup` flag
   - Validates required parameters: `--source-host`, `--source-root`
   - Routes to backup creation flow

4. **Exclusion patterns**
   - Hardcoded list of paths to exclude from wp-content backup

### Execution Context

When `--create-backup` is provided:
- Script executes entirely via SSH on source server
- No local WordPress installation required
- Creates archive in `~/wp-migrate-backups/` on source server
- Reports final backup path to user

## Archive Format Specification

### File Structure

```
example-com-2025-11-11-143022.zip
├── wpmigrate-backup.json     # Metadata (signature file)
├── database.sql              # Full database dump
└── wp-content/               # Filtered WordPress content
    ├── plugins/
    ├── themes/
    └── uploads/
```

### Metadata File (`wpmigrate-backup.json`)

```json
{
  "format_version": "1.0",
  "created_at": "2025-11-11T14:30:22Z",
  "wp_migrate_version": "2.7.0",
  "source_url": "https://example.com",
  "database_tables": 23,
  "exclusions": [
    "wp-content/cache",
    "wp-content/object-cache.php",
    "wp-content/debug.log"
  ]
}
```

**Purpose:**
- Signature file for format detection
- Version tracking for future compatibility
- Audit trail (when/where backup created)
- Documentation of exclusions applied

### Naming Convention

**Pattern:** `{sanitized-domain}-{YYYY-MM-DD-HHMMSS}.zip`

**Examples:**
- `example-com-2025-11-11-143022.zip`
- `mysite-org-2025-11-11-150000.zip`

**Domain sanitization:** Replace dots and slashes with dashes
**Timestamp:** UTC time for consistency across timezones

### Storage Location

**Source server:** `~/wp-migrate-backups/`
- Created automatically if doesn't exist
- No automatic cleanup of old backups (user's responsibility)
- User must manually download if needed for destination import

### Exclusion Patterns (Hardcoded)

```
wp-content/cache/
wp-content/*/cache/           # Plugin-specific cache dirs
wp-content/object-cache.php
wp-content/advanced-cache.php
wp-content/debug.log
wp-content/*.log
```

**Rationale:**
- Cache directories: Regenerated automatically, waste space
- Object/advanced cache: Environment-specific, may break on import
- Log files: Not needed for migration, often large

## Backup Creation Process

### High-Level Flow

1. Validate inputs (source-host, source-root required)
2. Connect to source server via SSH
3. Verify WordPress installation exists
4. Create backup directory (`~/wp-migrate-backups/`)
5. Generate backup filename with timestamp
6. Export database to temp location
7. Create metadata JSON file
8. Rsync wp-content with exclusions to temp location
9. Create zip archive from temp files
10. Clean up temp files
11. Report final backup path to user

### Implementation Details

#### Database Export

```bash
wp db export /tmp/wp-migrate-backup-XXXXX/database.sql --path=/var/www/site
```

Uses wp-cli on source server. Requires wp-cli to be installed (validation check).

#### wp-content Sync

```bash
rsync -az \
  --exclude='cache/' \
  --exclude='*/cache/' \
  --exclude='object-cache.php' \
  --exclude='advanced-cache.php' \
  --exclude='debug.log' \
  --exclude='*.log' \
  /var/www/site/wp-content/ \
  /tmp/wp-migrate-backup-XXXXX/wp-content/
```

Uses rsync for efficient filtering and progress tracking.

#### Metadata Generation

```bash
# Get site URL from WordPress
SITE_URL=$(wp option get siteurl --path=/var/www/site)

# Count database tables
TABLE_COUNT=$(wp db tables --path=/var/www/site | wc -l)

# Get wp-migrate version
WP_MIGRATE_VERSION="2.7.0"  # From script header

# Create JSON
cat > /tmp/wp-migrate-backup-XXXXX/wpmigrate-backup.json <<EOF
{
  "format_version": "1.0",
  "created_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "wp_migrate_version": "$WP_MIGRATE_VERSION",
  "source_url": "$SITE_URL",
  "database_tables": $TABLE_COUNT,
  "exclusions": [
    "wp-content/cache",
    "wp-content/*/cache/",
    "wp-content/object-cache.php",
    "wp-content/advanced-cache.php",
    "wp-content/debug.log",
    "wp-content/*.log"
  ]
}
EOF
```

#### Archive Creation

```bash
cd /tmp/wp-migrate-backup-XXXXX
zip -r ~/wp-migrate-backups/example-com-2025-11-11-143022.zip .
```

Creates zip at root level (all files directly in archive, not nested in subdirectory).

#### Temp Directory Management

- Pattern: `/tmp/wp-migrate-backup-XXXXX` (created with `mktemp -d`)
- Cleanup: Always remove on success or failure (trap handler)
- Location: Standard `/tmp` (cleared on reboot)

#### Progress Indicators

- Use existing `pv` support if available
- Show progress for: database export, wp-content sync, zip creation
- Fallback to simple status messages if `pv` not installed

## Adapter Implementation

### New File: `src/lib/adapters/wpmigrate.sh`

Implements standard adapter interface for wp-migrate backup format.

### Required Functions

```bash
adapter_wpmigrate_validate() {
  # 1. Check if wpmigrate-backup.json exists at archive root
  # 2. Verify it's valid JSON
  # 3. Verify it contains required field: format_version
  # Return 0 if valid, 1 otherwise
  # Populate ADAPTER_VALIDATION_ERRORS array on failure
}

adapter_wpmigrate_extract() {
  # 1. Extract zip to destination directory using unzip
  # 2. Return 0 on success, 1 on failure
}

adapter_wpmigrate_find_database() {
  # 1. Look for database.sql at root of extract dir
  # 2. Return 0 and echo full path on success
  # 3. Return 1 if not found
}

adapter_wpmigrate_find_content() {
  # 1. Look for wp-content/ at root of extract dir
  # 2. Use adapter_base_find_best_wp_content helper for robustness
  # 3. Return 0 and echo full path on success
  # 4. Return 1 if not found
}

adapter_wpmigrate_get_name() {
  # Return "wp-migrate Backup" for user-facing messages
}

adapter_wpmigrate_get_dependencies() {
  # Return "unzip file jq"
  # jq required for JSON validation
}
```

### Validation Specifics

**Signature:** Presence of `wpmigrate-backup.json` at archive root

**JSON validation:**
- Must parse successfully with `jq`
- Must contain `format_version` field
- If malformed, add detailed error to `ADAPTER_VALIDATION_ERRORS`

**Example validation:**
```bash
if ! adapter_base_archive_contains "$archive" "wpmigrate-backup.json"; then
  ADAPTER_VALIDATION_ERRORS+=("Missing wpmigrate-backup.json signature file")
  return 1
fi

# Extract and validate JSON
if ! unzip -p "$archive" "wpmigrate-backup.json" | jq -e '.format_version' > /dev/null 2>&1; then
  ADAPTER_VALIDATION_ERRORS+=("Invalid or missing format_version in metadata")
  return 1
fi
```

### Adapter Registration

Add `"wpmigrate"` to `AVAILABLE_ADAPTERS` array in `src/lib/functions.sh`:

```bash
AVAILABLE_ADAPTERS=("wpmigrate" "duplicator" "jetpack" "solidbackups" "solidbackups_nextgen")
```

**Position:** First in list for fastest detection of our own format.

## Error Handling

### Pre-Backup Validation

1. **SSH connectivity:** Fail fast if source host unreachable
2. **WordPress installation:** Check for `wp-config.php` at source-root
3. **wp-cli availability:** Verify wp-cli command exists on source server
4. **Disk space:** Estimate required space (DB size + wp-content size + 50% buffer)
5. **Write permissions:** Verify can create `~/wp-migrate-backups/` directory

### Failure Scenarios

**Mid-backup failure:**
- Database export fails → Clean up temp directory, report error, exit
- wp-content sync fails → Clean up temp directory, report error, exit
- Zip creation fails → Clean up temp directory, report error, exit
- **Always** clean up `/tmp/wp-migrate-backup-XXXXX` on any failure (trap handler)

**Partial backups:**
- If zip creation completes but is corrupted, report warning
- No automatic retry logic (user can re-run command)

**Disk space handling:**
```bash
REQUIRED_SPACE=$(calculate_backup_size)
AVAILABLE_SPACE=$(df -P ~/wp-migrate-backups | tail -1 | awk '{print $4}')

if [ $AVAILABLE_SPACE -lt $REQUIRED_SPACE ]; then
  err "Insufficient disk space. Required: ${REQUIRED_SPACE}KB, Available: ${AVAILABLE_SPACE}KB"
fi
```

### Edge Cases

1. **Backup directory exists with old backups:**
   - Continue using it (don't error)
   - No automatic cleanup (user's responsibility)

2. **Filename collision:**
   - Timestamp precision (seconds) makes collision unlikely
   - If collision occurs, append `-1`, `-2`, etc.

3. **Very large databases/sites:**
   - No size limits enforced
   - Progress indicators via `pv` if available
   - May take significant time (expected)

4. **Missing wp-cli:**
   - Error immediately with helpful message
   - Suggest installation command

5. **Database export permissions:**
   - wp-cli handles credentials via wp-config.php
   - If wp-cli fails, report full error output

### Dry-Run Mode

`--dry-run` flag should work with `--create-backup`:
- Validates all prerequisites
- Reports what would be backed up (sizes, file counts)
- Does NOT create actual backup
- Shows estimated backup size and destination path
- Example output: "Would create backup: ~/wp-migrate-backups/example-com-2025-11-11-143022.zip (estimated size: 450MB)"

## Testing Strategy

### Unit Tests (via test-wp-migrate.sh)

#### Adapter Validation Tests
- Valid wp-migrate backup → Passes validation
- Missing wpmigrate-backup.json → Fails validation with error
- Malformed JSON → Fails validation with error
- Wrong format (Duplicator/Jetpack) → Correctly rejects

#### Archive Import Tests
- Extract wp-migrate backup → Finds database.sql
- Extract wp-migrate backup → Finds wp-content/
- Full import flow → Database and wp-content imported correctly

#### Backup Creation Tests (requires test SSH environment)
- Create backup with valid WordPress install → Success
- Create backup without wp-cli → Fails with helpful error
- Create backup with insufficient disk space → Fails before starting
- Dry-run mode → Reports plan without creating backup

### Manual Testing Checklist

```
- [ ] Create backup on fresh WordPress install
- [ ] Verify backup file exists in ~/wp-migrate-backups/
- [ ] Extract backup manually and inspect contents
- [ ] Import backup to different server using --archive flag
- [ ] Verify imported site works (URLs updated, content intact)
- [ ] Test with very large site (1GB+ database)
- [ ] Test with missing wp-cli
- [ ] Test with insufficient disk space
- [ ] Test dry-run mode
- [ ] Test --verbose output
- [ ] Test filename collision handling
- [ ] Test with site in subdirectory
```

### Integration with Existing Tests

- Add wp-migrate backup format to test fixtures
- Update adapter auto-detection tests to include wpmigrate format
- Ensure wpmigrate adapter is tested first (appears first in AVAILABLE_ADAPTERS)
- Verify exclusion patterns work correctly

## Implementation Checklist

### Phase 1: Adapter Foundation
- [ ] Create `src/lib/adapters/wpmigrate.sh`
- [ ] Implement all 6 adapter functions
- [ ] Add `"wpmigrate"` to `AVAILABLE_ADAPTERS` (first position)
- [ ] Test adapter with manually-created backup fixture

### Phase 2: Backup Creation Logic
- [ ] Add `create_backup()` function to `src/lib/functions.sh`
- [ ] Implement database export logic
- [ ] Implement wp-content sync with exclusions
- [ ] Implement metadata generation
- [ ] Implement zip archive creation
- [ ] Implement temp directory cleanup (trap handler)

### Phase 3: Argument Handling
- [ ] Add `--create-backup` flag to argument parser
- [ ] Validate required parameters (source-host, source-root)
- [ ] Route to backup creation flow in main execution
- [ ] Support dry-run mode with `--create-backup`

### Phase 4: Error Handling
- [ ] Add pre-backup validation checks
- [ ] Implement disk space checking
- [ ] Add detailed error messages for common failures
- [ ] Test failure scenarios

### Phase 5: Testing & Documentation
- [ ] Add unit tests for adapter
- [ ] Add integration tests for backup creation
- [ ] Update README.md with `--create-backup` usage
- [ ] Update CHANGELOG.md
- [ ] Manual testing against real WordPress sites

### Phase 6: Build & Release
- [ ] Run `make build` to regenerate wp-migrate.sh
- [ ] Run ShellCheck validation
- [ ] Run full test suite
- [ ] Create PR with comprehensive summary
- [ ] Update version number for release

## Future Enhancements (Out of Scope)

- Automatic download of backup to local machine
- Incremental backups (only changed files)
- Compression level options
- Custom exclusion patterns via flag
- Multiple backup retention policies
- Backup verification/integrity checks
- Encryption support
- Split database by table (Jetpack-style)
- Multisite support

## References

- [Archive Adapter System](../../src/lib/adapters/README.md)
- [Existing Adapters](../../src/lib/adapters/)
- [wp-migrate.sh Main Script](../../wp-migrate.sh)
- [Project README](../../README.md)
