#!/bin/bash

# Script to run Fulcrum with automatic SSL detection
# Finds Let's Encrypt certificates and copies them locally

set -e

SSL_DIR="./ssl"

echo "Fulcrum Auto-SSL Runner"
echo "======================"
echo ""

# Find available Let's Encrypt certificates
LETSENCRYPT_BASE="/etc/letsencrypt/live"
if [ ! -d "$LETSENCRYPT_BASE" ]; then
    echo "❌ Let's Encrypt directory not found"
    echo "Running without SSL..."
    exec ./run_fulcrum.sh
fi

# Find domains with valid certificates
echo "🔍 Searching for SSL certificates..."
DOMAINS=$(sudo find "$LETSENCRYPT_BASE" -maxdepth 1 -type d -name "*.*" -exec basename {} \; 2>/dev/null | sort)

if [ -z "$DOMAINS" ]; then
    echo "❌ No SSL certificates found"
    echo "Running without SSL..."
    exec ./run_fulcrum.sh
fi

# If multiple domains, let user choose
DOMAIN_COUNT=$(echo "$DOMAINS" | wc -l)
if [ $DOMAIN_COUNT -eq 1 ]; then
    SELECTED_DOMAIN="$DOMAINS"
    echo "✅ Found certificate for: $SELECTED_DOMAIN"
else
    echo "Found multiple certificates:"
    echo "$DOMAINS" | nl -w2 -s'. '
    echo ""
    read -p "Select domain number (or press Enter for #1): " selection
    
    if [ -z "$selection" ]; then
        selection=1
    fi
    
    SELECTED_DOMAIN=$(echo "$DOMAINS" | sed -n "${selection}p")
    
    if [ -z "$SELECTED_DOMAIN" ]; then
        echo "❌ Invalid selection"
        exit 1
    fi
fi

LETSENCRYPT_DIR="$LETSENCRYPT_BASE/$SELECTED_DOMAIN"

# Create SSL directory
mkdir -p "$SSL_DIR"

# Copy certificates
echo "📋 Copying SSL certificates for $SELECTED_DOMAIN..."
sudo cp -L "$LETSENCRYPT_DIR/fullchain.pem" "$SSL_DIR/" || {
    echo "❌ Failed to copy fullchain.pem"
    exit 1
}
sudo cp -L "$LETSENCRYPT_DIR/privkey.pem" "$SSL_DIR/" || {
    echo "❌ Failed to copy privkey.pem"
    exit 1
}

# Fix ownership and permissions
sudo chown -R $USER:$USER "$SSL_DIR"
chmod 644 "$SSL_DIR/fullchain.pem"
chmod 600 "$SSL_DIR/privkey.pem"

echo "✅ SSL certificates copied successfully"

# Create/update a marker file with the domain
echo "$SELECTED_DOMAIN" > "$SSL_DIR/.domain"

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
echo "🔒 Using certificate for: $SELECTED_DOMAIN"
echo ""
echo "Available endpoints:"
echo "  - SSL/TLS: port 50002"
echo "  - WebSocket Secure (wss): port 50004"
echo ""
echo "To view logs: docker logs -f fulcrum-alpha"
echo "To stop: docker stop fulcrum-alpha"