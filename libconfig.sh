#!/bin/bash

# ===========================================================================
# CONFIG MODULE - HELPER FUNCTIONS
# ===========================================================================

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

# Convert seconds to human-readable format
seconds_to_human() {
    local input="$1"
    local style="${2:-simple}"
    local sec_int=${input%%.*}

    case "$style" in
        compact)
            local mins=$((sec_int / 60))
            local secs=$((sec_int % 60))
            echo "${mins}m${secs}s"
            ;;
        simple)
            if (( sec_int >= 3600 )); then
                echo "$((sec_int / 3600))h"
            elif (( sec_int >= 60 )); then
                echo "$((sec_int / 60))m"
            else
                echo "${sec_int}s"
            fi
            ;;
        *)
            echo "${sec_int}s"
            ;;
    esac
}

# Validate if input is positive integer
is_positive_integer() {
    [[ "$1" =~ ^[0-9]+$ ]]
}

# Validate time format
is_valid_time_format() {
    [[ "$1" =~ ^([0-9]+)(s|m|h)?$ ]]
}

# Format duration as HH:MM:SS
format_duration() {
    local total_seconds=$1
    printf '%02d:%02d:%02d' $((total_seconds/3600)) $(((total_seconds%3600)/60)) $((total_seconds%60))
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
    fi
    response=${response,,}
    
    if [[ "$response" == "y" || "$response" == "yes" || -z "$response" ]]; then
        return 0
    else
        return 1
    fi
}

# Calculate optimal chunk count for 30-35 minute chunks
calculate_chunk_count() {
    local total_seconds="$1"
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
}

# Convert floating-point seconds to timestamp
float_to_timestamp() {
    local seconds="$1"
    local style="${2:-full}"

    awk -v t="$seconds" -v style="$style" 'BEGIN {
        h = int(t / 3600);
        m = int((t - h * 3600) / 60);
        s = int(t - h * 3600 - m * 60);

        if (style == "compact") {
            if (h > 0)
                printf("%dh%02dm", h, m);
            else
                printf("%dm%02ds", m, s);
        } else {
            printf("%02d:%02d:%06.3f", h, m, t - (h * 3600) - (m * 60));
        }
    }'
}

#Codec Names
get_video_codec_label() {
    case "$VIDEO_CODEC" in
        libsvtav1) echo "(SVT-AV1)" ;;
        libx264)   echo "(H.264/AVC)" ;;
        libx265)   echo "(H.265/HEVC)" ;;
        libvpx)    echo "(VP8)" ;;
        libvpx-vp9) echo "(VP9)" ;;
        libaom-av1) echo "(AOM AV1)" ;;
        copy)      echo "(Original)" ;;
        *)         echo "" ;;
    esac
}

get_audio_codec_label() {
    case "$AUDIO_CODEC" in
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
    local deps=("ffmpeg" "ffprobe" "awk" "stat")
    
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &>/dev/null; then
            missing+=("$dep")
        fi
    done

    if [ ${#missing[@]} -gt 0 ]; then
        echo "❌ Missing dependencies:"
        for m in "${missing[@]}"; do
            echo "  - $m"
        done
        echo
        echo "Install them with:"
        echo "  pkg install ${missing[*]}"
        exit 1
    fi
}

# Initialize directories
init_directories() {
    mkdir -p "$LOG_DIR"
}

# Load configuration from file
load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        source "$CONFIG_FILE"
        echo "🔸 Loaded configuration from: $CONFIG_FILE" | tee -a "$MAIN_LOG"
    fi
}

# Save configuration to file
save_config() {
    cat > "$CONFIG_FILE" <<EOF
# Video Converter Configuration
INPUT_DIR="$INPUT_DIR"
OUTPUT_DIR="$OUTPUT_DIR"
VIDEO_CODEC="$VIDEO_CODEC"
AUDIO_CODEC="$AUDIO_CODEC"
AUDIO_BITRATE="$AUDIO_BITRATE"
CRF="$CRF"
PRESET="$PRESET"
CHUNK_THRESHOLD="$CHUNK_THRESHOLD"
COOLDOWN_TIME="$COOLDOWN_TIME"
LOG_DIR="$LOG_DIR"
MAIN_LOG="$MAIN_LOG"
BIT_DEPTH="$BIT_DEPTH"
OUTPUT_FORMAT="$OUTPUT_FORMAT"
EOF
    echo "🔸 Configuration saved to: $CONFIG_FILE" | tee -a "$MAIN_LOG"
}

# Cleanup temporary files on interrupt
cleanup_temp_files() {
    echo -e "\n\033[2K\r ‼️ENCODING INTERRUPTED BY USER (Ctrl+C). Cleaning up..."
    [ -n "$temp_output" ] && [ -f "$temp_output" ] && rm -f "$temp_output"
    [ -n "$fixed_output" ] && [ -f "$fixed_output" ] && rm -f "$fixed_output"
    [ -n "$chunk_dir" ] && [ -d "$chunk_dir" ] && rm -rf "$chunk_dir"
    echo " 🧹 Temporary files removed. Exiting..."
    exit 130
}