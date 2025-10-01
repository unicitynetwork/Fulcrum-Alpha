# Fulcrum-Alpha Docker

Production-ready Docker setup for Fulcrum-Alpha SPV server with SSL/TLS support.

## Features

- ✅ Automatic SSL/TLS configuration with Let's Encrypt
- ✅ Database auto-cleanup to prevent corruption
- ✅ Support for both TCP and SSL Electrum protocols
- ✅ WebSocket and WebSocket Secure support
- ✅ Multiple container support with different SSL certificates
- ✅ Optimized for Alpha cryptocurrency (RandomX support)

## Quick Start

### 1. Build the Image
```bash
cd docker
./build.sh
```

### 2. Run Fulcrum

**Without SSL (TCP only):**
```bash
./run-fulcrum.sh
```

**With SSL (auto-detect certificates):**
```bash
sudo ./run-fulcrum.sh
```

**With specific domain:**
```bash
./run-fulcrum.sh --domain example.com
```

### 3. Test the Connection
```bash
./test-ssl.sh
```

## Network Configuration

The container exposes the following ports:
- **50001** - TCP (standard Electrum protocol)
- **50002** - SSL/TLS (encrypted Electrum protocol)
- **50003** - WebSocket
- **50004** - WebSocket Secure

## SSL/TLS Setup

SSL is automatically configured when certificates are available. The script supports:
- Let's Encrypt certificates (auto-detected from `/etc/letsencrypt/live/`)
- Custom certificates (specify with `--cert` and `--key`)
- Multiple domains (interactive selection)

For detailed SSL setup instructions, see [SSL_SETUP.md](SSL_SETUP.md).

## Configuration

The default configuration connects to an Alpha node on the Docker network:
- Node: `alpha-node:8589`
- Credentials: `user/password`

To use a custom configuration, modify `config/fulcrum.conf`.

## Storage

All blockchain data is stored in a Docker volume `fulcrum-data`. The database is automatically cleaned on each startup to prevent corruption issues.

## Commands

```bash
# View logs
docker logs -f fulcrum-alpha

# Stop the container
docker stop fulcrum-alpha

# Check status
docker ps | grep fulcrum

# Test SSL connection
./test-ssl.sh
```

## Multiple Instances

Run multiple Fulcrum instances with different SSL certificates:

```bash
# Instance 1
./run-fulcrum.sh --domain site1.com --container-name fulcrum-1

# Instance 2
./run-fulcrum.sh --domain site2.com --container-name fulcrum-2
```

## Publishing to Registry

To publish the image to a registry:
```bash
./publish-image.sh
```

## Troubleshooting

If SSL is not working:
1. Check that port 50002 is listening: `nc -zv localhost 50002`
2. Verify certificates are loaded: `docker logs fulcrum-alpha | grep SSL`
3. Test SSL handshake: `echo | openssl s_client -connect localhost:50002`

## Requirements

- Docker 20.10+
- Docker Compose (optional)
- SSL certificates (for SSL/TLS support)
- Alpha node running on the same Docker network

## Support

For issues specific to Docker setup, please check the logs first:
```bash
docker logs fulcrum-alpha
```

For general Fulcrum-Alpha issues, see the main [README](../README.md).