#!/data/data/com.termux/files/usr/bin/bash

# Function: Show interactive menu
show_menu() {
    clear
    echo "╔════════════════════════════════════════════╗"
    echo "║            VIDEO TRIMMING TOOL             ║"
    echo "╠════════════════════════════════════════════╣"
    echo "║  INPUT: $INPUT"
    echo "╠════════════════════════════════════════════╣"
    echo "║  1. Timestamp Trim (consecutive segments)  ║"
    echo "║  2. Percentage Trim (equal parts)          ║"
    echo "║  3. Range Trim (start-end pairs)           ║"
    echo "║  4. Start Processing                       ║"
    echo "║  5. Exit                                   ║"
    echo "╚════════════════════════════════════════════╝"
    echo -n "   🔸SELECT OPTION [1-5]: "
}

# Normalize time input (e.g., "0.1" → "00:00:01.000", "1.5.30" → "01:05:30.000")
normalize_time() {
    IFS='.' read -ra parts <<< "$1"
    case ${#parts[@]} in
        1) printf "%02d:%02d:%02d.000" 0 0 "${parts[0]}" ;;
        2) printf "%02d:%02d:%02d.000" 0 "${parts[0]}" "${parts[1]}" ;;
        3) printf "%02d:%02d:%02d.000" "${parts[0]}" "${parts[1]}" "${parts[2]}" ;;
        *) echo "Invalid time format: $1" >&2; exit 1 ;;
    esac
}

# Convert "HH:MM:SS.mmm" → seconds (as a floating-point expression for bc)
time_to_seconds() {
    IFS=: read -r h m s <<< "$1"
    h=${h:-0}
    m=${m:-0}
    s=${s:-0}
    echo "$h * 3600 + $m * 60 + $s" | bc
}

# Convert seconds (floating) → "HH:MM:SS.mmm"
seconds_to_time() {
    local total_seconds="$1"
    local h m s
    h=$(echo "$total_seconds / 3600" | bc)
    m=$(echo "($total_seconds % 3600) / 60" | bc)
    s=$(echo "$total_seconds - ($h * 3600 + $m * 60)" | bc -l)
    printf "%02d:%02d:%06.3f" "$h" "$m" "$s"
}

get_duration() {
    ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$1"
}

# Initialize variables
INPUT=""
OUTDIR="/sdcard/Movies/ffmpeg/Trimmed"
trim_mode=""
timestamps=()
ranges=()
percentage=""
index=1

# Interactive mode when no arguments
if [ $# -eq 0 ]; then
    read -e -p "🔸ENTER INPUT FILE PATH: " INPUT
    INPUT=$(realpath "$INPUT")
    if [ ! -f "$INPUT" ]; then
        echo "❌ FILE NOT FOUND: $INPUT"
        exit 1
    fi
    
    # Interactive menu
    while true; do
        show_menu
        read choice
        
        case $choice in
            1)  # Timestamp Trim
                while true; do
                    echo -e "\n🔸TIMESTAMP TRIM (e.g., 0.5 1.0 1.5)"
                    echo "   (b) Back to main menu"
                    read -p "   ENTER TIMESTAMPS OR 'b': " timestamp_input
                    
                    if [ "$timestamp_input" = "b" ]; then
                        break
                    fi
                    
                    if [ -n "$timestamp_input" ]; then
                        timestamps=($timestamp_input)
                        trim_mode="timestamp"
                        break
                    else
                        echo "❌ Please enter at least one timestamp"
                    fi
                done
                ;;
                
            2)  # Percentage Trim
                while true; do
                    echo -e "\n🔸PERCENTAGE TRIM (e.g., 25 for 4 segments)"
                    echo "   (b) Back to main menu"
                    read -p "   ENTER PERCENTAGE OR 'b': " percentage_input
                    
                    if [ "$percentage_input" = "b" ]; then
                        break
                    fi
                    
                    if [[ "$percentage_input" =~ ^[0-9]+$ ]] && [ "$percentage_input" -ge 1 ] && [ "$percentage_input" -le 100 ]; then
                        percentage="$percentage_input"
                        trim_mode="percentage"
                        break
                    else
                        echo "❌ INVALID PERCENTAGE: Must be 1-100"
                    fi
                done
                ;;
                
            3)  # Range Trim
                while true; do
                    echo -e "\n🔸RANGE TRIM (e.g., 0.5-1.0 1.5-2.0)"
                    echo "   (b) Back to main menu"
                    read -p "   ENTER RANGES OR 'b': " ranges_input
                    
                    if [ "$ranges_input" = "b" ]; then
                        break
                    fi
                    
                    if [ -n "$ranges_input" ]; then
                        ranges=($ranges_input)
                        trim_mode="range"
                        break
                    else
                        echo "❌ Please enter at least one range"
                    fi
                done
                ;;
                
            4)  # Start Processing
                if [ -z "$trim_mode" ]; then
                    echo "❌ NO TRIMMING METHOD SELECTED"
                    read -p "   PRESS ENTER TO CONTINUE..."
                else
                    break
                fi
                ;;
                
            5)  # Exit
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
    # Command-line mode
    INPUT="$1"
    shift
    INPUT=$(realpath "$INPUT")
    
    if [ -z "$INPUT" ] || [ ! -f "$INPUT" ]; then
        echo "❌ FILE NOT FOUND: $INPUT"
        exit 1
    fi

    # Process raw arguments
    raw_args=("$@")
    args_processed=()
    i=0
    while [ $i -lt $# ]; do
        current="${raw_args[i]}"
        if [[ $current == "-" ]]; then
            if [ $i -gt 0 ] && [ $i -lt $(($#-1)) ]; then
                prev="${raw_args[i-1]}"
                next="${raw_args[i+1]}"
                if [[ $prev =~ ^[0-9.]+$ ]] && [[ $next =~ ^[0-9.]+$ ]]; then
                    unset 'args_processed[${#args_processed[@]}-1]'
                    combined="$prev-$next"
                    args_processed+=("$combined")
                    i=$((i+2))
                    continue
                fi
            fi
            echo "Warning: ignoring dash without valid surrounding times" >&2
        else
            args_processed+=("$current")
        fi
        i=$((i+1))
    done

    # Determine trim mode
    if [ ${#args_processed[@]} -gt 0 ]; then
        range_mode=false
        for token in "${args_processed[@]}"; do
            if [[ $token == *"-"* ]]; then
                range_mode=true
                break
            fi
        done

        if $range_mode; then
            trim_mode="range"
            ranges=("${args_processed[@]}")
        elif [[ "${args_processed[0]}" =~ ^([0-9]+)%$ ]]; then
            trim_mode="percentage"
            percentage="${BASH_REMATCH[1]}"
        else
            trim_mode="timestamp"
            timestamps=("${args_processed[@]}")
        fi
    fi
fi

# Create output directory if it doesn't exist
mkdir -p "$OUTDIR"
BASENAME=$(basename "$INPUT")
NAME="${BASENAME%.*}"
extension="${BASENAME##*.}"

# ── Processing Functions ─────────────────────────────────────────────────────

process_range_trim() {
    segments=()
    for token in "${ranges[@]}"; do
        if [[ $token == *"-"* ]]; then
            IFS='-' read -ra parts <<< "$token"
            if [ ${#parts[@]} -ne 2 ]; then
                echo "Invalid range: $token"
                exit 1
            fi
            start_time=$(normalize_time "${parts[0]}")
            end_time=$(normalize_time "${parts[1]}")
            segments+=("$start_time|$end_time")
        else
            echo "In range mode, all tokens must be ranges. Found: $token"
            exit 1
        fi
    done

    for seg in "${segments[@]}"; do
        IFS='|' read -r start end <<< "$seg"
        OUTPUT="$OUTDIR/${NAME}_part${index}.$extension"
        DURATION=$(echo "$(time_to_seconds "$end") - $(time_to_seconds "$start")" | bc)

        echo -n "✂️  Trimming part $index: $start → $end... "

        ffmpeg -hide_banner -loglevel error -ss "$start" -to "$end" -i "$INPUT" \
            -c:v copy -c:a copy -progress pipe:1 -nostats "$OUTPUT" 2>/dev/null |
        while IFS= read -r line; do
            if [[ $line =~ out_time_ms=([0-9]+) ]]; then
                ms=${BASH_REMATCH[1]}
                raw_pct=$(echo "scale=0; ($ms / 1000000) * 100 / $DURATION" | bc -l)
                if (( raw_pct > 100 )); then
                    pct=100
                else
                    pct=$raw_pct
                fi
                printf "\r   Progress: %3d%%" "$pct"
            fi
        done

        echo -e "\r   ✅ Done trimming part.\n"
        ((index++))
    done
}

process_timestamp_trim() {
    START_TIMES=()
    for raw in "${timestamps[@]}"; do
        START_TIMES+=("$(normalize_time "$raw")")
    done

    VIDEO_DURATION=$(get_duration "$INPUT")
    NUM_PARTS=${#START_TIMES[@]}
    END_OF_VIDEO=$(seconds_to_time "$VIDEO_DURATION")

    for ((i = 0; i < NUM_PARTS; i++)); do
        START="${START_TIMES[i]}"
        if (( i < NUM_PARTS - 1 )); then
            END="${START_TIMES[i + 1]}"
        else
            END="$END_OF_VIDEO"
        fi

        OUTPUT="$OUTDIR/${NAME}_part${index}.$extension"
        DURATION=$(echo "$(time_to_seconds "$END") - $(time_to_seconds "$START")" | bc)

        echo -n "✂️  Trimming part $index: $START → $END... "

        ffmpeg -hide_banner -loglevel error -ss "$START" -to "$END" -i "$INPUT" \
            -c:v copy -c:a copy -progress pipe:1 -nostats "$OUTPUT" 2>/dev/null |
        while IFS= read -r line; do
            if [[ $line =~ out_time_ms=([0-9]+) ]]; then
                ms=${BASH_REMATCH[1]}
                raw_pct=$(echo "scale=0; ($ms / 1000000) * 100 / $DURATION" | bc -l)
                if (( raw_pct > 100 )); then
                    pct=100
                else
                    pct=$raw_pct
                fi
                printf "\r   Progress: %3d%%" "$pct"
            fi
        done

        echo -e "\r   ✅ Done trimming part.\n"
        ((index++))
    done
}

process_percentage_trim() {
    if (( percentage <= 0 || percentage > 100 )); then
        echo "❌ Invalid percentage: $percentage%"
        exit 1
    fi

    PARTS=$((100 / percentage))
    echo "📐 Splitting into $PARTS equal parts based on $percentage% increments..."

    VIDEO_DURATION=$(get_duration "$INPUT")
    START_TIMES=()
    for ((i = 0; i < PARTS; i++)); do
        PART_SECONDS=$(echo "$VIDEO_DURATION * $i / $PARTS" | bc -l)
        START_TIMES+=("$(seconds_to_time "$PART_SECONDS")")
    done

    NUM_PARTS=${#START_TIMES[@]}
    END_OF_VIDEO=$(seconds_to_time "$VIDEO_DURATION")

    for ((i = 0; i < NUM_PARTS; i++)); do
        START="${START_TIMES[i]}"
        if (( i < NUM_PARTS - 1 )); then
            NEXT_PART_SECONDS=$(echo "$VIDEO_DURATION * (i + 1) / $PARTS" | bc -l)
            END="$(seconds_to_time "$NEXT_PART_SECONDS")"
        else
            END="$END_OF_VIDEO"
        fi

        OUTPUT="$OUTDIR/${NAME}_part${index}.$extension"
        DURATION=$(echo "$(time_to_seconds "$END") - $(time_to_seconds "$START")" | bc)

        echo -n "✂️  Trimming part $index: $START → $END... "

        ffmpeg -hide_banner -loglevel error -ss "$START" -to "$END" -i "$INPUT" \
            -c:v copy -c:a copy -progress pipe:1 -nostats "$OUTPUT" 2>/dev/null |
        while IFS= read -r line; do
            if [[ $line =~ out_time_ms=([0-9]+) ]]; then
                ms=${BASH_REMATCH[1]}
                raw_pct=$(echo "scale=0; ($ms / 1000000) * 100 / $DURATION" | bc -l)
                if (( raw_pct > 100 )); then
                    pct=100
                else
                    pct=$raw_pct
                fi
                printf "\r   Progress: %3d%%" "$pct"
            fi
        done

        echo -e "\r   ✅ Done trimming part.\n"
        ((index++))
    done
}

# ── Main Execution ─────────────────────────────────────────────────────────────

case "$trim_mode" in
    "timestamp")  process_timestamp_trim ;;
    "range")      process_range_trim ;;
    "percentage") process_percentage_trim ;;
    *)
        if [ $# -gt 0 ]; then
            echo "❌ No valid trimming mode specified."
            exit 1
        fi
        ;;
esac

if [ -n "$trim_mode" ]; then
    echo "🎉 All trimming operations completed. Output saved to:"
    echo "$OUTDIR"
fi
exit 0