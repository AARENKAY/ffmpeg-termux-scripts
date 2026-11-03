#!/bin/bash

# ==================== LOADING GUARD ====================
if [[ -n "${_LIB_PROBE_LOADED+x}" ]]; then
    return 0  # Already loaded, skip
fi
readonly _LIB_PROBE_LOADED=true  # Mark as loaded
# ==================================================

# ===========================================================================
# PROBE MODULE - MEDIA ANALYSIS FUNCTIONS
# ===========================================================================


# Non-negative integer or 0. ffprobe prints "N/A" for unknown values, and feeding
# that to $(( )) / [[ -le ]] aborts the whole script ("N: unbound variable").
_probe_int() {
    if [[ "${1:-}" =~ ^[0-9]+$ ]]; then printf '%s' "$1"; else printf '0'; fi
}

# File size in bytes (stat, then mediainfo, ffprobe, du). Always prints an integer.
_probe_file_size() {
    local f="$1" sz="" kb=""
    sz=$(stat -c%s -- "$f" 2>/dev/null) || sz=""
    if ! [[ "$sz" =~ ^[0-9]+$ ]] || [ "$sz" -le 0 ]; then
        sz=""
        if command -v mediainfo >/dev/null 2>&1; then
            sz=$(mediainfo --Inform="General;%FileSize%" "$f" 2>/dev/null </dev/null | head -n1) || sz=""
        fi
    fi
    if ! [[ "$sz" =~ ^[0-9]+$ ]] || [ "$sz" -le 0 ]; then
        sz=$(ffprobe -v error -show_entries format=size -of default=noprint_wrappers=1:nokey=1 "$f" 2>/dev/null </dev/null | head -n1) || sz=""
    fi
    if ! [[ "$sz" =~ ^[0-9]+$ ]] || [ "$sz" -le 0 ]; then
        kb=$(du -k -- "$f" 2>/dev/null | awk '{print $1}') || kb=""
        if [[ "$kb" =~ ^[0-9]+$ ]] && [ "$kb" -gt 0 ]; then sz=$((kb * 1024)); else sz=0; fi
    fi
    printf '%s' "$sz"
}

# Stream bitrate in bits/s, using the same logic as the frame extractor's probe:
#   1) ffprobe stream=bit_rate (first line only)
#   2) ffprobe stream_tags=BPS  (MKV/WebM store the real bitrate here; the plain
#      stream bit_rate is N/A for most Opus/AAC/AV1 tracks in Matroska)
#   3) mediainfo, if installed
#   4) audio only: packet sizes / duration (works with no extra tools)
# Prints an integer in bits/s, or nothing when unknown.   Usage: _probe_stream_bitrate FILE v:0|a:0
_probe_stream_bitrate() {
    local file="$1" sel="$2" kind="${2%%:*}" br="" mi_kind="Video"
    [ "$kind" = "a" ] && mi_kind="Audio"
    br=$(ffprobe -v error -select_streams "$sel" -show_entries stream=bit_rate \
        -of default=noprint_wrappers=1:nokey=1 "$file" 2>/dev/null </dev/null | head -n 1)
    if ! [[ "$br" =~ ^[0-9]+([.][0-9]+)?$ ]] || [ "$br" = "0" ]; then
        br=$(ffprobe -v error -select_streams "$sel" -show_entries stream_tags=BPS \
            -of default=noprint_wrappers=1:nokey=1 "$file" 2>/dev/null </dev/null | head -n 1)
    fi
    if ! [[ "$br" =~ ^[0-9]+([.][0-9]+)?$ ]] || [ "$br" = "0" ]; then
        br=""
        if command -v mediainfo >/dev/null 2>&1; then
            br=$(mediainfo --Inform="${mi_kind};%BitRate%" "$file" 2>/dev/null </dev/null | head -n 1)
        fi
    fi
    # 4) Last resort (audio only): sum the stream's packet sizes / duration.
    #    Needed for ffmpeg-written MKV/WebM, which carry neither bit_rate nor a BPS tag.
    #    Reads packet headers only (no decoding), so it stays reasonably quick.
    if [ "$kind" = "a" ] && { ! [[ "$br" =~ ^[0-9]+([.][0-9]+)?$ ]] || [ "$br" = "0" ]; }; then
        local dur_s=""
        dur_s=$(ffprobe -v error -show_entries format=duration \
            -of default=noprint_wrappers=1:nokey=1 "$file" 2>/dev/null </dev/null | head -n 1)
        br=$(ffprobe -v error -select_streams "$sel" -show_entries packet=size \
            -of csv=p=0 "$file" 2>/dev/null </dev/null | awk -v d="$dur_s" \
            '{ s += $1 } END { if (d+0 > 0 && s > 0) printf "%.0f", s*8/d }')
    fi
    if [[ "$br" =~ ^[0-9]+([.][0-9]+)?$ ]] && awk -v b="$br" 'BEGIN{exit !(b>0)}'; then
        awk -v b="$br" 'BEGIN{printf "%.0f", b}'
    fi
    return 0
}

# Audio bitrate in kbps -> audio_bitrate / audio_bitrate_kbps ("N/A" when unknown)
_probe_audio_bitrate() {
    local file="$1" ab=""
    ab=$(_probe_stream_bitrate "$file" "a:0")
    if [[ "$ab" =~ ^[0-9]+$ ]] && (( ab > 0 )); then
        audio_bitrate="$ab"
        audio_bitrate_kbps=$(( (ab + 500) / 1000 ))
    else
        audio_bitrate=""
        audio_bitrate_kbps="N/A"
    fi
    return 0
}

# Video-stream bitrate in kbps -> video_bitrate_kbps  (container bitrate includes audio)
# Order: ffprobe stream value, mediainfo, then container bitrate minus audio, then container.
_probe_video_bitrate() {   # file container_kbps audio_kbps
    local file="$1" container_kbps="${2:-0}" audio_kbps="${3:-N/A}" vb=""
    vb=$(_probe_stream_bitrate "$file" "v:0")
    if [[ "$vb" =~ ^[0-9]+$ ]] && (( vb > 0 )); then
        video_bitrate_kbps=$(( (vb + 500) / 1000 ))
    elif [[ "$audio_kbps" =~ ^[0-9]+$ ]] && (( container_kbps > audio_kbps )); then
        video_bitrate_kbps=$(( container_kbps - audio_kbps ))
    else
        video_bitrate_kbps="$container_kbps"
    fi
    return 0
}

# Probe input file information
probe_input_info() {
    local input_file="$1"
    local filename=$(basename -- "$input_file")
    
    declare -g width height duration size_bytes size_human bitrate bitrate_kbps video_bitrate_kbps
    declare -g audio_bitrate audio_bitrate_kbps file_ext format_disp codec_name codec_long
    declare -g audio_codec_name audio_codec_long input_pix_fmt

    width=$(ffprobe -v error -select_streams v:0 -show_entries stream=width -of csv=p=0 "$input_file" 2>/dev/null || echo 0)
    height=$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of csv=p=0 "$input_file" 2>/dev/null || echo 0)
    duration=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$input_file" 2>/dev/null </dev/null | head -n1) || duration=""
    if ! [[ "$duration" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then duration=""; fi
    
    size_bytes=$(_probe_file_size "$input_file")
    size_human=$(format_size "$size_bytes")
    
    bitrate=$(ffprobe -v error -show_entries format=bit_rate -of default=noprint_wrappers=1:nokey=1 "$input_file" 2>/dev/null || echo 0)
    bitrate=$(_probe_int "$bitrate")
    bitrate_kbps=$((bitrate / 1000))
    
    _probe_audio_bitrate "$input_file"
    _probe_video_bitrate "$input_file" "$bitrate_kbps" "$audio_bitrate_kbps"
    
    file_ext="${filename##*.}"
    format_disp=$(echo "$file_ext" | tr '[:lower:]' '[:upper:]')
    
    codec_name=$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of default=noprint_wrappers=1:nokey=1 "$input_file" 2>/dev/null || echo "Unknown")
    codec_long=$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_long_name -of default=noprint_wrappers=1:nokey=1 "$input_file" 2>/dev/null || echo "Unknown")
    
    audio_codec_name=$(ffprobe -v error -select_streams a:0 -show_entries stream=codec_name -of default=noprint_wrappers=1:nokey=1 "$input_file" 2>/dev/null || echo "Unknown")
    audio_codec_long=$(ffprobe -v error -select_streams a:0 -show_entries stream=codec_long_name -of default=noprint_wrappers=1:nokey=1 "$input_file" 2>/dev/null || echo "Unknown")
    
    input_pix_fmt=$(ffprobe -v error -select_streams v:0 -show_entries stream=pix_fmt -of csv=p=0 "$input_file" 2>/dev/null || echo "unknown")
    if [[ "$input_pix_fmt" == *10le* ]]; then
        input_pix_fmt_disp="10-bit"
    else
        input_pix_fmt_disp="8-bit"
    fi
}

# Get compatible pixel format for codec
get_compatible_pix_fmt() {
    case "$PIXFMT_MODE" in
        "8-bit") echo "yuv420p" ;;
        "10-bit") echo "yuv420p10le" ;;
        *) echo "" ;;
    esac
}

# Check video file integrity
# Usage: check_video_integrity FILE [EXPECTED_DURATION] [SOURCE_FILE]
# Returns 0 = OK, 1 = problem. Existing two-argument callers keep working.
# Sets INTEGRITY_REASON (OK|MISSING|EMPTY|UNREADABLE|NO_VIDEO|NO_AUDIO|DURATION) and
# INTEGRITY_DETAIL (human readable). With SOURCE_FILE, stream presence is checked too:
# the output must have a video stream if the source has one, and audio if the source has audio.
# Unavailable metadata is never treated as zero: an unknown duration skips the duration test.
declare -g INTEGRITY_REASON="OK"
declare -g INTEGRITY_DETAIL=""
check_video_integrity() {
    local file="$1"
    local expected_duration="${2:-0}"  # Default to 0 if not provided
    local source_file="${3:-}"
    INTEGRITY_REASON="OK"; INTEGRITY_DETAIL=""

    local soft_tol=$(awk -v dur="$expected_duration" 'BEGIN {print (dur > 3600) ? 2.0 : 0.5}')

    if [ ! -f "$file" ]; then
        INTEGRITY_REASON="MISSING"; INTEGRITY_DETAIL="output file does not exist"
        return 1
    fi
    local fsize
    fsize=$(stat -c%s "$file" 2>/dev/null || echo 0)
    if [ "${fsize:-0}" -lt 1024 ]; then
        INTEGRITY_REASON="EMPTY"; INTEGRITY_DETAIL="output file is empty or only ${fsize:-0} bytes"
        return 1
    fi

    if ! actual_duration=$(ffprobe -v error -show_entries format=duration \
        -of default=noprint_wrappers=1:nokey=1 "$file" 2>/dev/null); then
        INTEGRITY_REASON="UNREADABLE"; INTEGRITY_DETAIL="ffprobe cannot open the output"
        return 1
    fi

    # Stream presence (cheap: header/stream info only, no decoding)
    if [ -n "$source_file" ] && [ -f "$source_file" ]; then
        local src_v src_a out_v out_a
        src_v=$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_type -of csv=p=0 "$source_file" 2>/dev/null </dev/null | head -n1) || src_v=""
        src_a=$(ffprobe -v error -select_streams a:0 -show_entries stream=codec_type -of csv=p=0 "$source_file" 2>/dev/null </dev/null | head -n1) || src_a=""
        out_v=$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_type -of csv=p=0 "$file" 2>/dev/null </dev/null | head -n1) || out_v=""
        out_a=$(ffprobe -v error -select_streams a:0 -show_entries stream=codec_type -of csv=p=0 "$file" 2>/dev/null </dev/null | head -n1) || out_a=""
        if [ -n "$src_v" ] && [ -z "$out_v" ]; then
            INTEGRITY_REASON="NO_VIDEO"; INTEGRITY_DETAIL="output has no video stream"
            return 1
        fi
        if [ -n "$src_a" ] && [ -z "$out_a" ]; then
            INTEGRITY_REASON="NO_AUDIO"; INTEGRITY_DETAIL="source has audio but the output has none"
            return 1
        fi
    fi

    # Unavailable duration is "unknown", not zero
    if ! [[ "$actual_duration" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        INTEGRITY_DETAIL="duration metadata unavailable - duration check skipped"
        return 0
    fi

    # Normalize durations to 3 decimal places
    actual_duration=$(awk -v d="$actual_duration" 'BEGIN {printf "%.3f", d}')
    expected_duration=$(awk -v d="$expected_duration" 'BEGIN {printf "%.3f", d}')

    # If no valid expected duration, treat as success
    if (( $(awk -v e="$expected_duration" 'BEGIN {print (e <= 0)}') )); then
        return 0
    fi

    # Compare durations
    if ! awk -v a="$actual_duration" -v e="$expected_duration" -v soft="$soft_tol" '
    BEGIN {
        diff = (a > e) ? (a - e) : (e - a)
        exit (diff <= soft) ? 0 : 1
    }'; then
        INTEGRITY_REASON="DURATION"
        INTEGRITY_DETAIL="output duration ${actual_duration}s vs source ${expected_duration}s"
        return 1
    fi
    return 0
}

# probe output file info
probe_output_info() {
    local output_file="$1"
    local filename=$(basename -- "$output_file")

    declare -g width height duration bitrate bitrate_kbps video_bitrate_kbps audio_bitrate audio_bitrate_kbps
    declare -g format format_disp codec_name codec_long audio_codec_name audio_codec_long
    declare -g pix_fmt bit_depth orientation res_str file_ext
    declare -g size_bytes size_kb size_human

    width=$(ffprobe -v error -select_streams v:0 -show_entries stream=width -of csv=p=0 "$output_file" 2>/dev/null || echo 0)
    height=$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of csv=p=0 "$output_file" 2>/dev/null || echo 0)
    duration=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$output_file" 2>/dev/null || echo 0)

    size_bytes=$(_probe_file_size "$output_file")
    size_human=$(format_size "$size_bytes")

    bitrate=$(ffprobe -v error -show_entries format=bit_rate -of default=noprint_wrappers=1:nokey=1 "$output_file" 2>/dev/null || echo 0)
    bitrate=$(_probe_int "$bitrate")
    bitrate_kbps=$((bitrate / 1000))

    _probe_audio_bitrate "$output_file"
    _probe_video_bitrate "$output_file" "$bitrate_kbps" "$audio_bitrate_kbps"

    file_ext="${filename##*.}"
    format_disp=$(echo "$file_ext" | tr '[:lower:]' '[:upper:]')

    format=$(ffprobe -v error -show_entries format=format_name -of default=noprint_wrappers=1:nokey=1 "$output_file" 2>/dev/null || echo "Unknown")
    codec_name=$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of default=noprint_wrappers=1:nokey=1 "$output_file" 2>/dev/null || echo "Unknown")
    codec_long=$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_long_name -of default=noprint_wrappers=1:nokey=1 "$output_file" 2>/dev/null || echo "Unknown")

    audio_codec_name=$(ffprobe -v error -select_streams a:0 -show_entries stream=codec_name -of default=noprint_wrappers=1:nokey=1 "$output_file" 2>/dev/null || echo "Unknown")
    audio_codec_long=$(ffprobe -v error -select_streams a:0 -show_entries stream=codec_long_name -of default=noprint_wrappers=1:nokey=1 "$output_file" 2>/dev/null || echo "Unknown")

    pix_fmt=$(ffprobe -v error -select_streams v:0 -show_entries stream=pix_fmt -of csv=p=0 "$output_file" 2>/dev/null || echo "unknown")

    if [[ "$pix_fmt" == *10le* ]]; then
        pix_fmt_out="10-bit"
    else
        pix_fmt_out="8-bit"
    fi
}

# ---------------------------------------------------------------------------
# Frame-rate handling (automatic).  Sets the global array FPS_ARGS and FPS_NOTE.
#   * Constant frame rate source (r_frame_rate ~= avg_frame_rate): no flags, the output
#     keeps the source rate untouched.
#   * Variable frame rate source (the two differ by more than 1%, typical for phone
#     recordings): force a constant rate with "-fps_mode cfr -r N", where N is the average
#     rate snapped to the nearest standard one (23.976 ... 120). Constant timing plays
#     back evenly in software decoders and MKV's millisecond timestamps.
#   * Unusual average rate that matches no standard one: left alone (passthrough).
# FPS_HANDLING=source in the environment (or config) switches this off.
# Usage: _probe_fps_args FILE
# ---------------------------------------------------------------------------
declare -g FPS_HANDLING="${FPS_HANDLING:-auto}"
declare -ga FPS_ARGS=()
declare -g FPS_NOTE=""
_probe_fps_args() {
    local file="$1" r avg pick
    FPS_ARGS=(); FPS_NOTE=""
    if [ "${FPS_HANDLING:-auto}" != "auto" ]; then return 0; fi
    r=$(ffprobe -v error -select_streams v:0 -show_entries stream=r_frame_rate \
        -of default=noprint_wrappers=1:nokey=1 "$file" 2>/dev/null </dev/null | head -n 1)
    avg=$(ffprobe -v error -select_streams v:0 -show_entries stream=avg_frame_rate \
        -of default=noprint_wrappers=1:nokey=1 "$file" 2>/dev/null </dev/null | head -n 1)
    pick=$(awk -v r="$r" -v a="$avg" '
        function val(x,   n, p) { n = split(x, p, "/"); if (n == 2 && p[2] + 0 > 0) return p[1] / p[2]; return x + 0 }
        BEGIN {
            rv = val(r); av = val(a)
            if (rv <= 0 || av <= 0) exit
            d = (rv > av) ? (rv - av) / rv : (av - rv) / av
            if (d <= 0.01) { print "CFR " av; exit }
            n = split("24000/1001 24 25 30000/1001 30 48 50 60000/1001 60 90 100 120000/1001 120", s, " ")
            best = ""; bd = 1
            for (i = 1; i <= n; i++) {
                split(s[i], q, "/"); sv = (q[2] > 0) ? q[1] / q[2] : q[1] + 0
                e = (sv > av) ? (sv - av) / sv : (av - sv) / av
                if (e < bd) { bd = e; best = s[i] }
            }
            if (bd <= 0.03) print "VFR " best " " av
            else print "VFR_UNSNAPPED " av
        }')
    case "$pick" in
        VFR\ *)
            local target avgv
            target=$(echo "$pick" | awk '{print $2}')
            avgv=$(echo "$pick" | awk '{printf "%.2f", $3}')
            FPS_ARGS=(-fps_mode cfr -r "$target")
            FPS_NOTE="variable frame rate source (avg ${avgv} fps) -> constant ${target} fps"
            ;;
        VFR_UNSNAPPED\ *)
            FPS_NOTE="variable frame rate source, no standard rate matches - left unchanged"
            ;;
    esac
    return 0
}
