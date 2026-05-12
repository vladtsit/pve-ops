#!/bin/bash
# Weekly fstrim across VMs that have qemu-guest-agent.
# Reclaims unused blocks back to the LVM-thin pool / NVMe.
set -u

VMIDS=(100 101)   # 102 (amnezia) has no guest agent
LOG=/var/log/pve-vm-fstrim.log

log() { echo "[$(date -Is)] $*" >> "$LOG"; }

log "=== fstrim run start ==="
ANY_FAIL=0

for V in "${VMIDS[@]}"; do
    if ! qm guest cmd "$V" ping >/dev/null 2>&1; then
        log "VM $V: guest-agent unavailable, skipping"
        continue
    fi
    # Run fstrim -av; capture pid so we can wait on output
    PID=$(qm guest exec "$V" -- /sbin/fstrim -av 2>/dev/null | jq -r '.pid // empty')
    if [[ -z $PID ]]; then
        # Older guest-agent: synchronous form
        OUT=$(qm guest exec "$V" -- /sbin/fstrim -av 2>&1)
        log "VM $V (sync): $OUT"
        continue
    fi
    # Poll for completion (up to 5 min)
    for _ in $(seq 1 60); do
        sleep 5
        STATUS=$(qm guest exec-status "$V" "$PID" 2>/dev/null || true)
        EXITED=$(echo "$STATUS" | jq -r '.exited // false')
        [[ $EXITED == "true" ]] && break
    done
    OUT=$(echo "$STATUS" | jq -r '."out-data" // empty' | base64 -d 2>/dev/null || echo "$STATUS" | jq -r '."out-data" // empty')
    EC=$(echo "$STATUS" | jq -r '.exitcode // -1')
    log "VM $V exit=$EC: $(echo "$OUT" | tr '\n' ' ' | head -c 400)"
    [[ $EC -ne 0 ]] && ANY_FAIL=1
done

log "=== fstrim run done (failed=$ANY_FAIL) ==="

# Heartbeat
HB=ok; [[ $ANY_FAIL -ne 0 ]] && HB=fail
/usr/local/sbin/pve-cron-heartbeat.sh vm_fstrim "$HB" "VM fstrim" >/dev/null 2>&1 || true

# Trim log
tail -500 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
