#!/usr/bin/env bash
#
# Docker Integration Test Runner
# Runs end-to-end migration tests in Docker containers

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Change to script directory
cd "$(dirname "$0")"

echo -e "${YELLOW}Docker Integration Test Suite${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Helper functions
pass() {
  echo -e "${GREEN}✓${NC} $1"
  ((TESTS_PASSED++))
  ((TESTS_RUN++))
}

fail() {
  echo -e "${RED}✗${NC} $1"
  if [[ -n "${2:-}" ]]; then
    echo "  Expected: $2"
  fi
  ((TESTS_FAILED++))
  ((TESTS_RUN++))
}

test_header() {
  echo ""
  echo -e "${YELLOW}Test: $1${NC}"
}

# Function to wait for WordPress environment to be ready (WP-CLI + DB connectivity)
# This checks if the container is ready for wp core install, NOT if WP is installed
wait_for_wordpress() {
  local container=$1
  local max_wait=60
  local waited=0

  echo "Waiting for WordPress environment in $container to be ready..."

  while [ $waited -lt $max_wait ]; do
    # Check if WP-CLI can connect to database using a simple query (works before WP installation)
    if $DOCKER_COMPOSE exec -T "$container" wp db query 'SELECT 1' --allow-root 2>/dev/null >/dev/null; then
      echo "  WordPress environment ready in $container (WP-CLI + DB accessible)"
      return 0
    fi
    sleep 2
    ((waited+=2))
  done

  echo "  ERROR: WordPress environment in $container did not become ready in ${max_wait}s"
  return 1
}

# Function to install WordPress
install_wordpress() {
  local container=$1
  local url=$2
  local title=$3

  echo "Installing WordPress in $container..."

  $DOCKER_COMPOSE exec -T "$container" bash -c "
    cd /var/www/html && \
    wp core install \
      --url='$url' \
      --title='$title' \
      --admin_user=admin \
      --admin_password=admin \
      --admin_email=admin@example.com \
      --allow-root \
      --skip-email
  " 2>&1 | grep -v "Warning:" || true

  if $DOCKER_COMPOSE exec -T "$container" wp core is-installed --allow-root 2>/dev/null; then
    echo "  WordPress installed successfully in $container"
    return 0
  else
    echo "  ERROR: WordPress installation failed in $container"
    return 1
  fi
}

# Detect docker compose command (supports both docker-compose and docker compose)
DOCKER_COMPOSE="docker compose"
if ! command -v docker &> /dev/null; then
  echo -e "${RED}ERROR: Docker is not installed${NC}"
  exit 1
fi

# Check if we should use docker-compose (legacy) or docker compose (modern)
if command -v docker-compose &> /dev/null; then
  DOCKER_COMPOSE="docker-compose"
elif ! docker compose version &> /dev/null; then
  echo -e "${RED}ERROR: Neither 'docker compose' nor 'docker-compose' is available${NC}"
  exit 1
fi

echo "Using: $DOCKER_COMPOSE"

# Cleanup function
cleanup() {
  echo ""
  echo "Cleaning up Docker containers..."
  $DOCKER_COMPOSE down -v 2>/dev/null || true
}

# Trap cleanup on exit
trap cleanup EXIT

# Start containers
echo "Starting Docker containers..."
if ! $DOCKER_COMPOSE up -d --build; then
  echo -e "${RED}ERROR: Failed to start Docker containers${NC}"
  exit 1
fi

echo "Waiting for containers to be healthy..."
sleep 10

# Wait for both WordPress instances
if ! wait_for_wordpress "source-wp"; then
  echo -e "${RED}ERROR: Source WordPress did not start${NC}"
  exit 1
fi

if ! wait_for_wordpress "dest-wp"; then
  echo -e "${RED}ERROR: Destination WordPress did not start${NC}"
  exit 1
fi

# Install WordPress in both containers
if ! install_wordpress "source-wp" "http://localhost:8080" "Source Site"; then
  echo -e "${RED}ERROR: Failed to install source WordPress${NC}"
  exit 1
fi

if ! install_wordpress "dest-wp" "http://localhost:8081" "Destination Site"; then
  echo -e "${RED}ERROR: Failed to install destination WordPress${NC}"
  exit 1
fi

# Add some test content to source
echo ""
echo "Adding test content to source WordPress..."
$DOCKER_COMPOSE exec -T source-wp bash -c "
  cd /var/www/html && \
  wp post create \
    --post_title='Test Post 1' \
    --post_content='This is test content with URL http://localhost:8080' \
    --post_status=publish \
    --allow-root && \
  wp post create \
    --post_title='Test Post 2' \
    --post_content='Another test post' \
    --post_status=publish \
    --allow-root
" 2>&1 | grep -v "Warning:" || true

echo "  Test content added"

# ============================================================================
# TEST 1: Archive Mode - Duplicator Format
# ============================================================================
test_header "Archive Mode - Duplicator format import"

# Import Duplicator archive (disable errexit temporarily to capture output even on failure)
set +e
output=$($DOCKER_COMPOSE exec -T dest-wp bash -c "
  cd /var/www/html && \
  wp-migrate.sh --archive /opt/test-fixtures/duplicator-minimal.zip --dry-run --verbose
" 2>&1)
exit_code=$?
set -e

# Debug: show output if verbose
if [[ "${VERBOSE:-}" == "1" ]]; then
  echo "=== Duplicator Test Output (exit code: $exit_code) ==="
  echo "$output"
  echo "=============================="
fi

if echo "$output" | grep -q "Archive format: Duplicator"; then
  pass "Duplicator archive detected in dry-run mode"
else
  fail "Duplicator archive not detected" "Expected 'Archive format: Duplicator' in output"
fi

echo "About to start test 2"

# ============================================================================
# TEST 2: Archive Mode - Jetpack Format
# ============================================================================
test_header "Archive Mode - Jetpack format import"

set +e
output=$($DOCKER_COMPOSE exec -T dest-wp bash -c "
  cd /var/www/html && \
  wp-migrate.sh --archive /opt/test-fixtures/jetpack-minimal.tar.gz --dry-run --verbose
" 2>&1)
set -e

if echo "$output" | grep -q "Archive format: Jetpack"; then
  pass "Jetpack archive detected in dry-run mode"
else
  fail "Jetpack archive not detected"
fi

# ============================================================================
# TEST 3: Archive Mode - Solid Backups Format
# ============================================================================
test_header "Archive Mode - Solid Backups format import"

set +e
output=$($DOCKER_COMPOSE exec -T dest-wp bash -c "
  cd /var/www/html && \
  wp-migrate.sh --archive /opt/test-fixtures/solidbackups-minimal.zip --dry-run --verbose
" 2>&1)
set -e

if echo "$output" | grep -q "Archive format: Solid Backups"; then
  pass "Solid Backups archive detected in dry-run mode"
else
  fail "Solid Backups archive not detected"
fi

# ============================================================================
# TEST 4: WordPress Environment Verification
# ============================================================================
test_header "WordPress environment verification"

# Check source WordPress
if $DOCKER_COMPOSE exec -T source-wp bash -c "
  wp post list --format=count --allow-root
" 2>&1 | grep -q "2"; then
  pass "Source WordPress has test posts"
else
  fail "Source WordPress missing test posts"
fi

# Check destination WordPress exists
if $DOCKER_COMPOSE exec -T dest-wp wp core is-installed --allow-root 2>/dev/null; then
  pass "Destination WordPress is installed"
else
  fail "Destination WordPress not installed"
fi

# ============================================================================
# TEST 5: WP-CLI Availability
# ============================================================================
test_header "WP-CLI availability in containers"

if $DOCKER_COMPOSE exec -T source-wp wp --version --allow-root 2>&1 | grep -q "WP-CLI"; then
  pass "WP-CLI available in source container"
else
  fail "WP-CLI not available in source container"
fi

if $DOCKER_COMPOSE exec -T dest-wp wp --version --allow-root 2>&1 | grep -q "WP-CLI"; then
  pass "WP-CLI available in dest container"
else
  fail "WP-CLI not available in dest container"
fi

# ============================================================================
# TEST 6: wp-migrate.sh Script Availability
# ============================================================================
test_header "wp-migrate.sh script availability"

if $DOCKER_COMPOSE exec -T source-wp wp-migrate.sh --version 2>&1 | grep -q "wp-migrate.sh"; then
  pass "wp-migrate.sh available in source container"
else
  fail "wp-migrate.sh not available in source container"
fi

if $DOCKER_COMPOSE exec -T dest-wp wp-migrate.sh --version 2>&1 | grep -q "wp-migrate.sh"; then
  pass "wp-migrate.sh available in dest container"
else
  fail "wp-migrate.sh not available in dest container"
fi

# Print summary
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [ $TESTS_FAILED -eq 0 ]; then
  echo -e "Test Summary: $TESTS_RUN run, ${GREEN}$TESTS_PASSED passed${NC}, ${RED}$TESTS_FAILED failed${NC}"
else
  echo -e "Test Summary: $TESTS_RUN run, ${GREEN}$TESTS_PASSED passed${NC}, ${RED}$TESTS_FAILED failed${NC}"
fi
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Exit with failure if any tests failed
if [ $TESTS_FAILED -gt 0 ]; then
  exit 1
fi

exit 0
