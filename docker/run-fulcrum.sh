#!/bin/bash

# Fulcrum Docker Runner
# Runs Fulcrum in Docker container with flexible RPC endpoint configuration
# Always connects to alpha-net Docker network

set -e

# Detect OS for compatibility
detect_os() {
    if [[ "$OSTYPE" == "darwin"* ]]; then
        echo "macos"
    elif [ -f /etc/centos-release ] || [ -f /etc/redhat-release ]; then
        echo "centos"
    elif [ -f /etc/lsb-release ] || [ -f /etc/debian_version ]; then
        echo "ubuntu"
    else
        echo "linux"
    fi
}

OS_TYPE=$(detect_os)

# Cross-platform date formatting
format_date() {
    local timestamp="$1"
    if [[ "$OS_TYPE" == "macos" ]]; then
        date -j -f "%Y-%m-%dT%H:%M:%S" "${timestamp:0:19}" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || echo "$timestamp"
    else
        date -d "$timestamp" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || echo "$timestamp"
    fi
}

# Default values
CONTAINER_NAME="${CONTAINER_NAME:-fulcrum-alpha}"
NETWORK_NAME="${NETWORK_NAME:-alpha-net}"
RPC_HOST=""
RPC_PORT=""
RPC_USER=""
RPC_PASS=""
USE_SSL=""
CERT_SOURCE=""
KEY_SOURCE=""
DOMAIN=""
INTERACTIVE_MODE=true
# Port mappings (host:container)
PORT_TCP="50001"
PORT_SSL="50002"
PORT_WS="50003"
PORT_WSS="50004"

# Parse command line arguments
show_help() {
    cat << EOF
Fulcrum Docker Runner - Run Fulcrum in Docker with Alpha RPC connectivity

Usage: $0 [options]

Interactive Mode:
  Run without arguments for interactive configuration:
  $0

Non-Interactive Mode:
  Provide options to skip interactive prompts

RPC Configuration:
  --rpc-container <name>   Connect to Alpha in Docker container (default: alpha-node)
  --rpc-localhost          Connect to Alpha running on localhost (scans for availability)
  --rpc-host <host>        Custom RPC host (IP or hostname)
  --rpc-port <port>        Custom RPC port (default: 8589)
  --rpc-user <username>    RPC username (default: user)
  --rpc-pass <password>    RPC password (default: password)

Port Configuration:
  --port-tcp <port>        TCP port (default: 50001)
  --port-ssl <port>        SSL/TLS port (default: 50002)
  --port-ws <port>         WebSocket port (default: 50003)
  --port-wss <port>        WebSocket Secure port (default: 50004)

SSL Options:
  --no-ssl                 Disable SSL (TCP only)
  --ssl                    Enable SSL (requires --cert and --key, or auto-detect)
  --domain <domain>        Use Let's Encrypt certs for this domain
  --cert <path>            Path to certificate file
  --key <path>             Path to private key file

Other Options:
  --container-name <name>  Container name (default: fulcrum-alpha)
  --help                   Show this help message

Examples:
  # Interactive mode (prompts for all options):
  $0

  # Connect to alpha-node container (default):
  $0 --rpc-container alpha-node

  # Connect to Alpha on localhost:
  $0 --rpc-localhost

  # Custom RPC endpoint with SSL:
  $0 --rpc-host 192.168.1.10 --domain example.com

  # All options specified:
  $0 --rpc-container alpha-node --rpc-user myuser --rpc-pass mypass --no-ssl

EOF
    exit 0
}

# Check if any arguments provided
if [ $# -gt 0 ]; then
    INTERACTIVE_MODE=false
fi

RPC_LOCALHOST_FLAG=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --rpc-container)
            RPC_HOST="$2"
            shift 2
            ;;
        --rpc-localhost)
            RPC_LOCALHOST_FLAG="yes"
            shift
            ;;
        --rpc-host)
            RPC_HOST="$2"
            shift 2
            ;;
        --rpc-port)
            RPC_PORT="$2"
            shift 2
            ;;
        --rpc-user)
            RPC_USER="$2"
            shift 2
            ;;
        --rpc-pass)
            RPC_PASS="$2"
            shift 2
            ;;
        --no-ssl)
            USE_SSL="no"
            shift
            ;;
        --ssl)
            USE_SSL="yes"
            shift
            ;;
        --domain)
            DOMAIN="$2"
            USE_SSL="yes"
            shift 2
            ;;
        --cert)
            CERT_SOURCE="$2"
            USE_SSL="yes"
            shift 2
            ;;
        --key)
            KEY_SOURCE="$2"
            USE_SSL="yes"
            shift 2
            ;;
        --container-name)
            CONTAINER_NAME="$2"
            shift 2
            ;;
        --port-tcp)
            PORT_TCP="$2"
            shift 2
            ;;
        --port-ssl)
            PORT_SSL="$2"
            shift 2
            ;;
        --port-ws)
            PORT_WS="$2"
            shift 2
            ;;
        --port-wss)
            PORT_WSS="$2"
            shift 2
            ;;
        --help)
            show_help
            ;;
        *)
            echo "Unknown option: $1"
            echo "Run with --help for usage"
            exit 1
            ;;
    esac
done

echo "Fulcrum Docker Runner"
echo "====================="
echo ""

###################
# INTERACTIVE MODE
###################

# Process --rpc-localhost flag
if [ "$RPC_LOCALHOST_FLAG" = "yes" ]; then
    # Scan for Alpha on localhost
    echo "🔍 Scanning for Alpha node on localhost:8589..."
    if timeout 2 bash -c "</dev/tcp/127.0.0.1/8589" 2>/dev/null; then
        echo "✅ Alpha node detected on localhost:8589"
        RPC_HOST="host.docker.internal"
        RPC_PORT="8589"
    else
        echo "❌ No Alpha node found on localhost:8589"
        echo "Please ensure Alpha is running on the host machine"
        exit 1
    fi
fi

# 1. Select RPC endpoint interactively
if [ -z "$RPC_HOST" ] && [ "$INTERACTIVE_MODE" = true ]; then
    echo "Select Alpha RPC endpoint:"
    echo "1. Docker container 'alpha-node' (default, same network)"
    echo "2. Localhost (Alpha running as standalone app on host)"
    echo "3. Custom endpoint"
    echo ""
    read -p "Select [1-3] (default: 1): " rpc_choice
    rpc_choice=${rpc_choice:-1}

    case $rpc_choice in
        1)
            RPC_HOST="alpha-node"
            RPC_PORT="8589"
            echo "Selected: alpha-node container"
            ;;
        2)
            # Scan for Alpha on localhost
            echo "🔍 Scanning for Alpha node on localhost:8589..."
            if timeout 2 bash -c "</dev/tcp/127.0.0.1/8589" 2>/dev/null; then
                echo "✅ Alpha node detected on localhost:8589"
                RPC_HOST="host.docker.internal"
                RPC_PORT="8589"
            else
                echo "❌ No Alpha node found on localhost:8589"
                echo ""
                read -p "Continue anyway? [y/N]: " continue_choice
                if [[ ! "$continue_choice" =~ ^[Yy]$ ]]; then
                    echo "Exiting..."
                    exit 1
                fi
                RPC_HOST="host.docker.internal"
                RPC_PORT="8589"
                echo "⚠️  Warning: Proceeding without detected Alpha node"
            fi
            ;;
        3)
            read -p "RPC host (e.g., 192.168.1.10 or container name): " RPC_HOST
            read -p "RPC port (default: 8589): " RPC_PORT
            RPC_PORT=${RPC_PORT:-8589}
            echo "Selected: Custom endpoint ($RPC_HOST:$RPC_PORT)"
            ;;
    esac
    echo ""
fi

# Validate RPC configuration (non-interactive fallback)
if [ -z "$RPC_HOST" ]; then
    echo "Using default: alpha-node container"
    RPC_HOST="alpha-node"
fi

# Set default RPC port if not specified
RPC_PORT="${RPC_PORT:-8589}"

# 2. Get RPC credentials
if [ -z "$RPC_USER" ]; then
    if [ "$INTERACTIVE_MODE" = true ]; then
        read -p "RPC username (default: user): " RPC_USER
        RPC_USER=${RPC_USER:-user}
    else
        RPC_USER="user"
    fi
fi
if [ -z "$RPC_PASS" ]; then
    if [ "$INTERACTIVE_MODE" = true ]; then
        read -s -p "RPC password (default: password): " RPC_PASS
        echo ""
        RPC_PASS=${RPC_PASS:-password}
    else
        RPC_PASS="password"
    fi
fi

echo ""
echo "RPC Configuration:"
echo "  Host: $RPC_HOST:$RPC_PORT"
echo "  User: $RPC_USER"
echo ""

###################
# DOCKER SETUP
###################

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
    if [ "$INTERACTIVE_MODE" = true ]; then
        echo "Checking remote registry..."
        if docker manifest inspect ghcr.io/unicitynetwork/alpha/fulcrum:latest >/dev/null 2>&1; then
            echo "  Registry image available but not pulled locally"
            echo "  To use it, first run: docker pull ghcr.io/unicitynetwork/alpha/fulcrum:latest"
        fi
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

# 3. Interactive SSL selection
if [ -z "$USE_SSL" ] && [ "$INTERACTIVE_MODE" = true ]; then
    echo "SSL/TLS Configuration:"
    echo "1. No SSL (TCP only)"
    echo "2. Auto-detect Let's Encrypt certificates"
    echo "3. Specify domain for Let's Encrypt"
    echo "4. Use custom certificate files"
    echo ""
    read -p "Select [1-4] (default: 2 - Auto-detect): " ssl_choice
    ssl_choice=${ssl_choice:-2}

    case $ssl_choice in
        1)
            USE_SSL="no"
            echo "Selected: No SSL"
            ;;
        2)
            USE_SSL="auto"
            echo "Selected: Auto-detect SSL certificates"
            ;;
        3)
            read -p "Enter domain name: " DOMAIN
            USE_SSL="yes"
            echo "Selected: Let's Encrypt for $DOMAIN"
            ;;
        4)
            read -p "Certificate file path: " CERT_SOURCE
            read -p "Private key file path: " KEY_SOURCE
            USE_SSL="yes"
            echo "Selected: Custom certificates"
            ;;
    esac
    echo ""
fi

# Default SSL to auto-detect if not specified
if [ -z "$USE_SSL" ]; then
    USE_SSL="auto"
fi

# Handle SSL certificates
if [ "$USE_SSL" = "yes" ] || [ "$USE_SSL" = "auto" ]; then
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

        if [ -d "$LETSENCRYPT_BASE" ]; then
            echo "🔍 Searching for SSL certificates..."

            # Cross-platform find
            if [[ "$OS_TYPE" == "macos" ]]; then
                DOMAINS=$(find "$LETSENCRYPT_BASE" -maxdepth 1 -type d -name "*.*" -exec basename {} \; 2>/dev/null | sort || true)
            else
                DOMAINS=$(sudo find "$LETSENCRYPT_BASE" -maxdepth 1 -type d -name "*.*" -exec basename {} \; 2>/dev/null | sort || true)
            fi

            if [ -n "$DOMAINS" ]; then
                # If multiple domains, let user choose
                DOMAIN_COUNT=$(echo "$DOMAINS" | wc -l | tr -d ' ')
                if [ "$DOMAIN_COUNT" -eq 1 ]; then
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

        if [ -z "$CERT_SOURCE" ] || [ -z "$KEY_SOURCE" ]; then
            echo "No SSL certificates found. Continuing without SSL..."
            USE_SSL="no"
        else
            # Certificates found, set USE_SSL to yes
            USE_SSL="yes"
        fi
    fi
fi

# Create config directory for Docker (directory mounts are stable across restarts)
CONFIG_DIR="/tmp/fulcrum-${CONTAINER_NAME}-config"
mkdir -p "$CONFIG_DIR"
TMP_CONFIG="$CONFIG_DIR/fulcrum.conf"
cat > "$TMP_CONFIG" << EOF
datadir = /data
coin = alpha
bitcoind = $RPC_HOST:$RPC_PORT
rpcuser = $RPC_USER
rpcpassword = $RPC_PASS
tcp = 0.0.0.0:50001
peering = false
admin = 8000
stats = 8080
EOF

if [ "$USE_SSL" = "yes" ] && [ -n "$CERT_SOURCE" ] && [ -n "$KEY_SOURCE" ]; then
    cat >> "$TMP_CONFIG" << EOF
ssl = 0.0.0.0:50002
cert = /ssl/fullchain.pem
key = /ssl/privkey.pem
wss = 0.0.0.0:50004
wss_cert = /ssl/fullchain.pem
wss_key = /ssl/privkey.pem
EOF
fi

# Stop existing container
echo ""
echo "Stopping existing container if running..."
docker stop "$CONTAINER_NAME" 2>/dev/null || true
docker rm "$CONTAINER_NAME" 2>/dev/null || true

# Create Docker network if it doesn't exist
echo "Setting up Docker network '$NETWORK_NAME'..."
docker network create "$NETWORK_NAME" 2>/dev/null || true

# Prepare Docker networking options
ADD_HOST_OPTS=""

# Add host.docker.internal mapping for Linux (macOS/Windows have it built-in)
if [ "$RPC_HOST" = "host.docker.internal" ] && [[ "$OS_TYPE" != "macos" ]]; then
    # On Linux, add host-gateway mapping
    ADD_HOST_OPTS="--add-host=host.docker.internal:host-gateway"
fi

# Run Fulcrum in Docker
echo ""
if [ "$USE_SSL" = "yes" ] && [ -n "$CERT_SOURCE" ] && [ -n "$KEY_SOURCE" ]; then
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
    echo "🌐 Network: $NETWORK_NAME"

    $DOCKER_CMD run -d --restart always --name "$CONTAINER_NAME" \
        --network "$NETWORK_NAME" \
        $ADD_HOST_OPTS \
        -p ${PORT_TCP}:50001 -p ${PORT_SSL}:50002 -p ${PORT_WS}:50003 -p ${PORT_WSS}:50004 \
        -v fulcrum-data:/data \
        "$IMAGE_NAME"

    # Copy config and SSL certificates into the running container
    echo "📋 Copying configuration and SSL certificates into container..."
    $DOCKER_CMD exec "$CONTAINER_NAME" mkdir -p /config /ssl
    $DOCKER_CMD cp "$CONFIG_DIR/fulcrum.conf" "$CONTAINER_NAME:/config/fulcrum.conf"
    $DOCKER_CMD cp "$CERT_SOURCE" "$CONTAINER_NAME:/ssl/fullchain.pem"
    $DOCKER_CMD cp "$KEY_SOURCE" "$CONTAINER_NAME:/ssl/privkey.pem"
else
    echo "🚀 Starting Fulcrum without SSL..."
    echo "📦 Container: $CONTAINER_NAME"
    echo "🔒 Using image: $IMAGE_NAME"
    echo "🌐 Network: $NETWORK_NAME"

    docker run -d --restart always --name "$CONTAINER_NAME" \
        --network "$NETWORK_NAME" \
        $ADD_HOST_OPTS \
        -p ${PORT_TCP}:50001 -p ${PORT_SSL}:50002 -p ${PORT_WS}:50003 -p ${PORT_WSS}:50004 \
        -v fulcrum-data:/data \
        "$IMAGE_NAME"

    # Copy config into the running container
    echo "📋 Copying configuration into container..."
    docker exec "$CONTAINER_NAME" mkdir -p /config
    docker cp "$CONFIG_DIR/fulcrum.conf" "$CONTAINER_NAME:/config/fulcrum.conf"
fi

# Clean up temporary config directory from host
rm -rf "$CONFIG_DIR"
echo "🧹 Cleaned up temporary config directory"

echo ""
echo "✅ Fulcrum started successfully in Docker"
echo ""
echo "Available endpoints:"
echo "  - TCP: port $PORT_TCP"
if [ "$USE_SSL" = "yes" ] && [ -n "$CERT_SOURCE" ]; then
    echo "  - SSL/TLS: port $PORT_SSL"
fi
echo "  - WebSocket: port $PORT_WS"
if [ "$USE_SSL" = "yes" ] && [ -n "$CERT_SOURCE" ]; then
    echo "  - WebSocket Secure: port $PORT_WSS"
fi
echo ""
echo "Admin/Stats endpoints (inside container only, not published):"
echo "  - Admin RPC: localhost:8000 (use docker exec)"
echo "  - Stats HTTP: localhost:8080 (use docker exec)"
echo ""
echo "Commands:"
echo "  View logs: docker logs -f $CONTAINER_NAME"
echo "  Stop: docker stop $CONTAINER_NAME"
echo "  Admin (from inside container): docker exec $CONTAINER_NAME /app/FulcrumAdmin -p 8000 getinfo"
echo ""
