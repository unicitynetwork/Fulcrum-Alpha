#!/usr/bin/env bash
#
# crash-container.sh - Simulates complete container crash and restart
#
# This script causes the Docker container to exit completely, testing
# Docker's automatic restart policy (--restart always).
#
# Usage:
#   ./crash-container.sh [OPTIONS]
#
# Options:
#   -m, --method METHOD      Crash method (pid1-kill, pid1-abort, stop-start)
#   -c, --container NAME     Container name (default: fulcrum-alpha)
#   -w, --wait SECONDS       Wait time for restart (default: 10)
#   -h, --help              Show this help message
#
# Exit codes:
#   0 - Success
#   1 - General error
#   2 - Container not found
#   3 - Recovery failed

set -Eeuo pipefail

# Script metadata
readonly SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

# Default configuration
CONTAINER_NAME="fulcrum-alpha"
CRASH_METHOD="pid1-kill"
WAIT_TIME=10

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

Simulates complete container crash to test Docker restart policy.
Container must be running with --restart always policy.

Options:
    -m, --method METHOD      Crash method (see below)
                            Default: pid1-kill
    -c, --container NAME     Container name
                            Default: fulcrum-alpha
    -w, --wait SECONDS       Wait time for restart
                            Default: 10
    -h, --help              Show this help message

Crash methods:
    pid1-kill        - Send SIGKILL to PID 1 (immediate crash)
    pid1-abort       - Send SIGABRT to PID 1 (abnormal termination)
    pid1-term        - Send SIGTERM to PID 1 (graceful shutdown)
    stop-start       - Use 'docker stop' then verify auto-restart
    oom-trigger      - Trigger OOM killer (requires stress tools)

Examples:
    # Simulate hard crash with SIGKILL to PID 1
    $SCRIPT_NAME

    # Test graceful shutdown and restart
    $SCRIPT_NAME --method pid1-term

    # Test Docker stop/restart behavior
    $SCRIPT_NAME --method stop-start --wait 15

Restart policy check:
    This script verifies the container has --restart always policy.
    Without this policy, the container will not restart automatically.

EOF
}

# Parse command-line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -m|--method)
                CRASH_METHOD="$2"
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

    # Validate crash method
    case $CRASH_METHOD in
        pid1-kill|pid1-abort|pid1-term|stop-start|oom-trigger)
            ;;
        *)
            log_error "Invalid crash method: $CRASH_METHOD"
            log_info "Valid methods: pid1-kill, pid1-abort, pid1-term, stop-start, oom-trigger"
            exit 1
            ;;
    esac
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

# Check restart policy
check_restart_policy() {
    local restart_policy
    restart_policy=$(docker inspect --format '{{.HostConfig.RestartPolicy.Name}}' "$CONTAINER_NAME")

    log_info "Container restart policy: $restart_policy"

    if [[ $restart_policy != "always" && $restart_policy != "unless-stopped" ]]; then
        log_warn "WARNING: Container restart policy is '$restart_policy'"
        log_warn "Expected 'always' or 'unless-stopped' for automatic restart"
        log_warn "Container may not restart automatically after crash"
        printf "\n"
        read -rp "Continue anyway? (y/N): " confirm
        if [[ ! $confirm =~ ^[Yy]$ ]]; then
            log_info "Aborted by user"
            log_info "To set restart policy: docker update --restart always $CONTAINER_NAME"
            exit 0
        fi
    else
        log_success "Restart policy is configured correctly"
    fi
}

# Get container start time
get_container_start_time() {
    docker inspect --format '{{.State.StartedAt}}' "$CONTAINER_NAME"
}

# Crash container using specified method
crash_container() {
    local start_time_before
    start_time_before=$(get_container_start_time)

    log_info "Container start time before crash: $start_time_before"
    log_info "Crashing container using method: $CRASH_METHOD"

    case $CRASH_METHOD in
        pid1-kill)
            log_info "Sending SIGKILL to PID 1..."
            docker exec "$CONTAINER_NAME" kill -9 1 || true
            ;;
        pid1-abort)
            log_info "Sending SIGABRT to PID 1..."
            docker exec "$CONTAINER_NAME" kill -6 1 || true
            ;;
        pid1-term)
            log_info "Sending SIGTERM to PID 1..."
            docker exec "$CONTAINER_NAME" kill -15 1 || true
            ;;
        stop-start)
            log_info "Stopping container with docker stop..."
            docker stop "$CONTAINER_NAME" || true
            ;;
        oom-trigger)
            log_info "Triggering OOM killer..."
            log_warn "This method requires stress tools in the container"
            # Attempt to allocate excessive memory
            docker exec "$CONTAINER_NAME" sh -c 'stress-ng --vm 1 --vm-bytes 10G --timeout 5s' 2>/dev/null || \
            docker exec "$CONTAINER_NAME" sh -c 'yes | tr \\n x | head -c 10G | grep n' || true
            ;;
    esac

    log_success "Crash signal sent"
}

# Wait for container to exit
wait_for_exit() {
    log_info "Waiting for container to exit..."
    local timeout=5
    local elapsed=0

    while [[ $elapsed -lt $timeout ]]; do
        if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
            log_success "Container exited"
            return 0
        fi
        sleep 1
        ((elapsed++))
    done

    log_warn "Container did not exit within ${timeout}s"
    return 1
}

# Wait for restart
wait_for_restart() {
    log_info "Waiting up to ${WAIT_TIME} seconds for container to restart..."
    local elapsed=0

    while [[ $elapsed -lt $WAIT_TIME ]]; do
        if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
            log_success "Container is running"
            return 0
        fi
        sleep 1
        ((elapsed++))
        if [[ $((elapsed % 3)) -eq 0 ]]; then
            printf "." >&2
        fi
    done

    printf "\n" >&2
    log_error "Container did not restart within ${WAIT_TIME}s"
    return 1
}

# Wait for Fulcrum to be ready
wait_for_fulcrum() {
    log_info "Waiting for Fulcrum process to start..."
    local timeout=30
    local elapsed=0

    while [[ $elapsed -lt $timeout ]]; do
        if docker exec "$CONTAINER_NAME" pgrep -x Fulcrum &>/dev/null; then
            log_success "Fulcrum process is running"
            return 0
        fi
        sleep 1
        ((elapsed++))
        if [[ $((elapsed % 5)) -eq 0 ]]; then
            printf "." >&2
        fi
    done

    printf "\n" >&2
    log_error "Fulcrum did not start within ${timeout}s"
    return 1
}

# Verify recovery
verify_recovery() {
    local start_time_after
    local restart_count

    log_info "Verifying container recovery..."

    # Check if container is running
    if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        log_error "Container is not running"
        log_info "Container status:"
        docker ps -a --filter "name=${CONTAINER_NAME}" --format 'table {{.Names}}\t{{.Status}}\t{{.State}}'
        return 1
    fi

    # Get new start time
    start_time_after=$(get_container_start_time)
    log_info "Container start time after crash: $start_time_after"

    # Get restart count
    restart_count=$(docker inspect --format '{{.RestartCount}}' "$CONTAINER_NAME")
    log_info "Container restart count: $restart_count"

    # Check if Fulcrum is running
    if ! wait_for_fulcrum; then
        return 1
    fi

    # Show current state
    log_info "Container processes:"
    docker exec "$CONTAINER_NAME" ps aux

    log_success "Recovery verification complete"
    return 0
}

# Check SSL certificates
check_ssl_certs() {
    log_info "Checking SSL certificates preservation..."

    local cert_path="/etc/letsencrypt/live"

    if docker exec "$CONTAINER_NAME" test -d "$cert_path" 2>/dev/null; then
        log_success "SSL certificate directory exists: $cert_path"

        local cert_files
        cert_files=$(docker exec "$CONTAINER_NAME" find "$cert_path" -type f 2>/dev/null | wc -l)
        log_info "Certificate files found: $cert_files"
    else
        log_info "No SSL certificates directory found (may not be configured)"
    fi
}

# Check database
check_database() {
    log_info "Checking database status..."

    local db_path="/fulcrum/db"

    if docker exec "$CONTAINER_NAME" test -d "$db_path" 2>/dev/null; then
        log_success "Database directory exists: $db_path"

        # Check for lock files (indicating clean shutdown/restart)
        if docker exec "$CONTAINER_NAME" find "$db_path" -name "LOCK" 2>/dev/null | grep -q .; then
            log_info "Database LOCK files present (normal for running Fulcrum)"
        fi
    else
        log_warn "Database directory not found"
    fi
}

# Main execution
main() {
    parse_args "$@"

    printf "\n"
    log_info "=== Container Crash Simulation ==="
    log_info "Container: $CONTAINER_NAME"
    log_info "Method: $CRASH_METHOD"
    log_info "Wait time: ${WAIT_TIME}s"
    printf "\n"

    validate_prerequisites
    check_restart_policy

    printf "\n"
    log_info "Starting crash test..."
    crash_container

    # Wait for container to exit (may not happen with some methods)
    wait_for_exit || log_warn "Container did not exit cleanly"

    # Wait for automatic restart
    if ! wait_for_restart; then
        log_error "Container did not restart automatically"
        log_info "Manual recovery required: docker start $CONTAINER_NAME"
        exit 3
    fi

    printf "\n"
    if verify_recovery; then
        printf "\n"
        check_ssl_certs
        check_database

        printf "\n"
        log_success "=== Container crash recovery test PASSED ==="
        log_info "Container restarted successfully via Docker restart policy"
        exit 0
    else
        printf "\n"
        log_error "=== Container crash recovery test FAILED ==="
        log_warn "Container restarted but Fulcrum did not start properly"
        log_info "Check container logs: docker logs $CONTAINER_NAME"
        exit 3
    fi
}

# Trap errors for debugging
trap 'log_error "Script failed at line $LINENO"' ERR

main "$@"
