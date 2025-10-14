# v2.0.0 - Modular Architecture + Extensible Archive Adapters

**Release Date:** 2025-10-14

This release represents a **major internal refactor** with minimal user-facing changes. The codebase has been restructured with a modular source layout and build system, making future development and contributions significantly easier. The archive import feature (formerly "Duplicator mode") has been redesigned with an extensible adapter architecture to support multiple backup formats.

## Impact Summary

- **User Impact:** Minimal - The `--duplicator-archive` flag still works (deprecated). Users continue downloading a single `wp-migrate.sh` file as before.
- **Developer Impact:** Significant - Source code is now modular. Contributors must work with `src/` files and use `make build` to generate the single-file artifact.

---

## What's New

### Archive Adapter System

The biggest change is the new extensible adapter architecture for WordPress backup formats:

- **Modular Format Support**: Each backup plugin format is handled by its own adapter module in `src/lib/adapters/`
- **Auto-Detection**: Automatically detects archive formats (currently Duplicator; designed for Jetpack, UpdraftPlus, BackWPup, etc.)
- **Manual Override**: New `--archive-type` flag for explicit format specification
- **Easy Contribution**: Add new formats by creating a single adapter file (~100 lines) without modifying core code
- **Comprehensive Guide**: See [src/lib/adapters/README.md](https://github.com/BWBama85/wp-migrate.sh/blob/main/src/lib/adapters/README.md) for contributor documentation

### New Flags

- **`--archive <path>`**: Replaces `--duplicator-archive` as the primary archive import flag. Supports any backup format via the adapter system.
  ```bash
  ./wp-migrate.sh --archive /backups/site.zip
  ./wp-migrate.sh --archive /backups/site.zip --archive-type duplicator
  ```

### Modular Source Code (Developers)

The codebase is now organized in a modular structure:

```
src/
├── header.sh                # Shebang, defaults, variable declarations
├── lib/
│   ├── core.sh              # Core utilities (log, err, validate_url)
│   ├── adapters/            # Archive format adapters
│   │   ├── base.sh          # Shared adapter helper functions
│   │   ├── duplicator.sh    # Duplicator adapter implementation
│   │   └── README.md        # Contributor guide
│   └── functions.sh         # All other functions
└── main.sh                  # Argument parsing and execution
```

**Developer Workflow:**
1. Edit files in `src/` (not `wp-migrate.sh` directly)
2. Run `make build` to regenerate `wp-migrate.sh`
3. Run `make test` to verify ShellCheck passes
4. Commit both source files and built file

**Makefile Targets:**
- `make build` - Build the single-file script from modular source
- `make test` - Run shellcheck on the complete built script
- `make clean` - Remove build artifacts
- `make help` - Show available targets

---

## Breaking Changes

### For End Users
**None.** The user-facing interface remains compatible with v1.x. The `--duplicator-archive` flag is deprecated but still functional.

### For Developers
- **MUST** work in `src/` files, not `wp-migrate.sh` directly
- **MUST** run `make build` after any `src/` changes
- **MUST** commit both source files and built file
- **Internal variable names changed** (e.g., `DUPLICATOR_ARCHIVE` → `ARCHIVE_FILE`)
- **Internal function names changed** (e.g., `extract_duplicator_archive()` → `extract_archive_to_temp()`)

---

## Upgrade Guide

### For End Users

**No action required.** Download the new version and use it exactly as before:

```bash
# Download v2.0.0
curl -O https://raw.githubusercontent.com/BWBama85/wp-migrate.sh/main/wp-migrate.sh

# Verify checksum
curl -O https://raw.githubusercontent.com/BWBama85/wp-migrate.sh/main/wp-migrate.sh.sha256
shasum -c wp-migrate.sh.sha256

# Use as normal (all v1.x commands still work)
./wp-migrate.sh --dest-host user@dest --dest-root /var/www/site
./wp-migrate.sh --duplicator-archive /backups/site.zip  # Still works!
```

**Optional:** Start using the new `--archive` flag instead of `--duplicator-archive`:

```bash
# New style (recommended)
./wp-migrate.sh --archive /backups/site.zip

# Old style (deprecated but functional)
./wp-migrate.sh --duplicator-archive /backups/site.zip
```

### For Contributors

If you've contributed to v1.x, here's what changed:

1. **Clone and setup:**
   ```bash
   git clone https://github.com/BWBama85/wp-migrate.sh.git
   cd wp-migrate.sh
   git checkout main

   # Install pre-commit hook (recommended)
   ln -s ../../.githooks/pre-commit .git/hooks/pre-commit
   ```

2. **Edit source files in `src/`, not `wp-migrate.sh`:**
   ```bash
   # Edit modular source
   vim src/lib/functions.sh

   # Build single-file script
   make build

   # Test with shellcheck
   make test

   # Commit both source and built files
   git add src/lib/functions.sh wp-migrate.sh wp-migrate.sh.sha256
   git commit -m "fix: improve error handling"
   ```

3. **Branch from main, PR to main:**
   ```bash
   git checkout -b fix/my-bugfix
   # Make changes in src/
   make build && make test
   git add -A && git commit -m "fix: description"
   git push origin fix/my-bugfix
   # Open PR to main
   ```

---

## Detailed Changes

### Added
- **Archive Adapter System**: Implemented extensible adapter architecture for supporting multiple WordPress backup formats. Currently ships with Duplicator adapter only; designed to support Jetpack, UpdraftPlus, BackWPup, and other formats in future releases. Each backup plugin format is handled by its own adapter module in `src/lib/adapters/`. Includes auto-detection of archive formats and manual override via `--archive-type` flag. Contributors can add new formats by creating a single adapter file without modifying core code (see `src/lib/adapters/README.md` for guide).
- **New `--archive` flag**: Replaces `--duplicator-archive` as the primary archive import flag. Supports any backup format via the adapter system. Example: `--archive /path/to/backup.zip` with optional `--archive-type duplicator` for explicit format specification.
- **Adapter contributor documentation**: Created comprehensive `src/lib/adapters/README.md` guide for adding new backup format support. Includes adapter interface specification, implementation examples, testing checklist, and common pitfalls to avoid.
- **Duplicator adapter**: Moved all Duplicator-specific logic into `src/lib/adapters/duplicator.sh` as the first adapter implementation. Serves as reference implementation for future adapters.
- **Base adapter helpers**: Created `src/lib/adapters/base.sh` with shared functions for archive detection, wp-content scoring, and format identification that all adapters can use.
- **Modular source structure**: Organized codebase into `src/` directory (header.sh, lib/core.sh, lib/adapters/, lib/functions.sh, main.sh) for easier maintenance and code review.
- **Makefile build system**: Added targets: `make build` (concatenate source files), `make test` (run shellcheck), `make clean` (remove build artifacts). Developers work in modular `src/` files and run `make build` to update the single-file `wp-migrate.sh` at repo root.
- **Pre-commit git hook**: Added `.githooks/pre-commit` that prevents committing source changes without rebuilding `wp-migrate.sh` and `wp-migrate.sh.sha256`. Install with `ln -s ../../.githooks/pre-commit .git/hooks/pre-commit`.

### Changed
- **Renamed "Duplicator mode" to "archive mode"** throughout codebase. Migration mode is now detected as `MIGRATION_MODE="archive"` instead of `"duplicator"`. Log files now named `migrate-archive-import-*.log` instead of `migrate-duplicator-import-*.log`.
- **Internal variable names changed**: `DUPLICATOR_ARCHIVE` → `ARCHIVE_FILE`, `DUPLICATOR_EXTRACT_DIR` → `ARCHIVE_EXTRACT_DIR`, `DUPLICATOR_DB_FILE` → `ARCHIVE_DB_FILE`, `DUPLICATOR_WP_CONTENT` → `ARCHIVE_WP_CONTENT`. User-facing `--duplicator-archive` flag maintained for backward compatibility.
- **Internal function names changed**: `check_disk_space_for_duplicator()` → `check_disk_space_for_archive()`, `extract_duplicator_archive()` → `extract_archive_to_temp()`, `find_duplicator_database()` → `find_archive_database_file()`, `find_duplicator_wp_content()` → `find_archive_wp_content_dir()`, `cleanup_duplicator_temp()` → `cleanup_archive_temp()`.
- **Updated Makefile** to include `src/lib/adapters/*.sh` files in build concatenation order. Build order: header → core → adapters (base, duplicator, ...) → functions → main.
- **Updated help text** to reflect archive mode terminology and new `--archive` flag. Added examples for explicit format specification with `--archive-type`.
- **Expanded README Development section** with detailed instructions for building from source, git hook setup, Makefile targets, and contribution guidelines for v2+ development.

### Deprecated
- `--duplicator-archive` flag deprecated in favor of `--archive`. Backward compatibility maintained - the old flag still works and is internally converted to `--archive --archive-type=duplicator`. Will be removed in v3.0.0.

### Fixed
- **HIGH**: Fixed preserve-dest-plugins broken in archive mode. After merge of preservation feature, code still referenced old variable name `DUPLICATOR_WP_CONTENT` instead of renamed `ARCHIVE_WP_CONTENT`. With `set -u` enabled, this caused immediate script abortion when using `--stellarsites` or `--preserve-dest-plugins` flags in archive mode.
- **CRITICAL**: Fixed archive mode completely broken in single-file build. Removed dynamic `source` calls that tried to load adapter files at runtime (files don't exist in built artifact). The Makefile already concatenates all adapter code into the single `wp-migrate.sh` file, so these source calls were unnecessary and caused "No such file or directory" errors.
- **HIGH**: Fixed cryptic "command not found" errors during adapter detection. Moved dependency checks before adapter detection logic. Previously, missing tools caused script to terminate with bare "command not found" before reaching the friendly "missing dependency" error. Now checks for `file` and `unzip` before attempting detection, providing clear installation instructions if missing.
- **HIGH**: Fixed `set -e` causing silent exits with corrupt archives. Wrapped adapter function calls in `if !` blocks to capture non-zero exit status before `set -e` kills the script. Now properly displays user-friendly error explaining what went wrong.
- **HIGH**: Fixed uncompressed TAR archives failing validation. Now uses appropriate flags based on archive type: `tar -tf` for uncompressed `.tar`, `tar -tzf` for `.tar.gz`. Enables future adapters supporting plain TAR backups.
- **MEDIUM**: Updated README.md and CHANGELOG.md to accurately reflect currently supported formats. Changed documentation from promising "Duplicator, Jetpack, UpdraftPlus, etc." to stating "currently Duplicator only; designed to support additional formats in future releases." Prevents user confusion and "Unknown archive type" errors.
- Made table prefix update failures fatal to prevent silent migration failures. If both `wp config set` and sed fallback fail to update the table prefix in wp-config.php, the script now aborts with a clear error message instead of continuing with a broken configuration.
- Enhanced archive mode prefix detection fallback logic. When table prefix detection fails, the script now verifies that the assumed prefix is correct by querying the options table before continuing. Prevents silent failures where the script continues with an incorrect prefix assumption.

---

## Download

Download the script:
```bash
curl -O https://raw.githubusercontent.com/BWBama85/wp-migrate.sh/main/wp-migrate.sh
```

Verify the checksum:
```bash
curl -O https://raw.githubusercontent.com/BWBama85/wp-migrate.sh/main/wp-migrate.sh.sha256
shasum -c wp-migrate.sh.sha256
```

## Documentation

- **README**: [README.md](https://github.com/BWBama85/wp-migrate.sh/blob/main/README.md)
- **Changelog**: [CHANGELOG.md](https://github.com/BWBama85/wp-migrate.sh/blob/main/CHANGELOG.md)
- **Adapter Guide**: [src/lib/adapters/README.md](https://github.com/BWBama85/wp-migrate.sh/blob/main/src/lib/adapters/README.md)

## Contributing

Contributions welcome! See the [Contributing](https://github.com/BWBama85/wp-migrate.sh#contributing) section in README.md for:
- General contribution workflow
- Adding new archive adapters (Jetpack, UpdraftPlus, etc.)
- Build system usage

---

## What's Next?

With the adapter system in place, we're looking to add support for additional WordPress backup formats:

- **Jetpack Backup** (TAR format)
- **UpdraftPlus** (multiple files)
- **BackWPup** (archive format)
- **All-in-One WP Migration** (wpress format)

Contributors can add new formats by following the guide in [src/lib/adapters/README.md](https://github.com/BWBama85/wp-migrate.sh/blob/main/src/lib/adapters/README.md). Adding a new format is typically ~100 lines of code in a single file.

---

**Full Changelog**: [v1.1.8...v2.0.0](https://github.com/BWBama85/wp-migrate.sh/compare/v1.1.8...v2.0.0)
