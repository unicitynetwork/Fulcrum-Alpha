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

# Signal handler for graceful shutdown
handle_signal() {
    local signal=$1
    echo "🛑 Received $signal signal, initiating graceful shutdown..."
    SHUTDOWN_REQUESTED=1

    if [ -n "$FULCRUM_PID" ] && kill -0 "$FULCRUM_PID" 2>/dev/null; then
        echo "   Forwarding $signal to Fulcrum (PID $FULCRUM_PID)..."
        kill -"$signal" "$FULCRUM_PID" 2>/dev/null || true

        # Wait for Fulcrum to exit gracefully (up to 30 seconds)
        local wait_count=0
        while kill -0 "$FULCRUM_PID" 2>/dev/null && [ $wait_count -lt 30 ]; do
            sleep 1
            ((wait_count++))
        done

        if kill -0 "$FULCRUM_PID" 2>/dev/null; then
            echo "   Fulcrum did not exit gracefully, sending SIGKILL..."
            kill -9 "$FULCRUM_PID" 2>/dev/null || true
        fi
    fi

    echo "✅ Graceful shutdown complete"
    exit 0
}

# Set up signal handlers
trap 'handle_signal TERM' SIGTERM
trap 'handle_signal INT' SIGINT

# Calculate exponential backoff delay
calculate_backoff() {
    local count=$1
    local delay=$((BACKOFF_BASE * (2 ** (count - 1))))
    if [ $delay -gt $BACKOFF_MAX ]; then
        delay=$BACKOFF_MAX
    fi
    echo $delay
}

# Check if we should reset restart count (been stable for RESTART_WINDOW)
check_restart_window() {
    local now
    now=$(date +%s)
    if [ $LAST_RESTART_TIME -gt 0 ]; then
        local elapsed=$((now - LAST_RESTART_TIME))
        if [ $elapsed -gt $RESTART_WINDOW ]; then
            echo "   Fulcrum has been stable for $elapsed seconds, resetting restart count"
            RESTART_COUNT=0
        fi
    fi
}

# Wait for the "ready" signal from the run script
# This ensures all config and SSL files are copied before we proceed
# On restart, if files already exist, skip waiting
wait_for_ready_signal() {
  local SIGNAL_FILE="/tmp/.fulcrum-ready"
  local MAX_WAIT=60  # Maximum wait time in seconds

  # Check if this is a restart with existing config/SSL files
  # If config exists in /config/ and SSL certs exist in /ssl/, we're ready
  if [ -f "/config/fulcrum.conf" ]; then
    if [ -f "/ssl/fullchain.pem" ] && [ -f "/ssl/privkey.pem" ]; then
      echo "✅ Restart detected: config and SSL certificates already present"
      rm -f "$SIGNAL_FILE"  # Clean up any stale signal file
      return 0
    elif [ -f "/ssl/fulcrum.crt" ] && [ -f "/ssl/fulcrum.key" ]; then
      echo "✅ Restart detected: config and SSL certificates already present"
      rm -f "$SIGNAL_FILE"
      return 0
    else
      echo "✅ Restart detected: config present (no SSL)"
      rm -f "$SIGNAL_FILE"
      return 0
    fi
  fi

  # Fresh start - wait for run script to copy files
  echo "⏳ Waiting for configuration to be ready (signal file: $SIGNAL_FILE)..."
  for i in $(seq 1 $MAX_WAIT); do
    if [ -f "$SIGNAL_FILE" ]; then
      echo "✅ Ready signal received after ${i}s"
      rm -f "$SIGNAL_FILE"  # Clean up signal file
      return 0
    fi
    sleep 1
  done

  echo "⚠️  No ready signal received after ${MAX_WAIT}s, proceeding with available config..."
  return 0  # Continue anyway to support legacy usage
}

# Function to handle configuration
setup_config() {
  # Default location for config
  CONFIG_DIR="/data"
  mkdir -p $CONFIG_DIR

  # Check for config file at /config/fulcrum.conf (copied by run script)
  if [ -f "/config/fulcrum.conf" ]; then
    echo "Using configuration from /config/fulcrum.conf"
    cp /config/fulcrum.conf $CONFIG_DIR/fulcrum.conf
  fi

  # Fallback: Check for local config file
  if [ ! -f "$CONFIG_DIR/fulcrum.conf" ] && [ -f "/etc/fulcrum/fulcrum.conf" ]; then
    echo "Using local configuration from /etc/fulcrum/fulcrum.conf"
    cp /etc/fulcrum/fulcrum.conf $CONFIG_DIR/fulcrum.conf
  # Fallback: Use default config file
  elif [ ! -f "$CONFIG_DIR/fulcrum.conf" ]; then
    echo "Using default configuration file"
    cp /etc/fulcrum/fulcrum.conf.default $CONFIG_DIR/fulcrum.conf
  else
    echo "Using existing configuration from $CONFIG_DIR/fulcrum.conf"
  fi
}

# Configure SSL and WebSocket based on certificate availability
configure_ssl_and_websocket() {
  SSL_CERT_DIR="/ssl"
  DATA_SSL_CERT="${CONFIG_DIR}/fulcrum.crt"
  DATA_SSL_KEY="${CONFIG_DIR}/fulcrum.key"
  CONFIG_FILE="$CONFIG_DIR/fulcrum.conf"

  # No need to wait here - ready signal ensures files are already copied
  echo "Checking for SSL certificates in $SSL_CERT_DIR..."
  ls -la "$SSL_CERT_DIR" 2>/dev/null || echo "  (directory not found or empty)"

  # Check if SSL certificates are available
  # Support both standard names and Let's Encrypt names
  local ssl_found=0

  if [ -f "$SSL_CERT_DIR/fulcrum.crt" ] && [ -f "$SSL_CERT_DIR/fulcrum.key" ]; then
    echo "Found SSL certificates (standard names)"
    cp "$SSL_CERT_DIR/fulcrum.crt" "$DATA_SSL_CERT"
    cp "$SSL_CERT_DIR/fulcrum.key" "$DATA_SSL_KEY"
    ssl_found=1
  elif [ -f "$SSL_CERT_DIR/fullchain.pem" ] && [ -f "$SSL_CERT_DIR/privkey.pem" ]; then
    echo "Found SSL certificates (Let's Encrypt)"
    cp "$SSL_CERT_DIR/fullchain.pem" "$DATA_SSL_CERT"
    cp "$SSL_CERT_DIR/privkey.pem" "$DATA_SSL_KEY"
    ssl_found=1
  else
    echo "No SSL certificates found in $SSL_CERT_DIR"
    echo "Looked for: fulcrum.crt/fulcrum.key OR fullchain.pem/privkey.pem"
  fi
  
  if [ $ssl_found -eq 1 ]; then
    chmod 600 "$DATA_SSL_KEY"
    echo "SSL certificates copied to data directory"
    
    # Create temporary config file
    cp "$CONFIG_FILE" "$CONFIG_FILE.tmp"
    
    # Enable SSL and WSS ports (keep TCP and WS enabled too for compatibility)
    # This allows both encrypted and unencrypted connections
    
    # Ensure TCP is enabled
    if ! grep -q "^tcp\s*=" "$CONFIG_FILE.tmp"; then
      echo "" >> "$CONFIG_FILE.tmp"
      echo "tcp = 0.0.0.0:50001" >> "$CONFIG_FILE.tmp"
    else
      sed -i 's/^#tcp\s*=/tcp =/' "$CONFIG_FILE.tmp"
    fi
    
    # Enable SSL
    if ! grep -q "^ssl\s*=" "$CONFIG_FILE.tmp"; then
      # Ensure file ends with newline before appending
      echo "" >> "$CONFIG_FILE.tmp"
      echo "ssl = 0.0.0.0:50002" >> "$CONFIG_FILE.tmp"
    else
      sed -i 's/^#ssl\s*=/ssl =/' "$CONFIG_FILE.tmp"
    fi
    
    # Ensure WS is enabled
    if ! grep -q "^ws\s*=" "$CONFIG_FILE.tmp"; then
      echo "" >> "$CONFIG_FILE.tmp"
      echo "ws = 0.0.0.0:50003" >> "$CONFIG_FILE.tmp"
    else
      sed -i 's/^#ws\s*=/ws =/' "$CONFIG_FILE.tmp"
    fi
    
    # Enable WSS
    if ! grep -q "^wss\s*=" "$CONFIG_FILE.tmp"; then
      echo "" >> "$CONFIG_FILE.tmp"
      echo "wss = 0.0.0.0:50004" >> "$CONFIG_FILE.tmp"
    else
      sed -i 's/^#wss\s*=/wss =/' "$CONFIG_FILE.tmp"
    fi
    
    # Ensure cert and key paths are set and uncommented
    if ! grep -q "^cert\s*=" "$CONFIG_FILE.tmp"; then
      echo "" >> "$CONFIG_FILE.tmp"
      echo "cert = /data/fulcrum.crt" >> "$CONFIG_FILE.tmp"
    else
      sed -i 's/^#cert\s*=/cert =/' "$CONFIG_FILE.tmp"
    fi
    
    if ! grep -q "^key\s*=" "$CONFIG_FILE.tmp"; then
      echo "" >> "$CONFIG_FILE.tmp"
      echo "key = /data/fulcrum.key" >> "$CONFIG_FILE.tmp"
    else
      sed -i 's/^#key\s*=/key =/' "$CONFIG_FILE.tmp"
    fi
    
    # Move the modified config back
    mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
    
    echo "Configuration updated: Both SSL and non-SSL ports enabled"
    echo "  - TCP on port 50001"
    echo "  - SSL on port 50002"
    echo "  - WS on port 50003"
    echo "  - WSS on port 50004"
    echo ""
    echo "Final configuration check:"
    grep -E "^(tcp|ssl|ws|wss|cert|key)\s*=" "$CONFIG_FILE" || echo "No network ports configured!"
  else
    echo "No SSL certificates found, using plain TCP and WebSocket only"
    # Ensure ssl and wss are commented out if they exist
    sed -i 's/^ssl\s*=/#ssl =/' "$CONFIG_FILE"
    sed -i 's/^wss\s*=/#wss =/' "$CONFIG_FILE"
    echo "Configuration: Using non-SSL ports only"
    echo "  - TCP on port 50001"
    echo "  - WS on port 50003"
  fi
}

# Wait for Alpha node to be ready (if on same network)
wait_for_alpha() {
  # Try to detect if alpha-node is accessible
  if nc -z alpha-node 8589 2>/dev/null; then
    echo "Detected alpha-node on network, waiting for it to be ready..."
    while ! nc -z alpha-node 8589 2>/dev/null; do
      echo "Alpha node not ready, waiting..."
      sleep 5
    done
    echo "Alpha node is ready!"
  fi
}

# Function to clean database (removes all database subdirectories while preserving config and SSL files)
clean_database() {
  echo "🔧 Cleaning database..."
  # Remove all RocksDB subdirectories
  for subdir in meta blkinfo utxoset scripthash_history scripthash_unspent undo txhash2txnum rpa; do
    if [ -d "/data/$subdir" ]; then
      echo "  Removing $subdir..."
      rm -rf "/data/$subdir"
    fi
  done
  # Remove any other files that aren't config or SSL certificates
  find /data -maxdepth 1 -type f -not -name "*.conf" -not -name "*.crt" -not -name "*.key" -not -name "*.pem" -delete 2>/dev/null || true
  echo "✅ Database cleaned"
}

# Supervisor loop for Fulcrum - restarts on crash with database cleanup
run_fulcrum_supervised() {
    local config_file="$1"
    shift
    local extra_args=("$@")

    echo "🚀 Starting Fulcrum supervisor loop..."
    echo "   Config: $config_file"
    echo "   Max restarts: $MAX_RESTARTS within $RESTART_WINDOW seconds"
    echo "   Backoff: ${BACKOFF_BASE}s base, ${BACKOFF_MAX}s max"

    while [ $SHUTDOWN_REQUESTED -eq 0 ]; do
        # Check if we should reset restart count
        check_restart_window

        # Check if we've exceeded max restarts
        if [ $RESTART_COUNT -ge $MAX_RESTARTS ]; then
            echo "❌ Maximum restart count ($MAX_RESTARTS) exceeded within restart window"
            echo "   This indicates a persistent crash loop. Container will exit."
            echo "   Please investigate logs and fix the underlying issue."
            exit 1
        fi

        echo "▶️  Starting Fulcrum (attempt $((RESTART_COUNT + 1))/$MAX_RESTARTS)..."

        # Start Fulcrum in background so we can track its PID
        Fulcrum "$config_file" "${extra_args[@]}" &
        FULCRUM_PID=$!
        echo "   Fulcrum started with PID $FULCRUM_PID"

        # Wait for Fulcrum to exit
        wait $FULCRUM_PID
        EXIT_CODE=$?
        FULCRUM_PID=""

        # Check if shutdown was requested
        if [ $SHUTDOWN_REQUESTED -eq 1 ]; then
            echo "   Shutdown was requested, not restarting"
            break
        fi

        # Fulcrum exited unexpectedly
        LAST_RESTART_TIME=$(date +%s)
        ((RESTART_COUNT++))

        if [ $EXIT_CODE -eq 0 ]; then
            echo "⚠️  Fulcrum exited with code 0 (clean exit) - not restarting"
            echo "   If this was unexpected, check the logs for shutdown reason"
            break
        fi

        echo "💥 Fulcrum crashed with exit code $EXIT_CODE"
        echo "   Restart count: $RESTART_COUNT/$MAX_RESTARTS"

        # Calculate backoff delay
        local delay
        delay=$(calculate_backoff $RESTART_COUNT)
        echo "   Cleaning database before restart..."
        clean_database

        echo "   Waiting ${delay}s before restart (exponential backoff)..."

        # Sleep with interrupt check for graceful shutdown during backoff
        local slept=0
        while [ $slept -lt $delay ] && [ $SHUTDOWN_REQUESTED -eq 0 ]; do
            sleep 1
            ((slept++))
        done

        if [ $SHUTDOWN_REQUESTED -eq 1 ]; then
            echo "   Shutdown requested during backoff, exiting..."
            break
        fi

        echo "   Restarting Fulcrum..."
    done

    echo "✅ Fulcrum supervisor loop exited"
}

# Main execution
# Clean database on every start to prevent corruption issues
echo "🧹 Cleaning database on startup to ensure fresh state..."
clean_database

# Clean stale config and SSL from previous runs so the ready-signal handshake
# with run-fulcrum.sh always runs fresh. Without this, a leftover /config/fulcrum.conf
# causes wait_for_ready_signal() to skip waiting, and SSL certs from a new run
# arrive after the entrypoint has already started Fulcrum without them.
rm -f /config/fulcrum.conf /ssl/fullchain.pem /ssl/privkey.pem /ssl/fulcrum.crt /ssl/fulcrum.key 2>/dev/null || true

# Wait for run script to finish copying config and SSL certs
wait_for_ready_signal

# Handle configuration
setup_config

# Set the config file path (always the same after setup_config)
CONFIG_FILE="/data/fulcrum.conf"
CONFIG_DIR="/data"

# Configure SSL and WebSocket based on certificate availability
configure_ssl_and_websocket

# Wait for Alpha node if available
wait_for_alpha

# First argument is Fulcrum or FulcrumAdmin
if [ "$1" = "Fulcrum" ]; then
  # Run Fulcrum with supervisor loop (restarts on crash)
  run_fulcrum_supervised "$CONFIG_FILE" "${@:2}"
elif [ "$1" = "FulcrumAdmin" ]; then
  echo "Running FulcrumAdmin..."
  exec FulcrumAdmin "${@:2}"
else
  # Assume any other command is to be executed directly
  exec "$@"
fi