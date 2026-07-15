# Fulcrum Crash Recovery Testing

Comprehensive testing suite for validating Fulcrum SPV server crash recovery in Docker environments. Tests process-level crashes, container-level crashes, and verifies proper recovery mechanisms.

## Overview

This testing suite provides three specialized scripts to simulate and verify different crash scenarios:

1. **crash-fulcrum-process.sh** - Simulates Fulcrum process crash without container exit
2. **crash-container.sh** - Simulates complete container crash and Docker restart
3. **test-recovery.sh** - Automated test suite running both scenarios with verification

## Architecture

### Two Crash Scenarios

#### Scenario 1: Process Crash (Container Survives)
```
┌─────────────────────────────┐
│  Docker Container           │
│  ┌───────────────────────┐  │
│  │  Process Supervisor   │  │  ← PID 1 (tini/dumb-init/supervisord)
│  │  ┌─────────────────┐  │  │
│  │  │  Fulcrum        │  │  │  ← Child process
│  │  └─────────────────┘  │  │
│  └───────────────────────┘  │
└─────────────────────────────┘

Crash: Kill Fulcrum process
Result: Supervisor detects exit and restarts Fulcrum
Container: Stays running
```

#### Scenario 2: Container Crash (Full Restart)
```
┌─────────────────────────────┐
│  Docker Container           │
│  ┌───────────────────────┐  │
│  │  Fulcrum (PID 1)      │  │  ← Dies
│  └───────────────────────┘  │
└─────────────────────────────┘
        ↓ Container exits
        ↓ Docker restarts (--restart always)
        ↓
┌─────────────────────────────┐
│  Docker Container (new)     │
│  ┌───────────────────────┐  │
│  │  Fulcrum (PID 1)      │  │  ← Fresh start
│  └───────────────────────┘  │
└─────────────────────────────┘
```

## Prerequisites

### System Requirements
- Docker installed and running
- Bash 4.4+ or 5.x
- `nc` (netcat) for port testing (optional but recommended)
- `timeout` command (usually available on Linux)

### Container Requirements
- Container must be running with `--restart always` or `--restart unless-stopped` policy
- For process crash recovery: Container should use a process supervisor (tini, dumb-init, supervisord)
- For container crash recovery: No special requirements (Docker handles restart)

### Verify Setup
```bash
# Check container restart policy
docker inspect --format '{{.HostConfig.RestartPolicy.Name}}' fulcrum-alpha

# Expected output: "always" or "unless-stopped"

# Check if process supervisor is running
docker exec fulcrum-alpha ps aux

# Look for: tini, dumb-init, supervisord, or other init process as PID 1
```

## Usage

### Quick Start - Run All Tests
```bash
# Run comprehensive test suite
./test-recovery.sh

# Run with verbose output
./test-recovery.sh --verbose

# Test specific container
./test-recovery.sh --container my-fulcrum
```

### Individual Crash Tests

#### Test Process Crash
```bash
# Hard crash with SIGKILL (cannot be caught)
./crash-fulcrum-process.sh

# Graceful termination with SIGTERM
./crash-fulcrum-process.sh --signal SIGTERM

# Simulated crash with SIGABRT
./crash-fulcrum-process.sh --signal SIGABRT

# Segmentation fault simulation
./crash-fulcrum-process.sh --signal SIGSEGV

# Custom container and wait time
./crash-fulcrum-process.sh --container my-fulcrum --wait 15
```

#### Test Container Crash
```bash
# Kill PID 1 with SIGKILL (instant crash)
./crash-container.sh --method pid1-kill

# Kill PID 1 with SIGABRT (abnormal termination)
./crash-container.sh --method pid1-abort

# Kill PID 1 with SIGTERM (graceful shutdown)
./crash-container.sh --method pid1-term

# Use docker stop (tests restart policy)
./crash-container.sh --method stop-start

# Custom container with longer wait
./crash-container.sh --container my-fulcrum --wait 20
```

### Advanced Test Suite Options

#### Skip Specific Tests
```bash
# Skip process crash test (only test container crash)
./test-recovery.sh --skip-process

# Skip container crash test (only test process crash)
./test-recovery.sh --skip-container
```

#### Custom Port Testing
```bash
# Test custom ports
./test-recovery.sh --ports 60001,60002,60003,60004

# Test only SSL port
./test-recovery.sh --ports 50002
```

#### Custom Wait Times
```bash
# Longer wait for slow systems
./test-recovery.sh --wait 30

# Shorter wait for fast systems
./test-recovery.sh --wait 5
```

## Signal Reference

### Common Signals Used

| Signal    | Number | Description | Use Case |
|-----------|--------|-------------|----------|
| SIGTERM   | 15     | Graceful shutdown request | Test clean exit handling |
| SIGKILL   | 9      | Immediate termination | Test hard crash recovery |
| SIGABRT   | 6      | Abnormal termination | Simulate assertion failure |
| SIGSEGV   | 11     | Segmentation fault | Simulate memory error |
| SIGHUP    | 1      | Hang up | Test configuration reload |

### How Signals Affect Processes

**SIGTERM (15)**: Catchable, allows cleanup
- Process can handle signal
- Graceful shutdown possible
- Similar to normal exit

**SIGKILL (9)**: Not catchable, immediate death
- Cannot be handled or blocked
- No cleanup possible
- Most realistic crash simulation

**SIGABRT (6)**: Abnormal termination
- Typically from assertion failures
- Core dump generated (if enabled)
- Simulates programming error

## Expected Outcomes

### Process Crash Test

#### With Process Supervisor
```
✓ PASS: Fulcrum process killed
✓ PASS: Container remains running
✓ PASS: Supervisor detects exit
✓ PASS: Fulcrum automatically restarted
✓ PASS: New process has different PID
✓ PASS: Container uptime unchanged
```

#### Without Process Supervisor (Fulcrum as PID 1)
```
✓ PASS: Fulcrum process killed
✗ FAIL: Container exits (PID 1 died)
⚠ WARN: Docker restarts container
✓ PASS: Fulcrum starts in new container
⚠ WARN: Container uptime changed (full restart)
```

### Container Crash Test

#### With Proper Restart Policy
```
✓ PASS: Container killed
✓ PASS: Container exits
✓ PASS: Docker auto-restart triggered
✓ PASS: New container starts
✓ PASS: Fulcrum process running
✓ PASS: SSL certificates preserved
✓ PASS: Database cleaned and ready
✓ PASS: All ports responding
```

#### Without Restart Policy
```
✓ PASS: Container killed
✓ PASS: Container exits
✗ FAIL: Container stays stopped
✗ FAIL: Manual restart required
```

## Verification Steps

Each test performs these verification checks:

### 1. Process Verification
- Fulcrum process is running
- Process has valid PID
- Process responds to signals

### 2. Container State
- Container is in "running" state
- Container uptime (changed vs unchanged)
- Container restart count

### 3. SSL Certificate Preservation
- Certificate directories exist
- Certificate files intact
- Correct permissions maintained

### 4. Database Integrity
- Database directory exists
- Lock files present (if Fulcrum running)
- No corruption detected

### 5. Port Connectivity
- TCP port 50001 responding
- SSL port 50002 responding (if configured)
- WebSocket port 50003 responding (if configured)
- WSS port 50004 responding (if configured)

## Troubleshooting

### Process Crash Test Fails

**Problem**: Container exits when Fulcrum is killed

**Cause**: Fulcrum is running as PID 1 without supervisor

**Solution**: Implement process supervisor
```dockerfile
# Option 1: Use tini (lightweight)
RUN apk add --no-cache tini
ENTRYPOINT ["/sbin/tini", "--"]
CMD ["/usr/local/bin/Fulcrum", "/etc/fulcrum/fulcrum.conf"]

# Option 2: Use dumb-init
ADD https://github.com/Yelp/dumb-init/releases/download/v1.2.5/dumb-init_1.2.5_amd64 /usr/local/bin/dumb-init
RUN chmod +x /usr/local/bin/dumb-init
ENTRYPOINT ["/usr/local/bin/dumb-init", "--"]

# Option 3: Use supervisord (full-featured)
RUN apk add --no-cache supervisor
COPY supervisord.conf /etc/supervisord.conf
CMD ["/usr/bin/supervisord", "-c", "/etc/supervisord.conf"]
```

### Container Crash Test Fails

**Problem**: Container doesn't restart automatically

**Cause**: Missing or incorrect restart policy

**Solution**: Set restart policy
```bash
# Update existing container
docker update --restart always fulcrum-alpha

# Or recreate with restart policy
docker run -d --restart always --name fulcrum-alpha ...
```

### SSL Certificates Not Preserved

**Problem**: Certificates missing after restart

**Cause**: Certificates in ephemeral storage

**Solution**: Mount certificates from host
```bash
docker run -d \
  -v /etc/letsencrypt:/etc/letsencrypt:ro \
  --name fulcrum-alpha \
  fulcrum-alpha:latest
```

### Ports Not Responding

**Problem**: Port tests fail after recovery

**Possible Causes**:
1. Fulcrum still initializing (wait longer)
2. Database corruption preventing startup
3. Configuration error
4. Network connectivity issue

**Debug Steps**:
```bash
# Check Fulcrum logs
docker logs fulcrum-alpha

# Check process status
docker exec fulcrum-alpha ps aux

# Test port from inside container
docker exec fulcrum-alpha nc -zv localhost 50001

# Check port bindings
docker port fulcrum-alpha
```

## Performance Considerations

### Test Duration
- Process crash test: ~10-30 seconds
- Container crash test: ~15-45 seconds
- Full test suite: ~1-2 minutes

### System Load
- Minimal CPU impact (brief spikes during restart)
- Minimal memory impact
- Brief network interruption during restart
- Disk I/O from database cleanup

### Production Testing
- Run during maintenance window
- Monitor connected clients
- Verify no active transactions during test
- Consider backup before testing

## Best Practices

### 1. Test Regularly
- Run after configuration changes
- Run after Docker/system updates
- Include in CI/CD pipeline
- Schedule periodic automated tests

### 2. Monitor Results
- Track recovery times
- Log test outcomes
- Alert on failures
- Review trends over time

### 3. Document Findings
- Record baseline recovery times
- Note any anomalies
- Track configuration changes
- Maintain test history

### 4. Gradual Rollout
- Test in development first
- Validate in staging
- Limited production testing
- Full production deployment

## Integration with Monitoring

### Prometheus Metrics
Monitor these metrics during crash tests:
- Container restart count
- Process uptime
- Port response time
- Error rate

### Log Aggregation
Collect logs from:
- Docker daemon
- Container stdout/stderr
- Fulcrum application logs
- System logs (systemd journal)

### Alerting
Set up alerts for:
- Container restart loops
- Failed recovery attempts
- Port connectivity failures
- Certificate expiration

## Exit Codes

All scripts use consistent exit codes:

| Code | Meaning |
|------|---------|
| 0    | Success - all tests passed |
| 1    | General error - script failure |
| 2    | Prerequisites failed - setup issue |
| 3    | Process crash test failed |
| 4    | Container crash test failed |

## Examples

### Complete Test Workflow
```bash
# 1. Verify prerequisites
docker ps | grep fulcrum-alpha
docker inspect --format '{{.HostConfig.RestartPolicy.Name}}' fulcrum-alpha

# 2. Run comprehensive test
./test-recovery.sh --verbose

# 3. Review results
echo $?  # Check exit code

# 4. Check logs
docker logs fulcrum-alpha --tail 100

# 5. Verify functionality
docker exec fulcrum-alpha /usr/local/bin/FulcrumAdmin -p 8000 getinfo
```

### CI/CD Integration
```bash
#!/bin/bash
# ci-crash-test.sh

set -e

# Deploy container
./run-fulcrum.sh --no-ssl

# Wait for initialization
sleep 30

# Run recovery tests
./test-recovery.sh --skip-process --wait 20

# Verify service health
./test-ssl.sh || echo "SSL test skipped (no SSL configured)"

echo "Crash recovery tests passed!"
```

### Stress Testing
```bash
# Run multiple crash cycles
for i in {1..5}; do
  echo "=== Cycle $i ==="
  ./crash-container.sh --method pid1-kill --wait 15
  sleep 5
done

# Verify final state
./test-recovery.sh --skip-process --skip-container
```

## Contributing

When adding new test scenarios:

1. Follow defensive programming patterns
2. Use consistent logging functions
3. Implement proper error handling
4. Add comprehensive help text
5. Document exit codes
6. Test on multiple platforms
7. Update this documentation

## References

- [Docker Restart Policies](https://docs.docker.com/config/containers/start-containers-automatically/)
- [Linux Signal Handling](https://man7.org/linux/man-pages/man7/signal.7.html)
- [Process Supervisors Comparison](https://github.com/Yelp/dumb-init#why)
- Fulcrum documentation: `../README.md`
- Docker setup: `./README.md`

## License

Same as Fulcrum project (GPLv3)
