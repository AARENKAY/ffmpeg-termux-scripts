#!/bin/bash

# ==================== LOADING GUARD ====================
if [[ -n "${_LIB_UI_ADV_MENU_LOADED+x}" ]]; then
    return 0  # Already loaded, skip
fi
readonly _LIB_UI_ADV_MENU_LOADED=true  # Mark as loaded
# ==================================================

# ===========================================================================
# UI MODULE - ADVANCED MAIN MENU FUNCTIONS
# (look & feel helpers live in lib-ui-kit.sh)
# ===========================================================================

# Show advanced settings menu
show_advanced_menu() {
    local bval btone cval cool_val cool_extra sval sextra pval pextra
    clear
    ui_refresh

    ui_header "ADVANCED SETTINGS" "Output, chunking, filters and CPU use"

    ui_section "OUTPUT"
    ui_row 1 "Output format" "$OUTPUT_FORMAT" "" ""
    ui_row 2 "Pixel format"  "$PIXFMT_MODE"   "" ""
    if [ "${FPS_HANDLING:-auto}" = "auto" ]; then
        ui_row 3 "Frame rate" "auto" "on" "fixes variable fps"
    else
        ui_row 3 "Frame rate" "source" "" "never changed"
    fi
    if [ "$BITRATE_LIMITS_ENABLED" -eq 1 ]; then
        ui_row 4 "Bitrate limits" "ON" "on" "max $MAXRATE ${UI_SEP} buf $BUFSIZE"
    else
        ui_row 4 "Bitrate limits" "OFF" "off" ""
    fi

    ui_section "CHUNKING & COOLING"
    ui_row 5 "Chunk threshold" "$(format_time "$CHUNK_THRESHOLD" "simple")" "" "split longer files"
    if [ "$CHUNK_MODE" = "manual" ]; then
        cval="$(format_time "$MANUAL_CHUNK_DURATION" "simple")"
        ui_row 6 "Chunk duration" "$cval" "" "manual"
    else
        ui_row 6 "Chunk duration" "default" "" "30-35 min"
    fi
    if [[ "${AUTO_COOLDOWN:-0}" == "1" ]]; then
        ui_row 7 "Cooldown" "auto" "on" "by CPU temp"
    else
        ui_row 7 "Cooldown" "$(format_time "$COOLDOWN_TIME" "simple")" "" "fixed pause"
    fi

    ui_section "FILTERS"
    if [ "$SCALING_MODE" = "Custom" ]; then
        ui_row 8 "Scaling" "Custom" "" "$CUSTOM_RESOLUTION"
    elif [ "$SCALING_MODE" = "OFF" ]; then
        ui_row 8 "Scaling" "OFF" "off" ""
    else
        ui_row 8 "Scaling" "$SCALING_MODE" "on" ""
    fi
    if [ "$SHARPEN_EDGES" -eq 1 ]; then
        ui_row 9 "Sharpening" "ON" "on" ""
    else
        ui_row 9 "Sharpening" "OFF" "off" ""
    fi

    ui_section "INTERFACE & SYSTEM"
    if [ "$PROGRESS_STYLE" = "advanced" ]; then
        ui_row 10 "Progress style" "advanced" "" "$BAR_STYLE"
    else
        ui_row 10 "Progress style" "simple" "" "no bar"
    fi
    ui_row 11 "File sorting" "$FILE_SORT_MODE" "" ""
    ui_row 12 "CPU threads"  "$CPU_THREADS"    "" "1-4 safest"

    echo ""
    ui_rule
    ui_actions "0|Back to main menu|${UI_ERRC}"
    echo ""
}

# Bitrate limits editor (used by the advanced menu and by the codec menu)
ui_edit_bitrate_limits() {
    local bitrate_option new_maxrate new_bufsize
    ui_submenu_title "BITRATE LIMITS" "Caps the peak bitrate (maxrate / bufsize) to keep output size under control."
    ui_opt 1 "Enable limits"  "$BITRATE_LIMITS_ENABLED" 1
    ui_opt 2 "Disable limits" "$BITRATE_LIMITS_ENABLED" 0
    ui_opt 3 "Adjust values (maxrate=$MAXRATE, bufsize=$BUFSIZE)"
    echo ""
    read -r -p "$(ui_prompt "SELECT OPTION [1-3]")" bitrate_option || bitrate_option=""
    echo ""

    case "$bitrate_option" in
        1)
            BITRATE_LIMITS_ENABLED=1
            ui_ok "Bitrate limits enabled"
            ui_pause 1
            ;;
        2)
            BITRATE_LIMITS_ENABLED=0
            ui_warn "Bitrate limits disabled"
            ui_pause 1
            ;;
        3)
            ui_note "Current: maxrate=$MAXRATE, bufsize=$BUFSIZE"
            case "$VIDEO_CODEC" in
                libsvtav1|libaom-av1) ui_hint "AV1: maxrate 400k-2000k, bufsize 1.2-2x maxrate" ;;
                libx264)              ui_hint "H.264: maxrate 500k-5000k, bufsize 1.2-2x maxrate" ;;
                libx265)              ui_hint "H.265: maxrate 300k-3000k, bufsize 1.2-2x maxrate" ;;
                libvpx*)              ui_hint "VPx: maxrate 200k-1500k, bufsize 1.5-2x maxrate" ;;
                *)                    ui_hint "General: maxrate 200k-5000k, bufsize 1.2-2x maxrate" ;;
            esac
            ui_hint "Use whole numbers with k or M, e.g. 800k, 1200k, 2M. Enter on the first prompt cancels."
            echo ""

            while true; do
                read -r -p "$(ui_prompt "MAXRATE")" new_maxrate || new_maxrate=""
                if [ -z "$new_maxrate" ]; then
                    ui_note "Unchanged"
                    break
                fi
                read -r -p "$(ui_prompt "BUFSIZE")" new_bufsize || new_bufsize=""

                if [[ "$new_maxrate" =~ ^[0-9]+[kM]$ && "$new_bufsize" =~ ^[0-9]+[kM]$ ]]; then
                    if validate_bitrate_limits "$VIDEO_CODEC" "$new_maxrate" "$new_bufsize"; then
                        MAXRATE="$new_maxrate"; BUFSIZE="$new_bufsize"; BITRATE_LIMITS_ENABLED=1
                        ui_ok "Limits set: maxrate=$MAXRATE, bufsize=$BUFSIZE"
                        break
                    fi
                    if ui_confirm "Use these values anyway?" N; then
                        MAXRATE="$new_maxrate"; BUFSIZE="$new_bufsize"; BITRATE_LIMITS_ENABLED=1
                        ui_ok "Limits set (with warnings)"
                        break
                    fi
                else
                    ui_err "Invalid format - use something like 800k or 1M"
                    if ! ui_confirm "Try again?" Y; then break; fi
                fi
            done
            ui_pause 1
            ;;
        "")
            ui_note "Unchanged"
            ui_pause 1
            ;;
        *)
            ui_err "Invalid option"
            ui_pause 1
            ;;
    esac
    return 0
}

# Process advanced menu choices
process_advanced_choice() {
    local choice="${1:-}"
    local format_choice incompatible
    local pixfmt_choice new_threshold new_seconds
    local chunk_mode_choice chunk_dur dur_seconds
    local cooldown_mode new_cooldown
    local scaling_choice custom_res
    local subchoice style_choice cur_style
    local sort_choice
    local new_threads max_threads

    # Loop until user chooses to return to main menu
    while true; do
        case "$choice" in
            1)
                ui_submenu_title "OUTPUT FORMAT" "Container for the converted file. Enter keeps the current one."
                ui_opt 1 "mkv (Matroska)"   "$OUTPUT_FORMAT" mkv
                ui_opt 2 "mp4 (MPEG-4)"     "$OUTPUT_FORMAT" mp4
                ui_opt 3 "webm (WebM)"      "$OUTPUT_FORMAT" webm
                ui_opt 4 "mov (QuickTime)"  "$OUTPUT_FORMAT" mov
                ui_opt 5 "avi (AVI)"        "$OUTPUT_FORMAT" avi
                echo ""
                read -r -p "$(ui_prompt "SELECT OUTPUT FORMAT [1-5]")" format_choice || format_choice=""
                echo ""

                case "$format_choice" in
                    1) OUTPUT_FORMAT="mkv" ;;
                    2) OUTPUT_FORMAT="mp4" ;;
                    3) OUTPUT_FORMAT="webm" ;;
                    4) OUTPUT_FORMAT="mov" ;;
                    5) OUTPUT_FORMAT="avi" ;;
                    "") ui_note "Unchanged: $OUTPUT_FORMAT"; format_choice="" ;;
                    *)  ui_err "Invalid choice - keeping $OUTPUT_FORMAT"; format_choice="" ;;
                esac

                if [ -n "$format_choice" ]; then
                    ui_ok "Output format set to $OUTPUT_FORMAT"

                    # Compatibility check
                    incompatible=0
                    case "$OUTPUT_FORMAT" in
                        mp4|mov)
                            case "$VIDEO_CODEC" in libvpx|libvpx-vp9|libsvtav1|libaom-av1) incompatible=1 ;; esac
                            ;;
                        webm)
                            case "$VIDEO_CODEC" in libx264|libx265) incompatible=1 ;; esac
                            ;;
                        avi)
                            if [[ "$VIDEO_CODEC" != "libx264" ]]; then incompatible=1; fi
                            ;;
                    esac

                    if (( incompatible )); then
                        echo ""
                        ui_warn "$OUTPUT_FORMAT is not fully compatible with $VIDEO_CODEC"
                        if ui_confirm "Revert to mkv for safety?" Y; then
                            OUTPUT_FORMAT="mkv"
                            ui_ok "Output format reverted to mkv"
                        else
                            ui_warn "Proceeding with possible incompatibility"
                        fi
                    fi
                fi
                ui_pause 1
                ;;

            2)
                ui_submenu_title "PIXEL FORMAT" "Bit depth of the output video."
                ui_opt 1 "copy    (use source format)"   "$PIXFMT_MODE" copy
                ui_opt 2 "8-bit   (force yuv420p)"       "$PIXFMT_MODE" 8-bit
                ui_opt 3 "10-bit  (force yuv420p10le)"   "$PIXFMT_MODE" 10-bit
                echo ""
                read -r -p "$(ui_prompt "SELECT PIXEL FORMAT [1-3]")" pixfmt_choice || pixfmt_choice=""
                echo ""
                case "$pixfmt_choice" in
                    1) PIXFMT_MODE="copy";   ui_ok "Pixel format: copy" ;;
                    2) PIXFMT_MODE="8-bit";  ui_ok "Pixel format: 8-bit" ;;
                    3)
                        PIXFMT_MODE="10-bit"
                        ui_ok "Pixel format: 10-bit"
                        ui_warn "10-bit needs a 10-bit source video"
                        ui_note "On an 8-bit source it only adds size with no gain"
                        ;;
                    "") ui_note "Unchanged: $PIXFMT_MODE" ;;
                    *)  ui_err "Invalid option - keeping $PIXFMT_MODE" ;;
                esac
                ui_pause 1
                ;;

            3)
                ui_submenu_title "FRAME RATE" "How the output frame rate is chosen."
                ui_opt 1 "Auto    (constant rate only for variable-frame-rate sources)" "$FPS_HANDLING" auto
                ui_opt 2 "Source  (never change the frame rate or timing)"              "$FPS_HANDLING" source
                echo ""
                ui_note "Auto: phone videos with variable frame rate are made constant (e.g. 30 fps)"
                ui_note "which plays more evenly in software decoders. Constant sources are untouched."
                echo ""
                read -r -p "$(ui_prompt "SELECT FRAME RATE MODE [1-2]")" subchoice || subchoice=""
                echo ""
                case "$subchoice" in
                    1) FPS_HANDLING="auto";   ui_ok "Frame rate: auto" ;;
                    2) FPS_HANDLING="source"; ui_ok "Frame rate: source (unchanged)" ;;
                    "") ui_note "Unchanged: $FPS_HANDLING" ;;
                    *)  ui_err "Invalid option - keeping $FPS_HANDLING" ;;
                esac
                ui_pause 1
                ;;

            4)
                ui_edit_bitrate_limits
                ;;

            5)
                ui_submenu_title "CHUNK THRESHOLD" "Files longer than this are split into chunks. Examples: 30s, 1m, 40m, 1h."
                ui_note "Current value: $(format_time "$CHUNK_THRESHOLD" "simple")"
                read -r -p "$(ui_prompt "NEW THRESHOLD")" new_threshold || new_threshold=""
                if [ -z "$new_threshold" ]; then
                    ui_note "Unchanged"
                else
                    new_seconds=$(human_to_seconds "$new_threshold")
                    if is_positive_integer "$new_seconds" && [ "$new_seconds" -gt 0 ]; then
                        CHUNK_THRESHOLD="$new_seconds"
                        ui_ok "Chunk threshold set to $(format_time "$CHUNK_THRESHOLD" "simple")"
                    else
                        ui_err "Invalid time - keeping $(format_time "$CHUNK_THRESHOLD" "simple")"
                    fi
                fi
                ui_pause 1
                ;;

            6)
                ui_submenu_title "CHUNK DURATION" "How long each chunk should be."
                ui_opt 1 "Default (30-35 minute chunks max)" "$CHUNK_MODE" default
                ui_opt 2 "Manual  (set a custom duration)"   "$CHUNK_MODE" manual
                if [ "$CHUNK_MODE" = "manual" ]; then
                    ui_note "Manual duration: $(format_time "$MANUAL_CHUNK_DURATION" "simple")"
                fi
                echo ""
                read -r -p "$(ui_prompt "SELECT CHUNK MODE [1-2]")" chunk_mode_choice || chunk_mode_choice=""
                echo ""

                case "$chunk_mode_choice" in
                    1)
                        CHUNK_MODE="default"
                        ui_ok "Using default 30-35 minute chunks"
                        ;;
                    2)
                        read -r -p "$(ui_prompt "CHUNK DURATION (e.g. 10m, 30m, 1h)")" chunk_dur || chunk_dur=""
                        dur_seconds=$(human_to_seconds "$chunk_dur")
                        if [ -n "$chunk_dur" ] && is_positive_integer "$dur_seconds" && [ "$dur_seconds" -gt 0 ]; then
                            CHUNK_MODE="manual"
                            MANUAL_CHUNK_DURATION="$dur_seconds"
                            ui_ok "Manual chunks of ~$(format_time "$dur_seconds" "compact")"
                        else
                            ui_err "Invalid duration - nothing changed"
                        fi
                        ;;
                    "") ui_note "Unchanged: $CHUNK_MODE" ;;
                    *)  ui_err "Invalid option - keeping $CHUNK_MODE" ;;
                esac
                ui_pause 1
                ;;

            7)
                ui_submenu_title "COOLDOWN" "Pause between files and chunks so a phone can cool down."
                ui_opt 1 "Auto   (wait for CPU temperature)" "${AUTO_COOLDOWN:-0}" 1
                ui_opt 2 "Manual (fixed time)"               "${AUTO_COOLDOWN:-0}" 0
                if [[ "${AUTO_COOLDOWN:-0}" != "1" ]]; then
                    ui_note "Fixed pause: $(format_time "$COOLDOWN_TIME" "simple")"
                fi
                echo ""
                read -r -p "$(ui_prompt "SELECT MODE [1-2]")" cooldown_mode || cooldown_mode=""
                echo ""

                case "$cooldown_mode" in
                    1)
                        AUTO_COOLDOWN=1
                        ui_ok "Auto cooldown enabled (CPU temperature based)"
                        ;;
                    2)
                        read -r -p "$(ui_prompt "COOLDOWN TIME (e.g. 30s, 1m, 10m)")" new_cooldown || new_cooldown=""
                        new_seconds=$(human_to_seconds "$new_cooldown")
                        if [ -n "$new_cooldown" ] && is_positive_integer "$new_seconds"; then
                            AUTO_COOLDOWN=0
                            COOLDOWN_TIME="$new_seconds"
                            ui_ok "Manual cooldown set to $(format_time "$COOLDOWN_TIME" "simple")"
                        else
                            ui_err "Invalid time - nothing changed"
                        fi
                        ;;
                    "") ui_note "Unchanged" ;;
                    *)  ui_err "Invalid choice - keeping current setting" ;;
                esac
                ui_pause 1
                ;;

            8)
                ui_submenu_title "SCALING" "Resize the output video. Keeps the aspect ratio."
                ui_opt 1 "720P"                               "$SCALING_MODE" 720P
                ui_opt 2 "1080P"                              "$SCALING_MODE" 1080P
                ui_opt 3 "Custom (your own resolution)"       "$SCALING_MODE" Custom
                ui_opt 4 "OFF (keep original resolution)"     "$SCALING_MODE" OFF
                echo ""
                read -r -p "$(ui_prompt "SELECT SCALING MODE [1-4]")" scaling_choice || scaling_choice=""
                echo ""

                case "$scaling_choice" in
                    1) SCALING_MODE="720P";  ui_ok "Scaling set to 720P" ;;
                    2) SCALING_MODE="1080P"; ui_ok "Scaling set to 1080P" ;;
                    3)
                        read -r -p "$(ui_prompt "RESOLUTION (e.g. 1920x1080)")" custom_res || custom_res=""
                        if [[ "$custom_res" =~ ^[0-9]+x[0-9]+$ ]]; then
                            SCALING_MODE="Custom"
                            CUSTOM_RESOLUTION="$custom_res"
                            ui_ok "Custom scaling set to $CUSTOM_RESOLUTION"
                        else
                            ui_err "Invalid resolution - scaling stays $SCALING_MODE"
                        fi
                        ;;
                    4) SCALING_MODE="OFF"; ui_ok "Scaling disabled" ;;
                    "") ui_note "Unchanged: $SCALING_MODE" ;;
                    *)  ui_err "Invalid choice - scaling stays $SCALING_MODE" ;;
                esac
                ui_pause 1
                ;;

            9)
                ui_submenu_title "SHARPENING" "Edge-aware sharpening filter. Slower to encode."
                ui_opt 1 "Enable sharpening"  "$SHARPEN_EDGES" 1
                ui_opt 2 "Disable sharpening" "$SHARPEN_EDGES" 0
                echo ""
                read -r -p "$(ui_prompt "SELECT OPTION [1-2]")" subchoice || subchoice=""
                echo ""
                case "$subchoice" in
                    1) SHARPEN_EDGES=1; ui_ok "Sharpening enabled" ;;
                    2) SHARPEN_EDGES=0; ui_ok "Sharpening disabled" ;;
                    "") ui_note "Unchanged" ;;
                    *)  ui_err "Invalid option - keeping current setting" ;;
                esac
                ui_pause 1
                ;;

            10)
                ui_submenu_title "PROGRESS DISPLAY" "How encoding progress is shown."
                ui_opt 1 "Toggle progress style   (now: $PROGRESS_STYLE)"
                ui_opt 2 "Choose bar style        (now: $BAR_STYLE)"
                echo ""
                read -r -p "$(ui_prompt "SELECT OPTION [1-2]")" subchoice || subchoice=""
                echo ""

                case "$subchoice" in
                    1)
                        if [ "$PROGRESS_STYLE" = "advanced" ]; then
                            PROGRESS_STYLE="simple"
                            ui_ok "Progress style: simple (single line, no bar)"
                        else
                            PROGRESS_STYLE="advanced"
                            ui_ok "Progress style: advanced"
                        fi
                        ;;
                    2)
                        if [ "$PROGRESS_STYLE" != "advanced" ]; then
                            ui_err "Bar styles only apply to the advanced progress style"
                        else
                            cur_style="$BAR_STYLE"
                            if [ "$cur_style" = "h-bars" ]; then cur_style="horizontal_blocks"; fi
                            ui_submenu_title "BAR STYLE"
                            ui_opt 1 "Horizontal blocks  ▏▎▍▌▋▊▉█"   "$cur_style" horizontal_blocks
                            ui_opt 2 "ASCII              ####>"      "$cur_style" ascii
                            ui_opt 3 "Shading            ░▒▓█"       "$cur_style" shading_blocks
                            ui_opt 4 "Braille            ⠁⠃⠇⡇⣇⣧⣷⣿"   "$cur_style" braille
                            ui_opt 5 "Arrow              ›»⟫"        "$cur_style" arrow
                            ui_opt 6 "Circles            ○◔◑◕●⬤"     "$cur_style" circle
                            ui_opt 7 "Vertical blocks    ▁▂▃▄▅▆▇█"   "$cur_style" vertical_blocks
                            echo ""
                            read -r -p "$(ui_prompt "SELECT BAR STYLE [1-7]")" style_choice || style_choice=""
                            echo ""
                            case "$style_choice" in
                                1) BAR_STYLE="horizontal_blocks" ;;
                                2) BAR_STYLE="ascii" ;;
                                3) BAR_STYLE="shading_blocks" ;;
                                4) BAR_STYLE="braille" ;;
                                5) BAR_STYLE="arrow" ;;
                                6) BAR_STYLE="circle" ;;
                                7) BAR_STYLE="vertical_blocks" ;;
                                "") style_choice="" ;;
                                *)  style_choice="" ; ui_err "Invalid selection - keeping $BAR_STYLE" ;;
                            esac
                            if [ -n "$style_choice" ]; then
                                ui_ok "Bar style set to $BAR_STYLE"
                            else
                                ui_note "Unchanged: $BAR_STYLE"
                            fi
                        fi
                        ;;
                    "") ui_note "Unchanged" ;;
                    *)  ui_err "Invalid selection" ;;
                esac
                ui_pause 1
                ;;

            11)
                ui_submenu_title "FILE SORTING" "Order in which files are processed during a batch."
                ui_opt 1 "Name, A to Z"        "$FILE_SORT_MODE" name_az
                ui_opt 2 "Name, Z to A"        "$FILE_SORT_MODE" name_za
                ui_opt 3 "Smallest size first" "$FILE_SORT_MODE" size_small
                ui_opt 4 "Largest size first"  "$FILE_SORT_MODE" size_large
                ui_opt 5 "Newest first"        "$FILE_SORT_MODE" date_new
                ui_opt 6 "Oldest first"        "$FILE_SORT_MODE" date_old
                echo ""
                read -r -p "$(ui_prompt "SELECT SORTING MODE [1-6]")" sort_choice || sort_choice=""
                echo ""
                case "$sort_choice" in
                    1) FILE_SORT_MODE="name_az";     ui_ok "Sorting: name A-Z" ;;
                    2) FILE_SORT_MODE="name_za";     ui_ok "Sorting: name Z-A" ;;
                    3) FILE_SORT_MODE="size_small";  ui_ok "Sorting: smallest first" ;;
                    4) FILE_SORT_MODE="size_large";  ui_ok "Sorting: largest first" ;;
                    5) FILE_SORT_MODE="date_new";    ui_ok "Sorting: newest first" ;;
                    6) FILE_SORT_MODE="date_old";    ui_ok "Sorting: oldest first" ;;
                    "") ui_note "Unchanged: $FILE_SORT_MODE" ;;
                    *)  ui_err "Invalid option - keeping $FILE_SORT_MODE" ;;
                esac
                ui_pause 1
                ;;

            12)
                max_threads=8
                if command -v nproc >/dev/null 2>&1; then max_threads=$(nproc 2>/dev/null || echo 8); fi
                ui_submenu_title "CPU THREADS" "Fewer threads = cooler and safer on a phone, but slower. 1-4 is recommended."
                ui_note "Current: $CPU_THREADS thread(s)   ${UI_SEP}   this device: $max_threads core(s)"
                read -r -p "$(ui_prompt "THREADS")" new_threads || new_threads=""
                if [ -z "$new_threads" ]; then
                    ui_note "Unchanged"
                elif [[ "$new_threads" =~ ^[0-9]+$ ]] && [ "$new_threads" -ge 1 ]; then
                    CPU_THREADS="$new_threads"
                    ui_ok "Threads set to $CPU_THREADS"
                    if [ "$CPU_THREADS" -gt 4 ]; then
                        ui_warn "More than 4 threads can overheat a phone during long encodes"
                    fi
                else
                    ui_err "Invalid number - keeping $CPU_THREADS"
                fi
                ui_pause 1
                ;;

            0)
                # Return to main menu
                return 0
                ;;

            "")
                # Just Enter: redraw silently
                ;;

            *)
                ui_err "Invalid option: $choice"
                ui_pause 1
                ;;
        esac

        # After processing any choice (except exit), show the advanced menu again
        show_advanced_menu
        read -r -p "$(ui_prompt "SELECT OPTION [0-12]")" choice || choice=0
    done
}
