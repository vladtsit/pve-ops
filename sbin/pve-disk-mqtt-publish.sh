#!/bin/bash
# Publishes per-disk SMART state to MQTT + Home Assistant discovery topics.
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
. /etc/pve-monitor.env
HOST_ID="proxmox"
DEVICE_JSON='{"identifiers":["pve_disks_proxmox"],"name":"Proxmox Disks","manufacturer":"Intel NUC10i3FNH","model":"PVE 9.1"}'

pub() {
    mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT" -u "$MQTT_USER" -P "$MQTT_PASS" -r -t "$1" -m "$2"
}

publish_disk() {
    local dev=$1 stype=$2 label=$3
    local base="pve/$HOST_ID/$dev"
    local health temp poh percent_used reallocated pending crc

    if [ "$stype" = "nvme" ]; then
        # NVMe: smartctl -A -H -j
        local j
        j=$(smartctl -a -j /dev/$dev 2>/dev/null) || j='{}'
        health=$(echo "$j" | jq -r '.smart_status.passed | if . == true then "PASSED" elif . == false then "FAILED" else "UNKNOWN" end')
        temp=$(echo "$j" | jq -r '.temperature.current // empty')
        poh=$(echo "$j" | jq -r '.power_on_time.hours // empty')
        percent_used=$(echo "$j" | jq -r '.nvme_smart_health_information_log.percentage_used // empty')
        reallocated=$(echo "$j" | jq -r '.nvme_smart_health_information_log.media_errors // 0')
        pending=$(echo "$j" | jq -r '.nvme_smart_health_information_log.critical_warning // 0')
        crc=$(echo "$j" | jq -r '.nvme_smart_health_information_log.unsafe_shutdowns // 0')
    else
        local j
        j=$(smartctl -a -j /dev/$dev 2>/dev/null) || j='{}'
        health=$(echo "$j" | jq -r '.smart_status.passed | if . == true then "PASSED" elif . == false then "FAILED" else "UNKNOWN" end')
        temp=$(echo "$j" | jq -r '.temperature.current // empty')
        poh=$(echo "$j" | jq -r '.power_on_time.hours // empty')
        # Try common attributes
        reallocated=$(echo "$j" | jq -r '.ata_smart_attributes.table // [] | .[] | select(.id==5) | .raw.value // empty' | head -1)
        pending=$(echo "$j" | jq -r '.ata_smart_attributes.table // [] | .[] | select(.id==197) | .raw.value // empty' | head -1)
        crc=$(echo "$j" | jq -r '.ata_smart_attributes.table // [] | .[] | select(.id==199) | .raw.value // empty' | head -1)
        # Wear: id 177 (Samsung), 230 (WD) - normalized value
        percent_used=$(echo "$j" | jq -r '.ata_smart_attributes.table // [] | .[] | select(.id==177 or .id==230) | (100 - .value) // empty' | head -1)
        [ -z "$reallocated" ] && reallocated=0
        [ -z "$pending" ] && pending=0
        [ -z "$crc" ] && crc=0
    fi
    [ -z "$temp" ] && temp="null"
    [ -z "$poh" ] && poh="null"
    [ -z "$percent_used" ] && percent_used="null"

    pub "$base/health" "$health"
    pub "$base/temperature" "$temp"
    pub "$base/power_on_hours" "$poh"
    pub "$base/percent_used" "$percent_used"
    pub "$base/reallocated" "$reallocated"
    pub "$base/pending" "$pending"
    pub "$base/crc_errors" "$crc"

    # HA discovery: one sensor per metric
    local uid="pve_${HOST_ID}_${dev}"
    local name_prefix="PVE ${label}"

    pub "homeassistant/binary_sensor/${uid}_health/config" \
        "{\"name\":\"$name_prefix Health\",\"unique_id\":\"${uid}_health\",\"state_topic\":\"$base/health\",\"payload_on\":\"FAILED\",\"payload_off\":\"PASSED\",\"device_class\":\"problem\",\"device\":$DEVICE_JSON}"

    pub "homeassistant/sensor/${uid}_temp/config" \
        "{\"name\":\"$name_prefix Temperature\",\"unique_id\":\"${uid}_temp\",\"state_topic\":\"$base/temperature\",\"unit_of_measurement\":\"°C\",\"device_class\":\"temperature\",\"state_class\":\"measurement\",\"device\":$DEVICE_JSON}"

    pub "homeassistant/sensor/${uid}_poh/config" \
        "{\"name\":\"$name_prefix Power-On Hours\",\"unique_id\":\"${uid}_poh\",\"state_topic\":\"$base/power_on_hours\",\"unit_of_measurement\":\"h\",\"state_class\":\"total_increasing\",\"entity_category\":\"diagnostic\",\"device\":$DEVICE_JSON}"

    pub "homeassistant/sensor/${uid}_wear/config" \
        "{\"name\":\"$name_prefix Wear\",\"unique_id\":\"${uid}_wear\",\"state_topic\":\"$base/percent_used\",\"unit_of_measurement\":\"%\",\"state_class\":\"measurement\",\"entity_category\":\"diagnostic\",\"device\":$DEVICE_JSON}"

    pub "homeassistant/sensor/${uid}_realloc/config" \
        "{\"name\":\"$name_prefix Reallocated Sectors\",\"unique_id\":\"${uid}_realloc\",\"state_topic\":\"$base/reallocated\",\"state_class\":\"measurement\",\"entity_category\":\"diagnostic\",\"device\":$DEVICE_JSON}"

    pub "homeassistant/sensor/${uid}_pending/config" \
        "{\"name\":\"$name_prefix Pending Sectors\",\"unique_id\":\"${uid}_pending\",\"state_topic\":\"$base/pending\",\"state_class\":\"measurement\",\"entity_category\":\"diagnostic\",\"device\":$DEVICE_JSON}"

    pub "homeassistant/sensor/${uid}_crc/config" \
        "{\"name\":\"$name_prefix CRC/Unsafe-Shutdowns\",\"unique_id\":\"${uid}_crc\",\"state_topic\":\"$base/crc_errors\",\"state_class\":\"measurement\",\"entity_category\":\"diagnostic\",\"device\":$DEVICE_JSON}"
}

publish_disk sda sat  "sda WD 120GB"
publish_disk sdb sat  "sdb Samsung 870"
publish_disk sdc nvme "sdc NVMe 1TB"

# Also publish a host-level "last update" timestamp
pub "pve/$HOST_ID/last_update" "$(date -Is)"
pub "homeassistant/sensor/pve_${HOST_ID}_last_update/config" \
    "{\"name\":\"PVE Disk Stats Updated\",\"unique_id\":\"pve_${HOST_ID}_last_update\",\"state_topic\":\"pve/$HOST_ID/last_update\",\"device_class\":\"timestamp\",\"entity_category\":\"diagnostic\",\"device\":$DEVICE_JSON}"
