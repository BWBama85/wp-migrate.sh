# -------------
# Core Utilities
# -------------

# Verbosity control flags (set by argument parser)
VERBOSE=false
TRACE_MODE=false

err() { printf "ERROR: %s\n" "$*" >&2; exit 1; }

needs() {
  local cmd="$1"
  log_verbose "Checking for required dependency: $cmd"
  if command -v "$cmd" >/dev/null 2>&1; then
    local cmd_path
    cmd_path=$(command -v "$cmd")
    log_verbose "  ✓ Found: $cmd_path"
    return 0
  else
    err "Missing required dependency: $cmd

This command is required for migration to work.

Installation instructions:
$(case "$cmd" in
  wp)
    echo "  # WP-CLI (WordPress command-line tool)
  # macOS: brew install wp-cli
  # Linux: curl -O https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar && chmod +x wp-cli.phar && sudo mv wp-cli.phar /usr/local/bin/wp
  # Verify: wp --version"
    ;;
  rsync)
    echo "  # rsync (file synchronization tool)
  # macOS: brew install rsync (or use built-in)
  # Debian/Ubuntu: sudo apt-get install rsync
  # RHEL/CentOS: sudo yum install rsync
  # Verify: rsync --version"
    ;;
  ssh)
    echo "  # SSH client
  # macOS: built-in (check with: which ssh)
  # Debian/Ubuntu: sudo apt-get install openssh-client
  # RHEL/CentOS: sudo yum install openssh-clients
  # Verify: ssh -V"
    ;;
  gzip)
    echo "  # gzip (compression tool)
  # Usually pre-installed on most systems
  # macOS: built-in
  # Debian/Ubuntu: sudo apt-get install gzip
  # RHEL/CentOS: sudo yum install gzip
  # Verify: gzip --version"
    ;;
  unzip)
    echo "  # unzip (archive extraction tool for ZIP files)
  # macOS: brew install unzip (or use built-in)
  # Debian/Ubuntu: sudo apt-get install unzip
  # RHEL/CentOS: sudo yum install unzip
  # Verify: unzip -v"
    ;;
  tar)
    echo "  # tar (archive tool)
  # Usually pre-installed on most systems
  # macOS: built-in
  # Debian/Ubuntu: sudo apt-get install tar
  # RHEL/CentOS: sudo yum install tar
  # Verify: tar --version"
    ;;
  file)
    echo "  # file (file type detection tool)
  # macOS: brew install file (or use built-in)
  # Debian/Ubuntu: sudo apt-get install file
  # RHEL/CentOS: sudo yum install file
  # Verify: file --version"
    ;;
  *)
    echo "  # Generic installation:
  # Check your system's package manager
  # macOS: brew install $cmd
  # Debian/Ubuntu: sudo apt-get install $cmd
  # RHEL/CentOS: sudo yum install $cmd"
    ;;
esac)

After installation, verify with:
  which $cmd && $cmd --version"
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
