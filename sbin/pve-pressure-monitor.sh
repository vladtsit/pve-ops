#!/bin/bash
# pve-pressure-monitor.sh
# Sustained memory + disk pressure monitor with Pushover alerts.
# Runs from cron every 5 min. Alerts after 3 consecutive samples (15 min)
# above threshold. Hysteresis clears at warn-5%. Repeats every 6h while bad.
# Recovery notification sent when target returns to ok.
#
# Targets:
#  - host:mem, host:swap, host:root (/), host:nvme (/mnt/nvme)
#  - storage:<name>   for every entry in `pvesm status`
#  - vm:<id>:mem      for every running VM (via pvesh)
#
# State: /var/lib/pve-pressure-monitor/state.json
# Log:   /var/log/pve-pressure-monitor.log

set -uo pipefail

# ---------- config -------------------------------------------------------
WARN_PCT=80
CRIT_PCT=90
CLEAR_PCT=75            # hysteresis
SAMPLES_REQUIRED=3      # 3 x 5min = 15 min sustained
REPEAT_HOURS=6
STATE_DIR=/var/lib/pve-pressure-monitor
STATE_FILE=$STATE_DIR/state.json
LOG_FILE=/var/log/pve-pressure-monitor.log
ENV_FILE=/etc/pve-monitor.env
HOSTNAME=$(hostname)

# Load Pushover creds (PUSHOVER_TOKEN, PUSHOVER_USER)
if [[ -r $ENV_FILE ]]; then
    # shellcheck disable=SC1090
    . "$ENV_FILE"
fi

DRY_RUN=false
TEST_ONLY=false
VERBOSE=false
for arg in "$@"; do
    case $arg in
        --dry-run) DRY_RUN=true; VERBOSE=true ;;
        --test)    TEST_ONLY=true ;;
        --verbose) VERBOSE=true ;;
        --help|-h)
            echo "Usage: $0 [--dry-run] [--test] [--verbose]"
            exit 0 ;;
    esac
done

mkdir -p "$STATE_DIR"
[[ -f $STATE_FILE ]] || echo '{}' > "$STATE_FILE"

log() {
    local ts; ts=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$ts] $*" >> "$LOG_FILE"
    $VERBOSE && echo "[$ts] $*"
}

pushover() {
    local title="$1" msg="$2" prio="${3:-0}"
    if [[ -z ${PUSHOVER_TOKEN:-} || -z ${PUSHOVER_USER:-} ]]; then
        log "ERROR: Pushover creds missing; would have sent: [$title] $msg"
        return 1
    fi
    if $DRY_RUN; then
        log "DRY-RUN pushover prio=$prio title=\"$title\" msg=\"$msg\""
        return 0
    fi
    local rc
    rc=$(curl -sS --max-time 10 \
        --form-string "token=$PUSHOVER_TOKEN" \
        --form-string "user=$PUSHOVER_USER" \
        --form-string "title=$title" \
        --form-string "message=$msg" \
        --form-string "priority=$prio" \
        https://api.pushover.net/1/messages.json \
        -o /dev/null -w '%{http_code}')
    log "pushover prio=$prio rc=$rc title=\"$title\""
}

# ---------- MQTT publish (HA discovery + state) -------------------------
PRESSURE_MQTT_DEVICE_JSON='{"identifiers":["pve_pressure_proxmox"],"name":"Proxmox Pressure Monitor","manufacturer":"Intel NUC10i3FNH","model":"PVE 9.1"}'

publish_pressure_mqtt() {
    local target="$1" pct="$2" level="$3" detail="$4"
    [[ -z ${MQTT_HOST:-} ]] && return 0
    local slug
    slug=$(printf "%s" "$target" | sed "s/(.*)//" | tr ":" "_" | tr -c "[:alnum:]_-" "_" | tr -s "_" | sed "s/_$//")
    local base="pve/proxmox/pressure/$slug"
    local uid="pve_proxmox_pressure_${slug}"
    local mp=(mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT" -u "$MQTT_USER" -P "$MQTT_PASS" -r)
    "${mp[@]}" -t "$base/pct"    -m "$pct"    2>/dev/null || true
    "${mp[@]}" -t "$base/level"  -m "$level"  2>/dev/null || true
    "${mp[@]}" -t "$base/detail" -m "$detail" 2>/dev/null || true
    "${mp[@]}" -t "homeassistant/sensor/${uid}_pct/config" \
        -m "{\"name\":\"PVE Pressure $target %\",\"unique_id\":\"${uid}_pct\",\"state_topic\":\"$base/pct\",\"unit_of_measurement\":\"%\",\"state_class\":\"measurement\",\"entity_category\":\"diagnostic\",\"device\":$PRESSURE_MQTT_DEVICE_JSON}" 2>/dev/null || true
    "${mp[@]}" -t "homeassistant/sensor/${uid}_level/config" \
        -m "{\"name\":\"PVE Pressure $target Level\",\"unique_id\":\"${uid}_level\",\"state_topic\":\"$base/level\",\"entity_category\":\"diagnostic\",\"device\":$PRESSURE_MQTT_DEVICE_JSON}" 2>/dev/null || true
}


# ---------- self test ----------------------------------------------------
if $TEST_ONLY; then
    pushover "[TEST] pve-pressure-monitor" "Test from $HOSTNAME at $(date '+%Y-%m-%d %H:%M')" 0
    exit 0
fi

# ---------- collect samples ---------------------------------------------
# Build array of "target|pct|detail"
declare -a SAMPLES=()

# host mem
read -r mem_total mem_avail < <(awk '/^MemTotal:/{t=$2} /^MemAvailable:/{a=$2} END{print t,a}' /proc/meminfo)
mem_used=$((mem_total - mem_avail))
mem_pct=$(awk -v u=$mem_used -v t=$mem_total 'BEGIN{printf "%.1f", u/t*100}')
SAMPLES+=("host:mem|$mem_pct|$(awk -v u=$mem_used -v t=$mem_total 'BEGIN{printf "%.1f/%.1f GB", u/1048576, t/1048576}')")

# host swap
read -r swap_total swap_free < <(awk '/^SwapTotal:/{t=$2} /^SwapFree:/{f=$2} END{print t,f}' /proc/meminfo)
if [[ $swap_total -gt 0 ]]; then
    swap_used=$((swap_total - swap_free))
    swap_pct=$(awk -v u=$swap_used -v t=$swap_total 'BEGIN{printf "%.1f", u/t*100}')
    SAMPLES+=("host:swap|$swap_pct|$(awk -v u=$swap_used -v t=$swap_total 'BEGIN{printf "%.2f/%.2f GB", u/1048576, t/1048576}')")
fi

# host filesystems (root + nvme)
for mnt in / /mnt/nvme; do
    if mountpoint -q "$mnt"; then
        line=$(df -P "$mnt" | tail -1)
        pct=$(echo "$line" | awk '{gsub("%","",$5); print $5}')
        used=$(echo "$line" | awk '{print $3}')
        size=$(echo "$line" | awk '{print $2}')
        detail=$(awk -v u=$used -v s=$size 'BEGIN{printf "%.1f/%.1f GB", u/1048576, s/1048576}')
        key="host:$(echo "$mnt" | sed 's|/|root|;s|^root$|root|;s|/|_|g;s|^_||')"
        # cleaner: / -> root, /mnt/nvme -> nvme
        case "$mnt" in
            /) key="host:root" ;;
            /mnt/nvme) key="host:nvme" ;;
        esac
        SAMPLES+=("$key|$pct|$detail")
    fi
done

# PVE storage pools
while IFS= read -r line; do
    name=$(echo "$line" | awk '{print $1}')
    status=$(echo "$line" | awk '{print $3}')
    total=$(echo "$line" | awk '{print $4}')
    used=$(echo "$line" | awk '{print $5}')
    pctcol=$(echo "$line" | awk '{print $7}')
    [[ "$status" != "active" ]] && continue
    [[ -z "$total" || "$total" == "0" ]] && continue
    pct=$(echo "$pctcol" | tr -d '%')
    detail=$(awk -v u=$used -v t=$total 'BEGIN{printf "%.1f/%.1f GB", u/1048576, t/1048576}')
    SAMPLES+=("storage:$name|$pct|$detail")
done < <(pvesm status 2>/dev/null | awk 'NR>1')

# Running VMs - memory only (disk via guest agent not configured)
while IFS= read -r vmid; do
    [[ -z "$vmid" ]] && continue
    name=$(qm config "$vmid" 2>/dev/null | awk -F': ' '/^name:/{print $2}')
    json=$(pvesh get "/nodes/$HOSTNAME/qemu/$vmid/status/current" --output-format json 2>/dev/null)
    [[ -z "$json" ]] && continue
    mem=$(echo "$json" | jq -r '.mem // 0')
    maxmem=$(echo "$json" | jq -r '.maxmem // 0')
    [[ "$maxmem" -eq 0 ]] && continue
    pct=$(awk -v m=$mem -v M=$maxmem 'BEGIN{printf "%.1f", m/M*100}')
    detail=$(awk -v m=$mem -v M=$maxmem 'BEGIN{printf "%.2f/%.2f GB", m/1073741824, M/1073741824}')
    SAMPLES+=("vm:$vmid($name):mem|$pct|$detail")
done < <(qm list 2>/dev/null | awk 'NR>1 && $3=="running"{print $1}')

# ---------- evaluate state ----------------------------------------------
NOW=$(date +%s)
NOW_HUMAN=$(date '+%Y-%m-%d %H:%M')
NEW_STATE=$(cat "$STATE_FILE")

for entry in "${SAMPLES[@]}"; do
    IFS='|' read -r target pct detail <<< "$entry"

    # Append sample to ring (keep last SAMPLES_REQUIRED)
    NEW_STATE=$(jq --arg t "$target" --argjson p "$pct" --arg d "$detail" --argjson n $SAMPLES_REQUIRED '
        .[$t] = (.[$t] // {samples:[], level:"ok", last_notified_level:"ok", last_notified_ts:0, last_detail:""})
        | .[$t].samples = ((.[$t].samples + [$p])[-($n|tonumber):])
        | .[$t].last_detail = $d
    ' <<< "$NEW_STATE")

    # Determine current level
    samples_json=$(jq -r --arg t "$target" '.[$t].samples | @json' <<< "$NEW_STATE")
    sample_count=$(jq 'length' <<< "$samples_json")
    last_level=$(jq -r --arg t "$target" '.[$t].last_notified_level' <<< "$NEW_STATE")
    last_ts=$(jq -r --arg t "$target" '.[$t].last_notified_ts' <<< "$NEW_STATE")

    level="ok"
    if [[ $sample_count -ge $SAMPLES_REQUIRED ]]; then
        all_crit=$(jq --argjson c $CRIT_PCT '[.[] | select(. >= $c)] | length' <<< "$samples_json")
        all_warn=$(jq --argjson w $WARN_PCT '[.[] | select(. >= $w)] | length' <<< "$samples_json")
        if [[ $all_crit -eq $SAMPLES_REQUIRED ]]; then
            level="critical"
        elif [[ $all_warn -eq $SAMPLES_REQUIRED ]]; then
            level="warn"
        fi
    fi

    # Hysteresis: if previously alerted, stay alerted until below CLEAR_PCT
    cur_pct_int=$(awk -v p=$pct 'BEGIN{print int(p)}')
    if [[ "$last_level" != "ok" && "$level" == "ok" && $cur_pct_int -ge $CLEAR_PCT ]]; then
        level="$last_level"     # don't clear yet
    fi

    NEW_STATE=$(jq --arg t "$target" --arg l "$level" '.[$t].level = $l' <<< "$NEW_STATE")

    # Notification decision
    should_notify=false
    notify_kind=""
    if [[ "$level" != "ok" && "$last_level" == "ok" ]]; then
        should_notify=true; notify_kind="new"
    elif [[ "$level" != "ok" && "$level" != "$last_level" ]]; then
        should_notify=true; notify_kind="upgrade"
    elif [[ "$level" != "ok" && "$level" == "$last_level" ]]; then
        # repeat after REPEAT_HOURS
        if (( NOW - last_ts >= REPEAT_HOURS * 3600 )); then
            should_notify=true; notify_kind="repeat"
        fi
    elif [[ "$level" == "ok" && "$last_level" != "ok" ]]; then
        should_notify=true; notify_kind="recovery"
    fi

    log "target=$target pct=$pct%  samples=$samples_json  level=$level (was $last_level)  notify=$notify_kind"
    publish_pressure_mqtt "$target" "$pct" "$level" "$detail"

    if $should_notify; then
        prio=0
        title=""
        msg=""
        case "$notify_kind" in
            new|upgrade|repeat)
                [[ "$level" == "critical" ]] && prio=1
                tag=$([[ "$level" == "critical" ]] && echo CRIT || echo WARN)
                title="[$tag] $target ${pct}%"
                msg="$detail. Sustained ${SAMPLES_REQUIRED}x5min. Samples: $(jq -r 'join(", ")' <<< "$samples_json")%. $NOW_HUMAN"
                [[ "$notify_kind" == "repeat" ]] && title="$title (still)"
                ;;
            recovery)
                title="[OK] $target recovered (${pct}%)"
                msg="$detail. Returned to normal at $NOW_HUMAN."
                ;;
        esac
        pushover "$title" "$msg" "$prio"
        if ! $DRY_RUN; then
            NEW_STATE=$(jq --arg t "$target" --arg l "$level" --argjson ts "$NOW" '
                .[$t].last_notified_level = $l |
                .[$t].last_notified_ts = $ts
            ' <<< "$NEW_STATE")
        fi
    fi
done

# Save state (unless dry-run)
if ! $DRY_RUN; then
    echo "$NEW_STATE" | jq . > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
fi

# Trim log to last 500 lines
if [[ -f $LOG_FILE ]]; then
    tail -500 "$LOG_FILE" > "$LOG_FILE.tmp" && mv "$LOG_FILE.tmp" "$LOG_FILE"
fi

# Heartbeat for HA stale-detection (always ok if we reached this line)
/usr/local/sbin/pve-cron-heartbeat.sh pressure_monitor ok "Pressure Monitor" >/dev/null 2>&1 || true
