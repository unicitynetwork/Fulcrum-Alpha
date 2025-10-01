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

# Function to format timestamp
format_date() {
    local timestamp="$1"
    if command -v date >/dev/null 2>&1; then
        date -d "$timestamp" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || echo "$timestamp"
    else
        echo "$timestamp"
    fi
}

# Scan for available Docker images
echo "🔍 Scanning for available Docker images..."
echo ""

IMAGES=()
IMAGE_DATES=()
IMAGE_DISPLAY=()

# Check local image
if docker image inspect fulcrum-alpha:latest >/dev/null 2>&1; then
    CREATED=$(docker image inspect fulcrum-alpha:latest --format='{{.Created}}')
    FORMATTED_DATE=$(format_date "$CREATED")
    IMAGES+=("fulcrum-alpha:latest")
    IMAGE_DATES+=("$FORMATTED_DATE")
    IMAGE_DISPLAY+=("fulcrum-alpha:latest (local) - Updated: $FORMATTED_DATE")
fi

# Check GitHub Container Registry image
if docker image inspect ghcr.io/unicitynetwork/alpha/fulcrum:latest >/dev/null 2>&1; then
    CREATED=$(docker image inspect ghcr.io/unicitynetwork/alpha/fulcrum:latest --format='{{.Created}}')
    FORMATTED_DATE=$(format_date "$CREATED")
    IMAGES+=("ghcr.io/unicitynetwork/alpha/fulcrum:latest")
    IMAGE_DATES+=("$FORMATTED_DATE")
    IMAGE_DISPLAY+=("ghcr.io/unicitynetwork/alpha/fulcrum:latest (registry) - Updated: $FORMATTED_DATE")
else
    # Try to check if it exists in registry
    echo "Checking remote registry..."
    if docker manifest inspect ghcr.io/unicitynetwork/alpha/fulcrum:latest >/dev/null 2>&1; then
        echo "  Registry image available but not pulled locally"
        echo "  To use it, first run: docker pull ghcr.io/unicitynetwork/alpha/fulcrum:latest"
    fi
fi

# Display available images
if [ ${#IMAGES[@]} -eq 0 ]; then
    echo "❌ No Docker images found!"
    echo ""
    echo "Please build the image first with:"
    echo "  cd docker && ./build.sh"
    echo ""
    echo "Or pull from registry:"
    echo "  docker pull ghcr.io/unicitynetwork/alpha/fulcrum:latest"
    exit 1
fi

echo "Available Docker images:"
echo "------------------------"
for i in "${!IMAGE_DISPLAY[@]}"; do
    echo "$((i+1)). ${IMAGE_DISPLAY[$i]}"
done
echo ""

# Let user select image
if [ ${#IMAGES[@]} -eq 1 ]; then
    IMAGE_NAME="${IMAGES[0]}"
    echo "Using only available image: $IMAGE_NAME"
else
    read -p "Select image to run [1-${#IMAGES[@]}] (default: 1): " IMAGE_CHOICE
    IMAGE_CHOICE=${IMAGE_CHOICE:-1}
    
    if [ "$IMAGE_CHOICE" -ge 1 ] && [ "$IMAGE_CHOICE" -le ${#IMAGES[@]} ]; then
        IMAGE_NAME="${IMAGES[$((IMAGE_CHOICE-1))]}"
    else
        IMAGE_NAME="${IMAGES[0]}"
    fi
    echo "Selected: $IMAGE_NAME"
fi

# Override with environment variable if set
IMAGE_NAME="${FULCRUM_IMAGE:-$IMAGE_NAME}"

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
        echo "No SSL certificates found"
        echo ""
        echo "Options:"
        echo "1. Continue without SSL (TCP only)"
        echo "2. Exit"
        echo ""
        read -p "Select [1-2] (default: 1): " ssl_choice
        
        if [ "${ssl_choice:-1}" = "2" ]; then
            echo "Exiting..."
            exit 1
        fi
        
        echo "Continuing without SSL support..."
        CERT_SOURCE=""
        KEY_SOURCE=""
    else
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
fi

# Stop existing container
echo ""
echo "Stopping existing container if running..."
docker stop "$CONTAINER_NAME" 2>/dev/null || true
docker rm "$CONTAINER_NAME" 2>/dev/null || true

# Run Fulcrum
echo ""
if [ -n "$CERT_SOURCE" ] && [ -n "$KEY_SOURCE" ]; then
    # Check if we can read the certificates (may need sudo)
    if [ ! -r "$CERT_SOURCE" ] || [ ! -r "$KEY_SOURCE" ]; then
        echo "📋 Certificates require elevated permissions, using sudo..."
        DOCKER_CMD="sudo docker"
    else
        DOCKER_CMD="docker"
    fi
    
    echo "🚀 Starting Fulcrum with SSL support..."
    echo "📦 Container: $CONTAINER_NAME"
    echo "🔒 Using image: $IMAGE_NAME"
    
    $DOCKER_CMD run -d --rm --name "$CONTAINER_NAME" \
        --network "$NETWORK_NAME" \
        -p 50001:50001 -p 50002:50002 -p 50003:50003 -p 50004:50004 \
        -v fulcrum-data:/data \
        -v "$(pwd)/config:/config:ro" \
        -v "$CERT_SOURCE:/ssl/fullchain.pem:ro" \
        -v "$KEY_SOURCE:/ssl/privkey.pem:ro" \
        "$IMAGE_NAME"
else
    echo "🚀 Starting Fulcrum without SSL..."
    echo "📦 Container: $CONTAINER_NAME"
    echo "🔒 Using image: $IMAGE_NAME"
    
    docker run -d --rm --name "$CONTAINER_NAME" \
        --network "$NETWORK_NAME" \
        -p 50001:50001 -p 50002:50002 -p 50003:50003 -p 50004:50004 \
        -v fulcrum-data:/data \
        -v "$(pwd)/config:/config:ro" \
        "$IMAGE_NAME"
fi

echo ""
echo "✅ Fulcrum started successfully"
echo ""
echo "Available endpoints:"
echo "  - TCP: port 50001"
if [ -n "$CERT_SOURCE" ] && [ -n "$KEY_SOURCE" ]; then
    echo "  - SSL/TLS: port 50002"
fi
echo "  - WebSocket: port 50003"
if [ -n "$CERT_SOURCE" ] && [ -n "$KEY_SOURCE" ]; then
    echo "  - WebSocket Secure: port 50004"
fi
echo ""
echo "Commands:"
echo "  View logs: docker logs -f $CONTAINER_NAME"
echo "  Stop: docker stop $CONTAINER_NAME"
echo ""
if [ -n "$CERT_SOURCE" ] && [ -n "$KEY_SOURCE" ]; then
    echo "Note: Certificates are mounted directly from:"
    echo "  - $CERT_SOURCE"
    echo "  - $KEY_SOURCE"
fi