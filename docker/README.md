# Fulcrum-Alpha Docker

Production-ready Docker setup for Fulcrum-Alpha SPV server with SSL/TLS support.

## Features

- ✅ Docker-only deployment (always runs in containers on `alpha-net` network)
- ✅ Automatic SSL/TLS configuration with Let's Encrypt
- ✅ Flexible Alpha RPC endpoint selection (container, localhost, or custom)
- ✅ Localhost scanning for standalone Alpha nodes
- ✅ Database auto-cleanup to prevent corruption
- ✅ Support for TCP, SSL, WebSocket, and WebSocket Secure protocols
- ✅ Cross-platform: Linux (Ubuntu/CentOS) and macOS
- ✅ Interactive and non-interactive modes
- ✅ Optimized for Alpha cryptocurrency (RandomX support)

## Quick Start

### 1. Build the Image
```bash
cd docker
./build.sh
```

### 2. Run Fulcrum

**Interactive mode (recommended for first-time setup):**
```bash
./run-fulcrum.sh
```
The script will guide you through:
- Choosing Alpha RPC endpoint (alpha-node container, localhost, or custom)
- Entering RPC credentials (defaults: user/password)
- Configuring SSL/TLS options
- Selecting Docker image (if multiple available)
- Choosing SSL certificate (if multiple domains available)

> **Note:** Default configuration connects to `alpha-node` container on the `alpha-net` Docker network.

**Non-interactive examples:**

**Connect to alpha-node container (default):**
```bash
./run-fulcrum.sh --rpc-container alpha-node
# Uses default credentials: user/password
```

**Connect to Alpha on localhost (with scanning):**
```bash
./run-fulcrum.sh --rpc-localhost
# Scans localhost:8589 for Alpha node
```

**Custom RPC endpoint:**
```bash
./run-fulcrum.sh --rpc-host 192.168.1.10 --rpc-port 8589 --rpc-user myuser --rpc-pass mypass
```

**With SSL for specific domain:**
```bash
./run-fulcrum.sh --rpc-container alpha-node --domain example.com
```

**Disable SSL explicitly:**
```bash
./run-fulcrum.sh --rpc-container alpha-node --no-ssl
```

**Custom ports (if defaults are in use):**
```bash
./run-fulcrum.sh --rpc-container alpha-node --port-tcp 60001 --port-ssl 60002 --port-ws 60003 --port-wss 60004
```

### 3. Test the Connection
```bash
./test-ssl.sh
```

## Network Configuration

The container **always** runs on the `alpha-net` Docker network and exposes the following ports:
- **50001** - TCP (standard Electrum protocol) - customizable with `--port-tcp`
- **50002** - SSL/TLS (encrypted Electrum protocol) - customizable with `--port-ssl`
- **50003** - WebSocket - customizable with `--port-ws`
- **50004** - WebSocket Secure - customizable with `--port-wss`

**Note:** Admin RPC (8000) and Stats HTTP (8080) are NOT published to the host. Access them via `docker exec` if needed.

## RPC Endpoint Options

### 1. Docker Container (Default)
Connect to Alpha running in another Docker container on the same `alpha-net` network:

**Interactive:**
```
Select Alpha RPC endpoint:
1. Docker container 'alpha-node' (default, same network)  <-- Select this
```

**Non-interactive:**
```bash
./run-fulcrum.sh --rpc-container alpha-node
```

### 2. Localhost (Standalone Alpha)
Connect to Alpha running as a standalone application on the host machine:

**Interactive:**
```
Select Alpha RPC endpoint:
2. Localhost (Alpha running as standalone app on host)  <-- Select this
```
The script will scan `localhost:8589` for availability.

**Non-interactive:**
```bash
./run-fulcrum.sh --rpc-localhost
```
This automatically scans and exits if Alpha is not detected.

### 3. Custom Endpoint
Connect to Alpha at any custom IP address or hostname:

**Interactive:**
```
Select Alpha RPC endpoint:
3. Custom endpoint  <-- Select this
```

**Non-interactive:**
```bash
./run-fulcrum.sh --rpc-host 192.168.1.10 --rpc-port 8589
```

## SSL/TLS Setup

SSL is automatically configured when certificates are available. The script supports:
- Let's Encrypt certificates (auto-detected from `/etc/letsencrypt/live/`)
- Custom certificates (specify with `--cert` and `--key`)
- Multiple domains (interactive selection)
- No SSL mode with `--no-ssl`

For detailed SSL setup instructions, see [SSL_SETUP.md](SSL_SETUP.md).

## Docker Networking

### Always on alpha-net Network
Fulcrum container is **always** attached to the `alpha-net` Docker network. This allows it to communicate with:
- `alpha-node` container (default)
- `explorer` container (if running)
- Other containers on the same network

### Connecting to Localhost
When connecting to Alpha on the host machine (`--rpc-localhost`):
- **Linux**: Uses `--add-host=host.docker.internal:host-gateway`
- **macOS/Windows**: Uses built-in `host.docker.internal`

This ensures the container can reach the host's `localhost:8589`.

## Storage

**Docker Mode:**
All blockchain data is stored in a Docker volume `fulcrum-data`. The database is automatically cleaned on each startup to prevent corruption issues.

## Commands

```bash
# View logs
docker logs -f fulcrum-alpha

# Stop the container
docker stop fulcrum-alpha

# Check status
docker ps | grep fulcrum

# Admin interface (from inside container)
docker exec fulcrum-alpha /app/FulcrumAdmin -p 8000 getinfo

# Stats (from inside container)
docker exec fulcrum-alpha curl http://localhost:8080

# Test SSL connection
./test-ssl.sh

# Check network
docker network inspect alpha-net
```

## Multiple Instances

Run multiple Fulcrum instances with different configurations and custom ports:

```bash
# Instance 1 - alpha-node on default ports
./run-fulcrum.sh --rpc-container alpha-node --container-name fulcrum-1 --no-ssl

# Instance 2 - localhost with SSL on custom ports
./run-fulcrum.sh --rpc-localhost --domain example.com --container-name fulcrum-2 \
  --port-tcp 60001 --port-ssl 60002 --port-ws 60003 --port-wss 60004
```

## Publishing to Registry

To publish the image to a registry:
```bash
./publish-image.sh
```

## Troubleshooting

### SSL Issues
If SSL is not working:
1. Check that port 50002 is listening: `nc -zv localhost 50002`
2. Verify certificates are loaded: `docker logs fulcrum-alpha | grep SSL`
3. Test SSL handshake: `echo | openssl s_client -connect localhost:50002`

### RPC Connection Issues
If seeing "Connection refused" errors:

1. **Check Alpha node is running:**
   ```bash
   # If alpha-node container
   docker ps | grep alpha-node

   # If localhost
   nc -zv localhost 8589
   ```

2. **Verify network:**
   ```bash
   docker network inspect alpha-net
   # Should show both fulcrum-alpha and alpha-node containers
   ```

3. **Check configuration:**
   ```bash
   docker logs fulcrum-alpha | grep "bitcoind ="
   # Should show: bitcoind = alpha-node:8589 (or host.docker.internal:8589)
   ```

4. **Common fixes:**
   - **For alpha-node container**: Ensure both containers are on `alpha-net` network
   - **For localhost**: Use `--rpc-localhost` (not `--rpc-host 127.0.0.1`)
   - **Check credentials**: Default is `user`/`password`, verify with Alpha node config

### Localhost Scanning Fails
If `--rpc-localhost` reports Alpha not found:

```bash
# Manually verify Alpha is listening
nc -zv localhost 8589

# Check Alpha node logs
# (depends on how you're running Alpha)

# Try continuing anyway (interactive mode will prompt)
./run-fulcrum.sh
# Then select option 2 and choose "yes" to continue
```

## Requirements

**For Docker Mode:**
- Docker 20.10+
- Alpha node (in container, localhost, or remote)
- SSL certificates (optional, for SSL/TLS support)

**Supported Platforms:**
- Ubuntu 18.04+
- CentOS 7+/RHEL 7+
- macOS 10.15+
- Other Linux distributions with compatible dependencies

## Default Configuration

- **Container name**: `fulcrum-alpha`
- **Network**: `alpha-net`
- **RPC endpoint**: `alpha-node:8589`
- **RPC credentials**: `user` / `password`
- **Peering**: Disabled
- **Admin RPC**: Enabled on port 8000
- **Stats HTTP**: Enabled on port 8080

## Support

For issues specific to Docker setup, please check the logs first:
```bash
docker logs fulcrum-alpha
```

For general Fulcrum-Alpha issues, see the main [README](../README.md).
