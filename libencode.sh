#!/bin/bash

# ===========================================================================
# ENCODE MODULE - PROCESSING FUNCTIONS
# ===========================================================================

# Process all files in directory
process_all_files() {
    local input_dir="$1"
    if [ "${DRY_RUN:-false}" = true ]; then
        echo "===== 🔸 DRY RUN STARTED =====" | tee -a "$MAIN_LOG"
        echo "NO FILES WILL BE MODIFIED" | tee -a "$MAIN_LOG"
    fi
    
    if [ ! -d "$input_dir" ]; then
        echo "❌ ERROR: Directory does not exist: $input_dir" | tee -a "$MAIN_LOG"
        return 1
    fi
    
    if [ -z "$OUTPUT_DIR" ]; then
        echo "❌ ERROR: OUTPUT_DIR is not set." | tee -a "$MAIN_LOG"
        return 1
    fi
    
    mkdir -p "$OUTPUT_DIR" || {
        echo "❌ ERROR: Failed to create output directory: $OUTPUT_DIR" | tee -a "$MAIN_LOG"
        return 1
    }
    
    LOG_DIR="$input_dir/logs"
    mkdir -p "$LOG_DIR"
    
    # Enable case-insensitive matching
    shopt -s nocaseglob
    shopt -s nullglob
    
    # Find all video files (case-insensitive)
    files=()
    while IFS= read -r -d $'\0' file; do
        files+=("$file")
    done < <(find "$input_dir" -maxdepth 1 -type f \( \
        -iname "*.mp4" -o \
        -iname "*.mkv" -o \
        -iname "*.mov" -o \
        -iname "*.avi" -o \
        -iname "*.webm" -o \
        -iname "*.flv" \) -print0)
    
    # Restore original settings
    shopt -u nocaseglob
    
    total_files=${#files[@]}
    
    # Debug: Show found files
    echo "🔍 Found ${total_files} files:" | tee -a "$MAIN_LOG"
    for file in "${files[@]}"; do
        echo "  - $file" | tee -a "$MAIN_LOG"
    done

    for ((i=0; i<total_files; i++)); do
        input_file="${files[$i]}"
        
        if [ "${DRY_RUN:-false}" = true ]; then
            echo "🔸 DRY RUN: Processing file $((i+1))/$total_files: $(basename "$input_file")" | tee -a "$MAIN_LOG"
            dry_run_file "$input_file"
        else
            echo "Processing file $((i+1))/$total_files: $(basename "$input_file")" | tee -a "$MAIN_LOG"
            process_file "$input_file"
            
            if (( i < total_files - 1 )); then
                echo "   🔸COOLDOWN BEFORE NEXT FILE ($(seconds_to_human $COOLDOWN_TIME))..." | tee -a "$MAIN_LOG"
                countdown "$COOLDOWN_TIME"
            fi
        fi
    done

    if [ "${DRY_RUN:-false}" = true ]; then
        echo "✅ DRY RUN COMPLETE. No files were processed." | tee -a "$MAIN_LOG"
    else
        echo "✅ All processing complete" | tee -a "$MAIN_LOG"
    fi
}

# Dry run for a single file
dry_run_file() {
    local input_file="$1"
    local filename=$(basename -- "$input_file")
    local filename_noext="${filename%.*}"
    local output_file="$OUTPUT_DIR/${filename_noext}.$OUTPUT_FORMAT"
    local LOG_FILE="$LOG_DIR/${filename_noext}.log"
    
    > "$LOG_FILE"
    echo "===== DRY RUN started: $(date) =====" >> "$LOG_FILE"
    
    probe_media_info "$input_file"
    display_media_info "$input_file"
    
    determine_scaling
    
    echo "   🔸SCALING: $scale_info" | tee -a "$LOG_FILE"
    echo "   🔸OUTPUT BIT DEPTH: $bit_depth" | tee -a "$LOG_FILE"
    
    [[ -n "$scale_filter" ]] && vf_args=(-vf "$scale_filter") || vf_args=()
    
    if awk -v d="$duration" -v t="$CHUNK_THRESHOLD" 'BEGIN { exit !(d > t) }'; then
        total_chunks=$(calculate_chunk_count "$duration")
        chunk_duration_total=$(awk -v d="$duration" -v c="$total_chunks" 'BEGIN { printf "%.3f", d / c }')
        human_chunk_hms=$(float_to_timestamp "$chunk_duration_total" compact)
        echo "   🔸WOULD SPLIT INTO $total_chunks CHUNKS OF ~$(printf "%.1f" "$chunk_duration_total")s (~$human_chunk_hms) EACH" | tee -a "$LOG_FILE"
    else
        echo "   🔸WOULD ENCODE IN SINGLE PASS" | tee -a "$LOG_FILE"
    fi
    
    echo "   🔸OUTPUT FILE: $output_file" | tee -a "$LOG_FILE"
    echo "   🔸SETTINGS:" | tee -a "$LOG_FILE"
    echo "     - Video Codec: $VIDEO_CODEC" | tee -a "$LOG_FILE"
    echo "     - Audio Codec: $AUDIO_CODEC" | tee -a "$LOG_FILE"
    echo "     - Audio Bitrate: ${AUDIO_BITRATE}k" | tee -a "$LOG_FILE"
    echo "     - CRF: $CRF" | tee -a "$LOG_FILE"
    echo "     - Preset: $PRESET" | tee -a "$LOG_FILE"
    
    echo "✅ DRY RUN COMPLETE: $filename" | tee -a "$LOG_FILE"
}

# Process a single file
process_file() {
	
    local input_file="$1"
    local filename=$(basename -- "$input_file")
    local filename_noext="${filename%.*}"
    local output_file="$OUTPUT_DIR/${filename_noext}.$OUTPUT_FORMAT"

    mkdir -p "$(dirname "$output_file")" || {
        echo "❌ ERROR: Failed to create output directory for: $output_file" | tee -a "$MAIN_LOG"
        return 1
    }
    local LOG_FILE="$LOG_DIR/${filename_noext}.log"
    
    > "$LOG_FILE"
    echo "===== Processing started: $(date) =====" >> "$LOG_FILE"
    
    probe_media_info "$input_file"
    display_media_info "$input_file"
    
    determine_scaling
    
    echo "   🔸SCALING: $scale_info" | tee -a "$LOG_FILE"
    echo "   🔸OUTPUT BIT DEPTH: $bit_depth" | tee -a "$LOG_FILE"
    
    if [ -n "$scale_filter" ]; then
        if confirm_action "   🔸APPLY SCALING? [Y/n] (default: Y, auto in 10s): " 10 "y"; then
            echo "   ✅ SCALING WILL BE APPLIED." | tee -a "$LOG_FILE"
        else
            echo "   ❎ SCALING SKIPPED." | tee -a "$LOG_FILE"
            scale_filter=""
            scale_info="Skipped by user"
        fi
    else
        echo "   🔸NO SCALING NEEDED. SKIPPING PROMPT." | tee -a "$LOG_FILE"
    fi

    [[ -n "$scale_filter" ]] && vf_args=(-vf "$scale_filter") || vf_args=()
    
    local start_time=$(date +%s)
    
    local RESILIENCE_INPUT_FLAGS=(
        -fflags +discardcorrupt+genpts+igndts+ignidx
        -analyzeduration 100M
        -probesize 100M
        -err_detect ignore_err
    )
    
    local RESILIENCE_OUTPUT_FLAGS=(
        -max_muxing_queue_size 1024
    )
    
    if awk -v d="$duration" -v t="$CHUNK_THRESHOLD" 'BEGIN { exit !(d > t) }'; then
    
        total_chunks=$(calculate_chunk_count "$duration")
        chunk_duration_total=$(awk -v d="$duration" -v c="$total_chunks" 'BEGIN { printf "%.3f", d / c }')
        
        human_chunk_hms=$(float_to_timestamp "$chunk_duration_total" compact)
        echo "   🔸SPLITTING INTO $total_chunks CHUNKS OF ~$(printf "%.1f" "$chunk_duration_total")s (~$human_chunk_hms) EACH" | tee -a "$LOG_FILE"
        
        FILE_DIR=$(dirname "$input_file")
        [ -z "$FILE_DIR" ] || [ "$FILE_DIR" = "." ] && FILE_DIR=$(pwd)
        
        CHUNK_DIR="${FILE_DIR}/trim_chunks_${filename_noext}_$$"
        chunk_dir="$CHUNK_DIR"
        if ! mkdir -p "$CHUNK_DIR"; then
            echo "❌ FAILED TO CREATE TEMP DIRECTORY: $CHUNK_DIR" | tee -a "$LOG_FILE"
            return 1
        fi

        local chunk_count=0
        local converted_chunks=()
        local progress_pct=0
        
        for (( i=0; i<total_chunks; i++ )); do
            local start_sec=$(awk -v i="$i" -v cdt="$chunk_duration_total" 'BEGIN { printf "%.3f", i * cdt }')
            local end_sec
            if (( i < total_chunks - 1 )); then
                end_sec=$(awk -v s="$start_sec" -v cdt="$chunk_duration_total" 'BEGIN { printf "%.3f", s + cdt }')
            else
                end_sec="$duration"
            fi

            local start_ts=$(float_to_timestamp "$start_sec")
            local end_ts=$(float_to_timestamp "$end_sec")
            local chunk_duration_seg=$(awk -v a="$end_sec" -v b="$start_sec" 'BEGIN { printf("%.3f", a - b) }')
            
            chunk_count=$((chunk_count + 1))
            progress_pct=$(( (i * 100) / total_chunks ))
            next_pct=$(( ((i+1) * 100) / total_chunks ))
            echo "🔹 CHUNK $chunk_count/$total_chunks (${progress_pct}%-${next_pct}%): $start_ts → $end_ts" | tee -a "$LOG_FILE"

            local chunk_out="$CHUNK_DIR/encoded_${chunk_count}.$OUTPUT_FORMAT"
            local ffmpeg_log="$CHUNK_DIR/ffmpeg_chunk_${chunk_count}.log"
            
            local chunk_start_time=$(date +%s)
         
            encode_chunk "$start_ts" "$end_ts" "$chunk_duration_seg" "$chunk_out" \
                         "$chunk_count" "$total_chunks" "$progress_pct" "$ffmpeg_log"
            
            if [ ! -f "$chunk_out" ]; then
                echo "❌ CHUNK $chunk_count FAILED TO CREATE OUTPUT" | tee -a "$LOG_FILE"
                tail -n 10 "$ffmpeg_log" | tee -a "$LOG_FILE"
                rm -f "$ffmpeg_log"
                continue
            fi
            
            converted_chunks+=("$chunk_out")
            rm -f "$ffmpeg_log"
            
            [[ $chunk_count -lt $total_chunks ]] && countdown $COOLDOWN_TIME

            local chunk_end_time=$(date +%s)
            local chunk_time=$((chunk_end_time - chunk_start_time))
            echo "   🔸CHUNK ENCODING TIME: $(format_duration "$chunk_time")" | tee -a "$LOG_FILE"
        done

        local chunk_total_end_time=$(date +%s)
        local chunk_total_time=$((chunk_total_end_time - start_time))
        echo "   🔸TOTAL CHUNK ENCODING TIME: $(format_duration "$chunk_total_time")" | tee -a "$LOG_FILE"
        
        # Pass duration and converted_chunks array to merge_chunks
        if ! merge_chunks "$CHUNK_DIR" "$output_file" "$total_chunks" "$filename_noext" "$duration" "${converted_chunks[@]}"; then
        echo "❌ CHUNK MERGE FAILED FOR: $filename" | tee -a "$LOG_FILE" | tee -a "$MAIN_LOG"
        return 1
        fi

        countdown "$COOLDOWN_TIME"
        rm -rf "$CHUNK_DIR"
    
    
else    
        echo "   🔸ENCODING IN SINGLE PASS..." | tee -a "$LOG_FILE"
        local ffmpeg_log="${output_file}.fflog"
        
        local compatible_pix_fmt
        compatible_pix_fmt=$(get_compatible_pix_fmt "$VIDEO_CODEC" "$pix_fmt")
        
        local single_start_time=$(date +%s)
        
        ffmpeg -hide_banner -loglevel warning -y "${RESILIENCE_INPUT_FLAGS[@]}" -i "$input_file" -map 0 "${vf_args[@]}" \
            "${RESILIENCE_OUTPUT_FLAGS[@]}" \
            -c:v $VIDEO_CODEC -crf $CRF -preset $PRESET -pix_fmt "$compatible_pix_fmt" \
            -c:a $AUDIO_CODEC -b:a ${AUDIO_BITRATE}k -progress pipe:1 -nostats "$output_file" 2>"$ffmpeg_log" | \
        display_progress "single" "$duration"

        if [ ! -f "$output_file" ]; then
            echo "❌ OUTPUT FILE NOT CREATED" | tee -a "$LOG_FILE"
            cat "$ffmpeg_log" | tee -a "$LOG_FILE"
            rm -f "$ffmpeg_log"
            return 1
        fi
        rm -f "$ffmpeg_log"

        local single_end_time=$(date +%s)
        local single_total_time=$((single_end_time - single_start_time))
        echo "   🔸ENCODING COMPLETED IN $(format_duration "$single_total_time")" | tee -a "$LOG_FILE"
        
        # Fixed: Added missing $duration parameter
        if ! check_video_integrity "$output_file" "$duration"; then
        echo "❌ Integrity check failed after single-pass encoding!" | tee -a "$LOG_FILE" | tee -a "$MAIN_LOG"
        echo "‼️ Output may be corrupted or incomplete: $output_file" | tee -a "$LOG_FILE" | tee -a "$MAIN_LOG"
        return 1
        else
        echo "✅ Output passed integrity check" | tee -a "$LOG_FILE"
        fi
fi        
    
    display_output_info "$output_file"
    
    local file_end_time=$(date +%s)
    local file_total_time=$((file_end_time - start_time))
    echo "   🔸TOTAL PROCESSING TIME: $(format_duration "$file_total_time")" | tee -a "$LOG_FILE"
    echo "   🔸COMPLETED AT: $(date +"%I:%M %p")" | tee -a "$LOG_FILE"
    echo "✅ PROCESSING COMPLETE: $filename" | tee -a "$LOG_FILE"
    echo "✅ PROCESSING COMPLETE: $filename" >> "$MAIN_LOG"
    
    return 0
}

# Encode video chunk
encode_chunk() {
    local start_ts="$1"
    local end_ts="$2"
    local chunk_duration_seg="$3"
    local chunk_out="$4"
    local chunk_count="$5"
    local total_chunks="$6"
    local progress_pct="$7"
    local ffmpeg_log="$8"
    
    local compatible_pix_fmt
    compatible_pix_fmt=$(get_compatible_pix_fmt "$VIDEO_CODEC" "$pix_fmt")

    ffmpeg -hide_banner -y "${RESILIENCE_INPUT_FLAGS[@]}" \
        -ss "$start_ts" -to "$end_ts" -i "$input_file" -map 0 "${vf_args[@]}" \
        "${RESILIENCE_OUTPUT_FLAGS[@]}" \
        -c:v $VIDEO_CODEC -crf $CRF -preset $PRESET -pix_fmt "$compatible_pix_fmt" \
        -c:a $AUDIO_CODEC -b:a ${AUDIO_BITRATE}k -progress pipe:1 -nostats "$chunk_out" 2>"$ffmpeg_log" | \
    display_progress "chunked" "$chunk_duration_seg" "$chunk_count" "$total_chunks" "$progress_pct"
}

# Merge video chunks
merge_chunks() {
    local CHUNK_DIR="$1"
    local output_file="$2"
    local total_chunks="$3"
    local filename_noext="$4"
    local duration="$5"  # Added duration parameter
    shift 5
    local converted_chunks=("$@")  # Capture remaining args as array

    echo "🔸MERGING $total_chunks CHUNKS INTO FINAL OUTPUT..." | tee -a "$MAIN_LOG"
    concat_file="$CHUNK_DIR/concat_list.txt"
    > "$concat_file"
    for f in "${converted_chunks[@]}"; do
        [ -f "$f" ] && echo "file '$f'" >> "$concat_file"
    done

    local merge_log="$LOG_DIR/${filename_noext}_merge.log"
    temp_output="${output_file%.*}_temp.${output_file##*.}"
    fixed_output="${output_file%.*}_fixed.${output_file##*.}"
    local merge_success=0

    echo "   🔹 Attempting initial merge..." | tee -a "$MAIN_LOG"
    if ffmpeg -hide_banner -loglevel warning -y -f concat -safe 0 -i "$concat_file" \
        -c copy -fflags +genpts "$temp_output" 2>"$merge_log"; then

        echo "   🔹 Initial merge completed" | tee -a "$MAIN_LOG"

        # Now using the passed duration parameter
        if check_video_integrity "$temp_output" "$duration"; then
            echo "   ✅ MERGE SUCCESSFUL (passed integrity check)" | tee -a "$MAIN_LOG"
            mv "$temp_output" "$output_file"
            merge_success=1
        else
            echo "   ‼️ Merge completed but failed integrity check" | tee -a "$MAIN_LOG"
        fi

    else
        echo "   ❌ Initial merge failed" | tee -a "$MAIN_LOG"
    fi

    if [ "$merge_success" -eq 0 ] && [ -f "$temp_output" ]; then
        echo "   🔹 Attempting remux fallback..." | tee -a "$MAIN_LOG"
        if ffmpeg -hide_banner -loglevel warning -y -fflags +genpts -i "$temp_output" \
            -c:v copy -c:a copy -movflags +faststart "$fixed_output" 2>>"$merge_log"; then

            if check_video_integrity "$fixed_output" "$duration"; then
                echo "   ✅ REMUX SUCCESSFUL (passed integrity check)" | tee -a "$MAIN_LOG"
                mv "$fixed_output" "$output_file"
                merge_success=1
            else
                echo "   ❌ Remux failed integrity check" | tee -a "$MAIN_LOG"
            fi

        else
            echo "   ❌ Remux attempt failed" | tee -a "$MAIN_LOG"
        fi
    fi

    [ -f "$temp_output" ] && rm -f "$temp_output"
    [ -f "$fixed_output" ] && rm -f "$fixed_output"

    if [ "$merge_success" -eq 1 ]; then
        return 0
    else
        echo "❌ UNABLE TO CREATE VALID OUTPUT FILE" | tee -a "$MAIN_LOG"
        echo "🔹 FFmpeg log saved to: $merge_log" | tee -a "$MAIN_LOG"
        return 1
    fi
}

# Display real-time progress bar
display_progress() {
    local mode="$1"            
    local duration="$2"         
    local chunk_num="${3:-0}"   
    local total_chunks="${4:-0}" 
    local progress_start="${5:-0}"
    
    awk -v mode="$mode" -v dur="$duration" -v chunk="$chunk_num" -v total="$total_chunks" -v pct_start="$progress_start" '
BEGIN {
    bar_width = 30
    reset   = "\033[0m"
    green   = "\033[0;32m"
    blue    = "\033[0;34m"
    partials[1] = "▏"; partials[2] = "▎"; partials[3] = "▍"
    partials[4] = "▌"; partials[5] = "▋"; partials[6] = "▊"
    partials[7] = "▉"; partials[8] = "█"
    fps   = "--"
    eta   = "--:--:--"
    speed_str = "--"
    current_size = 0
    first = 1
    
    if (mode == "chunked") {
        chunk_pct = 100 / total
        pct_offset = pct_start
        lines_to_update = 4
    } else {
        lines_to_update = 3
    }
}

/^fps=/ {
    split($0, B, "=")
    fps = B[2]
}

/^out_time=/ {
    split($0, a, "=")
    split(a[2], t, ":")
    sec = (t[1]*3600) + (t[2]*60) + t[3]
    if (sec > dur) sec = dur
    
    if (mode == "chunked") {
        seg_pct = (sec / dur) * 100
        if (seg_pct > 100) seg_pct = 100
        pct = pct_offset + (seg_pct * chunk_pct / 100)
        if (pct > 100) pct = 100
    } else {
        pct = (sec / dur) * 100
        if (pct > 100) pct = 100
    }

    now = systime()
    if (start_time == 0) { start_time = now }
    elapsed = now - start_time
    
    # NEW: Calculate dynamic speed units (b/s, Kb/s, Mb/s)
    if (current_size > 0 && elapsed > 0) {
        # Calculate bytes per second
        speed_Bps = current_size / elapsed
        
        # Convert to bits per second (1 byte = 8 bits)
        speed_bps = speed_Bps * 8
        
        # Determine appropriate unit
        if (speed_bps < 1000) {
            speed_str = sprintf("%.1f b/s", speed_bps)
        } else if (speed_bps < 1000000) {
            speed_str = sprintf("%.1f Kb/s", speed_bps / 1000)
        } else {
            speed_str = sprintf("%.1f Mb/s", speed_bps / 1000000)
        }
    }

    hrs_cur = int(sec / 3600)
    mins_cur = int((sec % 3600) / 60)
    secs_cur = sec % 60
    current_time = sprintf("%02d:%02d:%06.3f", hrs_cur, mins_cur, secs_cur)

    hrs_tot = int(dur / 3600)
    mins_tot = int((dur % 3600) / 60)
    secs_tot = dur % 60
    total_time = sprintf("%02d:%02d:%06.3f", hrs_tot, mins_tot, secs_tot)

    if (sec > 0 && elapsed > 0) {
        speed = elapsed / sec
        remaining_sec = dur - sec
        eta_sec = remaining_sec * speed
        eta_hr = int(eta_sec / 3600)
        eta_mn = int((eta_sec % 3600) / 60)
        eta_sc = int(eta_sec % 60)
        eta = sprintf("%02d:%02d:%02d", eta_hr, eta_mn, eta_sc)
    }

    # Main progress bar
    filled_blocks = int(pct * bar_width * 8 / 100 + 0.5)  # Proper rounding
    full_cells    = int(filled_blocks / 8)
    partial_cell  = filled_blocks % 8
    bar = ""
    for (i2 = 0; i2 < full_cells; i2++) bar = bar partials[8]
    if (partial_cell > 0) bar = bar partials[partial_cell]
    for (i2 = full_cells + (partial_cell > 0 ? 1 : 0); i2 < bar_width; i2++)
        bar = bar "-"

    if (mode == "chunked") {
        # Chunk progress bar (blue)
        filled_blocks_chunk = int(seg_pct * bar_width * 8 / 100 + 0.5)  # Proper rounding
        full_cells_chunk    = int(filled_blocks_chunk / 8)
        partial_cell_chunk  = filled_blocks_chunk % 8
        bar_chunk = ""
        for (i2 = 0; i2 < full_cells_chunk; i2++) bar_chunk = bar_chunk partials[8]
        if (partial_cell_chunk > 0) bar_chunk = bar_chunk partials[partial_cell_chunk]
        for (i2 = full_cells_chunk + (partial_cell_chunk > 0 ? 1 : 0); i2 < bar_width; i2++)
            bar_chunk = bar_chunk "-"
    }

    if (first) {
        if (mode == "chunked") {
            printf "   🔸OVERALL PROGRESS: %s║%s║%s %3d%%\n", green, bar, reset, int(pct)
            printf "   🔸ENCODING CHUNK %d: %s║%s║%s %3d%%\n", chunk, blue, bar_chunk, reset, int(seg_pct)
            printf "   🔸DURATION: %s / %s\n", current_time, total_time
            printf "   🔸ETA: %s | 🔸FPS: %s | 🔸Speed: %s\n", eta, fps, speed_str
        } else {
            printf "   🔸ENCODING:%s║%s║%s %3d%%\n", green, bar, reset, int(pct)
            printf "   🔸DURATION: %s / %s\n", current_time, total_time
            printf "   🔸ETA: %s | 🔸FPS: %s | 🔸Speed: %s\n", eta, fps, speed_str
        }
        first = 0
    } else {
        printf "\033[%dA", lines_to_update
        if (mode == "chunked") {
            printf "\033[2K\r   🔸OVERALL PROGRESS: %s║%s║%s %3d%%\n", green, bar, reset, int(pct)
            printf "\033[2K\r   🔸ENCODING CHUNK %d: %s║%s║%s %3d%%\n", chunk, blue, bar_chunk, reset, int(seg_pct)
            printf "\033[2K\r   🔸DURATION: %s / %s\n", current_time, total_time
            printf "\033[2K\r   🔸ETA: %s | 🔸FPS: %s | 🔸Speed: %s\n", eta, fps, speed_str
        } else {
            printf "\033[2K\r   🔸ENCODING:%s║%s║%s %3d%%\n", green, bar, reset, int(pct)
            printf "\033[2K\r   🔸DURATION: %s / %s\n", current_time, total_time
            printf "\033[2K\r   🔸ETA: %s | 🔸FPS: %s | 🔸Speed: %s\n", eta, fps, speed_str
        }
    }
    fflush()
}

/^total_size=/ {
    split($0, S, "=")
    current_size = S[2] + 0
}

/^progress=end/ {
    # Update time and speed at completion
    now = systime()
    elapsed = now - start_time
    # NEW: Dynamic speed units at completion
    if (current_size > 0 && elapsed > 0) {
        speed_Bps = current_size / elapsed
        speed_bps = speed_Bps * 8
        if (speed_bps < 1000) {
            speed_str = sprintf("%.1f b/s", speed_bps)
        } else if (speed_bps < 1000000) {
            speed_str = sprintf("%.1f Kb/s", speed_bps / 1000)
        } else {
            speed_str = sprintf("%.1f Mb/s", speed_bps / 1000000)
        }
    }

    # Force 100% progress
    sec = dur
    if (mode == "chunked") {
        seg_pct = 100
        pct = pct_offset + (seg_pct * chunk_pct / 100)
        if (pct > 100) pct = 100
    } else {
        pct = 100
    }
    
    # Update to 100% progress
    printf "\033[%dA", lines_to_update
    if (mode == "chunked") {
        printf "\033[2K\r   🔸OVERALL PROGRESS: %s║%s║%s %3d%%\n", green, bar, reset, int(pct + 0.5)  # Round to nearest integer
        printf "\033[2K\r   🔸ENCODING CHUNK %d: %s║%s║%s %3d%%\n", chunk, blue, bar_chunk, reset, int(seg_pct + 0.5)  # Round to nearest integer
        printf "\033[2K\r   🔸DURATION: %s / %s\n", current_time, total_time
        printf "\033[2K\r   🔸ETA: 00:00:00 | 🔸FPS: %s | 🔸Speed: %s\n", fps, speed_str
    } else {
        printf "\033[2K\r   🔸ENCODING:%s║%s║%s %3d%%\n", green, bar, reset, int(pct + 0.5)  # Round to nearest integer
        printf "\033[2K\r   🔸DURATION: %s / %s\n", current_time, total_time
        printf "\033[2K\r   🔸ETA: 00:00:00 | 🔸FPS: %s | 🔸Speed: %s\n", fps, speed_str
    }
    
    # Move down to print completion message below progress bars
    printf "\n"  # Move to next line after progress bars
    if (mode == "chunked") {
        printf "   ✅ CHUNK %d/%d encoded successfully\n", chunk, total
    } else {
        printf "   ✅ DONE ENCODING.\n"
    }
    printf "\n"  # Add extra space before next output
    fflush()
}
'
}