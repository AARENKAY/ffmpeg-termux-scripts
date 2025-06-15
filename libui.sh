#!/bin/bash

# ===========================================================================
# UI MODULE - USER INTERFACE FUNCTIONS
# ===========================================================================

# Show real-time countdown
countdown() {
    local total=$1
    echo
    while (( total > 0 )); do
        hrs=$(( total / 3600 ))
        mins=$(( (total % 3600) / 60 ))
        secs=$(( total % 60 ))
        printf "\033[2K\r   🔸WAITING %02d:%02d:%02d BEFORE PROCEEDING TO NEXT FILE..." "$hrs" "$mins" "$secs"
        sleep 1
        (( total-- ))
    done
    printf "\033[2K\r   🔸STARTING TO PROCESS NEXT FILE...\n"
}

# Show interactive menu
show_menu() {
    clear
    echo -e "\033[1;36m╔════════════════════════════════════════════════════════════╗\033[0m"
    echo -e "\033[1;36m║            🎬  \033[1;33mFFMPEG VIDEO CONVERSION TOOL\033[1;36m                ║\033[0m"
    echo -e "\033[1;36m╠════════════════════════════════════════════════════════════╣\033[0m"
    echo -e "\033[1;36m║ 📁 \033[1mOUTPUT DIRECTORY:\033[0m $OUTPUT_DIR\033[1;36m       ║\033[0m"
    if [ "$DRY_RUN" = true ]; then
        echo -e "\033[1;36m║ 🟡 \033[1;33mDRY RUN MODE ACTIVE - NO CHANGES WILL BE MADE\033[1;36m    ║\033[0m"
    fi
    echo -e "\033[1;36m╚════════════════════════════════════════════════════════════╝\033[0m"

    printf "  [1]  \033[1mVideo Codec     \033[0m        ║ 🔹 %s %s\n" "$VIDEO_CODEC" "$(get_video_codec_label)"
    printf "  [2]  \033[1mAudio Codec     \033[0m        ║ 🔹 %s %s\n" "$AUDIO_CODEC" "$(get_audio_codec_label)"
    printf "  [3]  \033[1mAudio Bitrate   \033[0m        ║ 🔹 %sKbps\n" "$AUDIO_BITRATE"
    printf "  [4]  \033[1mOutput Format   \033[0m        ║ 🔹 %s\n" "$OUTPUT_FORMAT"
    printf "  [5]  \033[1mCRF (Quality)   \033[0m        ║ 🔹 %s\n" "$CRF"
    printf "  [6]  \033[1mEncoding Speed  \033[0m        ║ 🔹 %s\n" "$PRESET"
    printf "  [7]  \033[1mBit Depth       \033[0m        ║ 🔹 %s-bit\n" "$BIT_DEPTH"
    printf "  [8]  \033[1mChunk Threshold \033[0m        ║ 🔹 %s\n" "$(seconds_to_human "$CHUNK_THRESHOLD")"
    printf "  [9]  \033[1mCooldown Time   \033[0m        ║ 🔹 %s\n" "$(seconds_to_human "$COOLDOWN_TIME")"

    echo -e "\033[1;36m╔════════════════════════════════════════════════════════════╗\033[0m"
    echo -e "\033[1;36m║ \033[1;32m[10] Start Conversion\033[0m [11] \033[1mSave Configuration\033[0m \033[1;33m[12] Dry-Run\033[0m \033[1;36m║\033[0m"
    echo -e "\033[1;36m║ \033[1;31m[0]  Exit\033[0m                                                  \033[1;36m║\033[0m"
    echo -e "\033[1;36m╚════════════════════════════════════════════════════════════╝\033[0m"
}

# Process menu choice
process_menu_choice() {
    local choice=$1
    
    case $choice in
        1)
            echo -e "\n🔸VIDEO CODEC OPTIONS:"
            echo "  ╔═════════════════════════╗"
            echo "  ║ 1. libsvtav1 (SVT-AV1)  ║"
            echo "  ║ 2. libx264 (H.264/AVC)  ║"
            echo "  ║ 3. libx265 (H.265/HEVC) ║"
            echo "  ║ 4. libvpx (VP8)         ║"
            echo "  ║ 5. libvpx-vp9 (VP9)     ║"
            echo "  ║ 6. libaom-av1 (AV1)     ║"
            echo "  ║ 7. copy (original video)║"
            echo "  ╚═════════════════════════╝"
            read -p "   SELECT VIDEO CODEC [1-7]: " vcodec_choice
            case $vcodec_choice in
                1) VIDEO_CODEC="libsvtav1"
                echo "‼️ WARNING: SVT-AV1 encoding is very CPU intensive!" 
                sleep 5
                ;;
                2) VIDEO_CODEC="libx264" ;;
                3) VIDEO_CODEC="libx265" ;;
                4) VIDEO_CODEC="libvpx" ;;
                5) VIDEO_CODEC="libvpx-vp9" ;;
                6) VIDEO_CODEC="libaom-av1" 
                echo "‼️ WARNING: AV1 encoding is very CPU intensive!" 
                sleep 5
                ;;
                7) VIDEO_CODEC="copy" ;;
                *) VIDEO_CODEC="libsvtav1"
                echo "❌ INVALID INPUT, FALLBACK TO DEFAULT (SVT-AV1)!" 
                sleep 2
                echo "‼️ WARNING: SVT-AV1 ENCODING IS VERY CPU INTENSIVE!" 
                sleep 5
                ;;
            esac
            ;;
        2)
            echo -e "\n🔸AUDIO CODEC OPTIONS:"
            echo "  ╔═════════════════════════╗"
            echo "  ║ 1. libopus (Opus)       ║"
            echo "  ║ 2. aac (AAC)            ║"
            echo "  ║ 3. flac (lossless)      ║"
            echo "  ║ 4. mp3 (MPEG Audio)     ║"
            echo "  ║ 5. copy (original audio)║"
            echo "  ╚═════════════════════════╝"
            read -p "   SELECT AUDIO CODEC [1-7]: " acodec_choice
            case $acodec_choice in
                1) AUDIO_CODEC="libopus" ;;
                2) AUDIO_CODEC="aac" ;;
                3) AUDIO_CODEC="flac" ;;
                4) AUDIO_CODEC="mp3" ;;
                5) AUDIO_CODEC="copy" ;;
                *) AUDIO_CODEC="libopus" ;;
            esac
            ;;
        3)
            echo -e "\n🔸CURRENT AUDIO BITRATE: ${AUDIO_BITRATE}Kbps"
            read -p "   ENTER NEW BITRATE (e.g., 128): " new_bitrate
            if is_positive_integer "$new_bitrate"; then
                AUDIO_BITRATE="$new_bitrate"
            else
                echo "❌ INVALID BITRATE. USING DEFAULT."
            fi
            ;;
        4)
            echo -e "\n🔸OUTPUT FORMAT OPTIONS:"
            echo "  ╔═══════════════════╗"
            echo "  ║ 1. mkv (Matroska) ║"
            echo "  ║ 2. mp4 (MPEG-4)   ║"
            echo "  ║ 3. webm (WebM)    ║"
            echo "  ║ 4. mov (QuickTime)║"
            echo "  ║ 5. avi (AVI)      ║"
            echo "  ╚═══════════════════╝"
            read -p "   SELECT OUTPUT FORMAT [1-5]: " format_choice
            case $format_choice in
                1) OUTPUT_FORMAT="mkv" ;;
                2) OUTPUT_FORMAT="mp4" ;;
                3) OUTPUT_FORMAT="webm" ;;
                4) OUTPUT_FORMAT="mov" ;;
                5) OUTPUT_FORMAT="avi" ;;
                *) OUTPUT_FORMAT="mkv" ;;
            esac
            ;;
        5)
            echo -e "\n🔸CURRENT CRF VALUE: $CRF"
            read -p "   ENTER NEW CRF VALUE (0-63 for AV1, 0-51 for H.264/H.265)    (A lower CRF means higher video quality and larger file size, while a higher CRF means lower quality and smaller file size.): " new_crf
            if is_positive_integer "$new_crf"; then
                CRF="$new_crf"
            else
                echo "❌ INVALID VALUE. USING DEFAULT."
            fi
            ;;
        6)
            echo -e "\n🔸CURRENT PRESET VALUE: $PRESET"
            read -p "   ENTER NEW PRESET VALUE (0-13 for AV1, 0-9 for H.264/H.265)  (A slower preset takes more time to encode but gives better compression and efficiency, while a faster preset encodes quickly but with less efficient compression.): " new_preset
            if is_positive_integer "$new_preset"; then
                PRESET="$new_preset"
            else
                echo "❌ INVALID VALUE. USING DEFAULT."
            fi
            ;;
        7)
            echo -e "\n🔸BIT DEPTH OPTIONS:"
            echo "   1. auto (default: 8-bit for portrait, 10-bit for landscape)"
            echo "   2. 8-bit"
            echo "   3. 10-bit"
            read -p "   SELECT BIT DEPTH [1-3]: " bit_choice
            case $bit_choice in
                2) BIT_DEPTH="8" ;;
                3) BIT_DEPTH="10" 
                echo "‼️ WARNING: 10-bit requires 10-bit source, otherwise may cause issues!"
                sleep 5
                ;;
                *) BIT_DEPTH="auto" ;;
            esac
            ;;
        8)
            echo -e "\n🔸CURRENT CHUNK THRESHOLD: ${CHUNK_THRESHOLD} sec"
            read -p "   ENTER NEW THRESHOLD (e.g., 30s, 1m, 40m, 1h): " new_threshold
            new_seconds=$(human_to_seconds "$new_threshold")
            if is_positive_integer "$new_seconds"; then
            CHUNK_THRESHOLD="$new_seconds"
            else
            echo "❌ INVALID TIME FORMAT. USING DEFAULT."
            fi
            ;;
        9)
            echo -e "\n🔸CURRENT COOLDOWN TIME: ${COOLDOWN_TIME} sec"
            read -p "   ENTER NEW COOLDOWN (e.g., 30s, 1m, 40m, 1h): " new_cooldown
            new_seconds=$(human_to_seconds "$new_cooldown")
            if is_positive_integer "$new_seconds"; then
            COOLDOWN_TIME="$new_seconds"
            else
            echo "❌ INVALID TIME FORMAT. USING DEFAULT."
            fi
            ;;
        10)
            if [ "$DRY_RUN" = true ]; then
                echo "   🔸 DRY RUN MODE IS ALREADY ACTIVE" | tee -a "$MAIN_LOG"
                sleep 2
                return
            fi
            
            read -e -p "📂 ENTER VIDEO FILE FOLDER PATH (e.g., /sdcard/Movies): " INPUT_DIR
            INPUT_DIR=$(portable_realpath "$INPUT_DIR")
            process_all_files "$INPUT_DIR"
            exit 0
            ;;
        11)
            save_config
            ;;
        12)  # New dry run option
            if [ "$DRY_RUN" = true ]; then
                echo "   🔸 DRY RUN MODE IS ALREADY ACTIVE" | tee -a "$MAIN_LOG"
                sleep 2
                return
            fi
            
            DRY_RUN=true
            echo "   🟡 DRY RUN MODE ACTIVATED" | tee -a "$MAIN_LOG"
            sleep 1
            
            read -e -p "📂 ENTER VIDEO FILE FOLDER PATH (e.g., /sdcard/Movies): " INPUT_DIR
            INPUT_DIR=$(portable_realpath "$INPUT_DIR")
            process_all_files "$INPUT_DIR"
            exit 0
            ;;
        0)
            echo "   EXITING..." | tee -a "$MAIN_LOG"
            exit 0
            ;;
        *)
            echo "❌ INVALID OPTION"
            sleep 1
            ;;
    esac
}