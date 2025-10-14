# wp-migrate.sh

`wp-migrate.sh` migrates WordPress sites in two modes:

1. **Push mode**: Pushes a WordPress site's `wp-content` directory and database export from a source server to a destination server via SSH.
2. **Archive mode**: Imports WordPress backup archives (Duplicator, Jetpack, UpdraftPlus, etc.) directly on the destination server without requiring SSH access to the source.

Both modes coordinate the entire workflow, including maintenance mode, database handling, file sync, and cache maintenance.

## Features

### Push Mode
- Verifies WordPress installations on both source and destination before proceeding.
- Enables maintenance mode on both sides during a real migration to minimise downtime (skip the source with `--no-maint-source`).
- Exports the database, transfers it to the destination, and imports it by default (disable with `--no-import-db`; gzipped dumps are decompressed automatically).
- Rewrites migrated URLs so the destination keeps its own domain via `wp search-replace` (skipped for dry runs or `--no-import-db`).
- Creates a timestamped backup of the destination `wp-content` directory before replacing it.
- Syncs the entire `wp-content` tree with rsync archive mode; files on the destination are overwritten.
- **Excludes `object-cache.php`** to preserve destination caching infrastructure and prevent fatal errors from missing PHP extensions (Redis, Memcache, etc.).
- Optionally flushes the destination Object Cache Pro/Redis cache when `wp redis` is available.
- Supports a comprehensive dry-run mode that previews every step without mutating either server.

### Archive Mode
- Imports WordPress backup archives from various plugins (Duplicator, Jetpack, UpdraftPlus, etc.) without requiring SSH access to the source server.
- **Auto-detects backup format** or accepts explicit `--archive-type` for manual override.
- Automatically extracts and detects database and wp-content from archives with smart directory scoring.
- **Extensible adapter system** makes adding new backup formats simple (see [src/lib/adapters/README.md](src/lib/adapters/README.md) for contributor guide).
- Pre-flight disk space validation ensures 3x archive size is available (archive + extraction + buffer).
- Creates timestamped backups of both the destination database and wp-content before any destructive operations.
- Automatically detects and aligns table prefix if the imported database uses a different prefix than the destination's `wp-config.php` (supports complex prefixes with underscores like `my_site_`, `wp_live_2024_`).
- Automatically detects imported site URLs and performs search-replace to align with the destination site URLs.
- **Removes `object-cache.php`** from imported archive to preserve destination caching infrastructure and prevent fatal errors from missing PHP extensions (Redis, Memcache, etc.).
- Provides comprehensive rollback instructions with exact commands to restore both backups if needed.
- Auto-cleanup of temporary extraction directory on success; kept on failure for debugging.
- Supports dry-run mode to preview the import workflow without making any changes.

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
- Format-specific tools (e.g., `unzip` for Duplicator, `tar` for Jetpack)

Run the script from the WordPress root on the destination server (where `wp-config.php` lives). The backup archive must be accessible on the filesystem.

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
  ./wp-migrate.sh --archive /backups/site_20251009.zip
  ```
- Import with explicit format specification:
  ```bash
  ./wp-migrate.sh --archive /backups/jetpack-backup.tar.gz --archive-type jetpack
  ```
- Preview import without making changes (dry run):
  ```bash
  ./wp-migrate.sh --archive /backups/site_20251009.zip --dry-run
  ```
- **Backward compatible** - old Duplicator flag still works:
  ```bash
  ./wp-migrate.sh --duplicator-archive /backups/site.zip
  ```

## Options

### Common Options (both modes)
| Flag | Description |
| ---- | ----------- |
| `--dry-run` | Preview the workflow. No files are created, maintenance mode is not toggled, and caches are left untouched. Database work is described rather than executed. |
| `--help` | Print usage information and exit. |
| `--version` | Show version information and exit. |

### Push Mode Options
| Flag | Description |
| ---- | ----------- |
| `--dest-host <user@host>` | **Required.** SSH connection string for the destination server. |
| `--dest-root </abs/path>` | **Required.** Absolute path to WordPress root on destination server. |
| `--import-db` | (Deprecated) Explicitly request a destination DB import; the script already imports by default. |
| `--no-import-db` | Skip importing the transferred SQL dump on the destination (manually import later; decompress first if the file ends in `.gz`). |
| `--no-gzip` | Skip gzipping the database dump before transfer. |
| `--no-maint-source` | Leave the source site out of maintenance mode during the migration. |
| `--dest-domain <host>` | Override detection by forcing the destination domain (defaults to `https://<host>` unless other overrides are supplied). |
| `--dest-home-url <url>` | Force the destination `home` URL used for post-import replacements. |
| `--dest-site-url <url>` | Force the destination `siteurl` used for post-import replacements. |
| `--rsync-opt <opt>` | Append an additional rsync option (can be passed multiple times). |
| `--ssh-opt <opt>` | Append an extra SSH option (repeatable; options are safely quoted). |

### Archive Mode Options
| Flag | Description |
| ---- | ----------- |
| `--archive </path/to/backup>` | **Required.** Path to the backup archive file (ZIP, TAR, TAR.GZ, etc.). Format is auto-detected (mutually exclusive with `--dest-host`). |
| `--archive-type <type>` | **Optional.** Explicitly specify archive format (`duplicator`, `jetpack`, etc.). Useful when auto-detection fails. Available types are listed if detection fails. |
| `--duplicator-archive </path/to/backup.zip>` | **Deprecated.** Use `--archive` instead. Still works for backward compatibility (treated as `--archive --archive-type=duplicator`). |

## Workflow Overview

### Push Mode
1. **Preflight**: Ensures the script runs from a WordPress root, verifies the presence of required binaries, confirms both WP installations, and tests SSH connectivity.
2. **Discovery**: Determines source and destination `wp-content` paths and logs disk usage details.
3. **Maintenance Mode**: Activates maintenance on both sides during a real migration (`wp maintenance-mode activate`). Dry runs only log what would happen.
4. **Database Step**:
   - Real run: Exports the source DB (optionally gzipped), stores it in `db-dumps/`, creates the destination `db-imports` directory, transfers the dump, and imports it by default (gzipped files are expanded on the destination first; use `--no-import-db` to skip). When domains differ, it aligns the destination database back to its original URL with `wp search-replace` and resets the `home`/`siteurl` options. Supply `--dest-domain`, `--dest-home-url`, or `--dest-site-url` if you need to override the detected destination values.
   - Dry run: Logs the planned export, transfer, import, and any pending URL replacements without creating `db-dumps/` or touching the destination.
5. **File Sync**: Builds rsync options (archive mode, compression, link preservation, no ownership/permission changes) and syncs `wp-content` from source to destination. Dry runs leverage `rsync --dry-run --itemize-changes`.
6. **Post Tasks**: Flushes the destination Object Cache Pro cache via `wp redis flush` when the command exists. Dry runs skip execution and log intent.
7. **Cleanup**: Disables maintenance mode (real runs only) and logs final status as well as the dump location or future import instructions when imports are skipped.

### Archive Mode
1. **Preflight**: Ensures the script runs from a WordPress root, verifies required binaries, confirms WordPress installation, validates the archive file exists.
2. **Format Detection**: Auto-detects archive format (Duplicator, Jetpack, etc.) by trying each adapter's validation function, or uses explicit `--archive-type` if provided.
3. **Dependency Check**: Verifies format-specific tools are available (e.g., `unzip` for Duplicator, `tar` for Jetpack).
4. **URL Capture**: Captures current destination site URLs (`home` and `siteurl` options) before any operations.
5. **Disk Space Check**: Validates that 3x the archive size is available (archive + extraction + buffer) and fails early if insufficient.
6. **Extraction**: Extracts the archive to a temporary directory using the appropriate adapter's extract function.
7. **Discovery**: Auto-detects the database file and wp-content directory using format-specific adapter functions with smart scoring based on presence of plugins/themes/uploads subdirectories.
8. **Maintenance Mode**: Activates maintenance mode on the destination during a real import. Dry runs only log what would happen.
9. **Backup Database**: Creates a timestamped gzipped backup of the current destination database in `db-backups/` before import.
10. **Backup wp-content**: Creates a timestamped backup of the current destination wp-content directory before replacement.
11. **Import Database**: Imports the database from the archive.
12. **Table Prefix Alignment**: Detects the table prefix from the imported database by verifying core WordPress tables (`options`, `posts`, `users`) exist with the same prefix. If the imported prefix differs from `wp-config.php`, automatically updates `wp-config.php` to match. Supports complex prefixes with underscores (e.g., `my_site_`, `wp_live_2024_`).
13. **URL Alignment**: Detects the imported site URLs, performs `wp search-replace` to align all URL references to the destination URLs (captured in step 4), and updates the `home`/`siteurl` options.
14. **Replace wp-content**: Removes the existing wp-content directory and replaces it completely with the wp-content from the archive (1:1 copy).
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
