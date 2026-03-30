# IMPLEMENTATION PLAN: SSL Management and HAProxy Registration System

## System Overview

This plan covers three major components across two repositories:

1. **HAProxy Registration API** (haproxy repo) -- A custom HAProxy Docker image with an embedded Node.js REST API for dynamic backend registration
2. **ssl-manager Base Image** (Fulcrum-Alpha repo) -- A reusable Docker base image providing certbot, HAProxy registration, and HTTP reverse proxy
3. **Fulcrum SSL Integration** (Fulcrum-Alpha repo) -- Migration of the Fulcrum runtime image to use ssl-manager as its base, replacing the host-injection SSL flow

Two test suites validate the system:
- HAProxy E2E tests (haproxy repo)
- SSL management integration tests (Fulcrum-Alpha repo)

## Dependency Graph

```
                                 ssl-manager base image (1B)
                                /                            \
HAProxy custom image (1A) ----+                               +-- Fulcrum image (2A)
        |                      \                             /        |
        |                       +-- ssl-manager scripts (1C)         |
        |                                                            |
HAProxy E2E tests (3A)                               Fulcrum SSL tests (3B)
```

Key independence relationships:
- HAProxy image (1A) has ZERO dependency on ssl-manager
- ssl-manager Dockerfile (1B) and ssl-manager scripts (1C) can proceed in parallel; scripts are COPYed at image build time
- HAProxy Registration API code (inside 1A) and ssl-manager scripts (inside 1C) are completely independent codebases
- Test code (3A, 3B) can be written before images are built -- tests only need images at runtime

---

## Phase 0: Prerequisites (serial)

### Task 0.1: Verify Docker Environment
- **Description**: Confirm Docker is installed, haproxy-net exists, and both repos are in a clean git state
- **Input**: Host system
- **Output**: Confirmation that prerequisites are met
- **Dependencies**: None
- **Estimated complexity**: S
- **Agent type**: bash-pro
- **Repo**: Both
- **Detailed instructions**:
  1. Run `docker --version` and `docker compose version` to confirm Docker is available
  2. Run `docker network ls | grep haproxy-net` to confirm the network exists; if not, run `docker network create haproxy-net`
  3. Run `git -C /home/vrogojin/haproxy status` and `git -C /home/vrogojin/Fulcrum-Alpha status` to confirm clean working trees
  4. Verify Node.js is available on the host for potential local testing: `node --version` (need v18+)

---

## Phase 1: Foundation (parallel streams)

### Stream 1A: HAProxy Custom Image + Registration API

#### Task 1A.1: Create HAProxy Dockerfile
- **Task ID**: 1A.1
- **Description**: Create the Dockerfile for the custom HAProxy image that includes Node.js and the Registration API
- **Input**: Spec section 7.3 of `/home/vrogojin/haproxy/specs/REGISTRATION_API_SPEC.md` (lines 1104-1141). Existing templates at `/home/vrogojin/haproxy/templates/`
- **Output**: `/home/vrogojin/haproxy/Dockerfile`
- **Dependencies**: None
- **Estimated complexity**: S
- **Agent type**: bash-pro
- **Repo**: haproxy
- **Detailed instructions**:
  Create `/home/vrogojin/haproxy/Dockerfile` with this exact content structure:
  ```
  FROM haproxy:lts
  ```
  Install: `nodejs`, `npm`, `procps`, `curl`, `socat` (socat for master CLI socket access). Use `apt-get update && apt-get install -y --no-install-recommends ... && rm -rf /var/lib/apt/lists/*`.

  COPY these files into the image:
  - `generate-config.sh` -> `/usr/local/bin/generate-config.sh`
  - `templates/` -> `/usr/local/share/haproxy/templates/`
  - `registration-api.mjs` -> `/usr/local/bin/registration-api.mjs`
  - `entrypoint.sh` -> `/usr/local/bin/entrypoint.sh`

  Set permissions: `chmod +x` on entrypoint.sh and generate-config.sh.

  Create directories: `/etc/haproxy/conf.d`, `/etc/haproxy/maps`, `/etc/haproxy/state`.

  Create symlinks so template map paths resolve correctly:
  ```
  ln -sf /etc/haproxy/maps /usr/local/etc/haproxy/maps
  ln -sf /etc/haproxy/conf.d /usr/local/etc/haproxy/conf.d
  ```

  EXPOSE: 80 443 8000 8404

  ENTRYPOINT: `/usr/local/bin/entrypoint.sh`

  Add HEALTHCHECK:
  ```
  HEALTHCHECK --interval=10s --timeout=5s --start-period=15s --retries=3 \
      CMD curl -sf http://localhost:8404/v1/health || exit 1
  ```

#### Task 1A.2: Create HAProxy Entrypoint Script
- **Task ID**: 1A.2
- **Description**: Create the container entrypoint that starts the Registration API in a restart loop and then exec's into HAProxy in master-worker mode
- **Input**: Spec section 3.4 of `/home/vrogojin/haproxy/specs/REGISTRATION_API_SPEC.md` (lines 616-685). This section contains exact pseudocode for the entrypoint
- **Output**: `/home/vrogojin/haproxy/entrypoint.sh`
- **Dependencies**: None
- **Estimated complexity**: M
- **Agent type**: bash-pro
- **Repo**: haproxy
- **Detailed instructions**:
  Create `/home/vrogojin/haproxy/entrypoint.sh`. The script must:

  1. `set -e` and define path constants:
     - `DOMAINS_MAP="/etc/haproxy/domains.map"`
     - `CONF_DIR="/etc/haproxy/conf.d"`
     - `MAPS_DIR="/etc/haproxy/maps"`
     - `TEMPLATES_DIR="/usr/local/share/haproxy/templates"`

  2. Create `domains.map` if it does not exist (first run). Write a comment header explaining the format including extra port fields. The format is: `domain container http_port https_port [map_port] [extra:listen:target:mode] ...`

  3. Export environment variables for generate-config.sh:
     - `HAPROXY_CONF_DIR`, `HAPROXY_MAPS_DIR`, `HAPROXY_TEMPLATES_DIR`, `HAPROXY_DOMAINS_MAP`

  4. Run `/usr/local/bin/generate-config.sh` to generate initial config from any existing domains.map entries.

  5. Start the Registration API in a background restart loop with exponential backoff (exactly as shown in spec lines 646-677). The loop runs `node /usr/local/bin/registration-api.mjs`. Backoff starts at 2s, doubles up to 60s max, resets after 60s of stability. Stop after 10 consecutive failures.

  6. Trap SIGTERM and SIGINT to kill the API restart loop and its children.

  7. `exec haproxy -W -f "$CONF_DIR" -S /var/run/haproxy-master.sock` -- this makes HAProxy PID 1 in master-worker mode.

  The script must be idempotent -- running it multiple times with the same volume state produces the same result.

#### Task 1A.3: Create Registration API (registration-api.mjs)
- **Task ID**: 1A.3
- **Description**: Implement the Node.js HTTP Registration API server as a single ES module file with zero npm dependencies
- **Input**: Full spec at `/home/vrogojin/haproxy/specs/REGISTRATION_API_SPEC.md`. Key sections: 2.3 (endpoints), 3.5-3.6 (implementation), 4.1 (config generation flow), 5.3-5.7 (reload strategy), 6.1-6.3 (data model), 8.1-8.3 (error handling), 10.1-10.5 (security)
- **Output**: `/home/vrogojin/haproxy/registration-api.mjs`
- **Dependencies**: None
- **Estimated complexity**: L
- **Agent type**: javascript-pro
- **Repo**: haproxy
- **Detailed instructions**:
  Create `/home/vrogojin/haproxy/registration-api.mjs` using ONLY Node.js built-in modules: `node:http`, `node:fs`, `node:path`, `node:child_process`, `node:util`, `node:os`, `node:dns`.

  **Constants** (from environment):
  - `PORT = parseInt(process.env.HAPROXY_API_PORT || '8404')`
  - `DOMAINS_MAP = process.env.HAPROXY_DOMAINS_MAP || '/etc/haproxy/domains.map'`
  - `CONF_DIR = process.env.HAPROXY_CONF_DIR || '/etc/haproxy/conf.d'`
  - `TEMPLATES_DIR = process.env.HAPROXY_TEMPLATES_DIR || '/usr/local/share/haproxy/templates'`
  - `MAPS_DIR = process.env.HAPROXY_MAPS_DIR || '/etc/haproxy/maps'`
  - `STATE_DIR = '/etc/haproxy/state'`
  - `API_KEY = process.env.HAPROXY_API_KEY || ''`
  - `MAX_REGISTRATIONS = parseInt(process.env.MAX_REGISTRATIONS || '100')`
  - `RESERVED_PORTS = [80, 443, 8000, 8404]`

  **Endpoints** (all under `/v1/`):

  1. **POST /v1/backends** - Register a backend
     - Parse JSON body (handle malformed JSON with 400)
     - Validate fields per spec Section 2.3.1:
       - `domain`: required, regex `^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$`, max 253 chars, max 63 per label, must contain at least one dot
       - `container`: required, regex `[a-zA-Z0-9][a-zA-Z0-9_.-]*`
       - `http_port`: integer 1-65535 or null, defaults to 80
       - `https_port`: integer 1-65535 or null, defaults to 443
       - At least one of http_port/https_port must be non-null
       - `map_port`: integer 1-65535 or null, defaults to null
       - `extra_ports`: array or null, max 10 entries. Each: `{listen: int, target: int, mode: "http"|"tcp"}`. listen must not be in RESERVED_PORTS. All registrations sharing the same listen port must use the same mode (MODE_CONFLICT 409).
     - Check MAX_REGISTRATIONS limit (429 with LIMIT_EXCEEDED)
     - Check authentication if API_KEY is set
     - Acquire file lock (O_EXCL lock file at `/etc/haproxy/state/domains.lock`, poll every 200ms with 60s deadline)
     - Parse existing domains.map entries
     - Check for conflict: same domain, different container or different ports -> 409 DOMAIN_CONFLICT
     - Check for idempotent match: same domain, same everything -> 200 OK with `"message": "Already registered with identical configuration"`
     - New registration: append line to domains.map in format `domain container http_port https_port [map_port] [extra:listen:target:mode ...]`
       - null ports become `-` in the file
       - If extra_ports present and map_port null, write `-` for map_port to maintain positional alignment
     - Trigger debounced reload (2s timer via setTimeout/clearTimeout)
     - Run generate-config.sh via `child_process.execFile` with 30s timeout
     - Validate config: `haproxy -c -f /etc/haproxy/conf.d` with 30s timeout
     - If validation fails: roll back domains.map from backup, re-run generate-config.sh, return 500 RELOAD_FAILED
     - Record pre-reload worker PIDs, send SIGUSR2 to HAProxy master
     - Poll for new worker PIDs (200ms interval, 10s timeout) per spec Section 5.7
     - Update state/registrations.json with created_at timestamp
     - Release file lock
     - Return 201 with response body

  2. **GET /v1/backends** - List all backends
     - Parse domains.map, merge with registrations.json for created_at
     - Return `{backends: [...], count: N}`

  3. **GET /v1/backends/:domain** - Get specific backend
     - Look up in domains.map, return 200 or 404

  4. **DELETE /v1/backends/:domain** - Unregister backend
     - If API_KEY not set: verify container ownership by comparing source IP against Docker DNS resolution of registered container name (use `node:dns` to resolve). Return 403 OWNERSHIP_MISMATCH on failure
     - Acquire lock, remove line, regenerate, reload, release
     - Return 204 on success, 404 if not found

  5. **POST /v1/reload** - Force reload
     - Regenerate config from current domains.map, reload HAProxy
     - Return 200 with backends_count and reload_timestamp

  6. **GET /v1/health** - Health check (exempt from auth)
     - Return haproxy_pid, uptime, api_version "1.0", backends_count, status
     - Check if file lock has been held > 30s -> status "degraded"
     - If HAProxy master PID not found -> 503 status "unhealthy"

  **Helper functions needed**:
  - `getHaproxyMasterPid()`: Scan /proc for haproxy process with PPID 0 or 1 (see spec Section 5.3, lines 900-921)
  - `getHaproxyWorkerPids(masterPid)`: Scan /proc for haproxy processes with PPID = masterPid
  - `acquireLock(timeout)`: Create lock file with O_EXCL, poll until acquired or timeout
  - `releaseLock()`: Remove lock file
  - `parseDomainsMmap()`: Read domains.map, skip comments/empty lines, parse each line into structured object including extra ports
  - `sendJson(res, status, data)`: Standard JSON response helper
  - `readBody(req)`: Promise-based request body reader with 1MB max
  - `reloadHaproxy()`: Generate config, validate, signal, confirm -- the full reload sequence with debouncing

  **Authentication** (spec Section 10.2):
  - When `HAPROXY_API_KEY` is set, check `Authorization: Bearer <key>` header on all endpoints except `/v1/health`
  - Return 401 UNAUTHORIZED for missing/invalid key

  **File format for domains.map** (spec Section 6.1):
  ```
  domain  container  http_port  https_port  [map_port]  [extra:listen:target:mode] ...
  ```

  **Debouncing** (spec Section 10.5):
  - Use a single `setTimeout` timer. Each mutation resets it. When it fires, run the full reload sequence.
  - The API response should block until the reload completes, not return immediately.

#### Task 1A.4: Update generate-config.sh for Container Use
- **Task ID**: 1A.4
- **Description**: Modify generate-config.sh to accept directory paths via environment variables and support extra port fields in domains.map
- **Input**: Existing script at `/home/vrogojin/haproxy/generate-config.sh`. Spec sections 4.3 (lines 823-836) and 2.4 (lines 459-541) of REGISTRATION_API_SPEC.md
- **Output**: `/home/vrogojin/haproxy/generate-config.sh` (modified in place)
- **Dependencies**: None
- **Estimated complexity**: M
- **Agent type**: bash-pro
- **Repo**: haproxy
- **Detailed instructions**:
  Modify `/home/vrogojin/haproxy/generate-config.sh` with these changes:

  1. **Parameterize paths** using environment variables with fallbacks:
     ```bash
     CONF_DIR="${HAPROXY_CONF_DIR:-./conf.d}"
     MAPS_DIR="${HAPROXY_MAPS_DIR:-./maps}"
     TEMPLATES_DIR="${HAPROXY_TEMPLATES_DIR:-./templates}"
     DOMAINS_MAP="${HAPROXY_DOMAINS_MAP:-./domains.map}"
     ```
     Replace all hardcoded `conf.d`, `maps`, `templates`, and `domains.map` references with these variables.

  2. **Remove the `cd "$(dirname "$0")"` line** -- the script should work with absolute paths from env vars. Keep it only as a fallback when env vars are not set.

  3. **Add extra port support**: After parsing the 5 standard fields (domain, container, http_port, https_port, map_port), look for additional fields matching `extra:*`. Parse each as `extra:listen:target:mode`.

  4. **Generate extra port frontends and backends**: For each extra port entry:
     - Add a line to `maps/extra-<listen>-domains.map`: `domain backend-name`
     - Add a backend block to `conf.d/20-backends.cfg`:
       ```
       backend <container>-<mode>-<listen>
           mode <mode>
           server <container> <container>:<target> init-addr last,libc,none
       ```
     - Track unique listen ports and their modes

  5. **Generate extra frontends file** (`conf.d/30-extra-frontends.cfg`): For each unique listen port:
     - HTTP mode:
       ```
       frontend extra-http-<port>
           mode http
           bind *:<port>
           use_backend %[req.hdr(host),lower,map(/etc/haproxy/maps/extra-<port>-domains.map,no-match)]
       ```
     - TCP mode with multiple domains (SNI routing):
       ```
       frontend extra-tcp-<port>
           mode tcp
           bind *:<port>
           tcp-request inspect-delay 5s
           tcp-request content accept if { req_ssl_hello_type 1 }
           use_backend %[req.ssl_sni,lower,map(/etc/haproxy/maps/extra-<port>-domains.map,no-match-tcp)]
       ```
     - TCP mode with single domain (default_backend, no SNI):
       ```
       frontend extra-tcp-<port>
           mode tcp
           bind *:<port>
           default_backend <backend-name>
       ```

  6. **Use the correct map paths**: The templates reference `/usr/local/etc/haproxy/maps/`. The symlinks created in the Dockerfile handle this, so the script should generate map paths as `/etc/haproxy/maps/` when running inside the container (i.e., when HAPROXY_MAPS_DIR is set to `/etc/haproxy/maps`). For backward compatibility when running on the host, keep the original path format.

  7. **Add `hard-stop-after 30s`** to the generated `00-global.cfg` or ensure it exists in the template.

  8. **Preserve comments and empty lines** from domains.map when the script reads it.

#### Task 1A.5: Update docker-compose.yml
- **Task ID**: 1A.5
- **Description**: Update the HAProxy docker-compose.yml to use the custom image with build context, named volume, and extra ports
- **Input**: Existing `/home/vrogojin/haproxy/docker-compose.yml`. Spec section 7.1 (lines 1060-1090) of REGISTRATION_API_SPEC.md
- **Output**: `/home/vrogojin/haproxy/docker-compose.yml` (modified in place)
- **Dependencies**: 1A.1
- **Estimated complexity**: S
- **Agent type**: bash-pro
- **Repo**: haproxy
- **Detailed instructions**:
  Replace the contents of `/home/vrogojin/haproxy/docker-compose.yml` with:
  ```yaml
  services:
    haproxy:
      build:
        context: .
        dockerfile: Dockerfile
      container_name: haproxy
      restart: unless-stopped
      ports:
        - "80:80"
        - "443:443"
        - "8000:8000"
        - "50001-50004:50001-50004"
        # Port 8404 is NOT published -- API is internal only
      volumes:
        - haproxy-data:/etc/haproxy
      networks:
        - haproxy-net

  volumes:
    haproxy-data:

  networks:
    haproxy-net:
      external: true
  ```

  Key changes from current:
  - `image: haproxy:lts` -> `build: .` (custom image)
  - `./conf.d:ro` and `./maps:ro` bind mounts -> `haproxy-data:/etc/haproxy` named volume
  - Added `50001-50004:50001-50004` for Electrum protocol ports
  - Removed explicit `command:` (entrypoint handles it)

#### Task 1A.6: Update 00-global.cfg Template
- **Task ID**: 1A.6
- **Description**: Add `hard-stop-after 30s` to the global config template
- **Input**: `/home/vrogojin/haproxy/templates/00-global.cfg`
- **Output**: `/home/vrogojin/haproxy/templates/00-global.cfg` (modified)
- **Dependencies**: None
- **Estimated complexity**: S
- **Agent type**: bash-pro
- **Repo**: haproxy
- **Detailed instructions**:
  Add `hard-stop-after 30s` to the `global` section in `/home/vrogojin/haproxy/templates/00-global.cfg`. The file should become:
  ```
  global
      log stdout format raw local0
      maxconn 4096
      hard-stop-after 30s

  defaults
      log global
      option dontlognull
      timeout connect 5s
      timeout client 30s
      timeout server 30s
      retries 3
      option redispatch
  ```

---

### Stream 1B: ssl-manager Base Image

#### Task 1B.1: Create ssl-manager Dockerfile
- **Task ID**: 1B.1
- **Description**: Create the Dockerfile for the ssl-manager base image
- **Input**: Spec section 2.1 of `/home/vrogojin/Fulcrum-Alpha/docker/specs/SSL_MANAGEMENT_ARCHITECTURE.md` (lines 46-91)
- **Output**: `/home/vrogojin/Fulcrum-Alpha/docker/Dockerfile.ssl-manager`
- **Dependencies**: None
- **Estimated complexity**: S
- **Agent type**: bash-pro
- **Repo**: Fulcrum-Alpha
- **Detailed instructions**:
  Create `/home/vrogojin/Fulcrum-Alpha/docker/Dockerfile.ssl-manager`:
  ```dockerfile
  FROM debian:trixie-slim

  RUN apt-get update && apt-get install -y --no-install-recommends \
          certbot \
          curl \
          jq \
          openssl \
          netcat-openbsd \
          python3 \
          procps \
          ca-certificates \
      && apt-get clean \
      && rm -rf /var/lib/apt/lists/*

  # SSL management scripts
  COPY scripts/ssl-setup.sh       /usr/local/bin/ssl-setup
  COPY scripts/ssl-renew.sh       /usr/local/bin/ssl-renew
  COPY scripts/haproxy-register.sh /usr/local/bin/haproxy-register
  COPY scripts/ssl-verify.sh      /usr/local/bin/ssl-verify
  COPY scripts/ssl-http-proxy.py  /usr/local/bin/ssl-http-proxy

  RUN chmod +x /usr/local/bin/ssl-setup \
               /usr/local/bin/ssl-renew \
               /usr/local/bin/haproxy-register \
               /usr/local/bin/ssl-verify \
               /usr/local/bin/ssl-http-proxy

  # Webroot for ACME challenges
  RUN mkdir -p /var/www/acme-challenge/.well-known/acme-challenge

  # Let's Encrypt certificate storage
  VOLUME ["/etc/letsencrypt"]

  # HTTP reverse proxy port (shared: ACME + app forwarding)
  EXPOSE 80

  # Default: no app HTTP port (proxy returns 502 for non-ssl paths)
  ENV APP_HTTP_PORT=0
  ```

  Note: The scripts directory path is relative to the docker build context. The build context for ssl-manager should be the `docker/` directory within Fulcrum-Alpha.

---

### Stream 1C: ssl-manager Scripts (all scripts are independent of each other)

#### Task 1C.1: Create ssl-http-proxy.py
- **Task ID**: 1C.1
- **Description**: Create the Python HTTP reverse proxy that shares port 80 between ACME challenges, nonce verification, health endpoints, and application traffic forwarding
- **Input**: Spec section 3.1 of SSL_MANAGEMENT_ARCHITECTURE.md (lines 258-360 for detailed behavior) plus the proxy hardening requirements
- **Output**: `/home/vrogojin/Fulcrum-Alpha/docker/scripts/ssl-http-proxy.py`
- **Dependencies**: None
- **Estimated complexity**: L
- **Agent type**: python-pro
- **Repo**: Fulcrum-Alpha
- **Detailed instructions**:
  Create `/home/vrogojin/Fulcrum-Alpha/docker/scripts/ssl-http-proxy.py`.

  This is a Python 3 HTTP reverse proxy using only the standard library (`http.server`, `urllib.request`, `threading`, `argparse`, `json`, `os`, `datetime`, `pathlib`).

  **Command-line arguments**:
  - `--port` (default: 80): Listen port
  - `--webroot` (required): Path to ACME webroot directory
  - `--upstream` (default: "127.0.0.1:0"): Upstream app address (host:port). Port 0 means disabled.
  - `--cert-dir` (default: ""): Path to /etc/letsencrypt/live/<domain>/ for health endpoint

  **Request routing** (order matters):
  1. `GET /.well-known/acme-challenge/*` -> Serve static file from `webroot/.well-known/acme-challenge/`. Limit file size to 1KB. Return 404 if file not found.
  2. `POST /_ssl/nonce/{nonce}` -> Store nonce in an in-memory dict (thread-safe). Return 200 with empty body.
  3. `GET /_ssl/nonce/{nonce}` -> If nonce exists in memory, return 200 with the nonce string as body. If not, return 404.
  4. `DELETE /_ssl/nonce/{nonce}` -> Remove nonce from memory. Return 200.
  5. `GET /_ssl/health` -> Return JSON with certificate status:
     ```json
     {
       "status": "ok",
       "domain": "<from cert-dir path>",
       "cert_expires": "ISO8601",
       "days_remaining": N,
       "last_renewal_check": "ISO8601 or null",
       "app_upstream": "host:port",
       "app_reachable": true/false
     }
     ```
     Read cert expiry from the cert file using `openssl` (subprocess) or Python's `ssl` module.
  6. All other paths -> Forward to upstream (`localhost:APP_HTTP_PORT`). If upstream port is 0 or connection fails, return 502 Bad Gateway.

  **Hardening requirements** (from spec):
  - Use `ThreadingHTTPServer` (not single-threaded)
  - 30-second timeout for upstream connections
  - 5-second connect timeout for upstream
  - 8KB max header size (reject with 431)
  - 10MB max request body for proxied requests (configurable via `PROXY_MAX_BODY_SIZE` env var). 1KB limit for ACME challenge paths.
  - Reserved port validation: APP_HTTP_PORT must not be 80, 8404, or any EXPOSE'd port. Reject at startup.
  - No WebSocket support

  **Thread safety**: The nonce dict must use a `threading.Lock`.

#### Task 1C.2: Create ssl-setup.sh
- **Task ID**: 1C.2
- **Description**: Create the main SSL orchestration script that handles HAProxy detection/registration, domain reachability verification, certificate acquisition, and renewal loop startup
- **Input**: Spec section 3.2 of SSL_MANAGEMENT_ARCHITECTURE.md (lines 228-483). Spec section 3 of FULCRUM_SSL_INTEGRATION_SPEC.md (lines 150-313). Exit codes from section 7.1 (lines 969-978).
- **Output**: `/home/vrogojin/Fulcrum-Alpha/docker/scripts/ssl-setup.sh`
- **Dependencies**: None (will use 1C.1, 1C.3, 1C.4 at runtime, but can be written independently)
- **Estimated complexity**: L
- **Agent type**: bash-pro
- **Repo**: Fulcrum-Alpha
- **Detailed instructions**:
  Create `/home/vrogojin/Fulcrum-Alpha/docker/scripts/ssl-setup.sh`. Begin with `#!/bin/bash` and `set -euo pipefail`.

  **Environment variables read**:
  - `SSL_DOMAIN` (if empty/unset, exit 0 immediately with "No SSL_DOMAIN set, skipping SSL setup")
  - `SSL_ADMIN_EMAIL`
  - `HAPROXY_HOST` (default: "haproxy")
  - `HAPROXY_API_PORT` (default: "8404")
  - `HAPROXY_API_KEY` (optional)
  - `SSL_SERVICE_PORT` (default: "443")
  - `SSL_HTTPS_PORT` (default: value of SSL_SERVICE_PORT)
  - `SSL_REQUIRED` (default: "true" when SSL_DOMAIN is set)
  - `SSL_STAGING` (default: "false")
  - `SSL_TEST_MODE` (default: "false")
  - `SSL_SKIP_VERIFY` (default: "false")
  - `SSL_CERT_RENEW_DAYS` (default: "30")
  - `APP_HTTP_PORT` (default: "0")
  - `EXTRA_PORTS` (default: empty, JSON array)

  **Validation** (first thing after checking SSL_DOMAIN is set):
  - Validate SSL_DOMAIN matches `^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$` and contains at least one dot. Exit with code 1 and clear error message if invalid.

  **Step 1: Start HTTP reverse proxy** (runs for container lifetime):
  ```bash
  WEBROOT="/var/www/acme-challenge"
  mkdir -p "$WEBROOT/.well-known/acme-challenge"
  python3 /usr/local/bin/ssl-http-proxy \
      --port 80 \
      --webroot "$WEBROOT" \
      --upstream "127.0.0.1:${APP_HTTP_PORT}" \
      --cert-dir "/etc/letsencrypt/live/${SSL_DOMAIN}" &
  HTTP_PROXY_PID=$!
  # Wait for proxy to start
  for i in $(seq 1 10); do
      nc -z localhost 80 2>/dev/null && break
      sleep 0.5
  done
  ```

  **Step 2: HAProxy detection and registration** (per spec section 3.2, Step 1):
  - If `HAPROXY_HOST` is set or `getent hosts haproxy` succeeds: HAProxy mode
  - In HAProxy mode: call `/usr/local/bin/haproxy-register` to register HTTP-only initially (https_port=null). Use exponential backoff for HAProxy connectivity: 2s, 4s, 8s, 16s, 32s, 60s... max 5 minutes total. Exit 13 if unreachable after 5 minutes.
  - Perform nonce verification (spec lines 296-321): generate nonce, POST to localhost:80/_ssl/nonce/$NONCE, then curl http://$SSL_DOMAIN/_ssl/nonce/$NONCE through the public internet. 3 attempts, 5s between. Exit 10 if nonce never matches.

  **Step 3: Certificate acquisition**:
  - Check for existing valid cert at `/etc/letsencrypt/live/$SSL_DOMAIN/fullchain.pem`
  - If valid and > SSL_CERT_RENEW_DAYS days remaining: skip certbot, reuse
  - If SSL_TEST_MODE is "true": generate self-signed cert instead of running certbot, log prominent WARNING
  - Otherwise: run certbot with `--webroot --webroot-path $WEBROOT -d $SSL_DOMAIN`. Add `--staging` if SSL_STAGING is true. Add `--email` if SSL_ADMIN_EMAIL set. Exit 11 if certbot fails.

  **Step 4: HTTPS registration and TLS verification** (spec section 3.2, Step 3):
  - If HAProxy mode: re-register with https_port set (idempotent POST with updated ports + extra_ports)
  - Unless SSL_SKIP_VERIFY: start temporary openssl s_server on port 8443, verify cert via openssl s_client. Kill temp server. Exit 12 on failure.

  **Step 5: Export and start renewal**:
  - Export `SSL_CERT_PATH` and `SSL_KEY_PATH`
  - Start background renewal loop (see 1C.3 for the script, but start it here):
    ```bash
    /usr/local/bin/ssl-renew "$SSL_DOMAIN" "$WEBROOT" &
    RENEWAL_LOOP_PID=$!
    ```
  - Log "SSL setup complete for $SSL_DOMAIN"

  **Exit codes**:
  - 0: Success (or SSL_DOMAIN not set)
  - 10: Domain unreachable (nonce verification failed)
  - 11: Certbot failed
  - 12: TLS verification failed
  - 13: HAProxy registration failed
  - 14: HAProxy reload failed

#### Task 1C.3: Create ssl-renew.sh
- **Task ID**: 1C.3
- **Description**: Create the certificate renewal loop script that runs in the background
- **Input**: Spec section 5.3 of SSL_MANAGEMENT_ARCHITECTURE.md (lines 800-875)
- **Output**: `/home/vrogojin/Fulcrum-Alpha/docker/scripts/ssl-renew.sh`
- **Dependencies**: None
- **Estimated complexity**: S
- **Agent type**: bash-pro
- **Repo**: Fulcrum-Alpha
- **Detailed instructions**:
  Create `/home/vrogojin/Fulcrum-Alpha/docker/scripts/ssl-renew.sh`. Arguments: `$1` = domain, `$2` = webroot path.

  1. Initial delay: `sleep 3600` (1 hour after startup)
  2. Infinite loop:
     - Log "[ssl-renew] Checking certificate renewal..."
     - Run `certbot renew --webroot --webroot-path "$WEBROOT"` with deploy hook that touches `/tmp/.ssl-renewal-restart`
     - Log renewal check result
     - Sleep 12 hours + random jitter (0-1800 seconds): `JITTER=$((RANDOM % 1800)); sleep $((43200 + JITTER))`

  The deploy hook script should:
  - Log that certificate was renewed
  - Touch `/tmp/.ssl-renewal-restart` marker file
  - If Fulcrum is running (pgrep -x Fulcrum), send SIGTERM to trigger supervisor restart

#### Task 1C.4: Create haproxy-register.sh
- **Task ID**: 1C.4
- **Description**: Create the HAProxy Registration API client script
- **Input**: Spec section 3.2 Step 1 of SSL_MANAGEMENT_ARCHITECTURE.md (lines 239-254). API spec section 2.3.1 of REGISTRATION_API_SPEC.md
- **Output**: `/home/vrogojin/Fulcrum-Alpha/docker/scripts/haproxy-register.sh`
- **Dependencies**: None
- **Estimated complexity**: M
- **Agent type**: bash-pro
- **Repo**: Fulcrum-Alpha
- **Detailed instructions**:
  Create `/home/vrogojin/Fulcrum-Alpha/docker/scripts/haproxy-register.sh`.

  **Arguments/Environment**:
  - `HAPROXY_HOST` (required)
  - `HAPROXY_API_PORT` (default: 8404)
  - `HAPROXY_API_KEY` (optional)
  - Arguments: `--domain`, `--container` (defaults to $(hostname)), `--http-port`, `--https-port`, `--extra-ports` (JSON array)

  **Behavior**:
  1. Build JSON payload using `jq`:
     ```bash
     PAYLOAD=$(jq -n \
         --arg domain "$DOMAIN" \
         --arg container "$CONTAINER" \
         --argjson http_port "$HTTP_PORT" \
         --argjson https_port "$HTTPS_PORT" \
         --argjson extra_ports "${EXTRA_PORTS:-null}" \
         '{domain: $domain, container: $container, http_port: $http_port, https_port: $https_port, extra_ports: $extra_ports}')
     ```

  2. POST to `http://${HAPROXY_HOST}:${HAPROXY_API_PORT}/v1/backends` with:
     - `Content-Type: application/json`
     - Optional `Authorization: Bearer $HAPROXY_API_KEY` header
     - 10-second timeout

  3. Parse response. On 201 or 200: success. On 409: log conflict details and exit 13. On other errors: exit 13.

  4. Also support `--action delete` for deregistration (DELETE endpoint).

#### Task 1C.5: Create ssl-verify.sh
- **Task ID**: 1C.5
- **Description**: Create the domain reachability and TLS verification script
- **Input**: Spec section 3.2 Step 3 of SSL_MANAGEMENT_ARCHITECTURE.md (lines 406-450)
- **Output**: `/home/vrogojin/Fulcrum-Alpha/docker/scripts/ssl-verify.sh`
- **Dependencies**: None
- **Estimated complexity**: S
- **Agent type**: bash-pro
- **Repo**: Fulcrum-Alpha
- **Detailed instructions**:
  Create `/home/vrogojin/Fulcrum-Alpha/docker/scripts/ssl-verify.sh`.

  The script verifies:
  1. That a given domain resolves and is reachable on port 443
  2. That the TLS certificate served matches the expected domain

  Usage: `ssl-verify <domain> <cert-file> <key-file>`

  Steps:
  1. Start a temporary openssl s_server on port 8443 using the provided cert/key
  2. Wait for it to be ready (nc -z localhost 8443)
  3. Run `openssl s_client -connect localhost:8443 -servername $DOMAIN` and extract the subject CN
  4. Kill the temporary server
  5. If the CN matches or the SAN includes the domain, exit 0
  6. Otherwise exit 12 with clear error message

---

## Phase 2: Integration (parallel where possible)

### Stream 2A: Fulcrum Image Update (depends on 1B, 1C)

#### Task 2A.1: Update Fulcrum Dockerfile
- **Task ID**: 2A.1
- **Description**: Modify the Fulcrum Dockerfile to use ssl-manager as the runtime base image
- **Input**: Existing Dockerfile at `/home/vrogojin/Fulcrum-Alpha/docker/Dockerfile`. Spec section 2 of FULCRUM_SSL_INTEGRATION_SPEC.md (lines 36-144)
- **Output**: `/home/vrogojin/Fulcrum-Alpha/docker/Dockerfile` (modified in place)
- **Dependencies**: 1B.1, all of 1C
- **Estimated complexity**: M
- **Agent type**: bash-pro
- **Repo**: Fulcrum-Alpha
- **Detailed instructions**:
  Modify `/home/vrogojin/Fulcrum-Alpha/docker/Dockerfile`. The builder stage remains unchanged. Replace the runtime stage:

  Change `FROM debian:trixie-slim` to `FROM ssl-manager:latest`.

  **Remove** from the runtime RUN: `openssl`, `netcat-openbsd`, `procps` (provided by ssl-manager base).

  **Keep** in the runtime RUN: `libqt5network5`, `zlib1g`, `libbz2-1.0`, `libjemalloc2`, `libzmq5`, `python3`, `libminiupnpc18`.

  **Remove** these ENV lines:
  ```
  ENV SSL_CERTFILE=${DATA_DIR}/fulcrum.crt
  ENV SSL_KEYFILE=${DATA_DIR}/fulcrum.key
  ```

  **Update** HEALTHCHECK start-period from 60s to 120s (allows time for SSL setup).

  Keep everything else the same: COPY binary, COPY config, VOLUME, EXPOSE, ENTRYPOINT.

#### Task 2A.2: Update Fulcrum Entrypoint
- **Task ID**: 2A.2
- **Description**: Rewrite docker-entrypoint.sh to integrate ssl-setup, generate fulcrum.conf from environment variables and SSL state, and handle shutdown deregistration
- **Input**: Existing entrypoint at `/home/vrogojin/Fulcrum-Alpha/docker/docker-entrypoint.sh`. Spec section 3 of FULCRUM_SSL_INTEGRATION_SPEC.md (lines 150-313). Config generation function from section 4 (lines 316-406). Shutdown cleanup from lines 230-239.
- **Output**: `/home/vrogojin/Fulcrum-Alpha/docker/docker-entrypoint.sh` (modified in place)
- **Dependencies**: 1C.2 (ssl-setup.sh must be designed)
- **Estimated complexity**: L
- **Agent type**: bash-pro
- **Repo**: Fulcrum-Alpha
- **Detailed instructions**:
  Rewrite `/home/vrogojin/Fulcrum-Alpha/docker/docker-entrypoint.sh`. Keep the existing supervisor loop, signal handling, exponential backoff, and database cleaning logic. The changes are:

  1. **Remove** the entire `wait_for_ready_signal()` function and all references to `/tmp/.fulcrum-ready` signal files.

  2. **Remove** the stale config/SSL cleanup block (lines 356-360).

  3. **Remove** the current `configure_ssl_and_websocket()` function (lines 134-241). This is replaced by ssl-setup and generate_fulcrum_config.

  4. **Add ssl-setup call** (after clean_database, before config generation):
     ```bash
     if [ -n "${SSL_DOMAIN:-}" ]; then
         echo "Running ssl-setup for domain: $SSL_DOMAIN"
         if /usr/local/bin/ssl-setup; then
             echo "SSL setup completed successfully"
         else
             SSL_EXIT=$?
             if [ "${SSL_REQUIRED:-true}" = "true" ]; then
                 echo "ERROR: SSL setup failed (exit $SSL_EXIT), SSL_REQUIRED=true, exiting"
                 exit $SSL_EXIT
             else
                 echo "WARNING: SSL setup failed (exit $SSL_EXIT), SSL_REQUIRED=false, continuing without SSL"
             fi
         fi
     fi
     ```

  5. **Replace `setup_config()` with `generate_fulcrum_config()`** using the function from spec section 4 (lines 326-406). This generates `/data/fulcrum.conf` from environment variables. Key logic:
     - Always enable: `tcp = 0.0.0.0:50001`, `ws = 0.0.0.0:50003`
     - If certs exist at `/etc/letsencrypt/live/$SSL_DOMAIN/`: enable `ssl = 0.0.0.0:50002`, `wss = 0.0.0.0:50004`, set cert/key paths
     - Set bitcoind, rpcuser, rpcpassword from env vars
     - Set all performance/limit settings from env vars with defaults
     - `chmod 600` the config file (contains RPC credentials)

  6. **Add certificate expiry logging** after config generation:
     ```bash
     if [ -n "${SSL_DOMAIN:-}" ] && [ -f "/etc/letsencrypt/live/$SSL_DOMAIN/fullchain.pem" ]; then
         EXPIRY=$(openssl x509 -enddate -noout -in "/etc/letsencrypt/live/$SSL_DOMAIN/fullchain.pem")
         echo "SSL certificate for $SSL_DOMAIN expires: $EXPIRY"
     fi
     ```

  7. **Add SSL_TEST_MODE warning** if set.

  8. **Update supervisor loop** to recognize `/tmp/.ssl-renewal-restart` as a planned restart (not a crash). At the top of each iteration: `rm -f /tmp/.ssl-renewal-restart`. After Fulcrum exits: if marker file exists, restart immediately without incrementing crash counter or cleaning database.

  9. **Add shutdown deregistration trap**: On SIGTERM, before forwarding to Fulcrum:
     - If HAProxy was detected and SSL_DOMAIN is set: `curl -sf -X DELETE "http://${HAPROXY_HOST:-haproxy}:${HAPROXY_API_PORT:-8404}/v1/backends/$SSL_DOMAIN" || true`
     - Kill the HTTP proxy PID if running
     - Kill the renewal loop PID if running
     - Then proceed with existing signal forwarding to Fulcrum

---

### Stream 2B: Build ssl-manager Image (depends on 1B, 1C)

#### Task 2B.1: Create scripts directory and build image
- **Task ID**: 2B.1
- **Description**: Ensure the scripts directory exists and build the ssl-manager Docker image
- **Input**: Tasks 1B.1, 1C.1-1C.5
- **Output**: `ssl-manager:latest` Docker image
- **Dependencies**: 1B.1, 1C.1, 1C.2, 1C.3, 1C.4, 1C.5
- **Estimated complexity**: S
- **Agent type**: bash-pro
- **Repo**: Fulcrum-Alpha
- **Detailed instructions**:
  1. Ensure `/home/vrogojin/Fulcrum-Alpha/docker/scripts/` directory exists with all 5 scripts from Phase 1C
  2. Build the image:
     ```bash
     cd /home/vrogojin/Fulcrum-Alpha/docker
     docker build -t ssl-manager:latest -f Dockerfile.ssl-manager .
     ```
  3. Verify the image:
     ```bash
     docker run --rm ssl-manager:latest certbot --version
     docker run --rm ssl-manager:latest test -x /usr/local/bin/ssl-setup
     docker run --rm ssl-manager:latest test -x /usr/local/bin/ssl-http-proxy
     docker run --rm ssl-manager:latest test -x /usr/local/bin/haproxy-register
     docker run --rm ssl-manager:latest test -x /usr/local/bin/ssl-renew
     docker run --rm ssl-manager:latest test -x /usr/local/bin/ssl-verify
     ```

---

## Phase 3: Testing (parallel)

### Stream 3A: HAProxy E2E Tests (depends on 1A)

#### Task 3A.1: Create Mock Service Image
- **Task ID**: 3A.1
- **Description**: Create the unified mock service Docker image used by all E2E tests
- **Input**: Spec section 3 of `/home/vrogojin/haproxy/specs/E2E_TEST_SPEC.md` (lines 156-376). Dockerfile, entrypoint, and ws-echo-server.mjs are all specified in full.
- **Output**: `/home/vrogojin/haproxy/tests/e2e/mock-service/Dockerfile`, `/home/vrogojin/haproxy/tests/e2e/mock-service/test-service-entrypoint.sh`, `/home/vrogojin/haproxy/tests/e2e/mock-service/ws-echo-server.mjs`
- **Dependencies**: None (can start before 1A completes)
- **Estimated complexity**: M
- **Agent type**: javascript-pro
- **Repo**: haproxy
- **Detailed instructions**:
  Create the directory `/home/vrogojin/haproxy/tests/e2e/mock-service/` and three files:

  1. `Dockerfile` -- Use `FROM node:20-alpine`. Install `openssl curl socat bash` via `apk`. COPY entrypoint and ws-echo-server.

  2. `test-service-entrypoint.sh` -- Copy the exact entrypoint from spec lines 179-273. It handles three SERVICE_TYPE values: web (HTTP on 80, HTTPS on 443), electrum (HTTP on 80, TCP echo on 50001, TLS echo on 50002, WS on 50003, WSS on 50004), api (HTTP on 8080, HTTPS on 8443). Generates self-signed cert at startup.

  3. `ws-echo-server.mjs` -- Copy the exact WebSocket echo server from spec lines 282-376. Uses only Node.js built-ins. Supports `--tls <cert> <key>` flag. Implements RFC 6455 handshake and echoes text frames back.

#### Task 3A.2: Create E2E Test Runner
- **Task ID**: 3A.2
- **Description**: Create the comprehensive E2E test runner script with all 13 test suites
- **Input**: Full spec at `/home/vrogojin/haproxy/specs/E2E_TEST_SPEC.md`. All 13 suites are specified with exact bash code.
- **Output**: `/home/vrogojin/haproxy/tests/e2e/run-tests.sh`
- **Dependencies**: None (can start before 1A completes; test code is independent of image build)
- **Estimated complexity**: L
- **Agent type**: bash-pro
- **Repo**: haproxy
- **Detailed instructions**:
  Create `/home/vrogojin/haproxy/tests/e2e/run-tests.sh` following the test runner structure from spec section 6 (lines 2000-2098+). The script must:

  1. Define constants: TEST_PREFIX="haproxy-e2e-test", all container/image/network names.
  2. Implement `clean_room()` function (spec section 4.2, lines 399-433).
  3. Set `trap clean_room EXIT`.
  4. Implement assertion helpers: `assert_equals`, `assert_contains`, `assert_true`.
  5. Implement `start_environment()`:
     - Pre-clean
     - Create test network
     - Build mock service image from `tests/e2e/mock-service/`
     - Build HAProxy test image from project root
     - Start HAProxy container with published ports (use `-p 0:<port>` for dynamic port assignment). Publish: 80, 443, 8404, 50001, 50003, 50004.
     - Start 3 mock service containers: web, electrum, api
     - Discover ports via `docker port`
     - Wait for HAProxy API to be healthy (poll /v1/health)
  6. Implement all 13 test suites exactly as specified in the E2E spec:
     - Suite 1: Clean room verification
     - Suite 2: HAProxy startup
     - Suite 3: Backend registration (9 tests)
     - Suite 4: HTTP routing (5 tests)
     - Suite 5: HTTPS/TLS passthrough (5 tests)
     - Suite 6: Extra ports (4 tests)
     - Suite 7: WebSocket (3 tests)
     - Suite 8: Backend unregistration (6 tests)
     - Suite 9: Reload under load (1 test)
     - Suite 10: Error handling (15 tests)
     - Suite 11: Concurrent registration (2 tests)
     - Suite 12: Container ownership on DELETE (3 tests)
     - Suite 13: Authentication and rate limiting (2 tests -- these start separate containers)
  7. Test runner with suite selector support: `./run-tests.sh [suite_name]`
  8. Final summary: total passed/failed/skipped

  Each test function name must match the spec exactly. Use `set -euo pipefail` but wrap test execution to catch failures without aborting.

---

### Stream 3B: SSL Management Tests (depends on 2A, 2B)

#### Task 3B.1: Create SSL Test Infrastructure
- **Task ID**: 3B.1
- **Description**: Create the test service image, docker-compose.test.yml, pebble config, and test runner for SSL management
- **Input**: `/home/vrogojin/Fulcrum-Alpha/docker/specs/TESTING_INSTRUCTIONS.md` (full document)
- **Output**: 
  - `/home/vrogojin/Fulcrum-Alpha/docker/tests/docker-compose.test.yml`
  - `/home/vrogojin/Fulcrum-Alpha/docker/tests/Dockerfile.test-service`
  - `/home/vrogojin/Fulcrum-Alpha/docker/tests/test-health-server.py`
  - `/home/vrogojin/Fulcrum-Alpha/docker/tests/test-entrypoint.sh`
  - `/home/vrogojin/Fulcrum-Alpha/docker/tests/pebble-config.json`
  - `/home/vrogojin/Fulcrum-Alpha/docker/tests/run-ssl-tests.sh`
- **Dependencies**: 2A.1, 2B.1 (needs ssl-manager:latest image to exist)
- **Estimated complexity**: L
- **Agent type**: bash-pro
- **Repo**: Fulcrum-Alpha
- **Detailed instructions**:
  Create the `/home/vrogojin/Fulcrum-Alpha/docker/tests/` directory with all test files specified in TESTING_INSTRUCTIONS.md:

  1. `docker-compose.test.yml` -- Exact content from spec lines 68-158. Services: pebble, pebble-challtestsrv, haproxy (build from haproxy repo), ssl-test-service (build from local Dockerfile.test-service).

  2. `Dockerfile.test-service` -- FROM ssl-manager:latest, install python3, copy test-health-server.py and test-entrypoint.sh. Expose 80 443.

  3. `test-health-server.py` -- Exact content from spec lines 214-298. Dual HTTP/HTTPS health server.

  4. `test-entrypoint.sh` -- Exact content from spec lines 306-330. Runs ssl-setup if SSL_DOMAIN is set, then starts health server.

  5. `pebble-config.json` -- Exact content from spec lines 163-177.

  6. `run-ssl-tests.sh` -- Test runner implementing all 4 test suites from TESTING_INSTRUCTIONS.md:
     - Suite 1: ssl-manager base image validation (6 tests)
     - Suite 2: HAProxy Registration API (12 tests)
     - Suite 3: HAProxy integration / HTTP routing (5 tests)
     - Suite 4: End-to-end SSL flow (with Pebble mock ACME and with SSL_TEST_MODE)

---

## Phase 4: Validation (serial)

### Task 4.1: Build and Run HAProxy E2E Tests
- **Task ID**: 4.1
- **Description**: Build the HAProxy custom image and run the full E2E test suite
- **Input**: All Phase 1A outputs + 3A outputs
- **Output**: Test results (all 13 suites passing)
- **Dependencies**: 1A.1-1A.6, 3A.1, 3A.2
- **Estimated complexity**: M
- **Agent type**: bash-pro
- **Repo**: haproxy
- **Detailed instructions**:
  ```bash
  cd /home/vrogojin/haproxy
  bash tests/e2e/run-tests.sh
  ```
  All tests must pass. If any fail, diagnose and fix the relevant implementation task, then re-run.

### Task 4.2: Build and Run SSL Management Tests
- **Task ID**: 4.2
- **Description**: Build ssl-manager and test service images, then run the SSL test suite
- **Input**: All Phase 1B, 1C, 2A, 2B, 3B outputs
- **Output**: Test results (all 4 suites passing)
- **Dependencies**: 2A.1, 2A.2, 2B.1, 3B.1
- **Estimated complexity**: M
- **Agent type**: bash-pro
- **Repo**: Fulcrum-Alpha
- **Detailed instructions**:
  ```bash
  cd /home/vrogojin/Fulcrum-Alpha/docker/tests
  bash run-ssl-tests.sh
  ```
  All tests must pass.

### Task 4.3: Steelman Review
- **Task ID**: 4.3
- **Description**: Adversarial review of the complete implementation -- try to break it
- **Input**: All implemented code, all test results
- **Output**: List of issues found (if any)
- **Dependencies**: 4.1, 4.2
- **Estimated complexity**: M
- **Agent type**: bash-pro
- **Repo**: Both
- **Detailed instructions**:
  Review areas:
  1. Security: Can a container on haproxy-net escalate or impersonate?
  2. Race conditions: Concurrent registration, reload during reload
  3. File corruption: What if generate-config.sh is killed mid-write?
  4. Resource exhaustion: What if 100+ registrations arrive simultaneously?
  5. Docker restart: Does state survive container recreation?
  6. Network partition: What happens if HAProxy starts before any backends?

---

## Critical Path

The longest dependency chain determines the minimum elapsed time with maximum parallelism:

```
Phase 0 (0.1)        -> Phase 1 (1B.1 + 1C.1-1C.5)   -> Phase 2 (2B.1 + 2A.1-2A.2) -> Phase 3 (3B.1) -> Phase 4 (4.2 + 4.3)
     S                        L (1C.2 is largest)              M                             L                   M
    ~15min                   ~2-3 hours                      ~1 hour                      ~2 hours             ~1 hour
```

**Critical path total: approximately 6-7 hours** with maximum parallelism.

The HAProxy stream (1A -> 3A -> 4.1) runs fully in parallel and its critical path is:
```
1A.3 (L, ~2-3 hours) -> 3A.2 (L, ~2 hours) -> 4.1 (M, ~1 hour) = ~5-6 hours
```

Both paths converge at Task 4.3 (steelman review).

**Without parallelism**: Approximately 15-20 hours.

**Maximum parallelism lanes**: 5 agents can work simultaneously in Phase 1:
- Agent A: Tasks 1A.1, 1A.2, 1A.5, 1A.6
- Agent B: Task 1A.3 (Registration API -- largest single task)
- Agent C: Task 1A.4 (generate-config.sh update)
- Agent D: Task 1B.1, 1C.1 (ssl-manager Dockerfile + HTTP proxy)
- Agent E: Tasks 1C.2, 1C.3, 1C.4, 1C.5 (ssl-manager shell scripts)

---

## Risk Register

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| HAProxy master-worker mode SIGUSR2 behavior differs from expectation | Low | High | Test reload confirmation thoroughly in E2E. Fallback: use master CLI socket `echo "reload" \| socat` |
| Node.js not available in `haproxy:lts` base image | Medium | Medium | The Dockerfile installs nodejs via apt. Verify `apt-get install -y nodejs` works on Debian bookworm (haproxy:lts base). If not, install from NodeSource. |
| certbot version in Debian trixie may not support all flags | Low | Medium | Verify `certbot --version` in the ssl-manager image. Use only well-established certbot flags. |
| Docker DNS resolution timing for container ownership verification | Medium | Low | The DELETE ownership check resolves the registered container name via DNS. If the container restarted and got a new IP, DNS updates may lag. Use `getent hosts` with retry. |
| Extra port frontends conflict with HAProxy reserved ports | Low | High | Validation in registration-api.mjs rejects reserved ports (80, 443, 8000, 8404). |
| Concurrent writes to domains.map corrupt the file | Medium | High | File locking with O_EXCL lock file + 60s polling deadline. Atomic write via write-to-temp-then-rename. |
| ssl-manager proxy on port 80 conflicts with application | Low | Medium | APP_HTTP_PORT validation rejects 80 at startup. Default is 0 (disabled). |
| Pebble ACME test server may not be available in all environments | Medium | Low | SSL_TEST_MODE provides self-signed cert fallback for CI environments without Pebble. |
| `haproxy -c` config validation timeout under heavy load | Low | Low | 30-second timeout is generous. HAProxy validation is typically < 1 second. |
| Fulcrum does not support runtime cert reload (requires restart) | Known | Low | The renewal hook touches `/tmp/.ssl-renewal-restart` and the supervisor loop handles graceful restart without crash counter increment. |

### Assumptions

1. The `haproxy:lts` Docker image is based on Debian and supports `apt-get install nodejs`.
2. The `debian:trixie-slim` image includes a certbot package in its apt repository.
3. Docker DNS resolution works reliably within Docker bridge networks for container-to-container communication.
4. HAProxy master-worker mode (`-W`) with SIGUSR2 provides hitless reloads as documented.
5. The haproxy-net Docker network already exists on the target host.
6. Both repositories are checked out at `/home/vrogojin/haproxy` and `/home/vrogojin/Fulcrum-Alpha`.

---

### Critical Files for Implementation

- `/home/vrogojin/haproxy/registration-api.mjs` -- The Node.js Registration API (largest single file, core of the HAProxy system)
- `/home/vrogojin/Fulcrum-Alpha/docker/scripts/ssl-setup.sh` -- The SSL orchestration script (core of the ssl-manager system)
- `/home/vrogojin/haproxy/generate-config.sh` -- Must be updated to support extra ports and container-internal paths
- `/home/vrogojin/Fulcrum-Alpha/docker/docker-entrypoint.sh` -- Must be rewritten to integrate ssl-setup and new config generation
- `/home/vrogojin/haproxy/tests/e2e/run-tests.sh` -- The comprehensive E2E test runner validating all HAProxy Registration API behavior