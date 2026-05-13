#!/bin/bash
# =============================================================================
# Video Converter - PVE host (UHD 620 VA-API)
# Converts /mnt/nvme/data/xxx/{Selected,auto_metart,auto} -> .../converted
# Hardware H.264 720p encode via Intel iHD driver
# Publishes rich MQTT/HA discovery sensors
# Sends Pushover on failure (priority 1)
# =============================================================================
set -eo pipefail

DATA_ROOT="/mnt/nvme/data/xxx"
declare -a SOURCE_DIRS=(
    "$DATA_ROOT/Selected"
    "$DATA_ROOT/auto_metart"
    "$DATA_ROOT/auto"
)
declare -a OUTPUT_DIRS=(
    "$DATA_ROOT/converted"
    "$DATA_ROOT/converted/metart"
    "$DATA_ROOT/converted"
)

LOG_FILE="$DATA_ROOT/conversion.log"
LOCK_FILE="/run/convert_copy.lock"

# MQTT (HAOS broker)
MQTT_BASE="video_converter"
HA_BASE="homeassistant"
HA_DEVICE_ID="video_converter"

# Pushover
. /etc/pve-monitor.env


VAAPI_DEVICE="/dev/dri/renderD128"
QUALITY=22

DRY_RUN=false
VERBOSE=false
while [[ $# -gt 0 ]]; do
    case $1 in
        --dry-run|-n) DRY_RUN=true; shift;;
        --verbose|-v) VERBOSE=true; shift;;
        --help|-h)
            echo "Usage: $0 [--dry-run] [--verbose]"; exit 0;;
        *) echo "Unknown: $1"; exit 1;;
    esac
done

# -------- helpers ---------------------------------------------------------
log() {
    local ts; ts=$(date '+%Y-%m-%d %H:%M:%S')
    echo "$1"
    echo "[$ts] $1" >> "$LOG_FILE"
}

mqtt_pub() {
    # $1=topic suffix  $2=payload  $3=retain (0/1)
    local retain=()
    [[ "${3:-1}" == "1" ]] && retain=(-r)
    mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT" -u "$MQTT_USER" -P "$MQTT_PASS" \
        "${retain[@]}" -t "$MQTT_BASE/$1" -m "$2" 2>/dev/null || true
}

mqtt_pub_raw() {
    # $1=full topic $2=payload $3=retain
    local retain=()
    [[ "${3:-1}" == "1" ]] && retain=(-r)
    mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT" -u "$MQTT_USER" -P "$MQTT_PASS" \
        "${retain[@]}" -t "$1" -m "$2" 2>/dev/null || true
}

pushover() {
    # $1=title $2=message $3=priority(0=default,1=high)
    curl -sf --max-time 10 https://api.pushover.net/1/messages.json \
        --form-string token="$PUSHOVER_TOKEN" \
        --form-string user="$PUSHOVER_USER" \
        --form-string title="$1" \
        --form-string message="$2" \
        --form-string priority="${3:-0}" \
        >/dev/null 2>&1 || true
}

# Publish HA MQTT discovery for all sensors (called once per run)
mqtt_register_ha() {
    local dev_json
    dev_json='"device":{"identifiers":["'"$HA_DEVICE_ID"'"],"name":"Video Converter","model":"ffmpeg VA-API","manufacturer":"Mediaserver"}'

    # Status (text)
    mqtt_pub_raw "$HA_BASE/sensor/${HA_DEVICE_ID}_status/config" \
'{"name":"Video Converter Status","state_topic":"'"$MQTT_BASE"'/status","unique_id":"'"$HA_DEVICE_ID"'_status","icon":"mdi:video-convert",'"$dev_json"'}' 1

    # Current file (text)
    mqtt_pub_raw "$HA_BASE/sensor/${HA_DEVICE_ID}_current/config" \
'{"name":"Video Converter Current File","state_topic":"'"$MQTT_BASE"'/current","unique_id":"'"$HA_DEVICE_ID"'_current","icon":"mdi:file-video",'"$dev_json"'}' 1

    # Progress (text "12/45")
    mqtt_pub_raw "$HA_BASE/sensor/${HA_DEVICE_ID}_progress/config" \
'{"name":"Video Converter Progress","state_topic":"'"$MQTT_BASE"'/progress","unique_id":"'"$HA_DEVICE_ID"'_progress","icon":"mdi:progress-clock",'"$dev_json"'}' 1

    # Numeric counters
    mqtt_pub_raw "$HA_BASE/sensor/${HA_DEVICE_ID}_processed/config" \
'{"name":"Video Converter Last Processed","state_topic":"'"$MQTT_BASE"'/last_processed","unique_id":"'"$HA_DEVICE_ID"'_processed","icon":"mdi:check-circle","unit_of_measurement":"files","state_class":"total",'"$dev_json"'}' 1

    mqtt_pub_raw "$HA_BASE/sensor/${HA_DEVICE_ID}_skipped/config" \
'{"name":"Video Converter Last Skipped","state_topic":"'"$MQTT_BASE"'/last_skipped","unique_id":"'"$HA_DEVICE_ID"'_skipped","icon":"mdi:skip-next-circle","unit_of_measurement":"files","state_class":"total",'"$dev_json"'}' 1

    mqtt_pub_raw "$HA_BASE/sensor/${HA_DEVICE_ID}_errors/config" \
'{"name":"Video Converter Last Errors","state_topic":"'"$MQTT_BASE"'/last_errors","unique_id":"'"$HA_DEVICE_ID"'_errors","icon":"mdi:alert-circle","unit_of_measurement":"files","state_class":"total",'"$dev_json"'}' 1

    mqtt_pub_raw "$HA_BASE/sensor/${HA_DEVICE_ID}_corrupted/config" \
'{"name":"Video Converter Last Corrupted","state_topic":"'"$MQTT_BASE"'/last_corrupted","unique_id":"'"$HA_DEVICE_ID"'_corrupted","icon":"mdi:file-cancel","unit_of_measurement":"files","state_class":"total",'"$dev_json"'}' 1

    mqtt_pub_raw "$HA_BASE/sensor/${HA_DEVICE_ID}_duration/config" \
'{"name":"Video Converter Last Duration","state_topic":"'"$MQTT_BASE"'/last_duration","unique_id":"'"$HA_DEVICE_ID"'_duration","icon":"mdi:timer","unit_of_measurement":"s","device_class":"duration","state_class":"measurement",'"$dev_json"'}' 1

    # Last run timestamp
    mqtt_pub_raw "$HA_BASE/sensor/${HA_DEVICE_ID}_last_run/config" \
'{"name":"Video Converter Last Run","state_topic":"'"$MQTT_BASE"'/last_run","unique_id":"'"$HA_DEVICE_ID"'_last_run","device_class":"timestamp",'"$dev_json"'}' 1

    # Problem binary_sensor (on = failure)
    mqtt_pub_raw "$HA_BASE/binary_sensor/${HA_DEVICE_ID}_problem/config" \
'{"name":"Video Converter Problem","state_topic":"'"$MQTT_BASE"'/problem","unique_id":"'"$HA_DEVICE_ID"'_problem","device_class":"problem","payload_on":"ON","payload_off":"OFF",'"$dev_json"'}' 1

    # Encoder (Hardware/CPU)
    mqtt_pub_raw "$HA_BASE/sensor/${HA_DEVICE_ID}_encoder/config" \
'{"name":"Video Converter Encoder","state_topic":"'"$MQTT_BASE"'/encoder","unique_id":"'"$HA_DEVICE_ID"'_encoder","icon":"mdi:chip",'"$dev_json"'}' 1
}

# -------- ffmpeg validation -----------------------------------------------
validate_input() {
    local file="$1"
    [[ -r "$file" ]] || { log "    ✗ Not readable: $file"; return 1; }
    if ! ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of csv=p=0 "$file" 2>/dev/null | grep -q .; then
        log "    ✗ No video stream: $file"; return 1
    fi
    local errs; errs=$(ffprobe -v error -i "$file" 2>&1 || true)
    [[ -z "$errs" ]] || { log "    ✗ Input errors: $errs"; return 1; }
    return 0
}

validate_output() {
    local file="$1" in_dur="$2" out_dur codec errs
    [[ -s "$file" ]] || { log "    ✗ Output empty"; return 1; }
    errs=$(ffprobe -v error -i "$file" 2>&1 || true)
    [[ -z "$errs" ]] || { log "    ✗ Output errors: $errs"; return 1; }
    codec=$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of csv=p=0 "$file" 2>/dev/null)
    [[ "$codec" == "h264" ]] || { log "    ✗ Codec not h264: $codec"; return 1; }
    out_dur=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$file" 2>/dev/null | cut -d'.' -f1)
    if [[ -n "$in_dur" && -n "$out_dur" ]]; then
        local d=$((out_dur - in_dur)); d=${d#-}
        [[ $d -le 2 ]] || { log "    ✗ Duration mismatch in=$in_dur out=$out_dur"; return 1; }
    fi
    return 0
}

check_vaapi() {
    [[ -e "$VAAPI_DEVICE" ]] || return 1
    ffmpeg -hide_banner -vaapi_device "$VAAPI_DEVICE" -f lavfi -i color=black:s=64x64:d=1 \
        -vf 'format=nv12,hwupload' -c:v h264_vaapi -low_power 1 -f null - 2>/dev/null
}

encode_vaapi_full() {
    # Full HW pipeline: VA-API decode -> scale -> VA-API encode.
    # Fails fast if the input codec/profile is not supported by the iGPU decoder.
    local input="$1" output="$2"
    ffmpeg -nostdin -hide_banner -loglevel warning -stats \
        -xerror -err_detect explode \
        -hwaccel vaapi -hwaccel_device "$VAAPI_DEVICE" -hwaccel_output_format vaapi \
        -i "$input" \
        -map 0:v:0 -map 0:a:0? \
        -vf "hwdownload,format=nv12,scale=-2:720:flags=lanczos,format=nv12,hwupload" \
        -c:v h264_vaapi -low_power 1 -qp $QUALITY -profile:v main -level 40 \
        -c:a aac -b:a 128k -ac 2 \
        -max_muxing_queue_size 1024 -movflags +faststart -y "$output"
}

encode_vaapi() {
    local input="$1" output="$2"
    ffmpeg -nostdin -hide_banner -loglevel warning -stats \
        -xerror -err_detect explode \
        -i "$input" \
        -vaapi_device "$VAAPI_DEVICE" \
        -map 0:v:0 -map 0:a:0? \
        -vf "scale=-2:720:flags=lanczos,format=nv12,hwupload" \
        -c:v h264_vaapi -low_power 1 -qp $QUALITY -profile:v main -level 40 \
        -c:a aac -b:a 128k -ac 2 \
        -max_muxing_queue_size 1024 -movflags +faststart -y "$output"
}

encode_cpu() {
    local input="$1" output="$2"
    ffmpeg -nostdin -hide_banner -loglevel warning -stats \
        -xerror -err_detect explode \
        -i "$input" \
        -map 0:v:0 -map 0:a:0? \
        -vf "scale=-2:720:flags=lanczos" \
        -c:v libx264 -preset medium -crf $QUALITY -profile:v main -level 4.0 -pix_fmt yuv420p \
        -x264-params "keyint=250:min-keyint=25:ref=3:bframes=3:b-adapt=1" \
        -c:a aac -b:a 128k -ac 2 \
        -max_muxing_queue_size 1024 -movflags +faststart -y "$output"
}

# -------- main with single-instance lock ----------------------------------
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    log "Another conversion run is in progress. Exiting."
    exit 0
fi

CURRENT_OUTPUT=""
total_processed=0
total_skipped=0
total_errors=0
total_corrupted=0
RUN_START=$(date +%s)

cleanup() {
    log "⚠ Interrupted, cleaning up"
    [[ -n "$CURRENT_OUTPUT" && -f "$CURRENT_OUTPUT" ]] && rm -f "$CURRENT_OUTPUT"
    mqtt_pub status "Aborted"
    mqtt_pub problem "ON"
    pushover "Video Converter aborted" "Processed=$total_processed Errors=$total_errors" 1
    exit 130
}
trap cleanup SIGINT SIGTERM

mkdir -p "$(dirname "$LOG_FILE")"
echo "" >> "$LOG_FILE"
log "========== Conversion started =========="

mqtt_register_ha
sleep 1
mqtt_pub status "Running"
mqtt_pub problem "OFF"
mqtt_pub current "(checking)"
mqtt_pub progress "0/0"

if check_vaapi; then
    USE_VAAPI=true; ENCODER="Hardware (VA-API)"
    log "✓ VA-API hardware encoding available"
else
    USE_VAAPI=false; ENCODER="CPU (libx264)"
    log "⚠ VA-API not available, using CPU"
fi
mqtt_pub encoder "$ENCODER"

for dir_index in "${!SOURCE_DIRS[@]}"; do
    SOURCE_DIR="${SOURCE_DIRS[$dir_index]}"
    OUTPUT_DIR="${OUTPUT_DIRS[$dir_index]}"
    [[ -d "$SOURCE_DIR" ]] || { log "Skip missing: $SOURCE_DIR"; continue; }
    mkdir -p "$OUTPUT_DIR"

    counter=1
    if ls "$OUTPUT_DIR"/*.mp4 >/dev/null 2>&1; then
        highest=$(ls "$OUTPUT_DIR"/*.mp4 2>/dev/null | sed 's/.*\///' | grep -oE '^[0-9]+' | sort -n | tail -1)
        [[ -n "$highest" ]] && counter=$((10#$highest + 1))
    fi

    log ""
    log "=== Pair $((dir_index+1))/${#SOURCE_DIRS[@]}: $SOURCE_DIR -> $OUTPUT_DIR (start #$counter) ==="

    total_files=$(find "$SOURCE_DIR" -type f \( \
        -iname "*.mp4" -o -iname "*.mkv" -o -iname "*.avi" -o -iname "*.mov" -o \
        -iname "*.wmv" -o -iname "*.flv" -o -iname "*.webm" -o -iname "*.m4v" -o -iname "*.ts" \
    \) 2>/dev/null | wc -l)
    log "Found $total_files video files"

    processed=0; skipped=0; errors=0; corrupted=0; idx=0

    while read -r input_file; do
        ((idx++)) || true
        filename=$(basename "$input_file")
        name_no_ext="${filename%.*}"
        rel="${input_file#$SOURCE_DIR/}"
        output_filename=$(printf "%03d-%s.mp4" "$counter" "$name_no_ext")
        output_path="$OUTPUT_DIR/$output_filename"

        existing=$(find "$OUTPUT_DIR" -maxdepth 1 -type f -name "*-${name_no_ext}.mp4" 2>/dev/null | head -1)
        if [[ -n "$existing" ]]; then
            $VERBOSE && log "SKIP: $name_no_ext -> $(basename "$existing")"
            ((skipped++)) || true
            continue
        fi

        log ""
        log "[$idx/$total_files] $rel -> $output_filename"
        mqtt_pub current "$filename"
        mqtt_pub progress "$idx/$total_files"
        mqtt_pub status "Converting (dir $((dir_index+1))/${#SOURCE_DIRS[@]})"

        if $DRY_RUN; then
            log "    [DRY RUN] would convert"
            ((counter++)) || true
            continue
        fi

        if ! validate_input "$input_file"; then
            log "    ✗ Bad input: $filename"
            ((errors++)) || true; ((counter++)) || true
            continue
        fi

        in_dur=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$input_file" 2>/dev/null | cut -d'.' -f1)
        CURRENT_OUTPUT="$output_path"
        t0=$(date +%s)

        ok=false; method=""
        if $USE_VAAPI; then
            if encode_vaapi_full "$input_file" "$output_path"; then
                ok=true; method="HW-decode+HW-encode"
            else
                log "    ⚠ HW decode failed, retrying with SW decode + HW encode"
                rm -f "$output_path"
                if encode_vaapi "$input_file" "$output_path"; then
                    ok=true; method="SW-decode+HW-encode"
                else
                    log "    ⚠ VA-API encode failed, falling back to CPU"
                    rm -f "$output_path"
                    encode_cpu "$input_file" "$output_path" && { ok=true; method="CPU"; }
                fi
            fi
        else
            encode_cpu "$input_file" "$output_path" && { ok=true; method="CPU"; }
        fi

        if $ok && validate_output "$output_path" "$in_dur"; then
            t1=$(date +%s); dur=$((t1-t0))
            sz=$(du -h "$output_path" | cut -f1)
            log "    ✓ Done ${dur}s ${sz} ($method)"
            log "    Deleting source: $rel"
            rm -f "$input_file"
            ((processed++)) || true
        else
            log "    ✗ Conversion/validation failed (corrupt source): $filename"
            rm -f "$output_path"
            log "    Deleting corrupt source: $rel"
            rm -f "$input_file"
            ((corrupted++)) || true
        fi

        CURRENT_OUTPUT=""
        ((counter++)) || true
    done < <(find "$SOURCE_DIR" -type f \( \
        -iname "*.mp4" -o -iname "*.mkv" -o -iname "*.avi" -o -iname "*.mov" -o \
        -iname "*.wmv" -o -iname "*.flv" -o -iname "*.webm" -o -iname "*.m4v" -o -iname "*.ts" \
    \) 2>/dev/null | sort)

    # Prune empty subdirs (deepest first)
    while read -r subdir; do
        vc=$(find "$subdir" -type f \( \
            -iname "*.mp4" -o -iname "*.mkv" -o -iname "*.avi" -o -iname "*.mov" -o \
            -iname "*.wmv" -o -iname "*.flv" -o -iname "*.webm" -o -iname "*.m4v" -o -iname "*.ts" \
        \) 2>/dev/null | wc -l)
        if [[ "$vc" -eq 0 ]]; then
            $DRY_RUN && log "  [DRY] would rm $subdir" || { log "  rm $subdir"; rm -rf "$subdir"; }
        fi
    done < <(find "$SOURCE_DIR" -mindepth 1 -type d 2>/dev/null | sort -r)

    log "Pair $((dir_index+1)) done: processed=$processed skipped=$skipped corrupted=$corrupted errors=$errors"
    ((total_processed += processed)) || true
    ((total_skipped += skipped)) || true
    ((total_corrupted += corrupted)) || true
    ((total_errors += errors)) || true
done

RUN_END=$(date +%s)
RUN_DUR=$((RUN_END - RUN_START))
TS_ISO=$(date -u -d "@$RUN_END" +%Y-%m-%dT%H:%M:%S+00:00)

log ""
log "========== Complete: processed=$total_processed skipped=$total_skipped corrupted=$total_corrupted errors=$total_errors duration=${RUN_DUR}s =========="

mqtt_pub last_processed "$total_processed"
mqtt_pub last_skipped   "$total_skipped"
mqtt_pub last_corrupted "$total_corrupted"
mqtt_pub last_errors    "$total_errors"
mqtt_pub last_duration  "$RUN_DUR"
mqtt_pub last_run       "$TS_ISO"
mqtt_pub current        "(idle)"
mqtt_pub progress       "$total_processed/$total_processed"

# Inform about deleted corrupt sources (priority 0 — informational)
if [[ $total_corrupted -gt 0 ]]; then
    pushover "Video Converter: $total_corrupted corrupt file(s) deleted" \
        "processed=$total_processed skipped=$total_skipped corrupted=$total_corrupted dur=${RUN_DUR}s" 0
fi

if [[ $total_errors -gt 0 ]]; then
    mqtt_pub status "Idle (errors)"
    mqtt_pub problem "ON"
    pushover "Video Converter: $total_errors errors" \
        "processed=$total_processed skipped=$total_skipped corrupted=$total_corrupted errors=$total_errors dur=${RUN_DUR}s" 1
    exit 1
else
    mqtt_pub status "Idle"
    mqtt_pub problem "OFF"
    exit 0
fi
