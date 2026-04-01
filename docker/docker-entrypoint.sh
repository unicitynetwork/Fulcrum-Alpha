#!/bin/bash
set -e

# Global variables for process management
FULCRUM_PID=""
SHUTDOWN_REQUESTED=0
RESTART_COUNT=0
MAX_RESTARTS=10
BACKOFF_BASE=5
BACKOFF_MAX=300
RESTART_WINDOW=3600  # Reset restart count if stable for 1 hour
LAST_RESTART_TIME=0

# ---------------------------------------------------------------------------
# Signal handler for graceful shutdown
# ---------------------------------------------------------------------------
handle_signal() {
    local signal=$1
    echo "[entrypoint] Received $signal signal, initiating graceful shutdown..."
    SHUTDOWN_REQUESTED=1

    # Deregister from HAProxy if we were registered
    if [ -n "${SSL_DOMAIN:-}" ] && [ -n "${HAPROXY_HOST:-}" ]; then
        echo "[entrypoint] Deregistering from HAProxy..."
        haproxy-register unregister 2>/dev/null || true
    fi

    # Stop the HTTP reverse proxy (ssl-manager)
    if [ -f /tmp/.ssl-http-proxy.pid ]; then
        local proxy_pid
        proxy_pid=$(cat /tmp/.ssl-http-proxy.pid 2>/dev/null || true)
        if [ -n "$proxy_pid" ] && kill -0 "$proxy_pid" 2>/dev/null; then
            kill "$proxy_pid" 2>/dev/null || true
        fi
    fi

    # Stop the renewal loop
    if [ -f /tmp/.ssl-renew.pid ]; then
        local renew_pid
        renew_pid=$(cat /tmp/.ssl-renew.pid 2>/dev/null || true)
        if [ -n "$renew_pid" ] && kill -0 "$renew_pid" 2>/dev/null; then
            kill "$renew_pid" 2>/dev/null || true
        fi
    fi

    # Forward signal to Fulcrum
    if [ -n "$FULCRUM_PID" ] && kill -0 "$FULCRUM_PID" 2>/dev/null; then
        echo "[entrypoint] Forwarding $signal to Fulcrum (PID $FULCRUM_PID)..."
        kill -"$signal" "$FULCRUM_PID" 2>/dev/null || true

        # Wait for Fulcrum to exit gracefully (up to 30 seconds)
        local wait_count=0
        while kill -0 "$FULCRUM_PID" 2>/dev/null && [ $wait_count -lt 30 ]; do
            sleep 1
            ((wait_count++))
        done

        if kill -0 "$FULCRUM_PID" 2>/dev/null; then
            echo "[entrypoint] Fulcrum did not exit gracefully, sending SIGKILL..."
            kill -9 "$FULCRUM_PID" 2>/dev/null || true
        fi
    fi

    echo "[entrypoint] Graceful shutdown complete"
    exit 0
}

# Set up signal handlers
trap 'handle_signal TERM' SIGTERM
trap 'handle_signal INT' SIGINT

# ---------------------------------------------------------------------------
# Calculate exponential backoff delay
# ---------------------------------------------------------------------------
calculate_backoff() {
    local count=$1
    local delay=$((BACKOFF_BASE * (2 ** (count - 1))))
    if [ $delay -gt $BACKOFF_MAX ]; then
        delay=$BACKOFF_MAX
    fi
    echo $delay
}

# ---------------------------------------------------------------------------
# Check if we should reset restart count (been stable for RESTART_WINDOW)
# ---------------------------------------------------------------------------
check_restart_window() {
    local now
    now=$(date +%s)
    if [ $LAST_RESTART_TIME -gt 0 ]; then
        local elapsed=$((now - LAST_RESTART_TIME))
        if [ $elapsed -gt $RESTART_WINDOW ]; then
            echo "[entrypoint] Fulcrum has been stable for $elapsed seconds, resetting restart count"
            RESTART_COUNT=0
        fi
    fi
}

# ---------------------------------------------------------------------------
# Function to clean database (removes all database subdirectories while
# preserving config and SSL files)
# ---------------------------------------------------------------------------
clean_database() {
    echo "[entrypoint] Cleaning database..."
    # Remove all RocksDB subdirectories
    for subdir in meta blkinfo utxoset scripthash_history scripthash_unspent undo txhash2txnum rpa; do
        if [ -d "/data/$subdir" ]; then
            echo "  Removing $subdir..."
            rm -rf "/data/$subdir"
        fi
    done
    # Remove any other files that aren't config or SSL certificates
    find /data -maxdepth 1 -type f -not -name "*.conf" -not -name "*.crt" -not -name "*.key" -not -name "*.pem" -not -name ".crash_state" -delete 2>/dev/null || true
    echo "[entrypoint] Database cleaned"
}

# ---------------------------------------------------------------------------
# Crash state persistence (survives container restarts via /data volume)
# ---------------------------------------------------------------------------
CRASH_STATE_FILE="/data/.crash_state"

# DB corruption patterns from Fulcrum source code (Storage.cpp).
# These are anchored to Fulcrum's own log format to avoid false positives
# from quoted error messages relayed from bitcoind or other services.
# Fulcrum logs as: [timestamp] <Component> message  or  [timestamp] message
DB_CORRUPTION_PATTERNS=(
    "DatabaseFormatError"
    "Delete the datadir and resynch"
    "database has been corrupted"
    "database may be corrupted"
    "Database corruption likely"
    "Possible databaase corruption"
    "Failed to read.*from db.*may be corrupted"
    "bad record"
    "Empty db data"
    "Missing data for txHash"
    "Extra bytes at the end of data"
)

# Check if Fulcrum's output indicates database corruption
detect_db_corruption() {
    local log_file="$1"
    for pattern in "${DB_CORRUPTION_PATTERNS[@]}"; do
        if grep -qiE "$pattern" "$log_file" 2>/dev/null; then
            echo "[entrypoint] DB corruption detected: $(grep -iE "$pattern" "$log_file" | head -1)"
            return 0  # Corruption found
        fi
    done
    return 1  # No corruption
}

# Record a crash event to persistent state
record_crash() {
    local exit_code="$1"
    local corruption_detected="$2"
    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    # Count consecutive crashes since last RECOVERY or start of file
    local consecutive_crashes=0
    if [ -f "$CRASH_STATE_FILE" ]; then
        # Count CRASH lines after the last RECOVERY line
        consecutive_crashes=$(sed -n '/^RECOVERY:/=' "$CRASH_STATE_FILE" | tail -1)
        if [ -n "$consecutive_crashes" ]; then
            consecutive_crashes=$(tail -n +"$consecutive_crashes" "$CRASH_STATE_FILE" | grep -c "^CRASH:" 2>/dev/null || echo 0)
        else
            consecutive_crashes=$(grep -c "^CRASH:" "$CRASH_STATE_FILE" 2>/dev/null || echo 0)
        fi
    fi
    consecutive_crashes=$((consecutive_crashes + 1))

    # Cap crash state file to last 50 lines to prevent unbounded growth
    if [ -f "$CRASH_STATE_FILE" ] && [ "$(wc -l < "$CRASH_STATE_FILE")" -gt 50 ]; then
        tail -50 "$CRASH_STATE_FILE" > "${CRASH_STATE_FILE}.tmp" && mv "${CRASH_STATE_FILE}.tmp" "$CRASH_STATE_FILE"
    fi

    echo "CRASH:${timestamp}:exit=${exit_code}:corruption=${corruption_detected}:consecutive=${consecutive_crashes}" >> "$CRASH_STATE_FILE"
    echo "[entrypoint] Crash recorded (consecutive: ${consecutive_crashes}, corruption: ${corruption_detected})"
}

# Clear crash state (called after successful stable run)
clear_crash_state() {
    if [ -f "$CRASH_STATE_FILE" ]; then
        rm -f "$CRASH_STATE_FILE"
        echo "[entrypoint] Crash state cleared (Fulcrum is stable)"
    fi
}

# Check if previous run ended in corruption (recovery mode)
check_recovery_mode() {
    if [ ! -f "$CRASH_STATE_FILE" ]; then
        return 1  # No crash state, normal startup
    fi

    local last_line
    last_line=$(tail -1 "$CRASH_STATE_FILE" 2>/dev/null)

    if echo "$last_line" | grep -q "corruption=yes"; then
        local consecutive
        consecutive=$(echo "$last_line" | grep -oP 'consecutive=\K[0-9]+')
        echo "[entrypoint] RECOVERY MODE: Previous crash was due to DB corruption (crash #${consecutive})"
        echo "[entrypoint] Cleaning database for fresh resync..."
        clean_database
        # Keep the crash state file for audit trail but mark recovery started
        echo "RECOVERY:$(date -u +"%Y-%m-%dT%H:%M:%SZ"):database_cleaned" >> "$CRASH_STATE_FILE"
        return 0  # Recovery mode activated
    fi

    return 1  # Previous crash was not corruption
}

# ---------------------------------------------------------------------------
# Generate fulcrum.conf from environment variables
# ---------------------------------------------------------------------------
generate_fulcrum_config() {
    local config_file="/data/fulcrum.conf"

    cat > "$config_file" << CONF
# Auto-generated Fulcrum configuration
bitcoind = ${RPC_HOST:-alpha-node}:${RPC_PORT:-8589}
rpcuser = ${RPC_USER:-user}
rpcpassword = ${RPC_PASS:-password}
datadir = /data
coin = alpha

# TCP Electrum
tcp = 0.0.0.0:50001

# WebSocket
ws = 0.0.0.0:50003
CONF

    # Add SSL if certs available
    if [ -n "${SSL_CERT_FILE:-}" ] && [ -f "${SSL_CERT_FILE}" ]; then
        cat >> "$config_file" << CONF

# SSL Electrum
ssl = 0.0.0.0:50002
cert = ${SSL_CERT_FILE}
key = ${SSL_KEY_FILE}

# WebSocket Secure
wss = 0.0.0.0:50004
wss_cert = ${SSL_CERT_FILE}
wss_key = ${SSL_KEY_FILE}
CONF
    fi

    chmod 600 "$config_file"
    echo "[entrypoint] Generated fulcrum.conf"
}

# ---------------------------------------------------------------------------
# Wait for Alpha node to be ready (if on same network)
# ---------------------------------------------------------------------------
wait_for_alpha() {
    echo "[entrypoint] Waiting for Alpha node at ${RPC_HOST:-alpha-node}:${RPC_PORT:-8589}..."
    local max_wait=120
    local waited=0
    while ! nc -z "${RPC_HOST:-alpha-node}" "${RPC_PORT:-8589}" 2>/dev/null; do
        if [ "$waited" -ge "$max_wait" ]; then
            echo "[entrypoint] WARNING: Alpha node not reachable after ${max_wait}s, proceeding anyway..."
            return 0
        fi
        echo "[entrypoint] Alpha node not ready, waiting... ($waited/${max_wait}s)"
        sleep 5
        waited=$((waited + 5))
    done
    echo "[entrypoint] Alpha node is ready!"
}

# ---------------------------------------------------------------------------
# Supervisor loop for Fulcrum - restarts on crash with database cleanup
# ---------------------------------------------------------------------------
run_fulcrum_supervised() {
    local config_file="$1"
    shift
    local extra_args=("$@")

    echo "[entrypoint] Starting Fulcrum supervisor loop..."
    echo "  Config: $config_file"
    echo "  Max restarts: $MAX_RESTARTS within $RESTART_WINDOW seconds"
    echo "  Backoff: ${BACKOFF_BASE}s base, ${BACKOFF_MAX}s max"

    while [ $SHUTDOWN_REQUESTED -eq 0 ]; do
        # Check for SSL renewal restart marker
        if [ -f /tmp/.ssl-renewal-restart ]; then
            echo "[entrypoint] SSL certificate renewed -- restarting Fulcrum to load new cert"
            rm -f /tmp/.ssl-renewal-restart

            # Re-source SSL env to pick up any path changes
            if [ -f /tmp/.ssl-env ]; then
                . /tmp/.ssl-env
            fi

            # Regenerate config with new cert paths
            generate_fulcrum_config
        fi

        # Check if we should reset restart count
        check_restart_window

        # Check if we've exceeded max restarts
        if [ $RESTART_COUNT -ge $MAX_RESTARTS ]; then
            echo "[entrypoint] Maximum restart count ($MAX_RESTARTS) exceeded within restart window"
            echo "  This indicates a persistent crash loop. Container will exit."
            echo "  Please investigate logs and fix the underlying issue."
            exit 1
        fi

        echo "[entrypoint] Starting Fulcrum (attempt $((RESTART_COUNT + 1))/$MAX_RESTARTS)..."

        # Start Fulcrum in background. Output goes to stdout (docker logs) AND
        # a size-limited crash log for corruption detection after exit.
        # We use a named pipe + background tail to avoid orphaned tee processes
        # and unbounded file growth.
        rm -f /tmp/.fulcrum-output
        Fulcrum "$config_file" "${extra_args[@]}" &
        FULCRUM_PID=$!
        FULCRUM_START_TIME=$(date +%s)
        echo "  Fulcrum started with PID $FULCRUM_PID"

        # Wait for Fulcrum to exit. Disable set -e so non-zero exit codes
        # don't kill the supervisor loop (this is the CRASH RECOVERY path).
        set +e
        wait $FULCRUM_PID
        EXIT_CODE=$?
        set -e
        FULCRUM_PID=""

        # Capture last 200 lines of container output for corruption detection.
        # Done AFTER Fulcrum exits — no orphaned processes, no unbounded growth.
        # Uses /proc/1/fd/1 (entrypoint's stdout = docker logs).
        # Fallback: check the Docker log file directly if available.
        {
            tail -200 /proc/1/fd/1 2>/dev/null || \
            docker logs "$HOSTNAME" 2>&1 | tail -200 2>/dev/null || \
            true
        } > /tmp/.fulcrum-output 2>/dev/null
        FULCRUM_RUN_DURATION=$(( $(date +%s) - FULCRUM_START_TIME ))

        # If Fulcrum ran for more than RESTART_WINDOW, it was stable — clear crash state
        if [ "$FULCRUM_RUN_DURATION" -gt "$RESTART_WINDOW" ]; then
            clear_crash_state
        fi

        # Check for SSL renewal restart FIRST (before shutdown check).
        # The deploy hook sends SIGTERM (sets SHUTDOWN_REQUESTED=1) but also
        # touches the marker file. We must detect this BEFORE breaking out.
        if [ -f /tmp/.ssl-renewal-restart ]; then
            rm -f /tmp/.ssl-renewal-restart
            echo "[entrypoint] SSL certificate renewed — restarting Fulcrum to load new cert"
            SHUTDOWN_REQUESTED=0  # Override — this is a restart, not a shutdown
            continue
        fi

        # Check if shutdown was requested (container stop, not renewal)
        if [ $SHUTDOWN_REQUESTED -eq 1 ]; then
            echo "  Shutdown was requested, not restarting"
            break
        fi

        # Fulcrum exited unexpectedly
        LAST_RESTART_TIME=$(date +%s)
        ((RESTART_COUNT++))

        if [ $EXIT_CODE -eq 0 ]; then
            echo "[entrypoint] Fulcrum exited with code 0 (clean exit) -- not restarting"
            echo "  If this was unexpected, check the logs for shutdown reason"
            break
        fi

        echo "[entrypoint] Fulcrum crashed with exit code $EXIT_CODE"
        echo "  Restart count: $RESTART_COUNT/$MAX_RESTARTS"

        # Check for DB corruption in Fulcrum's captured output
        local corruption="no"
        if detect_db_corruption /tmp/.fulcrum-output; then
            corruption="yes"
            echo "[entrypoint] DATABASE CORRUPTION DETECTED — will clean and resync"
            clean_database
        else
            echo "[entrypoint] No DB corruption detected — retrying without database wipe"
        fi

        # Record crash to persistent state
        record_crash "$EXIT_CODE" "$corruption"

        # Calculate backoff delay
        local delay
        delay=$(calculate_backoff $RESTART_COUNT)
        echo "  Waiting ${delay}s before restart (exponential backoff)..."

        # Sleep with interrupt check for graceful shutdown during backoff
        local slept=0
        while [ $slept -lt $delay ] && [ $SHUTDOWN_REQUESTED -eq 0 ]; do
            sleep 1
            ((slept++))
        done

        if [ $SHUTDOWN_REQUESTED -eq 1 ]; then
            echo "  Shutdown requested during backoff, exiting..."
            break
        fi

        echo "  Restarting Fulcrum..."
    done

    echo "[entrypoint] Fulcrum supervisor loop exited"
}

# ===========================================================================
# Main execution
# ===========================================================================

# Step 1: Check for recovery mode (previous crash was DB corruption)
if check_recovery_mode; then
    echo "[entrypoint] Database cleaned — will resync from scratch"
elif [ "${CLEAN_DB_ON_START:-false}" = "true" ]; then
    echo "[entrypoint] CLEAN_DB_ON_START is set, cleaning database..."
    clean_database
fi

# Step 2: Run ssl-setup from ssl-manager base image
echo "[entrypoint] Running ssl-setup..."
ssl_setup_exit=0
/usr/local/bin/ssl-setup || ssl_setup_exit=$?

if [ $ssl_setup_exit -ne 0 ]; then
    if [ "${SSL_REQUIRED:-true}" = "true" ]; then
        echo "[entrypoint] ERROR: ssl-setup failed (exit code $ssl_setup_exit) and SSL_REQUIRED=true"
        echo "[entrypoint] Container will not start without SSL. Set SSL_REQUIRED=false to allow TCP-only fallback."
        exit $ssl_setup_exit
    else
        echo "[entrypoint] WARNING: ssl-setup failed (exit code $ssl_setup_exit) but SSL_REQUIRED=false"
        echo "[entrypoint] Continuing without SSL -- only TCP and WS ports will be available"
    fi
fi

# Step 3: Source SSL environment if ssl-setup wrote it
if [ -f /tmp/.ssl-env ]; then
    . /tmp/.ssl-env
    echo "[entrypoint] SSL configured: cert=${SSL_CERT_FILE}, key=${SSL_KEY_FILE}"

    # Log certificate expiry
    if [ -f "${SSL_CERT_FILE}" ]; then
        EXPIRY=$(openssl x509 -enddate -noout -in "${SSL_CERT_FILE}" | cut -d= -f2)
        echo "[entrypoint] SSL certificate expires: ${EXPIRY}"
    fi

    # Warn if using self-signed certificate
    if [ "${SSL_TEST_MODE:-}" = "true" ]; then
        echo "[entrypoint] WARNING: SSL_TEST_MODE is active -- using self-signed certificate"
        echo "[entrypoint] WARNING: This is NOT suitable for production. Clients will reject this certificate."
    fi
else
    echo "[entrypoint] No SSL certificates configured -- running in TCP-only mode"
fi

# Step 4: Generate fulcrum.conf from environment variables
generate_fulcrum_config

# Step 5: Wait for Alpha node if available
wait_for_alpha

# Step 6: Start Fulcrum
CONFIG_FILE="/data/fulcrum.conf"

if [ "${1:-}" = "Fulcrum" ]; then
    # Run Fulcrum with supervisor loop (restarts on crash)
    run_fulcrum_supervised "$CONFIG_FILE" "${@:2}"
elif [ "${1:-}" = "FulcrumAdmin" ]; then
    echo "[entrypoint] Running FulcrumAdmin..."
    exec FulcrumAdmin "${@:2}"
else
    # Assume any other command is to be executed directly
    exec "$@"
fi
