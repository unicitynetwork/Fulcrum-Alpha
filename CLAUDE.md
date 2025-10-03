# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Fulcrum-Alpha is a specialized fork of Fulcrum SPV server, modified to support the Alpha cryptocurrency which uses RandomX proof-of-work. It's a high-performance C++20 application using Qt framework without GUI components.

## Build Commands

```bash
# Standard build
qmake Fulcrum.pro
make -j8

# Clean build
make clean
qmake Fulcrum.pro
make -j8

# Debug build
qmake "CONFIG+=debug" Fulcrum.pro
make -j8

# Run tests
./Fulcrum --test
./Fulcrum --bench

# Run specific test
./Fulcrum --test "TestName"

# Docker build and run
cd docker
./build.sh                    # Build image
./run-fulcrum.sh              # Run without SSL
sudo ./run-fulcrum.sh         # Run with SSL (auto-detect Let's Encrypt certs)
./run-fulcrum.sh --domain example.com  # Run with specific domain
./test-ssl.sh                 # Test SSL connection

# Docker management
docker logs -f fulcrum-alpha  # View logs
docker stop fulcrum-alpha     # Stop container

# Legacy Docker build (original location)
cd contrib/docker
docker build -t fulcrum-alpha .
```

## Architecture Overview

### Core Components

1. **Controller** (`src/Controller.h/cpp`): Central coordinator managing block synchronization, mempool, and component lifecycle
2. **Storage** (`src/Storage.h/cpp`): RocksDB-based persistence layer for blocks, transactions, and UTXO management
3. **Servers** (`src/Servers.h/cpp`): Electrum protocol server implementation with TCP/SSL/WebSocket support
4. **BitcoinD** (`src/BitcoinD.h/cpp`): RPC client for communicating with Alpha/Bitcoin nodes

### Key Design Patterns

- **Manager Pattern**: Base `Mgr` class provides lifecycle management (startup/cleanup) for major subsystems
- **Mixin Pattern**: `ThreadObjectMixin`, `TimersByNameMixin`, `ProcessAgainMixin` for shared functionality
- **Event-Driven**: Qt signal/slot mechanism for asynchronous operations
- **Multi-threaded**: Thread pools, atomic operations, and thread-safe data structures

### RandomX/Alpha Specifics

- **Extended Headers**: Alpha uses 112-byte headers (vs 80-byte standard) after block 70,228
- **Version Detection**: RandomX blocks identified by version bit `0x20000000`, mixed chain period uses `0x20000002`
- **Trust Model**: Fulcrum trusts the connected node for hash validation (no local RandomX verification)
- **Configuration**: Use `coin=alpha` in config file
- **Mixed Chain Period**: Supports both SHA-256 and RandomX blocks during transition

### Important Files

- `src/bitcoin/block.h`: Extended CBlockHeader with RandomX support (includes `hashRandomX` field)
- `src/Controller.cpp`: Contains coin detection and RandomX block handling logic
- `src/Storage.cpp`: Database schema and block storage implementation
- `src/BTC.h`: Coin detection and Alpha-specific constants
- `src/Mgr.h`: Base manager class providing lifecycle management for subsystems
- `doc/alpha.conf`: Alpha-specific configuration template
- `FulcrumAdmin`: Python 3.6+ admin script for server management
- `docker/run-fulcrum.sh`: Docker runner with SSL auto-detection
- `docker/README.md`: Docker setup documentation with SSL/TLS instructions

## Development Guidelines

### Code Style
- Modern C++20 features preferred
- Qt conventions for naming (camelCase methods, PascalCase classes)
- Header guards use `#pragma once`
- Extensive use of Qt's container classes and utilities

### Testing
- Tests are integrated into main binary (not separate executables)
- Use `--test` flag to run unit tests
- Test files in `src/tests/` directory
- JSON test data in `test/` directory

### Dependencies
- Qt 5.15.2+ (Core, Network modules only)
- RocksDB (static library v9.2.1 included in `staticlibs/`)
- C++20 compiler (GCC 11+, Clang 17+, or MinGW G++ 11+)
- Optional: libzmq 4.x (for ZMQ notifications), jemalloc, libminiupnpc

### Common Tasks

```bash
# Check for RandomX blocks in database
./Fulcrum --query-storage-info

# Validate configuration
./Fulcrum -C /path/to/config.conf --checkconfig

# Debug logging
./Fulcrum -d -v  # Debug verbosity

# Admin operations
./FulcrumAdmin -h localhost -p 8000  # Connect to admin port

# Start server with config
./Fulcrum /path/to/alpha.conf

# Database operations
./Fulcrum --compact  # Compact the database
```

## Docker Deployment

### Production Setup
- The `docker/` directory contains production-ready Docker setup with SSL/TLS support
- `run-fulcrum.sh` provides interactive image selection between local and registry images
- SSL certificates are auto-detected from Let's Encrypt (`/etc/letsencrypt/live/`)
- Database is automatically cleaned on container start to prevent corruption
- Network ports: 50001 (TCP), 50002 (SSL), 50003 (WS), 50004 (WSS)

### Multiple Instances
```bash
./run-fulcrum.sh --domain site1.com --container-name fulcrum-1
./run-fulcrum.sh --domain site2.com --container-name fulcrum-2
```

## Important Notes

1. **Header Size Handling**: When working with block headers, always check if it's a RandomX block (112 bytes) or standard (80 bytes)
2. **Thread Safety**: Storage operations are thread-safe, but always use appropriate locking for shared state
3. **Memory Management**: Uses Qt's parent-child ownership model extensively
4. **Error Handling**: Exceptions are used sparingly; prefer Qt's error signaling patterns
5. **Performance**: Code is optimized for high throughput; avoid unnecessary allocations in hot paths
6. **Trust Boundary**: Fulcrum trusts the connected Alpha node for RandomX hash validation - do not connect to untrusted nodes