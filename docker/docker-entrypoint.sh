#!/bin/bash
set -e

# Function to handle configuration
setup_config() {
  # Default location for config
  CONFIG_DIR="/data"
  mkdir -p $CONFIG_DIR

  # Wait for config to be copied via docker cp (max 30 seconds)
  if [ ! -f "$CONFIG_DIR/fulcrum.conf" ]; then
    echo "Waiting for configuration to be copied via docker cp..."
    for i in {1..30}; do
      if [ -f "/config/fulcrum.conf" ]; then
        echo "Configuration file appeared, copying..."
        cp /config/fulcrum.conf $CONFIG_DIR/fulcrum.conf
        break
      fi
      sleep 1
    done
  fi

  # Check for mounted config file at /config/fulcrum.conf (consistent with alpha pattern)
  if [ -f "/config/fulcrum.conf" ] && [ ! -f "$CONFIG_DIR/fulcrum.conf" ]; then
    echo "Using mounted configuration from /config/fulcrum.conf"
    cp /config/fulcrum.conf $CONFIG_DIR/fulcrum.conf
  # Check for local config file
  elif [ ! -f "$CONFIG_DIR/fulcrum.conf" ] && [ -f "/etc/fulcrum/fulcrum.conf" ]; then
    echo "Using local configuration from /etc/fulcrum/fulcrum.conf"
    cp /etc/fulcrum/fulcrum.conf $CONFIG_DIR/fulcrum.conf
  # Use default config file
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
  DATA_SSL_CERT="${DATA_DIR}/fulcrum.crt"
  DATA_SSL_KEY="${DATA_DIR}/fulcrum.key"
  CONFIG_FILE="$CONFIG_DIR/fulcrum.conf"
  
  # Wait for SSL certificates to be copied via docker cp (max 10 seconds)
  echo "Checking for SSL certificates in $SSL_CERT_DIR..."
  for i in {1..10}; do
    if [ -d "$SSL_CERT_DIR" ]; then
      ls -la "$SSL_CERT_DIR" 2>/dev/null || true
      break
    fi
    sleep 1
  done

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

# Function to run Fulcrum
run_fulcrum() {
  echo "Starting Fulcrum server..."
  exec Fulcrum "$CONFIG_FILE" "${@:2}"
}

# Main execution
# Clean database on every start to prevent corruption issues
echo "🧹 Cleaning database on startup to ensure fresh state..."
clean_database

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
  # Run Fulcrum
  run_fulcrum "$@"
elif [ "$1" = "FulcrumAdmin" ]; then
  echo "Running FulcrumAdmin..."
  exec FulcrumAdmin "${@:2}"
else
  # Assume any other command is to be executed directly
  exec "$@"
fi