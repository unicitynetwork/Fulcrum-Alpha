#!/usr/bin/env bash
#
# test-recovery.sh - Comprehensive crash recovery testing suite
#
# Tests both process-level and container-level crash recovery scenarios
# for Fulcrum SPV server running in Docker.
#
# Usage:
#   ./test-recovery.sh [OPTIONS]
#
# Options:
#   -c, --container NAME     Container name (default: fulcrum-alpha)
#   -s, --skip-process      Skip process crash test
#   -k, --skip-container    Skip container crash test
#   -p, --ports PORTS       Comma-separated list of ports to test
#   -w, --wait SECONDS      Wait time between tests (default: 15)
#   -v, --verbose           Verbose output
#   -h, --help              Show this help message
#
# Exit codes:
#   0 - All tests passed
#   1 - General error
#   2 - Prerequisites failed
#   3 - Process crash test failed
#   4 - Container crash test failed

set -Eeuo pipefail

# Script metadata
readonly SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

# Default configuration
CONTAINER_NAME="fulcrum-alpha"
SKIP_PROCESS_TEST=false
SKIP_CONTAINER_TEST=false
PORTS="50001,50002,50003,50004"
WAIT_TIME=15
VERBOSE=false

# Test results tracking
declare -A TEST_RESULTS=(
    [prerequisites]=pending
    [process_crash]=pending
    [container_crash]=pending
    [ssl_preservation]=pending
    [port_connectivity]=pending
)

# Color output helpers
if [[ -t 1 ]]; then
    readonly RED='\033[0;31m'
    readonly GREEN='\033[0;32m'
    readonly YELLOW='\033[1;33m'
    readonly BLUE='\033[0;34m'
    readonly CYAN='\033[0;36m'
    readonly BOLD='\033[1m'
    readonly NC='\033[0m' # No Color
else
    readonly RED=''
    readonly GREEN=''
    readonly YELLOW=''
    readonly BLUE=''
    readonly CYAN=''
    readonly BOLD=''
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

log_verbose() {
    if [[ $VERBOSE == true ]]; then
        printf "${CYAN}[DEBUG]${NC} %s\n" "$*" >&2
    fi
}

log_header() {
    printf "\n${BOLD}${BLUE}=== %s ===${NC}\n\n" "$*" >&2
}

# Usage information
usage() {
    cat <<EOF
Usage: $SCRIPT_NAME [OPTIONS]

Comprehensive crash recovery testing for Fulcrum Docker deployment.
Tests process crash, container crash, SSL preservation, and connectivity.

Options:
    -c, --container NAME     Container name
                            Default: fulcrum-alpha
    -s, --skip-process      Skip process crash test
    -k, --skip-container    Skip container crash test
    -p, --ports PORTS       Comma-separated list of ports to test
                            Default: 50001,50002,50003,50004
    -w, --wait SECONDS      Wait time between tests
                            Default: 15
    -v, --verbose           Enable verbose output
    -h, --help              Show this help message

Test scenarios:
    1. Process crash    - Kill Fulcrum process, verify supervisor restart
    2. Container crash  - Kill container, verify Docker auto-restart
    3. SSL preservation - Verify certificates survive restarts
    4. Port connectivity - Verify all ports responding after recovery

Examples:
    # Run all tests
    $SCRIPT_NAME

    # Run only container crash test
    $SCRIPT_NAME --skip-process

    # Test custom ports with verbose output
    $SCRIPT_NAME --ports 60001,60002 --verbose

    # Test specific container
    $SCRIPT_NAME --container my-fulcrum --wait 20

Exit codes:
    0 - All tests passed
    1 - General error
    2 - Prerequisites failed
    3 - Process crash test failed
    4 - Container crash test failed

EOF
}

# Parse command-line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -c|--container)
                CONTAINER_NAME="$2"
                shift 2
                ;;
            -s|--skip-process)
                SKIP_PROCESS_TEST=true
                shift
                ;;
            -k|--skip-container)
                SKIP_CONTAINER_TEST=true
                shift
                ;;
            -p|--ports)
                PORTS="$2"
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
            -v|--verbose)
                VERBOSE=true
                shift
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

    # Validate that at least one test is enabled
    if [[ $SKIP_PROCESS_TEST == true && $SKIP_CONTAINER_TEST == true ]]; then
        log_error "Cannot skip both process and container tests"
        exit 1
    fi
}

# Validate prerequisites
validate_prerequisites() {
    log_header "Validating Prerequisites"

    local failed=false

    # Check docker
    if ! command -v docker &>/dev/null; then
        log_error "docker command not found"
        failed=true
    else
        log_success "docker: $(docker --version)"
    fi

    # Check nc (netcat) for port testing
    if ! command -v nc &>/dev/null && ! command -v netcat &>/dev/null; then
        log_warn "nc/netcat not found - port connectivity tests will be limited"
    else
        log_success "nc/netcat: available"
    fi

    # Check if container exists
    if ! docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        log_error "Container '$CONTAINER_NAME' not found"
        failed=true
    else
        log_success "Container: $CONTAINER_NAME found"
    fi

    # Check if container is running
    if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        log_error "Container '$CONTAINER_NAME' is not running"
        failed=true
    else
        log_success "Container: $CONTAINER_NAME is running"
    fi

    # Check if crash scripts exist
    if [[ ! -x "${SCRIPT_DIR}/crash-fulcrum-process.sh" ]]; then
        log_warn "crash-fulcrum-process.sh not found or not executable"
        SKIP_PROCESS_TEST=true
    else
        log_success "crash-fulcrum-process.sh: available"
    fi

    if [[ ! -x "${SCRIPT_DIR}/crash-container.sh" ]]; then
        log_warn "crash-container.sh not found or not executable"
        SKIP_CONTAINER_TEST=true
    else
        log_success "crash-container.sh: available"
    fi

    # Check restart policy
    local restart_policy
    restart_policy=$(docker inspect --format '{{.HostConfig.RestartPolicy.Name}}' "$CONTAINER_NAME" 2>/dev/null || echo "unknown")
    log_info "Restart policy: $restart_policy"

    if [[ $restart_policy != "always" && $restart_policy != "unless-stopped" ]]; then
        log_warn "Container restart policy is '$restart_policy' (expected 'always')"
    fi

    if [[ $failed == true ]]; then
        TEST_RESULTS[prerequisites]=failed
        log_error "Prerequisites validation failed"
        return 1
    fi

    TEST_RESULTS[prerequisites]=passed
    log_success "All prerequisites validated"
    return 0
}

# Get container host IP
get_container_host() {
    # Try to get the host IP that can reach the container
    local host_ip
    host_ip=$(docker inspect --format '{{range.NetworkSettings.Networks}}{{.Gateway}}{{end}}' "$CONTAINER_NAME" 2>/dev/null || echo "localhost")
    printf "%s" "${host_ip:-localhost}"
}

# Test port connectivity
test_port_connectivity() {
    local host="$1"
    local port="$2"
    local timeout="${3:-2}"

    log_verbose "Testing connectivity to $host:$port (timeout: ${timeout}s)..."

    # Try with timeout and nc
    if command -v timeout &>/dev/null && command -v nc &>/dev/null; then
        if timeout "$timeout" nc -z "$host" "$port" &>/dev/null; then
            return 0
        fi
    fi

    # Fallback to bash TCP test
    if (timeout "$timeout" bash -c "exec 3<>/dev/tcp/$host/$port" 2>/dev/null); then
        exec 3<&- 3>&-
        return 0
    fi

    return 1
}

# Verify all ports are responding
verify_ports() {
    log_info "Verifying port connectivity..."

    local host
    host=$(get_container_host)
    log_verbose "Testing ports on host: $host"

    local all_ok=true
    local -a port_array

    # Convert comma-separated ports to array
    IFS=',' read -ra port_array <<< "$PORTS"

    for port in "${port_array[@]}"; do
        # Trim whitespace
        port=$(echo "$port" | tr -d ' ')

        if test_port_connectivity "$host" "$port" 3; then
            log_success "Port $port is responding"
        else
            log_warn "Port $port is NOT responding"
            all_ok=false
        fi
    done

    if [[ $all_ok == true ]]; then
        TEST_RESULTS[port_connectivity]=passed
        log_success "All ports responding"
        return 0
    else
        TEST_RESULTS[port_connectivity]=failed
        log_warn "Some ports not responding"
        return 1
    fi
}

# Check SSL certificates
check_ssl_certificates() {
    log_info "Checking SSL certificate preservation..."

    local cert_paths=(
        "/etc/letsencrypt/live"
        "/ssl"
        "/certs"
    )

    local found=false

    for cert_path in "${cert_paths[@]}"; do
        if docker exec "$CONTAINER_NAME" test -d "$cert_path" 2>/dev/null; then
            log_success "SSL directory found: $cert_path"

            local cert_count
            cert_count=$(docker exec "$CONTAINER_NAME" find "$cert_path" -type f 2>/dev/null | wc -l)

            if [[ $cert_count -gt 0 ]]; then
                log_success "Certificate files: $cert_count"
                TEST_RESULTS[ssl_preservation]=passed
                found=true
                break
            fi
        fi
    done

    if [[ $found == false ]]; then
        log_info "No SSL certificates found (SSL may not be configured)"
        TEST_RESULTS[ssl_preservation]=skipped
    fi
}

# Verify Fulcrum is running
verify_fulcrum_running() {
    log_info "Verifying Fulcrum process..."

    if docker exec "$CONTAINER_NAME" pgrep -x Fulcrum &>/dev/null; then
        local pid
        pid=$(docker exec "$CONTAINER_NAME" pgrep -x Fulcrum)
        log_success "Fulcrum is running (PID: $pid)"
        return 0
    else
        log_error "Fulcrum is NOT running"
        return 1
    fi
}

# Get container uptime
get_container_uptime() {
    local started_at
    started_at=$(docker inspect --format '{{.State.StartedAt}}' "$CONTAINER_NAME")
    printf "%s" "$started_at"
}

# Test process crash recovery
test_process_crash() {
    log_header "Test 1: Process Crash Recovery"

    if [[ $SKIP_PROCESS_TEST == true ]]; then
        log_warn "Process crash test skipped"
        TEST_RESULTS[process_crash]=skipped
        return 0
    fi

    local uptime_before
    uptime_before=$(get_container_uptime)
    log_info "Container uptime before: $uptime_before"

    # Run process crash script
    if "${SCRIPT_DIR}/crash-fulcrum-process.sh" --container "$CONTAINER_NAME" --wait 10; then
        log_success "Process crash recovery successful"

        # Verify container didn't restart
        local uptime_after
        uptime_after=$(get_container_uptime)

        if [[ $uptime_before == "$uptime_after" ]]; then
            log_success "Container did not restart (process supervisor working)"
            TEST_RESULTS[process_crash]=passed
            return 0
        else
            log_warn "Container restarted (Fulcrum may be running as PID 1)"
            TEST_RESULTS[process_crash]=warning
            return 0
        fi
    else
        log_error "Process crash recovery failed"
        TEST_RESULTS[process_crash]=failed
        return 1
    fi
}

# Test container crash recovery
test_container_crash() {
    log_header "Test 2: Container Crash Recovery"

    if [[ $SKIP_CONTAINER_TEST == true ]]; then
        log_warn "Container crash test skipped"
        TEST_RESULTS[container_crash]=skipped
        return 0
    fi

    local uptime_before
    uptime_before=$(get_container_uptime)
    log_info "Container uptime before: $uptime_before"

    # Run container crash script
    if "${SCRIPT_DIR}/crash-container.sh" --container "$CONTAINER_NAME" --method pid1-kill --wait "$WAIT_TIME"; then
        log_success "Container crash recovery successful"

        # Verify container restarted
        local uptime_after
        uptime_after=$(get_container_uptime)

        if [[ $uptime_before != "$uptime_after" ]]; then
            log_success "Container restarted with new uptime"
            TEST_RESULTS[container_crash]=passed
            return 0
        else
            log_warn "Container uptime unchanged (unexpected)"
            TEST_RESULTS[container_crash]=warning
            return 0
        fi
    else
        log_error "Container crash recovery failed"
        TEST_RESULTS[container_crash]=failed
        return 1
    fi
}

# Print test summary
print_summary() {
    log_header "Test Summary"

    printf "${BOLD}%-25s %s${NC}\n" "Test" "Result"
    printf "%s\n" "----------------------------------------"

    local all_passed=true

    for test_name in "${!TEST_RESULTS[@]}"; do
        local result="${TEST_RESULTS[$test_name]}"
        local color=""
        local symbol=""

        case $result in
            passed)
                color="$GREEN"
                symbol="✓ PASS"
                ;;
            failed)
                color="$RED"
                symbol="✗ FAIL"
                all_passed=false
                ;;
            warning)
                color="$YELLOW"
                symbol="⚠ WARN"
                ;;
            skipped)
                color="$CYAN"
                symbol="○ SKIP"
                ;;
            pending)
                color="$YELLOW"
                symbol="- PENDING"
                ;;
        esac

        printf "%-25s ${color}%s${NC}\n" "$test_name" "$symbol"
    done

    printf "\n"

    if [[ $all_passed == true ]]; then
        log_success "All tests passed!"
        return 0
    else
        log_error "Some tests failed"
        return 1
    fi
}

# Cleanup and wait between tests
wait_between_tests() {
    local wait_time="${1:-$WAIT_TIME}"
    log_info "Waiting ${wait_time}s for system stabilization..."
    sleep "$wait_time"
}

# Main execution
main() {
    parse_args "$@"

    printf "\n"
    printf "${BOLD}${BLUE}╔═══════════════════════════════════════════════╗${NC}\n"
    printf "${BOLD}${BLUE}║  Fulcrum Crash Recovery Test Suite           ║${NC}\n"
    printf "${BOLD}${BLUE}╚═══════════════════════════════════════════════╝${NC}\n"
    printf "\n"

    log_info "Container: $CONTAINER_NAME"
    log_info "Test ports: $PORTS"
    log_info "Wait time: ${WAIT_TIME}s"
    printf "\n"

    # Prerequisites
    if ! validate_prerequisites; then
        log_error "Prerequisites failed"
        exit 2
    fi

    # Initial state verification
    log_header "Initial State Verification"
    verify_fulcrum_running || log_warn "Fulcrum not running initially"
    check_ssl_certificates
    verify_ports || log_warn "Some ports not responding initially"

    # Test 1: Process crash
    if [[ $SKIP_PROCESS_TEST == false ]]; then
        wait_between_tests
        if ! test_process_crash; then
            log_error "Process crash test failed"
            print_summary
            exit 3
        fi

        # Verify state after process crash
        log_info "Post-test verification..."
        verify_fulcrum_running
        check_ssl_certificates
        verify_ports
    fi

    # Test 2: Container crash
    if [[ $SKIP_CONTAINER_TEST == false ]]; then
        wait_between_tests
        if ! test_container_crash; then
            log_error "Container crash test failed"
            print_summary
            exit 4
        fi

        # Verify state after container crash
        log_info "Post-test verification..."
        verify_fulcrum_running
        check_ssl_certificates
        verify_ports
    fi

    # Final summary
    if print_summary; then
        exit 0
    else
        exit 1
    fi
}

# Trap errors for debugging
trap 'log_error "Script failed at line $LINENO"' ERR

main "$@"
