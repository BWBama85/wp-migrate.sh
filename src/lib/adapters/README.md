# Archive Adapter Development Guide

This directory contains archive format adapters for `wp-migrate.sh`. Each adapter handles a specific backup plugin's archive format (Duplicator, Jetpack, UpdraftPlus, etc.).

## Adapter Interface

Every adapter must implement these five functions:

### 1. `adapter_NAME_validate <archive_path>`

**Purpose:** Validate if the archive matches this adapter's format.

**Returns:**
- `0` if the archive is compatible with this adapter
- `1` if the archive is not compatible

**Example:**
```bash
adapter_duplicator_validate() {
  local archive="$1"

  # Check file exists
  [[ -f "$archive" ]] || return 1

  # Check file type
  local archive_type
  archive_type=$(adapter_base_get_archive_type "$archive")
  [[ "$archive_type" == "zip" ]] || return 1

  # Check for signature files
  if adapter_base_archive_contains "$archive" "installer.php"; then
    return 0
  fi

  return 1
}
```

### 2. `adapter_NAME_extract <archive_path> <dest_dir>`

**Purpose:** Extract the archive to the destination directory.

**Returns:**
- `0` on successful extraction
- `1` on failure

**Example:**
```bash
adapter_duplicator_extract() {
  local archive="$1" dest="$2"

  if ! unzip -q "$archive" -d "$dest" 2>/dev/null; then
    return 1
  fi

  return 0
}
```

### 3. `adapter_NAME_find_database <extract_dir>`

**Purpose:** Locate the database SQL file within the extracted archive.

**Returns:**
- `0` and **echoes the full path** to the database file if found
- `1` if not found

**Example:**
```bash
adapter_duplicator_find_database() {
  local extract_dir="$1"
  local db_file

  db_file=$(find "$extract_dir" -type f -path "*/dup-installer/dup-database__*.sql" 2>/dev/null | head -1)

  if [[ -z "$db_file" ]]; then
    return 1
  fi

  echo "$db_file"
  return 0
}
```

### 4. `adapter_NAME_find_content <extract_dir>`

**Purpose:** Locate the wp-content directory within the extracted archive.

**Returns:**
- `0` and **echoes the full path** to the wp-content directory if found
- `1` if not found

**Example:**
```bash
adapter_duplicator_find_content() {
  local extract_dir="$1"
  local wp_content_dir

  # Use base helper for smart directory scoring
  wp_content_dir=$(adapter_base_find_best_wp_content "$extract_dir")

  if [[ -z "$wp_content_dir" ]]; then
    return 1
  fi

  echo "$wp_content_dir"
  return 0
}
```

### 5. `adapter_NAME_get_name`

**Purpose:** Return a human-readable name for this format.

**Returns:** Echoes the format name (used in log messages)

**Example:**
```bash
adapter_duplicator_get_name() {
  echo "Duplicator"
}
```

### 6. `adapter_NAME_get_dependencies` (Optional)

**Purpose:** List required system commands for this adapter.

**Returns:** Space-separated list of required commands

**Example:**
```bash
adapter_duplicator_get_dependencies() {
  echo "unzip file"
}
```

## Base Helper Functions

Use these shared functions from `base.sh` in your adapter:

### `adapter_base_get_archive_type <archive_path>`
Returns: `"zip"`, `"tar"`, `"tar.gz"`, or `"unknown"`

### `adapter_base_archive_contains <archive_path> <pattern>`
Returns: `0` if pattern found in archive listing, `1` otherwise

### `adapter_base_find_best_wp_content <extract_dir>`
Returns: Path to best wp-content directory (scores by presence of plugins/themes/uploads)

### `adapter_base_score_wp_content <dir>`
Returns: Score (0-3) based on WordPress subdirectories present

## Creating a New Adapter

### Step 1: Create the adapter file

Create `src/lib/adapters/PLUGIN_NAME.sh` (use lowercase, no spaces):

```bash
# Example: src/lib/adapters/jetpack.sh
```

### Step 2: Implement all required functions

Copy the template structure from `duplicator.sh` and modify for your format.

### Step 3: Research the archive format

Before implementing, understand:
- **Archive format:** ZIP, TAR, TAR.GZ, or other?
- **Database location:** Where is the `.sql` file? What naming pattern?
- **wp-content location:** Is it at the root? In a subdirectory?
- **Signature files:** Any unique files that identify this format?
- **Directory structure:** Does it preserve WordPress structure?

### Step 4: Test your adapter

Create a test archive and verify:
```bash
# Dry-run test
./wp-migrate.sh --archive /path/to/test-archive.zip --archive-type YOUR_ADAPTER --dry-run

# Real test (on test site)
./wp-migrate.sh --archive /path/to/test-archive.zip --archive-type YOUR_ADAPTER
```

### Step 5: Submit a pull request

- Add your adapter file to `src/lib/adapters/`
- Update the Makefile if needed (build system auto-includes all .sh files)
- Run `make build` to regenerate `wp-migrate.sh`
- Test the built script
- Submit PR with description of supported format

## Archive Format Examples

### Duplicator
- **Format:** ZIP
- **Database:** `dup-installer/dup-database__[hash].sql`
- **wp-content:** Auto-detected via scoring
- **Signature:** `installer.php`

### Jetpack VaultPress (Example)
- **Format:** TAR (uncompressed)
- **Database:** `*.sql` at root level
- **wp-content:** Subdirectories: `plugins/`, `themes/`, `uploads/`
- **Signature:** Specific directory structure

### UpdraftPlus (Example)
- **Format:** Multiple ZIP files
- **Database:** `backup_[date]-db.gz`
- **wp-content:** Split: `*-plugins.zip`, `*-themes.zip`, `*-uploads.zip`
- **Signature:** File naming pattern

## Common Pitfalls

### 1. Not checking file existence
Always check if files/directories exist before operating on them.

```bash
# BAD
db_file=$(find "$extract_dir" -name "*.sql" | head -1)
echo "$db_file"  # Echoes empty string even on failure

# GOOD
db_file=$(find "$extract_dir" -name "*.sql" 2>/dev/null | head -1)
[[ -z "$db_file" ]] && return 1
echo "$db_file"
return 0
```

### 2. Not handling errors during extraction
Always check extraction command exit codes.

```bash
# BAD
unzip -q "$archive" -d "$dest"

# GOOD
if ! unzip -q "$archive" -d "$dest" 2>/dev/null; then
  return 1
fi
```

### 3. Not using proper path quoting
Always quote variables to handle spaces in paths.

```bash
# BAD
find $extract_dir -name "*.sql"

# GOOD
find "$extract_dir" -name "*.sql"
```

### 4. Overly strict validation
Make validation permissive enough to catch edge cases, but strict enough to avoid false positives.

```bash
# Check multiple signature indicators
if adapter_base_archive_contains "$archive" "signature-file.txt"; then
  return 0
fi

# Fallback to pattern matching
if adapter_base_archive_contains "$archive" "expected-pattern"; then
  return 0
fi

return 1
```

## Testing Checklist

Before submitting an adapter:

- [ ] Validate function correctly identifies format
- [ ] Validate function rejects other formats
- [ ] Extract function handles archives without errors
- [ ] Find database function locates SQL file correctly
- [ ] Find content function locates wp-content directory
- [ ] Adapter works with `--dry-run` flag
- [ ] Adapter works with actual import
- [ ] Database imports successfully
- [ ] wp-content replaces correctly
- [ ] URLs are rewritten properly
- [ ] Site functions after migration
- [ ] Rollback instructions work if needed
- [ ] ShellCheck passes (`make test`)

## Questions?

- Review existing adapters: `duplicator.sh`
- Check base helper functions: `base.sh`
- Open an issue on GitHub for clarification

## License

All adapters are MIT licensed, same as the main project.
