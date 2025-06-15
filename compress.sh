#!/data/data/com.termux/files/usr/bin/bash

# Function: Show interactive menu
show_menu() {
    clear
    # Determine input type for display
    local input_type="FILE"
    if [ -d "$INPUT" ]; then
        input_type="FOLDER"
    fi
    
    echo "============================================================"
    echo "|             VIDEO COMPRESSION TOOL                       |"
    echo "============================================================"
    echo "|  INPUT ($input_type): $INPUT"
    echo "------------------------------------------------------------"
    echo "|  1. Compress to Target Size                              |"
    echo "|  2. Exit                                                  |"
    echo "============================================================"
    echo -n "👉 SELECT OPTION [1-2]: "
}

get_duration() {
    ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$1"
}

# Compress video to target size with real-time progress
compress_to_target() {
    local input="$1"
    local target_mb="$2"
    local output_dir="$3"
    
    mkdir -p "$output_dir"
    local base=$(basename "$input")
    local name="${base%.*}"
    local output="${output_dir}/${name}_compressed_${target_mb}mb.mp4"
    
    local duration_sec=$(get_duration "$input")
    
    local target_kbits=$(echo "scale=2; $target_mb * 8192" | bc)
    local bitrate=$(echo "scale=2; $target_kbits / $duration_sec" | bc)
    
    local temp_log_dir=$(mktemp -d)
    local log_prefix="${temp_log_dir}/ffmpeg2pass"
    
    echo "📼 Starting compression to $target_mb MB (target bitrate: $bitrate kbps)..."
    echo "🔁 Pass 1/2..."
    
    ffmpeg -y -i "$input" -c:v libx264 -b:v "${bitrate}k" -pass 1 -passlogfile "$log_prefix" \
        -an -f mp4 -pix_fmt yuv420p -progress pipe:1 -nostats /dev/null 2>/dev/null | \
    while IFS= read -r line; do
        if [[ $line =~ out_time_ms=([0-9]+) ]]; then
            ms=${BASH_REMATCH[1]}
            current_sec=$(echo "scale=2; $ms / 1000000" | bc)
            raw_pct=$(echo "scale=0; ($current_sec * 100) / $duration_sec" | bc)
            [ "$raw_pct" -gt 100 ] && pct=100 || pct=$raw_pct
            printf "\r   Progress: %3d%%" "$pct"
        fi
    done
    
    echo -e "\r   ✅ Pass 1 complete."
    echo "🔁 Pass 2/2..."
    
    ffmpeg -y -i "$input" -c:v libx264 -b:v "${bitrate}k" -pass 2 -passlogfile "$log_prefix" \
        -c:a aac -b:a 64k -pix_fmt yuv420p -progress pipe:1 -nostats "$output" 2>/dev/null | \
    while IFS= read -r line; do
        if [[ $line =~ out_time_ms=([0-9]+) ]]; then
            ms=${BASH_REMATCH[1]}
            current_sec=$(echo "scale=2; $ms / 1000000" | bc)
            raw_pct=$(echo "scale=0; ($current_sec * 100) / $duration_sec" | bc)
            [ "$raw_pct" -gt 100 ] && pct=100 || pct=$raw_pct
            printf "\r   Progress: %3d%%" "$pct"
        fi
    done
    
    rm -rf "$temp_log_dir"
    
    echo -e "\r   ✅ Pass 2 complete."
    echo "✅ Compressed file saved to: $output"
}

compress_batch() {
    local input_dir="$1"
    local target_mb="$2"
    local output_dir="$3"
    
    local extensions=("mp4" "mkv" "avi" "mov" "flv" "wmv" "m4v" "mpg" "mpeg")
    
    local video_files=()
    for ext in "${extensions[@]}"; do
        while IFS= read -r -d $'\0'; do
            video_files+=("$REPLY")
        done < <(find "$input_dir" -maxdepth 1 -type f -iname "*.$ext" -print0)
    done
    
    local total_files=${#video_files[@]}
    [ $total_files -eq 0 ] && echo "❌ No video files found in $input_dir" && return 1
    
    echo "✅ Found $total_files video files in folder"
    
    local count=0
    for file in "${video_files[@]}"; do
        count=$((count+1))
        echo "------------------------------------------------------------"
        echo "|  PROCESSING FILE $count/$total_files: $(basename "$file")"
        echo "------------------------------------------------------------"
        
        compress_to_target "$file" "$target_mb" "$output_dir"
        
        [ $count -lt $total_files ] && echo "------------------------------------------------------------"
    done
    
    echo "✅ Batch compression complete! $count files processed."
}

INPUT=""
OUTDIR="/sdcard/Movies/ffmpeg/Compressed"

if [ $# -eq 0 ]; then
    read -e -p "👉 ENTER INPUT FILE OR FOLDER PATH: " INPUT
    INPUT=$(realpath "$INPUT")
    [ ! -e "$INPUT" ] && echo "❌ FILE/FOLDER NOT FOUND: $INPUT" && exit 1
    
    while true; do
        show_menu
        read choice
        case $choice in
            1)
                while true; do
                    clear
                    input_type="FILE"
                    [ -d "$INPUT" ] && input_type="FOLDER"
                    echo "============================================================"
                    echo "|           COMPRESS TO TARGET SIZE                        |"
                    echo "------------------------------------------------------------"
                    echo "|  INPUT ($input_type): $INPUT"
                    echo "|  TARGET SIZE: 8.7 MB (default)"
                    echo "------------------------------------------------------------"
                    echo "|  Enter target size in MB (e.g., 10) or                   |"
                    echo "|  press Enter to use default.                             |"
                    echo "|                                                          |"
                    echo "|  (b) Back to main menu                                   |"
                    echo "============================================================"
                    echo -n "👉 SELECT: "
                    read input
                    
                    [ "$input" = "b" ] && break
                    
                    if [ -z "$input" ]; then
                        TARGET_MB=8.7
                    elif [[ "$input" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
                        TARGET_MB=$input
                    else
                        echo "❌ INVALID NUMBER: $input"
                        read -p "Press Enter to continue..."
                        continue
                    fi
                    
                    if [ -f "$INPUT" ]; then
                        compress_to_target "$INPUT" "$TARGET_MB" "$OUTDIR"
                    elif [ -d "$INPUT" ]; then
                        compress_batch "$INPUT" "$TARGET_MB" "$OUTDIR"
                    else
                        echo "❌ Invalid input type: $INPUT"
                    fi
                    
                    read -p "✅ OPERATION COMPLETE! Press Enter to continue..."
                    break
                done
                ;;
            2)
                echo "   EXITING..."
                exit 0
                ;;
            *)
                echo "❌ INVALID OPTION"
                sleep 1
                ;;
        esac
    done

else
    INPUT="$1"
    shift
    INPUT=$(realpath "$INPUT")
    [ ! -e "$INPUT" ] && echo "❌ FILE/FOLDER NOT FOUND: $INPUT" && exit 1
    
    TARGET_MB=8.7
    if [ $# -ge 1 ]; then
        if [[ "$1" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
            TARGET_MB="$1"
        else
            echo "❌ INVALID TARGET SIZE: $1"
            exit 1
        fi
    fi
    
    mkdir -p "$OUTDIR"
    
    if [ -f "$INPUT" ]; then
        compress_to_target "$INPUT" "$TARGET_MB" "$OUTDIR"
    elif [ -d "$INPUT" ]; then
        compress_batch "$INPUT" "$TARGET_MB" "$OUTDIR"
    else
        echo "❌ Invalid input type: $INPUT"
        exit 1
    fi
fi

exit 0