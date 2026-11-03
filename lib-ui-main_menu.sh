#!/bin/bash

# ==================== LOADING GUARD ====================
if [[ -n "${_LIB_UI_MAIN_MENU_LOADED+x}" ]]; then
    return 0  # Already loaded, skip
fi
readonly _LIB_UI_MAIN_MENU_LOADED=true  # Mark as loaded
# ==================================================

# ===========================================================================
# UI MODULE - USER INTERFACE MAIN MENU FUNCTIONS
# (look & feel helpers live in lib-ui-kit.sh)
# ===========================================================================

# One-line digest of the advanced settings, shown under the "Advanced" row.
_menu_advanced_summary() {
    local cool chunk
    if [[ "${AUTO_COOLDOWN:-0}" == "1" ]]; then
        cool="auto"
    else
        cool="$(format_time "$COOLDOWN_TIME" "simple")"
    fi
    chunk="$(format_time "$CHUNK_THRESHOLD" "simple")"
    printf '%s%s%s' "$OUTPUT_FORMAT" " ${UI_SEP} " "scale $SCALING_MODE"
    printf '%s' " ${UI_SEP} chunk>$chunk ${UI_SEP} cool $cool ${UI_SEP} ${CPU_THREADS}thr"
}

# Show interactive menu
show_menu() {
    local vlabel alabel summary aval atone aextra
    clear
    ui_refresh

    ui_header "TERMUX VIDEO CONVERTER" "Output ${UI_BUL} $(_batch_trunc "$OUTPUT_DIR" $((UI_W - 14)))"

    vlabel="$(get_video_codec_label)"; vlabel="${vlabel//[()]/}"
    alabel="$(get_audio_codec_label)"; alabel="${alabel//[()]/}"

    ui_section "VIDEO"
    ui_row 1 "Codec"          "$VIDEO_CODEC" "" "$vlabel"
    ui_row 2 "Quality (CRF)"  "$CRF"         "" "lower = better"
    ui_row 3 "Speed preset"   "$PRESET"      "" ""

    ui_section "AUDIO"
    ui_row 4 "Codec" "$AUDIO_CODEC" "" "$alabel"
    case "$AUDIO_CODEC" in
        copy|flac) aval="${AUDIO_BITRATE} kbps"; atone="off"; aextra="ignored" ;;
        *)         aval="${AUDIO_BITRATE} kbps"; atone="";    aextra="" ;;
    esac
    ui_row 5 "Bitrate" "$aval" "$atone" "$aextra"

    ui_section "SETTINGS"
    ui_row 6 "Advanced" "${UI_MORE} more options" "" ""
    summary="$(_menu_advanced_summary)"
    printf '       %s%s%s\n' "$UI_DIM" "$(_ui_trunc "$summary" $((UI_W - 8)))" "$UI_RST"

    echo ""
    ui_rule
    ui_actions "7|${UI_PLAY} Start|${UI_OK}" "8|Save|" "9|Diagnose|" "0|Exit|${UI_ERRC}"
    echo ""
}

process_menu_choice() {
    local choice="${1:-}"
    local vcodec_choice acodec_choice new_bitrate
    local new_crf new_preset crf_max cur_style i
    local INPUT_PATH val unit
    local prev_codec presets

    case "$choice" in
        "")
            # Just Enter: redraw silently
            ;;

        1)
            ui_submenu_title "VIDEO CODEC" "Encoder used for the output video. Enter keeps the current one."
            ui_opt 1 "libsvtav1 (SVT-AV1)"   "$VIDEO_CODEC" libsvtav1
            ui_opt 2 "libx264 (H.264/AVC)"   "$VIDEO_CODEC" libx264
            ui_opt 3 "libx265 (H.265/HEVC)"  "$VIDEO_CODEC" libx265
            ui_opt 4 "libvpx (VP8)"          "$VIDEO_CODEC" libvpx
            ui_opt 5 "libvpx-vp9 (VP9)"      "$VIDEO_CODEC" libvpx-vp9
            ui_opt 6 "libaom-av1 (AV1)"      "$VIDEO_CODEC" libaom-av1
            echo ""

            if [ "$BITRATE_LIMITS_ENABLED" -eq 1 ]; then
                ui_note "Bitrate limits ON: maxrate $MAXRATE | bufsize $BUFSIZE"
                validate_bitrate_limits "$VIDEO_CODEC" "$MAXRATE" "$BUFSIZE" || true
                echo ""
            fi

            read -r -p "$(ui_prompt "SELECT VIDEO CODEC [1-6]")" vcodec_choice || vcodec_choice=""
            prev_codec="$VIDEO_CODEC"
            echo ""

            case "$vcodec_choice" in
                1)
                    VIDEO_CODEC="libsvtav1"; PRESET="6"; OUTPUT_FORMAT="mkv"
                    ui_warn "SVT-AV1 encoding is very CPU intensive"
                    ui_note "Recommended maxrate <= 2000k for SVT-AV1"
                    if [[ "$MAXRATE" =~ ^([0-9]+)([kM])$ ]]; then
                        val=${BASH_REMATCH[1]}; unit=${BASH_REMATCH[2]}
                        if [[ "$unit" == "M" ]]; then val=$((val * 1000)); fi
                        if (( val > 2000 )); then
                            ui_warn "Current maxrate ($MAXRATE) may be too high for SVT-AV1"
                            if ui_confirm "Adjust maxrate to 2000k?" Y; then
                                MAXRATE="2000k"; BUFSIZE="3000k"
                                ui_ok "Adjusted to maxrate=2000k, bufsize=3000k"
                            fi
                        fi
                    fi
                    ui_pause 2
                    ;;
                2)
                    VIDEO_CODEC="libx264"; PRESET="medium"; OUTPUT_FORMAT="mp4"
                    if [[ "$MAXRATE" =~ ^([0-9]+)k$ ]] && (( ${BASH_REMATCH[1]} < 500 )); then
                        ui_warn "H.264 works well with higher bitrates (current: $MAXRATE)"
                    fi
                    ui_ok "Video codec set to libx264"
                    ui_pause 1
                    ;;
                3)
                    VIDEO_CODEC="libx265"; PRESET="medium"; OUTPUT_FORMAT="mp4"
                    if [[ "$MAXRATE" =~ ^([0-9]+)k$ ]] && (( ${BASH_REMATCH[1]} > 3000 )); then
                        ui_warn "HEVC typically doesn't need maxrate > 3000k (current: $MAXRATE)"
                    fi
                    ui_ok "Video codec set to libx265"
                    ui_pause 1
                    ;;
                4)
                    VIDEO_CODEC="libvpx"; PRESET="default"; OUTPUT_FORMAT="mkv"
                    if [[ "$MAXRATE" =~ ^([0-9]+)k$ ]] && (( ${BASH_REMATCH[1]} > 1500 )); then
                        ui_warn "VP8 works best with maxrate <= 1500k (current: $MAXRATE)"
                        if ui_confirm "Adjust maxrate to 1500k?" Y; then
                            MAXRATE="1500k"; BUFSIZE="2250k"
                            ui_ok "Adjusted to maxrate=1500k, bufsize=2250k"
                        fi
                    fi
                    ui_ok "Video codec set to libvpx"
                    ui_pause 1
                    ;;
                5)
                    VIDEO_CODEC="libvpx-vp9"; PRESET="default"; OUTPUT_FORMAT="mkv"
                    if [[ "$MAXRATE" =~ ^([0-9]+)k$ ]] && (( ${BASH_REMATCH[1]} > 1800 )); then
                        ui_warn "VP9 works best with maxrate <= 1800k (current: $MAXRATE)"
                    fi
                    ui_ok "Video codec set to libvpx-vp9"
                    ui_pause 1
                    ;;
                6)
                    VIDEO_CODEC="libaom-av1"; PRESET="medium"; OUTPUT_FORMAT="mkv"
                    ui_warn "AV1 encoding is very CPU intensive"
                    ui_note "Recommended maxrate <= 2000k for AV1"
                    if [[ "$MAXRATE" =~ ^([0-9]+)([kM])$ ]]; then
                        val=${BASH_REMATCH[1]}; unit=${BASH_REMATCH[2]}
                        if [[ "$unit" == "M" ]]; then val=$((val * 1000)); fi
                        if (( val > 2000 )); then
                            ui_warn "Current maxrate ($MAXRATE) may be too high for AV1"
                            if ui_confirm "Adjust maxrate to 2000k?" Y; then
                                MAXRATE="2000k"; BUFSIZE="3000k"
                                ui_ok "Adjusted to maxrate=2000k, bufsize=3000k"
                            fi
                        fi
                    fi
                    ui_pause 2
                    ;;
                "")
                    ui_note "Unchanged: $VIDEO_CODEC"
                    ui_pause 1
                    ;;
                *)
                    ui_err "Invalid choice - keeping $VIDEO_CODEC"
                    ui_pause 1
                    ;;
            esac

            # Codec changed while bitrate limits are active: offer to review them
            if [[ "$prev_codec" != "$VIDEO_CODEC" && "$BITRATE_LIMITS_ENABLED" -eq 1 ]]; then
                if ! validate_bitrate_limits "$VIDEO_CODEC" "$MAXRATE" "$BUFSIZE"; then
                    ui_warn "Current bitrate limits may not be optimal for $VIDEO_CODEC"
                    if ui_confirm "Open the bitrate limits editor now?" Y; then
                        ui_edit_bitrate_limits
                    fi
                fi
            fi
            ;;

        2)
            case "$VIDEO_CODEC" in
                libx264|libx265) crf_max=51 ;;
                *)               crf_max=63 ;;
            esac
            ui_submenu_title "QUALITY (CRF)" "Lower = better quality, bigger files. Range for $VIDEO_CODEC: 0-$crf_max."
            ui_note "Current value: $CRF"
            read -r -p "$(ui_prompt "NEW CRF [0-$crf_max]")" new_crf || new_crf=""
            if [ -z "$new_crf" ]; then
                ui_note "Unchanged: $CRF"
            elif is_positive_integer "$new_crf" && [ "$new_crf" -le "$crf_max" ]; then
                CRF="$new_crf"
                ui_ok "CRF set to $CRF"
            else
                ui_err "Invalid CRF - keeping $CRF"
            fi
            ui_pause 1
            ;;

        3)
            ui_submenu_title "ENCODING SPEED" "Preset for $VIDEO_CODEC. Slower = smaller file, longer encode."
            case "$VIDEO_CODEC" in
                libsvtav1)
                    ui_note "Current preset: $PRESET   (0 = slowest, 13 = fastest)"
                    read -r -p "$(ui_prompt "PRESET NUMBER [0-13]")" new_preset || new_preset=""
                    if [ -z "$new_preset" ]; then
                        ui_note "Unchanged: $PRESET"
                    elif [[ "$new_preset" =~ ^[0-9]+$ ]] && [ "$new_preset" -le 13 ]; then
                        PRESET="$new_preset"
                        ui_ok "Preset set to $PRESET"
                    else
                        ui_err "Invalid preset - keeping $PRESET"
                    fi
                    ;;
                libx264|libx265|libaom-av1)
                    presets=(ultrafast superfast veryfast faster fast medium slow slower veryslow)
                    for i in "${!presets[@]}"; do
                        ui_opt $((i + 1)) "${presets[$i]}" "$PRESET" "${presets[$i]}"
                    done
                    echo ""
                    read -r -p "$(ui_prompt "SELECT PRESET [1-9]")" new_preset || new_preset=""
                    new_preset="${new_preset,,}"
                    if [ -z "$new_preset" ]; then
                        ui_note "Unchanged: $PRESET"
                    elif [[ "$new_preset" =~ ^[1-9]$ ]]; then
                        PRESET="${presets[$((new_preset - 1))]}"
                        ui_ok "Preset set to $PRESET"
                    else
                        for i in "${!presets[@]}"; do
                            if [ "${presets[$i]}" = "$new_preset" ]; then PRESET="$new_preset"; fi
                        done
                        if [ "$PRESET" = "$new_preset" ]; then
                            ui_ok "Preset set to $PRESET"
                        else
                            ui_err "Invalid preset - keeping $PRESET"
                        fi
                    fi
                    ;;
                libvpx*|copy)
                    PRESET="default"
                    ui_note "$VIDEO_CODEC needs no preset - using default"
                    ;;
                *)
                    PRESET="medium"
                    ui_warn "Unknown video codec - using preset medium"
                    ;;
            esac
            ui_pause 1
            ;;

        4)
            ui_submenu_title "AUDIO CODEC" "Encoder used for the output audio. Enter keeps the current one."
            ui_opt 1 "libopus (Opus)"       "$AUDIO_CODEC" libopus
            ui_opt 2 "aac (AAC)"            "$AUDIO_CODEC" aac
            ui_opt 3 "flac (lossless)"      "$AUDIO_CODEC" flac
            ui_opt 4 "mp3 (MPEG Audio)"     "$AUDIO_CODEC" mp3
            ui_opt 5 "copy (original audio)" "$AUDIO_CODEC" copy
            echo ""
            read -r -p "$(ui_prompt "SELECT AUDIO CODEC [1-5]")" acodec_choice || acodec_choice=""
            case "$acodec_choice" in
                1) AUDIO_CODEC="libopus"; ui_ok "Audio codec set to libopus" ;;
                2) AUDIO_CODEC="aac";     ui_ok "Audio codec set to aac" ;;
                3) AUDIO_CODEC="flac";    ui_ok "Audio codec set to flac" ;;
                4) AUDIO_CODEC="mp3";     ui_ok "Audio codec set to mp3" ;;
                5) AUDIO_CODEC="copy";    ui_ok "Audio will be copied unchanged" ;;
                "") ui_note "Unchanged: $AUDIO_CODEC" ;;
                *) ui_err "Invalid choice - keeping $AUDIO_CODEC" ;;
            esac
            ui_pause 1
            ;;

        5)
            ui_submenu_title "AUDIO BITRATE" "Target audio bitrate in kbps (e.g. 64, 96, 128). Ignored for copy and flac."
            ui_note "Current value: ${AUDIO_BITRATE} kbps"
            read -r -p "$(ui_prompt "NEW BITRATE (kbps)")" new_bitrate || new_bitrate=""
            if [ -z "$new_bitrate" ]; then
                ui_note "Unchanged: ${AUDIO_BITRATE} kbps"
            elif is_positive_integer "$new_bitrate" && [ "$new_bitrate" -gt 0 ]; then
                AUDIO_BITRATE="$new_bitrate"
                ui_ok "Audio bitrate set to ${AUDIO_BITRATE} kbps"
            else
                ui_err "Invalid bitrate - keeping ${AUDIO_BITRATE} kbps"
            fi
            ui_pause 1
            ;;

        6)
            # Advanced Settings submenu
            show_advanced_menu
            read -r -p "$(ui_prompt "SELECT OPTION [0-11]")" advanced_choice || advanced_choice=0
            process_advanced_choice "$advanced_choice"
            ;;

        7)
            ui_submenu_title "START CONVERSION" "Enter a video file or folder. Press Enter to scan the default folders."
            read -r -p "$(ui_prompt "PATH")" INPUT_PATH || INPUT_PATH=""
            echo ""

            if [ -z "$INPUT_PATH" ]; then
                # Auto-detect default directories with video files
                ui_note "Scanning default folders..."
                mapfile -t INPUT_DIRS < <(get_active_input_dirs)

                if [ "${#INPUT_DIRS[@]}" -eq 0 ]; then
                    ui_err "No video files found in the default folders"
                    ui_note "Checked: $DEFAULT_INPUT_DIR_1"
                    ui_note "Checked: $DEFAULT_INPUT_DIR_2"
                    ui_pause 3
                    return 0
                fi

                ui_ok "Active input folders:"
                for d in "${INPUT_DIRS[@]}"; do
                    printf '    %s%s%s %s%s%s\n' "$UI_ACC" "$UI_BUL" "$UI_RST" "$UI_PATH" "$d" "$UI_RST"
                done
                ui_pause 2

                total_dirs=${#INPUT_DIRS[@]}
                current_dir=0

                for dir in "${INPUT_DIRS[@]}"; do
                    current_dir=$((current_dir + 1))
                    echo ""
                    ui_section "FOLDER $current_dir/$total_dirs"
                    printf '   %s%s%s\n' "$UI_PATH" "$dir" "$UI_RST"
                    echo ""
                    process_input "$dir"

                    # No cooldown when nothing was processed (cancelled / empty / no pending files)
                    if [ "$current_dir" -lt "$total_dirs" ] && \
                       [[ "${BATCH_LAST_RESULT:-}" != "cancelled" && "${BATCH_LAST_RESULT:-}" != "empty" && "${BATCH_LAST_RESULT:-}" != "no_pending" ]]; then
                        echo ""
                        ui_note "Folder finished - cooling down before the next one"
                        countdown "$COOLDOWN_TIME"
                    fi
                done
            else
                # Process the custom path the user entered
                INPUT_PATH=$(portable_realpath "$INPUT_PATH" 2>/dev/null || realpath -m "$INPUT_PATH")

                if [ ! -e "$INPUT_PATH" ]; then
                    ui_err "Path does not exist: $INPUT_PATH"
                    ui_note "Please enter a valid file or folder path"
                    ui_pause 2
                    return 0
                fi

                process_input "$INPUT_PATH"
            fi
            exit 0
            ;;

        8)
            save_config || true
            ;;

        9)
            diag_standalone_menu
            ;;

        0)
            echo ""
            ui_note "Goodbye"
            ui_pause 1
            exit 0
            ;;

        *)
            ui_err "Invalid option: $choice"
            ui_pause 1
            ;;
    esac
    return 0
}
