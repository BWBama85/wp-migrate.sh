# wp-migrate.sh

![Tests](https://github.com/BWBama85/wp-migrate.sh/workflows/Tests/badge.svg)

`wp-migrate.sh` migrates WordPress sites in two modes:

1. **Push mode**: Pushes a WordPress site's `wp-content` directory and database export from a source server to a destination server via SSH.
2. **Archive mode**: Imports WordPress backup archives (currently supports **wp-migrate native backups**, **Duplicator**, **Jetpack Backup**, **Solid Backups Legacy**, and **Solid Backups NextGen**; designed to support UpdraftPlus and other formats in future releases) directly on the destination server without requiring SSH access to the source.

Both modes coordinate the entire workflow, including maintenance mode, database handling, file sync, and cache maintenance.

## Features

### Migration Preview
- **Pre-migration summary** displays detailed information before starting any operations.
- Shows source/destination URLs, database size, file counts, and disk space requirements.
- Lists planned operations step-by-step (database export, transfer, import, search-replace, file sync).
- **Confirmation prompt** "Proceed with migration? [y/N]" gives you a chance to review before making changes.
- Skip confirmation with `--yes` flag for automated workflows.
- Works in both push mode and archive mode with mode-specific details.

### Push Mode
- Verifies WordPress installations on both source and destination before proceeding.
- **Shows migration preview** with source/destination details, file sizes, and planned operations.
- Enables maintenance mode on both sides during a real migration to minimise downtime (skip the source with `--no-maint-source`).
- Exports the database, transfers it to the destination, and imports it by default (disable with `--no-import-db`; gzipped dumps are decompressed automatically).
- Rewrites migrated URLs so the destination keeps its own domain via `wp search-replace` (skipped for dry runs or `--no-import-db`; use `--no-search-replace` to skip bulk search-replace and only update home/siteurl options).
- Creates a timestamped backup of the destination `wp-content` directory before replacing it.
- Syncs the entire `wp-content` tree with rsync archive mode; files on the destination are overwritten.
- **Shows real-time progress bars** for database transfers and file synchronization when `pv` is installed (optional dependency).
- **Excludes `object-cache.php`** to preserve destination caching infrastructure and prevent fatal errors from missing PHP extensions (Redis, Memcache, etc.).
- Optionally flushes the destination Object Cache Pro/Redis cache when `wp redis` is available.
- Supports a comprehensive dry-run mode that previews every step without mutating either server.

### Archive Mode
- Imports WordPress backup archives (currently supports **wp-migrate native backups**, **Duplicator**, **Jetpack Backup**, **Solid Backups Legacy**, and **Solid Backups NextGen**; designed to support additional formats).
  - **wp-migrate**: Native backup format with JSON metadata, simple structure (created by `--create-backup` mode)
  - **Duplicator**: ZIP archives with `dup-installer/dup-database__*.sql` structure
  - **Jetpack Backup**: ZIP, TAR.GZ, or TAR archives with `sql/*.sql` multi-file structure
  - **Solid Backups Legacy** (formerly BackupBuddy): ZIP archives with split SQL files in `wp-content/uploads/backupbuddy_temp/{BACKUP_ID}/` (one file per table, automatically consolidated during import)
  - **Solid Backups NextGen**: ZIP archives with completely different structure using `data/` and `files/` directories (one SQL file per table in `data/`, WordPress files in `files/`)
- **Extensible adapter system** makes adding new backup formats simple (see [src/lib/adapters/README.md](src/lib/adapters/README.md) for contributor guide).
- **Auto-detects backup format** or accepts explicit `--archive-type` for manual override.
- **Shows migration preview** with archive details, format, size, file counts, and planned operations.
- Automatically extracts and detects database and wp-content from archives with smart directory scoring.
- **Shows real-time progress bars** for archive extraction, database imports, and file synchronization when `pv` is installed. ZIP extraction progress requires `bsdtar` (optional dependency).
- Pre-flight disk space validation ensures 3x archive size is available (archive + extraction + buffer).
- Creates timestamped backups of both the destination database and wp-content before any destructive operations.
- Automatically detects and aligns table prefix if the imported database uses a different prefix than the destination's `wp-config.php` (supports complex prefixes with underscores like `my_site_`, `wp_live_2024_`).
- Automatically detects imported site URLs and performs search-replace to align with the destination site URLs (use `--no-search-replace` to skip bulk search-replace and only update home/siteurl options).
- **Removes `object-cache.php`** from imported archive to preserve destination caching infrastructure and prevent fatal errors from missing PHP extensions (Redis, Memcache, etc.).
- Provides comprehensive rollback instructions with exact commands to restore both backups if needed.
- Auto-cleanup of temporary extraction directory on success; kept on failure for debugging.
- Supports dry-run mode to preview the import workflow without making any changes.

### Rollback Mode
- **One-command rollback** to undo migrations using backups created during archive mode operations.
- **Auto-detects latest backups** from `db-backups/` directory and `wp-content.backup-*` directories.
- **Confirmation prompt** before proceeding (skip with `--yes` flag for automation).
- **Dry-run support** to preview rollback plan without making changes.
- **Explicit backup specification** via `--rollback-backup` for manual control.
- Restores both database and wp-content atomically.
- Provides clear error messages if backups are not found or restoration fails.

## Requirements

### Push Mode
- WordPress CLI (`wp`)
- `rsync`
- `ssh`
- `gzip` (also required on the destination when importing compressed dumps)

Run the script from the WordPress root on the source server (where `wp-config.php` lives). The destination host must be reachable over SSH and capable of running `wp` commands.

### Archive Mode
- WordPress CLI (`wp`)
- `file` (for archive type detection)
- `unzip` and `tar` (for archive format extraction - wp-migrate, Duplicator, and Solid Backups use ZIP; Jetpack uses TAR.GZ or TAR)
- `jq` (for wp-migrate format JSON validation - optional, only needed when importing wp-migrate archives)

Run the script from the WordPress root on the destination server (where `wp-config.php` lives). The backup archive must be accessible on the filesystem.

### Optional Dependencies

These tools are optional but provide enhanced functionality when installed:

- **`pv` (Pipe Viewer)**: Enables real-time progress bars for long-running operations including database imports, archive extraction, and file synchronization. Without `pv`, operations complete successfully but without progress feedback.
  - Install: `apt-get install pv` (Debian/Ubuntu) or `brew install pv` (macOS)

- **`bsdtar` (BSD tar)**: Enables progress bars for ZIP archive extraction when combined with `pv`. Standard `unzip` doesn't support reading from stdin (required for progress piping), but `bsdtar` does. Without `bsdtar`, ZIP extraction works correctly but without progress feedback, while tar-based archives (Jetpack tar.gz) still show progress via GNU tar.
  - Install: `apt-get install libarchive-tools` (Debian/Ubuntu) or `brew install libarchive` (macOS)
  - Note: On macOS, `bsdtar` is typically pre-installed

- **`jq` (JSON processor)**: Required for wp-migrate format validation when importing native backups. The wp-migrate format uses JSON metadata (`wpmigrate-backup.json`) that must be validated. Without `jq`, wp-migrate archives cannot be imported, but other formats work normally.
  - Install: `apt-get install jq` (Debian/Ubuntu) or `brew install jq` (macOS)

**Progress Matrix:**

| Archive Format | pv | bsdtar | Progress Shown? |
|----------------|-----|--------|-----------------|
| ZIP (wp-migrate, Duplicator, Solid Backups) | ✅ | ✅ | ✅ Yes |
| ZIP | ✅ | ❌ | ❌ No (but works) |
| ZIP | ❌ | - | ❌ No |
| tar.gz/tar (Jetpack) | ✅ | - | ✅ Yes (via GNU tar) |
| tar.gz/tar | ❌ | - | ❌ No |

## Usage

### Push Mode
```bash
./wp-migrate.sh --dest-host user@dest.example.com --dest-root /var/www/site [options]
```

Common examples:
- Real migration with default behaviour:
  ```bash
  ./wp-migrate.sh --dest-host wp@dest --dest-root /var/www/site
  ```
- Dry run with an additional rsync option (e.g., exclude a directory):
  ```bash
  ./wp-migrate.sh --dest-host wp@dest --dest-root /var/www/site \
    --dry-run --rsync-opt '--exclude=uploads/large-folders/'
  ```
- Migrate but skip importing the database on the destination:
  ```bash
  ./wp-migrate.sh --dest-host wp@dest --dest-root /var/www/site --no-import-db
  ```

### Archive Mode
```bash
./wp-migrate.sh --archive /path/to/backup [options]
```

Common examples:
- Import a backup archive (auto-detect format):
  ```bash
  # wp-migrate native backup
  ./wp-migrate.sh --archive /backups/example-com-2025-11-15-143022.zip

  # Duplicator
  ./wp-migrate.sh --archive /backups/duplicator-site.zip

  # Jetpack Backup
  ./wp-migrate.sh --archive /backups/jetpack-backup.tar.gz

  # Solid Backups Legacy (formerly BackupBuddy)
  ./wp-migrate.sh --archive /backups/solidbackups-legacy.zip

  # Solid Backups NextGen
  ./wp-migrate.sh --archive /backups/solidbackups-nextgen.zip
  ```
- Import with explicit format specification:
  ```bash
  ./wp-migrate.sh --archive /backups/site.zip --archive-type wpmigrate
  ./wp-migrate.sh --archive /backups/site.zip --archive-type duplicator
  ./wp-migrate.sh --archive /backups/backup.tar.gz --archive-type jetpack
  ./wp-migrate.sh --archive /backups/backup.zip --archive-type solidbackups
  ./wp-migrate.sh --archive /backups/backup.zip --archive-type solidbackups_nextgen
  ```
- Preview import without making changes (dry run):
  ```bash
  ./wp-migrate.sh --archive /backups/site.zip --dry-run
  ```
- **Backward compatible** - old Duplicator flag still works:
  ```bash
  ./wp-migrate.sh --duplicator-archive /backups/site.zip
  ```

**Note:** Currently supports **wp-migrate native backups** (created with `--create-backup`), **Duplicator**, **Jetpack Backup**, **Solid Backups Legacy**, and **Solid Backups NextGen** archives. The extensible adapter architecture supports adding UpdraftPlus and other formats—contributors can add adapters following the guide in [src/lib/adapters/README.md](src/lib/adapters/README.md).

### Backup Creation Mode

Create WordPress backups locally or remotely via SSH. Backups are compatible with `--archive` import mode.

#### Local Backup (No SSH Required)

Run directly from your WordPress directory:

```bash
cd /var/www/html
./wp-migrate.sh --create-backup
```

Or specify a path:

```bash
./wp-migrate.sh --create-backup --source-root /var/www/html
```

#### Remote Backup (via SSH)

Create a backup on a remote server:

```bash
./wp-migrate.sh --source-host user@source.example.com \
                --source-root /var/www/html \
                --create-backup
```

**Features:**
- Creates timestamped ZIP archive with database and wp-content in **wp-migrate native format**
- Includes JSON metadata (`wpmigrate-backup.json`) for format validation
- Automatically excludes cache directories, object cache files, and debug logs
- Stores backup in `~/wp-migrate-backups/`
- **Fully compatible with `--archive` import mode** - backups can be imported on any WordPress installation
- Local mode requires no SSH configuration

**Backup location:** `~/wp-migrate-backups/{domain}-{YYYY-MM-DD-HHMMSS}.zip`

**Archive format:** wp-migrate native format with simple structure (see [src/lib/adapters/README.md](src/lib/adapters/README.md) for format details)

**Example workflows:**

**Local backup and import:**
```bash
# Step 1: Create local backup
cd /var/www/html
./wp-migrate.sh --create-backup

# Output: Backup created: ~/wp-migrate-backups/example-com-2025-11-11-143022.zip

# Step 2: Import on another server
./wp-migrate.sh --archive ~/wp-migrate-backups/example-com-2025-11-11-143022.zip
```

**Remote backup workflow:**
```bash
# Step 1: Create backup on source server
./wp-migrate.sh --source-host user@source.example.com \
                --source-root /var/www/html \
                --create-backup

# Step 2: Download backup
scp user@source.example.com:~/wp-migrate-backups/example-com-2025-11-11-143022.zip .

# Step 3: Import on destination
./wp-migrate.sh --archive example-com-2025-11-11-143022.zip
```

**Dry-run preview:**
```bash
# Local
./wp-migrate.sh --create-backup --dry-run

# Remote
./wp-migrate.sh --source-host user@source.example.com \
                --source-root /var/www/html \
                --create-backup --dry-run
```

### Rollback Mode
```bash
./wp-migrate.sh --rollback [options]
```

Common examples:
- Rollback to latest backup (with confirmation prompt):
  ```bash
  ./wp-migrate.sh --rollback
  ```
- Rollback without confirmation (for automation):
  ```bash
  ./wp-migrate.sh --rollback --yes
  ```
- Preview rollback without making changes:
  ```bash
  ./wp-migrate.sh --rollback --dry-run
  ```
- Rollback using specific backup file:
  ```bash
  ./wp-migrate.sh --rollback --rollback-backup db-backups/pre-archive-backup_20251020-164523.sql.gz
  ```

**Note:** Rollback mode works with backups created during archive mode migrations. Backups are automatically created in `db-backups/` (database) and `wp-content.backup-TIMESTAMP` (files) before any destructive operations.

## Options

### Common Options (both modes)
| Flag | Description |
| ---- | ----------- |
| `--dry-run` | Preview the workflow without making changes. No files are created, maintenance mode is not toggled, caches are left untouched, and database operations are described rather than executed. Safe to run on production sites. |
| `--quiet` | Suppress progress indicators for long-running operations. Useful for non-interactive scripts or automated migrations where progress output is not desired. Operations complete normally but without real-time progress bars even if `pv` is installed. |
| `--yes` | Skip confirmation prompts for automated/non-interactive workflows. Applies to migration preview confirmation and rollback confirmation. **Use with caution** as it bypasses safety checks. |
| `--verbose` | Show additional details during migration. Displays dependency checks, command construction, archive detection process, and other diagnostic information. Useful for understanding what the script is doing and troubleshooting issues. Can be combined with `--dry-run` to preview detailed workflow. |
| `--trace` | Show every command before execution (implies `--verbose`). Displays exact commands (rsync, wp-cli, ssh, etc.) with all arguments before running them. Useful for debugging, filing bug reports, or manually reproducing operations. Output can be copied/pasted to run commands manually. |
| `--help` | Print usage information and exit. |
| `--version` | Show version information and exit. |

### Push Mode Options

#### Required Flags
| Flag | Description |
| ---- | ----------- |
| `--dest-host <user@host>` | **Required.** SSH connection string for the destination server (e.g., `wp@example.com` or `user@192.168.1.100`). |
| `--dest-root </abs/path>` | **Required.** Absolute path to WordPress root directory on destination server (e.g., `/var/www/html` or `/home/user/public_html`). |

#### Database Options
| Flag | Description |
| ---- | ----------- |
| `--import-db` | (Deprecated) Explicitly request database import on destination. The script imports by default, so this flag is no longer needed. |
| `--no-import-db` | Skip importing the database on destination after transfer. The SQL dump will be transferred but not imported. Useful for manual review before import. If the dump is gzipped (`.gz`), decompress it first: `gunzip dump.sql.gz && wp db import dump.sql` |
| `--no-search-replace` | Skip bulk search-replace operations but still update `home` and `siteurl` options to destination URLs. Useful for faster migrations when you only need the site to load at destination but don't need to replace URLs in post content, metadata, or other options. **Warning:** Only `home` and `siteurl` WordPress options are updated; all other content (posts, metadata, serialized options) remains unchanged. The script logs the manual `wp search-replace` command if you need to run it later. |
| `--no-gzip` | Skip gzipping the database dump before transfer. By default, the script gzips the dump to reduce transfer time. Use this flag if you prefer uncompressed dumps or have very fast network. |

#### Source Site Options
| Flag | Description |
| ---- | ----------- |
| `--no-maint-source` | Skip enabling maintenance mode on the source site during migration. By default, source site is placed in maintenance mode to prevent content changes during migration. Use this flag if you want the source site to remain accessible (not recommended for production migrations). |

#### Destination URL Overrides
| Flag | Description |
| ---- | ----------- |
| `--dest-domain <host>` | Override destination domain detection. By default, the script uses the SSH hostname. Specify custom domain for search-replace operations (e.g., `--dest-domain example.com`). Automatically prepends `https://` unless you provide full URL. |
| `--dest-home-url <url>` | Force the destination `home` URL for search-replace operations. Overrides auto-detection. Must be full URL (e.g., `https://example.com`). The `home` option controls the site's front-end URL. |
| `--dest-site-url <url>` | Force the destination `siteurl` for search-replace operations. Overrides auto-detection. Must be full URL (e.g., `https://example.com`). The `siteurl` option controls the WordPress admin URL. |

#### Transfer Options
| Flag | Description |
| ---- | ----------- |
| `--rsync-opt <opt>` | Append additional rsync option (can be specified multiple times). Useful for custom rsync behavior like bandwidth limiting (`--rsync-opt '--bwlimit=1000'`) or excluding patterns (`--rsync-opt '--exclude=*.log'`). |
| `--ssh-opt <opt>` | Append additional SSH `-o` option (can be specified multiple times). Useful for SSH configuration like jump hosts (`--ssh-opt 'ProxyJump=bastion.example.com'`), custom ports (`--ssh-opt 'Port=2222'`), or key files (`--ssh-opt 'IdentityFile=~/.ssh/custom_key'`). |

### Archive Mode Options

#### Required Flags
| Flag | Description |
| ---- | ----------- |
| `--archive </path/to/backup>` | **Required.** Path to backup archive file or extracted directory. Supports wp-migrate native backups (ZIP), Duplicator (ZIP), Jetpack Backup (ZIP, TAR.GZ, TAR, or extracted directory), Solid Backups Legacy (ZIP or extracted directory), and Solid Backups NextGen (ZIP or extracted directory). Format is auto-detected. Mutually exclusive with `--dest-host`. |
| `--archive-type <type>` | **Optional.** Explicitly specify archive format: `wpmigrate`, `duplicator`, `jetpack`, `solidbackups` (legacy), or `solidbackups_nextgen`. Useful when auto-detection fails or you want to skip detection. If not specified, the script tries each adapter's validation function to identify the format. Use `wpmigrate` for native backups created with `--create-backup`, `solidbackups` for old Solid Backups/BackupBuddy archives (with `backupbuddy_temp/` structure), and `solidbackups_nextgen` for new NextGen archives (with `data/` and `files/` structure). |
| `--duplicator-archive </path/to/backup.zip>` | **Deprecated.** Use `--archive` instead. Maintained for backward compatibility - internally converted to `--archive --archive-type=duplicator`. Will be removed in v3.0.0. |

#### Database Options
| Flag | Description |
| ---- | ----------- |
| `--no-search-replace` | Skip bulk search-replace operations but still update `home` and `siteurl` options to destination URLs. Useful for faster migrations when you only need the site to load at destination but don't need to replace URLs in post content, metadata, or other options. **Warning:** Only `home` and `siteurl` WordPress options are updated; all other content (posts, metadata, serialized options) remains unchanged. The script logs the manual `wp search-replace` command if you need to run it later. |

### Plugin/Theme Preservation Options (both modes)

| Flag | Description |
| ---- | ----------- |
| `--preserve-dest-plugins` | Preserve destination plugins and themes that don't exist in the source. After wp-content sync, the script detects unique destination plugins/themes, restores them from backup, and automatically deactivates restored plugins (themes remain available but inactive). Useful for preserving host-specific plugins or custom configurations. Works in both push and archive modes. |
| `--stellarsites` | Enable StellarSites managed hosting compatibility mode. Automatically enables `--preserve-dest-plugins` and excludes the destination `mu-plugins/` directory and `mu-plugins.php` loader file from being overwritten during wp-content sync. Prevents conflicts with StellarSites' protected mu-plugins system (e.g., `mu-plugins/stellarsites-cloud`). Recommended for StellarSites and similar managed WordPress hosts that provide system-level mu-plugins. Works in both push and archive modes. |

## Workflow Overview

### Push Mode
1. **Preflight**: Ensures the script runs from a WordPress root, verifies the presence of required binaries, confirms both WP installations, and tests SSH connectivity.
2. **Discovery**: Determines source and destination `wp-content` paths and logs disk usage details.
3. **Maintenance Mode**: Activates maintenance on both sides during a real migration (`wp maintenance-mode activate`). Dry runs only log what would happen.
4. **Database Step**:
   - Real run: Exports the source DB (optionally gzipped), stores it in `db-dumps/`, creates the destination `db-imports` directory, transfers the dump, and imports it by default (gzipped files are expanded on the destination first; use `--no-import-db` to skip). When domains differ, it aligns the destination database back to its original URL with `wp search-replace` and resets the `home`/`siteurl` options. Use `--no-search-replace` to skip bulk search-replace and only update `home`/`siteurl` options (faster but leaves URLs in content unchanged). Supply `--dest-domain`, `--dest-home-url`, or `--dest-site-url` if you need to override the detected destination values.
   - Dry run: Logs the planned export, transfer, import, and any pending URL replacements without creating `db-dumps/` or touching the destination.
5. **File Sync**: Builds rsync options (archive mode, compression, link preservation, no ownership/permission changes) and syncs `wp-content` from source to destination. Dry runs leverage `rsync --dry-run --itemize-changes`.
6. **Post Tasks**: Flushes the destination Object Cache Pro cache via `wp redis flush` when the command exists. Dry runs skip execution and log intent.
7. **Cleanup**: Disables maintenance mode (real runs only) and logs final status as well as the dump location or future import instructions when imports are skipped.

### Archive Mode
1. **Preflight**: Ensures the script runs from a WordPress root, verifies required binaries, confirms WordPress installation, validates the archive file exists.
2. **Format Detection**: Auto-detects archive format (wp-migrate, Duplicator, Jetpack Backup, Solid Backups Legacy, or Solid Backups NextGen) by trying each adapter's validation function. Each adapter checks for format-specific signature files:
   - **wp-migrate**: Looks for `wpmigrate-backup.json` metadata file (checked first for performance)
   - **Duplicator**: Looks for `installer.php` and `dup-installer/` directory
   - **Jetpack Backup**: Looks for `meta.json` + `sql/wp_options.sql` (archives) or `sql/` + `meta.json` + `wp-content/` (extracted directories)
   - **Solid Backups Legacy**: Looks for `importbuddy.php` or `backupbuddy_dat.php` signature files in `wp-content/uploads/backupbuddy_temp/`
   - **Solid Backups NextGen**: Looks for `data/` directory with SQL files and `files/` directory
   - Alternatively, use explicit `--archive-type` to skip auto-detection
3. **Dependency Check**: Verifies format-specific tools are available (e.g., `unzip` for ZIP archives, `tar` for TAR/GZ archives).
4. **URL Capture**: Captures current destination site URLs (`home` and `siteurl` options) before any operations.
5. **Disk Space Check**: Validates that 3x the archive size is available (archive + extraction + buffer) and fails early if insufficient.
6. **Extraction**: Extracts the archive to a temporary directory using the appropriate adapter's extract function.
7. **Discovery**: Auto-detects the database file and wp-content directory using format-specific adapter functions:
   - **wp-migrate**: Single SQL file at root (`database.sql`), wp-content at root
   - **Duplicator**: Single SQL file in `dup-installer/dup-database__*.sql`
   - **Jetpack Backup**: Multiple SQL files in `sql/*.sql` directory, automatically consolidated during import
   - **Solid Backups Legacy**: Split SQL files (one per table) in `wp-content/uploads/backupbuddy_temp/{BACKUP_ID}/`, automatically consolidated during import
   - **Solid Backups NextGen**: Split SQL files (one per table) in `data/` directory, WordPress files in `files/` directory, automatically consolidated during import
   - Smart directory scoring based on presence of plugins/themes/uploads subdirectories
8. **Maintenance Mode**: Activates maintenance mode on the destination during a real import. Dry runs only log what would happen.
9. **Backup Database**: Creates a timestamped gzipped backup of the current destination database in `db-backups/` before import.
10. **Backup wp-content**: Creates a timestamped backup of the current destination wp-content directory before replacement.
11. **Import Database**: Imports the database from the archive (Solid Backups split SQL files are consolidated first).
12. **Table Prefix Alignment**: Detects the table prefix from the imported database by verifying core WordPress tables (`options`, `posts`, `users`) exist with the same prefix. If the imported prefix differs from `wp-config.php`, automatically updates `wp-config.php` to match. Supports complex prefixes with underscores (e.g., `my_site_`, `wp_live_2024_`).
13. **URL Alignment**: Detects the imported site URLs, performs `wp search-replace` to align all URL references to the destination URLs (captured in step 4), and updates the `home`/`siteurl` options. Use `--no-search-replace` to skip bulk search-replace and only update `home`/`siteurl` options (faster but leaves URLs in content unchanged).
14. **Replace wp-content**: Removes the existing wp-content directory and replaces it completely with the wp-content from the archive (1:1 copy). The `object-cache.php` file is excluded to preserve destination caching infrastructure.
15. **Post Tasks**: Flushes the Object Cache Pro cache via `wp redis flush` when available.
16. **Cleanup**: Disables maintenance mode and removes the temporary extraction directory on success (keeps it on failure for debugging).
17. **Rollback Instructions**: Logs detailed rollback commands showing how to restore both the database and wp-content backups if needed.

## Directories and Logging

### Push Mode
- Real runs create `logs/` with timestamped log files (`migrate-wpcontent-push-*.log`) and `db-dumps/` for exported databases.
- Dry runs do **not** create or modify directories; logging is routed to `/dev/null` to ensure a zero-impact preview.

### Archive Mode
- Real runs create `logs/` with timestamped log files (`migrate-archive-import-*.log`) and `db-backups/` for database backups before import.
- Timestamped wp-content backups are created alongside the original wp-content directory (e.g., `wp-content.backup-20251009-123456`).
- Temporary extraction directory is auto-created in `$TMPDIR` (typically `/tmp`) and removed on success.
- Dry runs do **not** create or modify directories; logging is routed to `/dev/null` to ensure a zero-impact preview.

## Safety Characteristics

### Security Features (v2.10.0)

The script includes comprehensive security protections added in v2.10.0 to prevent common attack vectors and data loss scenarios:

- **Zip Slip Path Traversal Protection**: All archive extraction validates paths to prevent malicious archives from writing files outside the extraction directory. Archives containing paths like `../../etc/passwd` are rejected with detailed error messages. This prevents potential remote code execution via crafted archives.

- **SQL Injection Prevention**: Table names are validated before DROP TABLE operations. Only WordPress-pattern table names are allowed: `{prefix}_{tablename}` or `{prefix}{number}_{tablename}` (multisite). This prevents malicious table names from executing arbitrary SQL commands.

- **Emergency Database Snapshot**: Before database reset, an emergency snapshot is automatically created. If import fails or produces zero tables, the original database is automatically restored on script exit. The snapshot is cleaned up after successful migration, preventing permanent database loss from crashes.

- **Multi-WordPress Database Detection**: The script detects when multiple WordPress installations share a database and prevents ambiguous migrations. Users must confirm which installation to import, preventing accidental imports from the wrong site.

- **wp-content Backup Verification**: Backup operations are validated before proceeding with destructive changes. The script verifies backup existence, non-emptiness, and that backup size matches source (within 10% tolerance). This prevents data loss from failed backup operations.

- **Dry-run Mode Safety**: Dry-run mode is fully functional and performs no file operations. All file stat, size checks, and filesystem operations check the `$DRY_RUN` flag first, providing accurate migration previews without touching the filesystem.

### WP-CLI Automatic Error Recovery (v2.9.0)

All WP-CLI commands automatically use `--skip-plugins --skip-themes` flags:
- **Prevents plugin/theme errors** from breaking migrations or rollbacks
- **Provides automatic recovery** when plugin/theme code causes fatal errors
- **Safe for all migration operations** - the script uses only low-level database and filesystem commands (plugin/theme code is not needed)
- **Consistent behavior** between local (`wp_local`) and remote (`wp_remote`) WP-CLI operations

This means migrations will succeed even if destination plugins or themes have errors, and rollbacks will work even if the migration introduced problematic code.

### Push Mode
- A timestamped backup of the destination `wp-content` directory is created before files are overwritten.
- Rsync runs without `--delete`, so unmatched files on the destination remain in place, and remote ownership/permissions are untouched (`--no-perms --no-owner --no-group`).
- Maintenance commands run under `set -e`; if enabling or disabling maintenance fails the script aborts to prevent partial migrations.
- Cache flushing is attempted but non-blocking; failures are logged and the run continues.

### Archive Mode
- Both database and wp-content are backed up **before** any destructive operations occur.
- Database backup is created as a gzipped SQL dump in `db-backups/pre-archive-backup_<timestamp>.sql.gz`.
- wp-content backup is created as a complete timestamped copy (e.g., `wp-content.backup-<timestamp>`).
- Comprehensive rollback instructions are logged showing exact commands to restore both backups.
- Maintenance mode activation runs under `set -e`; if it fails the script aborts before making any changes.
- Temporary extraction directory is preserved on failure for debugging (removed on success).
- The script ensures a perfect 1:1 copy of the backed-up site with only URLs changed to match the destination.

## Git Workflow
Use the repo's Git helpers to keep changes small, reviewable, and easy to trace.

1. Branching: start from `main` and create a descriptive branch such as `feature/<slug>` for enhancements or `fix/<slug>` for bug fixes.
2. Commits: commit in small slices using the `.gitmessage` template. Run `git config commit.template .gitmessage` once per clone, then write messages as `type: short imperative summary` (e.g., `feat: add staging backup option`).
3. Changelog: update `CHANGELOG.md` under the `[Unreleased]` section with every feature or fix.
4. Review: open a pull request (even when working solo) and use the checklist in `.github/pull_request_template.md` to verify testing and documentation.
5. Merging: keep `main` release-ready by merging with `git merge --no-ff` or by squashing after review; delete the feature branch once merged.
6. Releases: tag meaningful milestones (e.g., `git tag v0.3.0`) and include a brief summary in the pull request or release notes.

## Troubleshooting
- Ensure `wp` runs correctly on both hosts; authentication or environment issues will surface during the verification step.
- Supply additional SSH options with repeated `--ssh-opt` flags (e.g., alternate ports or identities).
- Install [ShellCheck](https://www.shellcheck.net/) to lint modifications; the current script is ShellCheck-clean.

## Development

### Source Code Structure (v2+)

Starting with v2.0.0, the codebase uses a modular source structure for easier maintenance:

```
src/
├── header.sh         # Shebang, defaults, variable declarations
├── lib/
│   ├── core.sh       # Core utilities (log, err, validate_url)
│   └── functions.sh  # All other functions
└── main.sh           # Argument parsing and main execution
```

The single-file `wp-migrate.sh` at the repo root is built from these modular source files.

### Building from Source

If you modify files in `src/`, you must rebuild the script:

```bash
# Install dependencies (macOS/Linux)
# - shellcheck (linting)
# - make (build system)

# Build the single-file script
make build

# This will:
# 1. Run shellcheck on the concatenated source
# 2. Concatenate src/ files into dist/wp-migrate.sh
# 3. Copy to ./wp-migrate.sh (repo root)
# 4. Generate SHA256 checksum
```

### Git Hook Setup (Recommended)

To prevent accidentally committing source changes without rebuilding, install the pre-commit hook:

```bash
ln -s ../../.githooks/pre-commit .git/hooks/pre-commit
```

This hook will block commits if you modify `src/` files without updating both `wp-migrate.sh` and `wp-migrate.sh.sha256`.

### Makefile Targets

- `make build` - Build the single-file script from modular source
- `make test` - Run shellcheck on the complete built script
- `make clean` - Remove build artifacts (`dist/` directory)
- `make help` - Show available targets

### Contributing

This project was developed with assistance from AI coding tools ([Claude Code](https://claude.com/claude-code)). Contributions are welcome!

When contributing to v2+:
1. Make changes in `src/` files (not `wp-migrate.sh` directly)
2. Run `make build` to regenerate `wp-migrate.sh`
3. Commit both the source files and built file
4. Open a PR with your changes

## License
MIT License - see [LICENSE](LICENSE) file for details.

Copyright (c) 2025 BWBama85
