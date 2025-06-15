#!/bin/bash

# ===========================================================================
# PROBE MODULE - MEDIA ANALYSIS FUNCTIONS
# ===========================================================================

# Probe media file information
probe_media_info() {
    local input_file="$1"
    local filename=$(basename -- "$input_file")
    
    declare -g width height duration duration_full size_bytes size_mb bitrate bitrate_kbps
    declare -g audio_bitrate audio_bitrate_kbps file_ext format_disp codec_name codec_long
    declare -g audio_codec_name audio_codec_long input_pix_fmt input_bit_depth
    
    width=$(ffprobe -v error -select_streams v:0 -show_entries stream=width -of csv=p=0 "$input_file" 2>/dev/null || echo 0)
    height=$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of csv=p=0 "$input_file" 2>/dev/null || echo 0)
    duration_full=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$input_file" 2>/dev/null)
    duration=$(awk -v d="$duration_full" 'BEGIN { printf("%.3f", d) }')
    if [[ "$OSTYPE" == "darwin"* ]]; then
    size_bytes=$(stat -f%z "$input_file")
    else
    size_bytes=$(stat -c%s "$input_file")
    fi
    size_mb=$((size_bytes / 1024 / 1024))
    bitrate=$(ffprobe -v error -show_entries format=bit_rate -of default=noprint_wrappers=1:nokey=1 "$input_file" 2>/dev/null || echo 0)
    bitrate_kbps=$((bitrate / 1000))
    audio_bitrate=$(ffprobe -v error -select_streams a:0 -show_entries stream=bit_rate -of default=noprint_wrappers=1:nokey=1 "$input_file" 2>/dev/null || echo 0)
    
    if [[ "$audio_bitrate" =~ ^[0-9]+$ ]]; then
        audio_bitrate_kbps=$((audio_bitrate / 1000))
    else
        audio_bitrate_kbps="N/A"
    fi
    
    file_ext="${filename##*.}"
    format_disp=$(echo "$file_ext" | tr '[:lower:]' '[:upper:]')
    
    codec_name=$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of default=noprint_wrappers=1:nokey=1 "$input_file" 2>/dev/null || echo "Unknown")
    codec_long=$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_long_name -of default=noprint_wrappers=1:nokey=1 "$input_file" 2>/dev/null || echo "Unknown")
    
    audio_codec_name=$(ffprobe -v error -select_streams a:0 -show_entries stream=codec_name -of default=noprint_wrappers=1:nokey=1 "$input_file" 2>/dev/null || echo "Unknown")
    audio_codec_long=$(ffprobe -v error -select_streams a:0 -show_entries stream=codec_long_name -of default=noprint_wrappers=1:nokey=1 "$input_file" 2>/dev/null || echo "Unknown")
    
    input_pix_fmt=$(ffprobe -v error -select_streams v:0 -show_entries stream=pix_fmt -of csv=p=0 "$input_file" 2>/dev/null || echo "unknown")
    
    case "$input_pix_fmt" in
        yuv420p)      input_bit_depth="8-bit" ;;
        yuv420p10le)  input_bit_depth="10-bit" ;;
        *)            input_bit_depth="$input_pix_fmt" ;;
    esac
}

# Determine scaling parameters and bit depth
determine_scaling() {
    if [[ "$width" -eq 0 || "$height" -eq 0 ]]; then
        scale_filter=""
        pix_fmt="yuv420p"
        scale_info="No scaling (audio-only?)"
        bit_depth="8-bit"
        return
    fi
    
    local width_even=$((width - width % 2))
    local height_even=$((height - height % 2))
    local scale_threshold=720
    
    case "$BIT_DEPTH" in
        8)
            pix_fmt="yuv420p"
            bit_depth="8-bit (forced)"
            ;;
        10)
            pix_fmt="yuv420p10le"
            bit_depth="10-bit (forced)"
            ;;
        *)
            if [ "$height_even" -gt "$width_even" ]; then
                pix_fmt="yuv420p"
                bit_depth="8-bit"
            else
                pix_fmt="yuv420p10le"
                bit_depth="10-bit"
            fi
            ;;
    esac

    if [ "$height_even" -gt "$width_even" ]; then
        if (( height_even > scale_threshold )); then
            scale_filter="scale=720:-2"
            scale_info="Resized to 720p (portrait)"
        else
            scale_filter=""
            scale_info="No scaling (portrait ≤ 720p)"
        fi
    else
        if (( height_even > scale_threshold )); then
            scale_filter="scale=-2:720"
            scale_info="Resized to 720p (landscape)"
        else
            scale_filter=""
            scale_info="No scaling (landscape ≤ 720p)"
        fi
    fi
}

# Display media information
display_media_info() {
    local input_file="$1"
    
    if [[ -z "$width" || -z "$height" || "$width" -eq 0 || "$height" -eq 0 ]]; then
        res_str="Audio Only"
    else
        if (( width > height )); then orientation="landscape"; else orientation="portrait"; fi
        res_str="${width}x${height} (${orientation})"
    fi

    echo "🔸INPUT: $input_file" | tee -a "$LOG_FILE"
    echo "   🔸RESOLUTION: $res_str" | tee -a "$LOG_FILE"
    echo "   🔸DURATION: $(float_to_timestamp "$duration")" | tee -a "$LOG_FILE"
    echo "   🔸SIZE: ${size_mb}M" | tee -a "$LOG_FILE"
    echo "   🔸BITRATE: ${bitrate_kbps} kbps" | tee -a "$LOG_FILE"
    echo "   🔸BIT DEPTH: $input_bit_depth" | tee -a "$LOG_FILE"
    echo "   🔸FORMAT: $format_disp" | tee -a "$LOG_FILE"
    echo "   🔸CODEC: $codec_name ($codec_long)" | tee -a "$LOG_FILE"
    echo "   🔸AUDIO CODEC: $audio_codec_name ($audio_codec_long)" | tee -a "$LOG_FILE"
    echo "   🔸AUDIO BITRATE: ${audio_bitrate_kbps} kbps" | tee -a "$LOG_FILE"
    echo "-----------------------------------------------" | tee -a "$LOG_FILE"
}

# Get compatible pixel format for codec
get_compatible_pix_fmt() {
    local codec="$1"
    local current_pix_fmt="$2"
    
    case "$codec" in
        libsvtav1)
            echo "$current_pix_fmt"
            ;;
        libx264|libx265)
            if [[ "$current_pix_fmt" == "yuv420p10le" ]]; then
                echo "yuv420p10le"
            else
                echo "yuv420p"
            fi
            ;;
        libvpx*|libaom*)
            echo "$current_pix_fmt"
            ;;
        *)
            echo "yuv420p"
            ;;
    esac
}

# Check video file integrity
check_video_integrity() {
    local file="$1"
    local expected_duration="${2:-}"
    local strict_tol="0.3"
    local soft_tol="0.5"

    if ! actual_duration=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$file" 2>/dev/null); then
        return 1
    fi

    if [[ -z "$expected_duration" ]]; then
        return 0
    fi

    awk -v a="$actual_duration" -v e="$expected_duration" -v strict="$strict_tol" -v soft="$soft_tol" '
    BEGIN {
        diff = (a > e) ? (a - e) : (e - a)
        if (diff <= strict) {
            exit 0
        } else if (diff <= soft) {
            print "‼️ Duration mismatch within soft range: " diff "s" > "/dev/stderr"
            exit 0
        } else {
            print "❌ Duration mismatch too large: " diff "s" > "/dev/stderr"
            exit 1
        }
    }'
}

# Display output file info
display_output_info() {
    local output_file="$1"
    
    local out_width out_height out_duration_full out_duration out_size_bytes out_size_mb
    local out_bitrate out_bitrate_kbps out_audio_bitrate out_audio_bitrate_kbps
    local out_format out_codec_name out_codec_long audio_codec_name_out audio_codec_long_out
    local out_pix_fmt out_bit_depth out_res_str out_orientation out_file_ext out_format_disp

    out_width=$(ffprobe -v error -select_streams v:0 -show_entries stream=width -of csv=p=0 "$output_file" 2>/dev/null || echo 0)
    out_height=$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of csv=p=0 "$output_file" 2>/dev/null || echo 0)
    out_duration_full=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$output_file" 2>/dev/null || echo 0)
    out_duration=${out_duration_full%.*}
    out_size_bytes=$(stat -c%s "$output_file" 2>/dev/null || echo 0)
    out_size_mb=$((out_size_bytes / 1024 / 1024))
    out_bitrate=$(ffprobe -v error -show_entries format=bit_rate -of default=noprint_wrappers=1:nokey=1 "$output_file" 2>/dev/null || echo 0)
    out_bitrate_kbps=$((out_bitrate / 1000))
    out_audio_bitrate=$(ffprobe -v error -select_streams a:0 -show_entries stream=bit_rate -of default=noprint_wrappers=1:nokey=1 "$output_file" 2>/dev/null || echo 0)
    
    if is_positive_integer "$out_audio_bitrate"; then
        out_audio_bitrate_kbps=$((out_audio_bitrate / 1000))
    else
        out_audio_bitrate_kbps="N/A"
    fi
    
    out_format=$(ffprobe -v error -show_entries format=format_name -of default=noprint_wrappers=1:nokey=1 "$output_file" 2>/dev/null || echo "Unknown")
    out_codec_name=$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of default=noprint_wrappers=1:nokey=1 "$output_file" 2>/dev/null || echo "Unknown")
    out_codec_long=$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_long_name -of default=noprint_wrappers=1:nokey=1 "$output_file" 2>/dev/null || echo "Unknown")
    audio_codec_name_out=$(ffprobe -v error -select_streams a:0 -show_entries stream=codec_name -of default=noprint_wrappers=1:nokey=1 "$output_file" 2>/dev/null || echo "Unknown")
    audio_codec_long_out=$(ffprobe -v error -select_streams a:0 -show_entries stream=codec_long_name -of default=noprint_wrappers=1:nokey=1 "$output_file" 2>/dev/null || echo "Unknown")
    out_pix_fmt=$(ffprobe -v error -select_streams v:0 -show_entries stream=pix_fmt -of csv=p=0 "$output_file" 2>/dev/null || echo "unknown")
    
    case "$out_pix_fmt" in
        yuv420p)     out_bit_depth="8-bit" ;;
        yuv420p10le) out_bit_depth="10-bit" ;;
        *)           out_bit_depth="$out_pix_fmt" ;;
    esac

    if [[ -z "$out_width" || -z "$out_height" || "$out_width" == 0 || "$out_height" == 0 ]]; then
        out_res_str="Audio Only"
    else
        if (( out_width > out_height )); then out_orientation="landscape"; else out_orientation="portrait"; fi
        out_res_str="${out_width}x${out_height} (${out_orientation})"
    fi
    out_file_ext="${output_file##*.}"
    out_format_disp=$(echo "$out_file_ext" | tr '[:lower:]' '[:upper:]')
    
    echo "-----------------------------------------------" | tee -a "$LOG_FILE"
    echo "   🔸FINAL OUTPUT INFO:" | tee -a "$LOG_FILE"
    echo "     🔹RESOLUTION: $out_res_str" | tee -a "$LOG_FILE"
    echo "     🔹DURATION: $(format_duration "$out_duration")" | tee -a "$LOG_FILE"
    echo "     🔹SIZE: ${out_size_mb}M" | tee -a "$LOG_FILE"
    echo "     🔹BITRATE: ${out_bitrate_kbps} kbps" | tee -a "$LOG_FILE"
    echo "     🔹BIT DEPTH: $out_bit_depth" | tee -a "$LOG_FILE"
    echo "     🔹FORMAT: $out_format_disp" | tee -a "$LOG_FILE"
    echo "     🔹CODEC: $out_codec_name ($out_codec_long)" | tee -a "$LOG_FILE"
    echo "     🔹AUDIO CODEC: $audio_codec_name_out ($audio_codec_long_out)" | tee -a "$LOG_FILE"
    echo "     🔹AUDIO BITRATE: ${out_audio_bitrate_kbps} kbps" | tee -a "$LOG_FILE"
    echo "🔸OUTPUT: $output_file" | tee -a "$LOG_FILE"
    echo "-----------------------------------------------" | tee -a "$LOG_FILE"
}