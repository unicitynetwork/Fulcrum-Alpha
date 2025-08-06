#!/bin/bash
set -e

# Function to handle configuration
setup_config() {
  # Default location for config
  CONFIG_DIR="/data"
  mkdir -p $CONFIG_DIR
  
  # Check for mounted config file at /config/fulcrum.conf (consistent with alpha pattern)
  if [ -f "/config/fulcrum.conf" ]; then
    echo "Using mounted configuration from /config/fulcrum.conf"
    cp /config/fulcrum.conf $CONFIG_DIR/fulcrum.conf
  # Check for local config file
  elif [ -f "/etc/fulcrum/fulcrum.conf" ]; then
    echo "Using local configuration from /etc/fulcrum/fulcrum.conf"
    cp /etc/fulcrum/fulcrum.conf $CONFIG_DIR/fulcrum.conf
  # Use default config file
  else
    echo "Using default configuration file"
    cp /etc/fulcrum/fulcrum.conf.default $CONFIG_DIR/fulcrum.conf
  fi
}

# Configure SSL and WebSocket based on certificate availability
configure_ssl_and_websocket() {
  SSL_CERT_DIR="/ssl"
  DATA_SSL_CERT="${DATA_DIR}/fulcrum.crt"
  DATA_SSL_KEY="${DATA_DIR}/fulcrum.key"
  CONFIG_FILE="$CONFIG_DIR/fulcrum.conf"
  
  # Check if SSL certificates are mounted
  if [ -f "$SSL_CERT_DIR/fulcrum.crt" ] && [ -f "$SSL_CERT_DIR/fulcrum.key" ]; then
    echo "Found mounted SSL certificates"
    cp "$SSL_CERT_DIR/fulcrum.crt" "$DATA_SSL_CERT"
    cp "$SSL_CERT_DIR/fulcrum.key" "$DATA_SSL_KEY"
    chmod 600 "$DATA_SSL_KEY"
    echo "SSL certificates copied to data directory"
    
    # Create temporary config file
    cp "$CONFIG_FILE" "$CONFIG_FILE.tmp"
    
    # Comment out plain ports (tcp and ws) and enable secure ports (ssl and wss)
    sed -i 's/^tcp\s*=/#tcp =/' "$CONFIG_FILE.tmp"
    sed -i 's/^ws\s*=/#ws =/' "$CONFIG_FILE.tmp"
    
    # Enable SSL and WSS if not already enabled
    if ! grep -q "^ssl\s*=" "$CONFIG_FILE.tmp"; then
      echo "ssl = 0.0.0.0:50002" >> "$CONFIG_FILE.tmp"
    else
      sed -i 's/^#ssl\s*=/ssl =/' "$CONFIG_FILE.tmp"
    fi
    
    if ! grep -q "^wss\s*=" "$CONFIG_FILE.tmp"; then
      echo "wss = 0.0.0.0:50004" >> "$CONFIG_FILE.tmp"
    else
      sed -i 's/^#wss\s*=/wss =/' "$CONFIG_FILE.tmp"
    fi
    
    # Move the modified config back
    mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
    
    echo "Configuration updated: SSL enabled, using secure ports only"
    echo "  - TCP disabled, SSL on port 50002"
    echo "  - WS disabled, WSS on port 50004"
  else
    echo "No SSL certificates found, using plain TCP and WebSocket"
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

# Function to clean corrupted database
clean_corrupted_db() {
  echo "🔧 Cleaning corrupted database..."
  # Remove all database files except config and SSL certs
  find /data -type f -not -name "*.conf" -not -name "*.crt" -not -name "*.key" -delete 2>/dev/null || true
  find /data -type d -not -path "/data" -exec rm -rf {} + 2>/dev/null || true
  echo "✅ Database cleaned"
}

# Function to run Fulcrum with auto-recovery
run_with_recovery() {
  local max_retries=3
  local retry_count=0
  local retry_delay=10
  
  while [ $retry_count -lt $max_retries ]; do
    echo "Starting Fulcrum server (attempt $((retry_count + 1))/$max_retries)..."
    
    # Run Fulcrum and capture exit code
    set +e
    Fulcrum "$CONFIG_FILE" "${@:2}" 2>&1 | tee /tmp/fulcrum.log
    exit_code=$?
    set -e
    
    # Check if it was a clean exit
    if [ $exit_code -eq 0 ]; then
      echo "Fulcrum exited cleanly"
      break
    fi
    
    # Check for database corruption
    if grep -q "database has been corrupted\|inconsistent state\|forcefully killed" /tmp/fulcrum.log; then
      echo "⚠️  Database corruption detected!"
      clean_corrupted_db
      retry_count=0  # Reset counter after cleaning
      echo "🔄 Restarting with clean database..."
    else
      retry_count=$((retry_count + 1))
      if [ $retry_count -lt $max_retries ]; then
        echo "⚠️  Fulcrum crashed (exit code: $exit_code)"
        echo "🔄 Retrying in $retry_delay seconds..."
        sleep $retry_delay
      fi
    fi
  done
  
  if [ $retry_count -ge $max_retries ]; then
    echo "❌ Fulcrum failed after $max_retries attempts"
    exit 1
  fi
}

# Main execution
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
  # Run with auto-recovery
  run_with_recovery "$@"
elif [ "$1" = "FulcrumAdmin" ]; then
  echo "Running FulcrumAdmin..."
  exec FulcrumAdmin "${@:2}"
else
  # Assume any other command is to be executed directly
  exec "$@"
fi