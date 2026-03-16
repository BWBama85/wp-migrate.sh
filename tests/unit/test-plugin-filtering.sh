#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2329
# SC2034: Variables (STELLARSITES_MODE, DRY_RUN) are used by sourced functions
# SC2329: wp_local() is invoked indirectly by sourced detect_dest_plugins_local()
set -Eeuo pipefail

# -------------------------------------------------------------------
# Unit Tests: Plugin Filtering Feature
# -------------------------------------------------------------------
# Tests should_exclude_plugin() and detect_dest_plugins_local()
# without requiring WordPress installations or WP-CLI.
#
# Covers: Issue #76, PRs #72 #73 #74, Issue #75 (dry-run fix)
# -------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

pass() {
  ((TESTS_PASSED++)) || true
  ((TESTS_RUN++)) || true
  printf "${GREEN}✓${NC} %s\n" "$1"
}

fail() {
  ((TESTS_FAILED++)) || true
  ((TESTS_RUN++)) || true
  printf "${RED}✗${NC} %s\n" "$1"
  [[ -n "${2:-}" ]] && printf "  Error: %s\n" "$2"
}

test_header() {
  printf "\n${YELLOW}%s${NC}\n" "$1"
}

# -------------------------------------------------------------------
# Source the modules we need (without triggering main execution)
# -------------------------------------------------------------------

# Source header.sh for global variable declarations
# shellcheck source=../../src/header.sh
source "$PROJECT_ROOT/src/header.sh"

# Source core.sh for logging functions
# shellcheck source=../../src/lib/core.sh
source "$PROJECT_ROOT/src/lib/core.sh"

# Source functions.sh for should_exclude_plugin, detect_dest_plugins_local, etc.
# shellcheck source=../../src/lib/functions.sh
source "$PROJECT_ROOT/src/lib/functions.sh"

# Override the exit trap set by functions.sh (exit_cleanup does maintenance
# cleanup and SSH teardown that we don't want in tests)
trap - EXIT

# -------------------------------------------------------------------
# Helper: reset filtering state between tests
# -------------------------------------------------------------------
reset_filtering_state() {
  FILTERED_DROPINS=()
  FILTERED_MANAGED_PLUGINS=()
  DEST_PLUGINS_BEFORE=()
  STELLARSITES_MODE=false
  DRY_RUN=false
}

# -------------------------------------------------------------------
# Helper: check if an array contains a value
# -------------------------------------------------------------------
array_contains() {
  local needle="$1"; shift
  local item
  for item in "$@"; do
    [[ "$item" == "$needle" ]] && return 0
  done
  return 1
}

# ===================================================================
# PHASE 1: Unit tests for should_exclude_plugin()
# ===================================================================

# -------------------------------------------------------------------
# Test: Drop-in advanced-cache.php is excluded
# -------------------------------------------------------------------
test_header "Phase 1: should_exclude_plugin() — Drop-in filtering"

reset_filtering_state
if should_exclude_plugin "advanced-cache.php"; then
  pass "advanced-cache.php is excluded"
else
  fail "advanced-cache.php should be excluded"
fi

if array_contains "advanced-cache.php" "${FILTERED_DROPINS[@]}"; then
  pass "advanced-cache.php tracked in FILTERED_DROPINS"
else
  fail "advanced-cache.php should be in FILTERED_DROPINS"
fi

# -------------------------------------------------------------------
# Test: Drop-in db.php is excluded
# -------------------------------------------------------------------
reset_filtering_state
if should_exclude_plugin "db.php"; then
  pass "db.php is excluded"
else
  fail "db.php should be excluded"
fi

if array_contains "db.php" "${FILTERED_DROPINS[@]}"; then
  pass "db.php tracked in FILTERED_DROPINS"
else
  fail "db.php should be in FILTERED_DROPINS"
fi

# -------------------------------------------------------------------
# Test: Drop-in db-error.php is excluded
# -------------------------------------------------------------------
reset_filtering_state
if should_exclude_plugin "db-error.php"; then
  pass "db-error.php is excluded"
else
  fail "db-error.php should be excluded"
fi

if array_contains "db-error.php" "${FILTERED_DROPINS[@]}"; then
  pass "db-error.php tracked in FILTERED_DROPINS"
else
  fail "db-error.php should be in FILTERED_DROPINS"
fi

# -------------------------------------------------------------------
# Test: Normal plugins are NOT excluded
# -------------------------------------------------------------------
test_header "Phase 1: should_exclude_plugin() — Normal plugin preservation"

reset_filtering_state
if should_exclude_plugin "akismet"; then
  fail "akismet should NOT be excluded"
else
  pass "akismet is preserved"
fi

if [[ ${#FILTERED_DROPINS[@]} -eq 0 && ${#FILTERED_MANAGED_PLUGINS[@]} -eq 0 ]]; then
  pass "No filtering arrays populated for normal plugin"
else
  fail "Filtering arrays should be empty for normal plugin"
fi

reset_filtering_state
if should_exclude_plugin "jetpack"; then
  fail "jetpack should NOT be excluded"
else
  pass "jetpack is preserved"
fi

reset_filtering_state
if should_exclude_plugin "woocommerce"; then
  fail "woocommerce should NOT be excluded"
else
  pass "woocommerce is preserved"
fi

# -------------------------------------------------------------------
# Test: Similar names are NOT excluded (no partial matching)
# -------------------------------------------------------------------
test_header "Phase 1: should_exclude_plugin() — Similar name edge cases"

reset_filtering_state
if should_exclude_plugin "advanced-cache"; then
  fail "advanced-cache (without .php) should NOT be excluded"
else
  pass "advanced-cache (without .php) is preserved"
fi

reset_filtering_state
if should_exclude_plugin "db"; then
  fail "db (without .php) should NOT be excluded"
else
  pass "db (without .php) is preserved"
fi

reset_filtering_state
if should_exclude_plugin "my-db.php-plugin"; then
  fail "my-db.php-plugin should NOT be excluded"
else
  pass "my-db.php-plugin is preserved (no partial match)"
fi

# -------------------------------------------------------------------
# Test: StellarSites managed plugin excluded when mode ON
# -------------------------------------------------------------------
test_header "Phase 1: should_exclude_plugin() — StellarSites filtering"

reset_filtering_state
STELLARSITES_MODE=true
if should_exclude_plugin "stellarsites-cloud"; then
  pass "stellarsites-cloud excluded when STELLARSITES_MODE=true"
else
  fail "stellarsites-cloud should be excluded in StellarSites mode"
fi

if array_contains "stellarsites-cloud" "${FILTERED_MANAGED_PLUGINS[@]}"; then
  pass "stellarsites-cloud tracked in FILTERED_MANAGED_PLUGINS"
else
  fail "stellarsites-cloud should be in FILTERED_MANAGED_PLUGINS"
fi

# -------------------------------------------------------------------
# Test: StellarSites managed plugin preserved when mode OFF
# -------------------------------------------------------------------
reset_filtering_state
STELLARSITES_MODE=false
if should_exclude_plugin "stellarsites-cloud"; then
  fail "stellarsites-cloud should NOT be excluded when STELLARSITES_MODE=false"
else
  pass "stellarsites-cloud preserved when STELLARSITES_MODE=false"
fi

if [[ ${#FILTERED_MANAGED_PLUGINS[@]} -eq 0 ]]; then
  pass "FILTERED_MANAGED_PLUGINS empty when mode off"
else
  fail "FILTERED_MANAGED_PLUGINS should be empty when mode off"
fi

# -------------------------------------------------------------------
# Test: Drop-ins excluded regardless of StellarSites mode
# -------------------------------------------------------------------
test_header "Phase 1: should_exclude_plugin() — Drop-ins + StellarSites interaction"

reset_filtering_state
STELLARSITES_MODE=true
if should_exclude_plugin "advanced-cache.php"; then
  pass "Drop-in excluded with StellarSites mode on"
else
  fail "Drop-ins should be excluded regardless of StellarSites mode"
fi

# Verify it went to FILTERED_DROPINS, not FILTERED_MANAGED_PLUGINS
if array_contains "advanced-cache.php" "${FILTERED_DROPINS[@]}"; then
  pass "Drop-in tracked in FILTERED_DROPINS (not managed plugins)"
else
  fail "Drop-in should be in FILTERED_DROPINS"
fi

if [[ ${#FILTERED_MANAGED_PLUGINS[@]} -eq 0 ]]; then
  pass "FILTERED_MANAGED_PLUGINS not used for drop-ins"
else
  fail "Drop-ins should not appear in FILTERED_MANAGED_PLUGINS"
fi

# -------------------------------------------------------------------
# Test: Multiple exclusions accumulate in tracking arrays
# -------------------------------------------------------------------
test_header "Phase 1: should_exclude_plugin() — Accumulation"

reset_filtering_state
STELLARSITES_MODE=true
should_exclude_plugin "advanced-cache.php"
should_exclude_plugin "db.php"
should_exclude_plugin "stellarsites-cloud"

if [[ ${#FILTERED_DROPINS[@]} -eq 2 ]]; then
  pass "FILTERED_DROPINS has 2 entries after 2 drop-ins"
else
  fail "Expected 2 entries in FILTERED_DROPINS, got ${#FILTERED_DROPINS[@]}"
fi

if [[ ${#FILTERED_MANAGED_PLUGINS[@]} -eq 1 ]]; then
  pass "FILTERED_MANAGED_PLUGINS has 1 entry after 1 managed plugin"
else
  fail "Expected 1 entry in FILTERED_MANAGED_PLUGINS, got ${#FILTERED_MANAGED_PLUGINS[@]}"
fi

# ===================================================================
# PHASE 2: Integration tests for detect_dest_plugins_local()
# ===================================================================

test_header "Phase 2: detect_dest_plugins_local() — Mocked WP-CLI"

# Mock wp_local to return a fake plugin list
wp_local() {
  # Simulate: wp plugin list --field=name --format=csv
  if [[ "${*}" == *"plugin list"* ]]; then
    printf "akismet\njetpack\nadvanced-cache.php\ndb.php\nwoocommerce\n"
    return 0
  fi
  return 1
}

# -------------------------------------------------------------------
# Test: Mixed plugins and drop-ins — drop-ins filtered out
# -------------------------------------------------------------------
reset_filtering_state
detect_dest_plugins_local 2>/dev/null

if [[ ${#DEST_PLUGINS_BEFORE[@]} -eq 3 ]]; then
  pass "DEST_PLUGINS_BEFORE has 3 real plugins (drop-ins filtered)"
else
  fail "Expected 3 plugins in DEST_PLUGINS_BEFORE, got ${#DEST_PLUGINS_BEFORE[@]}"
fi

if array_contains "akismet" "${DEST_PLUGINS_BEFORE[@]}"; then
  pass "akismet preserved in DEST_PLUGINS_BEFORE"
else
  fail "akismet should be in DEST_PLUGINS_BEFORE"
fi

if array_contains "jetpack" "${DEST_PLUGINS_BEFORE[@]}"; then
  pass "jetpack preserved in DEST_PLUGINS_BEFORE"
else
  fail "jetpack should be in DEST_PLUGINS_BEFORE"
fi

if array_contains "woocommerce" "${DEST_PLUGINS_BEFORE[@]}"; then
  pass "woocommerce preserved in DEST_PLUGINS_BEFORE"
else
  fail "woocommerce should be in DEST_PLUGINS_BEFORE"
fi

# Verify drop-ins NOT in DEST_PLUGINS_BEFORE
if ! array_contains "advanced-cache.php" "${DEST_PLUGINS_BEFORE[@]}"; then
  pass "advanced-cache.php NOT in DEST_PLUGINS_BEFORE"
else
  fail "advanced-cache.php should be filtered from DEST_PLUGINS_BEFORE"
fi

if ! array_contains "db.php" "${DEST_PLUGINS_BEFORE[@]}"; then
  pass "db.php NOT in DEST_PLUGINS_BEFORE"
else
  fail "db.php should be filtered from DEST_PLUGINS_BEFORE"
fi

# Verify tracking arrays
if [[ ${#FILTERED_DROPINS[@]} -eq 2 ]]; then
  pass "FILTERED_DROPINS has 2 drop-ins"
else
  fail "Expected 2 in FILTERED_DROPINS, got ${#FILTERED_DROPINS[@]}"
fi

# -------------------------------------------------------------------
# Test: StellarSites mode filters managed plugins too
# -------------------------------------------------------------------
test_header "Phase 2: detect_dest_plugins_local() — StellarSites mode"

# Mock wp_local with stellarsites-cloud in the list
wp_local() {
  if [[ "${*}" == *"plugin list"* ]]; then
    printf "akismet\nstellarsites-cloud\nadvanced-cache.php\n"
    return 0
  fi
  return 1
}

reset_filtering_state
STELLARSITES_MODE=true
detect_dest_plugins_local 2>/dev/null

if [[ ${#DEST_PLUGINS_BEFORE[@]} -eq 1 ]]; then
  pass "Only akismet preserved (drop-in + managed plugin filtered)"
else
  fail "Expected 1 plugin in DEST_PLUGINS_BEFORE, got ${#DEST_PLUGINS_BEFORE[@]}"
fi

if array_contains "akismet" "${DEST_PLUGINS_BEFORE[@]}"; then
  pass "akismet is the one preserved plugin"
else
  fail "akismet should be the only preserved plugin"
fi

if [[ ${#FILTERED_DROPINS[@]} -eq 1 ]]; then
  pass "1 drop-in filtered"
else
  fail "Expected 1 drop-in, got ${#FILTERED_DROPINS[@]}"
fi

if [[ ${#FILTERED_MANAGED_PLUGINS[@]} -eq 1 ]]; then
  pass "1 managed plugin filtered"
else
  fail "Expected 1 managed plugin, got ${#FILTERED_MANAGED_PLUGINS[@]}"
fi

# -------------------------------------------------------------------
# Test: StellarSites OFF preserves stellarsites-cloud
# -------------------------------------------------------------------
test_header "Phase 2: detect_dest_plugins_local() — StellarSites OFF"

reset_filtering_state
STELLARSITES_MODE=false
detect_dest_plugins_local 2>/dev/null

if array_contains "stellarsites-cloud" "${DEST_PLUGINS_BEFORE[@]}"; then
  pass "stellarsites-cloud preserved when STELLARSITES_MODE=false"
else
  fail "stellarsites-cloud should be in DEST_PLUGINS_BEFORE when mode off"
fi

if [[ ${#FILTERED_MANAGED_PLUGINS[@]} -eq 0 ]]; then
  pass "No managed plugins filtered when mode off"
else
  fail "FILTERED_MANAGED_PLUGINS should be empty when mode off"
fi

# -------------------------------------------------------------------
# Test: Dry-run mode still runs detection (Issue #75 fix)
# -------------------------------------------------------------------
test_header "Phase 2: detect_dest_plugins_local() — Dry-run mode"

wp_local() {
  if [[ "${*}" == *"plugin list"* ]]; then
    printf "akismet\nadvanced-cache.php\n"
    return 0
  fi
  return 1
}

reset_filtering_state
DRY_RUN=true
detect_dest_plugins_local 2>/dev/null

if [[ ${#DEST_PLUGINS_BEFORE[@]} -eq 1 ]]; then
  pass "Detection runs in dry-run mode (1 plugin found)"
else
  fail "Expected 1 plugin in dry-run mode, got ${#DEST_PLUGINS_BEFORE[@]}"
fi

if [[ ${#FILTERED_DROPINS[@]} -eq 1 ]]; then
  pass "Filtering applies in dry-run mode (1 drop-in filtered)"
else
  fail "Expected 1 drop-in filtered in dry-run mode, got ${#FILTERED_DROPINS[@]}"
fi

# -------------------------------------------------------------------
# Test: Empty plugin list
# -------------------------------------------------------------------
test_header "Phase 2: detect_dest_plugins_local() — Edge cases"

wp_local() {
  if [[ "${*}" == *"plugin list"* ]]; then
    echo ""
    return 0
  fi
  return 1
}

reset_filtering_state
detect_dest_plugins_local 2>/dev/null

if [[ ${#DEST_PLUGINS_BEFORE[@]} -eq 0 ]]; then
  pass "Empty plugin list produces empty DEST_PLUGINS_BEFORE"
else
  fail "Expected 0 plugins for empty list, got ${#DEST_PLUGINS_BEFORE[@]}"
fi

# -------------------------------------------------------------------
# Test: All plugins are drop-ins (all filtered)
# -------------------------------------------------------------------
wp_local() {
  if [[ "${*}" == *"plugin list"* ]]; then
    printf "advanced-cache.php\ndb.php\ndb-error.php\n"
    return 0
  fi
  return 1
}

reset_filtering_state
detect_dest_plugins_local 2>/dev/null

if [[ ${#DEST_PLUGINS_BEFORE[@]} -eq 0 ]]; then
  pass "All-drop-in list produces empty DEST_PLUGINS_BEFORE"
else
  fail "Expected 0 preserved plugins when all are drop-ins, got ${#DEST_PLUGINS_BEFORE[@]}"
fi

if [[ ${#FILTERED_DROPINS[@]} -eq 3 ]]; then
  pass "All 3 drop-ins tracked in FILTERED_DROPINS"
else
  fail "Expected 3 in FILTERED_DROPINS, got ${#FILTERED_DROPINS[@]}"
fi

# -------------------------------------------------------------------
# Test: WP-CLI failure returns empty (graceful degradation)
# -------------------------------------------------------------------
wp_local() {
  return 1
}

reset_filtering_state
detect_dest_plugins_local 2>/dev/null

if [[ ${#DEST_PLUGINS_BEFORE[@]} -eq 0 ]]; then
  pass "WP-CLI failure produces empty plugin list (no crash)"
else
  fail "Expected 0 plugins on WP-CLI failure, got ${#DEST_PLUGINS_BEFORE[@]}"
fi

# -------------------------------------------------------------------
# Summary
# -------------------------------------------------------------------
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [[ $TESTS_FAILED -eq 0 ]]; then
  printf "Test Summary: %d run, ${GREEN}%d passed${NC}, ${RED}%d failed${NC}\n" \
    "$TESTS_RUN" "$TESTS_PASSED" "$TESTS_FAILED"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  exit 0
else
  printf "Test Summary: %d run, ${GREEN}%d passed${NC}, ${RED}%d failed${NC}\n" \
    "$TESTS_RUN" "$TESTS_PASSED" "$TESTS_FAILED"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  exit 1
fi
