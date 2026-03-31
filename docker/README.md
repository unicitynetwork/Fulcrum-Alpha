# Fulcrum-Alpha Docker

Production Docker setup for Fulcrum-Alpha SPV server with automatic SSL/TLS and HAProxy integration.

## Features

- Automatic SSL certificates via Let's Encrypt (certbot, in-container)
- Automatic HAProxy registration for domain-based routing
- All 4 Electrum protocols: TCP (50001), SSL (50002), WS (50003), WSS (50004)
- Certificate auto-renewal (~12h background checks)
- Based on [ssl-manager](https://github.com/unicitynetwork/ssl-manager) reusable base image

## Quick Start

### 1. Build

```bash
cd docker
./build.sh
```

### 2. Run

**Without SSL (TCP only):**
```bash
./run-fulcrum.sh --no-ssl
```

**With SSL and HAProxy (production):**
```bash
./run-fulcrum.sh \
    --domain electrum.example.com \
    --ssl-email admin@example.com
```

**With SSL, no HAProxy (direct):**
```bash
./run-fulcrum.sh \
    --domain electrum.example.com \
    --ssl-email admin@example.com \
    --no-haproxy
```

### 3. Verify

```bash
# Check logs
docker logs -f fulcrum-alpha

# Check SSL cert
echo | openssl s_client -connect electrum.example.com:443 \
    -servername electrum.example.com 2>/dev/null | \
    openssl x509 -noout -subject -dates

# Check Electrum protocol
echo '{"id":1,"method":"server.version","params":["test","1.4"]}' | \
    nc electrum.example.com 50001

# Check SSL health
curl -sf http://electrum.example.com/_ssl/health | jq .
```

## Configuration

### RPC Endpoint

```bash
# Alpha node in Docker (default)
./run-fulcrum.sh --rpc-container alpha-node

# Alpha on localhost
./run-fulcrum.sh --rpc-localhost

# Custom endpoint
./run-fulcrum.sh --rpc-host 192.168.1.10 --rpc-port 8589 --rpc-user myuser --rpc-pass mypass
```

### SSL Options

| Flag | Description |
|------|-------------|
| `--domain <domain>` | Domain for SSL certificate (enables SSL) |
| `--ssl-email <email>` | Email for Let's Encrypt registration |
| `--ssl-staging` | Use Let's Encrypt staging (test certs, no rate limits) |
| `--ssl-test-mode` | Self-signed cert for development (never use in prod) |
| `--ssl-required <bool>` | Fail if SSL setup fails (default: true) |
| `--no-ssl` | Disable SSL entirely |

### HAProxy Options

| Flag | Description |
|------|-------------|
| `--haproxy-host <host>` | HAProxy container hostname (default: haproxy) |
| `--haproxy-net <network>` | HAProxy Docker network (default: haproxy-net) |
| `--haproxy-api-key <key>` | Bearer token for Registration API |
| `--no-haproxy` | Skip HAProxy, expose ports directly |

### Port Options (direct mode only)

| Flag | Default | Description |
|------|---------|-------------|
| `--port-tcp` | 50001 | Electrum TCP |
| `--port-ssl` | 50002 | Electrum SSL |
| `--port-ws` | 50003 | WebSocket |
| `--port-wss` | 50004 | WebSocket Secure |

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│  HAProxy (haproxy-net)                                      │
│  :80  → Host routing → fulcrum:80 (ssl-manager proxy)       │
│  :443 → SNI routing  → fulcrum:50002 (Electrum SSL)         │
│  :50001 → TCP        → fulcrum:50001 (Electrum TCP)         │
│  :50003 → HTTP       → fulcrum:50003 (Electrum WS)          │
│  :50004 → TCP        → fulcrum:50004 (Electrum WSS)         │
└─────────────────────────────────────────────────────────────┘
          │
┌─────────────────────────────────────────────────────────────┐
│  Fulcrum Container (haproxy-net + alpha-net)                 │
│                                                             │
│  ssl-manager layer:                                         │
│    :80  HTTP reverse proxy (ACME + /_ssl/health)            │
│    certbot (webroot mode, auto-renewal)                     │
│    HAProxy registration client                              │
│                                                             │
│  Fulcrum service:                                           │
│    :50001 TCP Electrum                                      │
│    :50002 SSL Electrum (Let's Encrypt cert)                 │
│    :50003 WebSocket Electrum                                │
│    :50004 WebSocket Secure Electrum                         │
└─────────────────────────────────────────────────────────────┘
          │
┌─────────────────────────────────────────────────────────────┐
│  Alpha Node (alpha-net)                                     │
│    :8589 JSON-RPC                                           │
└─────────────────────────────────────────────────────────────┘
```

## Multi-Network Setup

When using HAProxy, the container joins two networks:
- `haproxy-net` — for HAProxy registration and proxied traffic
- `alpha-net` — for Alpha node RPC

The `run-fulcrum.sh` script uses `docker create` + `docker network connect` + `docker start` to ensure both networks are ready before the entrypoint runs.

## Volumes

| Volume | Mount | Purpose |
|--------|-------|---------|
| `fulcrum-data` | `/data` | Blockchain database + generated config |
| `letsencrypt-data` | `/etc/letsencrypt` | SSL certificates (persist across restarts) |

## Commands

```bash
# View logs
docker logs -f fulcrum-alpha

# Stop
docker stop fulcrum-alpha

# Admin
docker exec fulcrum-alpha FulcrumAdmin -p 8000 getinfo

# Check SSL cert expiry
docker exec fulcrum-alpha certbot certificates

# Force cert renewal
docker exec fulcrum-alpha certbot renew --force-renewal
```

## Publishing

```bash
./publish-image.sh           # Push to GHCR
./publish-image.sh v1.0.0    # Push with version tag
```

## Requirements

- Docker 20.10+
- Alpha node with `txindex=1` (in container, localhost, or remote)
- For SSL: a publicly reachable domain pointing to your server
- For HAProxy: [HAProxy with Registration API](https://github.com/vrogojin/haproxy) on `haproxy-net`
