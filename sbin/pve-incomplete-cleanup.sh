#!/bin/bash
# pve-incomplete-cleanup.sh
# Delete stale files in torrent "incomplete" staging dirs.
# Files older than $AGE_DAYS days are removed; empty subdirs are pruned.
# The root dirs themselves are never deleted.
set -euo pipefail

AGE_DAYS="${AGE_DAYS:-7}"
DIRS=(
    /mnt/nvme/data/incomplete
    /mnt/nvme/data/incomplete_xxx
)
LOG=/var/log/pve-incomplete-cleanup.log
DRY_RUN="${DRY_RUN:-0}"

ts() { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "[$(ts)] $*" | tee -a "$LOG"; }

log "=== cleanup start (age>${AGE_DAYS}d, dry_run=${DRY_RUN}) ==="

total_files=0
total_bytes=0

for d in "${DIRS[@]}"; do
    if [ ! -d "$d" ]; then
        log "skip (missing): $d"
        continue
    fi

    # Sum size of files to be deleted
    bytes=$(find "$d" -type f -mtime "+${AGE_DAYS}" -printf '%s\n' 2>/dev/null \
            | awk '{s+=$1} END {print s+0}')
    count=$(find "$d" -type f -mtime "+${AGE_DAYS}" 2>/dev/null | wc -l)

    log "$d : ${count} files, $(numfmt --to=iec --suffix=B "${bytes}")"

    if [ "$DRY_RUN" = "1" ]; then
        continue
    fi

    # Delete stale files
    find "$d" -type f -mtime "+${AGE_DAYS}" -delete 2>>"$LOG" || true
    # Prune empty subdirs (but never the root)
    find "$d" -mindepth 1 -type d -empty -delete 2>>"$LOG" || true

    total_files=$(( total_files + count ))
    total_bytes=$(( total_bytes + bytes ))
done

log "=== done. removed ${total_files} files, $(numfmt --to=iec --suffix=B "${total_bytes}") freed ==="
