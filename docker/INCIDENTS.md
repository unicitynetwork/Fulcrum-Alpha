# Incident Log & Runbook

Operational record of production incidents affecting Fulcrum-Alpha availability, their
root causes, the fixes applied, and how to recognize/prevent a recurrence.

Deployment topology for context:

- `fulcrum-alpha` — this container. Serves Electrum on TCP 50001 / SSL 50002 / WS 50003 /
  WSS 50004. Terminates its own TLS (certbot, in-container). Chain/index DB on the
  `fulcrum-data` volume (`/data`).
- `haproxy` — SNI/TCP front proxy with a dynamic Registration API (port 8404). Publishes
  80/443/8000/50001-50004. Fulcrum self-registers its ports on startup.
- `alpha-fork-miner` — the Alpha full node. Serves RPC as the network alias
  **`alpha-node:8589`** on `alpha-net`. Chaindata on the `alpha-data` volume
  (`/root/.alpha`). Fulcrum's `bitcoind=alpha-node:8589` points here.

---

## 2026-10-05 — Fulcrum unavailable: Alpha node stuck re-indexing

### Symptom
- `fulcrum-alpha` was `Exited (1)`, `RestartCount=5` (Docker `on-failure:5` exhausted).
- Each run started, loaded its DB (height 612358), then died in ~12s with:
  ```
  <Controller> We have height 612358, but bitcoind reports height 73776. Possible reorg ...
  <Controller> FATAL: Failed to rewind: Unable to retrieve undo info for 612358
  ```

### Root cause
The Alpha node (`alpha-fork-miner`) had been recreated with
`Cmd=[alphad -reindex-chainstate]`. `-reindex-chainstate` is a **one-time repair tool**
that rebuilds the entire UTXO set from local block files (2-3h), but it had been left as
the container's **permanent command**. So on every start the node went back to the bottom
of a chainstate rebuild. While rebuilding, the node's reported height was far **below**
Fulcrum's DB height, which Fulcrum reads as an un-rewindable reorg → `FATAL` → exit →
restart loop.

Why the node needed a repair in the first place: an **unclean shutdown**. `alphad` takes
~32s to flush its chainstate on stop, but Docker's default stop timeout is 10s → `SIGKILL`
mid-flush → dirty chainstate → someone added `-reindex-chainstate` to recover and it stuck.

The chain data itself was never lost — it lives on the persistent `alpha-data` volume; only
the UTXO index was being rebuilt. Fulcrum's DB was also intact the whole time (it is only
wiped when the crash-state file ends with `corruption=yes` or `CLEAN_DB_ON_START=true`; a
node-behind situation does **not** wipe it).

### Fix
After letting the in-progress reindex finish (node back at tip), the node was recreated
**without** the repair flag and **with** a long stop grace so it can always flush cleanly:

```bash
docker stop -t 120 alpha-fork-miner     # clean flush; confirm "Shutdown: done" in logs
docker rm alpha-fork-miner
docker run -d --restart unless-stopped \
  --name alpha-fork-miner \
  --network alpha-net --network-alias alpha-node \
  -p 8590:8590 \
  --stop-timeout 120 \
  -v alpha-data:/root/.alpha \
  -v /home/vrogojin/alpha-fork-miner/config:/config \
  alpha-e2e alphad                       # plain alphad — NO -reindex-chainstate
docker start fulcrum-alpha
```

On restart the node now logs `Loaded best chain: height=… progress=1.000000` and is ready
in seconds (no reindex). Fulcrum then catches up the few missed blocks and serves normally.

### Prevention
- **Never leave `-reindex-chainstate` (or `-reindex`) as the node's permanent command.**
  `alpha-fork-miner/setup.sh` already launches it as plain `alphad`; keep it that way. Use
  the flag only for a single manual recovery run, then recreate without it.
- Keep `--stop-timeout 120` on the node so a stop/host-reboot never SIGKILLs it mid-flush
  (the original trigger for the dirty chainstate).

### Quick diagnosis
```bash
# Is the node behind Fulcrum's DB height / still in IBD?
docker exec alpha-fork-miner alpha-cli -rpcport=8589 -rpcuser=user -rpcpassword=password getblockchaininfo
# Is the node permanently set to reindex? (should print "alphad" only)
docker inspect alpha-fork-miner --format '{{.Config.Cmd}}'
```
Note: `initialblockdownload:true` can persist even when fully synced if the tip block is
>24h old (quiet chain). That alone does **not** block Fulcrum — Fulcrum only needs node
height ≥ its own DB height.

---

## 2026-09-14 — Fulcrum serving an expired TLS cert (renewal not reloaded)

### Symptom
Web wallets failed TLS validation on WSS/SSL while `fulcrum-alpha` was `running` and
`RestartCount=0`. The live listeners served a cert that had **expired Sep 10**, even though
certbot had already renewed it on disk (valid to Nov 9).

### Root cause
Two defects in the SSL-renewal reload path meant a renewed cert was never loaded by a
long-running Fulcrum:

1. The `ssl-renew` deploy-hook only `touch`es `/tmp/.ssl-renewal-restart`; it never signals
   Fulcrum. The supervisor only consumes that marker when Fulcrum exits — which a stable
   Fulcrum never does — so the marker sat unconsumed.
2. The supervisor's post-exit `tail -200 /proc/1/fd/1` blocked forever on PID 1's live log
   pipe, so even when Fulcrum did exit, the restart logic below it was never reached.

### Fix (`docker/docker-entrypoint.sh`, PR #18)
- Added a background **renewal watcher**: while Fulcrum runs, it polls for the marker and
  gracefully `SIGTERM`s Fulcrum when it appears, so the existing post-exit handler reloads
  the new cert. Self-contained — works regardless of the base-image deploy-hook.
- Wrapped the output-capture `tail` in `timeout 3` so the supervisor can never stall.

Verified end-to-end: `touch /tmp/.ssl-renewal-restart` now auto-restarts Fulcrum with the
renewed cert; the supervisor logs
`SSL renewal marker detected → SSL certificate renewed — restarting → Starting Fulcrum`.

### Manual fallback
If a renewed cert is ever not picked up, reload it immediately with:
```bash
docker restart fulcrum-alpha   # safe: no DB wipe on a clean restart
```

### Upstream note
Defect #1 also lives in `ssl-renew` inside the `ssl-manager` base image. The entrypoint
watcher makes Fulcrum immune regardless, but fixing the deploy-hook upstream would benefit
all `ssl-manager`-based services.

---

## Related

- Web-wallet reconnect churn was traced to the haproxy `defaults` lacking `timeout tunnel`
  (30s idle cap severing long-lived WSS/Electrum passthrough). Fixed in the haproxy repo
  (`timeout tunnel 300s` + self-healing DNS resolvers); the backend health-check interval
  was also relaxed 2s→10s (haproxy repo PR #9).
