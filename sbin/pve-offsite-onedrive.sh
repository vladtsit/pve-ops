#!/bin/bash
# pve-offsite-onedrive.sh
# Weekly off-site of latest vzdump for selected VMs to OneDrive.
# - Targets: VM 101 (HAOS), VM 102 (Amnezia). VM 100 (docker) skipped: re-creatable from /opt/stacks/.
# - Weekly retention: 4 per VM in OneDrive:proxmox-offsite/weekly/
# - Monthly retention: 1 per VM in OneDrive:proxmox-offsite/monthly/ (promoted on first run of each month)
# - No encryption (per user choice).
# - Pushover on failure (priority 1) or success summary (priority -1).
# - Cron: Sun 04:00, after the nightly vzdump at 03:00.

set -uo pipefail

. /etc/pve-monitor.env

VMIDS=(101 102)
DUMP_DIR=/mnt/nvme/backups/dump
REMOTE=OneDrive:proxmox-offsite
WEEKLY=$REMOTE/weekly
MONTHLY=$REMOTE/monthly
WEEKLY_KEEP=4
MONTHLY_KEEP=1
LOG=/var/log/pve-offsite-onedrive.log
RCLONE_FLAGS="--config /root/.config/rclone/rclone.conf --transfers 1 --checkers 2 --low-level-retries 10 --retries 3"

log() {
    local ts; ts=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$ts] $*" >> "$LOG"
    echo "[$ts] $*"
}

push() {
    local title="$1" msg="$2" prio="${3:-0}"
    [[ -z ${PUSHOVER_TOKEN:-} ]] && return
    curl -sS --max-time 10 \
        --form-string "token=$PUSHOVER_TOKEN" \
        --form-string "user=$PUSHOVER_USER" \
        --form-string "title=$title" \
        --form-string "message=$msg" \
        --form-string "priority=$prio" \
        https://api.pushover.net/1/messages.json -o /dev/null
}

DRY_RUN=false
PROMOTE_MONTHLY=false
for arg in "$@"; do
    case $arg in
        --dry-run) DRY_RUN=true; RCLONE_FLAGS="$RCLONE_FLAGS --dry-run" ;;
        --force-monthly) PROMOTE_MONTHLY=true ;;
    esac
done

# Auto-promote to monthly on first run of the month (day 1-7 + Sunday)
DAY=$(date +%-d)
if [[ $DAY -ge 1 && $DAY -le 7 ]]; then
    PROMOTE_MONTHLY=true
fi

START=$(date +%s)
log "=== offsite run start (dry_run=$DRY_RUN promote_monthly=$PROMOTE_MONTHLY) ==="

SUMMARY=""
FAILED=0
TOTAL_BYTES=0

for VMID in "${VMIDS[@]}"; do
    # Find latest vzdump for this VM
    LATEST=$(ls -1t "$DUMP_DIR"/vzdump-qemu-${VMID}-*.vma.zst 2>/dev/null | head -1)
    if [[ -z "$LATEST" ]]; then
        log "VM $VMID: no vzdump found, skipping"
        SUMMARY+="VM $VMID: NO DUMP"$'\n'
        FAILED=$((FAILED+1))
        continue
    fi
    BASE=$(basename "$LATEST" .vma.zst)
    SIZE=$(stat -c%s "$LATEST")
    SIZE_GB=$(awk -v b=$SIZE 'BEGIN{printf "%.2f", b/1073741824}')
    log "VM $VMID: $BASE.vma.zst ($SIZE_GB GB)"

    # Skip if already in weekly remote (idempotent on re-run)
    if rclone lsf $RCLONE_FLAGS "$WEEKLY/" 2>/dev/null | grep -q "^${BASE}\.vma\.zst$"; then
        log "VM $VMID: already in weekly, skipping upload"
    else
        # Upload .vma.zst + .log + .notes (rclone copy = 1 src + 1 dst, so loop)
        log "VM $VMID: uploading to $WEEKLY/"
        UPLOAD_OK=true
        for src in "$LATEST" "${LATEST%.vma.zst}.log" "${LATEST}.notes"; do
            [[ -e "$src" ]] || continue
            if ! rclone copy $RCLONE_FLAGS "$src" "$WEEKLY/" 2>&1 | tee -a "$LOG"; then
                UPLOAD_OK=false
                break
            fi
        done
        if ! $UPLOAD_OK; then
            log "VM $VMID: UPLOAD FAILED"
            SUMMARY+="VM $VMID: UPLOAD FAILED"$'\n'
            FAILED=$((FAILED+1))
            continue
        fi
        TOTAL_BYTES=$((TOTAL_BYTES + SIZE))
    fi

    # Promote to monthly?
    if $PROMOTE_MONTHLY; then
        if rclone lsf $RCLONE_FLAGS "$MONTHLY/" 2>/dev/null | grep -q "^${BASE}\.vma\.zst$"; then
            log "VM $VMID: already in monthly, skipping promote"
        else
            log "VM $VMID: promoting to monthly (server-side copy)"
            # Server-side copy from weekly → monthly (avoids re-upload)
            for ext in vma.zst log vma.zst.notes; do
                rclone copy $RCLONE_FLAGS "$WEEKLY/${BASE}.${ext}" "$MONTHLY/" 2>&1 | tee -a "$LOG" || true
            done
        fi
    fi

    SUMMARY+="VM $VMID: $SIZE_GB GB"$'\n'
done


### RESTORE-SYNC-BLOCK ###
# Mirror the local pve-restore-*.tar.gz.gpg snapshots to OneDrive:proxmox-offsite/restore/
# `rclone sync` makes the remote match the local dir, so local retention (KEEP=8)
# propagates automatically. Tarballs are GPG-symmetric encrypted at rest.
RESTORE_LOCAL=/mnt/nvme/backups/pve-config
RESTORE_REMOTE=$REMOTE/restore
if compgen -G "$RESTORE_LOCAL/pve-restore-*.tar.gz.gpg" >/dev/null; then
    log "restore: syncing $RESTORE_LOCAL -> $RESTORE_REMOTE"
    if rclone sync $RCLONE_FLAGS \
        --include "pve-restore-*.tar.gz.gpg" \
        "$RESTORE_LOCAL/" "$RESTORE_REMOTE/" 2>&1 | tee -a "$LOG"; then
        RCOUNT=$(ls -1 "$RESTORE_LOCAL"/pve-restore-*.tar.gz.gpg 2>/dev/null | wc -l)
        RBYTES=$(du -cb "$RESTORE_LOCAL"/pve-restore-*.tar.gz.gpg 2>/dev/null | tail -1 | cut -f1)
        RGB=$(awk -v b=${RBYTES:-0} 'BEGIN{printf "%.2f", b/1073741824}')
        log "restore: $RCOUNT snapshots, $RGB GB total"
        SUMMARY+="Restore: $RCOUNT snapshots ($RGB GB)"$'\n'
    else
        log "restore: SYNC FAILED"
        SUMMARY+="Restore: SYNC FAILED"$'\n'
        FAILED=$((FAILED+1))
    fi
else
    log "restore: no local snapshots in $RESTORE_LOCAL (skip)"
fi
### /RESTORE-SYNC-BLOCK ###

# Prune
prune_remote() {
    local remote=$1 vmid=$2 keep=$3
    # List files for this vmid, newest first by name (vzdump timestamp = ISO-ish = lex sort works)
    mapfile -t files < <(rclone lsf $RCLONE_FLAGS "$remote/" 2>/dev/null \
        | grep "^vzdump-qemu-${vmid}-.*\.vma\.zst$" | sort -r)
    if [[ ${#files[@]} -le $keep ]]; then
        log "prune $remote VM $vmid: ${#files[@]} files (≤ $keep), nothing to remove"
        return
    fi
    for ((i=keep; i<${#files[@]}; i++)); do
        local base="${files[$i]%.vma.zst}"
        log "prune $remote VM $vmid: removing $base.*"
        rclone delete $RCLONE_FLAGS "$remote/${base}.vma.zst"  2>&1 | tee -a "$LOG" || true
        rclone delete $RCLONE_FLAGS "$remote/${base}.log"      2>&1 | tee -a "$LOG" || true
        rclone delete $RCLONE_FLAGS "$remote/${base}.vma.zst.notes" 2>&1 | tee -a "$LOG" || true
    done
}

for VMID in "${VMIDS[@]}"; do
    prune_remote "$WEEKLY"  "$VMID" "$WEEKLY_KEEP"
    prune_remote "$MONTHLY" "$VMID" "$MONTHLY_KEEP"
done

ELAPSED=$(( $(date +%s) - START ))
MINS=$((ELAPSED / 60))
TOTAL_GB=$(awk -v b=$TOTAL_BYTES 'BEGIN{printf "%.2f", b/1073741824}')

log "=== offsite run done in ${MINS}m, uploaded ${TOTAL_GB} GB, failed=$FAILED ==="

if [[ $FAILED -gt 0 ]]; then
    push "[OFFSITE] PVE backup FAILED" "Failed $FAILED VMs in ${MINS}m. Check /var/log/pve-offsite-onedrive.log" 1
elif ! $DRY_RUN; then
    push "[OFFSITE] PVE backup OK" "${TOTAL_GB} GB uploaded in ${MINS}m. promote_monthly=$PROMOTE_MONTHLY" -1
fi

# Trim log to last 1000 lines
tail -1000 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"

# Heartbeat for HA stale-detection
HB_STATUS=ok; [[ $FAILED -gt 0 ]] && HB_STATUS=fail
/usr/local/sbin/pve-cron-heartbeat.sh offsite_onedrive "$HB_STATUS" "Off-site OneDrive" >/dev/null 2>&1 || true
