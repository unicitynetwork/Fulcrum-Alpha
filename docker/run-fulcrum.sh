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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── App identity (set BEFORE sourcing run-lib.sh) ────────────────────────────
CONTAINER_NAME="${CONTAINER_NAME:-fulcrum-alpha}"
IMAGE_NAME="${FULCRUM_IMAGE:-fulcrum-alpha:latest}"
APP_TITLE="Fulcrum-Alpha SPV Server"

# ─── App networking ───────────────────────────────────────────────────────────
APP_NET="${APP_NET:-alpha-net}"
DATA_VOLUME="${DATA_VOLUME:-fulcrum-data}"
HEALTH_PORT=50001                    # Electrum TCP — first port to come up
SSL_CHECK_PORT=50002                 # Electrum SSL — verify after SSL setup
SSL_HTTPS_PORT="${SSL_HTTPS_PORT:-50002}"
APP_HTTP_PORT="${APP_HTTP_PORT:-0}"   # Fulcrum doesn't serve HTTP

# ─── App defaults ─────────────────────────────────────────────────────────────
RPC_HOST="${RPC_HOST:-alpha-node}"
RPC_PORT="${RPC_PORT:-8589}"
RPC_USER="${RPC_USER:-user}"
RPC_PASS="${RPC_PASS:-password}"
PORT_TCP="${PORT_TCP:-50001}"
PORT_SSL="${PORT_SSL:-50002}"
PORT_WS="${PORT_WS:-50003}"
PORT_WSS="${PORT_WSS:-50004}"

# ─── Source the ssl-manager run library ───────────────────────────────────────
if [ ! -f "${SCRIPT_DIR}/run-lib.sh" ]; then
    echo "ERROR: run-lib.sh not found in ${SCRIPT_DIR}" >&2
    echo "Download it from https://github.com/unicitynetwork/ssl-manager" >&2
    exit 1
fi
source "${SCRIPT_DIR}/run-lib.sh"

# ═══════════════════════════════════════════════════════════════════════════════
# App-specific hooks
# ═══════════════════════════════════════════════════════════════════════════════

app_parse_args() {
    case "$1" in
        --rpc-container)  require_arg "$1" "${2:-}"; RPC_HOST="$2";  return 2 ;;
        --rpc-localhost)  RPC_HOST="host.docker.internal"; return 1 ;;
        --rpc-host)       require_arg "$1" "${2:-}"; RPC_HOST="$2";  return 2 ;;
        --rpc-port)       require_arg "$1" "${2:-}"; RPC_PORT="$2";  return 2 ;;
        --rpc-user)       require_arg "$1" "${2:-}"; RPC_USER="$2";  return 2 ;;
        --rpc-pass)       require_arg "$1" "${2:-}"; RPC_PASS="$2";  return 2 ;;
        --port-tcp)       require_arg "$1" "${2:-}"; PORT_TCP="$2";  return 2 ;;
        --port-ssl)       require_arg "$1" "${2:-}"; PORT_SSL="$2";  return 2 ;;
        --port-ws)        require_arg "$1" "${2:-}"; PORT_WS="$2";   return 2 ;;
        --port-wss)       require_arg "$1" "${2:-}"; PORT_WSS="$2";  return 2 ;;
        *)                return 0 ;;
    esac
}

app_validate() {
    validate_port "PORT_TCP" "$PORT_TCP"
    validate_port "PORT_SSL" "$PORT_SSL"
    validate_port "PORT_WS" "$PORT_WS"
    validate_port "PORT_WSS" "$PORT_WSS"
    validate_port "RPC_PORT" "$RPC_PORT"

    if [ -n "$SSL_DOMAIN" ] && [ "$RPC_PASS" = "password" ]; then
        printf "${C_YELLOW}WARNING: Using default RPC password with SSL enabled${C_RESET}\n" >&2
    fi
}

app_env_args() {
    echo "-e RPC_HOST=$RPC_HOST"
    echo "-e RPC_PORT=$RPC_PORT"
    echo "-e RPC_USER=$RPC_USER"
    echo "-e RPC_PASS=$RPC_PASS"
}

app_port_args() {
    echo "-p ${PORT_TCP}:50001"
    echo "-p ${PORT_SSL}:50002"
    echo "-p ${PORT_WS}:50003"
    echo "-p ${PORT_WSS}:50004"
}

app_docker_args() {
    # Auto-populate HAProxy extra ports for Fulcrum's 4 protocols
    if [ "$USE_HAPROXY" = true ] && [ -n "$HAPROXY_HOST" ] && [ -z "$EXTRA_PORTS" ]; then
        EXTRA_PORTS='[{"listen":50001,"target":50001,"mode":"tcp"},{"listen":50003,"target":50003,"mode":"http"},{"listen":50004,"target":50004,"mode":"tcp"}]'
        echo "-e EXTRA_PORTS=$EXTRA_PORTS"
    fi
}

app_needs_host_gateway() {
    [ "$RPC_HOST" = "host.docker.internal" ]
}

app_print_config() {
    echo "  RPC:        $RPC_HOST:$RPC_PORT"
}

app_help() {
    cat <<'APPHELP'
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
APPHELP
}

app_health_check() {
    local container="$1"

    # 1. Server version (protocol handshake)
    local ver sv
    ver=$(echo '{"id":1,"method":"server.version","params":["healthcheck","1.4"]}' | \
        docker exec -i "$container" nc -w3 localhost 50001 2>/dev/null | head -1)
    sv=$(echo "$ver" | jq -r '.result[0]' 2>/dev/null)
    if [ -n "$sv" ] && [ "$sv" != "null" ]; then
        echo "pass:Server version: $sv"
    else
        echo "fail:server.version not responding"
    fi

    # 2. Blockchain tip (proves node is synced)
    local tip height
    tip=$(echo '{"id":2,"method":"blockchain.headers.subscribe","params":[]}' | \
        docker exec -i "$container" nc -w3 localhost 50001 2>/dev/null | head -1)
    height=$(echo "$tip" | jq -r '.result.height' 2>/dev/null)
    if [ -n "$height" ] && [ "$height" != "null" ] && [ "$height" -gt 0 ] 2>/dev/null; then
        echo "pass:Block height: $height (synced)"
    else
        echo "warn:Could not query block height"
    fi

    # 3. Server banner
    local banner_resp banner
    banner_resp=$(echo '{"id":3,"method":"server.banner","params":[]}' | \
        docker exec -i "$container" nc -w3 localhost 50001 2>/dev/null | head -1)
    banner=$(echo "$banner_resp" | jq -r '.result' 2>/dev/null | head -1)
    if [ -n "$banner" ] && [ "$banner" != "null" ]; then
        echo "pass:Banner: $(echo "$banner" | cut -c1-60)"
    else
        echo "warn:server.banner not responding (non-critical)"
    fi

    # 4. SSL protocol check
    if [ -n "$SSL_DOMAIN" ]; then
        local ssl_ver ssl_name
        ssl_ver=$(echo '{"id":4,"method":"server.version","params":["healthcheck","1.4"]}' | \
            docker exec -i "$container" openssl s_client -connect localhost:50002 -quiet 2>/dev/null | head -1)
        ssl_name=$(echo "$ssl_ver" | jq -r '.result[0]' 2>/dev/null)
        if [ -n "$ssl_name" ] && [ "$ssl_name" != "null" ]; then
            echo "pass:SSL Electrum: $ssl_name"
        else
            echo "fail:SSL Electrum not responding"
        fi
    fi
}

app_summary() {
    echo ""
    echo "Endpoints:"
    if [ "$USE_HAPROXY" = true ] && [ -n "$HAPROXY_HOST" ] && [ -n "$SSL_DOMAIN" ]; then
        echo "  Electrum SSL:  $SSL_DOMAIN:443 (via HAProxy)"
        echo "  Electrum WS:   $SSL_DOMAIN:50003 (via HAProxy)"
        echo "  Electrum WSS:  $SSL_DOMAIN:50004 (via HAProxy)"
    else
        echo "  Electrum TCP:  localhost:$PORT_TCP"
        [ -n "$SSL_DOMAIN" ] && echo "  Electrum SSL:  localhost:$PORT_SSL"
        echo "  WebSocket:     localhost:$PORT_WS"
        [ -n "$SSL_DOMAIN" ] && echo "  WSS:           localhost:$PORT_WSS"
    fi
    echo ""
    echo "  Admin: docker exec \"$CONTAINER_NAME\" FulcrumAdmin -p 8000 getinfo"
}

# ═══════════════════════════════════════════════════════════════════════════════
# Run
# ═══════════════════════════════════════════════════════════════════════════════
ssl_manager_run "$@"
