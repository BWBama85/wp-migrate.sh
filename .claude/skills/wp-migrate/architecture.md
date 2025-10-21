# Architecture Overview

Deep dive into wp-migrate.sh internal architecture and design patterns.

## Project Structure

### Repository Layout
```
wp-migrate/
├── wp-migrate.sh              # Built single-file script (repo root)
├── wp-migrate.sh.sha256       # Checksum for built script
├── src/                       # Modular source files
│   ├── header.sh              # Shebang, set options, variable declarations
│   ├── lib/
│   │   ├── core.sh            # Core utilities (log, err, needs)
│   │   ├── adapters/          # Archive format adapters
│   │   │   ├── README.md      # Adapter development guide
│   │   │   ├── base.sh        # Shared adapter helper functions
│   │   │   ├── duplicator.sh  # Duplicator adapter
│   │   │   ├── jetpack.sh     # Jetpack Backup adapter
│   │   │   └── solidbackups.sh # Solid Backups adapter
│   │   └── functions.sh       # All other functions
│   └── main.sh                # Argument parsing and main() execution
├── dist/                      # Build artifacts (git-ignored)
│   └── wp-migrate.sh          # Intermediate build output
├── logs/                      # Runtime logs (created by script)
├── db-dumps/                  # Database exports (push mode)
├── db-backups/                # Database backups (archive mode)
├── db-imports/                # Database imports (on destination)
├── Makefile                   # Build system
├── test-wp-migrate.sh         # Test suite
├── .githooks/                 # Git hooks (pre-commit)
├── .gitmessage                # Commit message template
├── .github/
│   └── pull_request_template.md
├── CHANGELOG.md               # Version history
├── README.md                  # User documentation
└── LICENSE                    # MIT License
```

### Build System Architecture

**Source to Distribution Flow:**
```
src/header.sh          →
src/lib/core.sh        →
src/lib/adapters/      →  Concatenation  →  ShellCheck  →  wp-migrate.sh
src/lib/functions.sh   →                                →  + SHA256 checksum
src/main.sh            →
```

**Build Process (Makefile):**
1. **Test target**: Concatenates source → runs ShellCheck → validates
2. **Build target**: Runs test → copies to dist/ → copies to repo root → generates checksum
3. **Clean target**: Removes dist/ directory

**Why Modular Source?**
- Easier maintenance and code review
- Logical separation of concerns
- Simpler testing of individual components
- Better IDE support and navigation
- Clearer git diffs

## Core Components

### 1. Header (src/header.sh)

**Purpose**: Script initialization and global configuration

**Contents:**
- Shebang: `#!/usr/bin/env bash`
- Shell options: `set -Eeuo pipefail`
  - `-e`: Exit on error
  - `-E`: Inherit ERR trap
  - `-u`: Error on undefined variables
  - `-o pipefail`: Pipe failures propagate
- Default variable declarations
- Global state tracking
- Mode detection variables

**Key Variables:**
```bash
DEST_HOST=""              # Push mode: SSH destination
DEST_ROOT=""              # Push mode: Destination WP root
ARCHIVE_FILE=""           # Archive mode: Path to backup
ARCHIVE_TYPE=""           # Archive mode: Adapter override
MIGRATION_MODE=""         # Detected: "push" or "archive"
DRY_RUN=false             # Preview mode flag
IMPORT_DB=true            # Auto-import database
SEARCH_REPLACE=true       # Perform URL search-replace
STELLARSITES_MODE=false   # Managed hosting compatibility
```

### 2. Core Utilities (src/lib/core.sh)

**Purpose**: Fundamental functions used throughout the script

**Functions:**

**`err()`** - Error handling and exit
```bash
err() { printf "ERROR: %s\n" "$*" >&2; exit 1; }
```

**`log()`** - Logging to file and/or stdout
```bash
log() {
  # Logs to LOG_FILE and optionally to stdout
  # Handles dry-run mode (logs to /dev/null)
}
```

**`verbose()`** - Conditional verbose logging
```bash
verbose() {
  # Only logs if VERBOSE=true
  # Used for diagnostic information
}
```

**`trace()`** - Command tracing
```bash
trace() {
  # Shows exact command before execution
  # Enabled with --trace flag
}
```

**`needs()`** - Dependency checking
```bash
needs() {
  # Checks if command exists
  # Shows installation instructions if missing
  # Exits if required dependency not found
}
```

**`validate_url()`** - URL validation
```bash
validate_url() {
  # Ensures URL is well-formed
  # Used before search-replace operations
}
```

### 3. Archive Adapters (src/lib/adapters/)

**Purpose**: Pluggable format handlers for different backup plugins

**Adapter Interface**: Each adapter implements 5 required functions:

1. **`adapter_NAME_validate(archive_path)`**
   - Returns 0 if archive matches format, 1 otherwise
   - Checks file type and signature files

2. **`adapter_NAME_extract(archive_path, dest_dir)`**
   - Extracts archive to destination
   - Handles format-specific extraction (unzip, tar, etc.)

3. **`adapter_NAME_find_database(extract_dir)`**
   - Locates SQL file(s) in extracted archive
   - Echoes full path to database file

4. **`adapter_NAME_find_content(extract_dir)`**
   - Locates wp-content directory
   - Uses smart scoring to find best match

5. **`adapter_NAME_get_name()`**
   - Returns human-readable format name

**Base Helpers (adapter/base.sh):**
- `adapter_base_get_archive_type()` - Detect ZIP/TAR/TAR.GZ
- `adapter_base_archive_contains()` - Check for files in archive
- `adapter_base_find_best_wp_content()` - Score-based directory detection
- `adapter_base_score_wp_content()` - Score directory (0-3)

**Adapter Registry:**
Dynamically registered in main workflow:
```bash
ADAPTERS=(duplicator jetpack solidbackups)
```

**Auto-Detection Flow:**
```
For each adapter in ADAPTERS:
  ├─ Call adapter_NAME_validate(archive)
  ├─ If returns 0:
  │  └─ Use this adapter
  └─ If returns 1:
     └─ Try next adapter
```

### 4. Functions (src/lib/functions.sh)

**Purpose**: All migration workflow functions

**Categories:**

**SSH and Connectivity:**
- `setup_ssh_control()` - Persistent SSH connections
- `cleanup_ssh_control()` - Close SSH control socket
- `test_ssh_connection()` - Verify destination reachable

**WordPress Detection:**
- `verify_wp_installation()` - Check wp-config.php exists
- `get_wp_content_path()` - Find wp-content directory
- `detect_table_prefix()` - Read prefix from database

**Database Operations:**
- `export_database()` - wp db export with optional gzip
- `import_database()` - wp db import with auto-gunzip
- `backup_database()` - Create timestamped backup
- `align_table_prefix()` - Update wp-config.php if needed

**URL Management:**
- `detect_site_urls()` - Get home and siteurl options
- `perform_search_replace()` - wp search-replace with validation
- `update_site_urls()` - Set home/siteurl options

**File Operations:**
- `sync_wp_content()` - rsync wp-content directory
- `backup_wp_content()` - Create timestamped copy
- `replace_wp_content()` - Remove and replace directory

**Maintenance Mode:**
- `enable_maintenance()` - Activate .maintenance file
- `disable_maintenance()` - Deactivate .maintenance file
- `setup_cleanup_trap()` - Ensure maintenance disabled on exit

**Cache Management:**
- `detect_redis_command()` - Check if wp redis available
- `flush_cache()` - wp cache flush + wp redis flush

**Archive Operations:**
- `detect_archive_format()` - Auto-detect adapter
- `validate_disk_space()` - Check 3x archive size available
- `extract_archive()` - Call adapter extract function
- `detect_archive_database()` - Call adapter find_database
- `detect_archive_wp_content()` - Call adapter find_content

**Plugin/Theme Preservation:**
- `capture_dest_plugins_themes()` - List before migration
- `detect_unique_plugins_themes()` - Compare source vs destination
- `restore_unique_plugins_themes()` - Copy from backup
- `deactivate_restored_plugins()` - Ensure safe state

### 5. Main Execution (src/main.sh)

**Purpose**: Argument parsing and orchestration

**Argument Parser:**
```bash
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dest-host) DEST_HOST="$2"; shift 2 ;;
    --archive) ARCHIVE_FILE="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    --verbose) VERBOSE=true; shift ;;
    # ... etc
  esac
done
```

**Main Workflow:**
```bash
main() {
  # 1. Detect migration mode (push vs archive)
  # 2. Validate prerequisites
  # 3. Setup logging and traps
  # 4. Execute mode-specific workflow
  # 5. Cleanup and summary
}
```

## Execution Flow

### Push Mode Workflow

```
1. Preflight Checks
   ├─ Verify WordPress installation (source)
   ├─ Check dependencies (wp, rsync, ssh, gzip)
   ├─ Test SSH connectivity to destination
   └─ Verify WordPress installation (destination)

2. URL Detection
   ├─ Detect source home/siteurl
   ├─ Detect destination home/siteurl
   └─ Determine if search-replace needed

3. Setup
   ├─ Create log directory
   ├─ Setup SSH control connection
   ├─ Setup cleanup trap (ensure maintenance disabled)
   └─ Capture destination plugins/themes (if --preserve-dest-plugins)

4. Maintenance Mode
   ├─ Enable maintenance on source (unless --no-maint-source)
   └─ Enable maintenance on destination

5. Database Migration
   ├─ Export database on source (wp db export)
   ├─ Optionally gzip export (unless --no-gzip)
   ├─ Transfer to destination (rsync over SSH)
   ├─ Import on destination (if IMPORT_DB=true)
   └─ Perform search-replace (if SEARCH_REPLACE=true)

6. File Migration
   ├─ Backup destination wp-content (timestamped)
   ├─ Rsync wp-content (source → destination)
   │  └─ Exclude: object-cache.php
   │  └─ Exclude: mu-plugins/ (if --stellarsites)
   └─ Restore unique plugins/themes (if --preserve-dest-plugins)

7. Post-Migration
   ├─ Flush caches (wp cache flush, wp redis flush)
   ├─ Disable maintenance mode (both servers)
   └─ Cleanup SSH control connection

8. Summary
   ├─ Log migration completion
   └─ Show database dump location and import status
```

### Archive Mode Workflow

```
1. Preflight Checks
   ├─ Verify WordPress installation (destination)
   ├─ Check dependencies (wp, file, unzip/tar)
   └─ Verify archive file exists

2. Format Detection
   ├─ Auto-detect adapter (try each validator)
   └─ Or use explicit --archive-type

3. URL Capture
   └─ Capture destination home/siteurl (before import)

4. Disk Space Validation
   └─ Ensure 3x archive size available

5. Extraction
   ├─ Create temporary directory
   ├─ Call adapter extract function
   ├─ Detect database file (adapter find_database)
   └─ Detect wp-content directory (adapter find_content)

6. Setup
   ├─ Create log directory
   ├─ Setup cleanup trap
   └─ Capture destination plugins/themes (if --preserve-dest-plugins)

7. Maintenance Mode
   └─ Enable maintenance on destination

8. Database Backup
   └─ Export destination database (gzipped, timestamped)

9. wp-content Backup
   └─ Copy destination wp-content (timestamped)

10. Database Import
    ├─ Import database from archive
    ├─ Detect table prefix from imported data
    ├─ Align wp-config.php prefix if needed
    ├─ Detect imported home/siteurl
    └─ Perform search-replace (use captured destination URLs)

11. wp-content Replacement
    ├─ Remove destination wp-content
    ├─ Copy archive wp-content to destination
    │  └─ Exclude: object-cache.php
    │  └─ Exclude: mu-plugins/ (if --stellarsites)
    └─ Restore unique plugins/themes (if --preserve-dest-plugins)

12. Post-Import
    ├─ Flush caches (wp cache flush, wp redis flush)
    ├─ Disable maintenance mode
    └─ Cleanup temporary extraction directory

13. Summary
    ├─ Log import completion
    ├─ Show backup locations
    └─ Provide rollback commands
```

## Design Patterns

### 1. Dry-Run Safety

**Pattern**: All destructive operations check `DRY_RUN` flag

```bash
if [[ "$DRY_RUN" == true ]]; then
  log "Would perform operation..."
  return 0
fi

# Actually perform operation
perform_operation
```

**Guarantees**:
- No files created or modified
- No database changes
- No maintenance mode toggled
- No SSH connections (except test)
- Logs route to /dev/null

### 2. Error Handling

**Pattern**: Set `-e` and explicit error checking

```bash
set -Eeuo pipefail  # Exit on any error

# Explicit checks for important operations
if ! wp db import "$dump"; then
  err "Database import failed"
fi
```

**Cleanup Trap**:
```bash
cleanup() {
  # Ensure maintenance mode disabled
  # Close SSH connections
  # Remove temp files
}
trap cleanup EXIT
```

### 3. Logging Strategy

**Multi-Level Logging**:
- `err()` - Fatal errors, exit immediately
- `log()` - Important operations, always shown
- `verbose()` - Diagnostic info, shown with --verbose
- `trace()` - Command preview, shown with --trace

**Timestamped Log Files**:
```bash
LOG_FILE="logs/migrate-MODE-$(date +%Y%m%d-%H%M%S).log"
```

### 4. Adapter Pattern

**Plugin Architecture**: Archive formats are pluggable adapters

**Benefits**:
- Easy to add new formats
- Clear interface contract
- Shared helper functions
- Independent testing

**Registration**:
```bash
ADAPTERS=(duplicator jetpack solidbackups)

for adapter in "${ADAPTERS[@]}"; do
  if "adapter_${adapter}_validate" "$ARCHIVE_FILE"; then
    ARCHIVE_ADAPTER="$adapter"
    break
  fi
done
```

### 5. URL Alignment

**Two-Phase Approach**:

**Phase 1: Capture URLs Before Changes**
```bash
ORIGINAL_DEST_HOME_URL=$(wp option get home)
ORIGINAL_DEST_SITE_URL=$(wp option get siteurl)
```

**Phase 2: Restore After Import**
```bash
# Import changes URLs to source site
wp db import archive.sql

# Detect what was imported
IMPORTED_HOME=$(wp option get home)

# Restore destination URLs
wp search-replace "$IMPORTED_HOME" "$ORIGINAL_DEST_HOME_URL"
```

### 6. Backup Before Destroy

**Pattern**: Always backup before destructive operations

```bash
# Database
backup_database  # Creates timestamped .sql.gz

# wp-content
backup_wp_content  # Creates timestamped directory copy

# Then proceed with import/replacement
```

### 7. Table Prefix Detection

**Smart Detection**:
```bash
detect_table_prefix() {
  # Try core tables with different prefixes
  for prefix in wp_ wpress_ custom_; do
    if wp db tables --format=csv | grep -q "${prefix}options"; then
      echo "$prefix"
      return 0
    fi
  done
}
```

**Auto-Alignment**:
```bash
if [[ "$detected_prefix" != "$config_prefix" ]]; then
  # Update wp-config.php automatically
  update_config_prefix "$detected_prefix"
fi
```

### 8. Plugin/Theme Preservation

**Diff and Restore Pattern**:
```bash
# Before migration
DEST_PLUGINS_BEFORE=($(wp plugin list --field=name))

# After migration
SOURCE_PLUGINS=($(wp plugin list --field=name))

# Find unique to destination
UNIQUE_DEST_PLUGINS=(plugins in BEFORE but not in SOURCE)

# Restore from backup
for plugin in "${UNIQUE_DEST_PLUGINS[@]}"; do
  cp -a "wp-content.backup/plugins/$plugin" wp-content/plugins/
done

# Deactivate for safety
wp plugin deactivate "${UNIQUE_DEST_PLUGINS[@]}"
```

## State Management

### Global State Variables

**Migration Mode**:
```bash
MIGRATION_MODE="push"  # or "archive"
```

**Maintenance Mode Tracking**:
```bash
MAINT_LOCAL_ACTIVE=false
MAINT_REMOTE_ACTIVE=false
MAINT_REMOTE_HOST=""
MAINT_REMOTE_ROOT=""
```

**Cleanup Trap Uses These**:
```bash
cleanup() {
  if [[ "$MAINT_LOCAL_ACTIVE" == true ]]; then
    wp maintenance-mode deactivate
  fi
  if [[ "$MAINT_REMOTE_ACTIVE" == true ]]; then
    ssh "$MAINT_REMOTE_HOST" "cd '$MAINT_REMOTE_ROOT' && wp maintenance-mode deactivate"
  fi
}
```

### SSH Connection Pooling

**Persistent Connections**:
```bash
SSH_CONTROL_DIR="/tmp/wp-migrate-ssh-$$"
SSH_CONTROL_PATH="$SSH_CONTROL_DIR/master-%r@%h:%p"

setup_ssh_control() {
  mkdir -p "$SSH_CONTROL_DIR"
  ssh -o ControlMaster=auto \
      -o ControlPath="$SSH_CONTROL_PATH" \
      -o ControlPersist=600 \
      "$DEST_HOST" true
}
```

**Benefits**:
- Faster subsequent SSH operations
- Reuses authentication
- Single connection for entire migration

## Performance Optimizations

### 1. Database Compression

**Gzip During Transfer**:
```bash
wp db export - | gzip > dump.sql.gz
rsync dump.sql.gz dest:/
gunzip -c dump.sql.gz | wp db import -
```

**Savings**: ~10x reduction in transfer size

### 2. Rsync Compression

**Built-in Compression**:
```bash
rsync -avz  # -z enables compression
```

### 3. SSH Control Sockets

Single connection reused for all operations

### 4. Conditional Search-Replace

**Skip if Same Domain**:
```bash
if [[ "$SOURCE_HOME_URL" == "$DEST_HOME_URL" ]]; then
  log "URLs identical, skipping search-replace"
  URL_ALIGNMENT_REQUIRED=false
fi
```

### 5. Smart wp-content Scoring

**Avoid Full Directory Scan**:
```bash
score=0
[[ -d "$dir/plugins" ]] && ((score++))
[[ -d "$dir/themes" ]] && ((score++))
[[ -d "$dir/uploads" ]] && ((score++))
# Stop early if score == 3 (perfect match)
```

## Security Considerations

### 1. Shell Injection Prevention

**Always Quote Variables**:
```bash
# BAD - vulnerable to injection
ssh "$DEST_HOST" cd $DEST_ROOT

# GOOD - properly quoted
ssh "$DEST_HOST" "cd '$DEST_ROOT'"
```

### 2. File Path Validation

**Check for Dangerous Characters**:
```bash
if [[ "$path" =~ [^\w/.-] ]]; then
  err "Invalid path"
fi
```

### 3. Credential Protection

**No Passwords in Code**:
- Use SSH keys for authentication
- Rely on wp-cli for database credentials (reads from wp-config.php)

### 4. Maintenance Mode

**Prevent Concurrent Access**:
- Enables .maintenance file during migration
- Prevents data changes during sync

### 5. Rollback Instructions

**Always Provide Recovery Path**:
```bash
log "To rollback:"
log "  wp db import db-backups/backup-$timestamp.sql.gz"
log "  rm -rf wp-content && mv wp-content.backup-$timestamp wp-content"
```

**Automated Rollback (v2.6.0)**:
The `--rollback` flag automates the manual rollback process:
- Auto-detects latest timestamped backups in `db-backups/` and `wp-content.backup-*`
- Confirmation prompt (bypass with `--yes` for automation)
- Dry-run support for preview
- Works for archive mode migrations only (restores from local backups)

## v2.6.0 Feature Architecture

### 1. Migration Preview System

**Purpose**: Prevent migration mistakes by showing detailed summary before execution

**Implementation**:
```bash
show_migration_preview() {
  # Phase 1: Display summary header
  # Phase 2: Show source/destination details
  # Phase 3: Calculate and display statistics
  # Phase 4: List planned operations
  # Phase 5: Confirmation prompt
}
```

**Preview Components**:

**For Push Mode**:
- Source and destination URLs
- SSH connection details
- Database size estimate (via remote wp db size)
- File counts and rsync size estimate
- Planned operations list (backup, sync, search-replace, etc.)

**For Archive Mode**:
- Archive format and path
- Extracted size estimate
- Destination URL and paths
- Backup locations
- Planned operations list

**Non-Interactive Protection**:
```bash
if [[ ! -t 0 ]]; then
  err "This script requires a TTY for confirmation prompts. Add --yes flag for automation."
fi
```

**Bypass Options**:
- `--yes`: Skip confirmation for CI/CD
- `--dry-run`: Skip confirmation (preview only)

### 2. Rollback Command

**Purpose**: Easy recovery from failed or unwanted migrations

**Architecture**:
```bash
perform_rollback() {
  # Phase 1: Auto-detect latest backups
  # Phase 2: Validate backup existence
  # Phase 3: Show rollback preview
  # Phase 4: Confirmation prompt
  # Phase 5: Execute restoration
}
```

**Backup Detection Logic**:
```bash
# Find latest database backup
DB_BACKUP=$(find db-backups/ -name "backup-*.sql.gz" -type f | sort -r | head -1)

# Find latest wp-content backup
WP_CONTENT_BACKUP=$(find . -maxdepth 1 -name "wp-content.backup-*" -type d | sort -r | head -1)
```

**Features**:
- Auto-detection of latest timestamped backups
- Explicit backup specification via `--rollback-backup`
- Confirmation prompt (bypass with `--yes`)
- Dry-run support
- Non-interactive context protection

**Limitations**:
- Archive mode migrations only (local backups)
- Does not work for push mode (no local destination backups)

### 3. Progress Indicators

**Purpose**: User feedback for long-running operations

**Architecture**:

**Detection**:
```bash
if command -v pv &> /dev/null && [[ "$QUIET_MODE" != true ]]; then
  SHOW_PROGRESS=true
else
  SHOW_PROGRESS=false
fi
```

**Progress-Aware Operations**:

**Database Import**:
```bash
if [[ "$SHOW_PROGRESS" == true ]]; then
  pv "$DB_FILE" | wp db import -
else
  wp db import "$DB_FILE"
fi
```

**Archive Extraction**:
```bash
# ZIP archives with bsdtar (supports stdin for progress)
if command -v bsdtar &> /dev/null; then
  pv "$ARCHIVE_FILE" | bsdtar -xf - -C "$EXTRACT_DIR"
else
  # Fallback: unzip doesn't support stdin, no progress
  unzip -q "$ARCHIVE_FILE" -d "$EXTRACT_DIR"
fi

# TAR.GZ archives (GNU tar supports stdin)
pv "$ARCHIVE_FILE" | tar -xzf - -C "$EXTRACT_DIR"
```

**wp-content Sync**:
```bash
rsync -a --info=progress2 --delete "$SRC/" "$DEST/"
```

**Dependencies**:
- `pv` (pipe viewer) - optional, gracefully degrades if not installed
- `bsdtar` - optional, enables progress for ZIP archives

**Suppression**:
- `--quiet` flag disables all progress indicators

### 4. Non-Interactive Context Handling

**Problem**: Confirmation prompts fail silently in CI/CD, causing migrations to skip with exit 0

**Solution**: Detect non-interactive contexts and fail explicitly

**Detection**:
```bash
if [[ ! -t 0 ]]; then
  # stdin is not a TTY (CI/CD, cron, pipeline)
  err "This script requires a TTY for confirmation prompts. Add --yes flag for automation."
fi
```

**Impact**:
- Migration preview confirmation
- Rollback confirmation
- Prevents silent failures in automation

**Automation Support**:
- `--yes` flag bypasses all confirmation prompts
- Intended for CI/CD, cron jobs, non-interactive scripts

## Extension Points

### 1. Adding New Archive Formats

See [src/lib/adapters/README.md](../../../src/lib/adapters/README.md)

### 2. Custom rsync Options

**Via Command Line**:
```bash
--rsync-opt '--exclude=cache/'
--rsync-opt '--bwlimit=1000'
```

### 3. Custom SSH Options

**Via Command Line**:
```bash
--ssh-opt 'Port=2222'
--ssh-opt 'ProxyJump=bastion'
```

### 4. Hooks (Future Enhancement)

**Potential Hook Points**:
- Before/after database import
- Before/after wp-content sync
- Before/after search-replace
- On migration success/failure

## Debugging and Diagnostics

### Verbosity Levels

**Normal**: Essential operations only
```bash
./wp-migrate.sh <flags>
```

**Verbose**: Diagnostic information
```bash
./wp-migrate.sh <flags> --verbose
```

**Trace**: Every command shown
```bash
./wp-migrate.sh <flags> --trace
```

### Log File Analysis

**Location**:
```
logs/migrate-wpcontent-push-TIMESTAMP.log
logs/migrate-archive-import-TIMESTAMP.log
```

**Contents**:
- Timestamped operations
- Command outputs
- Error messages
- Rollback instructions

### Error Exit Codes

```bash
0   - Success
1   - General error (err() function)
2   - Dependency missing
3-9 - Reserved for future use
```

## Future Architecture Considerations

### Potential Enhancements

1. **Hook System**: Pre/post operation hooks
2. **Config Files**: YAML/TOML for complex migrations
3. **Progress Bars**: Visual feedback for long operations
4. **Parallel Transfers**: rsync multiple directories concurrently
5. **Incremental Backups**: Only backup changed files
6. **Remote Archive Mode**: Fetch archive from URL
7. **Multi-Site Support**: Handle WordPress multisite networks
8. **Custom Table Prefixes**: Allow prefix transformation
9. **Selective Sync**: Sync only plugins/themes/uploads
10. **Database Table Filtering**: Import only specific tables

### Backward Compatibility

**Deprecation Strategy**:
- Mark old flags as deprecated (e.g., --duplicator-archive)
- Maintain support for 2+ major versions
- Provide migration guide in CHANGELOG
- Show warnings when deprecated flags used

**Example**:
```bash
if [[ -n "$DUPLICATOR_ARCHIVE" ]]; then
  log "WARNING: --duplicator-archive is deprecated. Use --archive --archive-type=duplicator"
  ARCHIVE_FILE="$DUPLICATOR_ARCHIVE"
  ARCHIVE_TYPE="duplicator"
fi
```
