#!/usr/bin/env bash
#
# crash-fulcrum-process.sh - Simulates Fulcrum process crash without killing container
#
# This script kills the Fulcrum process to test process-level crash recovery.
# It should NOT cause the container to exit if a proper supervisor is running.
#
# Usage:
#   ./crash-fulcrum-process.sh [OPTIONS]
#
# Options:
#   -s, --signal SIGNAL    Signal to send (default: SIGKILL)
#   -c, --container NAME   Container name (default: fulcrum-alpha)
#   -w, --wait SECONDS     Wait time after crash (default: 5)
#   -h, --help            Show this help message
#
# Exit codes:
#   0 - Success
#   1 - General error
#   2 - Container not found
#   3 - Process not found

set -Eeuo pipefail

# Script metadata
readonly SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

# Default configuration
CONTAINER_NAME="fulcrum-alpha"
SIGNAL="SIGKILL"
WAIT_TIME=5

# Color output helpers
if [[ -t 1 ]]; then
    readonly RED='\033[0;31m'
    readonly GREEN='\033[0;32m'
    readonly YELLOW='\033[1;33m'
    readonly BLUE='\033[0;34m'
    readonly NC='\033[0m' # No Color
else
    readonly RED=''
    readonly GREEN=''
    readonly YELLOW=''
    readonly BLUE=''
    readonly NC=''
fi

# Logging functions
log_info() {
    printf "${BLUE}[INFO]${NC} %s\n" "$*" >&2
}

log_success() {
    printf "${GREEN}[SUCCESS]${NC} %s\n" "$*" >&2
}

log_warn() {
    printf "${YELLOW}[WARN]${NC} %s\n" "$*" >&2
}

log_error() {
    printf "${RED}[ERROR]${NC} %s\n" "$*" >&2
}

# Usage information
usage() {
    cat <<EOF
Usage: $SCRIPT_NAME [OPTIONS]

Simulates Fulcrum process crash without killing the container.
Tests process-level crash recovery with supervisor.

Options:
    -s, --signal SIGNAL    Signal to send (SIGTERM, SIGKILL, SIGABRT, etc.)
                          Default: SIGKILL
    -c, --container NAME   Container name
                          Default: fulcrum-alpha
    -w, --wait SECONDS     Wait time after crash for recovery
                          Default: 5
    -h, --help            Show this help message

Examples:
    # Simulate hard crash with SIGKILL
    $SCRIPT_NAME

    # Simulate graceful termination with SIGTERM
    $SCRIPT_NAME --signal SIGTERM

    # Test with custom container name
    $SCRIPT_NAME --container my-fulcrum --wait 10

Signals explained:
    SIGTERM  - Graceful shutdown request (signal 15)
    SIGKILL  - Immediate termination, cannot be caught (signal 9)
    SIGABRT  - Abnormal termination, simulates crash (signal 6)
    SIGSEGV  - Segmentation fault simulation (signal 11)

EOF
}

# Parse command-line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -s|--signal)
                SIGNAL="$2"
                shift 2
                ;;
            -c|--container)
                CONTAINER_NAME="$2"
                shift 2
                ;;
            -w|--wait)
                if [[ ! $2 =~ ^[0-9]+$ ]]; then
                    log_error "Wait time must be a positive integer"
                    exit 1
                fi
                WAIT_TIME="$2"
                shift 2
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done
}

# Validate prerequisites
validate_prerequisites() {
    log_info "Validating prerequisites..."

    # Check if docker is available
    if ! command -v docker &>/dev/null; then
        log_error "docker command not found. Please install Docker."
        exit 1
    fi

    # Check if container exists
    if ! docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        log_error "Container '${CONTAINER_NAME}' not found"
        log_info "Available containers:"
        docker ps -a --format 'table {{.Names}}\t{{.Status}}'
        exit 2
    fi

    # Check if container is running
    if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        log_error "Container '${CONTAINER_NAME}' is not running"
        exit 2
    fi

    log_success "Prerequisites validated"
}

# Find Fulcrum process ID
find_fulcrum_pid() {
    local pid
    pid=$(docker exec "$CONTAINER_NAME" pgrep -x Fulcrum 2>/dev/null || true)

    if [[ -z $pid ]]; then
        log_error "Fulcrum process not found in container"
        log_info "Running processes in container:"
        docker exec "$CONTAINER_NAME" ps aux
        exit 3
    fi

    printf "%s" "$pid"
}

# Get container PID 1
get_container_pid1() {
    local pid1
    pid1=$(docker exec "$CONTAINER_NAME" ps -o pid= -p 1 | tr -d ' ')
    printf "%s" "$pid1"
}

# Crash Fulcrum process
crash_fulcrum() {
    local fulcrum_pid
    local pid1

    log_info "Searching for Fulcrum process..."
    fulcrum_pid=$(find_fulcrum_pid)
    pid1=$(get_container_pid1)

    log_info "Container PID 1: $pid1"
    log_info "Fulcrum PID: $fulcrum_pid"

    # Verify Fulcrum is not PID 1 (or warn if it is)
    if [[ $fulcrum_pid == "$pid1" ]]; then
        log_warn "WARNING: Fulcrum is running as PID 1!"
        log_warn "Killing PID 1 will cause the container to exit."
        log_warn "Consider implementing a process supervisor (tini, dumb-init, supervisord)."
        printf "\n"
        read -rp "Continue anyway? (y/N): " confirm
        if [[ ! $confirm =~ ^[Yy]$ ]]; then
            log_info "Aborted by user"
            exit 0
        fi
    fi

    log_info "Sending $SIGNAL to Fulcrum process (PID $fulcrum_pid)..."
    if docker exec "$CONTAINER_NAME" kill -s "$SIGNAL" "$fulcrum_pid"; then
        log_success "Signal sent successfully"
    else
        log_error "Failed to send signal"
        exit 1
    fi
}

# Wait for recovery
wait_for_recovery() {
    log_info "Waiting ${WAIT_TIME} seconds for recovery..."
    sleep "$WAIT_TIME"
}

# Verify recovery
verify_recovery() {
    log_info "Verifying recovery..."

    # Check if container is still running
    if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        log_error "Container exited after crash (expected if Fulcrum was PID 1)"
        log_info "Check container status with: docker ps -a | grep $CONTAINER_NAME"
        return 1
    fi

    log_success "Container is still running"

    # Check if Fulcrum process is running
    local new_pid
    new_pid=$(docker exec "$CONTAINER_NAME" pgrep -x Fulcrum 2>/dev/null || true)

    if [[ -z $new_pid ]]; then
        log_error "Fulcrum process NOT running after recovery"
        log_warn "Process supervisor may not be configured properly"
        log_info "Running processes in container:"
        docker exec "$CONTAINER_NAME" ps aux
        return 1
    fi

    log_success "Fulcrum process is running (PID: $new_pid)"

    # Show process tree
    log_info "Process tree in container:"
    docker exec "$CONTAINER_NAME" ps auxf || docker exec "$CONTAINER_NAME" ps aux

    return 0
}

# Main execution
main() {
    parse_args "$@"

    printf "\n"
    log_info "=== Fulcrum Process Crash Simulation ==="
    log_info "Container: $CONTAINER_NAME"
    log_info "Signal: $SIGNAL"
    log_info "Wait time: ${WAIT_TIME}s"
    printf "\n"

    validate_prerequisites
    crash_fulcrum
    wait_for_recovery

    if verify_recovery; then
        printf "\n"
        log_success "=== Process crash recovery test PASSED ==="
        log_info "Fulcrum successfully restarted by supervisor"
        exit 0
    else
        printf "\n"
        log_error "=== Process crash recovery test FAILED ==="
        log_warn "Fulcrum did not restart automatically"
        log_info "Consider implementing a process supervisor:"
        log_info "  - tini (lightweight, Docker-friendly)"
        log_info "  - dumb-init (simple init system)"
        log_info "  - supervisord (full-featured)"
        exit 1
    fi
}

# Trap errors for debugging
trap 'log_error "Script failed at line $LINENO"' ERR

main "$@"
