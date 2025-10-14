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
    err "Missing dependency: $cmd"
  fi
}

validate_url() {
  local url="$1" flag_name="$2"
  # Basic URL validation: must start with http:// or https://
  if [[ ! "$url" =~ ^https?:// ]]; then
    err "$flag_name must be a valid URL starting with http:// or https:// (got: $url)"
  fi
  # Ensure URL has a domain part after protocol
  if [[ ! "$url" =~ ^https?://[^/]+ ]]; then
    err "$flag_name must include a domain name (got: $url)"
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
