# wp-migrate.sh

`wp-migrate.sh` pushes a WordPress site's `wp-content` directory and database export from a source server to a destination server. It is designed to be run from the WordPress root on the source host and coordinates the entire workflow, including maintenance mode, database handling, file sync, and cache clearing.

## Features
- Verifies WordPress installations on both source and destination before proceeding.
- Enables maintenance mode on both sides during a real migration to minimise downtime.
- Exports the database, transfers it to the destination, and imports it by default (disable with `--no-import-db`; gzipped dumps are decompressed automatically).
- Syncs `wp-content` with `rsync --ignore-existing` while skipping common cache directories.
- Optionally clears popular caches (Object Cache Pro, Redis, WP Rocket, LiteSpeed Cache, etc.) on the destination.
- Supports a comprehensive dry-run mode that previews every step without mutating either server.

## Requirements
- WordPress CLI (`wp`)
- `rsync`
- `ssh`
- `gzip` (also required on the destination when importing compressed dumps)

Run the script from the WordPress root on the source server (where `wp-config.php` lives). The destination host must be reachable over SSH and capable of running `wp` commands.

## Usage
```bash
./wp-migrate.sh --dest-host user@dest.example.com --dest-root /var/www/site [options]
```

Common examples:
- Real migration with default behaviour:
  ```bash
  ./wp-migrate.sh --dest-host wp@dest --dest-root /var/www/site
  ```
- Dry run with an additional rsync exclude:
  ```bash
  ./wp-migrate.sh --dest-host wp@dest --dest-root /var/www/site \
    --dry-run --extra-exclude 'uploads/large-folders/'
  ```
- Migrate but skip importing the database on the destination:
  ```bash
  ./wp-migrate.sh --dest-host wp@dest --dest-root /var/www/site --no-import-db
  ```

## Options
| Flag | Description |
| ---- | ----------- |
| `--dry-run` | Preview the workflow. No files are created, maintenance mode is not toggled, and caches are left untouched. Rsync runs with `--dry-run` and database work is described rather than executed. |
| `--import-db` | (Deprecated) Explicitly request a destination DB import; the script already imports by default. |
| `--no-import-db` | Skip importing the transferred SQL dump on the destination (manually import later; decompress first if the file ends in `.gz`). |
| `--no-gzip` | Skip gzipping the database dump before transfer. |
| `--no-maint-source` | Leave the source site out of maintenance mode during the migration. |
| `--no-cache-clear` | Disable automatic cache clearing on the destination. |
| `--no-transients` | Skip deleting transients on the destination. |
| `--rsync-opt <opt>` | Append an additional rsync option (can be passed multiple times). |
| `--extra-exclude <pattern>` | Add extra rsync exclude patterns (repeat as needed). |
| `--ssh-opt <opt>` | Append an extra SSH option (repeatable; options are safely quoted). |
| `--help` | Print usage information and exit. |

## Workflow Overview
1. **Preflight**: Ensures the script runs from a WordPress root, verifies the presence of required binaries, and confirms both WP installations.
2. **Discovery**: Determines source and destination `wp-content` paths and logs disk usage details.
3. **Maintenance Mode**: Activates maintenance on both sides during a real migration (`wp maintenance-mode activate`). Dry runs only log what would happen.
4. **Database Step**:
   - Real run: Exports the source DB (optionally gzipped), stores it in `db-dumps/`, creates the destination `db-imports` directory, transfers the dump, and imports it by default (gzipped files are expanded on the destination first; use `--no-import-db` to skip).
   - Dry run: Logs the planned export, transfer, and import without creating `db-dumps/` or touching the destination.
5. **File Sync**: Builds rsync options (including `--ignore-existing`, `--links`, and default cache excludes) and syncs `wp-content` from source to destination. Dry runs leverage `rsync --dry-run --itemize-changes`.
6. **Post Tasks**: Optionally clears caches on the destination using `wp` CLI commands. Dry runs skip execution and log intent.
7. **Cleanup**: Disables maintenance mode (real runs only) and logs final status as well as the dump location or future import instructions when imports are skipped.

## Directories and Logging
- Real runs create `logs/` with timestamped log files and `db-dumps/` for exported databases.
- Dry runs do **not** create or modify directories; logging is routed to `/dev/null` to ensure a zero-impact preview.

## Safety Characteristics
- Rsync never deletes remote files (`--ignore-existing` with no `--delete`).
- Ownership and permissions are left untouched (`--no-perms --no-owner --no-group`).
- Maintenance mode calls are best-effort and swallowed on failure to avoid aborting the migration.
- Cache clearing is attempted but non-blocking; failures simply log and continue.

## Troubleshooting
- Ensure `wp` runs correctly on both hosts; authentication or environment issues will surface during the verification step.
- Supply additional SSH options with repeated `--ssh-opt` flags (e.g., alternate ports or identities).
- Install [ShellCheck](https://www.shellcheck.net/) to lint modifications; the current script is ShellCheck-clean.

## License
No explicit licence is provided. Adapt as needed for your environment.
