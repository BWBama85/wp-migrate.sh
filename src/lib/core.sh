# -------------
# Core Utilities
# -------------

# Verbosity control flags (set by argument parser)
VERBOSE=false
TRACE_MODE=false

err() { printf "ERROR: %s\n" "$*" >&2; exit 1; }
needs() { command -v "$1" >/dev/null 2>&1 || err "Missing dependency: $1"; }

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
  printf "%s %s\n" "$(date '+%F %T')" "$*" | tee -a "$LOG_FILE"
}

log_warning() {
  # Yellow text for warnings (non-critical issues that don't stop migration)
  local yellow='\033[1;33m'
  local reset='\033[0m'
  local timestamp
  local plain_msg
  timestamp="$(date '+%F %T')"
  plain_msg="$timestamp WARNING: $*"

  # Always write plain text to log file
  printf "%s\n" "$plain_msg" >> "$LOG_FILE"

  # Write colored output to terminal if interactive
  if [[ -t 1 ]]; then
    printf "%s ${yellow}WARNING:${reset} %s\n" "$timestamp" "$*"
  else
    # Non-interactive, just echo the plain message
    printf "%s\n" "$plain_msg"
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
  if $TRACE_MODE; then
    local cyan='\033[0;36m'
    local reset='\033[0m'
    local timestamp
    local plain_msg
    timestamp="$(date '+%F %T')"
    plain_msg="$timestamp + $*"

    # Always write plain text to log file
    printf "%s\n" "$plain_msg" >> "$LOG_FILE"

    # Write colored output to terminal if interactive
    if [[ -t 1 ]]; then
      printf "%s ${cyan}+${reset} %s\n" "$timestamp" "$*"
    else
      # Non-interactive, just echo the plain message
      printf "%s\n" "$plain_msg"
    fi
  fi
}
