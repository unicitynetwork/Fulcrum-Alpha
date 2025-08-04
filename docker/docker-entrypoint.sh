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

# Generate SSL certificates if they don't exist
generate_ssl_certs() {
  SSL_CERTFILE="${DATA_DIR}/fulcrum.crt"
  SSL_KEYFILE="${DATA_DIR}/fulcrum.key"
  
  if [ ! -e "$SSL_CERTFILE" ] || [ ! -e "$SSL_KEYFILE" ] ; then
    echo "Generating SSL certificates..."
    openssl req -newkey rsa:2048 -sha256 -nodes -x509 -days 365 \
      -subj "/O=Fulcrum-Alpha" -keyout "$SSL_KEYFILE" -out "$SSL_CERTFILE"
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

# Handle configuration
setup_config

# Set the config file path (always the same after setup_config)
CONFIG_FILE="/data/fulcrum.conf"

# Generate SSL certificates
generate_ssl_certs

# Wait for Alpha node if available
wait_for_alpha

# First argument is Fulcrum or FulcrumAdmin
if [ "$1" = "Fulcrum" ]; then
  echo "Starting Fulcrum server with config: $CONFIG_FILE"
  exec Fulcrum "$CONFIG_FILE" "${@:2}"
elif [ "$1" = "FulcrumAdmin" ]; then
  echo "Running FulcrumAdmin..."
  exec FulcrumAdmin "${@:2}"
else
  # Assume any other command is to be executed directly
  exec "$@"
fi