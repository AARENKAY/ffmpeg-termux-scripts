#!/data/data/com.termux/files/usr/bin/bash
set -uo pipefail

# ===========================================================================
# VIDEO ↔ GIF CONVERTER
# Standalone batch tool — converts videos to animated GIFs (ffmpeg two-pass
# palettegen/paletteuse) and GIFs back to video, with an interactive menu.
# ===========================================================================

# ==================== COLOR DEFINITIONS (matches convert.sh) ====================
declare -g COLOR_RESET="\033[0m"
declare -g COLOR_RED="\033[1m\033[38;5;196m"
declare -g COLOR_GREEN="\033[1m\033[38;5;82m"
declare -g COLOR_YELLOW="\033[1m\033[38;5;226m"
declare -g COLOR_ORANGE="\033[1m\033[38;5;208m"
declare -g COLOR_BLUE="\033[1m\033[38;5;39m"
declare -g COLOR_CYAN="\033[1m\033[38;5;6m"
# ===================================================================================

# ==================== CONFIG — EDIT THESE AS NEEDED, OR USE THE MENU ====================
declare -g DEFAULT_INPUT_DIR="/sdcard/Movies/ffmpeg/Converted"   # source for Video -> GIF
declare -g OUTPUT_DIR="/sdcard/Movies/ffmpeg/GIF/Video-to-GIF"                # also the default source for GIF -> Video
declare -g LOG_DIR="/sdcard/Movies/ffmpeg/GIF/Video-to-GIF/Logs"
declare -g OUTPUT_DIR_G2V="/sdcard/Movies/ffmpeg/GIF/GIF-to-Video"
declare -g LOG_DIR_G2V="/sdcard/Movies/ffmpeg/GIF/GIF-to-Video/Logs"
declare -g COMPLETED_DIR="/sdcard/Movies/ffmpeg/.gif_status/completed"

declare -g GIF_FPS=12          # fixed frames per second when GIF_FPS_MODE=fixed
declare -g GIF_FPS_MODE="dynamic" # dynamic = follow each source video FPS; fixed = use GIF_FPS
declare -g GIF_WIDTH=480       # fixed output width in px when GIF_WIDTH_MODE=fixed
declare -g GIF_WIDTH_MODE="dynamic" # dynamic = preserve each source video width; fixed = use GIF_WIDTH
declare -g GIF_START_TIME=""   # e.g. "00:00:05" to trim the start; empty = from 0
declare -g GIF_DURATION=""     # e.g. "10" (seconds) to trim length; empty = full length
declare -g GIF_DITHER="bayer:bayer_scale=3"  # paletteuse dither algorithm
declare -g GIF_PALETTE_STATS_MODE="diff"       # full or diff
declare -g FFMPEG_THREADS=1    # CPU threads ffmpeg may use (decoding, filters, encoding); 1 = lowest CPU load

declare -g GIF2VIDEO_FORMAT="mp4"        # mp4, webm or mkv
declare -g GIF2VIDEO_CODEC="libx264"     # kept in sync with format via the menu
declare -g GIF2VIDEO_CRF=15              # H.264: 0-51; VP9: 0-63
declare -g GIF2VIDEO_PRESET="slow"     # libx264 preset
declare -g GIF2VIDEO_VP9_DEADLINE="good" # libvpx-vp9: good, best, realtime
declare -g GIF2VIDEO_VP9_CPU_USED=2      # libvpx-vp9: 0-8
declare -g GIF2VIDEO_PIX_FMT="yuv420p"   # encoder pixel format
declare -g GIF2VIDEO_WIDTH=480           # fixed output width in px when GIF2VIDEO_WIDTH_MODE=fixed
declare -g GIF2VIDEO_WIDTH_MODE="dynamic" # dynamic = preserve GIF dimensions; fixed = use GIF2VIDEO_WIDTH
declare -g GIF2VIDEO_FPS=30               # fixed output FPS when GIF2VIDEO_FPS_MODE=fixed
declare -g GIF2VIDEO_FPS_MODE="dynamic"  # dynamic = preserve source GIF frame timing; fixed = use GIF2VIDEO_FPS
# ==========================================================================================

# Thread limits passed to every ffmpeg run (decoder, filter graph).
declare -ga FFMPEG_THREAD_ARGS=()
set_thread_args() {
    FFMPEG_THREAD_ARGS=(-threads "$FFMPEG_THREADS" -filter_threads "$FFMPEG_THREADS" -filter_complex_threads "$FFMPEG_THREADS")
}
set_thread_args

# ==================== UI HELPERS ====================
# Look: sentence-case text, one icon per message type, a rounded banner,
# thin section dividers, [n] menu keys and a live progress bar. Widths adapt
# to the terminal (clamped so it still looks right on a phone).
declare -g COLOR_ACCENT="\033[1m\033[38;5;45m"
declare -g COLOR_WHITE="\033[1m\033[38;5;255m"
declare -g COLOR_GRAY="\033[38;5;245m"
declare -g UI_WIDTH=40
declare -g UI_RULE=""

ui_init() {
    local cols i
    cols=$(tput cols 2>/dev/null || echo 44)
    [[ "$cols" =~ ^[0-9]+$ ]] || cols=44
    UI_WIDTH=$(( cols - 4 ))
    [ "$UI_WIDTH" -gt 52 ] && UI_WIDTH=52
    [ "$UI_WIDTH" -lt 24 ] && UI_WIDTH=24
    UI_RULE=""
    for ((i = 0; i < UI_WIDTH; i++)); do UI_RULE+="─"; done
}
ui_init

ui_banner() {  # title [subtitle]  (ASCII only: padding is by character count)
    local inner=$(( UI_WIDTH - 4 )) t sub=""
    printf -v t '%-*s' "$inner" "${1:0:$inner}"
    [ -n "${2:-}" ] && printf -v sub '%-*s' "$inner" "${2:0:$inner}"
    echo ""
    echo -e " ${COLOR_ACCENT}╭${UI_RULE}╮${COLOR_RESET}"
    echo -e " ${COLOR_ACCENT}│${COLOR_RESET}  ${COLOR_WHITE}${t}${COLOR_RESET}  ${COLOR_ACCENT}│${COLOR_RESET}"
    [ -n "$sub" ] && echo -e " ${COLOR_ACCENT}│${COLOR_RESET}  ${COLOR_GRAY}${sub}${COLOR_RESET}  ${COLOR_ACCENT}│${COLOR_RESET}"
    echo -e " ${COLOR_ACCENT}╰${UI_RULE}╯${COLOR_RESET}"
}

ui_section() {  # title (ASCII only: its length sizes the divider)
    local t="$1" fill i bar=""
    fill=$(( UI_WIDTH - ${#t} - 3 ))
    [ "$fill" -lt 3 ] && fill=3
    for ((i = 0; i < fill; i++)); do bar+="─"; done
    echo ""
    echo -e " ${COLOR_ACCENT}──${COLOR_RESET} ${COLOR_WHITE}${t}${COLOR_RESET} ${COLOR_GRAY}${bar}${COLOR_RESET}"
}

ui_ok()   { echo -e " ${COLOR_GREEN}✔${COLOR_RESET} $*"; }
ui_warn() { echo -e " ${COLOR_YELLOW}⚠${COLOR_RESET} $*"; }
ui_err()  { echo -e " ${COLOR_RED}✖${COLOR_RESET} $*"; }
ui_info() { echo -e " ${COLOR_ACCENT}•${COLOR_RESET} $*"; }
ui_note() { echo -e "   ${COLOR_GRAY}$*${COLOR_RESET}"; }

ui_kv() {  # label value
    local l
    l=$(printf '%-9s' "$1")
    echo -e "   ${COLOR_GRAY}${l}${COLOR_RESET} $2"
}

ui_opt() {  # key label [hint]
    local hint=""
    [ -n "${3:-}" ] && hint="  ${COLOR_GRAY}${3}${COLOR_RESET}"
    echo -e "   ${COLOR_ACCENT}[${1}]${COLOR_RESET} ${2}${hint}"
}

# Use as: read -r -p "$(ui_prompt "Question" "(hint)")" var
ui_prompt() {  # label [hint]
    local out=" ${COLOR_ACCENT}❯${COLOR_RESET} ${COLOR_WHITE}$1${COLOR_RESET}"
    [ -n "${2:-}" ] && out+=" ${COLOR_GRAY}$2${COLOR_RESET}"
    printf '%b ' "$out"
}

ui_progress() {  # current total  (only drawn on a real terminal)
    [ -t 1 ] || return 0
    local cur="$1" total="$2" w=20 filled pct i bar=""
    [ "$total" -gt 0 ] 2>/dev/null || return 0
    filled=$(( cur * w / total ))
    pct=$(( cur * 100 / total ))
    for ((i = 0; i < w; i++)); do
        if (( i < filled )); then bar+="█"; else bar+="░"; fi
    done
    printf '\r\033[K   %b%s%b %3d%%  %b%d/%d%b' \
        "$COLOR_ACCENT" "$bar" "$COLOR_RESET" "$pct" "$COLOR_GRAY" "$cur" "$total" "$COLOR_RESET"
}
ui_progress_clear() { [ -t 1 ] && printf '\r\033[K'; return 0; }

ui_row() {  # key label value  (settings menu line)
    printf '   %b%-4s%b %-12s %b%s%b\n' "$COLOR_ACCENT" "[$1]" "$COLOR_RESET" "$2" "$COLOR_GRAY" "$3" "$COLOR_RESET"
}

ui_bar_line() {  # label percent  (in-place ffmpeg progress line)
    local label="$1" pct="$2" w=16 filled i bar=""
    filled=$(( pct * w / 100 ))
    for ((i = 0; i < w; i++)); do
        if (( i < filled )); then bar+="█"; else bar+="░"; fi
    done
    printf '\r\033[K   %b%-12s%b %b%s%b %3d%%' \
        "$COLOR_GRAY" "$label" "$COLOR_RESET" "$COLOR_ACCENT" "$bar" "$COLOR_RESET" "$pct"
}

# ------------------------------------------------------------
human_duration() {
    awk -v d="$1" 'BEGIN {
        d = int(d + 0.5)
        h = int(d / 3600); m = int((d % 3600) / 60); s = d % 60
        if (h > 0)      printf "%dh %dm %ds", h, m, s
        else if (m > 0) printf "%dm %ds", m, s
        else            printf "%ds", s
    }'
}

declare -g BATCH_LABEL=""   # "[3/12] " prefix shown on file headers during folder batches
declare -g FAILED=0
declare -g SUCCEEDED=0
declare -g SKIPPED=0
declare -g CURRENT_FFMPEG_PID=""
declare -g CURRENT_PALETTE=""
declare -g CURRENT_OUTPUT_FILE=""
# Completion markers are used only for directory batch operations.
# Single-file conversions always attempt conversion and never touch markers.
declare -g TRACK_COMPLETION_MARKERS=0

# ------------------------------------------------------------
# Ctrl+C handling — kills only the ffmpeg process this script
# itself started (tracked by PID, not by pattern-matching every
# ffmpeg on the system), and cleans up any in-progress temp
# palette / partial output file.
# ------------------------------------------------------------
trap handle_interrupt INT TERM

handle_interrupt() {
    echo ""
    printf '\r\033[K'
    ui_err "Ctrl+C detected — aborting..."
    if [ -n "$CURRENT_FFMPEG_PID" ]; then
        kill -INT "$CURRENT_FFMPEG_PID" 2>/dev/null
        sleep 1
        kill -KILL "$CURRENT_FFMPEG_PID" 2>/dev/null
    fi
    [ -n "$CURRENT_PALETTE" ] && rm -f "$CURRENT_PALETTE" 2>/dev/null
    [ -n "$CURRENT_OUTPUT_FILE" ] && rm -f "$CURRENT_OUTPUT_FILE" 2>/dev/null
    ui_err "Process terminated by user"
    exit 130
}

# ------------------------------------------------------------
# FUNCTION: run_ffmpeg — runs ffmpeg in the background so its
# PID can be tracked for handle_interrupt, then waits for it.
# ------------------------------------------------------------
run_ffmpeg() {
    "$@" &
    CURRENT_FFMPEG_PID=$!
    wait "$CURRENT_FFMPEG_PID"
    local status=$?
    CURRENT_FFMPEG_PID=""
    return $status
}

# Run an FFmpeg encode while displaying its percentage progress in-place.
# Usage: run_ffmpeg_progress DURATION LABEL LOG_FILE ffmpeg [arguments...]
run_ffmpeg_progress() {
    local duration="$1" label="$2" log_file="$3"
    shift 3
    local ffmpeg_bin="$1"
    shift
    local progress_dir progress_fifo status=0 out_time_us=0 percent=0

    progress_dir=$(mktemp -d "${TMPDIR:-/tmp}/v2g-progress.XXXXXX") || return 1
    progress_fifo="$progress_dir/progress"
    if ! mkfifo "$progress_fifo"; then
        rm -rf "$progress_dir"
        return 1
    fi

    "$ffmpeg_bin" -progress "$progress_fifo" -nostats "$@" >>"$log_file" 2>&1 &
    CURRENT_FFMPEG_PID=$!

    while IFS='=' read -r key value; do
        case "$key" in
            out_time_us)
                out_time_us="$value"
                if [[ "$duration" =~ ^[0-9]+([.][0-9]+)?$ ]] && awk -v d="$duration" 'BEGIN { exit !(d > 0) }'; then
                    percent=$(awk -v t="$out_time_us" -v d="$duration" 'BEGIN { p=int((t/(d*1000000))*100); if (p<0) p=0; if (p>99) p=99; print p }')
                    ui_bar_line "$label" "$percent"
                else
                    printf '\r\033[K   %b%s%b %bworking…%b' "$COLOR_GRAY" "$label" "$COLOR_RESET" "$COLOR_GRAY" "$COLOR_RESET"
                fi
                ;;
            progress)
                if [ "$value" = "end" ]; then
                    ui_bar_line "$label" 100
                    printf '\n'
                fi
                ;;
        esac
    done < "$progress_fifo"

    wait "$CURRENT_FFMPEG_PID" || status=$?
    CURRENT_FFMPEG_PID=""
    rm -rf "$progress_dir"
    return "$status"
}

# ------------------------------------------------------------
# FUNCTION: format_time — seconds -> H:MM:SS for display
# ------------------------------------------------------------
format_time() {
    local seconds="$1"
    awk -v t="$seconds" 'BEGIN {
        if (t ~ /[^0-9.]/ || t == "") { print "?"; exit }
        h = int(t / 3600); m = int((t % 3600) / 60); s = int(t % 60)
        printf("%d:%02d:%02d", h, m, s)
    }'
}

# ------------------------------------------------------------
# FUNCTION: check_dependencies
# ------------------------------------------------------------
check_dependencies() {
    local missing=()
    local deps=(ffmpeg ffprobe find realpath sha256sum sort awk du mktemp)

    declare -A dep_pkg=(
        [ffmpeg]="ffmpeg" [ffprobe]="ffmpeg"
        [realpath]="coreutils" [sha256sum]="coreutils" [sort]="coreutils"
        [du]="coreutils" [mktemp]="coreutils"
        [awk]="gawk" [find]="findutils"
    )

    for dep in "${deps[@]}"; do
        command -v "$dep" >/dev/null 2>&1 || missing+=("$dep")
    done

    if [ ${#missing[@]} -gt 0 ]; then
        ui_err "Missing dependencies"
        for m in "${missing[@]}"; do echo -e "   ${COLOR_GRAY}•${COLOR_RESET} $m"; done
        local pkgs=()
        for m in "${missing[@]}"; do pkgs+=("${dep_pkg[$m]}"); done
        pkgs=($(printf "%s\n" "${pkgs[@]}" | sort -u))
        echo ""
        ui_info "Install with:"
        printf "   ${COLOR_ACCENT}pkg install${COLOR_RESET}"
        for p in "${pkgs[@]}"; do printf " %s" "$p"; done
        printf "\n"
        exit 1
    fi
}

# ------------------------------------------------------------
# FUNCTION: mark_completed / is_completed
# Hash-based resume tracking for directory batch operations only.
# Single-file conversions must not consult or update these markers.
# ------------------------------------------------------------
mark_completed() {
    local input_file="$1"
    local marker_name
    marker_name=$(printf '%s' "$input_file" | sha256sum | awk '{print $1}')
    touch "$COMPLETED_DIR/$marker_name"
}

is_completed() {
    local input_file="$1"
    local marker_name
    marker_name=$(printf '%s' "$input_file" | sha256sum | awk '{print $1}')
    [ -f "$COMPLETED_DIR/$marker_name" ] && return 0
    return 1
}

# ------------------------------------------------------------
# FUNCTION: has_video_files / has_gif_files — recursive finders,
# both prune chunks_* dirs for consistency with the rest of the
# toolkit.
# ------------------------------------------------------------
has_video_files() {
    local dir="$1"
    [ ! -d "$dir" ] && return 1

    local first_match
    first_match=$(find "$dir" \
        \( -type d -iname "chunks_*" -prune \) -o \
        \( -type f \( \
        -iname "*.mp4" -o -iname "*.mkv" -o -iname "*.mov" -o -iname "*.avi" -o \
        -iname "*.webm" -o -iname "*.wmv" -o -iname "*.flv" -o -iname "*.mpeg" -o \
        -iname "*.mpg" -o -iname "*.mpe" -o -iname "*.m4v" -o -iname "*.3gp" -o \
        -iname "*.3g2" -o -iname "*.f4v" -o -iname "*.ts" -o -iname "*.m2ts" -o \
        -iname "*.mts" -o -iname "*.vob" \) -print \) -quit)

    [ -n "$first_match" ]
}

has_gif_files() {
    local dir="$1"
    [ ! -d "$dir" ] && return 1

    local first_match
    first_match=$(find "$dir" \
        \( -type d -iname "chunks_*" -prune \) -o \
        \( -type f -iname "*.gif" -print \) -quit)

    [ -n "$first_match" ]
}

# ------------------------------------------------------------
# FUNCTION: get_video_fps — returns the source video's average frame rate
# as a decimal suitable for FFmpeg's fps filter. Falls back to r_frame_rate
# and then to the configured fixed FPS if probing fails.
# ------------------------------------------------------------
get_video_fps() {
    local input_file="$1" rate=""
    rate=$(ffprobe -v error -select_streams v:0 \
        -show_entries stream=avg_frame_rate -of default=noprint_wrappers=1:nokey=1 \
        "$input_file" 2>/dev/null | head -n 1)
    if [ -z "$rate" ] || [ "$rate" = "0/0" ]; then
        rate=$(ffprobe -v error -select_streams v:0 \
            -show_entries stream=r_frame_rate -of default=noprint_wrappers=1:nokey=1 \
            "$input_file" 2>/dev/null | head -n 1)
    fi
    awk -v r="$rate" -v fallback="$GIF_FPS" 'BEGIN {
        if (r ~ /^[0-9]+\/[0-9]+$/) {
            split(r,a,"/"); if (a[2] > 0) r=a[1]/a[2]; else r=fallback
        }
        if (r !~ /^[0-9]+([.][0-9]+)?$/ || r <= 0) r=fallback
        # Avoid producing an impractically huge GIF from very high-frame-rate sources.
        if (r > 120) r=120
        printf "%.3f", r
    }'
}

# ------------------------------------------------------------
# FUNCTION: process_file — converts one video to one GIF
# $1 = input file, $2 = relative subdirectory under the scan
#      root (mirrored into OUTPUT_DIR/LOG_DIR), optional
# ------------------------------------------------------------
process_file() {
    local input_file
    input_file=$(realpath "$1")
    local relative_dir="${2:-}"
    local filename
    filename=$(basename -- "$input_file")
    local filename_noext="${filename%.*}"

    if [ "$TRACK_COMPLETION_MARKERS" -eq 1 ] && is_completed "$input_file"; then
        echo -e " ${COLOR_GRAY}↷${COLOR_RESET} ${BATCH_LABEL}$filename ${COLOR_GRAY}(already converted in batch)${COLOR_RESET}"
        ((SKIPPED++))
        return 0
    fi

    local output_dir="$OUTPUT_DIR"
    local log_dir="$LOG_DIR"
    if [ -n "$relative_dir" ] && [ "$relative_dir" != "." ]; then
        output_dir="$OUTPUT_DIR/$relative_dir"
        log_dir="$LOG_DIR/$relative_dir"
    fi
    mkdir -p "$output_dir" "$log_dir"

    local output_file
    output_file=$(realpath -m "$output_dir/${filename_noext}.gif")
    local LOG_FILE
    LOG_FILE=$(realpath -m "$log_dir/${filename_noext}.log")
    > "$LOG_FILE"

    echo ""
    echo -e " ${COLOR_ORANGE}▶${COLOR_RESET} ${BATCH_LABEL}${COLOR_WHITE}$filename${COLOR_RESET} ${COLOR_GRAY}→ GIF${COLOR_RESET}"

    local duration
    duration=$(ffprobe -v error -show_entries format=duration \
        -of default=noprint_wrappers=1:nokey=1 "$input_file" 2>>"$LOG_FILE")
    if [ -n "$duration" ]; then
        ui_kv "Duration" "$(human_duration "$duration")"
    fi

    # Build the shared filter chain and the optional trim args
    local gif_scale_filter
    if [ "$GIF_WIDTH_MODE" = "dynamic" ]; then
        # Preserve each input video's native width; only keep the derived height even.
        gif_scale_filter="scale=iw:-2:flags=lanczos"
    else
        gif_scale_filter="scale=${GIF_WIDTH}:-2:flags=lanczos"
    fi
    local effective_gif_fps="$GIF_FPS"
    if [ "$GIF_FPS_MODE" = "dynamic" ]; then
        effective_gif_fps=$(get_video_fps "$input_file")
        ui_kv "FPS" "${effective_gif_fps} ${COLOR_GRAY}(dynamic, from source)${COLOR_RESET}"
    else
        ui_kv "FPS" "${effective_gif_fps} ${COLOR_GRAY}(fixed)${COLOR_RESET}"
    fi
    local filters="fps=${effective_gif_fps},${gif_scale_filter}"
    local trim_args=()
    [ -n "$GIF_START_TIME" ] && trim_args+=(-ss "$GIF_START_TIME")
    [ -n "$GIF_DURATION" ] && trim_args+=(-t "$GIF_DURATION")

    CURRENT_PALETTE=$(mktemp "${log_dir}/palette_XXXXXX.png")

    # Pass 1: build an optimized color palette for this clip
    ui_info "Generating palette…"
    if ! run_ffmpeg ffmpeg -y "${FFMPEG_THREAD_ARGS[@]}" "${trim_args[@]}" -i "$input_file" \
        -vf "${filters},palettegen=stats_mode=${GIF_PALETTE_STATS_MODE}" \
        -threads "$FFMPEG_THREADS" \
        "$CURRENT_PALETTE" >>"$LOG_FILE" 2>&1; then
        ui_err "Palette generation failed ${COLOR_GRAY}(see $LOG_FILE)${COLOR_RESET}"
        rm -f "$CURRENT_PALETTE"
        CURRENT_PALETTE=""
        ((FAILED++))
        return 1
    fi

    # Pass 2: encode the GIF using that palette
    local gif_encode_duration="$duration"
    if [ -n "$GIF_DURATION" ] && [[ "$GIF_DURATION" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        gif_encode_duration="$GIF_DURATION"
    elif [ -n "$GIF_START_TIME" ] && [ -n "$duration" ]; then
        local start_seconds
        start_seconds=$(awk -v t="$GIF_START_TIME" 'BEGIN { if (t ~ /^[0-9]+([.][0-9]+)?$/) print t; else { split(t,a,":"); if (length(a)==3) print a[1]*3600+a[2]*60+a[3]; else if (length(a)==2) print a[1]*60+a[2]; else print 0 } }')
        gif_encode_duration=$(awk -v d="$duration" -v st="$start_seconds" 'BEGIN { r=d-st; if (r<0) r=0; print r }')
    fi
    CURRENT_OUTPUT_FILE="$output_file"
    if ! run_ffmpeg_progress "$gif_encode_duration" "Encoding GIF" "$LOG_FILE" ffmpeg -y "${FFMPEG_THREAD_ARGS[@]}" "${trim_args[@]}" -i "$input_file" -i "$CURRENT_PALETTE" \
        -lavfi "${filters} [x]; [x][1:v] paletteuse=dither=${GIF_DITHER}" \
        -an -loop 0 -threads "$FFMPEG_THREADS" \
        "$output_file"; then
        printf '\r\033[K'
        ui_err "GIF encoding failed ${COLOR_GRAY}(see $LOG_FILE)${COLOR_RESET}"
        rm -f "$CURRENT_PALETTE" "$output_file"
        CURRENT_PALETTE=""
        CURRENT_OUTPUT_FILE=""
        ((FAILED++))
        return 1
    fi

    rm -f "$CURRENT_PALETTE"
    CURRENT_PALETTE=""
    CURRENT_OUTPUT_FILE=""

    local size
    size=$(du -h "$output_file" 2>/dev/null | cut -f1)
    ui_ok "Saved ${COLOR_GRAY}($size)${COLOR_RESET}"
    ui_note "$output_file"

    if [ "$TRACK_COMPLETION_MARKERS" -eq 1 ]; then
        mark_completed "$input_file"
    fi
    ((SUCCEEDED++))
    return 0
}

# ------------------------------------------------------------
# FUNCTION: process_gif_file — converts one GIF to one video
# $1 = input file, $2 = relative subdirectory under the scan
#      root (mirrored into OUTPUT_DIR_G2V/LOG_DIR_G2V), optional
# ------------------------------------------------------------
process_gif_file() {
    local input_file
    input_file=$(realpath "$1")
    local relative_dir="${2:-}"
    local filename
    filename=$(basename -- "$input_file")
    local filename_noext="${filename%.*}"

    if [ "$TRACK_COMPLETION_MARKERS" -eq 1 ] && is_completed "$input_file"; then
        echo -e " ${COLOR_GRAY}↷${COLOR_RESET} ${BATCH_LABEL}$filename ${COLOR_GRAY}(already converted in batch)${COLOR_RESET}"
        ((SKIPPED++))
        return 0
    fi

    local output_dir="$OUTPUT_DIR_G2V"
    local log_dir="$LOG_DIR_G2V"
    if [ -n "$relative_dir" ] && [ "$relative_dir" != "." ]; then
        output_dir="$OUTPUT_DIR_G2V/$relative_dir"
        log_dir="$LOG_DIR_G2V/$relative_dir"
    fi
    mkdir -p "$output_dir" "$log_dir"

    local output_file
    output_file=$(realpath -m "$output_dir/${filename_noext}.${GIF2VIDEO_FORMAT}")
    local LOG_FILE
    LOG_FILE=$(realpath -m "$log_dir/${filename_noext}.log")
    > "$LOG_FILE"

    echo ""
    echo -e " ${COLOR_ORANGE}▶${COLOR_RESET} ${BATCH_LABEL}${COLOR_WHITE}$filename${COLOR_RESET} ${COLOR_GRAY}→ ${GIF2VIDEO_FORMAT}${COLOR_RESET}"

    local faststart_args=()
    local encoder_args=()
    local fps_mode_args=()
    local video_filters=()
    local scale_filter="scale=trunc(iw/2)*2:trunc(ih/2)*2"
    [ "$GIF2VIDEO_FORMAT" = "mp4" ] && faststart_args+=(-movflags +faststart)

    if [ "$GIF2VIDEO_WIDTH_MODE" = "fixed" ]; then
        scale_filter="scale=${GIF2VIDEO_WIDTH}:-2:flags=lanczos"
    fi
    video_filters+=("$scale_filter")

    if [ "$GIF2VIDEO_FPS_MODE" = "fixed" ]; then
        video_filters+=("fps=${GIF2VIDEO_FPS}")
        ui_kv "FPS" "${GIF2VIDEO_FPS} ${COLOR_GRAY}(fixed)${COLOR_RESET}"
    else
        # Preserve the per-frame timing stored in the GIF instead of forcing CFR.
        fps_mode_args=(-fps_mode passthrough)
        ui_kv "FPS" "${COLOR_GRAY}dynamic (keeps the GIF's timing)${COLOR_RESET}"
    fi
    local video_filter_string
    video_filter_string=$(IFS=,; echo "${video_filters[*]}")

    if [ "$GIF2VIDEO_CODEC" = "libvpx-vp9" ]; then
        # VP9 constant-quality mode requires -b:v 0; speed controls differ from x264.
        encoder_args=(-c:v "$GIF2VIDEO_CODEC" -crf "$GIF2VIDEO_CRF" -b:v 0
            -deadline "$GIF2VIDEO_VP9_DEADLINE" -cpu-used "$GIF2VIDEO_VP9_CPU_USED")
    else
        encoder_args=(-c:v "$GIF2VIDEO_CODEC" -crf "$GIF2VIDEO_CRF"
            -preset "$GIF2VIDEO_PRESET")
    fi

    local video_duration
    video_duration=$(ffprobe -v error -show_entries format=duration \
        -of default=noprint_wrappers=1:nokey=1 "$input_file" 2>>"$LOG_FILE")
    CURRENT_OUTPUT_FILE="$output_file"
    if ! run_ffmpeg_progress "$video_duration" "Encoding ${GIF2VIDEO_FORMAT^^}" "$LOG_FILE" ffmpeg -y "${FFMPEG_THREAD_ARGS[@]}" -i "$input_file" \
        -vf "$video_filter_string" \
        "${fps_mode_args[@]}" \
        -pix_fmt "$GIF2VIDEO_PIX_FMT" \
        "${encoder_args[@]}" \
        -threads "$FFMPEG_THREADS" \
        "${faststart_args[@]}" \
        "$output_file"; then
        printf '\r\033[K'
        ui_err "Video encoding failed ${COLOR_GRAY}(see $LOG_FILE)${COLOR_RESET}"
        rm -f "$output_file"
        CURRENT_OUTPUT_FILE=""
        ((FAILED++))
        return 1
    fi
    CURRENT_OUTPUT_FILE=""

    local size
    size=$(du -h "$output_file" 2>/dev/null | cut -f1)
    ui_ok "Saved ${COLOR_GRAY}($size)${COLOR_RESET}"
    ui_note "$output_file"

    if [ "$TRACK_COMPLETION_MARKERS" -eq 1 ]; then
        mark_completed "$input_file"
    fi
    ((SUCCEEDED++))
    return 0
}

# ------------------------------------------------------------
# FUNCTION: process_all_files — recursive batch scan of a
# directory for VIDEO files, pruning chunks_* temp folders,
# mirroring the input's subfolder structure into OUTPUT_DIR
# and LOG_DIR. Converts each one to GIF.
# ------------------------------------------------------------
process_all_files() {
    local input_dir
    input_dir=$(realpath "$1")
    local input_dir_clean="${input_dir%/}"

    local files=()
    while IFS= read -r -d '' f; do
        files+=("$f")
    done < <(find "$input_dir" \
        \( -type d -iname "chunks_*" -prune \) -o \
        \( -type f \( \
        -iname "*.mp4" -o -iname "*.mkv" -o -iname "*.mov" -o -iname "*.avi" -o \
        -iname "*.webm" -o -iname "*.wmv" -o -iname "*.flv" -o -iname "*.mpeg" -o \
        -iname "*.mpg" -o -iname "*.mpe" -o -iname "*.m4v" -o -iname "*.3gp" -o \
        -iname "*.3g2" -o -iname "*.f4v" -o -iname "*.ts" -o -iname "*.m2ts" -o \
        -iname "*.mts" -o -iname "*.vob" \) -printf "%p\0" \))

    if [ ${#files[@]} -eq 0 ]; then
        ui_err "No video files found in:"
        ui_note "$input_dir"
        return 1
    fi

    mapfile -d '' files < <(printf '%s\0' "${files[@]}" | sort -zV)

    ui_info "Found ${COLOR_WHITE}${#files[@]}${COLOR_RESET} video file(s) in"
    ui_note "$input_dir"

    local batch_idx=0 batch_total=${#files[@]}
    for input_file in "${files[@]}"; do
        batch_idx=$((batch_idx + 1))
        BATCH_LABEL="${COLOR_ACCENT}[${batch_idx}/${batch_total}]${COLOR_RESET} "
        local relative_path="${input_file#"$input_dir_clean"/}"
        local relative_dir
        relative_dir="$(dirname "$relative_path")"

        if [ "$relative_dir" = "." ]; then
            process_file "$input_file" || true
        else
            process_file "$input_file" "$relative_dir" || true
        fi
    done
    BATCH_LABEL=""
}

# ------------------------------------------------------------
# FUNCTION: process_all_gif_files — same, but for GIF files,
# converting each one to video.
# ------------------------------------------------------------
process_all_gif_files() {
    local input_dir
    input_dir=$(realpath "$1")
    local input_dir_clean="${input_dir%/}"

    local files=()
    while IFS= read -r -d '' f; do
        files+=("$f")
    done < <(find "$input_dir" \
        \( -type d -iname "chunks_*" -prune \) -o \
        \( -type f -iname "*.gif" -printf "%p\0" \))

    if [ ${#files[@]} -eq 0 ]; then
        ui_err "No GIF files found in:"
        ui_note "$input_dir"
        return 1
    fi

    mapfile -d '' files < <(printf '%s\0' "${files[@]}" | sort -zV)

    ui_info "Found ${COLOR_WHITE}${#files[@]}${COLOR_RESET} GIF file(s) in"
    ui_note "$input_dir"

    local batch_idx=0 batch_total=${#files[@]}
    for input_file in "${files[@]}"; do
        batch_idx=$((batch_idx + 1))
        BATCH_LABEL="${COLOR_ACCENT}[${batch_idx}/${batch_total}]${COLOR_RESET} "
        local relative_path="${input_file#"$input_dir_clean"/}"
        local relative_dir
        relative_dir="$(dirname "$relative_path")"

        if [ "$relative_dir" = "." ]; then
            process_gif_file "$input_file" || true
        else
            process_gif_file "$input_file" "$relative_dir" || true
        fi
    done
    BATCH_LABEL=""
}

# ------------------------------------------------------------
# FUNCTION: run_conversion — shared "ask for a path, then
# convert it" flow used by both the menu and CLI subcommands.
# $1 = "to-gif" or "to-video", $2 = optional path (skips prompt)
# ------------------------------------------------------------
run_conversion() {
    local mode="$1"
    local input_path="${2:-}"
    local default_dir

    FAILED=0; SUCCEEDED=0; SKIPPED=0; BATCH_LABEL=""

    if [ "$mode" = "to-gif" ]; then
        default_dir="$DEFAULT_INPUT_DIR"
        ui_section "Video to GIF"
    else
        default_dir="$OUTPUT_DIR"
        ui_section "GIF to video"
    fi

    if [ -z "$input_path" ]; then
        read -p "$(ui_prompt "File or folder path" "(blank = $default_dir)")" input_path
        [ -z "$input_path" ] && input_path="$default_dir"
    fi

    if [ -f "$input_path" ]; then
        # Single-file operation: ignore completion markers and do not update them.
        TRACK_COMPLETION_MARKERS=0
        if [ "$mode" = "to-gif" ]; then process_file "$input_path" || true
        else process_gif_file "$input_path" || true; fi
    elif [ -d "$input_path" ]; then
        # Directory batch operation: use completion markers for resume/skip behavior.
        TRACK_COMPLETION_MARKERS=1
        if [ "$mode" = "to-gif" ]; then process_all_files "$input_path" || true
        else process_all_gif_files "$input_path" || true; fi
    else
        ui_err "File or folder doesn't exist:"
        ui_note "$input_path"
        return 1
    fi

    ui_section "Done"
    ui_kv "Converted" "${COLOR_GREEN}$SUCCEEDED${COLOR_RESET}"
    ui_kv "Skipped" "$SKIPPED ${COLOR_GRAY}(already done)${COLOR_RESET}"
    if [ "$FAILED" -gt 0 ]; then
        ui_kv "Failed" "${COLOR_RED}$FAILED${COLOR_RESET}"
    else
        ui_kv "Failed" "0"
    fi
}

# ===========================================================================
# INTERACTIVE MENU
# ===========================================================================
show_menu() {
    clear
    local start_display="${GIF_START_TIME:-From start}"
    local dur_display="Full length"
    [ -n "$GIF_DURATION" ] && dur_display="${GIF_DURATION}s"
    local speed_display="$GIF2VIDEO_PRESET"
    if [ "$GIF2VIDEO_CODEC" = "libvpx-vp9" ]; then
        speed_display="${GIF2VIDEO_VP9_DEADLINE} / cpu ${GIF2VIDEO_VP9_CPU_USED}"
    fi
    local width_display="Dynamic (source)"
    [ "$GIF2VIDEO_WIDTH_MODE" = "fixed" ] && width_display="${GIF2VIDEO_WIDTH} px wide"
    local g2v_fps_display="Dynamic (source)"
    [ "$GIF2VIDEO_FPS_MODE" = "fixed" ] && g2v_fps_display="${GIF2VIDEO_FPS} FPS"
    local gif_fps_display="Dynamic (source)"
    [ "$GIF_FPS_MODE" = "fixed" ] && gif_fps_display="${GIF_FPS} FPS"
    local gif_width_display="Dynamic (source)"
    [ "$GIF_WIDTH_MODE" = "fixed" ] && gif_width_display="${GIF_WIDTH} px wide"

    ui_banner "Video / GIF Converter" "Videos to GIFs and back"

    ui_section "Video to GIF"
    ui_row 1  "GIF FPS"      "$gif_fps_display"
    ui_row 2  "GIF width"    "$gif_width_display"
    ui_row 3  "Trim start"   "$start_display"
    ui_row 4  "Trim length"  "$dur_display"
    ui_row 5  "Dither"       "$GIF_DITHER"
    ui_row 6  "Palette"      "$GIF_PALETTE_STATS_MODE"

    ui_section "GIF to video"
    ui_row 7  "Format"       "$GIF2VIDEO_FORMAT ($GIF2VIDEO_CODEC)"
    ui_row 8  "Quality CRF"  "$GIF2VIDEO_CRF"
    ui_row 9  "Speed"        "$speed_display"
    ui_row 10 "Pixel fmt"    "$GIF2VIDEO_PIX_FMT"
    ui_row 11 "Resolution"   "$width_display"
    ui_row 12 "Output FPS"   "$g2v_fps_display"

    ui_section "General"
    ui_row 15 "CPU threads"  "$FFMPEG_THREADS"

    ui_section "Convert"
    echo -e "   ${COLOR_GREEN}[13]${COLOR_RESET} Convert video(s) → GIF"
    echo -e "   ${COLOR_GREEN}[14]${COLOR_RESET} Convert GIF(s) → video"
    echo -e "   ${COLOR_RED}[0]${COLOR_RESET}  Exit"
    echo ""
}

process_menu_choice() {
    local choice="$1"
    local val cur scale crf_max crf_hint cores

    case "$choice" in
        1)
            ui_section "GIF FPS"
            ui_note "dynamic/auto follows each input video's frame rate."
            ui_note "A number from 1-120 uses a fixed GIF frame rate."
            [ "$GIF_FPS_MODE" = "dynamic" ] && cur="dynamic" || cur="$GIF_FPS"
            read -r -p "$(ui_prompt "GIF FPS" "(dynamic/auto or 1-120, current: $cur)")" val
            case "${val,,}" in
                dynamic|auto)
                    GIF_FPS_MODE="dynamic"
                    ui_ok "GIF FPS: dynamic (source frame rate)"
                    ;;
                "") ;;
                *)
                    if [[ "$val" =~ ^[0-9]+$ ]] && [ "$val" -ge 1 ] && [ "$val" -le 120 ]; then
                        GIF_FPS="$val"
                        GIF_FPS_MODE="fixed"
                        ui_ok "GIF FPS: fixed $GIF_FPS"
                    else
                        ui_err "Invalid value — use dynamic/auto or an FPS from 1-120"
                    fi
                    ;;
            esac
            ;;
        2)
            ui_section "GIF width"
            ui_note "dynamic/auto uses each input video's original width."
            ui_note "An even number (2-7680) uses a fixed width."
            [ "$GIF_WIDTH_MODE" = "dynamic" ] && cur="dynamic" || cur="$GIF_WIDTH"
            read -r -p "$(ui_prompt "GIF width" "(dynamic/auto or pixels, current: $cur)")" val
            case "${val,,}" in
                dynamic|auto)
                    GIF_WIDTH_MODE="dynamic"
                    ui_ok "GIF width: dynamic (source width)"
                    ;;
                "") ;;
                *)
                    if [[ "$val" =~ ^[0-9]+$ ]] && [ "$val" -ge 2 ] && [ "$val" -le 7680 ] && (( val % 2 == 0 )); then
                        GIF_WIDTH="$val"
                        GIF_WIDTH_MODE="fixed"
                        ui_ok "GIF width: fixed ${GIF_WIDTH}px"
                    else
                        ui_err "Invalid value — use dynamic/auto or an even width from 2-7680"
                    fi
                    ;;
            esac
            ;;
        3)
            ui_section "Trim start"
            read -r -p "$(ui_prompt "Trim start" "(HH:MM:SS or seconds, 'clear' to reset)")" val
            if [ "$val" = "clear" ]; then GIF_START_TIME=""; ui_ok "Trim start cleared"
            elif [ -n "$val" ]; then GIF_START_TIME="$val"; ui_ok "Trim start set to $val"; fi
            ;;
        4)
            ui_section "Trim length"
            read -r -p "$(ui_prompt "Trim length in seconds" "('clear' to reset)")" val
            if [ "$val" = "clear" ]; then GIF_DURATION=""; ui_ok "Trim length cleared"
            elif [[ "$val" =~ ^[0-9]+([.][0-9]+)?$ ]] && awk -v n="$val" 'BEGIN { exit !(n > 0) }'; then
                GIF_DURATION="$val"; ui_ok "Trim length set to ${val}s"
            elif [ -n "$val" ]; then ui_err "Invalid duration"; fi
            ;;
        5)
            ui_section "GIF dither"
            ui_opt 1 "Bayer" "fast, patterned; scale 0-5"
            ui_opt 2 "Floyd-Steinberg"
            ui_opt 3 "Sierra 2"
            ui_opt 4 "Sierra 2-4A"
            ui_opt 5 "Heckbert"
            ui_opt 6 "None"
            echo ""
            read -r -p "$(ui_prompt "Select dither" "[1-6]")" val
            case "$val" in
                1)
                    read -r -p "$(ui_prompt "Bayer scale" "[0-5, default 3]")" scale
                    [ -z "$scale" ] && scale=3
                    if [[ "$scale" =~ ^[0-5]$ ]]; then GIF_DITHER="bayer:bayer_scale=$scale"; ui_ok "Dither: Bayer (scale $scale)"
                    else ui_err "Invalid Bayer scale"; fi
                    ;;
                2) GIF_DITHER="floyd_steinberg"; ui_ok "Dither: Floyd-Steinberg" ;;
                3) GIF_DITHER="sierra2"; ui_ok "Dither: Sierra 2" ;;
                4) GIF_DITHER="sierra2_4a"; ui_ok "Dither: Sierra 2-4A" ;;
                5) GIF_DITHER="heckbert"; ui_ok "Dither: Heckbert" ;;
                6) GIF_DITHER="none"; ui_ok "Dither: none" ;;
                *) [ -n "$val" ] && ui_err "Invalid choice" ;;
            esac
            ;;
        6)
            ui_section "Palette statistics"
            ui_opt 1 "diff" "focus on frame-to-frame changes"
            ui_opt 2 "full" "statistics from all frames"
            echo ""
            read -r -p "$(ui_prompt "Select mode" "[1-2]")" val
            case "$val" in
                1) GIF_PALETTE_STATS_MODE="diff"; ui_ok "Palette statistics: diff" ;;
                2) GIF_PALETTE_STATS_MODE="full"; ui_ok "Palette statistics: full" ;;
                *) [ -n "$val" ] && ui_err "Invalid choice" ;;
            esac
            ;;
        7)
            ui_section "Output format"
            ui_opt 1 "MP4" "H.264 / libx264"
            ui_opt 2 "WebM" "VP9 / libvpx-vp9"
            ui_opt 3 "MKV" "H.264 / libx264"
            echo ""
            read -r -p "$(ui_prompt "Select format" "[1-3]")" val
            case "$val" in
                1) GIF2VIDEO_FORMAT="mp4"; GIF2VIDEO_CODEC="libx264"; ui_ok "Format: MP4 (H.264)" ;;
                2) GIF2VIDEO_FORMAT="webm"; GIF2VIDEO_CODEC="libvpx-vp9"; ui_ok "Format: WebM (VP9)" ;;
                3) GIF2VIDEO_FORMAT="mkv"; GIF2VIDEO_CODEC="libx264"; ui_ok "Format: MKV (H.264)" ;;
                *) [ -n "$val" ] && ui_err "Invalid choice" ;;
            esac
            if [ "$GIF2VIDEO_CODEC" = "libvpx-vp9" ] && [ "$GIF2VIDEO_CRF" -gt 63 ]; then GIF2VIDEO_CRF=30
            elif [ "$GIF2VIDEO_CODEC" = "libx264" ] && [ "$GIF2VIDEO_CRF" -gt 51 ]; then GIF2VIDEO_CRF=18; fi
            ;;
        8)
            ui_section "Quality (CRF)"
            crf_max=51
            crf_hint="H.264 CRF 0-51; lower generally means higher quality and larger files"
            if [ "$GIF2VIDEO_CODEC" = "libvpx-vp9" ]; then
                crf_max=63; crf_hint="VP9 CRF 0-63; lower generally means higher quality and larger files"
            fi
            ui_note "$crf_hint"
            read -r -p "$(ui_prompt "New CRF" "(0-$crf_max, current: $GIF2VIDEO_CRF)")" val
            if [[ "$val" =~ ^[0-9]+$ ]] && [ "$val" -ge 0 ] && [ "$val" -le "$crf_max" ]; then
                GIF2VIDEO_CRF="$val"; ui_ok "CRF set to $val"
            elif [ -n "$val" ]; then ui_err "Invalid CRF for $GIF2VIDEO_CODEC"; fi
            ;;
        9)
            ui_section "Encoder speed"
            if [ "$GIF2VIDEO_CODEC" = "libvpx-vp9" ]; then
                ui_note "VP9 deadline: good, best, realtime"
                read -r -p "$(ui_prompt "Deadline" "(current: $GIF2VIDEO_VP9_DEADLINE)")" val
                case "$val" in good|best|realtime) GIF2VIDEO_VP9_DEADLINE="$val"; ui_ok "Deadline: $val" ;; "") ;; *) ui_err "Invalid deadline"; val="invalid" ;; esac
                if [ "$val" != "invalid" ]; then
                    read -r -p "$(ui_prompt "CPU-used" "[0-8, lower is slower, current: $GIF2VIDEO_VP9_CPU_USED]")" val
                    if [ -z "$val" ]; then :
                    elif [[ "$val" =~ ^[0-8]$ ]]; then GIF2VIDEO_VP9_CPU_USED="$val"; ui_ok "CPU-used: $val"
                    else ui_err "Invalid CPU-used value"; fi
                fi
            else
                ui_note "1 ultrafast · 2 superfast · 3 veryfast"
                ui_note "4 faster · 5 fast · 6 medium"
                ui_note "7 slow · 8 slower · 9 veryslow"
                read -r -p "$(ui_prompt "Select H.264 preset" "[1-9, current: $GIF2VIDEO_PRESET]")" val
                case "$val" in
                    1) GIF2VIDEO_PRESET="ultrafast" ;; 2) GIF2VIDEO_PRESET="superfast" ;;
                    3) GIF2VIDEO_PRESET="veryfast" ;; 4) GIF2VIDEO_PRESET="faster" ;;
                    5) GIF2VIDEO_PRESET="fast" ;; 6) GIF2VIDEO_PRESET="medium" ;;
                    7) GIF2VIDEO_PRESET="slow" ;; 8) GIF2VIDEO_PRESET="slower" ;;
                    9) GIF2VIDEO_PRESET="veryslow" ;;
                    *) [ -n "$val" ] && ui_err "Invalid choice" ;;
                esac
                [[ "$val" =~ ^[1-9]$ ]] && ui_ok "Preset: $GIF2VIDEO_PRESET"
            fi
            ;;
        10)
            ui_section "Pixel format"
            ui_opt 1 "yuv420p" "widest compatibility"
            ui_opt 2 "yuv444p" "higher chroma detail; compatibility varies"
            ui_opt 3 "yuv420p10le" "10-bit; encoder support required"
            echo ""
            read -r -p "$(ui_prompt "Select pixel format" "[1-3]")" val
            case "$val" in
                1) GIF2VIDEO_PIX_FMT="yuv420p"; ui_ok "Pixel format: yuv420p" ;;
                2) GIF2VIDEO_PIX_FMT="yuv444p"; ui_ok "Pixel format: yuv444p" ;;
                3) GIF2VIDEO_PIX_FMT="yuv420p10le"; ui_ok "Pixel format: yuv420p10le" ;;
                *) [ -n "$val" ] && ui_err "Invalid choice" ;;
            esac
            ;;
        11)
            ui_section "Output resolution"
            ui_note "dynamic/auto preserves the GIF's original resolution."
            ui_note "An even width (2-7680) uses a fixed width."
            [ "$GIF2VIDEO_WIDTH_MODE" = "dynamic" ] && cur="dynamic" || cur="$GIF2VIDEO_WIDTH"
            read -r -p "$(ui_prompt "Output resolution" "(dynamic/auto or width, current: $cur)")" val
            case "${val,,}" in
                dynamic|auto)
                    GIF2VIDEO_WIDTH_MODE="dynamic"
                    ui_ok "Resolution: dynamic (source)"
                    ;;
                "") ;;
                *)
                    if [[ "$val" =~ ^[0-9]+$ ]] && [ "$val" -ge 2 ] && [ "$val" -le 7680 ] && (( val % 2 == 0 )); then
                        GIF2VIDEO_WIDTH="$val"
                        GIF2VIDEO_WIDTH_MODE="fixed"
                        ui_ok "Resolution: fixed ${GIF2VIDEO_WIDTH}px wide"
                    else
                        ui_err "Invalid value — use dynamic/auto or an even width from 2-7680"
                    fi
                    ;;
            esac
            ;;
        12)
            ui_section "Output FPS"
            ui_note "dynamic/auto preserves the GIF's original frame timing."
            ui_note "A number from 1-120 uses a fixed output FPS."
            [ "$GIF2VIDEO_FPS_MODE" = "dynamic" ] && cur="dynamic" || cur="$GIF2VIDEO_FPS"
            read -r -p "$(ui_prompt "Output FPS" "(dynamic/auto or 1-120, current: $cur)")" val
            case "${val,,}" in
                dynamic|auto)
                    GIF2VIDEO_FPS_MODE="dynamic"
                    ui_ok "Output FPS: dynamic (source GIF timing)"
                    ;;
                "") ;;
                *)
                    if [[ "$val" =~ ^[0-9]+$ ]] && [ "$val" -ge 1 ] && [ "$val" -le 120 ]; then
                        GIF2VIDEO_FPS="$val"
                        GIF2VIDEO_FPS_MODE="fixed"
                        ui_ok "Output FPS: fixed $GIF2VIDEO_FPS"
                    else
                        ui_err "Invalid value — use dynamic/auto or an FPS from 1-120"
                    fi
                    ;;
            esac
            ;;
        15)
            ui_section "CPU threads"
            cores=$(nproc 2>/dev/null || echo "?")
            ui_note "Threads ffmpeg may use. Lower = cooler and lighter, but slower."
            ui_note "This device reports $cores core(s)."
            read -r -p "$(ui_prompt "CPU threads" "(1-64, current: $FFMPEG_THREADS)")" val
            if [[ "$val" =~ ^[0-9]+$ ]] && [ "$((10#$val))" -ge 1 ] && [ "$((10#$val))" -le 64 ]; then
                FFMPEG_THREADS=$((10#$val))
                set_thread_args
                ui_ok "CPU threads set to $FFMPEG_THREADS"
            elif [ -n "$val" ]; then
                ui_err "Invalid value — use a whole number from 1-64"
            fi
            ;;
        13) run_conversion "to-gif" ;;
        14) run_conversion "to-video" ;;
        0) ui_ok "Bye!"; exit 0 ;;
        *) ui_err "Invalid option" ;;
    esac

    echo ""
    read -r -p "$(printf '%b' " ${COLOR_GRAY}Press Enter to continue…${COLOR_RESET} ")" _
}

# ===========================================================================
# MAIN
# ===========================================================================
mkdir -p "$LOG_DIR" "$LOG_DIR_G2V" "$COMPLETED_DIR"
check_dependencies

if [ $# -ge 1 ]; then
    case "$1" in
        to-gif|v2g)
            run_conversion "to-gif" "${2:-}"
            ;;
        to-video|g2v)
            run_conversion "to-video" "${2:-}"
            ;;
        *)
            INPUT_PATH="$1"
            if [ -f "$INPUT_PATH" ]; then
                case "$INPUT_PATH" in
                    *.[Gg][Ii][Ff]) run_conversion "to-video" "$INPUT_PATH" ;;
                    *)              run_conversion "to-gif" "$INPUT_PATH" ;;
                esac
            elif [ -d "$INPUT_PATH" ]; then
                run_conversion "to-gif" "$INPUT_PATH"
            else
                ui_err "File or folder doesn't exist:"
                ui_note "$INPUT_PATH"
                exit 1
            fi
            ;;
    esac
    [ "$FAILED" -gt 0 ] && exit 1
    exit 0
fi

# No arguments — interactive menu
while true; do
    show_menu
    if ! read -p "$(ui_prompt "Select option" "[0-15]")" menu_choice; then
        echo ""
        ui_warn "Input closed — exiting"
        break
    fi
    process_menu_choice "$menu_choice"
done
