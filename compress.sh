#!/data/data/com.termux/files/usr/bin/bash
#
# compress.sh - interactive video compressor / GIF converter for Termux.
#
# Requires : bash >= 4.0, ffmpeg + ffprobe (libx264 and libopus; libsvtav1 for AV1),
#            awk, find, sort, stat, mktemp, realpath, df, sed, tail (standard in Termux).
# Optional : nice (CPU priority), timeout, and termux-api + the Termux:API app
#            (battery-temperature guard).
# Notes    : "MB" in this script means MiB (1024 * 1024 bytes).
#            Nothing is installed automatically.

############################## CONFIGURATION ##############################
OUTDIR="${COMPRESS_OUTDIR:-/sdcard/Movies/ffmpeg/Compressed}"
COMP_METHOD="H.264"          # H.264 | AV1
RESOLUTION_CAP="Disabled"    # Disabled | WIDTHxHEIGHT
GIF_DURATION_WARN_SEC=30     # Warn if a clip is longer than this for GIF output

AUDIO_KBPS=64                # Opus audio bitrate (also reserved in size targeting)
MIN_VIDEO_KBPS=50            # Refuse size targets that need less video bitrate than this
MAX_SIZE_RETRIES=1           # Extra re-encodes allowed when a size target is overshot
OVERWRITE_POLICY="rename"    # rename | skip | overwrite   (existing output files)

# --- CPU / thermal protection (also editable from the T menu) ---
THREADS=2                    # Encoder, decoder and filter threads (clamped to CPU cores)
NICE_LEVEL=10                # 0 = normal priority, 19 = lowest
COOLDOWN_SEC=0               # Idle pause between files in batch mode
X264_PRESET="medium"         # libx264 preset (faster presets = less CPU time, bigger files)
SVT_PRESET=""                # libsvtav1 preset; empty = encoder default
THERMAL_GUARD="off"          # on | off  (needs termux-battery-status from termux-api)
THERMAL_MAX_C=40             # Pause encoding when battery temperature is above this
THERMAL_RESUME_C=37          # ...and resume once it is at or below this
THERMAL_POLL_SEC=15          # How often the temperature is checked

VIDEO_EXTS=(mp4 mkv webm avi mov flv wmv m4v mpg mpeg)

############################## RUNTIME STATE ##############################
INPUT=""
RUN_TMP=""          # private temp dir (progress file, ffmpeg stderr log, GIF palette)
FFMPEG_PID=""       # PID of the ffmpeg process currently running, if any
PARTIAL_FILE=""     # in-progress output (removed on failure or cancel)
CPU_CORES=4
VIDEO_FILES=()
declare -A ENCODER_OK=()

############################## BASIC HELPERS ##############################
exit_on_eof() {
    echo ""
    echo "   Input closed (EOF). Exiting."
    exit 0
}

pause_for_enter() {
    read -r -p "$1" _ || exit_on_eof
}

is_positive_number() {
    [[ "$1" =~ ^[0-9]+(\.[0-9]+)?$ ]] && awk -v v="$1" 'BEGIN { exit !(v + 0 > 0) }'
}

is_positive_int() {
    [[ "$1" =~ ^[0-9]{1,9}$ ]] && [ "$1" -gt 0 ]
}

detect_cores() {
    local n
    n=$(nproc 2>/dev/null)
    if ! [[ "$n" =~ ^[0-9]+$ ]] || [ "$n" -lt 1 ]; then
        n=$(getconf _NPROCESSORS_ONLN 2>/dev/null)
    fi
    if ! [[ "$n" =~ ^[0-9]+$ ]] || [ "$n" -lt 1 ]; then
        n=4
    fi
    printf '%s\n' "$n"
}

clamp_threads() {
    [ "$THREADS" -gt "$CPU_CORES" ] && THREADS="$CPU_CORES"
    [ "$THREADS" -lt 1 ] && THREADS=1
    return 0
}

check_dependencies() {
    local missing=() cmd
    for cmd in ffmpeg ffprobe awk find sort stat mktemp realpath df sed tail mv rm mkdir; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done
    if [ "${#missing[@]}" -gt 0 ]; then
        echo "❌ Missing required command(s): ${missing[*]}" >&2
        echo "   ffmpeg/ffprobe:  pkg install ffmpeg" >&2
        echo "   Others:          pkg search <command>  (then pkg install the package)" >&2
        return 1
    fi
    return 0
}

init_runtime() {
    local base="${TMPDIR:-}"
    [ -n "$base" ] || base="${PREFIX:+$PREFIX/tmp}"
    [ -d "$base" ] || base="/tmp"
    RUN_TMP=$(mktemp -d "${base}/compress.XXXXXX") || {
        echo "❌ Cannot create a temporary directory under $base" >&2
        return 1
    }
}

have_encoder() {
    local enc="$1"
    if [ -z "${ENCODER_OK[$enc]:-}" ]; then
        if ffmpeg -hide_banner -encoders 2>/dev/null | awk -v e="$enc" '$2 == e { f = 1 } END { exit !f }'; then
            ENCODER_OK[$enc]=yes
        else
            ENCODER_OK[$enc]=no
        fi
    fi
    [ "${ENCODER_OK[$enc]}" = "yes" ]
}

require_encoder() {
    if ! have_encoder "$1"; then
        echo "❌ This ffmpeg build has no '$1' encoder." >&2
        echo "   Check with:  ffmpeg -encoders | grep $1" >&2
        return 1
    fi
}

############################## CLEANUP / SIGNALS ##############################
stop_ffmpeg() {
    local pid="$FFMPEG_PID" i
    [ -n "$pid" ] || return 0
    if kill -0 "$pid" 2>/dev/null; then
        kill -CONT "$pid" 2>/dev/null     # in case it is paused by the thermal guard
        kill -TERM "$pid" 2>/dev/null
        for i in 1 2 3 4 5 6 7 8 9 10; do
            kill -0 "$pid" 2>/dev/null || break
            sleep 0.5
        done
        kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null
        wait "$pid" 2>/dev/null
    fi
    FFMPEG_PID=""
}

cleanup() {
    stop_ffmpeg
    if [ -n "$PARTIAL_FILE" ]; then
        rm -f -- "$PARTIAL_FILE" "${PARTIAL_FILE}.retry"
        PARTIAL_FILE=""
    fi
    if [ -n "$RUN_TMP" ] && [ -d "$RUN_TMP" ]; then
        rm -rf -- "$RUN_TMP"
        RUN_TMP=""
    fi
}

on_interrupt() {
    printf '\n🛑 CTRL+C / termination signal received. Stopping...\n' >&2
    cleanup
    printf '‼️ Process terminated by user. Unfinished output was removed.\n' >&2
    exit 130
}

trap on_interrupt INT TERM HUP
trap cleanup EXIT

############################## THERMAL GUARD ##############################
# Battery temperature (deg C) from Termux:API, empty if unavailable.
# This is a proxy for how hot the phone is, not the CPU die temperature.
battery_temp_c() {
    command -v termux-battery-status >/dev/null 2>&1 || return 1
    local out
    if command -v timeout >/dev/null 2>&1; then
        out=$(timeout 5 termux-battery-status 2>/dev/null)
    else
        out=$(termux-battery-status 2>/dev/null)
    fi
    printf '%s\n' "$out" |
        sed -n 's/.*"temperature"[[:space:]]*:[[:space:]]*\([0-9][0-9.]*\).*/\1/p' |
        head -n 1
}

temp_above_max() {
    awk -v t="$1" -v m="$THERMAL_MAX_C" 'BEGIN { exit !(t + 0 > m + 0) }'
}

temp_at_or_below_resume() {
    awk -v t="$1" -v r="$THERMAL_RESUME_C" 'BEGIN { exit !(t + 0 <= r + 0) }'
}

thermal_unreadable() {
    printf '\r\033[2K' >&2
    echo "⚠️  Temperature guard: battery temperature cannot be read" >&2
    echo "   (needs 'pkg install termux-api' and the Termux:API app). Guard turned off." >&2
    THERMAL_GUARD="off"
}

# Pause until the battery cools down. If a PID is given, that process is
# frozen with SIGSTOP meanwhile (no CPU use) and resumed with SIGCONT.
thermal_cooldown_wait() {
    local pid="$1" temp
    [ -n "$pid" ] && kill -STOP "$pid" 2>/dev/null
    while true; do
        temp=$(battery_temp_c)
        if [ -z "$temp" ]; then
            thermal_unreadable
            break
        fi
        if temp_at_or_below_resume "$temp"; then
            break
        fi
        printf '\r\033[2K   ⏸  Cooling down: battery %s°C (resumes at <= %s°C, Ctrl+C cancels)' \
            "$temp" "$THERMAL_RESUME_C"
        sleep "$THERMAL_POLL_SEC"
    done
    printf '\r\033[2K'
    [ -n "$pid" ] && kill -CONT "$pid" 2>/dev/null
    return 0
}

# Called before every ffmpeg run: do not start while the phone is hot.
thermal_gate() {
    [ "$THERMAL_GUARD" = "on" ] || return 0
    local t
    t=$(battery_temp_c)
    if [ -z "$t" ]; then
        thermal_unreadable
        return 0
    fi
    temp_above_max "$t" && thermal_cooldown_wait ""
    return 0
}

# Called periodically while ffmpeg runs.
thermal_check_running() {
    local pid="$1" t
    t=$(battery_temp_c)
    if [ -z "$t" ]; then
        thermal_unreadable
        return 0
    fi
    temp_above_max "$t" && thermal_cooldown_wait "$pid"
    return 0
}

cooldown_between_files() {
    [ "$COOLDOWN_SEC" -gt 0 ] || return 0
    local i
    for ((i = COOLDOWN_SEC; i > 0; i--)); do
        printf '\r\033[2K   ❄️  Cooling down before next file: %ds (Ctrl+C cancels)' "$i"
        sleep 1
    done
    printf '\r\033[2K'
}

############################## MENUS ##############################
show_menu() {
    clear
    local input_type="FILE"
    if [ -d "$INPUT" ]; then
        input_type="FOLDER"
    fi

    echo "============================================================"
    echo "             VIDEO COMPRESSION TOOL                       "
    echo "============================================================"
    echo "  INPUT ($input_type): $INPUT"
    echo "  RESOLUTION CAP: $RESOLUTION_CAP"
    echo "  COMPRESSION METHOD: $COMP_METHOD"
    echo "  CPU: $THREADS of $CPU_CORES threads | nice $NICE_LEVEL | temp guard: $THERMAL_GUARD"
    echo "------------------------------------------------------------"
    echo "  1. Compress to Target Size                              "
    echo "  2. Compress to Target Bitrate                           "
    echo "  3. Set Compression Method (Current: $COMP_METHOD)        "
    echo "  4. Set Resolution Cap (Current: $RESOLUTION_CAP)         "
    echo "  5. Convert Video to GIF                                 "
    echo "  6. Exit                                                 "
    echo "  T. CPU / Thermal Settings                               "
    echo "============================================================"
    echo -n "👉 SELECT OPTION [1-6, T]: "
}

show_compression_method_menu() {
    clear
    echo "============================================================"
    echo "  SET COMPRESSION METHOD (Current: $COMP_METHOD)"
    echo "============================================================"
    echo "  1. H.264 (Faster, MP4 output)                           "
    echo "  2. AV1 (Slower, Higher Quality/Compression, WEBM output) "
    echo "  3. Back to main menu                                    "
    echo "============================================================"
    echo -n "👉 SELECT OPTION [1-3]: "
}

show_resolution_menu() {
    clear
    echo "============================================================"
    echo "  SET RESOLUTION CAP (Current: $RESOLUTION_CAP)"
    echo "============================================================"
    echo "  1. 1080p (1920x1080) - Standard HD                      "
    echo "  2. 720p (1280x720) - HD Ready                           "
    echo "  3. 480p (854x480) - SD                                  "
    echo "  4. Custom (e.g., 1920x1080 or 1080x1920)                "
    echo "  5. Disable Resolution Cap                               "
    echo "  6. Back to main menu                                    "
    echo "============================================================"
    echo -n "👉 SELECT OPTION [1-6]: "
}

show_thermal_menu() {
    clear
    echo "============================================================"
    echo "  CPU / THERMAL SETTINGS"
    echo "============================================================"
    echo "  1. Encoder threads        (now: $THREADS of $CPU_CORES cores)"
    echo "  2. CPU priority (nice)    (now: $NICE_LEVEL; 0 = normal)"
    echo "  3. Cooldown between files (now: ${COOLDOWN_SEC}s)"
    echo "  4. Battery-temp guard     (now: $THERMAL_GUARD)"
    echo "  5. Temp limits            (pause > ${THERMAL_MAX_C}°C, resume <= ${THERMAL_RESUME_C}°C)"
    echo "  6. Back to main menu"
    echo "------------------------------------------------------------"
    echo "  Fewer threads = cooler and slower. Applies to the decoder,"
    echo "  filters and encoder (H.264, AV1 and GIF)."
    echo "============================================================"
    echo -n "👉 SELECT OPTION [1-6]: "
}

# ask_int "prompt" min max  -> sets ASK_RESULT, returns 1 on invalid input
ask_int() {
    local ans
    printf '%s' "$1"
    read -r ans || exit_on_eof
    if [[ "$ans" =~ ^[0-9]{1,6}$ ]] && [ "$ans" -ge "$2" ] && [ "$ans" -le "$3" ]; then
        ASK_RESULT="$ans"
        return 0
    fi
    echo "❌ INVALID VALUE: enter a whole number from $2 to $3"
    sleep 2
    return 1
}

thermal_settings_menu() {
    local choice t
    while true; do
        show_thermal_menu
        read -r choice || exit_on_eof
        case "$choice" in
            1)
                echo ""
                echo "  Lower = cooler/slower. SVT-AV1 may still use a few extra"
                echo "  helper threads beyond this limit."
                if ask_int "👉 THREADS [1-${CPU_CORES}]: " 1 "$CPU_CORES"; then
                    THREADS="$ASK_RESULT"
                    echo "✅ Threads set to $THREADS"
                    sleep 1
                fi
                ;;
            2)
                echo ""
                if ! command -v nice >/dev/null 2>&1; then
                    echo "⚠️  'nice' is not installed; this setting would have no effect."
                    sleep 2
                elif ask_int "👉 NICE LEVEL [0-19]: " 0 19; then
                    NICE_LEVEL="$ASK_RESULT"
                    echo "✅ Nice level set to $NICE_LEVEL"
                    sleep 1
                fi
                ;;
            3)
                echo ""
                if ask_int "👉 COOLDOWN SECONDS BETWEEN FILES [0-3600]: " 0 3600; then
                    COOLDOWN_SEC="$ASK_RESULT"
                    echo "✅ Cooldown set to ${COOLDOWN_SEC}s"
                    sleep 1
                fi
                ;;
            4)
                echo ""
                if [ "$THERMAL_GUARD" = "on" ]; then
                    THERMAL_GUARD="off"
                    echo "✅ Temperature guard turned off"
                    sleep 1
                else
                    t=$(battery_temp_c)
                    if [ -z "$t" ]; then
                        echo "❌ Cannot read battery temperature."
                        echo "   Install the termux-api package AND the Termux:API app, then retry."
                        sleep 3
                    else
                        THERMAL_GUARD="on"
                        echo "✅ Guard on (battery now ${t}°C). Encoding pauses above ${THERMAL_MAX_C}°C."
                        echo "   Note: battery temperature is a proxy; charging also warms it."
                        sleep 3
                    fi
                fi
                ;;
            5)
                echo ""
                if ask_int "👉 PAUSE ABOVE (°C) [30-60]: " 30 60; then
                    local new_max="$ASK_RESULT"
                    if ask_int "👉 RESUME AT OR BELOW (°C) [25-$((new_max - 1))]: " 25 "$((new_max - 1))"; then
                        THERMAL_MAX_C="$new_max"
                        THERMAL_RESUME_C="$ASK_RESULT"
                        echo "✅ Pause > ${THERMAL_MAX_C}°C, resume <= ${THERMAL_RESUME_C}°C"
                        sleep 1
                    fi
                fi
                ;;
            6) break ;;
            *)
                echo "❌ INVALID OPTION"
                sleep 1
                ;;
        esac
    done
}

############################## MEDIA HELPERS ##############################
# Prints the container duration in seconds; fails if it is missing or not > 0.
get_duration() {
    local d
    d=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 -i "$1" 2>/dev/null | head -n 1)
    [[ "$d" =~ ^[0-9]+(\.[0-9]+)?$ ]] || return 1
    awk -v d="$d" 'BEGIN { exit !(d + 0 > 0) }' || return 1
    printf '%s\n' "$d"
}

# Scale filter for the current resolution cap. The expressions are evaluated by
# ffmpeg on the real (already auto-rotated) frame, so phone videos with rotation
# metadata are handled correctly. When the frame already fits and has even
# dimensions the filter is a pass-through.
build_scale_filter() {
    local max_w=1920 max_h=1080
    if [ "$RESOLUTION_CAP" = "Disabled" ]; then
        # libx264 + yuv420p need even dimensions.
        printf '%s' "scale=trunc(iw/2)*2:trunc(ih/2)*2"
        return 0
    fi
    if [[ "$RESOLUTION_CAP" =~ ^([0-9]+)x([0-9]+)$ ]]; then
        max_w="${BASH_REMATCH[1]}"
        max_h="${BASH_REMATCH[2]}"
    fi
    printf "scale=w='min(%s,iw)':h='min(%s,ih)':force_original_aspect_ratio=decrease:force_divisible_by=2" \
        "$max_w" "$max_h"
}

# Full -vf chain for an input (scale, plus 30 fps for GIF inputs only).
build_video_filter() {
    local vf
    vf=$(build_scale_filter)
    if [[ "${1,,}" == *.gif ]]; then
        vf="${vf:+$vf,}fps=30"
    fi
    printf '%s' "$vf"
}

# Sets ENCODER, OUT_EXT, OUT_FMT for a codec name.
set_codec_props() {
    case "$1" in
        H.264) ENCODER="libx264";   OUT_EXT="mp4";  OUT_FMT="mp4" ;;
        AV1)   ENCODER="libsvtav1"; OUT_EXT="webm"; OUT_FMT="webm" ;;
        *)
            echo "❌ Unknown compression method: $1" >&2
            return 1
            ;;
    esac
}

# Sets VIDEO_ARGS (array) for a codec and video bitrate in kbps.
build_video_args() {
    local codec="$1" kbps="$2"
    case "$codec" in
        H.264)
            VIDEO_ARGS=(-c:v libx264 -preset "$X264_PRESET" -threads "$THREADS" -b:v "${kbps}k" -pix_fmt yuv420p)
            ;;
        AV1)
            VIDEO_ARGS=(-c:v libsvtav1 -svtav1-params "lp=${THREADS}" -b:v "${kbps}k")
            [ -n "$SVT_PRESET" ] && VIDEO_ARGS+=(-preset "$SVT_PRESET")
            ;;
    esac
}

# Video kbps that fits target_bytes after reserving audio and a 5% muxing buffer.
# Fails if the result would be below MIN_VIDEO_KBPS.
calc_video_kbps() {
    awk -v dur="$1" -v tb="$2" -v ab="$AUDIO_KBPS" -v min="$MIN_VIDEO_KBPS" '
        BEGIN {
            v = (tb * 8 - ab * 1000 * dur) / dur / 1000 * 0.95
            if (v < min) exit 1
            printf "%.2f\n", v
        }'
}

# percent done from the ffmpeg -progress file ("out_time_ms" is in microseconds)
progress_pct() {
    tail -n 40 -- "$1" 2>/dev/null | awk -F= -v dur="$2" '
        $1 == "out_time_us" || $1 == "out_time_ms" { if ($2 ~ /^[0-9]+$/) v = $2 }
        END {
            p = 0
            if (v != "" && dur > 0) p = int(v / 1000000 * 100 / dur)
            if (p > 100) p = 100
            if (p < 0) p = 0
            print p
        }'
}

# run_ffmpeg LABEL DURATION ffmpeg-args...
#   DURATION empty -> show elapsed time instead of a percentage.
# Runs ffmpeg niced in the background, shows progress, optionally freezes it
# when hot, captures stderr in a log and returns ffmpeg's real exit status.
run_ffmpeg() {
    local label="$1" duration="$2"
    shift 2
    local prog="$RUN_TMP/progress.txt" errlog="$RUN_TMP/ffmpeg.err"
    local -a cmd=()
    local rc pct start last_check

    : >"$prog"
    : >"$errlog"
    thermal_gate

    if [ "$NICE_LEVEL" -gt 0 ] && command -v nice >/dev/null 2>&1; then
        cmd=(nice -n "$NICE_LEVEL")
    fi
    cmd+=(ffmpeg -hide_banner -nostdin -loglevel warning -progress "$prog" -nostats "$@")

    start=$SECONDS
    last_check=$SECONDS
    "${cmd[@]}" 2>"$errlog" &
    FFMPEG_PID=$!

    while kill -0 "$FFMPEG_PID" 2>/dev/null; do
        if [ -n "$duration" ]; then
            pct=$(progress_pct "$prog" "$duration")
            printf '\r   %s: %3d%%' "$label" "$pct"
        else
            printf '\r   %s: working... %ds' "$label" "$((SECONDS - start))"
        fi
        if [ "$THERMAL_GUARD" = "on" ] && [ $((SECONDS - last_check)) -ge "$THERMAL_POLL_SEC" ]; then
            last_check=$SECONDS
            thermal_check_running "$FFMPEG_PID"
        fi
        sleep 1
    done
    wait "$FFMPEG_PID"
    rc=$?
    FFMPEG_PID=""
    printf '\r\033[2K'

    if [ "$rc" -ne 0 ]; then
        echo "❌ ffmpeg failed (exit status $rc) during: $label" >&2
        if [ -s "$errlog" ]; then
            echo "   Last ffmpeg messages:" >&2
            tail -n 8 "$errlog" | sed 's/^/   | /' >&2
        fi
    fi
    return "$rc"
}

# Basic validity check of a finished output. strict=no only checks non-empty.
validate_output() {
    local file="$1" strict="${2:-yes}"
    if [ ! -s "$file" ]; then
        echo "❌ Output is missing or empty: $file" >&2
        return 1
    fi
    if [ "$strict" = "yes" ] && ! get_duration "$file" >/dev/null; then
        echo "❌ Output failed validation (ffprobe cannot read its duration): $file" >&2
        return 1
    fi
    return 0
}

############################## FILESYSTEM HELPERS ##############################
ensure_output_dir() {
    local d="$1"
    if ! mkdir -p -- "$d" 2>/dev/null || [ ! -w "$d" ]; then
        echo "❌ Cannot create or write to output folder: $d" >&2
        case "$d" in
            /sdcard* | /storage/*)
                echo "   Run 'termux-setup-storage' and grant storage permission," >&2
                echo "   or set a different OUTDIR in the script." >&2
                ;;
        esac
        return 1
    fi
}

# Prints the output path to use, honoring OVERWRITE_POLICY. Returns 1 for "skip".
resolve_output() {
    local path="$1" stem ext n=1 candidate
    if [ ! -e "$path" ]; then
        printf '%s\n' "$path"
        return 0
    fi
    case "$OVERWRITE_POLICY" in
        overwrite)
            printf '%s\n' "$path"
            return 0
            ;;
        skip)
            return 1
            ;;
    esac
    stem="${path%.*}"
    ext="${path##*.}"
    candidate="${stem}_${n}.${ext}"
    while [ -e "$candidate" ]; do
        n=$((n + 1))
        candidate="${stem}_${n}.${ext}"
    done
    printf '%s\n' "$candidate"
}

# Best-effort free-space check. If df cannot report, the check is skipped.
check_free_space() {
    local dir="$1" need_bytes="$2" avail_kb need_kb
    avail_kb=$(df -Pk "$dir" 2>/dev/null | awk 'NR == 2 { print $4 }')
    [[ "$avail_kb" =~ ^[0-9]+$ ]] || return 0
    need_kb=$(awk -v b="$need_bytes" 'BEGIN { printf "%d", b / 1024 * 1.1 + 1 }')
    if [ "$avail_kb" -lt "$need_kb" ]; then
        echo "❌ Not enough free space in $dir (need about $((need_kb / 1024)) MB, have $((avail_kb / 1024)) MB)" >&2
        return 1
    fi
}

bytes_to_mb() {
    awk -v b="$1" 'BEGIN { printf "%.2f", b / 1024 / 1024 }'
}

############################## VIDEO COMPRESSION ##############################
# One encode pass: encode_video_once CODEC INPUT KBPS OUTFILE DURATION LABEL
encode_video_once() {
    local codec="$1" input="$2" kbps="$3" outfile="$4" duration="$5" label="$6"
    local vf
    local -a args
    vf=$(build_video_filter "$input")
    build_video_args "$codec" "$kbps"
    args=(-y -threads "$THREADS" -filter_threads "$THREADS" -i "$input")
    [ -n "$vf" ] && args+=(-vf "$vf")
    args+=("${VIDEO_ARGS[@]}" -c:a libopus -b:a "${AUDIO_KBPS}k" -shortest -f "$OUT_FMT" "$outfile")
    run_ffmpeg "$label" "$duration" "${args[@]}"
}

# compress_core MODE CODEC INPUT VALUE OUTPUT_DIR
#   MODE size    : VALUE is the target size in MB (single pass + size correction)
#   MODE bitrate : VALUE is the video bitrate in kbps (single pass)
# Returns 0 = done, 1 = failed, 2 = skipped.
compress_core() {
    local mode="$1" codec="$2" input="$3" value="$4" output_dir="$5"
    local base name duration kbps final partial retry size target_bytes est_bytes
    local attempt=0 next_kbps desc wanted

    set_codec_props "$codec" || return 1
    require_encoder "$ENCODER" || return 1
    require_encoder libopus || return 1

    if ! duration=$(get_duration "$input"); then
        echo "❌ Cannot read a valid duration from: $input" >&2
        return 1
    fi
    ensure_output_dir "$output_dir" || return 1

    base="${input##*/}"
    name="${base%.*}"
    if [ "$mode" = "size" ]; then
        target_bytes=$(awk -v mb="$value" 'BEGIN { printf "%d", mb * 1024 * 1024 }')
        if ! kbps=$(calc_video_kbps "$duration" "$target_bytes"); then
            echo "❌ ${value} MB is too small for this video's length (needs under ${MIN_VIDEO_KBPS} kbps video)." >&2
            return 1
        fi
        est_bytes="$target_bytes"
        wanted="${output_dir}/${name}_compressed_${value}mb.${OUT_EXT}"
    else
        kbps="$value"
        est_bytes=$(awk -v k="$value" -v a="$AUDIO_KBPS" -v d="$duration" 'BEGIN { printf "%d", (k + a) * 1000 * d / 8 }')
        wanted="${output_dir}/${name}_${value}kbps.${OUT_EXT}"
    fi
    final=$(resolve_output "$wanted")
    if [ -z "$final" ]; then
        echo "⏭️  Skipping (output already exists and OVERWRITE_POLICY=skip): $base"
        return 2
    fi
    check_free_space "$output_dir" "$est_bytes" || return 1

    if [ "$mode" = "size" ]; then
        desc="to a ${value} MB target"
    else
        desc="at ${value}kbps"
    fi
    echo "📼 Starting $codec compression $desc (single pass)"
    if [ "$RESOLUTION_CAP" != "Disabled" ]; then
        echo "   Resolution cap: $RESOLUTION_CAP"
    fi
    echo "   Video bitrate: ${kbps}kbps (+ ${AUDIO_KBPS}kbps audio) | threads: $THREADS | nice: $NICE_LEVEL"
    if [ "$final" != "$wanted" ]; then
        echo "   Output name already existed; saving as: ${final##*/}"
    fi
    echo ""
    echo "🔁 Encoding..."

    partial="${final}.part"
    PARTIAL_FILE="$partial"
    if ! encode_video_once "$codec" "$input" "$kbps" "$partial" "$duration" "Progress" ||
        ! validate_output "$partial"; then
        rm -f -- "$partial"
        PARTIAL_FILE=""
        return 1
    fi
    echo "   ✅ Encoding complete."

    if [ "$mode" = "size" ]; then
        size=$(stat -c %s "$partial")
        while [ "$size" -gt "$target_bytes" ] && [ "$attempt" -lt "$MAX_SIZE_RETRIES" ]; do
            attempt=$((attempt + 1))
            echo ""
            echo "‼️ Output size too large ($(bytes_to_mb "$size") MB vs target ${value} MB)"
            if ! next_kbps=$(awk -v k="$kbps" -v t="$target_bytes" -v s="$size" -v min="$MIN_VIDEO_KBPS" \
                'BEGIN { v = k * t / s * 0.95; if (v < min) exit 1; printf "%.2f\n", v }'); then
                echo "⚠️  Cannot lower the bitrate further without going below ${MIN_VIDEO_KBPS} kbps." >&2
                break
            fi
            echo "   Re-encoding with corrected bitrate (${next_kbps} kbps), attempt ${attempt}/${MAX_SIZE_RETRIES}"
            echo ""
            retry="${partial}.retry"
            if encode_video_once "$codec" "$input" "$next_kbps" "$retry" "$duration" "Re-encoding" &&
                validate_output "$retry"; then
                mv -f -- "$retry" "$partial"
                kbps="$next_kbps"
                size=$(stat -c %s "$partial")
                echo "   ✅ Size correction complete."
            else
                rm -f -- "$retry"
                echo "⚠️  Correction pass failed; keeping the first-pass output." >&2
                break
            fi
        done
    fi

    if ! mv -f -- "$partial" "$final"; then
        echo "❌ Could not move finished file to: $final" >&2
        echo "   The encoded data remains at: $partial" >&2
        PARTIAL_FILE=""
        return 1
    fi
    PARTIAL_FILE=""

    size=$(stat -c %s "$final")
    echo ""
    echo "✅ Compressed file saved to: $final ($(bytes_to_mb "$size") MB)"
    if [ "$mode" = "size" ] && [ "$size" -gt "$target_bytes" ]; then
        echo "⚠️  Final size is above the ${value} MB target. Try a lower target, a resolution cap," >&2
        echo "   or raise MAX_SIZE_RETRIES." >&2
    fi
    echo ""
    return 0
}

# Original entry points (unchanged names and argument order).
compress_to_target()         { compress_core size    "H.264" "$1" "$2" "$3"; }
compress_av1_to_target()     { compress_core size    "AV1"   "$1" "$2" "$3"; }
compress_by_bitrate()        { compress_core bitrate "H.264" "$1" "$2" "$3"; }
compress_av1_by_bitrate()    { compress_core bitrate "AV1"   "$1" "$2" "$3"; }

############################## BATCH PROCESSING ##############################
# Fills VIDEO_FILES with the videos directly inside a folder (not recursive).
collect_videos() {
    local dir="$1" with_gif="$2" ext f
    local -a expr=()
    VIDEO_FILES=()
    for ext in "${VIDEO_EXTS[@]}"; do
        expr+=(-o -iname "*.${ext}")
    done
    [ "$with_gif" = "true" ] && expr+=(-o -iname "*.gif")
    expr=("${expr[@]:1}")    # drop the leading -o
    while IFS= read -r -d '' f; do
        VIDEO_FILES+=("$f")
    done < <(find "$dir" -maxdepth 1 -type f \( "${expr[@]}" \) -print0 | sort -z)
}

# run_batch INPUT_DIR WITH_GIF HANDLER HANDLER_ARGS...
#   HANDLER is called as:  HANDLER FILE HANDLER_ARGS...
#   Handler status: 0 done, 1 failed, 2 skipped, 3 user abort.
run_batch() {
    local input_dir="$1" with_gif="$2" handler="$3"
    shift 3
    local total count=0 n_done=0 n_failed=0 n_skipped=0 rc file aborted=false

    if [ ! -r "$input_dir" ] || [ ! -x "$input_dir" ]; then
        echo "❌ Cannot read folder: $input_dir" >&2
        return 1
    fi
    collect_videos "$input_dir" "$with_gif"
    total=${#VIDEO_FILES[@]}
    if [ "$total" -eq 0 ]; then
        echo "❌ No video files found in $input_dir" >&2
        return 1
    fi

    echo "✅ Found $total video files in folder"
    if [ "$RESOLUTION_CAP" != "Disabled" ] && [ "$handler" != "convert_to_gif" ]; then
        echo "   Resolution cap: $RESOLUTION_CAP"
    fi
    echo ""

    for file in "${VIDEO_FILES[@]}"; do
        count=$((count + 1))
        echo "------------------------------------------------------------"
        echo "|  PROCESSING FILE $count/$total: ${file##*/}"
        echo "------------------------------------------------------------"

        "$handler" "$file" "$@"
        rc=$?
        case "$rc" in
            0) n_done=$((n_done + 1)) ;;
            2) n_skipped=$((n_skipped + 1)) ;;
            3)
                aborted=true
                break
                ;;
            *) n_failed=$((n_failed + 1)) ;;
        esac

        if [ "$count" -lt "$total" ]; then
            echo "------------------------------------------------------------"
            [ "$rc" -eq 2 ] || cooldown_between_files
        fi
    done

    if [ "$aborted" = "true" ]; then
        echo "🛑 Batch aborted by user: $n_done done, $n_failed failed, $n_skipped skipped, $((total - count)) not started."
    else
        echo "✅ Batch finished: $n_done done, $n_failed failed, $n_skipped skipped (of $total)."
    fi
    echo ""
    [ "$aborted" = "false" ] && [ "$n_failed" -eq 0 ]
}

compress_batch()             { run_batch "$1" true  compress_to_target      "$2" "$3"; }
compress_av1_batch()         { run_batch "$1" true  compress_av1_to_target  "$2" "$3"; }
compress_bitrate_batch()     { run_batch "$1" true  compress_by_bitrate     "$2" "$3"; }
compress_av1_bitrate_batch() { run_batch "$1" true  compress_av1_by_bitrate "$2" "$3"; }
convert_gif_batch()          { run_batch "$1" false convert_to_gif "$2" "$3" "$4" "$5" true; }

############################## GIF CONVERSION ##############################
# Warn if a clip is long for a GIF. Returns 0=proceed, 1=abort, 2=skip
check_gif_duration() {
    local input="$1" dur="$2" is_batch="$3"
    local too_long dur_min dur_sec choice

    too_long=$(awk -v d="$dur" -v cap="$GIF_DURATION_WARN_SEC" 'BEGIN { print (d > cap) ? 1 : 0 }')
    [ "$too_long" != "1" ] && return 0

    dur_min=$(awk -v d="$dur" 'BEGIN { printf "%d", d / 60 }')
    dur_sec=$(awk -v d="$dur" 'BEGIN { printf "%02d", d % 60 }')

    echo ""
    echo "⚠️  \"${input##*/}\""
    echo "Duration:${dur_min}m ${dur_sec}s"
    echo "GIFs that are too long tend to be huge and slow to load."
    echo ""
    if [ "$is_batch" = "true" ]; then
        echo "  1. Abort batch"
        echo "  2. Proceed anyway"
        echo "  3. Skip this file"
        echo -n "👉 SELECT OPTION [1-3] (auto-skip in 10s): "
    else
        echo "  1. Abort"
        echo "  2. Proceed anyway"
        echo -n "👉 SELECT OPTION [1-2] (auto-abort in 10s): "
    fi

    if ! read -t 10 -r choice; then
        echo ""
        if [ "$is_batch" = "true" ]; then
            echo "⏱️  No response in time — skipping this file."
            return 2
        else
            echo "⏱️  No response in time — aborting."
            return 1
        fi
    fi

    case "$choice" in
        1)
            echo "🛑 Aborted."
            return 1
            ;;
        2)
            echo "▶️  Proceeding..."
            return 0
            ;;
        3)
            if [ "$is_batch" = "true" ]; then
                echo "⏭️  Skipping this file."
                return 2
            else
                echo "❌ Invalid option — aborting."
                return 1
            fi
            ;;
        *)
            if [ "$is_batch" = "true" ]; then
                echo "❌ Invalid option — skipping this file."
                return 2
            else
                echo "❌ Invalid option — aborting."
                return 1
            fi
            ;;
    esac
}

# Two-pass palette GIF encode: gif_encode_pass INPUT FPS WIDTH DURATION OUTFILE
gif_encode_pass() {
    local input="$1" fps="$2" width="$3" duration="$4" outfile="$5"
    local palette="$RUN_TMP/palette.png"
    local scale_expr="scale=${width}:-1:flags=lanczos"

    rm -f -- "$palette"
    echo "🔁 Pass 1/2: Generating color palette..."
    run_ffmpeg "Palette" "" -y -threads "$THREADS" -filter_threads "$THREADS" -i "$input" \
        -vf "fps=${fps},${scale_expr},palettegen=stats_mode=diff" "$palette" || return 1
    if [ ! -s "$palette" ]; then
        echo "❌ Palette was not produced." >&2
        return 1
    fi
    echo "   ✅ Palette generated."

    echo "🔁 Pass 2/2: Encoding GIF..."
    run_ffmpeg "Progress" "$duration" -y -threads "$THREADS" -filter_complex_threads "$THREADS" \
        -i "$input" -i "$palette" \
        -filter_complex "fps=${fps},${scale_expr}[x];[x][1:v]paletteuse=dither=sierra2_4a" \
        -f gif "$outfile" || return 1
    rm -f -- "$palette"
    echo "   ✅ Encoding complete."
}

# Returns 0 = done, 1 = failed, 2 = skipped, 3 = aborted by user.
convert_to_gif() {
    local input="$1" output_dir="$2" fps="$3" width="$4" target_mb="$5" is_batch="${6:-false}"
    local base name final partial retry duration dur_check
    local final_size target_bytes attempts=0

    require_encoder gif || return 1
    if ! duration=$(get_duration "$input"); then
        echo "❌ Cannot read a valid duration from: $input" >&2
        return 1
    fi

    check_gif_duration "$input" "$duration" "$is_batch"
    dur_check=$?
    if [ "$dur_check" -eq 1 ]; then
        echo "🛑 GIF conversion cancelled for ${input##*/}."
        echo ""
        return 3
    elif [ "$dur_check" -eq 2 ]; then
        echo "⏭️  Skipping ${input##*/}."
        echo ""
        return 2
    fi

    ensure_output_dir "$output_dir" || return 1
    base="${input##*/}"
    name="${base%.*}"
    final=$(resolve_output "${output_dir}/${name}.gif")
    if [ -z "$final" ]; then
        echo "⏭️  Skipping (output already exists and OVERWRITE_POLICY=skip): $base"
        return 2
    fi
    if [ "$final" != "${output_dir}/${name}.gif" ]; then
        echo "   Output name already existed; saving as: ${final##*/}"
    fi

    echo "🎞️  Converting to GIF (fps=${fps}, width=${width}px | threads: $THREADS, nice: $NICE_LEVEL)..."
    echo ""

    partial="${final}.part"
    PARTIAL_FILE="$partial"
    if ! gif_encode_pass "$input" "$fps" "$width" "$duration" "$partial" ||
        ! validate_output "$partial" no; then
        rm -f -- "$partial"
        PARTIAL_FILE=""
        return 1
    fi
    final_size=$(stat -c %s "$partial")

    # Optional: shrink fps/width and re-encode until under the target size
    if [ -n "$target_mb" ]; then
        target_bytes=$(awk -v mb="$target_mb" 'BEGIN { printf "%d", mb * 1024 * 1024 }')
        retry="${partial}.retry"
        while [ "$final_size" -gt "$target_bytes" ] && [ "$attempts" -lt 6 ]; do
            attempts=$((attempts + 1))
            local new_width new_fps="$fps"
            new_width=$(awk -v w="$width" 'BEGIN { w = int(w * 0.85); if (w < 100) w = 100; print w }')
            if [ "$new_fps" -gt 5 ]; then
                new_fps=$((new_fps - 2))
                [ "$new_fps" -lt 5 ] && new_fps=5
            fi

            echo ""
            echo "‼️ GIF too large ($(bytes_to_mb "$final_size") MB vs target ${target_mb} MB). Retrying at fps=${new_fps}, width=${new_width}px (attempt $attempts)..."
            echo ""
            if gif_encode_pass "$input" "$new_fps" "$new_width" "$duration" "$retry" &&
                validate_output "$retry" no; then
                mv -f -- "$retry" "$partial"
                fps="$new_fps"
                width="$new_width"
                final_size=$(stat -c %s "$partial")
            else
                rm -f -- "$retry"
                echo "⚠️  Retry failed; keeping the previous GIF." >&2
                break
            fi
        done

        if [ "$final_size" -gt "$target_bytes" ]; then
            echo "⚠️  Could not fit under ${target_mb} MB after $attempts attempts (final: $(bytes_to_mb "$final_size") MB). Try a lower starting FPS/width." >&2
        fi
    fi

    if ! mv -f -- "$partial" "$final"; then
        echo "❌ Could not move finished GIF to: $final" >&2
        echo "   The encoded data remains at: $partial" >&2
        PARTIAL_FILE=""
        return 1
    fi
    PARTIAL_FILE=""

    echo ""
    echo "✅ GIF saved to: $final ($(bytes_to_mb "$final_size") MB)"
    echo ""
    return 0
}

############################## OPERATION DISPATCH ##############################
finish_operation() {
    if [ "$1" -eq 0 ] || [ "$1" -eq 2 ]; then
        pause_for_enter "✅ OPERATION COMPLETE! Press Enter to continue..."
    else
        pause_for_enter "⚠️  OPERATION FINISHED WITH PROBLEMS (see messages above). Press Enter to continue..."
    fi
}

run_target_size() {
    local target_mb="$1" rc=0
    if [ -f "$INPUT" ]; then
        if [ "$COMP_METHOD" = "H.264" ]; then
            compress_to_target "$INPUT" "$target_mb" "$OUTDIR"
        else
            compress_av1_to_target "$INPUT" "$target_mb" "$OUTDIR"
        fi
        rc=$?
    elif [ -d "$INPUT" ]; then
        if [ "$COMP_METHOD" = "H.264" ]; then
            compress_batch "$INPUT" "$target_mb" "$OUTDIR"
        else
            compress_av1_batch "$INPUT" "$target_mb" "$OUTDIR"
        fi
        rc=$?
    else
        echo "❌ Invalid input type: $INPUT" >&2
        rc=1
    fi
    return "$rc"
}

run_target_bitrate() {
    local kbps="$1" rc=0
    if [ -f "$INPUT" ]; then
        if [ "$COMP_METHOD" = "H.264" ]; then
            compress_by_bitrate "$INPUT" "$kbps" "$OUTDIR"
        else
            compress_av1_by_bitrate "$INPUT" "$kbps" "$OUTDIR"
        fi
        rc=$?
    elif [ -d "$INPUT" ]; then
        if [ "$COMP_METHOD" = "H.264" ]; then
            compress_bitrate_batch "$INPUT" "$kbps" "$OUTDIR"
        else
            compress_av1_bitrate_batch "$INPUT" "$kbps" "$OUTDIR"
        fi
        rc=$?
    else
        echo "❌ Invalid input type: $INPUT" >&2
        rc=1
    fi
    return "$rc"
}

run_gif() {
    local fps="$1" width="$2" target_mb="$3" rc=0
    if [ -f "$INPUT" ]; then
        convert_to_gif "$INPUT" "$OUTDIR" "$fps" "$width" "$target_mb"
        rc=$?
        [ "$rc" -eq 3 ] && rc=1
    elif [ -d "$INPUT" ]; then
        convert_gif_batch "$INPUT" "$OUTDIR" "$fps" "$width" "$target_mb"
        rc=$?
    else
        echo "❌ Invalid input type: $INPUT" >&2
        rc=1
    fi
    return "$rc"
}

############################## INPUT PATH ##############################
# Trims spaces and surrounding quotes, expands a leading ~, validates and
# prints the canonical absolute path.
normalize_input_path() {
    local p="$1"
    p="${p#"${p%%[![:space:]]*}"}"
    p="${p%"${p##*[![:space:]]}"}"
    if [ "${#p}" -ge 2 ] && { [[ "$p" == \"*\" ]] || [[ "$p" == \'*\' ]]; }; then
        p="${p:1:${#p}-2}"
    fi
    case "$p" in
        "~")   p="$HOME" ;;
        "~/"*) p="$HOME/${p:2}" ;;
    esac
    if [ -z "$p" ]; then
        echo "❌ No path entered." >&2
        return 1
    fi
    if [ ! -e "$p" ]; then
        echo "❌ FILE/FOLDER NOT FOUND: $p" >&2
        case "$p" in
            /sdcard* | /storage/*)
                echo "   If it should exist, grant storage access first:  termux-setup-storage" >&2
                ;;
        esac
        return 1
    fi
    if [ ! -r "$p" ]; then
        echo "❌ NOT READABLE (permission denied): $p" >&2
        return 1
    fi
    realpath -- "$p"
}

############################## MAIN ##############################
main() {
    local choice input TARGET_MB TARGET_BITRATE comp_choice res_choice custom_res
    local gif_fps gif_width gif_target_mb input_type op_rc

    if [ $# -ne 0 ]; then
        echo "Command-line mode not implemented. Please run interactively." >&2
        exit 1
    fi

    check_dependencies || exit 1
    init_runtime || exit 1
    CPU_CORES=$(detect_cores)
    clamp_threads

    read -r -e -p "📂 ENTER VIDEO FILE/FOLDER PATH (e.g., /sdcard/Movies): " INPUT || exit_on_eof
    INPUT=$(normalize_input_path "$INPUT") || exit 1

    while true; do
        show_menu
        read -r choice || exit_on_eof
        case "$choice" in
            1)  # Target Size
                while true; do
                    clear
                    input_type="FILE"
                    [ -d "$INPUT" ] && input_type="FOLDER"
                    echo "============================================================"
                    echo "  COMPRESS TO TARGET SIZE (METHOD: $COMP_METHOD)"
                    echo "============================================================"
                    echo "  INPUT ($input_type): $INPUT"
                    echo "  RESOLUTION CAP: $RESOLUTION_CAP"
                    echo "------------------------------------------------------------"
                    echo "  Enter target size in MB (e.g., 10) or"
                    echo "  press Enter to use default 9.5 MB."
                    echo ""
                    echo "  Type (b) for go back to main menu"
                    echo "============================================================"
                    echo -n "👉 SET TARGET SIZE: "
                    read -r input || exit_on_eof
                    echo ""

                    [ "$input" = "b" ] && break

                    if [ -z "$input" ]; then
                        TARGET_MB=9.5
                    elif is_positive_number "$input"; then
                        TARGET_MB="$input"
                    else
                        echo "❌ INVALID NUMBER: $input (must be greater than 0)"
                        pause_for_enter "Press Enter to continue..."
                        continue
                    fi

                    run_target_size "$TARGET_MB"
                    op_rc=$?
                    finish_operation "$op_rc"
                    break
                done
                ;;

            2)  # Target Bitrate
                while true; do
                    clear
                    input_type="FILE"
                    [ -d "$INPUT" ] && input_type="FOLDER"
                    echo "============================================================"
                    echo "  COMPRESS TO TARGET BITRATE (METHOD: $COMP_METHOD)"
                    echo "============================================================"
                    echo "  INPUT ($input_type): $INPUT"
                    echo "  RESOLUTION CAP: $RESOLUTION_CAP"
                    echo "------------------------------------------------------------"
                    echo "  Enter target bitrate in kbps (e.g., 500) or"
                    echo "  press Enter to use default 1000 kbps.                             "
                    echo ""
                    echo "  Type (b) for go back to main menu                                   "
                    echo "============================================================"
                    echo -n "👉 SET TARGET BITRATE: "
                    read -r input || exit_on_eof
                    echo ""

                    [ "$input" = "b" ] && break

                    if [ -z "$input" ]; then
                        TARGET_BITRATE=1000
                    elif is_positive_int "$input"; then
                        TARGET_BITRATE="$input"
                    else
                        echo "❌ INVALID BITRATE: Must be a whole number greater than 0"
                        pause_for_enter "Press Enter to continue..."
                        continue
                    fi

                    run_target_bitrate "$TARGET_BITRATE"
                    op_rc=$?
                    finish_operation "$op_rc"
                    break
                done
                ;;

            3)  # Set Compression Method
                while true; do
                    show_compression_method_menu
                    read -r comp_choice || exit_on_eof
                    case "$comp_choice" in
                        1)
                            COMP_METHOD="H.264"
                            echo "✅ Compression method set to H.264"
                            sleep 1
                            break
                            ;;
                        2)
                            COMP_METHOD="AV1"
                            echo "✅ Compression method set to AV1"
                            sleep 1
                            break
                            ;;
                        3)
                            break
                            ;;
                        *)
                            echo "❌ INVALID OPTION"
                            sleep 1
                            ;;
                    esac
                done
                ;;

            4)  # Set Resolution Cap
                while true; do
                    show_resolution_menu
                    read -r res_choice || exit_on_eof
                    case "$res_choice" in
                        1)
                            RESOLUTION_CAP="1920x1080"
                            echo "✅ Resolution cap set to 1080p (1920x1080)"
                            sleep 1
                            break
                            ;;
                        2)
                            RESOLUTION_CAP="1280x720"
                            echo "✅ Resolution cap set to 720p (1280x720)"
                            sleep 1
                            break
                            ;;
                        3)
                            RESOLUTION_CAP="854x480"
                            echo "✅ Resolution cap set to 480p (854x480)"
                            sleep 1
                            break
                            ;;
                        4)  # Custom resolution
                            echo ""
                            echo "Enter custom resolution (format: WIDTHxHEIGHT)"
                            echo "Examples: 1920x1080 (landscape) or 1080x1920 (portrait)"
                            echo -n "👉 CUSTOM RESOLUTION: "
                            read -r custom_res || exit_on_eof

                            if [[ "$custom_res" =~ ^([0-9]+)x([0-9]+)$ ]] &&
                                [ "${BASH_REMATCH[1]}" -gt 0 ] && [ "${BASH_REMATCH[2]}" -gt 0 ]; then
                                RESOLUTION_CAP="$custom_res"
                                echo "✅ Resolution cap set to $RESOLUTION_CAP"
                                sleep 1
                                break
                            else
                                echo "❌ INVALID FORMAT. Use WIDTHxHEIGHT (e.g., 1920x1080)"
                                sleep 2
                            fi
                            ;;
                        5)
                            RESOLUTION_CAP="Disabled"
                            echo "✅ Resolution cap disabled - original resolution preserved"
                            sleep 1
                            break
                            ;;
                        6)
                            break
                            ;;
                        *)
                            echo "❌ INVALID OPTION"
                            sleep 1
                            ;;
                    esac
                done
                ;;

            5)  # Convert to GIF
                while true; do
                    clear
                    input_type="FILE"
                    [ -d "$INPUT" ] && input_type="FOLDER"
                    echo "============================================================"
                    echo "  CONVERT TO GIF"
                    echo "============================================================"
                    echo "  INPUT ($input_type): $INPUT"
                    echo "------------------------------------------------------------"
                    echo "  Enter FPS (e.g., 15) or press Enter for default 15.       "
                    echo ""
                    echo "  Type (b) for go back to main menu                         "
                    echo "============================================================"
                    echo -n "👉 SET FPS: "
                    read -r gif_fps || exit_on_eof
                    echo ""

                    [ "$gif_fps" = "b" ] && break

                    if [ -z "$gif_fps" ]; then
                        gif_fps=15
                    elif ! is_positive_int "$gif_fps"; then
                        echo "❌ INVALID FPS: Must be a whole number greater than 0"
                        pause_for_enter "Press Enter to continue..."
                        continue
                    fi

                    echo -n "👉 SET WIDTH IN PX (e.g., 480, Enter for default 480): "
                    read -r gif_width || exit_on_eof
                    echo ""

                    if [ -z "$gif_width" ]; then
                        gif_width=480
                    elif ! is_positive_int "$gif_width"; then
                        echo "❌ INVALID WIDTH: Must be a whole number greater than 0"
                        pause_for_enter "Press Enter to continue..."
                        continue
                    fi

                    echo -n "👉 MAX FILE SIZE IN MB, optional (Enter to skip): "
                    read -r gif_target_mb || exit_on_eof
                    echo ""

                    if [ -n "$gif_target_mb" ] && ! is_positive_number "$gif_target_mb"; then
                        echo "❌ INVALID SIZE: Must be a number greater than 0"
                        pause_for_enter "Press Enter to continue..."
                        continue
                    fi

                    run_gif "$gif_fps" "$gif_width" "$gif_target_mb"
                    op_rc=$?
                    finish_operation "$op_rc"
                    break
                done
                ;;

            6)  # Exit
                echo "   EXITING..."
                exit 0
                ;;

            [tT])  # CPU / thermal settings
                thermal_settings_menu
                ;;

            *)
                echo "❌ INVALID OPTION"
                sleep 1
                ;;
        esac
    done
}

main "$@"
exit 0
