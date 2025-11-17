# Test Fixtures

This directory contains minimal test archives for integration testing of wp-migrate.sh's archive format detection.

## Overview

Each test archive is a **minimal** valid archive that contains just enough structure to satisfy the format detection logic for its respective backup plugin adapter.

**⚠️ These are NOT real backups** - they contain stub data only and cannot be used for actual WordPress migrations.

## Test Archives

### 1. duplicator-minimal.zip (1.9 KB)

**Format**: Duplicator Pro/Lite
**Type**: ZIP archive
**Contents**:
- `installer.php` - Signature file for Duplicator format detection
- `dup-installer/dup-database__test123.sql` - Minimal SQL stub with wp_options table
- `wp-content/` - Minimal directory structure

**Detection**: Validated by presence of `installer.php` or `dup-installer/dup-database__*.sql` pattern

### 2. jetpack-minimal.tar.gz (1.1 KB)

**Format**: Jetpack Backup
**Type**: TAR.GZ archive
**Contents**:
- `meta.json` - Jetpack metadata file (required signature)
- `sql/wp_options.sql` - Database file in Jetpack multi-file format
- `wp-content/` - Minimal directory structure

**Detection**: Validated by presence of both `meta.json` AND `sql/wp_options.sql`

### 3. solidbackups-minimal.zip (2.0 KB)

**Format**: Solid Backups (formerly BackupBuddy)
**Type**: ZIP archive
**Contents**:
- `wp-content/uploads/backupbuddy_temp/test123abc/importbuddy.php` - Signature file
- `wp-content/uploads/backupbuddy_temp/test123abc/wp_options.sql` - Database file
- `wp-content/plugins/` - Minimal directory structure

**Detection**: Validated by presence of `importbuddy.php` or `backupbuddy_dat.php` in `backupbuddy_temp/`

## Usage in Tests

These fixtures are used by integration tests in `../integration/`:

```bash
# Archive format detection test
./tests/integration/test-archive-detection.sh

# Tests that each archive is correctly identified by its adapter:
# - Duplicator adapter recognizes duplicator-minimal.zip
# - Jetpack adapter recognizes jetpack-minimal.tar.gz
# - Solid Backups adapter recognizes solidbackups-minimal.zip
# - All adapters reject invalid archives
```

## Creating New Test Fixtures

If you need to create additional test fixtures:

1. **Study the adapter requirements** in `src/lib/adapters/<format>.sh`
2. **Create minimum viable structure** that satisfies validation
3. **Keep file size small** (< 5 KB preferred)
4. **Include stub SQL** with at minimum:
   - `wp_options` table definition
   - `siteurl` and `home` option rows
5. **Test validation** using `./wp-migrate.sh --archive <file> --verbose`

### Example: Creating a Duplicator test fixture

```bash
mkdir -p test/dup-installer
echo "<?php // Stub" > test/installer.php
echo "CREATE TABLE wp_options (option_name varchar(191));" > test/dup-installer/dup-database__test.sql
cd test && zip -r duplicator-test.zip . && cd ..
```

## Missing Fixtures

The following adapters do not yet have test fixtures:

- **wp-migrate native format** (v2.8.0+) - Should include `wpmigrate-backup.json`, `database.sql`, and `wp-content/`
- **Solid Backups NextGen** (v2.7.0+) - Should include `data/` directory with SQL files and `files/` directory

These should be added to provide complete test coverage for all 5 supported formats.

## Updating Test Fixtures

Test fixtures should be regenerated when:

1. **Adapter validation logic changes significantly** - If validation functions add new requirements
2. **New required signature files are added** - If formats add mandatory metadata files
3. **Format specifications change** - If backup plugins change their archive structure
4. **Security fixes affect extraction** - After v2.10.0 Zip Slip protection, verify paths are clean

### Regeneration Procedure

1. Study current adapter requirements in `src/lib/adapters/<format>.sh`
2. Create minimal structure satisfying validation (see "Creating New Test Fixtures" above)
3. Test with: `./wp-migrate.sh --archive <file> --dry-run --verbose`
4. Verify format detection works: `./tests/integration/test-archive-detection.sh`
5. Update "Current versions created" date below

Current versions created: 2025-11-17

## See Also

- `src/lib/adapters/README.md` - Adapter architecture documentation
- `tests/integration/` - Integration test scripts
- `.github/workflows/test.yml` - CI/CD pipeline that runs these tests
