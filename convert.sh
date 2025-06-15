#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

# ===========================================================================
# MAIN SCRIPT - MODULE IMPORTS
# ===========================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

# Import modules
source "$SCRIPT_DIR/libconfig.sh"
source "$SCRIPT_DIR/libprobe.sh"
source "$SCRIPT_DIR/libencode.sh"
source "$SCRIPT_DIR/libui.sh"

# ===========================================================================
# MAIN SCRIPT - VARIABLES
# ===========================================================================
# Configuration settings
INPUT_DIR=""
OUTPUT_DIR="${HOME}/Movies/ffmpeg/Converted"
VIDEO_CODEC="libsvtav1"
AUDIO_CODEC="libopus"
AUDIO_BITRATE="96"
CRF="20"
PRESET="6"
CHUNK_THRESHOLD=1200
COOLDOWN_TIME=300
CONFIG_FILE="video_converter.conf"
LOG_DIR=""
BIT_DEPTH="auto"
OUTPUT_FORMAT="mkv"
DRY_RUN=false  # Added dry run flag

# Cleanup Temporary Files
temp_output=""
fixed_output=""
chunk_dir=""

# ===========================================================================
# MAIN SCRIPT - EXECUTION
# ===========================================================================
# Trap to catch interrupt signals
trap cleanup_temp_files INT TERM

# Initialize logging
[ -z "$LOG_DIR" ] && LOG_DIR="./logs"
MAIN_LOG="$LOG_DIR/main.log"
mkdir -p "$LOG_DIR"
touch "$MAIN_LOG"

echo "===== 🔸 Video Converter Started: $(date) =====" | tee -a "$MAIN_LOG"

# Dependency check
check_dependencies
load_config

# Main processing logic
if [ $# -ge 1 ]; then
    if [ "$1" == "--create-downloader" ]; then
        echo "Downloader creation not implemented in this version" | tee -a "$MAIN_LOG"
        exit 1
    elif [ "$1" == "--dry-run" ]; then  # Added dry-run option
        DRY_RUN=true
        shift
        if [ $# -ge 1 ]; then
            INPUT_DIR="$1"
        fi
    else
        INPUT_DIR="$1"
    fi
    
    if [ -n "$INPUT_DIR" ]; then
        process_all_files "$INPUT_DIR"
        exit 0
    fi
fi

# Interactive mode
while true; do
    show_menu
    
    read -p "   🔸 SELECT OPTION [0-11]: " choice
    process_menu_choice "$choice"
done