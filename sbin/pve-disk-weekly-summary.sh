#!/bin/bash
# Sends Saturday 10:00 health summary via Pushover.
. /etc/pve-monitor.env
TOKEN="$PUSHOVER_TOKEN"
USER_KEY="$PUSHOVER_USER"

line() {
    local dev=$1 stype=$2
    local health temp poh wear extra
    if [ "$stype" = "nvme" ]; then
        local j
        j=$(smartctl -a -j /dev/$dev 2>/dev/null)
        health=$(echo "$j" | jq -r '.smart_status.passed | if . == true then "OK" elif . == false then "FAIL" else "?" end')
        temp=$(echo "$j" | jq -r '.temperature.current // "?"')
        poh=$(echo "$j" | jq -r '.power_on_time.hours // "?"')
        wear=$(echo "$j" | jq -r '.nvme_smart_health_information_log.percentage_used // "?"')
        extra="MediaErr:$(echo "$j" | jq -r '.nvme_smart_health_information_log.media_errors // 0')"
    else
        local j
        j=$(smartctl -a -j /dev/$dev 2>/dev/null)
        health=$(echo "$j" | jq -r '.smart_status.passed | if . == true then "OK" elif . == false then "FAIL" else "?" end')
        temp=$(echo "$j" | jq -r '.temperature.current // "?"')
        poh=$(echo "$j" | jq -r '.power_on_time.hours // "?"')
        wear=$(echo "$j" | jq -r '.ata_smart_attributes.table // [] | .[] | select(.id==177 or .id==230) | (100 - .value) // 0' | head -1)
        local realloc=$(echo "$j" | jq -r '.ata_smart_attributes.table // [] | .[] | select(.id==5) | .raw.value // 0' | head -1)
        local pending=$(echo "$j" | jq -r '.ata_smart_attributes.table // [] | .[] | select(.id==197) | .raw.value // 0' | head -1)
        extra="Realloc:$realloc Pending:$pending"
    fi
    echo "/dev/$dev: $health  temp=${temp}C  poh=${poh}h  wear=${wear}%  $extra"
}

MSG="$(line sda sat)
$(line sdb sat)
$(line sdc nvme)

Uptime: $(uptime -p)
Disk usage:
$(df -h / /mnt/nvme 2>/dev/null | tail -2 | awk '{printf "  %s: %s used / %s (%s)\n", $6, $3, $2, $5}')
Backups ($(ls /mnt/nvme/backups/dump/*.vma.zst 2>/dev/null | wc -l) files, $(du -sh /mnt/nvme/backups/dump 2>/dev/null | cut -f1)):
$(ls -1t /mnt/nvme/backups/dump/*.vma.zst 2>/dev/null | head -3 | sed 's|/mnt/nvme/backups/dump/|  |')"

curl -s --max-time 15 https://api.pushover.net/1/messages.json \
    --form-string token="$TOKEN" \
    --form-string user="$USER_KEY" \
    --form-string title="PVE Weekly Disk Health" \
    --form-string message="$MSG" \
    --form-string priority=-1 \
    >> /var/log/smartd-alert.log 2>&1

# Refresh MQTT state too
/usr/local/sbin/pve-disk-mqtt-publish.sh >> /var/log/smartd-alert.log 2>&1 || true

# Heartbeat for HA stale-detection
/usr/local/sbin/pve-cron-heartbeat.sh disk_weekly_summary ok "Disk Weekly Summary" >/dev/null 2>&1 || true
