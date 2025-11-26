# -------------
# Core Utilities
# -------------

# Verbosity control flags (set by argument parser)
VERBOSE=false
TRACE_MODE=false

err() { printf "ERROR: %s\n" "$*" >&2; exit 1; }

# Get installation instructions for a missing dependency
# Usage: get_install_instructions <command_name>
# Returns: Installation instructions text
get_install_instructions() {
  local cmd="$1"
  case "$cmd" in
    wp)
      cat << 'INSTRUCTIONS'
  # WP-CLI (WordPress command-line tool)
  # macOS: brew install wp-cli
  # Linux: curl -O https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar && chmod +x wp-cli.phar && sudo mv wp-cli.phar /usr/local/bin/wp
  # Verify: wp --version
INSTRUCTIONS
      ;;
    rsync)
      cat << 'INSTRUCTIONS'
  # rsync (file synchronization tool)
  # macOS: brew install rsync (or use built-in)
  # Debian/Ubuntu: sudo apt-get install rsync
  # RHEL/CentOS: sudo yum install rsync
  # Verify: rsync --version
INSTRUCTIONS
      ;;
    ssh)
      cat << 'INSTRUCTIONS'
  # SSH client
  # macOS: built-in (check with: which ssh)
  # Debian/Ubuntu: sudo apt-get install openssh-client
  # RHEL/CentOS: sudo yum install openssh-clients
  # Verify: ssh -V
INSTRUCTIONS
      ;;
    gzip)
      cat << 'INSTRUCTIONS'
  # gzip (compression tool)
  # Usually pre-installed on most systems
  # macOS: built-in
  # Debian/Ubuntu: sudo apt-get install gzip
  # RHEL/CentOS: sudo yum install gzip
  # Verify: gzip --version
INSTRUCTIONS
      ;;
    unzip)
      cat << 'INSTRUCTIONS'
  # unzip (archive extraction tool for ZIP files)
  # macOS: brew install unzip (or use built-in)
  # Debian/Ubuntu: sudo apt-get install unzip
  # RHEL/CentOS: sudo yum install unzip
  # Verify: unzip -v
INSTRUCTIONS
      ;;
    tar)
      cat << 'INSTRUCTIONS'
  # tar (archive tool)
  # Usually pre-installed on most systems
  # macOS: built-in
  # Debian/Ubuntu: sudo apt-get install tar
  # RHEL/CentOS: sudo yum install tar
  # Verify: tar --version
INSTRUCTIONS
      ;;
    file)
      cat << 'INSTRUCTIONS'
  # file (file type detection tool)
  # macOS: brew install file (or use built-in)
  # Debian/Ubuntu: sudo apt-get install file
  # RHEL/CentOS: sudo yum install file
  # Verify: file --version
INSTRUCTIONS
      ;;
    *)
      cat << INSTRUCTIONS
  # Generic installation:
  # Check your system's package manager
  # macOS: brew install $cmd
  # Debian/Ubuntu: sudo apt-get install $cmd
  # RHEL/CentOS: sudo yum install $cmd
INSTRUCTIONS
      ;;
  esac
}

needs() {
  local cmd="$1" min_version="${2:-}"
  log_verbose "Checking for required dependency: $cmd${min_version:+ (>= $min_version)}"

  if ! command -v "$cmd" >/dev/null 2>&1; then
    err "Missing required dependency: $cmd

This command is required for migration to work.

Installation instructions:
$(get_install_instructions "$cmd")

After installation, verify with:
  which $cmd && $cmd --version"
  fi

  local cmd_path
  cmd_path=$(command -v "$cmd")
  log_verbose "  ✓ Found: $cmd_path"

  # Check version if minimum specified
  if [[ -n "$min_version" ]]; then
    check_version "$cmd" "$min_version" || return 1
  fi

  return 0
}

# Check if command meets minimum version requirement
# Usage: check_version <command> <min_version>
# Returns: 0 if version >= min_version, 1 otherwise
check_version() {
  local cmd="$1" min_version="$2"
  local current_version

  # Get version based on command
  case "$cmd" in
    wp)
      # WP-CLI: "WP-CLI 2.8.1"
      current_version=$(wp --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
      ;;
    rsync)
      # rsync: "rsync  version 3.2.3"
      current_version=$(rsync --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
      ;;
    ssh)
      # OpenSSH: "OpenSSH_8.6p1"
      current_version=$(ssh -V 2>&1 | grep -oE '[0-9]+\.[0-9]+' | head -1)
      ;;
    bash)
      # Bash: "GNU bash, version 5.1.16"
      current_version=$(bash --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
      ;;
    *)
      # Generic version detection
      current_version=$($cmd --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)
      ;;
  esac

  if [[ -z "$current_version" ]]; then
    log_verbose "  ⚠️  Could not detect $cmd version (continuing anyway)"
    return 0  # Don't fail if we can't detect version
  fi

  log_verbose "  Version: $current_version (min: $min_version)"

  # Compare versions (simple numeric comparison)
  if version_compare "$current_version" "$min_version"; then
    log_verbose "  ✓ Version requirement met"
    return 0
  else
    log_warning "$cmd version $current_version is below recommended minimum $min_version

Current version: $current_version
Minimum recommended: $min_version

While the script may still work, you may encounter issues with older versions.

To upgrade:
$(get_install_instructions "$cmd")

Continuing anyway..."
    return 0  # Warn but don't fail
  fi
}

# Compare two semantic versions
# Usage: version_compare <version1> <version2>
# Returns: 0 if version1 >= version2, 1 otherwise
version_compare() {
  local ver1="$1" ver2="$2"

  # Split versions into components
  IFS='.' read -r -a v1 <<< "$ver1"
  IFS='.' read -r -a v2 <<< "$ver2"

  # Compare major version
  if [[ ${v1[0]:-0} -gt ${v2[0]:-0} ]]; then
    return 0
  elif [[ ${v1[0]:-0} -lt ${v2[0]:-0} ]]; then
    return 1
  fi

  # Compare minor version
  if [[ ${v1[1]:-0} -gt ${v2[1]:-0} ]]; then
    return 0
  elif [[ ${v1[1]:-0} -lt ${v2[1]:-0} ]]; then
    return 1
  fi

  # Compare patch version
  if [[ ${v1[2]:-0} -ge ${v2[2]:-0} ]]; then
    return 0
  fi

  return 1
}

# Check if local rsync supports a specific option
# Usage: rsync_supports_option <option>
# Returns: 0 if supported, 1 otherwise
# Note: macOS ships with openrsync which lacks many GNU rsync features
rsync_supports_option() {
  local option="$1"
  # Test the option with --dry-run against /dev/null to see if rsync accepts it
  # Suppress both stdout and stderr (some builds print "skipping non-regular file")
  rsync --dry-run "$option" /dev/null /dev/null >/dev/null 2>&1
}

# Get rsync progress options compatible with the local rsync version
# Usage: get_rsync_progress_opts
# Returns: Space-separated list of options for progress display
# Note: GNU rsync 3.1+ supports --info=progress2 for aggregate progress
#       macOS openrsync only supports --progress (per-file progress)
get_rsync_progress_opts() {
  if rsync_supports_option "--info=progress2"; then
    echo "--info=progress2"
  else
    # Fall back to --progress for macOS openrsync and older rsync versions
    echo "--progress"
  fi
}

# Get rsync stats options compatible with the local rsync version
# Usage: get_rsync_stats_opts
# Returns: Space-separated list of options for stats display, or empty string
get_rsync_stats_opts() {
  if rsync_supports_option "--info=stats2"; then
    echo "--info=stats2"
  else
    # macOS openrsync doesn't support --info=stats2, use --stats instead
    if rsync_supports_option "--stats"; then
      echo "--stats"
    fi
  fi
}

validate_url() {
  local url="$1" flag_name="$2"
  # Basic URL validation: must start with http:// or https://
  if [[ ! "$url" =~ ^https?:// ]]; then
    err "$flag_name must be a valid URL starting with http:// or https://

Invalid URL: $url

Common mistakes:
  • Missing protocol: use http://example.com (not example.com)
  • Wrong protocol: use http:// or https:// (not ftp:// or file://)

Examples:
  $flag_name http://example.com
  $flag_name https://staging.example.com
  $flag_name https://example.com/subdir"
  fi
  # Ensure URL has a domain part after protocol
  if [[ ! "$url" =~ ^https?://[^/]+ ]]; then
    err "$flag_name must include a domain name after the protocol.

Invalid URL: $url

The URL must have a domain name after http:// or https://

Examples:
  ✓ Correct: http://example.com
  ✓ Correct: https://staging.example.com/wordpress
  ✗ Wrong: http://
  ✗ Wrong: https:///path"
  fi
}

log() {
  # Write to stderr to prevent contaminating command substitutions
  # This ensures log output doesn't interfere with captured return values
  printf "%s %s\n" "$(date '+%F %T')" "$*" | tee -a "$LOG_FILE" >&2
}

log_warning() {
  # Yellow text for warnings (non-critical issues that don't stop migration)
  # Write to stderr to prevent contaminating command substitutions
  local yellow='\033[1;33m'
  local reset='\033[0m'
  local timestamp
  local plain_msg
  timestamp="$(date '+%F %T')"
  plain_msg="$timestamp WARNING: $*"

  # Always write plain text to log file
  printf "%s\n" "$plain_msg" >> "$LOG_FILE"

  # Write colored output to stderr (check fd 2, not fd 1)
  if [[ -t 2 ]]; then
    printf "%s ${yellow}WARNING:${reset} %s\n" "$timestamp" "$*" >&2
  else
    # Non-interactive, just echo the plain message to stderr
    printf "%s\n" "$plain_msg" >&2
  fi
}

log_verbose() {
  # Only log if --verbose flag is set
  # Uses same format as log() for consistency
  if $VERBOSE; then
    log "$@"
  fi
}

log_trace() {
  # Logs command execution traces when --trace flag is set
  # Uses cyan color to distinguish from regular logs
  # CRITICAL: Write to stderr to prevent contaminating command substitutions
  # Without this, trace output gets captured in variables like SOURCE_DB_PREFIX="$(wp_local ...)"
  if $TRACE_MODE; then
    local cyan='\033[0;36m'
    local reset='\033[0m'
    local timestamp
    local plain_msg
    timestamp="$(date '+%F %T')"
    plain_msg="$timestamp + $*"

    # Always write plain text to log file
    printf "%s\n" "$plain_msg" >> "$LOG_FILE"

    # Write colored output to stderr (check fd 2, not fd 1)
    if [[ -t 2 ]]; then
      printf "%s ${cyan}+${reset} %s\n" "$timestamp" "$*" >&2
    else
      # Non-interactive, write plain message to stderr
      printf "%s\n" "$plain_msg" >&2
    fi
  fi
}
