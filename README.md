# wp-migrate.sh

`wp-migrate.sh` migrates WordPress sites in two modes:

1. **Push mode**: Pushes a WordPress site's `wp-content` directory and database export from a source server to a destination server via SSH.
2. **Duplicator mode**: Imports a Duplicator backup archive directly on the destination server without requiring SSH access to the source.

Both modes coordinate the entire workflow, including maintenance mode, database handling, file sync, and cache maintenance.

## Features

### Push Mode
- Verifies WordPress installations on both source and destination before proceeding.
- Enables maintenance mode on both sides during a real migration to minimise downtime (skip the source with `--no-maint-source`).
- Exports the database, transfers it to the destination, and imports it by default (disable with `--no-import-db`; gzipped dumps are decompressed automatically).
- Rewrites migrated URLs so the destination keeps its own domain via `wp search-replace` (skipped for dry runs or `--no-import-db`).
- Creates a timestamped backup of the destination `wp-content` directory before replacing it.
- Syncs the entire `wp-content` tree with rsync archive mode; files on the destination are overwritten and there are no built-in excludes.
- Optionally flushes the destination Object Cache Pro/Redis cache when `wp redis` is available.
- Supports a comprehensive dry-run mode that previews every step without mutating either server.

### Duplicator Mode
- Imports Duplicator WordPress backup archives without requiring SSH access to the source server.
- Automatically extracts and detects database and wp-content from Duplicator `.zip` archives with smart directory scoring.
- Pre-flight disk space validation ensures 3x archive size is available (archive + extraction + buffer).
- Creates timestamped backups of both the destination database and wp-content before any destructive operations.
- Automatically detects and aligns table prefix if the imported database uses a different prefix than the destination's `wp-config.php` (supports complex prefixes with underscores like `my_site_`, `wp_live_2024_`).
- Automatically detects imported site URLs and performs search-replace to align with the destination site URLs.
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

### Duplicator Mode
- WordPress CLI (`wp`)
- `unzip`
- `file`

Run the script from the WordPress root on the destination server (where `wp-config.php` lives). The Duplicator backup archive must be accessible on the filesystem.

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

### Duplicator Mode
```bash
./wp-migrate.sh --duplicator-archive /path/to/backup.zip [options]
```

Common examples:
- Import a Duplicator backup:
  ```bash
  ./wp-migrate.sh --duplicator-archive /backups/site_20251009.zip
  ```
- Preview import without making changes (dry run):
  ```bash
  ./wp-migrate.sh --duplicator-archive /backups/site_20251009.zip --dry-run
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

### Duplicator Mode Options
| Flag | Description |
| ---- | ----------- |
| `--duplicator-archive </path/to/backup.zip>` | **Required.** Path to the Duplicator backup archive file (mutually exclusive with `--dest-host`). |

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

### Duplicator Mode
1. **Preflight**: Ensures the script runs from a WordPress root, verifies required binaries, confirms WordPress installation, validates the Duplicator archive file exists and is a valid ZIP.
2. **URL Capture**: Captures current destination site URLs (`home` and `siteurl` options) before any operations.
3. **Disk Space Check**: Validates that 3x the archive size is available (archive + extraction + buffer) and fails early if insufficient.
4. **Extraction**: Extracts the Duplicator archive to a temporary directory.
5. **Discovery**: Auto-detects the database file (`dup-installer/dup-database__*.sql`) and wp-content directory using smart scoring based on presence of plugins/themes/uploads subdirectories.
6. **Maintenance Mode**: Activates maintenance mode on the destination during a real import. Dry runs only log what would happen.
7. **Backup Database**: Creates a timestamped gzipped backup of the current destination database in `db-backups/` before import.
8. **Backup wp-content**: Creates a timestamped backup of the current destination wp-content directory before replacement.
9. **Import Database**: Imports the database from the Duplicator archive.
10. **Table Prefix Alignment**: Detects the table prefix from the imported database by verifying core WordPress tables (`options`, `posts`, `users`) exist with the same prefix. If the imported prefix differs from `wp-config.php`, automatically updates `wp-config.php` to match. Supports complex prefixes with underscores (e.g., `my_site_`, `wp_live_2024_`).
11. **URL Alignment**: Detects the imported site URLs, performs `wp search-replace` to align all URL references to the destination URLs (captured in step 2), and updates the `home`/`siteurl` options.
12. **Replace wp-content**: Removes the existing wp-content directory and replaces it completely with the wp-content from the archive (1:1 copy).
13. **Post Tasks**: Flushes the Object Cache Pro cache via `wp redis flush` when available.
14. **Cleanup**: Disables maintenance mode and removes the temporary extraction directory on success (keeps it on failure for debugging).
15. **Rollback Instructions**: Logs detailed rollback commands showing how to restore both the database and wp-content backups if needed.

## Directories and Logging

### Push Mode
- Real runs create `logs/` with timestamped log files (`migrate-wpcontent-push-*.log`) and `db-dumps/` for exported databases.
- Dry runs do **not** create or modify directories; logging is routed to `/dev/null` to ensure a zero-impact preview.

### Duplicator Mode
- Real runs create `logs/` with timestamped log files (`migrate-duplicator-import-*.log`) and `db-backups/` for database backups before import.
- Timestamped wp-content backups are created alongside the original wp-content directory (e.g., `wp-content.backup-20251009-123456`).
- Temporary extraction directory is auto-created in `$TMPDIR` (typically `/tmp`) and removed on success.
- Dry runs do **not** create or modify directories; logging is routed to `/dev/null` to ensure a zero-impact preview.

## Safety Characteristics

### Push Mode
- A timestamped backup of the destination `wp-content` directory is created before files are overwritten.
- Rsync runs without `--delete`, so unmatched files on the destination remain in place, and remote ownership/permissions are untouched (`--no-perms --no-owner --no-group`).
- Maintenance commands run under `set -e`; if enabling or disabling maintenance fails the script aborts to prevent partial migrations.
- Cache flushing is attempted but non-blocking; failures are logged and the run continues.

### Duplicator Mode
- Both database and wp-content are backed up **before** any destructive operations occur.
- Database backup is created as a gzipped SQL dump in `db-backups/pre-duplicator-backup_<timestamp>.sql.gz`.
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

## License
No explicit licence is provided. Adapt as needed for your environment.
