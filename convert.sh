#!/bin/bash
set -euo pipefail
IFS=$'\n\t'
# (cp /sdcard/Download/*.sh "$HOME/" && chmod +x "$HOME"/*.sh)
# ===========================================================================
# MAIN SCRIPT - MODULE IMPORTS
# ===========================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

# ==================== COLOR DEFINITIONS ====================
# Reset
declare -g COLOR_RESET="\033[0m"	# ${COLOR_RESET}

# Regular Colors
declare -g COLOR_RED="\033[1m\033[38;5;196m"	# ${COLOR_RED}
declare -g COLOR_GREEN="\033[1m\033[38;5;82m"	# ${COLOR_GREEN}
declare -g COLOR_YELLOW="\033[1m\033[38;5;226m"	# ${COLOR_YELLOW}
declare -g COLOR_ORANGE="\033[1m\033[38;5;208m"	# ${COLOR_ORANGE}
declare -g COLOR_BLUE="\033[1m\033[38;5;39m"	# ${COLOR_BLUE}
declare -g COLOR_CYAN="\033[1m\033[38;5;6m"	# ${COLOR_CYAN}

# ==========================================================

# Load modules with error handling
# Quiet by default (one self-updating line). Set VERBOSE_LOAD=1 to list the
# functions each module adds.
load_module() {
    local module="$1"
    local before_functions="" after_functions=""

    if [ "${VERBOSE_LOAD:-0}" = "1" ]; then
        echo -e "${COLOR_GREEN} LOADING:${COLOR_RESET} ${module}" >&2
        before_functions=$(declare -F | awk '{print $3}' | sort | grep -v '^_' || true)
    else
        printf '\r\033[2K %bLoading%b %s' "$COLOR_BLUE" "$COLOR_RESET" "$module" >&2
    fi

    # Load the module
    if ! source "${SCRIPT_DIR}/${module}"; then
        printf '\r\033[2K' >&2
        echo -e "${COLOR_RED} FAILED TO LOAD: ${module}${COLOR_RESET}" >&2
        exit 1
    fi

    if [ "${VERBOSE_LOAD:-0}" = "1" ]; then
        after_functions=$(declare -F | awk '{print $3}' | sort | grep -v '^_' || true)
        echo -e "${COLOR_BLUE} FUNCTIONS:${COLOR_RESET}" >&2
        comm -13 <(echo "$before_functions") <(echo "$after_functions") | awk '{print "  → " $0}' >&2
    fi
}

# Load all dependencies
load_module "lib-config.sh"
load_module "lib-probe.sh"
load_module "lib-encode.sh"
load_module "lib-diagnostics.sh"
load_module "lib-diag-recovery.sh"
load_module "lib-ui-kit.sh"
load_module "lib-ui-info.sh"
load_module "lib-ui-main_menu.sh"
load_module "lib-ui-adv_menu.sh"
printf '\r\033[2K' >&2   # clear the loader line

# Verify critical functions exist
required_functions=("show_menu" "process_menu_choice")
for func in "${required_functions[@]}"; do
    if ! declare -F "$func" >/dev/null; then
        echo -e "${COLOR_RED} MISSING REQUIRED FUNCTION:${COLOR_RESET} $func" >&2
        exit 1
    fi
done

# ===========================================================================
# MAIN SCRIPT - VARIABLES
# ===========================================================================
# Global declarations
declare -g INPUT_DIR=""
declare -g DEFAULT_INPUT_DIR_1="/sdcard/Movies/ffmpeg/Job"
declare -g DEFAULT_INPUT_DIR_2="/storage/F437-7513/Movies/ffmpeg/Job"
declare -g OUTPUT_DIR="/sdcard/Movies/ffmpeg/Converted"
declare -g VIDEO_CODEC="libsvtav1"
declare -g AUDIO_CODEC="libopus"
declare -g AUDIO_BITRATE="80"
declare -g CRF="20"
declare -g PRESET="6"
declare -g BITRATE_LIMITS_ENABLED=0  
declare -g MAXRATE="800k"
declare -g BUFSIZE="1200k"
declare -g CHUNK_THRESHOLD=1800
declare -g CHUNK_MODE="default"
declare -g MANUAL_CHUNK_DURATION=600
declare -g COOLDOWN_TIME=600
declare -g CONFIG_FILE="video_converter.conf"
declare -g LOG_DIR=""
declare -g COMPLETED_DIR=""
declare -g PIXFMT_MODE="copy"  
declare -g OUTPUT_FORMAT="mkv"
declare -g AUTO_COOLDOWN=0
declare -g SCALING_MODE="OFF"
declare -g CUSTOM_RESOLUTION="1920x1080"
declare -g SHARPEN_EDGES=0
declare -g FPS_HANDLING="${FPS_HANDLING:-auto}"   # auto | source (see lib-probe.sh)
declare -g PROGRESS_STYLE="advanced"
declare -g BAR_STYLE="horizontal_blocks"
declare -g FILE_SORT_MODE="name_az"
declare -g CPU_THREADS="2"
declare -g SVTAV1_LP="2"

# Global ETA tracking
declare -g TOTAL_QUEUE_DURATION=0
declare -g TOTAL_QUEUE_FILES=0

# Cleanup Temporary Files
declare -g temp_output=""
declare -g fixed_output=""
declare -g chunk_dir=""

# ===========================================================================
# MAIN SCRIPT - EXECUTION
# ===========================================================================

# Trap to catch interrupt signals
trap 'handle_termination; exit 130' INT TERM  # 130 = Script terminated by Ctrl+C

# Dependency check
check_dependencies

# Config location: a file next to the script wins; otherwise keep using one in the
# current directory (the old behaviour); otherwise create it next to the script.
case "$CONFIG_FILE" in
    /*) ;;
    *)
        if [ -f "$SCRIPT_DIR/$CONFIG_FILE" ]; then
            CONFIG_FILE="$SCRIPT_DIR/$CONFIG_FILE"
        elif [ ! -f "./$CONFIG_FILE" ]; then
            CONFIG_FILE="$SCRIPT_DIR/$CONFIG_FILE"
        fi
        ;;
esac
load_config

# Folders are created AFTER the config is loaded, so folders chosen in the config
# exist too (previously a configured COMPLETED_DIR/LOG_DIR was never created and
# the first completion marker aborted the batch).
[ -z "$COMPLETED_DIR" ] && COMPLETED_DIR="/sdcard/Movies/ffmpeg/.video_status/completed"
[ -z "$LOG_DIR" ] && LOG_DIR="/sdcard/Movies/ffmpeg/Logs"

ensure_dir() {   # ensure_dir PATH LABEL
    if ! mkdir -p -- "$1" 2>/dev/null || [ ! -w "$1" ]; then
        echo -e "${COLOR_RED} CANNOT CREATE OR WRITE ${2}:${COLOR_RESET} $1" >&2
        case "$1" in
            /sdcard/*|/storage/*)
                echo -e "${COLOR_YELLOW} SHARED STORAGE NEEDS PERMISSION - RUN:${COLOR_RESET} termux-setup-storage" >&2 ;;
        esac
        return 1
    fi
}
ensure_dir "$COMPLETED_DIR" "COMPLETION-MARKER FOLDER" || exit 1
ensure_dir "$LOG_DIR" "LOG FOLDER" || exit 1

# Process input based on type
process_input() {
    local input_path="$1"
    
    if [ -f "$input_path" ]; then
        # Single file (failures are isolated and offered for diagnosis, like in a batch)
        local pf_rc=0
        diag_batch_begin "$(dirname -- "$(portable_realpath "$input_path")")"
        process_file "$input_path" || pf_rc=$?
        diag_post_batch_menu || true
        return "$pf_rc"
    elif [ -d "$input_path" ]; then
        # Directory
        process_all_files "$input_path"
    else
        echo -e "${COLOR_RED} INPUT DOES NOT EXIST:${COLOR_RESET} $input_path"
        return 1
    fi
}

has_video_files() {
    local dir="$1"

    [ ! -d "$dir" ] && return 1

    local first_match
    first_match=$(find "$dir" \
        \( -type d \( -iname "chunks_*" -o -name ".ffmpeg_diagnostics" \) -prune \) -o \
        \( -type f \( \
        -iname "*.mp4" -o \
        -iname "*.mkv" -o \
        -iname "*.mov" -o \
        -iname "*.avi" -o \
        -iname "*.webm" -o \
        -iname "*.wmv" -o \
        -iname "*.flv" -o \
        -iname "*.mpeg" -o \
        -iname "*.mpg" -o \
        -iname "*.mpe" -o \
        -iname "*.m4v" -o \
        -iname "*.3gp" -o \
        -iname "*.3g2" -o \
        -iname "*.f4v" -o \
        -iname "*.ts" -o \
        -iname "*.m2ts" -o \
        -iname "*.mts" -o \
        -iname "*.vob" \) -print \) -quit)

    [ -n "$first_match" ]
}

# Get active input directories
get_active_input_dirs() {
    if has_video_files "$DEFAULT_INPUT_DIR_1"; then
        printf '%s\n' "$DEFAULT_INPUT_DIR_1"
    fi

    if has_video_files "$DEFAULT_INPUT_DIR_2"; then
        printf '%s\n' "$DEFAULT_INPUT_DIR_2"
    fi
}

# Main processing logic
if [ $# -ge 1 ]; then
    INPUT_PATH="$1"

    if [ -e "$INPUT_PATH" ]; then
        process_input "$INPUT_PATH"
        # Non-zero when files failed, so scripts/cron can tell
        if [ "${BATCH_LAST_RESULT:-}" = "failed" ]; then exit 1; fi
        exit 0
    else
        echo -e "${COLOR_RED} FILE OR DIRECTORY DOES NOT EXIST:${COLOR_RESET} $INPUT_PATH"
        exit 1
    fi
fi

# Interactive mode
while true; do
    show_menu
    read -r -p "$(ui_prompt "SELECT OPTION [0-9]")" choice || exit 0
    echo ""
    process_menu_choice "$choice"
done