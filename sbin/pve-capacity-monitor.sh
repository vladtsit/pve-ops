#!/bin/bash
# pve-capacity-monitor.sh
# Warn (Pushover + MQTT) when NVMe backup volume or OneDrive offsite quota
# is too tight to safely accept the next vzdump / weekly off-site upload.
#
# Runs daily 02:30 (before nightly vzdump @ 03:00 and before Sunday off-site @ 04:00).
#
# Policy:
#   NVMe (local /mnt/nvme/backups/dump):
#     required = 2 x largest_dump_in_last_7d        (covers full new daily dump cycle)
#     warn     when free < 1.5 x required           (priority 0)
#     critical when free < required                 (priority 1)
#
#   OneDrive (account-wide free as reported by `rclone about`):
#     required = max(5 x last_weekly_upload_size, 10 GiB)
#     warn     when free < 1.5 x required           (priority 0)
#     critical when free < required                 (priority 1)
#
# State file in /var/lib/pve-capacity-monitor.state suppresses duplicate
# alerts for the same level within 24h.

set -eo pipefail
. /etc/pve-monitor.env

DUMP_DIR="/mnt/nvme/backups/dump"
NVME_MOUNT="/mnt/nvme"
RCLONE_REMOTE="OneDrive:"
OFFSITE_PATH="OneDrive:proxmox-offsite"
RCLONE_CONF="/root/.config/rclone/rclone.conf"

LOG=/var/log/pve-capacity-monitor.log
STATE=/var/lib/pve-capacity-monitor.state
mkdir -p "$(dirname "$STATE")"
touch "$STATE"

MIN_OFFSITE_HEADROOM=$((10 * 1024 * 1024 * 1024))   # 10 GiB
SUPPRESS_SECS=$((24 * 3600))

BASE="pve/proxmox/capacity"
HA_BASE="homeassistant"
DEV_ID="pve_proxmox_capacity"
DEV_NAME="Proxmox Capacity"

log() { echo "[$(date '+%F %T')] $*" >> "$LOG"; }

pushover() {
    # $1=title $2=msg $3=priority(0|1)
    [[ -z "$PUSHOVER_TOKEN" || -z "$PUSHOVER_USER" ]] && return 0
    curl -sS --max-time 10 \
        --form-string "token=$PUSHOVER_TOKEN" \
        --form-string "user=$PUSHOVER_USER" \
        --form-string "title=$1" \
        --form-string "message=$2" \
        --form-string "priority=${3:-0}" \
        ${3:+--form-string "retry=60" --form-string "expire=3600"} \
        https://api.pushover.net/1/messages.json >/dev/null || true
}

mqtt_pub() {
    # $1=subtopic $2=value
    mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT" -u "$MQTT_USER" -P "$MQTT_PASS" \
        -r -t "$BASE/$1" -m "$2" 2>/dev/null || true
}

mqtt_pub_raw() {
    mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT" -u "$MQTT_USER" -P "$MQTT_PASS" \
        -r -t "$1" -m "$2" 2>/dev/null || true
}

DEV_JSON='"device":{"identifiers":["'"$DEV_ID"'"],"name":"'"$DEV_NAME"'","model":"NUC10i3FNH","manufacturer":"Intel"}'

disc_num() {
    # $1=key $2=name $3=unit $4=icon
    mqtt_pub_raw "$HA_BASE/sensor/${DEV_ID}_$1/config" \
'{"name":"'"$2"'","state_topic":"'"$BASE"'/'"$1"'","unique_id":"'"$DEV_ID"'_'"$1"'","unit_of_measurement":"'"$3"'","state_class":"measurement","icon":"'"$4"'",'"$DEV_JSON"'}'
}
disc_text() {
    mqtt_pub_raw "$HA_BASE/sensor/${DEV_ID}_$1/config" \
'{"name":"'"$2"'","state_topic":"'"$BASE"'/'"$1"'","unique_id":"'"$DEV_ID"'_'"$1"'","icon":"'"$3"'",'"$DEV_JSON"'}'
}

# ---- HA discovery (idempotent, retained) ----
disc_num  nvme_free_gb            "NVMe Backup Free"             "GB"    "mdi:harddisk"
disc_num  nvme_dump_used_gb       "NVMe Dump Dir Size"           "GB"    "mdi:database"
disc_num  nvme_largest_dump_gb    "Largest Recent vzdump"        "GB"    "mdi:file-chart"
disc_num  onedrive_free_gb        "OneDrive Free"                "GB"    "mdi:cloud"
disc_num  onedrive_used_gb        "OneDrive Used"                "GB"    "mdi:cloud-upload"
disc_num  onedrive_offsite_gb     "OneDrive Off-site Used"       "GB"    "mdi:cloud-lock"
disc_text nvme_status             "NVMe Backup Capacity Status"  "mdi:harddisk-plus"
disc_text onedrive_status         "OneDrive Capacity Status"     "mdi:cloud-check"

bytes_to_gb() { awk -v b="$1" 'BEGIN{printf "%.2f", b/1073741824}'; }

alert_once() {
    # $1=key $2=level(crit|warn) $3=title $4=msg
    local key="$1" level="$2" title="$3" msg="$4"
    local now last_ts last_lvl line
    now=$(date +%s)
    line=$(grep -E "^${key}:" "$STATE" 2>/dev/null | tail -1 || true)
    last_ts=$(echo "$line" | cut -d: -f2)
    last_lvl=$(echo "$line" | cut -d: -f3)
    if [[ -n "$last_ts" && "$last_lvl" == "$level" && $((now - last_ts)) -lt $SUPPRESS_SECS ]]; then
        log "suppress $key $level (last alert $((now - last_ts))s ago)"
        return 0
    fi
    local prio=0
    [[ "$level" == "crit" ]] && prio=1
    pushover "$title" "$msg" "$prio"
    log "ALERT $level $key: $msg"
    # rewrite state
    grep -vE "^${key}:" "$STATE" > "$STATE.tmp" 2>/dev/null || true
    echo "${key}:${now}:${level}" >> "$STATE.tmp"
    mv "$STATE.tmp" "$STATE"
}

# ---- NVMe checks ----
nvme_free=$(df -B1 --output=avail "$NVME_MOUNT" | tail -1)
dump_used=$(du -sb "$DUMP_DIR" 2>/dev/null | awk '{print $1}')
largest_dump=$(find "$DUMP_DIR" -name '*.vma.zst' -mtime -7 -printf '%s\n' 2>/dev/null \
                 | sort -n | tail -1)
[[ -z "$largest_dump" ]] && largest_dump=$(find "$DUMP_DIR" -name '*.vma.zst' -printf '%s\n' 2>/dev/null \
                                            | sort -n | tail -1)
[[ -z "$largest_dump" ]] && largest_dump=0

nvme_required=$((largest_dump * 2))
nvme_warn=$((nvme_required * 3 / 2))

mqtt_pub nvme_free_gb         "$(bytes_to_gb $nvme_free)"
mqtt_pub nvme_dump_used_gb    "$(bytes_to_gb $dump_used)"
mqtt_pub nvme_largest_dump_gb "$(bytes_to_gb $largest_dump)"

if (( largest_dump == 0 )); then
    mqtt_pub nvme_status "unknown"
    log "nvme: no recent vzdump found, skipping threshold check"
elif (( nvme_free < nvme_required )); then
    mqtt_pub nvme_status "critical"
    alert_once nvme crit "[CAPACITY] NVMe backup volume CRITICAL" \
"NVMe free $(bytes_to_gb $nvme_free) GB < required $(bytes_to_gb $nvme_required) GB
(2x largest recent dump $(bytes_to_gb $largest_dump) GB).
Next vzdump may fail. dump_dir=$(bytes_to_gb $dump_used) GB"
elif (( nvme_free < nvme_warn )); then
    mqtt_pub nvme_status "warning"
    alert_once nvme warn "[CAPACITY] NVMe backup volume tight" \
"NVMe free $(bytes_to_gb $nvme_free) GB < headroom $(bytes_to_gb $nvme_warn) GB.
largest_dump=$(bytes_to_gb $largest_dump) GB dump_dir=$(bytes_to_gb $dump_used) GB"
else
    mqtt_pub nvme_status "ok"
    log "nvme OK: free=$(bytes_to_gb $nvme_free)GB required=$(bytes_to_gb $nvme_required)GB"
fi

# ---- OneDrive checks ----
about_json=$(rclone --config "$RCLONE_CONF" about "$RCLONE_REMOTE" --json 2>/dev/null || echo '{}')
od_total=$(echo "$about_json" | jq -r '.total // 0')
od_used=$(echo  "$about_json" | jq -r '.used  // 0')
od_free=$(echo  "$about_json" | jq -r '.free  // 0')
offsite_used=$(rclone --config "$RCLONE_CONF" size "$OFFSITE_PATH" --json 2>/dev/null \
                  | jq -r '.bytes // 0' 2>/dev/null || echo 0)

# Estimate next weekly upload from largest weekly object on remote, fallback 5 GB
last_weekly=$(rclone --config "$RCLONE_CONF" lsjson "$OFFSITE_PATH/weekly" 2>/dev/null \
                  | jq -r '[.[].Size] | max // 0' 2>/dev/null || echo 0)
[[ -z "$last_weekly" || "$last_weekly" == "null" ]] && last_weekly=0
od_required=$((last_weekly * 5))
(( od_required < MIN_OFFSITE_HEADROOM )) && od_required=$MIN_OFFSITE_HEADROOM
od_warn=$((od_required * 3 / 2))

mqtt_pub onedrive_free_gb    "$(bytes_to_gb $od_free)"
mqtt_pub onedrive_used_gb    "$(bytes_to_gb $od_used)"
mqtt_pub onedrive_offsite_gb "$(bytes_to_gb $offsite_used)"

if (( od_total == 0 )); then
    mqtt_pub onedrive_status "unknown"
    log "onedrive: about call returned no quota, skipping check"
elif (( od_free < od_required )); then
    mqtt_pub onedrive_status "critical"
    alert_once onedrive crit "[CAPACITY] OneDrive off-site CRITICAL" \
"OneDrive free $(bytes_to_gb $od_free) GB < required $(bytes_to_gb $od_required) GB
(5x last weekly $(bytes_to_gb $last_weekly) GB, floor 10 GB).
Off-site upload Sunday may fail. account_used=$(bytes_to_gb $od_used) GB"
elif (( od_free < od_warn )); then
    mqtt_pub onedrive_status "warning"
    alert_once onedrive warn "[CAPACITY] OneDrive off-site tight" \
"OneDrive free $(bytes_to_gb $od_free) GB < headroom $(bytes_to_gb $od_warn) GB.
last_weekly=$(bytes_to_gb $last_weekly) GB offsite_used=$(bytes_to_gb $offsite_used) GB"
else
    mqtt_pub onedrive_status "ok"
    log "onedrive OK: free=$(bytes_to_gb $od_free)GB required=$(bytes_to_gb $od_required)GB"
fi

log "run done: nvme_free=$(bytes_to_gb $nvme_free)GB od_free=$(bytes_to_gb $od_free)GB"
