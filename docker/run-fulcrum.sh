#!/bin/bash

# Main script to run Fulcrum with optional SSL support
# SSL certificates can be auto-detected from Let's Encrypt or specified manually

set -e

# Container name can be customized
CONTAINER_NAME="${CONTAINER_NAME:-fulcrum-alpha}"
NETWORK_NAME="${NETWORK_NAME:-alpha-net}"

echo "Fulcrum Docker Runner"
echo "===================="
echo ""

# Parse command line arguments
CERT_SOURCE=""
KEY_SOURCE=""
DOMAIN=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --domain)
            DOMAIN="$2"
            shift 2
            ;;
        --cert)
            CERT_SOURCE="$2"
            shift 2
            ;;
        --key)
            KEY_SOURCE="$2"
            shift 2
            ;;
        --container-name)
            CONTAINER_NAME="$2"
            shift 2
            ;;
        --help)
            echo "Usage: $0 [options]"
            echo ""
            echo "Options:"
            echo "  --domain <domain>         Use Let's Encrypt certs for this domain"
            echo "  --cert <path>            Path to certificate file"
            echo "  --key <path>             Path to private key file"
            echo "  --container-name <name>   Container name (default: fulcrum-alpha)"
            echo ""
            echo "Examples:"
            echo "  # Use Let's Encrypt certificates for a domain:"
            echo "  $0 --domain example.com"
            echo ""
            echo "  # Use custom certificate files:"
            echo "  $0 --cert /path/to/cert.pem --key /path/to/key.pem"
            echo ""
            echo "  # Auto-detect Let's Encrypt certificates:"
            echo "  $0"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Run with --help for usage"
            exit 1
            ;;
    esac
done

# Determine certificate source
if [ -n "$CERT_SOURCE" ] && [ -n "$KEY_SOURCE" ]; then
    # Use specified certificate files
    if [ ! -f "$CERT_SOURCE" ]; then
        echo "❌ Certificate file not found: $CERT_SOURCE"
        exit 1
    fi
    if [ ! -f "$KEY_SOURCE" ]; then
        echo "❌ Key file not found: $KEY_SOURCE"
        exit 1
    fi
    echo "✅ Using custom certificates:"
    echo "   Cert: $CERT_SOURCE"
    echo "   Key: $KEY_SOURCE"
    
elif [ -n "$DOMAIN" ]; then
    # Use Let's Encrypt certificates for specified domain
    CERT_SOURCE="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
    KEY_SOURCE="/etc/letsencrypt/live/$DOMAIN/privkey.pem"
    
    if [ ! -f "$CERT_SOURCE" ] || [ ! -f "$KEY_SOURCE" ]; then
        echo "❌ Let's Encrypt certificates not found for domain: $DOMAIN"
        echo "   Expected: $CERT_SOURCE"
        echo "   Expected: $KEY_SOURCE"
        exit 1
    fi
    echo "✅ Using Let's Encrypt certificates for: $DOMAIN"
    
else
    # Auto-detect Let's Encrypt certificates
    LETSENCRYPT_BASE="/etc/letsencrypt/live"
    
    if [ ! -d "$LETSENCRYPT_BASE" ]; then
        echo "❌ Let's Encrypt directory not found"
        echo "Please specify --domain or --cert/--key"
        exit 1
    fi
    
    # Find domains with valid certificates
    echo "🔍 Searching for SSL certificates..."
    DOMAINS=$(sudo find "$LETSENCRYPT_BASE" -maxdepth 1 -type d -name "*.*" -exec basename {} \; 2>/dev/null | sort)
    
    if [ -z "$DOMAINS" ]; then
        echo "❌ No SSL certificates found"
        echo "Please specify --domain or --cert/--key"
        exit 1
    fi
    
    # If multiple domains, let user choose
    DOMAIN_COUNT=$(echo "$DOMAINS" | wc -l)
    if [ $DOMAIN_COUNT -eq 1 ]; then
        DOMAIN="$DOMAINS"
    else
        echo "Found multiple certificates:"
        echo "$DOMAINS" | nl -w2 -s'. '
        echo ""
        read -p "Select domain number (or press Enter for #1): " selection
        
        if [ -z "$selection" ]; then
            selection=1
        fi
        
        DOMAIN=$(echo "$DOMAINS" | sed -n "${selection}p")
        
        if [ -z "$DOMAIN" ]; then
            echo "❌ Invalid selection"
            exit 1
        fi
    fi
    
    CERT_SOURCE="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
    KEY_SOURCE="/etc/letsencrypt/live/$DOMAIN/privkey.pem"
    echo "✅ Selected domain: $DOMAIN"
fi

# Stop existing container
echo ""
echo "Stopping existing container if running..."
docker stop "$CONTAINER_NAME" 2>/dev/null || true
docker rm "$CONTAINER_NAME" 2>/dev/null || true

# Check if we can read the certificates (may need sudo)
if [ ! -r "$CERT_SOURCE" ] || [ ! -r "$KEY_SOURCE" ]; then
    echo "📋 Certificates require elevated permissions, using sudo..."
    DOCKER_CMD="sudo docker"
else
    DOCKER_CMD="docker"
fi

# Run Fulcrum with directly mounted certificates
echo ""
echo "🚀 Starting Fulcrum with SSL support..."
echo "📦 Container: $CONTAINER_NAME"

$DOCKER_CMD run -d --rm --name "$CONTAINER_NAME" \
    --network "$NETWORK_NAME" \
    -p 50001:50001 -p 50002:50002 -p 50003:50003 -p 50004:50004 \
    -v fulcrum-data:/data \
    -v "$(pwd)/config:/config:ro" \
    -v "$CERT_SOURCE:/ssl/fullchain.pem:ro" \
    -v "$KEY_SOURCE:/ssl/privkey.pem:ro" \
    fulcrum-alpha:latest

echo ""
echo "✅ Fulcrum started successfully"
echo ""
echo "Available endpoints:"
echo "  - TCP: port 50001"
echo "  - SSL/TLS: port 50002"
echo "  - WebSocket: port 50003"
echo "  - WebSocket Secure: port 50004"
echo ""
echo "Commands:"
echo "  View logs: docker logs -f $CONTAINER_NAME"
echo "  Stop: docker stop $CONTAINER_NAME"
echo ""
echo "Note: Certificates are mounted directly from:"
echo "  - $CERT_SOURCE"
echo "  - $KEY_SOURCE"