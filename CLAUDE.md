# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

`wp-migrate.sh` is a WordPress migration and backup tool that operates in three modes:
1. **Push Mode**: Migrates WordPress sites between servers via SSH
2. **Archive Mode**: Imports backup archives (Duplicator, Jetpack Backup, Solid Backups)
3. **Backup Mode**: Creates portable WordPress backups locally or remotely

Current version: 2.10.0

## Critical Build Workflow

**NEVER edit `wp-migrate.sh` directly.** The repo root script is a built artifact.

### Source Code Structure

```
src/
├── header.sh              # Shebang, version, defaults
├── lib/
│   ├── core.sh           # Core utilities (err, log, validate_url)
│   ├── functions.sh      # Main functionality
│   └── adapters/         # Archive format handlers
│       ├── base.sh       # Shared adapter utilities
│       ├── wpmigrate.sh  # Native backup format
│       ├── duplicator.sh
│       ├── jetpack.sh
│       ├── solidbackups.sh
│       └── solidbackups_nextgen.sh
└── main.sh               # Argument parser, main()
```

### Making Code Changes

1. Modify files in `src/` directory (NOT `wp-migrate.sh`)
2. Build the single-file script:
   ```bash
   make build
   ```
3. This concatenates source files into `dist/wp-migrate.sh`, copies to repo root, and generates SHA256 checksum
4. Commit both source files AND the built `wp-migrate.sh` together

### Pre-commit Hook

Install to prevent committing source changes without rebuilding:
```bash
ln -s ../../.githooks/pre-commit .git/hooks/pre-commit
```

## Common Development Tasks

### Testing

```bash
# Run all tests (includes shellcheck validation)
make test

# Build script
make build

# Clean build artifacts
make clean

# Shellcheck only (validates concatenated script)
shellcheck wp-migrate.sh
```

### Running the Script

**Push mode:**
```bash
./wp-migrate.sh --dest-host user@dest.example.com --dest-root /var/www/site
```

**Archive mode:**
```bash
./wp-migrate.sh --archive /path/to/backup.zip
./wp-migrate.sh --archive /path/to/backup.tar.gz --archive-type jetpack
```

**Backup creation:**
```bash
# Local
./wp-migrate.sh --create-backup

# Remote
./wp-migrate.sh --source-host user@source.example.com --source-root /var/www/html --create-backup
```

**Rollback:**
```bash
./wp-migrate.sh --rollback
```

**Always use dry-run for testing:**
```bash
./wp-migrate.sh --archive /path/to/backup.zip --dry-run --verbose
```

## Architecture Overview

### Modular Build System

The script is built from modular source files to improve maintainability. The Makefile:
1. Runs shellcheck on the concatenated script (not individual modules to avoid false positives)
2. Concatenates source files in order: header → core → adapters → functions → main
3. Makes executable and copies to repo root
4. Generates SHA256 checksum for distribution

### Archive Adapter System

Extensible architecture for supporting multiple backup formats. Each adapter implements:
- `adapter_NAME_validate()` - Check if archive matches format
- `adapter_NAME_extract()` - Extract archive to temp directory
- `adapter_NAME_find_database()` - Locate SQL file(s)
- `adapter_NAME_find_content()` - Locate wp-content directory
- `adapter_NAME_get_name()` - Human-readable format name
- `adapter_NAME_get_dependencies()` - Required system commands

Detection order: wpmigrate → duplicator → jetpack → solidbackups → solidbackups_nextgen

See `src/lib/adapters/README.md` for adapter development guide.

### Key Safety Features

**Security Protections (v2.10.0):**
- **Zip Slip Protection** - All archive extraction validates paths to prevent malicious archives from writing outside extraction directory (CVE protection)
- **SQL Injection Prevention** - Table names validated before DROP TABLE operations, only WordPress-pattern names allowed
- **Emergency Database Snapshot** - Automatic snapshot before database reset with auto-rollback on import failure
- **Multi-WordPress Detection** - Detects ambiguous migrations when multiple WordPress share a database, requires user confirmation
- **Backup Verification** - Validates backup existence, size, and non-emptiness before destructive operations
- **Dry-run Safety** - All file operations check `$DRY_RUN` flag, ensuring zero-impact previews

**WP-CLI Error Recovery (v2.9.0):**
- All WP-CLI commands use `--skip-plugins --skip-themes` automatically
- Prevents plugin/theme errors from breaking migrations or rollbacks
- Safe for all operations (script uses only low-level database/filesystem commands)
- Consistent behavior between local and remote WP-CLI operations

**Push mode:**
- Creates timestamped backup of destination wp-content before replacement
- Enables maintenance mode on both servers during migration
- rsync runs without `--delete` to preserve unmatched destination files
- No permission/ownership changes on destination (`--no-perms --no-owner --no-group`)
- Excludes `object-cache.php` to preserve destination caching infrastructure

**Archive mode:**
- Validates disk space (requires 3x archive size)
- Creates backups of both database and wp-content before any destructive operations
- Auto-detects and aligns table prefix if different from wp-config.php
- Provides rollback instructions with exact commands to restore backups
- Temporary extraction directory preserved on failure for debugging

### Migration Flow

**Push mode:**
1. Preflight validation (WordPress, binaries, SSH connectivity)
2. Enable maintenance mode (both servers)
3. Export source DB, transfer, import (with URL search-replace)
4. Backup destination wp-content, sync via rsync
5. Flush Object Cache Pro if available
6. Disable maintenance mode

**Archive mode:**
1. Preflight validation (WordPress, binaries, archive exists)
2. Auto-detect format via adapter validation functions
3. Disk space check (3x archive size)
4. Extract to temporary directory
5. Enable maintenance mode
6. Backup destination database and wp-content
7. Import database with table prefix alignment
8. URL search-replace to align with destination
9. Replace wp-content (excludes object-cache.php)
10. Flush cache, disable maintenance, cleanup temp directory

## Git Workflow

### Branching Strategy

Start from `main` branch:
- `feature/<slug>` - New functionality
- `fix/<slug>` - Bug fixes
- `docs/<slug>` - Documentation changes
- `chore/<slug>` - Maintenance tasks

### Commit Message Format

Configure template once per clone:
```bash
git config commit.template .gitmessage
```

Format: `type: short imperative summary`

Types: `feat`, `fix`, `docs`, `chore`, `refactor`, `test`

Examples:
```
feat: add WP-CLI skip flags for error recovery
fix: prevent Zip Slip path traversal vulnerability
docs: update archive adapter development guide
```

### Pull Request Checklist

1. Review ALL commits in branch: `git log main..HEAD` and `git diff main...HEAD`
2. Update `CHANGELOG.md` under `[Unreleased]` section
3. Write comprehensive PR summary covering complete scope (not just latest commit)
4. Include test plan with verification steps
5. Ensure shellcheck passes: `make test`
6. Test both dry-run and real execution
7. Use `.github/pull_request_template.md` checklist

### Merging and Releases

- Merge with `git merge --no-ff` or squash after review
- Keep `main` release-ready
- Delete feature branches after merge
- Tag releases with semantic versioning: `git tag v2.9.0`

## Important Code Patterns

### Verbosity and Logging

- `log()` - Standard output (respects `--quiet` flag)
- `err()` - Error messages that exit with status 1
- `VERBOSE` flag - Set by `--verbose`, enables diagnostic output
- `TRACE_MODE` flag - Set by `--trace`, shows every command before execution

### Maintenance Mode

Always runs under `set -e` - if enabling/disabling fails, script aborts to prevent partial migrations.

### URL Handling

- `validate_url()` - Ensures URLs are well-formed
- Auto-detects destination URLs via WP-CLI
- Supports override with `--dest-domain`, `--dest-home-url`, `--dest-site-url`
- Search-replace updates all URL references (skip bulk with `--no-search-replace`)

### Plugin/Theme Preservation

- `--preserve-dest-plugins` - Restores unique destination plugins/themes from backup
- `--stellarsites` - Managed hosting mode (enables preservation + excludes mu-plugins/)
- **WordPress Drop-in Filtering (v2.8.3)** - Automatically filters drop-ins (advanced-cache.php, db.php, db-error.php) from plugin preservation to prevent false restoration warnings
- **Managed Plugin Filtering (v2.8.3)** - In `--stellarsites` mode, filters managed hosting plugins (e.g., stellarsites-cloud) from preservation

## Special Considerations

### Managed Hosting (StellarSites)

Use `--stellarsites` flag to:
- Automatically enable `--preserve-dest-plugins`
- Exclude `mu-plugins/` directory and `mu-plugins.php` loader from sync
- Prevents conflicts with host-provided system plugins

### WP-CLI Skip Flags

**Automatic error recovery feature (v2.9.0)** - All WP-CLI commands use skip flags:
- `wp_local()` and `wp_remote()` both use `--skip-plugins --skip-themes` automatically
- **Why it's safe:** The script only uses low-level WP-CLI commands (database queries, option updates, filesystem operations) that don't require plugin/theme code to function
- **What it prevents:** Plugin or theme errors that would otherwise break migrations, imports, or rollbacks
- **When it helps:** Migrations succeed even if destination has problematic plugins; rollbacks work even if migration introduced broken code
- **Transparency:** Added NOTES section to help text explaining this behavior

Note: There's also `wp_local_full()` function for specific operations that DO need plugins loaded (e.g., Object Cache Pro redis flush via `wp redis` command provided by plugin)

### Table Prefix Alignment

Archive mode auto-detects imported table prefix by verifying core WordPress tables (options, posts, users) exist with same prefix. If different from `wp-config.php`, automatically updates config. Supports complex prefixes with underscores (e.g., `my_site_`, `wp_live_2024_`).

## Common File Locations

- `wp-migrate.sh` - Built script (DO NOT EDIT DIRECTLY)
- `src/` - Source files (EDIT THESE)
- `Makefile` - Build system
- `CHANGELOG.md` - Version history (update with every PR)
- `README.md` - User documentation
- `.githooks/pre-commit` - Validates source/build sync
- `tests/` - Test suite and fixtures

## Development Best Practices

1. **Always start with TodoWrite** for multi-step tasks to track progress
2. **Test with --dry-run --verbose** before real migrations
3. **Run `make test`** before every commit (includes shellcheck)
4. **Update CHANGELOG.md** for all features and fixes
5. **Commit source AND built files together** in same commit
6. **Review ALL branch commits** when creating PRs (not just latest)
7. **Use focused PRs** addressing single concerns
8. **Test rollback procedures** in safe environments
9. **Check logs/** directory after migrations for diagnostics

## Shellcheck Requirements

All code must be shellcheck-clean before merging. Common patterns:
- Quote all variable expansions: `"$variable"`
- Use `[[ ]]` for tests, not `[ ]`
- Explicit variable declarations for clarity
- Proper error handling with `|| return 1`

## Documentation Files

When implementation plans exist in `docs/plans/`, they provide context for recent features. Check these for understanding design decisions and implementation details.
