#!/data/data/com.termux/files/usr/bin/bash

# Trap CTRL+C to clean up and exit
trap ctrl_c INT

ctrl_c() {
    echo -e "\n🛑 CTRL+C detected. Stopping all processes..."
    # Kill any running ffmpeg processes
    pkill -f ffmpeg 2>/dev/null
    # Remove temporary files if they exist
    [ -n "$temp_log_dir" ] && rm -rf "$temp_log_dir" 2>/dev/null
    [ -n "$logfile" ] && rm -f "$logfile"* 2>/dev/null
    echo "💀 Process terminated by user"
    exit 1
}

# ── Normalize time input ────────────────────────────
normalize_time() {
    IFS='.' read -ra parts <<< "$1"
    len=${#parts[@]}
    ms=0; s=0; m=0; h=0

    case $len in
        1) s="${parts[0]}" ;;
        2) m="${parts[0]}"; s="${parts[1]}" ;;
        3) h="${parts[0]}"; m="${parts[1]}"; s="${parts[2]}" ;;
        4) h="${parts[0]}"; m="${parts[1]}"; s="${parts[2]}"; ms="${parts[3]}" ;;
        *) echo "❌ Invalid time format: $1" >&2; exit 1 ;;
    esac

    # normalize to decimal to avoid octal interpretation
    h=$((10#$h))
    m=$((10#$m))
    s=$((10#$s))
    ms=$((10#$ms))

    # validate
    if (( s > 59 || m > 59 || ms > 999 )); then
        echo "❌ Invalid time: $h:$m:$s.$ms" >&2
        exit 1
    fi

    printf "%02d:%02d:%02d.%03d" "$h" "$m" "$s" "$ms"
}

time_to_seconds() {
    IFS=':. ' read -r h m s_ms <<< "$1"
    s=$(echo "$s_ms" | cut -d. -f1)
    ms=$(echo "$s_ms" | cut -d. -f2)
    awk -v h="$h" -v m="$m" -v s="$s" -v ms="$ms" 'BEGIN {
        total = h * 3600 + m * 60 + s + (ms / 1000)
        printf "%.3f", total
    }'
}

seconds_to_time() {
    awk -v t="$1" 'BEGIN {
        h = int(t / 3600)
        m = int((t % 3600) / 60)
        s = t - (h * 3600 + m * 60)
        ms = s - int(s)
        printf "%02d:%02d:%02d.%03d", h, m, int(s), ms * 1000
    }'
}

get_duration() {
    ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$1"
}

# ── Menu UI ──────────────────────────────────────────
show_menu() {
    clear
    echo "╔════════════════════════════════════════════╗"
    echo "║            VIDEO TRIMMING TOOL             ║"
    echo "╠════════════════════════════════════════════╣"
    echo "║  INPUT: $INPUT"
    echo "╠════════════════════════════════════════════╣"
    echo "║  1. Range Trim (start-end pairs)	     ║"
    echo "║  2. Timestamp Trim (consecutive segments)  ║"
    echo "║  3. Equally Split Parts      	             ║"
    echo "║  4. Start Processing                       ║"
    echo "║  5. Exit                                   ║"
    echo "╚════════════════════════════════════════════╝"
    echo -n "   🔸SELECT OPTION [1-5]: "
}

# ── Init ─────────────────────────────────────────────
INPUT=""
OUTDIR="/sdcard/Movies/ffmpeg/Trimmed"
trim_mode=""
timestamps=()
ranges=()
DO_REENCODE=false
crf=23
preset="medium"
audio=libopus
audio_b=64k
COMPRESS=false
TARGET_MB=""
percentage=""
index=1

# ── Interactive Entry ────────────────────────────────
if [ $# -eq 0 ]; then
    read -e -p "🔸ENTER VIDEO FILE PATH (e.g., /sdcard/Movies/video.mp4): " INPUT
    INPUT=$(realpath "$INPUT")
    [ ! -f "$INPUT" ] && echo "❌ FILE NOT FOUND: $INPUT" && exit 1

    while true; do
        show_menu
        read choice
        case $choice in
        	1)
			    echo -e "\n🔸 RANGE TRIM MODE"
			    echo ""
			    echo "   MANUALLY DEFINE EXACT START–END PAIRS FOR TRIMMING"
			    echo ""
			    echo "   Format: START-END START-END ...(space seperated pairs)"
			    echo "   Supports:"
			    echo "     s = start of main video"
			    echo "     e = end of main video"
			    echo "     m = merge with previous output (if duration ≤ 2min)"
			    echo ""
			    echo "   For Example, Input: s-11 2.2-4.4.4 m 5.5.5.555-e"
			    echo "   Will generate 2 trimmed parts:"
			    echo "    Part 1 from 00:00:00.000 to 00:00:11.000"
			    echo "    Part 2 from 02:02:02.000 to 04:04:04.000"
			    echo "    (will be merged with next part only if total is ≤ 2min)" 
			    echo "    Part 3 from 05:05:05.555 to end of video"
			    echo ""
			    echo "   For milliseconds use full format otherwise it will fail"
			    echo "     0.0.1.111 = 00:00:01.111 ✅"
			    echo "         1.111 ≠ 00:00:01.111 ❌"
			    echo ""
			    echo "   Otherwise you can use"
			    echo "             1 = 00:00:01.000"
			    echo "          10.1 = 00:10:01.000"
			    echo "        4.1.10 = 04:01:10.000 and so on..."
			    echo ""
			    while true; do
			        read -p "   ➤ ENTER RANGES: " r
			        [ "$r" = "b" ] && break
			        [ -z "$r" ] && continue
			    echo ""
			    echo "   CHOOSE TRIM METHOD:"
			    echo "    1 = Copy (quick, approximate, original format)"
			    echo "    2 = Re-encode (slower, accurate, mp4 output)"
			    echo ""
			        read -p "   ➤ ENTER METHOD: " method
			        if [[ "$method" = "2" ]]; then
			            DO_REENCODE=true
			    echo ""
			    echo "   RE-ENCODE TRIMMED PARTS INTO H.264 VIDEO FORMAT"
			    echo ""
			    echo "   CHOOSE CRF TO DETERMINE QUALITY"
			    echo "   Available CRF range for H.264 (libx264) is from 0 to 51"
			    echo ""
			    echo "   Practical CRF Values for H.264:"
				echo "   18-19 = Visually lossless quality"
				echo "   20–23 = Good quality"
				echo "   28+ = Noticeable loss in quality"
				echo ""
				echo "   Lower = Higher quality = Larger file size"
			    echo "   Higher = Lower quality = Smaller file size"
				echo ""
			            read -p "   ➤ ENTER CRF (⏎ for default:23): " crf
			    echo ""
				echo "   CHOOSE PRESET TO ADJUST ENCODING SPEED"
				echo "   Available preset options for H.264 (libx264):"
				echo ""
				echo "   ultrafast, superfast, veryfast [Low compression presets]"
				echo "   faster, fast, medium [Moderate compression presets]"
				echo "   slow, slower, veryslow [High Compression presets]"
				echo "   placebo [Impractically slow, Higest compression]"
				echo ""
				echo "   Slower = Higher Compression efficiency = Smaller file size"
				echo "   Faster = Lower Compression efficiency = Larger file size"
				echo ""
			            read -p "   ➤ ENTER PRESET (⏎ for default:medium): " preset
			            crf="${crf:-23}"
			            preset="${preset:-medium}"
			    echo ""
				echo "   CHOOSE WETHER TO COMPRESS VIDEO TO TARGET SIZE"
				echo ""        
			            # Ask about compression
			            read -p "   ➤ COMPRESS OUTPUT? [y/N]: " compress_choice
			            if [[ "$compress_choice" =~ ^[Yy]$ ]]; then
			                COMPRESS=true
			                while true; do
			                    read -p "   ➤ TARGET SIZE IN MB (e.g., 10, 10.5, etc.): " TARGET_MB
			                    [[ "$TARGET_MB" =~ ^[0-9]+(\.[0-9]+)?$ ]] && break
			                    echo "❌ Invalid input. Please enter a number."
			                done
			            fi
			        else
			            DO_REENCODE=false
			            COMPRESS=false
			        fi
			
			        ranges=($r)
			        trim_mode="range"
			        break
			    done
			    ;;
			    
            2)
			    echo -e "\n🔸 TIMESTAMP TRIM MODE"
			    echo""
			    echo "   SPLIT VIDEO INTO SEGMENTS BASED ON TIME POINTS."
			    echo ""
			    echo "   Format: TIMESTAMP TIMESTAMP TIMESTAMP ..."
			    echo "   The first segment always starts from 00:00:00.000."
			    echo "   Last segment ends at video end."
			    echo ""
			    echo "   For Example, Input: 1.1.1.111 2.2.2.222 3.3.3.333"
			    echo "   Will generate 4 split parts:"
			    echo "    Part 1 from 00:00:00.000 to 01:01:01.111"
			    echo "    Part 2 from 01:01:01.111 to 02:02:02.222"
			    echo "    Part 3 from 02:02:02.222 to 03:03:03.333"
			    echo "    Part 4 from 03:03:03.333 to end of video"
			    echo ""
			    echo "   For milliseconds use full format otherwise will fail"
			    echo "       0.0.1.111 = 00:00:01.111 ✅"
			    echo "           1.111 ≠ 00:00:01.111 ❌"
			    echo ""
			    echo "   Otherwise you can use..."
			    echo "               1 = 00:00:01.000"
			    echo "            10.1 = 00:10:01.000"
			    echo "          4.1.10 = 04:01:10.000 and so on..."
			    echo ""
			    
                while true; do
                    echo "   TYPE 'b' TO GO BACK TO THE MAIN MENU"
                    read -p "  ➤ ENTER TIMESTAMPS: " ts
                    [ "$ts" = "b" ] && break
                    [ -n "$ts" ] && timestamps=($ts) && trim_mode="timestamp" && break
                done
                ;;
             3)
                echo -e "\n🔸 EQUAL SPLIT MODE"
                echo ""
                echo "   SPLIT VIDEO INTO EQUAL-DURATION PARTS."
                echo ""
                echo "   ➤ Format: Number of parts (2 or more)"
                echo "   ➤ Example: 4 → Creates 4 equal parts:"
                echo ""
                
                while true; do
                    echo "   TYPE 'b' TO GO BACK TO THE MAIN MENU"
                    read -p "   ENTER NUMBER OF PARTS: " p
                    [[ "$p" = "b" ]] && break
                    [[ "$p" =~ ^[0-9]+$ && "$p" -ge 2 ]] && parts_count="$p" && trim_mode="equal_split" && break
                    echo "❌ INVALID: Must be 2 or more"
                done
                ;;
             
            4) [ -z "$trim_mode" ] && echo "❌ NO MODE SELECTED" && read -p "   ENTER TO CONTINUE..." || break ;;
            5) echo "   EXITING..." && exit 0 ;;
            *) echo "❌ INVALID OPTION" && sleep 1 ;;
        esac
    done

else
    INPUT=$(realpath "$1")
    [ ! -f "$INPUT" ] && echo "❌ FILE NOT FOUND: $INPUT" && exit 1
    shift

    raw_args=("$@")
    args_processed=()
    i=0
    while [ $i -lt $# ]; do
        current="${raw_args[i]}"
        if [[ $current == "-" ]]; then
            prev="${raw_args[i-1]}"
            next="${raw_args[i+1]}"
            [[ "$prev" =~ ^[0-9.s]+$ && "$next" =~ ^[0-9.e]+$ ]] && {
                unset 'args_processed[${#args_processed[@]}-1]'
                args_processed+=("$prev-$next")
                i=$((i+2))
                continue
            }
        fi
        args_processed+=("$current")
        i=$((i+1))
    done

    range_mode=false
    for token in "${args_processed[@]}"; do
        [[ $token == *"-"* ]] && range_mode=true && break
    done

    if $range_mode; then
        trim_mode="range"
        ranges=("${args_processed[@]}")
    elif [[ "${args_processed[0]}" =~ ^[0-9]+$ && "${args_processed[0]}" -ge 2 ]]; then
        trim_mode="equal_split"
        parts_count="${args_processed[0]}"
    else
        trim_mode="timestamp"
        timestamps=("${args_processed[@]}")
    fi
fi

mkdir -p "$OUTDIR"
BASENAME=$(basename "$INPUT")
NAME="${BASENAME%.*}"
extension="${BASENAME##*.}"

# ── TRIM METHODS ─────────────────────────────────────

# Range Trimming
process_range_trim() {
    segments=()
    merge_marks=()     # mark if a segment belongs to a merge group
    processed_flags=() # mark finished segments
    VIDEO_DURATION=$(get_duration "$INPUT")
    END_OF_VIDEO=$(seconds_to_time "$VIDEO_DURATION")

    final_files=()
    current_merge_group=()
    segment_index=0
    i=0

    echo ""
    echo "🔍 Processing ranges:"

    # ---------------- FIRST PASS: collect all segments ----------------
    while [ $i -lt ${#ranges[@]} ]; do
        token="${ranges[i]}"

        # ---- MERGE MARKER ----
        if [[ "$token" == "m" ]]; then
            # Start or extend a merge group with the previous segment
            if [ ${#current_merge_group[@]} -eq 0 ] && [ $segment_index -gt 0 ]; then
                current_merge_group=($((segment_index - 1)))
                merge_marks[$((segment_index - 1))]=1
            fi

            # Expect a RANGE next
            if [ $i -lt $((${#ranges[@]} - 1)) ] && [[ "${ranges[i+1]}" == *"-"* ]]; then
                ((i++))
                IFS='-' read -ra parts <<< "${ranges[i]}"
                raw_start="${parts[0]}"; raw_end="${parts[1]}"

                [[ "$raw_start" == "s" ]] && start_time="00:00:00.000" || start_time=$(normalize_time "$raw_start")
                [[ "$raw_end"   == "e" ]] && end_time="$END_OF_VIDEO"    || end_time=$(normalize_time "$raw_end")

                segments+=("$start_time|$end_time")
                merge_marks[$segment_index]=1
                current_merge_group+=($segment_index)
                ((segment_index++))

                # Consume repeating "... m RANGE ..." sequences
                while [ $i -lt $((${#ranges[@]} - 2)) ] && [[ "${ranges[i+1]}" == "m" && "${ranges[i+2]}" == *"-"* ]]; do
                    ((i+=2))
                    IFS='-' read -ra parts <<< "${ranges[i]}"
                    raw_start="${parts[0]}"; raw_end="${parts[1]}"

                    [[ "$raw_start" == "s" ]] && start_time="00:00:00.000" || start_time=$(normalize_time "$raw_start")
                    [[ "$raw_end"   == "e" ]] && end_time="$END_OF_VIDEO"    || end_time=$(normalize_time "$raw_end")

                    segments+=("$start_time|$end_time")
                    merge_marks[$segment_index]=1
                    current_merge_group+=($segment_index)
                    ((segment_index++))
                done
            fi

            ((i++))
            continue
        fi

        # ---- RANGE TOKEN ----
        if [[ $token == *"-"* ]]; then
            IFS='-' read -ra parts <<< "$token"
            raw_start="${parts[0]}"
            raw_end="${parts[1]}"

            [[ "$raw_start" == "s" ]] && start_time="00:00:00.000" || start_time=$(normalize_time "$raw_start")
            [[ "$raw_end"   == "e" ]] && end_time="$END_OF_VIDEO"    || end_time=$(normalize_time "$raw_end")

            segments+=("$start_time|$end_time")

            # peek ahead for merge marker
            if [ $i -lt $((${#ranges[@]} - 1)) ] && [[ "${ranges[i+1]}" == "m" ]]; then
                merge_marks[$segment_index]=1
            fi

            ((segment_index++))
        fi

        ((i++))
    done

    # ---------------- PREVIEW LIST ----------------
    echo ""
    for idx in "${!segments[@]}"; do
        IFS='|' read -r st en <<< "${segments[idx]}"
        if [[ "${merge_marks[$idx]}" == "1" ]]; then
            echo "   $((idx+1))) $st → $en [merge group]"
        else
            echo "   $((idx+1))) $st → $en"
        fi
    done
    echo ""

    # ---------------- SECOND PASS: actual processing ----------------
    current_merge_group=()
    segment_index=0
    i=0

    while [ $i -lt ${#ranges[@]} ]; do
        token="${ranges[i]}"

        # ---- MERGE MARKER ----
        if [[ "$token" == "m" ]]; then
            if [ ${#current_merge_group[@]} -eq 0 ] && [ $segment_index -gt 0 ]; then
                current_merge_group=($((segment_index - 1)))
            fi

            if [ $i -lt $((${#ranges[@]} - 1)) ] && [[ "${ranges[i+1]}" == *"-"* ]]; then
                ((i++))
                IFS='-' read -ra parts <<< "${ranges[i]}"
                raw_start="${parts[0]}"; raw_end="${parts[1]}"
                [[ "$raw_start" == "s" ]] && start_time="00:00:00.000" || start_time=$(normalize_time "$raw_start")
                [[ "$raw_end"   == "e" ]] && end_time="$END_OF_VIDEO"    || end_time=$(normalize_time "$raw_end")
                segments[$segment_index]="$start_time|$end_time"
                current_merge_group+=($segment_index)
                ((segment_index++))
                while [ $i -lt $((${#ranges[@]} - 2)) ] && [[ "${ranges[i+1]}" == "m" && "${ranges[i+2]}" == *"-"* ]]; do
                    ((i+=2))
                    IFS='-' read -ra parts <<< "${ranges[i]}"
                    raw_start="${parts[0]}"; raw_end="${parts[1]}"
                    [[ "$raw_start" == "s" ]] && start_time="00:00:00.000" || start_time=$(normalize_time "$raw_start")
                    [[ "$raw_end"   == "e" ]] && end_time="$END_OF_VIDEO"    || end_time=$(normalize_time "$raw_end")
                    segments[$segment_index]="$start_time|$end_time"
                    current_merge_group+=($segment_index)
                    ((segment_index++))
                done
            fi

            if [ ${#current_merge_group[@]} -gt 0 ]; then
                echo "⛓️ Merge group detected: segments ${current_merge_group[*]}"
                process_merge_group "${current_merge_group[@]}"
                for idx in "${current_merge_group[@]}"; do processed_flags[$idx]=1; done
                current_merge_group=()
            fi

            ((i++))
            continue
        fi

        # ---- RANGE TOKEN ----
        if [[ $token == *"-"* ]]; then
            IFS='-' read -ra parts <<< "$token"
            raw_start="${parts[0]}"; raw_end="${parts[1]}"
            [[ "$raw_start" == "s" ]] && start_time="00:00:00.000" || start_time=$(normalize_time "$raw_start")
            [[ "$raw_end"   == "e" ]] && end_time="$END_OF_VIDEO"    || end_time=$(normalize_time "$raw_end")
            segments[$segment_index]="$start_time|$end_time"

            if [ $i -lt $((${#ranges[@]} - 1)) ] && [[ "${ranges[i+1]}" == "m" ]]; then
                current_merge_group=($segment_index)
            else
                process_individual_segment "$segment_index"
                processed_flags[$segment_index]=1
            fi

            ((segment_index++))
        fi

        ((i++))
    done

    # safety net: process any remaining segments not marked processed
    for i in "${!segments[@]}"; do
        if [[ "${processed_flags[$i]}" == "1" ]]; then
            continue
        fi
        process_individual_segment "$i"
        processed_flags[$i]=1
    done

    echo ""
    echo "🎉 Final output files:"
    for file in "${final_files[@]}"; do
        if [ -f "$file" ]; then
            size=$(stat -c %s "$file")
            size_mb=$(awk -v s="$size" 'BEGIN { printf "%.2f", s / (1024*1024) }')
            echo "   📁 $(basename "$file") (${size_mb}MB)"
        else
            echo "   ❌ $(basename "$file") (file missing)"
        fi
    done
}

# Function to compress a video file
compress_video() {
    local input="$1"
    local output="$2"
    local duration="$3"
    
    # Calculate bitrate for target size
    local target_bytes=$(awk -v mb="$TARGET_MB" 'BEGIN { printf "%.0f", mb * 1024 * 1024 }')
    local audio_bitrate=64 # kbps
    local bitrate=$(awk -v dur="$duration" -v audio="$audio_bitrate" -v target="$target_bytes" \
                   'BEGIN { 
                     total_bits = target * 8;
                     audio_bits = audio * 1000 * dur;
                     video_bits = total_bits - audio_bits;
                     if (video_bits < 0) video_bits = 1000;
                     printf "%.2f", (video_bits / dur) / 1000 * 0.97
                   }')
    
    local video_opts=$(
        awk -v br="$bitrate" 'BEGIN {
            if (br + 0 == br && br > 0) {
                bufsize = br * 2;
                if (bufsize < 100) bufsize = 100;
                printf "-b:v %dk -maxrate %dk -bufsize %dk", br, br, bufsize;
            } else {
                print "-b:v 2000k -maxrate 2000k -bufsize 4000k";
            }
        }'
    )
    
    # Compress the video with progress
    (
        ffmpeg -hide_banner -loglevel error -i "$input" -c:v libx264 -threads 1 $video_opts -preset "$preset" -c:a "$audio" -b:a "$audio_b" \
            -progress pipe:1 -nostats "$output" 2>/dev/null |
        while read -r line; do
            [[ $line =~ out_time_ms=([0-9]+) ]] && ms=${BASH_REMATCH[1]} &&
            pct=$(awk -v ms="$ms" -v dur="$duration" 'BEGIN {
                s = ms / 1000000; p = s * 100 / dur
                if (p > 100) p = 100
                printf "%d", p
            }') &&
            printf "\r   Progress: %3d%% (Bitrate: %.0fk)" "$pct" "$bitrate"
        done
    )
    
    printf "\r\033[2K"
    
    # Verify size and correct if needed
    local final_size=$(stat -c %s "$output")
    if [ "$final_size" -gt "$target_bytes" ]; then
        echo -e "\n‼️ Output size too large, running quick correction pass..."
        
        # Correction pass with progress
        (
            ffmpeg -y -i "$output" -c:v libx264 -threads 1 -b:v "${corrected_bitrate}k" -maxrate "${corrected_bitrate}k" \
                -bufsize $((corrected_bitrate * 2))k -c:a copy -progress pipe:1 -nostats "${output}.tmp" 2>/dev/null |
            while read -r line; do
                [[ $line =~ out_time_ms=([0-9]+) ]] && ms=${BASH_REMATCH[1]} &&
                pct=$(awk -v ms="$ms" -v dur="$duration" 'BEGIN {
                    s = ms / 1000000; p = s * 100 / dur
                    if (p > 100) p = 100
                    printf "%d", p
                }') &&
                printf "\r   Correction: %3d%% (Bitrate: %.0fk)" "$pct" "$corrected_bitrate"
            done
        )
        
        printf "\r\033[2K"
        mv "${output}.tmp" "$output"
    fi
    
    # Remove original file
    rm -f "$input"
    
    echo -e "\r\033[2K   ✅ Done\n"
}

# Process a single segment by index
process_individual_segment() {
    local seg_index="$1"
    IFS='|' read -r start end <<< "${segments[$seg_index]}"
    local DURATION=$(awk -v s="$(time_to_seconds "$start")" -v e="$(time_to_seconds "$end")" 'BEGIN { print e - s }')
    
    local final_output="$OUTDIR/${NAME}_trim${index}.mp4"

    echo ""
    echo "✂️ Trimming: $start → $end ($(seconds_to_time "$DURATION"))"

    if $COMPRESS; then
        # Calculate bitrate for target size
        local target_bytes=$(awk -v mb="$TARGET_MB" 'BEGIN { printf "%.0f", mb * 1024 * 1024 }')
        local audio_bitrate=64 #kbps
        local bitrate=$(awk -v dur="$DURATION" -v audio="$audio_bitrate" -v target="$target_bytes" \
                       'BEGIN { 
                         total_bits = target * 8;
                         audio_bits = audio * 1000 * dur;
                         video_bits = total_bits - audio_bits;
                         if (video_bits < 0) video_bits = 1000;
                         printf "%.2f", (video_bits / dur) / 1000 * 0.97
                       }')
        
        local video_opts=$(
            awk -v br="$bitrate" 'BEGIN {
                if (br + 0 == br && br > 0) {
                    bufsize = br * 2;
                    if (bufsize < 100) bufsize = 100;
                    printf "-b:v %dk -maxrate %dk -bufsize %dk", br, br, bufsize;
                } else {
                    print "-b:v 2000k -maxrate 2000k -bufsize 4000k";
                }
            }'
        )
        
        # Trim and compress in one step
        (
            ffmpeg -hide_banner -loglevel error -ss "$start" -to "$end" -i "$INPUT" \
                -c:v libx264 -threads 1 $video_opts -preset "$preset" -pix_fmt yuv420p \
                -c:a "$audio" -b:a "$audio_b" -progress pipe:1 -nostats "$final_output" 2>/dev/null |
            while read -r line; do
                [[ $line =~ out_time_ms=([0-9]+) ]] && ms=${BASH_REMATCH[1]} &&
                pct=$(awk -v ms="$ms" -v dur="$DURATION" 'BEGIN {
                    s = ms / 1000000; p = s * 100 / dur
                    if (p > 100) p = 100
                    printf "%d", p
                }') &&
                printf "\r   Progress: %3d%% (Bitrate: %.0fk)" "$pct" "$bitrate"
            done
        )
    elif $DO_REENCODE; then
        # Original re-encode without compression
        (
            ffmpeg -hide_banner -loglevel error -ss "$start" -to "$end" -i "$INPUT" \
                -c:v libx264 -threads 1 -crf "$crf" -preset "$preset" -pix_fmt yuv420p \
                -c:a "$audio" -b:a "$audio_b" -progress pipe:1 -nostats "$final_output" 2>/dev/null |
            while read -r line; do
                [[ $line =~ out_time_ms=([0-9]+) ]] && ms=${BASH_REMATCH[1]} &&
                pct=$(awk -v ms="$ms" -v dur="$DURATION" 'BEGIN {
                    s = ms / 1000000; p = s * 100 / dur
                    if (p > 100) p = 100
                    printf "%d", p
                }') &&
                printf "\r   Progress: %3d%%" "$pct"
            done
        )
    else
        # COPY METHOD (fast, no re-encoding)
        (
            ffmpeg -hide_banner -loglevel error -ss "$start" -to "$end" -i "$INPUT" \
                -c:v copy -c:a copy -progress pipe:1 -nostats "$final_output" 2>/dev/null |
            while read -r line; do
                [[ $line =~ out_time_ms=([0-9]+) ]] && ms=${BASH_REMATCH[1]} &&
                pct=$(awk -v ms="$ms" -v dur="$DURATION" 'BEGIN {
                    s = ms / 1000000; p = s * 100 / dur
                    if (p > 100) p = 100
                    printf "%d", p
                }') &&
                printf "\r   Progress: %3d%% (Copy method)" "$pct"
            done
        )
    fi

    printf "\r\033[2K"
    echo -e "\r\033[2K   ✅ Done\n"

    final_files+=("$final_output")
    ((index++))
}

# Process a merge group (list of indices)
process_merge_group() {
    local group=("$@")
    local total_dur=0
    local temp_files=()

    # Trim each segment in group
    for seg_index in "${group[@]}"; do
        IFS='|' read -r start end <<< "${segments[$seg_index]}"
        local DURATION=$(awk -v s="$(time_to_seconds "$start")" -v e="$(time_to_seconds "$end")" 'BEGIN { print e - s }')

        echo "✂️ Trimming (for merge): $start → $end ($(seconds_to_time "$DURATION"))"

        local temp_output="$OUTDIR/${NAME}_temp${seg_index}.mp4"

        if $DO_REENCODE; then
            # Re-encode method
            (
                ffmpeg -hide_banner -loglevel error -ss "$start" -to "$end" -i "$INPUT" \
                    -c:v libx264 -threads 1 -crf "$crf" -preset "$preset" -pix_fmt yuv420p -c:a "$audio" -b:a "$audio_b" \
                    -progress pipe:1 -nostats "$temp_output" 2>/dev/null |
                while read -r line; do
                    [[ $line =~ out_time_ms=([0-9]+) ]] && ms=${BASH_REMATCH[1]} &&
                    pct=$(awk -v ms="$ms" -v dur="$DURATION" 'BEGIN {
                        s = ms / 1000000; p = s * 100 / dur
                        if (p > 100) p = 100
                        printf "%d", p
                    }') &&
                    printf "\r   Progress: %3d%%" "$pct"
                done
            )
        else
            # Copy method
            (
                ffmpeg -hide_banner -loglevel error -ss "$start" -to "$end" -i "$INPUT" \
                    -c:v copy -c:a copy -progress pipe:1 -nostats "$temp_output" 2>/dev/null |
                while read -r line; do
                    [[ $line =~ out_time_ms=([0-9]+) ]] && ms=${BASH_REMATCH[1]} &&
                    pct=$(awk -v ms="$ms" -v dur="$DURATION" 'BEGIN {
                        s = ms / 1000000; p = s * 100 / dur
                        if (p > 100) p = 100
                        printf "%d", p
                    }') &&
                    printf "\r   Progress: %3d%% (Copy)" "$pct"
                done
            )
        fi

        printf "\r\033[2K"
        echo -e "\r\033[2K   ✅ Done\n"

        file_dur=$(get_duration "$temp_output")
        total_dur=$(awk -v total="$total_dur" -v dur="$file_dur" 'BEGIN { print total + dur }')
        temp_files+=("$temp_output")
    done

    echo "⛓️ Merging ${#group[@]} segments (total: $(seconds_to_time "$total_dur"))"

    # Create concat list
    concat_list="$OUTDIR/concat_list.txt"
    > "$concat_list"
    for temp_file in "${temp_files[@]}"; do
        echo "file '$temp_file'" >> "$concat_list"
    done

    # Merge files
    merged_output="$OUTDIR/${NAME}_trim${index}.mp4"
    
    if $COMPRESS; then
        # First merge, then compress
        merged_temp="$OUTDIR/merged_temp.mp4"
        ffmpeg -hide_banner -loglevel error -f concat -safe 0 -i "$concat_list" -c copy "$merged_temp" 2>/dev/null
        echo "🗜️ Compressing merged file..."
        compress_video "$merged_temp" "$merged_output" "$total_dur"
        rm -f "$merged_temp"
    else
        # Just merge without compression
        ffmpeg -hide_banner -loglevel error -f concat -safe 0 -i "$concat_list" -c copy "$merged_output" 2>/dev/null
        echo "   ✅ Merged without compression"
    fi

    final_files+=("$merged_output")
    ((index++))

    # Cleanup
    rm -f "$concat_list"
    for temp_file in "${temp_files[@]}"; do rm -f "$temp_file"; done

    for idx in "${group[@]}"; do processed_flags[$idx]=1; done
}

#Timestamp Trimming
process_timestamp_trim() {
    START_TIMES=()
    for raw in "${timestamps[@]}"; do
        START_TIMES+=("$(normalize_time "$raw")")
    done

    VIDEO_DURATION=$(get_duration "$INPUT")
    END_OF_VIDEO=$(seconds_to_time "$VIDEO_DURATION")
    NUM_PARTS=${#START_TIMES[@]}

    # Inject 00:00:00.000 at the beginning
    ALL_TIMES=("00:00:00.000" "${START_TIMES[@]}")
    TOTAL=${#ALL_TIMES[@]}

    for ((i = 0; i < TOTAL; i++)); do
        START="${ALL_TIMES[i]}"
        if (( i < TOTAL - 1 )); then
            END="${ALL_TIMES[i + 1]}"
        else
            END="$END_OF_VIDEO"
        fi

        OUTPUT="$OUTDIR/${NAME}_part${index}.$extension"
        DURATION=$(awk -v s="$(time_to_seconds "$START")" -v e="$(time_to_seconds "$END")" 'BEGIN { print e - s }')
		local part_dur=$(seconds_to_time "$DURATION")
		
		echo ""
        echo -n "✂️ Trimming: $START → $END ($part_dur)"
        echo ""
        ffmpeg -hide_banner -loglevel error -ss "$START" -to "$END" -i "$INPUT" \
            -c:v copy -c:a copy -progress pipe:1 -nostats "$OUTPUT" 2>/dev/null |
        while read -r line; do
            [[ $line =~ out_time_ms=([0-9]+) ]] && ms=${BASH_REMATCH[1]} &&
            pct=$(awk -v ms="$ms" -v dur="$DURATION" 'BEGIN {
                s = ms / 1000000; p = s * 100 / dur
                if (p > 100) p = 100
                printf "%d", p
            }') &&
            printf "\r   Progress: %3d%%" "$pct"
        done
        printf "\r\033[2K"
        echo -e "\r\033[2K   ✅ Done\n"
        ((index++))
    done
}

# ── Parts Trimming ──
process_equal_split() {
    (( parts_count < 2 )) && echo "❌ Invalid parts count: $parts_count" && exit 1
    VIDEO_DURATION=$(get_duration "$INPUT")
    END_OF_VIDEO=$(seconds_to_time "$VIDEO_DURATION")
	echo ""
    echo "✂️ Splitting into $parts_count equal parts..."
    echo "   Total duration: $(seconds_to_time "$VIDEO_DURATION")"

    for ((i = 0; i < parts_count; i++)); do
        START=$(seconds_to_time "$(awk -v d="$VIDEO_DURATION" -v i="$i" -v p="$parts_count" 'BEGIN { print d * i / p }')")
        END=$([[ $i -lt $((parts_count-1)) ]] &&
            seconds_to_time "$(awk -v d="$VIDEO_DURATION" -v i="$i" -v p="$parts_count" 'BEGIN { print d * (i + 1) / p }')" ||
            echo "$END_OF_VIDEO")
        OUTPUT="$OUTDIR/${NAME}_part${index}.$extension"
        DURATION=$(awk -v s="$(time_to_seconds "$START")" -v e="$(time_to_seconds "$END")" 'BEGIN { print e - s }')
        local part_dur=$(seconds_to_time "$DURATION")
        
        echo ""
        echo "   Part $((i+1))/$parts_count: $START → $END ($part_dur)"
        echo ""
        
        ffmpeg -hide_banner -loglevel error -ss "$START" -to "$END" -i "$INPUT" \
            -c:v copy -c:a copy -progress pipe:1 -nostats "$OUTPUT" 2>/dev/null |
        while read -r line; do
            [[ $line =~ out_time_ms=([0-9]+) ]] && ms=${BASH_REMATCH[1]} &&
            pct=$(awk -v ms="$ms" -v dur="$DURATION" 'BEGIN {
                s = ms / 1000000; p = s * 100 / dur
                if (p > 100) p = 100
                printf "%d", p
            }') &&
            printf "\r   Progress: %3d%%" "$pct"
        done
        printf "\r\033[2K"
        echo -e "\r\033[2K   ✅ Done\n"
        ((index++))
    done
}

# ── EXECUTION ────────────────────────────────────────
case "$trim_mode" in
    timestamp)     process_timestamp_trim ;;
    range)         process_range_trim ;;
    equal_split)   process_equal_split ;;
    *) echo "❌ Unknown trim mode"; exit 1 ;;
esac

echo "🎉 All trims done! Output in:"
echo "$OUTDIR"
exit 0
