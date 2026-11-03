#!/bin/bash

# ===========================================================================
# CONFIG MODULE - HELPER FUNCTIONS
# ===========================================================================

# ==================== LOADING GUARD ====================
if [[ -n "${_LIB_CONFIG_LOADED+x}" ]]; then
    return 0  # Already loaded, skip
fi
readonly _LIB_CONFIG_LOADED=true  # Mark as loaded
# ======================================================

# ------------------------------------------------------
# FUNCTION: mark_completed
# Purpose: Creates a completion marker for a file
# ------------------------------------------------------
mark_completed() {
    local input_file="$1"
    local marker_name
    marker_name=$(printf '%s' "$input_file" | sha256sum | awk '{print $1}')
    if ! mkdir -p -- "$COMPLETED_DIR" 2>/dev/null || ! touch -- "$COMPLETED_DIR/$marker_name" 2>/dev/null; then
        echo -e "${COLOR_YELLOW} WARNING: COULD NOT WRITE COMPLETION MARKER IN:${COLOR_RESET} $COMPLETED_DIR" >&2
        return 1
    fi
    return 0
}

# ------------------------------------------------------
# FUNCTION: is_completed
# Purpose: Checks if file was already processed
# Returns: 0 if completed, 1 if not
# ------------------------------------------------------
is_completed() {
    local input_file="$1"
    local marker_name
    marker_name=$(printf '%s' "$input_file" | sha256sum | awk '{print $1}')
    [ -f "$COMPLETED_DIR/$marker_name" ] && return 0
    return 1
}

#Max bitrate validation
validate_bitrate_limits() {
    local codec="$1"
    local maxrate="$2"
    local bufsize="$3"
    
    # Reject anything that is not <digits><k|M> (also protects the arithmetic below)
    if ! [[ "$maxrate" =~ ^[0-9]+[kM]$ && "$bufsize" =~ ^[0-9]+[kM]$ ]]; then
        echo -e " ${COLOR_YELLOW} MAXRATE/BUFSIZE MUST LOOK LIKE 800k OR 2M${COLOR_RESET}"
        return 1
    fi

    # Extract numeric value and unit
    local maxrate_val=${maxrate%[kM]}
    local maxrate_unit=${maxrate: -1}
    local bufsize_val=${bufsize%[kM]}
    local bufsize_unit=${bufsize: -1}
    
    # Convert to kbps for comparison
    if [[ "$maxrate_unit" == "M" ]]; then
        maxrate_val=$((maxrate_val * 1000))
    fi
    if [[ "$bufsize_unit" == "M" ]]; then
        bufsize_val=$((bufsize_val * 1000))
    fi
    
    case "$codec" in
        libsvtav1|libaom-av1)
            # AV1 codecs work best with moderate bitrates
            if (( maxrate_val > 2000 )); then
                echo -e "${COLOR_YELLOW} AV1 CODECS TYPICALLY DON'T BENEFIT FROM MAXRATE > 2000k${COLOR_RESET}"
                return 1
            fi
            ;;
        libx264)
            # H.264 can handle higher bitrates
            if (( maxrate_val > 5000 )); then
                echo -e " ${COLOR_YELLOW} VERY HIGH MAXRATE FOR H.264 MAY CAUSE QUALITY ISSUES${COLOR_RESET}"
                return 1
            fi
            ;;
        libx265)
            # H.265/HEVC is more efficient
            if (( maxrate_val > 3000 )); then
                echo -e " ${COLOR_YELLOW} HEVC TYPICALLY DOESN'T NEED MAXRATE > 3000k${COLOR_RESET}"
                return 1
            fi
            ;;
        libvpx*)
            # VP8/VP9 have specific recommendations
            if (( maxrate_val > 1500 )); then
                echo -e " ${COLOR_YELLOW} VPx CODECS WORK BEST With MAXRATE ≤ 1500k${COLOR_RESET}"
                return 1
            fi
            ;;
    esac
    
    # Check bufsize is reasonable compared to maxrate
    local buf_ratio
    buf_ratio=$(awk -v buf="$bufsize_val" -v max="$maxrate_val" 'BEGIN { if (max > 0) printf "%.1f", buf/max; else printf "0.0" }')
    if awk -v r="$buf_ratio" 'BEGIN { exit !(r < 1.2) }'; then
        echo -e " ${COLOR_YELLOW} BUFSIZE SHOULD TYPICALLY BE ≥1.2x MAXRATE (CURRENTLY $buf_ratio)${COLOR_RESET}"
        return 1
    elif awk -v r="$buf_ratio" 'BEGIN { exit !(r > 2.5) }'; then
        echo -e " ${COLOR_YELLOW} BUFSIZE SHOULD TYPICALLY BE ≤2.5x MAXRATE (CURRENTLY $buf_ratio)${COLOR_RESET}"
        return 1
    fi
    
    return 0
}

# Combined get_filters(), determine_scaling(), and get_compatible_pix_fmt() into one function
get_scaling_and_filters() {
    local width="$1"
    local height="$2"
    local input_pix_fmt="$3"
    local -n scale_filter_ref="$4"
    local -n scale_info_ref="$5"
    local -n vf_args_ref="$6"
    local -n pix_fmt_out_ref="$7"
    local res_str orientation

    if [[ -z "$width" || -z "$height" || "$width" -eq 0 || "$height" -eq 0 ]]; then
        res_str="Audio Only"
        orientation="n/a"
        scale_filter_ref=""
        scale_info_ref="No scaling (audio-only)"
        pix_fmt_out_ref=""
        vf_args_ref=()
        return
    else
        if (( width > height )); then 
            orientation="landscape"
        else 
            orientation="portrait"
        fi
        res_str="${width}x${height} (${orientation})"
    fi

    echo -e "${COLOR_YELLOW} OUTPUT PIXEL FORMAT SET:${COLOR_RESET} $PIXFMT_MODE" | tee >(clean_output >> "$LOG_FILE")
    sleep 1

    # Get compatible pixel format (replaces get_compatible_pix_fmt)
    case "$PIXFMT_MODE" in
        "8-bit") pix_fmt_out_ref="yuv420p" ;;
        "10-bit") pix_fmt_out_ref="yuv420p10le" ;;
        *) pix_fmt_out_ref="" ;;
    esac

    # Initialize reference variables
    scale_filter_ref=""
    scale_info_ref="OFF (Keeping Original)"
    
    # Determine scaling based on SCALING_MODE
    local width_even=$((width - width % 2))
    local height_even=$((height - height % 2))

    # If scaling is OFF, do not apply any scaling
    if [[ "$SCALING_MODE" == "OFF" ]]; then
        echo -e "${COLOR_YELLOW} SCALING:${COLOR_RESET} $scale_info_ref"
    elif [[ "$SCALING_MODE" == "720P" ]]; then
	    # Scale to 720p (normalize to 720p)
	    if [ "$height_even" -ne 720 ]; then
	        scale_filter_ref="scale=-2:720:flags=lanczos"
	        if [ "$height_even" -lt 720 ]; then
	            scale_info_ref="Upscaling from ${height}p to 720p"
	        else
	            scale_info_ref="Downscaling from ${height}p to 720p"
	        fi
	        echo -e "${COLOR_YELLOW} SCALING:${COLOR_RESET} $scale_info_ref"
	    else
	        scale_info_ref="Already 720p"
	        echo -e "${COLOR_YELLOW} NO SCALING NEEDED:${COLOR_RESET} $scale_info_ref"
	    fi
    elif [[ "$SCALING_MODE" == "1080P" ]]; then
	    # Scale to 1080p (normalize to 1080p)
	    if [ "$height_even" -ne 1080 ]; then
	        scale_filter_ref="scale=-2:1080:flags=lanczos"
	        if [ "$height_even" -lt 1080 ]; then
	            scale_info_ref="Upscaling from ${height}p to 1080p"
	        else
	            scale_info_ref="Downscaling from ${height}p to 1080p"
	        fi
	        echo -e "${COLOR_YELLOW} SCALING:${COLOR_RESET} $scale_info_ref"
	    else
	        scale_info_ref="Already 1080p"
	        echo -e "${COLOR_YELLOW} NO SCALING NEEDED:${COLOR_RESET} $scale_info_ref"
	    fi
    elif [[ "$SCALING_MODE" == "Custom" && -n "$CUSTOM_RESOLUTION" ]]; then
        # Apply custom scaling if a custom resolution is provided
        scale_filter_ref="scale=${CUSTOM_RESOLUTION}:force_original_aspect_ratio=decrease:force_divisible_by=2:flags=lanczos"
        scale_info_ref="To $CUSTOM_RESOLUTION"
        echo -e "${COLOR_YELLOW} CUSTOM SCALING:${COLOR_RESET} $scale_info_ref"
    else
        # No scaling applied if SCALING_MODE is not set or is invalid
        echo -e "${COLOR_YELLOW} SCALING:${COLOR_RESET} $scale_info_ref"
    fi

    sleep 1

    local sharpening_filter=""
    if [[ "$SHARPEN_EDGES" -eq 1 ]]; then
        sharpening_filter="split=3[main][sharp][edge]; \
        [sharp]format=gray,convolution='-1 -1 -1 -1 8 -1 -1 -1 -1'[sh]; \
        [edge]edgedetect=mode=canny:low=0.7:high=0.9,boxblur=0.5[mask]; \
        [sh][mask]alphamerge[sh_with_alpha]; \
        [main][sh_with_alpha]overlay"
        echo -e "\033[2K\r${COLOR_YELLOW} PRECISE EDGE SHARPENING ENABLED${COLOR_RESET}" | tee >(clean_output >> "$LOG_FILE")
        sleep 1
    fi

    vf_args_ref=()
    if [[ -n "$scale_filter_ref" && -n "$sharpening_filter" ]]; then
        vf_args_ref=(-vf "$scale_filter_ref,$sharpening_filter")
    elif [[ -n "$scale_filter_ref" ]]; then
        vf_args_ref=(-vf "$scale_filter_ref")
    elif [[ -n "$sharpening_filter" ]]; then
        vf_args_ref=(-vf "$sharpening_filter")
    fi
}

#Format Time
format_time() {
    local seconds="$1"
    local style="${2:-full}"  # Options: full, compact, hms, simple, about, dynamic

    awk -v t="$seconds" -v s="$style" 'BEGIN {
        if (t ~ /[^0-9.]/ || t == "") {
            print "INVALID_INPUT"
            exit 1
        }

        sign = (t < 0) ? "-" : ""
        t = (t < 0) ? -t : t

        h = int(t / 3600)
        m = int((t % 3600) / 60)
        s_remain = t % 60

        if (s == "compact") {
            if (h > 0) printf("%s%dh%02dm", sign, h, m)
            else if (m > 0) printf("%s%dm%02ds", sign, m, int(s_remain))
            else printf("%s%.2fs", sign, s_remain)
        }
        else if (s == "hms") {
            printf("%s%02d:%02d:%02d", sign, h, m, int(s_remain))
        }
        else if (s == "full") {
            printf("%s%02d:%02d:%06.3f", sign, h, m, s_remain)
        }
        else if (s == "simple") {
            if (t < 60)
                printf("%.0fs", t)
            else if (t < 3600)
                printf("%.0fm", int(t / 60))
            else
                printf("%.0fh", int(t / 3600))
        }
        else if (s == "about") {
            if (t < 60) printf("Less than a minute")
            else if (t < 120) printf("About 1 minute")
            else if (t < 3600) printf("About %.0f minutes", t / 60)
            else if ((t % 3600) < 300) printf("About %.0f hours", t / 3600)
            else if ((t % 3600) < 1800) printf("About %.1f hours", t / 3600)
            else printf("About %.0f.5 hours", t / 3600)
        }
        else if (s == "dynamic") {
            if (t >= 1)
                printf("%.3f seconds", t)
            else if (t >= 0.001)
                printf("%d milliseconds", t * 1000)
            else
                printf("%d microseconds", t * 1000000)
        }
        else {
            printf("%.0fs", t)
        }
    }'
}

# Convert human-readable time to seconds
human_to_seconds() {
    local input=$1
    if [[ $input =~ ^([0-9]+)s$ ]]; then
        echo ${BASH_REMATCH[1]}
    elif [[ $input =~ ^([0-9]+)m$ ]]; then
        echo $((${BASH_REMATCH[1]} * 60))
    elif [[ $input =~ ^([0-9]+)h$ ]]; then
        echo $((${BASH_REMATCH[1]} * 3600))
    else
        echo $input
    fi
}

# Format File Size Dynamically
format_size() {
    local bytes="$1"
    if (( bytes < 1024 )); then
        printf "%d B" "$bytes"
    elif (( bytes < 1048576 )); then  # 1024*1024
        printf "%.1f KB" "$(awk "BEGIN {printf \"%.1f\", $bytes/1024}")"
    elif (( bytes < 1073741824 )); then  # 1024*1024*1024
        printf "%.1f MB" "$(awk "BEGIN {printf \"%.1f\", $bytes/1048576}")"
    elif (( bytes < 1099511627776 )); then  # 1024*1024*1024*1024
        printf "%.1f GB" "$(awk "BEGIN {printf \"%.1f\", $bytes/1073741824}")"
    else
        printf "%.1f TB" "$(awk "BEGIN {printf \"%.1f\", $bytes/1099511627776}")"
    fi
}

# Validate if input is positive integer
is_positive_integer() {
    [[ "$1" =~ ^[0-9]+$ ]]
}

# Validate time format
is_valid_time_format() {
    [[ "$1" =~ ^([0-9]+)(s|m|h)?$ ]]
}

# Portable realpath
portable_realpath() {
    if command -v realpath >/dev/null; then
        realpath "$1"
    else
        readlink -f "$1" 2>/dev/null || echo "$1"
    fi
}

# Confirm action with user
confirm_action() {
    local prompt="$1"
    local timeout="$2"
    local default="$3"

    echo -n "$prompt"
    if ! read -t "$timeout" -r response; then
        response="$default"
        CONFIRM_INPUT="timeout"
    else
        CONFIRM_INPUT="$response"
    fi

    response=${response,,}  # lowercase

    if [[ "$response" == "y" || "$response" == "yes" || -z "$response" ]]; then
        return 0
    else
        return 1
    fi
}

# Calculate optimal chunk count for set chunking duration
calculate_chunk_count() {
    local total_seconds="$1"
    local chunk_mode="${2:-$CHUNK_MODE}"
    local manual_duration="${3:-600}"

    if [ "$chunk_mode" = "manual" ]; then
        local target_duration="$manual_duration"

        awk -v total="$total_seconds" -v target="$target_duration" 'BEGIN {
            min_duration = target - 300
            max_duration = target + 300

            ideal_chunks = int((total + target / 2) / target)
            if (ideal_chunks < 1) ideal_chunks = 1

            chunk_duration = total / ideal_chunks
            while (chunk_duration < min_duration && ideal_chunks > 1) {
                ideal_chunks -= 1
                chunk_duration = total / ideal_chunks
            }

            while (chunk_duration > max_duration) {
                ideal_chunks += 1
                chunk_duration = total / ideal_chunks
            }

            print ideal_chunks
        }'

    else
        # Default
        awk -v t="$total_seconds" 'BEGIN {
            min_chunks = int(t / 2100)
            if (t > min_chunks * 2100) min_chunks += 1
            if (min_chunks < 1) min_chunks = 1

            max_chunks = int(t / 1800)
            if (max_chunks < 1) max_chunks = 1

            best_chunks = min_chunks
            best_diff = 1000000

            for (chunks = min_chunks; chunks <= max_chunks; chunks++) {
                chunk_duration = t / chunks
                if (chunk_duration < 1800) {
                    diff = 1800 - chunk_duration
                } else if (chunk_duration > 2100) {
                    diff = chunk_duration - 2100
                } else {
                    diff = 0
                }
                if (diff < best_diff) {
                    best_diff = diff
                    best_chunks = chunks
                }
            }
            print best_chunks
        }'
    fi
}

#Get Labels
get_video_codec_label() {
    local video_codec="${1:-$VIDEO_CODEC}"
    case "$video_codec" in
        libsvtav1) echo "(SVT-AV1)" ;;
        libx264)   echo "(H.264/AVC)" ;;
        libx265)   echo "(H.265/HEVC)" ;;
        libvpx)    echo "(VP8)" ;;
        libvpx-vp9) echo "(VP9)" ;;
        libaom-av1) echo "(AOM-AV1)" ;;
        copy)      echo "(Original)" ;;
        *)         echo "" ;;
    esac
}

get_audio_codec_label() {
    local audio_codec="${1:-$AUDIO_CODEC}"
    case "$audio_codec" in
        libopus) echo "(Opus)" ;;
        aac)     echo "(AAC)" ;;
        flac)    echo "(FLAC)" ;;
        mp3)     echo "(MP3)" ;;
        copy)    echo "(Original)" ;;
        *)       echo "" ;;
    esac
}

# Check for required dependencies
check_dependencies() {
    local missing=()
    local deps=(
        ffmpeg
        ffprobe
        mkvmerge
        awk
        sed
        stat
        realpath
        find
        xargs
        sort
        du
        date
        tr
        cut
        head
        ls
        grep
        comm
        tee
        wc
        sleep
        sha256sum
    )

    # mediainfo is optional: lib-probe.sh only uses it as a last-resort fallback
    # (ffprobe BPS tag / packet-size calculation cover the same cases).

    # command -> package mapping (Termux specific)
    declare -A dep_pkg=(
        [ffmpeg]="ffmpeg"
        [ffprobe]="ffmpeg"
        [mkvmerge]="mkvtoolnix"
        [mediainfo]="mediainfo"
        [awk]="gawk"
        [sed]="sed"
        [stat]="coreutils"
        [realpath]="coreutils"
        [du]="coreutils"
        [date]="coreutils"
        [ls]="coreutils"
        [head]="coreutils"
        [cut]="coreutils"
        [tr]="coreutils"
        [wc]="coreutils"
        [tee]="coreutils"
        [sleep]="coreutils"
        [sha256sum]="coreutils"
        [sort]="coreutils"
        [grep]="grep"
        [find]="findutils"
        [xargs]="findutils"
        [comm]="diffutils"
    )

    for dep in "${deps[@]}"; do
        if ! command -v "$dep" >/dev/null 2>&1; then
            missing+=("$dep")
        fi
    done

    if [ ${#missing[@]} -gt 0 ]; then
        echo -e "${COLOR_RED} MISSING DEPENDENCIES:${COLOR_RESET}"
        for m in "${missing[@]}"; do
            echo "  - $m"
        done
        echo

        # Build correct package list
        local pkgs=()
        for m in "${missing[@]}"; do
            pkgs+=("${dep_pkg[$m]}")
        done

        # Remove duplicates
        pkgs=($(printf "%s\n" "${pkgs[@]}" | sort -u))

        echo -e "${COLOR_YELLOW} INSTALL WITH:${COLOR_RESET}"
		printf "  pkg install"
		for p in "${pkgs[@]}"; do
		    printf " %s" "$p"
		done
		printf "\n\n"

        # Special note for mkvmerge
        if printf "%s\n" "${missing[@]}" | grep -q "mkvmerge"; then
            echo -e "${COLOR_YELLOW} NOTE:${COLOR_RESET} mkvmerge requires x11-repo"
            echo "  pkg install x11-repo"
            echo "  pkg install mkvtoolnix"
            echo
        fi

        exit 1
    fi
}

# Initialize directories
init_directories() {
    mkdir -p "$LOG_DIR"
}

#clean logging
clean_output() {
    sed 's/\x1b\[[0-9;]*[mGK]//g'
}

# Settings that may appear in the config file, each with a validation regex.
# The file is parsed as KEY="value" lines and is NEVER sourced, so a damaged or
# edited config cannot run commands or crash the script with a non-numeric value.
declare -gA _CONFIG_SCHEMA=(
    [INPUT_DIR]='.*'
    [DEFAULT_INPUT_DIR_1]='.*'
    [DEFAULT_INPUT_DIR_2]='.*'
    [OUTPUT_DIR]='.*'
    [VIDEO_CODEC]='^[A-Za-z0-9_.-]+$'
    [AUDIO_CODEC]='^[A-Za-z0-9_.-]+$'
    [AUDIO_BITRATE]='^[0-9]+$'
    [CRF]='^[0-9]+$'
    [PRESET]='^[A-Za-z0-9_.-]+$'
    [BITRATE_LIMITS_ENABLED]='^[01]$'
    [MAXRATE]='^[0-9]+[kM]$'
    [BUFSIZE]='^[0-9]+[kM]$'
    [CHUNK_THRESHOLD]='^[0-9]+$'
    [CHUNK_MODE]='^(default|manual)$'
    [MANUAL_CHUNK_DURATION]='^[0-9]+$'
    [COOLDOWN_TIME]='^[0-9]+$'
    [AUTO_COOLDOWN]='^[01]$'
    [LOG_DIR]='.*'
    [COMPLETED_DIR]='.*'
    [PIXFMT_MODE]='^(copy|8-bit|10-bit)$'
    [OUTPUT_FORMAT]='^(mkv|mp4|webm|mov|avi)$'
    [SCALING_MODE]='^(OFF|720P|1080P|Custom)$'
    [CUSTOM_RESOLUTION]='^[0-9]+x[0-9]+$'
    [SHARPEN_EDGES]='^[01]$'
    [FPS_HANDLING]='^(auto|source)$'
    [PROGRESS_STYLE]='^(simple|advanced)$'
    [BAR_STYLE]='^[a-z_-]+$'
    [FILE_SORT_MODE]='^(name_az|name_za|size_small|size_large|date_new|date_old)$'
    [CPU_THREADS]='^[0-9]+$'
    [SVTAV1_LP]='^[0-9]+$'
)
# Order in which settings are written (keeps the file layout stable)
declare -ga _CONFIG_ORDER=(INPUT_DIR DEFAULT_INPUT_DIR_1 DEFAULT_INPUT_DIR_2 OUTPUT_DIR VIDEO_CODEC
    AUDIO_CODEC AUDIO_BITRATE CRF PRESET BITRATE_LIMITS_ENABLED MAXRATE BUFSIZE CHUNK_THRESHOLD
    CHUNK_MODE MANUAL_CHUNK_DURATION COOLDOWN_TIME AUTO_COOLDOWN LOG_DIR COMPLETED_DIR PIXFMT_MODE
    OUTPUT_FORMAT SCALING_MODE CUSTOM_RESOLUTION SHARPEN_EDGES FPS_HANDLING PROGRESS_STYLE BAR_STYLE
    FILE_SORT_MODE CPU_THREADS SVTAV1_LP)

# Load configuration from file (safe parser, see _CONFIG_SCHEMA)
load_config() {
    [[ -f "$CONFIG_FILE" ]] || return 0
    local line key val rx skipped=0 loaded=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
        if ! [[ "$line" =~ ^([A-Z][A-Z0-9_]*)=(.*)$ ]]; then skipped=$((skipped + 1)); continue; fi
        key="${BASH_REMATCH[1]}"; val="${BASH_REMATCH[2]}"
        rx="${_CONFIG_SCHEMA[$key]-}"
        if [[ -z "$rx" ]]; then skipped=$((skipped + 1)); continue; fi
        # strip one pair of surrounding double quotes (older files also have unquoted values)
        if [[ ${#val} -ge 2 && "$val" == \"*\" ]]; then val="${val:1:${#val}-2}"; fi
        if ! [[ "$val" =~ $rx ]]; then
            echo -e "${COLOR_YELLOW} CONFIG: IGNORED INVALID VALUE FOR${COLOR_RESET} $key" >&2
            skipped=$((skipped + 1)); continue
        fi
        printf -v "$key" '%s' "$val"
        loaded=$((loaded + 1))
    done < "$CONFIG_FILE"
    echo -e "${COLOR_GREEN} LOADED CONFIGURATION FROM:${COLOR_RESET} $CONFIG_FILE"
    if (( skipped > 0 )); then
        echo -e "${COLOR_YELLOW} CONFIG: $skipped LINE(S) SKIPPED${COLOR_RESET}" >&2
    fi
    sleep 1
    return 0
}

# Save configuration to file (written to a temp file first, then moved into place)
save_config() {
    local key tmp
    tmp="${CONFIG_FILE}.tmp.$$"
    {
        echo "# Video Converter Configuration"
        for key in "${_CONFIG_ORDER[@]}"; do
            printf '%s="%s"\n' "$key" "${!key//$'\n'/ }"
        done
    } > "$tmp" 2>/dev/null && mv -f -- "$tmp" "$CONFIG_FILE" 2>/dev/null || {
        rm -f -- "$tmp" 2>/dev/null
        echo -e "${COLOR_RED} COULD NOT SAVE CONFIGURATION TO:${COLOR_RESET} $CONFIG_FILE"
        sleep 1
        return 1
    }
    echo -e "${COLOR_YELLOW} CONFIGURATION SAVED TO:${COLOR_RESET} $CONFIG_FILE"
    sleep 1
    return 0
}

#Script termination
handle_termination() {
    echo ""
    echo "-----------------------------------------------"
    echo -e "${COLOR_RED} PROCESS TERMINATED${COLOR_RESET}"
    echo ""
    # keep whatever ffmpeg had written to its log so far
    if declare -F diag_on_interrupt >/dev/null 2>&1; then diag_on_interrupt || true; fi

    # Only provide information about chunk directory, don't move it
    if [ -n "${chunk_dir+x}" ] && [ -d "$chunk_dir" ]; then
        local chunk_dirname="${chunk_dir#/storage/emulated/0/}"
        echo -e "${COLOR_YELLOW} CHUNK DIRECTORY PRESERVED FOR RESUME:${COLOR_RESET}"
        echo " $chunk_dirname"
        echo ""
        echo -e "${COLOR_BLUE} TO RESUME PROCESSING:${COLOR_RESET}"
        echo " 1. NOTE THE CHUNK PROGRESS AND CONFIGURATION ABOVE"
        echo " 2. RERUN THE SCRIPT - IT WILL AUTO-DETECT AND RESUME"
    else
        echo -e "${COLOR_YELLOW} NO CHUNK DIRECTORY FOUND (SINGLE PASS MODE)${COLOR_RESET}"
    fi
    
    echo ""
    echo -e "${COLOR_RED} EXITING${COLOR_RESET}"
    exit 130
}