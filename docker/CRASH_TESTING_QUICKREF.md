# Crash Testing Quick Reference

## TL;DR - Run All Tests
```bash
cd docker
./test-recovery.sh
```

## Common Commands

### Test Everything
```bash
./test-recovery.sh --verbose
```

### Test Only Process Crash
```bash
./crash-fulcrum-process.sh
```

### Test Only Container Crash
```bash
./crash-container.sh
```

### Test Custom Container
```bash
./test-recovery.sh --container my-fulcrum
```

## Crash Methods

### Process Crash Signals
```bash
./crash-fulcrum-process.sh --signal SIGKILL   # Hard crash (default)
./crash-fulcrum-process.sh --signal SIGTERM   # Graceful exit
./crash-fulcrum-process.sh --signal SIGABRT   # Abnormal termination
./crash-fulcrum-process.sh --signal SIGSEGV   # Segfault simulation
```

### Container Crash Methods
```bash
./crash-container.sh --method pid1-kill       # Hard crash (default)
./crash-container.sh --method pid1-abort      # Abnormal termination
./crash-container.sh --method pid1-term       # Graceful shutdown
./crash-container.sh --method stop-start      # Docker stop test
```

## Quick Checks

### Is Fulcrum Running?
```bash
docker exec fulcrum-alpha pgrep -x Fulcrum
```

### Check Restart Policy
```bash
docker inspect --format '{{.HostConfig.RestartPolicy.Name}}' fulcrum-alpha
```

### View Container Logs
```bash
docker logs -f fulcrum-alpha
```

### Test Port Connectivity
```bash
nc -zv localhost 50001  # TCP
nc -zv localhost 50002  # SSL
```

### Get Process Tree
```bash
docker exec fulcrum-alpha ps auxf
```

## Expected Results

### ✓ Process Crash (With Supervisor)
- Container keeps running
- Fulcrum restarts automatically
- New PID assigned
- Container uptime unchanged

### ✓ Container Crash (With Restart Policy)
- Container exits
- Docker restarts container
- Fulcrum starts fresh
- SSL certs preserved
- Database cleaned

### ✗ Process Crash (Without Supervisor)
- Container exits when Fulcrum dies
- Docker restarts container
- **Fix**: Add process supervisor

### ✗ Container Crash (Without Restart Policy)
- Container stays stopped
- Manual restart needed
- **Fix**: `docker update --restart always fulcrum-alpha`

## Troubleshooting One-Liners

### Fix Restart Policy
```bash
docker update --restart always fulcrum-alpha
```

### Force Container Restart
```bash
docker restart fulcrum-alpha
```

### Clean Restart
```bash
docker stop fulcrum-alpha && docker start fulcrum-alpha
```

### View Recent Crashes
```bash
docker inspect --format '{{.RestartCount}}' fulcrum-alpha
```

### Get Container Start Time
```bash
docker inspect --format '{{.State.StartedAt}}' fulcrum-alpha
```

## Exit Codes
- `0` = Success
- `1` = General error
- `2` = Prerequisites failed
- `3` = Process crash test failed
- `4` = Container crash test failed

## Help
```bash
./crash-fulcrum-process.sh --help
./crash-container.sh --help
./test-recovery.sh --help
```

## Full Documentation
See `CRASH_RECOVERY_TESTING.md` for complete details.
