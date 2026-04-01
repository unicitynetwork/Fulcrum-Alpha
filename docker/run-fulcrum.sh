#!/bin/bash
#
# Fulcrum Docker Runner
#
# Starts the Fulcrum-Alpha SPV server in Docker with optional SSL/TLS
# via the ssl-manager base image and HAProxy auto-registration.
#
# Usage:
#   ./run-fulcrum.sh                                    # TCP only, no SSL
#   ./run-fulcrum.sh --domain electrum.example.com      # SSL with HAProxy
#   ./run-fulcrum.sh --domain electrum.example.com --no-haproxy  # SSL direct
#   ./run-fulcrum.sh --domain electrum.example.com --ssl-email admin@example.com
#
# See docker/specs/FULCRUM_SSL_INTEGRATION_SPEC.md for the full design.

set -euo pipefail

# Helper: validate that a two-argument option received a value
require_arg() {
    if [[ $# -lt 2 || "$2" == --* ]]; then
        printf 'ERROR: %s requires a value\n' "$1" >&2
        exit 1
    fi
}

# Helper: validate a port number
validate_port() {
    local name="$1" value="$2"
    if [ "$value" = "0" ]; then return 0; fi  # 0 means "disabled" for APP_HTTP_PORT
    if ! [[ "$value" =~ ^[0-9]+$ ]] || [ "$value" -lt 1 ] || [ "$value" -gt 65535 ]; then
        printf 'ERROR: %s must be a port number (1-65535), got: %s\n' "$name" "$value" >&2
        exit 1
    fi
}

###############################################################################
# Configuration — edit these or override via environment
###############################################################################

# Container identity
CONTAINER_NAME="${CONTAINER_NAME:-fulcrum-alpha}"
IMAGE_NAME="${FULCRUM_IMAGE:-fulcrum-alpha:latest}"

# ── SSL settings ──────────────────────────────────────────────────────────────
# SSL_DOMAIN: set to your public domain to enable automatic SSL via certbot.
#   Leave empty (or use --no-ssl) to run without SSL.
SSL_DOMAIN="${SSL_DOMAIN:-}"

# SSL_ADMIN_EMAIL: email for Let's Encrypt registration (recommended).
#   If unset, certbot uses --register-unsafely-without-email.
SSL_ADMIN_EMAIL="${SSL_ADMIN_EMAIL:-}"

# SSL_REQUIRED: when true (default if SSL_DOMAIN is set), ssl-setup failure
#   is fatal — the container exits. Set to "false" to allow TCP-only fallback.
SSL_REQUIRED="${SSL_REQUIRED:-true}"

# SSL_STAGING: set to "true" to use Let's Encrypt staging environment
#   (no rate limits, but certs are not trusted by browsers).
SSL_STAGING="${SSL_STAGING:-}"

# SSL_TEST_MODE: set to "true" for development/CI — generates a self-signed
#   cert instead of calling certbot. Never use in production.
SSL_TEST_MODE="${SSL_TEST_MODE:-}"

# ── Application HTTP port ────────────────────────────────────────────────────
# APP_HTTP_PORT: internal port where the application serves HTTP behind the
#   ssl-manager reverse proxy on port 80. The proxy forwards non-ssl traffic
#   here. Set to 0 to disable app forwarding (proxy returns 404 for non-ssl paths).
#   Fulcrum does not serve HTTP, so this defaults to 0 (disabled).
#   Override for services that need HTTP on port 80 (e.g., web apps).
APP_HTTP_PORT="${APP_HTTP_PORT:-0}"

# ── HAProxy extra port mappings ──────────────────────────────────────────────
# EXTRA_PORTS: JSON array of additional port mappings for HAProxy.
#   Each entry: {"listen":<port>,"target":<port>,"mode":"http"|"tcp"}
#   For Fulcrum, this registers Electrum protocol ports with HAProxy:
#   - TCP (50001): raw Electrum protocol
#   - WS  (50003): Electrum over WebSocket (HTTP mode, upgrade supported)
#   - WSS (50004): Electrum over WebSocket Secure (TCP passthrough)
EXTRA_PORTS="${EXTRA_PORTS:-}"

# SSL_HTTPS_PORT: backend port for HTTPS/TLS traffic via HAProxy.
#   HAProxy routes domain:443 → container:SSL_HTTPS_PORT via TCP passthrough.
#   For Fulcrum, this is 50002 (Electrum SSL), not 443.
SSL_HTTPS_PORT="${SSL_HTTPS_PORT:-50002}"

# ── HAProxy settings ─────────────────────────────────────────────────────────
# HAPROXY_HOST: hostname of the HAProxy container on the Docker network.
#   Set to empty or use --no-haproxy to skip HAProxy integration.
HAPROXY_HOST="${HAPROXY_HOST:-haproxy}"

# HAPROXY_API_PORT: port of the HAProxy Registration API.
HAPROXY_API_PORT="${HAPROXY_API_PORT:-8404}"

# HAPROXY_NET: Docker network shared with HAProxy.
HAPROXY_NET="${HAPROXY_NET:-haproxy-net}"

# HAPROXY_API_KEY: optional bearer token for the Registration API.
HAPROXY_API_KEY="${HAPROXY_API_KEY:-}"

# ── Alpha node RPC ───────────────────────────────────────────────────────────
RPC_HOST="${RPC_HOST:-alpha-node}"
RPC_PORT="${RPC_PORT:-8589}"
RPC_USER="${RPC_USER:-user}"
RPC_PASS="${RPC_PASS:-password}"

# ── Docker networking ────────────────────────────────────────────────────────
ALPHA_NET="${ALPHA_NET:-alpha-net}"

# Published ports (direct access mode — ignored when behind HAProxy)
PORT_TCP="${PORT_TCP:-50001}"
PORT_SSL="${PORT_SSL:-50002}"
PORT_WS="${PORT_WS:-50003}"
PORT_WSS="${PORT_WSS:-50004}"

# ── Volumes ──────────────────────────────────────────────────────────────────
DATA_VOLUME="${DATA_VOLUME:-fulcrum-data}"
LETSENCRYPT_VOLUME="${LETSENCRYPT_VOLUME:-letsencrypt-data}"

###############################################################################
# CLI argument parsing
###############################################################################

USE_HAPROXY=true
SHOW_HELP=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --domain)         require_arg "$1" "${2:-}"; SSL_DOMAIN="$2";       shift 2 ;;
        --ssl-email)      require_arg "$1" "${2:-}"; SSL_ADMIN_EMAIL="$2";  shift 2 ;;
        --ssl-staging)    SSL_STAGING="true";     shift ;;
        --ssl-test-mode)  SSL_TEST_MODE="true";   shift ;;
        --ssl-required)   require_arg "$1" "${2:-}"; SSL_REQUIRED="$2";      shift 2 ;;
        --no-ssl)         SSL_DOMAIN="";          shift ;;

        --app-http-port)  require_arg "$1" "${2:-}"; APP_HTTP_PORT="$2"; shift 2 ;;
        --extra-ports)    require_arg "$1" "${2:-}"; EXTRA_PORTS="$2"; shift 2 ;;
        --ssl-https-port) require_arg "$1" "${2:-}"; SSL_HTTPS_PORT="$2"; shift 2 ;;

        --haproxy-host)   require_arg "$1" "${2:-}"; HAPROXY_HOST="$2";      shift 2 ;;
        --haproxy-net)    require_arg "$1" "${2:-}"; HAPROXY_NET="$2";       shift 2 ;;
        --haproxy-api-key) require_arg "$1" "${2:-}"; HAPROXY_API_KEY="$2";  shift 2 ;;
        --no-haproxy)     USE_HAPROXY=false; HAPROXY_HOST=""; shift ;;

        --rpc-container)  require_arg "$1" "${2:-}"; RPC_HOST="$2";          shift 2 ;;
        --rpc-localhost)  RPC_HOST="host.docker.internal"; shift ;;
        --rpc-host)       require_arg "$1" "${2:-}"; RPC_HOST="$2";          shift 2 ;;
        --rpc-port)       require_arg "$1" "${2:-}"; RPC_PORT="$2";          shift 2 ;;
        --rpc-user)       require_arg "$1" "${2:-}"; RPC_USER="$2";          shift 2 ;;
        --rpc-pass)       require_arg "$1" "${2:-}"; RPC_PASS="$2";          shift 2 ;;

        --port-tcp)       require_arg "$1" "${2:-}"; PORT_TCP="$2";          shift 2 ;;
        --port-ssl)       require_arg "$1" "${2:-}"; PORT_SSL="$2";          shift 2 ;;
        --port-ws)        require_arg "$1" "${2:-}"; PORT_WS="$2";           shift 2 ;;
        --port-wss)       require_arg "$1" "${2:-}"; PORT_WSS="$2";          shift 2 ;;

        --container-name) require_arg "$1" "${2:-}"; CONTAINER_NAME="$2";    shift 2 ;;
        --image)          require_arg "$1" "${2:-}"; IMAGE_NAME="$2";        shift 2 ;;

        --help|-h)        SHOW_HELP=true;         shift ;;
        *)
            echo "Unknown option: $1" >&2
            echo "Run with --help for usage." >&2
            exit 1
            ;;
    esac
done

if [ "$SHOW_HELP" = true ]; then
    cat <<'USAGE'
Fulcrum Docker Runner — SSL-aware startup

Usage: run-fulcrum.sh [options]

SSL Configuration:
  --domain <domain>        Domain for automatic SSL (sets SSL_DOMAIN)
  --ssl-email <email>      Email for Let's Encrypt registration
  --ssl-staging            Use Let's Encrypt staging (test certs)
  --ssl-test-mode          Self-signed cert for dev/CI (never use in prod)
  --ssl-required <bool>    Fail if SSL setup fails (default: true)
  --no-ssl                 Run without SSL (TCP + WS only)

Application:
  --app-http-port <port>   App HTTP port behind ssl-manager proxy (default: 0/disabled)
  --extra-ports <json>     Extra HAProxy port mappings (JSON array)
  --ssl-https-port <port>  Backend port for HTTPS via HAProxy (default: 50002)

HAProxy Configuration:
  --haproxy-host <host>    HAProxy hostname (default: haproxy)
  --haproxy-net <network>  HAProxy Docker network (default: haproxy-net)
  --haproxy-api-key <key>  Bearer token for Registration API
  --no-haproxy             Skip HAProxy, expose ports directly

Alpha Node RPC:
  --rpc-container <name>   Alpha container name (default: alpha-node)
  --rpc-localhost           Alpha on host machine
  --rpc-host <host>        Custom RPC hostname/IP
  --rpc-port <port>        RPC port (default: 8589)
  --rpc-user <user>        RPC username (default: user)
  --rpc-pass <pass>        RPC password (default: password)

Ports (direct access mode only, ignored behind HAProxy):
  --port-tcp <port>        Electrum TCP (default: 50001)
  --port-ssl <port>        Electrum SSL (default: 50002)
  --port-ws <port>         WebSocket (default: 50003)
  --port-wss <port>        WebSocket Secure (default: 50004)

Container:
  --container-name <name>  Container name (default: fulcrum-alpha)
  --image <image>          Docker image (default: fulcrum-alpha:latest)

Examples:
  # SSL with HAProxy (production):
  run-fulcrum.sh --domain electrum.example.com --ssl-email admin@example.com

  # SSL direct (no HAProxy, ports exposed on host):
  run-fulcrum.sh --domain electrum.example.com --no-haproxy

  # No SSL (TCP only):
  run-fulcrum.sh --no-ssl

  # Development with self-signed cert:
  run-fulcrum.sh --domain localhost --ssl-test-mode --no-haproxy

  # Custom Alpha node:
  run-fulcrum.sh --domain electrum.example.com \
      --rpc-host 192.168.1.10 --rpc-user myuser --rpc-pass mypass
USAGE
    exit 0
fi

###############################################################################
# Validate critical arguments
###############################################################################

if [ -n "$SSL_DOMAIN" ] && ! printf '%s' "$SSL_DOMAIN" | grep -qE '^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$'; then
    printf 'ERROR: Invalid domain format: '\''%s'\''\n' "$SSL_DOMAIN" >&2
    exit 1
fi

validate_port "APP_HTTP_PORT" "$APP_HTTP_PORT"
validate_port "RPC_PORT" "$RPC_PORT"
validate_port "PORT_TCP" "$PORT_TCP"
validate_port "PORT_SSL" "$PORT_SSL"
validate_port "PORT_WS" "$PORT_WS"
validate_port "PORT_WSS" "$PORT_WSS"
validate_port "SSL_HTTPS_PORT" "$SSL_HTTPS_PORT"

if [ "$APP_HTTP_PORT" = "80" ]; then
    echo "ERROR: APP_HTTP_PORT cannot be 80 — port 80 is reserved for the ssl-manager proxy" >&2
    exit 1
fi

###############################################################################
# Pre-flight checks
###############################################################################

echo "Fulcrum Docker Runner (SSL-aware)"
echo "================================="

# Verify image exists
if ! docker image inspect "$IMAGE_NAME" >/dev/null 2>&1; then
    echo "ERROR: Docker image '$IMAGE_NAME' not found." >&2
    echo "Build it first:  cd docker && ./build.sh" >&2
    exit 1
fi

###############################################################################
# Network setup
###############################################################################

# Ensure the Alpha network exists
if ! docker network inspect "$ALPHA_NET" >/dev/null 2>&1; then
    docker network create "$ALPHA_NET"
fi

# Ensure the HAProxy network exists (if using HAProxy)
if [ "$USE_HAPROXY" = true ] && [ -n "$HAPROXY_HOST" ]; then
    if ! docker network inspect "$HAPROXY_NET" >/dev/null 2>&1; then
        docker network create "$HAPROXY_NET"
    fi
fi

# host.docker.internal on Linux
ADD_HOST_OPTS=()
if [ "$RPC_HOST" = "host.docker.internal" ]; then
    if [[ "$OSTYPE" != "darwin"* ]]; then
        ADD_HOST_OPTS=(--add-host=host.docker.internal:host-gateway)
    fi
fi

###############################################################################
# Stop any existing container with the same name
###############################################################################

if [ -n "$(docker ps -aq --filter "name=^${CONTAINER_NAME}$" 2>/dev/null)" ]; then
    echo "Stopping existing container '$CONTAINER_NAME'..."
    docker stop "$CONTAINER_NAME" 2>/dev/null || true
    docker rm "$CONTAINER_NAME" 2>/dev/null || true
fi

###############################################################################
# Build environment variable list
###############################################################################

ENV_ARGS=(
    -e "RPC_HOST=$RPC_HOST"
    -e "RPC_PORT=$RPC_PORT"
    -e "RPC_USER=$RPC_USER"
    -e "RPC_PASS=$RPC_PASS"
)

if [ -n "$SSL_DOMAIN" ]; then
    ENV_ARGS+=( -e "SSL_DOMAIN=$SSL_DOMAIN" )
    ENV_ARGS+=( -e "SSL_REQUIRED=$SSL_REQUIRED" )
    ENV_ARGS+=( -e "APP_HTTP_PORT=$APP_HTTP_PORT" )
    [ -n "$SSL_ADMIN_EMAIL" ] && ENV_ARGS+=( -e "SSL_ADMIN_EMAIL=$SSL_ADMIN_EMAIL" )
    [ -n "$SSL_STAGING" ]     && ENV_ARGS+=( -e "SSL_STAGING=$SSL_STAGING" )
    [ -n "$SSL_TEST_MODE" ]   && ENV_ARGS+=( -e "SSL_TEST_MODE=$SSL_TEST_MODE" )
fi

if [ "$USE_HAPROXY" = true ] && [ -n "$HAPROXY_HOST" ]; then
    ENV_ARGS+=( -e "HAPROXY_HOST=$HAPROXY_HOST" )
    ENV_ARGS+=( -e "HAPROXY_API_PORT=$HAPROXY_API_PORT" )
    ENV_ARGS+=( -e "SSL_HTTPS_PORT=$SSL_HTTPS_PORT" )
    [ -n "$HAPROXY_API_KEY" ] && ENV_ARGS+=( -e "HAPROXY_API_KEY=$HAPROXY_API_KEY" )
    [ -n "$EXTRA_PORTS" ] && ENV_ARGS+=( -e "EXTRA_PORTS=$EXTRA_PORTS" )
fi

# Default extra ports for Fulcrum when using HAProxy
if [ "$USE_HAPROXY" = true ] && [ -n "$HAPROXY_HOST" ] && [ -z "$EXTRA_PORTS" ]; then
    EXTRA_PORTS='[{"listen":50001,"target":50001,"mode":"tcp"},{"listen":50003,"target":50003,"mode":"http"},{"listen":50004,"target":50004,"mode":"tcp"}]'
    ENV_ARGS+=( -e "EXTRA_PORTS=$EXTRA_PORTS" )
fi

###############################################################################
# Build port publishing list
###############################################################################

# In HAProxy mode, HAProxy owns 80/443 — we only publish Electrum ports for
# direct client access (if desired). Port 80 inside the container is used by
# ssl-manager's HTTP reverse proxy (ACME challenges + app traffic forwarding)
# and is reached via HAProxy, not published directly.
#
# In direct mode, we also publish port 80 when SSL is enabled (for certbot).

PORT_ARGS=()
if [ "$USE_HAPROXY" = true ] && [ -n "$HAPROXY_HOST" ]; then
    # Behind HAProxy: all traffic routed through HAProxy.
    # No ports published — HAProxy owns 80, 443, 50001-50004.
    true  # PORT_ARGS stays empty
else
    # Direct mode: publish all ports
    PORT_ARGS+=(
        -p "${PORT_TCP}:50001"
        -p "${PORT_SSL}:50002"
        -p "${PORT_WS}:50003"
        -p "${PORT_WSS}:50004"
    )
    # Publish port 80 for certbot HTTP-01 challenge
    if [ -n "$SSL_DOMAIN" ]; then
        PORT_ARGS+=( -p "80:80" )
    fi
fi

# Warn if port 80 is in use and we need it for certbot in direct mode
if [ -n "$SSL_DOMAIN" ] && [ "$USE_HAPROXY" != true ]; then
    if ss -tlnp 2>/dev/null | grep -q ':80 ' || netstat -tlnp 2>/dev/null | grep -q ':80 '; then
        echo "WARNING: Port 80 appears to be in use. Certbot HTTP-01 challenge may fail." >&2
        echo "Consider using HAProxy mode (--haproxy-host) or freeing port 80." >&2
    fi
fi

###############################################################################
# Start the container
###############################################################################

echo ""
echo "Configuration:"
echo "  Image:      $IMAGE_NAME"
echo "  Container:  $CONTAINER_NAME"
echo "  RPC:        $RPC_HOST:$RPC_PORT"
if [ -n "$SSL_DOMAIN" ]; then
    echo "  SSL Domain: $SSL_DOMAIN"
    [ -n "$SSL_ADMIN_EMAIL" ] && echo "  SSL Email:  $SSL_ADMIN_EMAIL"
    [ "$SSL_STAGING" = "true" ] && echo "  SSL Mode:   STAGING (test certs)"
    [ "$SSL_TEST_MODE" = "true" ] && echo "  SSL Mode:   TEST (self-signed)"
    echo "  SSL Req'd:  $SSL_REQUIRED"
else
    echo "  SSL:        disabled"
fi
if [ "$USE_HAPROXY" = true ] && [ -n "$HAPROXY_HOST" ]; then
    echo "  HAProxy:    $HAPROXY_HOST (via $HAPROXY_NET)"
else
    echo "  HAProxy:    disabled (direct port access)"
fi

if [ -n "$SSL_DOMAIN" ] && [ "$RPC_PASS" = "password" ]; then
    echo "WARNING: Using default RPC password. Override with --rpc-pass for production." >&2
fi
echo ""

if ! docker run -d \
    --restart on-failure:5 \
    --name "$CONTAINER_NAME" \
    --network "$ALPHA_NET" \
    "${ADD_HOST_OPTS[@]}" \
    -v "${DATA_VOLUME}:/data" \
    -v "${LETSENCRYPT_VOLUME}:/etc/letsencrypt" \
    "${PORT_ARGS[@]}" \
    "${ENV_ARGS[@]}" \
    "$IMAGE_NAME"; then
    echo "ERROR: Failed to start container. Check port conflicts and docker logs." >&2
    exit 1
fi

# If HAProxy mode, connect the container to the HAProxy network as well
if [ "$USE_HAPROXY" = true ] && [ -n "$HAPROXY_HOST" ]; then
    echo "Connecting to HAProxy network '$HAPROXY_NET'..."
    if ! docker network connect "$HAPROXY_NET" "$CONTAINER_NAME" 2>/dev/null; then
        # Check if already connected (not an error)
        if docker inspect "$CONTAINER_NAME" --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}' 2>/dev/null | grep -q "$HAPROXY_NET"; then
            echo "Container already connected to '$HAPROXY_NET'"
        else
            echo "ERROR: Failed to connect container to HAProxy network '$HAPROXY_NET'" >&2
            docker stop "$CONTAINER_NAME" >/dev/null 2>&1 || true
            docker rm "$CONTAINER_NAME" >/dev/null 2>&1 || true
            exit 1
        fi
    fi
fi

###############################################################################
# Health check — wait for Fulcrum to be ready
###############################################################################

echo ""
echo "Waiting for Fulcrum to start..."

HEALTH_TIMEOUT=120
HEALTH_ELAPSED=0
HEALTH_STATUS=""

while [ "$HEALTH_ELAPSED" -lt "$HEALTH_TIMEOUT" ]; do
    # Check if container is still running
    if ! docker ps -q --filter "name=^${CONTAINER_NAME}$" 2>/dev/null | grep -q .; then
        echo ""
        echo "ERROR: Container '$CONTAINER_NAME' exited unexpectedly." >&2
        echo "Last logs:" >&2
        docker logs "$CONTAINER_NAME" 2>&1 | tail -15 >&2
        exit 1
    fi

    # Check if Electrum TCP port is listening (Fulcrum is ready)
    if docker exec "$CONTAINER_NAME" nc -z localhost 50001 2>/dev/null; then
        # If SSL is configured, also check SSL port
        if [ -n "$SSL_DOMAIN" ]; then
            if docker exec "$CONTAINER_NAME" nc -z localhost 50002 2>/dev/null; then
                HEALTH_STATUS="healthy (TCP + SSL)"
                break
            else
                # SSL setup may still be running — show progress
                printf "\r  SSL setup in progress... (%ds)" "$HEALTH_ELAPSED"
            fi
        else
            HEALTH_STATUS="healthy (TCP)"
            break
        fi
    else
        printf "\r  Starting up... (%ds)" "$HEALTH_ELAPSED"
    fi

    sleep 2
    HEALTH_ELAPSED=$((HEALTH_ELAPSED + 2))
done

echo ""

if [ -n "$HEALTH_STATUS" ]; then
    echo "Fulcrum is $HEALTH_STATUS"

    # Show block height
    BLOCK_INFO=$(docker logs "$CONTAINER_NAME" 2>&1 | grep "Block height" | tail -1 | sed 's/.*\] //')
    [ -n "$BLOCK_INFO" ] && echo "  $BLOCK_INFO"

    # Show SSL cert info if applicable
    if [ -n "$SSL_DOMAIN" ]; then
        CERT_INFO=$(docker exec "$CONTAINER_NAME" openssl x509 -enddate -noout \
            -in "/etc/letsencrypt/live/${SSL_DOMAIN}/fullchain.pem" 2>/dev/null | sed 's/notAfter=//')
        [ -n "$CERT_INFO" ] && echo "  SSL cert expires: $CERT_INFO"
    fi
else
    echo "WARNING: Fulcrum did not become healthy within ${HEALTH_TIMEOUT}s"
    echo "  It may still be starting (SSL setup, initial sync, etc.)"
    echo "  Check logs: docker logs -f $CONTAINER_NAME"
fi

###############################################################################
# Summary
###############################################################################

echo ""
echo "Fulcrum started: $CONTAINER_NAME"
echo ""
echo "Endpoints:"
echo "  Electrum TCP:  localhost:$PORT_TCP"
if [ -n "$SSL_DOMAIN" ]; then
    if [ "$USE_HAPROXY" = true ] && [ -n "$HAPROXY_HOST" ]; then
        echo "  Electrum SSL:  $SSL_DOMAIN:443 (via HAProxy -> :$SSL_HTTPS_PORT)"
        echo "  Electrum WS:   $SSL_DOMAIN:50003 (via HAProxy)"
        echo "  Electrum WSS:  $SSL_DOMAIN:50004 (via HAProxy)"
    else
        echo "  Electrum SSL:  localhost:$PORT_SSL"
        echo "  WebSocket:     localhost:$PORT_WS"
        echo "  WSS:           localhost:$PORT_WSS"
    fi
else
    echo "  WebSocket:     localhost:$PORT_WS"
fi
echo ""
echo "Commands:"
echo "  Logs:    docker logs -f \"$CONTAINER_NAME\""
echo "  Stop:    docker stop \"$CONTAINER_NAME\""
echo "  Admin:   docker exec \"$CONTAINER_NAME\" FulcrumAdmin -p 8000 getinfo"
echo "  SSL:     docker exec \"$CONTAINER_NAME\" certbot certificates"
