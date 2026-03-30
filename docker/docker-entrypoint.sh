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
    find /data -maxdepth 1 -type f -not -name "*.conf" -not -name "*.crt" -not -name "*.key" -not -name "*.pem" -delete 2>/dev/null || true
    echo "[entrypoint] Database cleaned"
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
    if nc -z "${RPC_HOST:-alpha-node}" "${RPC_PORT:-8589}" 2>/dev/null; then
        echo "[entrypoint] Detected Alpha node, waiting for it to be ready..."
        while ! nc -z "${RPC_HOST:-alpha-node}" "${RPC_PORT:-8589}" 2>/dev/null; do
            echo "[entrypoint] Alpha node not ready, waiting..."
            sleep 5
        done
        echo "[entrypoint] Alpha node is ready!"
    fi
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

        # Start Fulcrum in background so we can track its PID
        Fulcrum "$config_file" "${extra_args[@]}" &
        FULCRUM_PID=$!
        echo "  Fulcrum started with PID $FULCRUM_PID"

        # Wait for Fulcrum to exit
        wait $FULCRUM_PID
        EXIT_CODE=$?
        FULCRUM_PID=""

        # Check if shutdown was requested
        if [ $SHUTDOWN_REQUESTED -eq 1 ]; then
            echo "  Shutdown was requested, not restarting"
            break
        fi

        # Check for SSL renewal restart (graceful restart, not a crash)
        if [ -f /tmp/.ssl-renewal-restart ]; then
            echo "[entrypoint] SSL renewal restart detected, not counting as crash"
            continue
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

        # Calculate backoff delay
        local delay
        delay=$(calculate_backoff $RESTART_COUNT)
        echo "  Cleaning database before restart..."
        clean_database

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

# Step 1: Clean database on every start to prevent corruption issues
echo "[entrypoint] Cleaning database on startup to ensure fresh state..."
clean_database

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
