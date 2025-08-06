#!/bin/bash

# Script to run Fulcrum with SSL support
# Automatically copies Let's Encrypt certificates to local ssl directory

set -e

# Configuration
LETSENCRYPT_DOMAIN="friendly-miners.dyndns.org"
LETSENCRYPT_DIR="/etc/letsencrypt/live/$LETSENCRYPT_DOMAIN"
SSL_DIR="./ssl"

echo "Fulcrum SSL Runner"
echo "=================="
echo ""

# Check if Let's Encrypt directory exists
if [ ! -d "$LETSENCRYPT_DIR" ]; then
    echo "❌ Error: Let's Encrypt directory not found: $LETSENCRYPT_DIR"
    echo "Please check the domain name or run certbot first."
    exit 1
fi

# Create SSL directory
mkdir -p "$SSL_DIR"

# Copy certificates (following symlinks with -L)
echo "📋 Copying SSL certificates..."
sudo cp -L "$LETSENCRYPT_DIR/fullchain.pem" "$SSL_DIR/" || {
    echo "❌ Failed to copy fullchain.pem"
    exit 1
}
sudo cp -L "$LETSENCRYPT_DIR/privkey.pem" "$SSL_DIR/" || {
    echo "❌ Failed to copy privkey.pem"
    exit 1
}

# Fix ownership and permissions
sudo chown $USER:$USER "$SSL_DIR"/*
chmod 644 "$SSL_DIR/fullchain.pem"
chmod 600 "$SSL_DIR/privkey.pem"

echo "✅ SSL certificates copied successfully"

# Stop any existing container
docker stop fulcrum-alpha 2>/dev/null || true

# Run Fulcrum with SSL
echo "🚀 Starting Fulcrum with SSL support..."
docker run -d --rm --name fulcrum-alpha \
    --network alpha-net \
    -p 50001:50001 -p 50002:50002 -p 50003:50003 -p 50004:50004 \
    -v fulcrum-data:/data \
    -v ./config:/config \
    -v ./ssl:/ssl:ro \
    ghcr.io/unicitynetwork/alpha/fulcrum:latest

echo ""
echo "✅ Fulcrum started with SSL support"
echo ""
echo "Available endpoints:"
echo "  - SSL/TLS: port 50002"
echo "  - WebSocket Secure (wss): port 50004"
echo ""
echo "To view logs: docker logs -f fulcrum-alpha"
echo "To stop: docker stop fulcrum-alpha"