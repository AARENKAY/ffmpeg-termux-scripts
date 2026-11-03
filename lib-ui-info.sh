#!/bin/bash

# ==================== LOADING GUARD ====================
if [[ -n "${_LIB_UI_INFO_LOADED+x}" ]]; then
    return 0  # Already loaded, skip
fi
readonly _LIB_UI_INFO_LOADED=true  # Mark as loaded
# ==================================================

# ===========================================================================
# UI MODULE - USER INTERFACE INFORMATION FUNCTIONS
# (look & feel helpers live in lib-ui-kit.sh)
# ===========================================================================

# Short "codec · detail" strings for the info cards
_info_video_line() {   # codec depth video_bitrate_kbps
    local codec="${1:-}" depth="${2:-}" kbps="${3:-N/A}" out
    if [ -z "$codec" ] || [ "$codec" = "Unknown" ]; then printf 'none'; return 0; fi
    out="$codec"
    if [ -n "$depth" ]; then out+=" ${UI_SEP:-·} $depth"; fi
    case "$kbps" in ''|N/A|0) ;; *) out+=" ${UI_SEP:-·} ${kbps} kbps" ;; esac
    printf '%s' "$out"
}

_info_audio_line() {   # codec bitrate_kbps
    local codec="${1:-}" kbps="${2:-N/A}"
    if [ -z "$codec" ] || [ "$codec" = "Unknown" ]; then printf 'none'; return 0; fi
    if [ "$kbps" = "N/A" ]; then printf '%s' "$codec"; else printf '%s %s %s kbps' "$codec" "${UI_SEP:-·}" "$kbps"; fi
}

_info_resolution_line() {   # width height
    local w="${1:-0}" h="${2:-0}" orientation
    if [[ -z "$w" || -z "$h" || "$w" == "0" || "$h" == "0" ]]; then printf 'Audio only'; return 0; fi
    if (( w > h )); then orientation="landscape"; else orientation="portrait"; fi
    printf '%sx%s %s %s' "$w" "$h" "${UI_SEP:-·}" "$orientation"
}

# Display Input file information
display_input_info() {
    local input_file="$1"
    local filename; filename=$(basename -- "$input_file")
    local filename_noext="${filename%.*}"
    # Prefer the log path passed in by process_file (it knows the nested log dir)
    local LOG_FILE="${2:-${LOG_FILE:-$LOG_DIR/${filename_noext}.log}}"

    probe_input_info "$input_file"
    UI_LAST_INPUT_BYTES="${size_bytes:-0}"

    echo ""
    ui_card "INPUT" \
        "Name|${COLOR_CYAN}|$filename_noext" \
        "Duration||$(format_time "$duration" "hms")" \
        "Size||$size_human" \
        "Resolution||$(_info_resolution_line "${width:-0}" "${height:-0}")" \
        "Video||$(_info_video_line "${codec_name:-}" "${input_pix_fmt_disp:-}" "${video_bitrate_kbps:-N/A}")" \
        "Audio||$(_info_audio_line "${audio_codec_name:-}" "${audio_bitrate_kbps:-N/A}")" \
        "Container||$format_disp" \
        | tee >(clean_output >> "$LOG_FILE")
}

# Display Output file information
display_output_info() {
    local output_file="$1"
    local filename_out; filename_out=$(basename -- "$output_file")
    local filename_out_noext="${filename_out%.*}"
    local LOG_FILE="${2:-${LOG_FILE:-$LOG_DIR/${filename_out_noext}.log}}"
    local size_row size_color="" delta

    probe_output_info "$output_file"

    size_row="$size_human"
    if [ "${UI_LAST_INPUT_BYTES:-0}" -gt 0 ] && [ "${size_bytes:-0}" -gt 0 ] 2>/dev/null; then
        delta=$(awk -v i="$UI_LAST_INPUT_BYTES" -v o="$size_bytes" 'BEGIN {
            d = (1 - o / i) * 100
            if (d >= 0) printf "%.0f%% smaller", d
            else        printf "%.0f%% larger", -d
        }')
        size_row="$size_human ($delta)"
        if [[ "$delta" == *larger* ]]; then size_color="$UI_WARNC"; else size_color="$UI_OK"; fi
    fi

    echo ""
    ui_card "OUTPUT" \
        "Name|${COLOR_CYAN}|$filename_out_noext" \
        "Duration||$(format_time "$duration" "hms")" \
        "Size|${size_color}|$size_row" \
        "Resolution||$(_info_resolution_line "${width:-0}" "${height:-0}")" \
        "Video||$(_info_video_line "${codec_name:-}" "${pix_fmt_out:-}" "${video_bitrate_kbps:-N/A}")" \
        "Audio||$(_info_audio_line "${audio_codec_name:-}" "${audio_bitrate_kbps:-N/A}")" \
        "Container||$format_disp" \
        | tee >(clean_output >> "$LOG_FILE")
    echo ""
}

# Choose process style
display_progress() {
    local mode="$1"
    local duration="$2"
    local chunk_num="${3:-0}"
    local total_chunks="${4:-0}"
    local progress_start="${5:-0}"

    if [ "$PROGRESS_STYLE" = "simple" ]; then
        display_progress_simple "$mode" "$duration" "$chunk_num" "$total_chunks" "$progress_start"
    else
        display_progress_advanced "$mode" "$duration" "$chunk_num" "$total_chunks" "$progress_start" "$BAR_STYLE"
    fi
}

# Simple progress: one self-updating line, no bar
display_progress_simple() {
    local mode="$1"
    local duration="$2"
    local chunk_num="${3:-0}"
    local total_chunks="${4:-0}"

    awk -v mode="$mode" -v dur="$duration" -v chunk="$chunk_num" -v total="$total_chunks" '
    function hms(s,    h, m) {
        if (s < 0) s = 0
        h = int(s / 3600); m = int((s % 3600) / 60)
        return sprintf("%02d:%02d:%02d", h, m, int(s % 60))
    }
    BEGIN {
        reset = "\033[0m"; dim = "\033[2m"
        green = "\033[1m\033[38;5;82m"; blue = "\033[1m\033[38;5;39m"
        sec = 0; speed = ""
        if (mode == "chunked") label = sprintf("CHUNK %d/%d", chunk + 0, total + 0)
        else                   label = "ENCODING"
    }
    /^out_time=/ {
        split($0, a, "=")
        if (a[2] == "N/A" || a[2] == "") next
        n = split(a[2], t, ":")
        if (n == 3)      sec = t[1] * 3600 + t[2] * 60 + t[3]
        else if (n == 2) sec = t[1] * 60 + t[2]
        else             sec = t[1] + 0
        if (sec > dur) sec = dur
    }
    /^speed=/ { split($0, s, "="); speed = s[2] }
    /^progress=/ {
        if ($0 == "progress=end") {
            printf "\r\033[2K  %s\342\234\224%s %sENCODED%s\n\n", green, reset, green, reset
            fflush()
            next
        }
        pct = (dur > 0) ? sec / dur * 100 : 0
        if (pct > 100) pct = 100
        if (mode == "chunked" && total > 0)
            pct_all = (((chunk - 1) * dur) + sec) / (dur * total) * 100
        else
            pct_all = pct
        printf "\r\033[2K %s%s%s %3d%%  %s%s / %s%s", blue, label, reset, int(pct), dim, hms(sec), hms(dur), reset
        if (speed != "" && speed != "N/A") printf "  %s%s%s", dim, speed, reset
        fflush()
    }
    '
}

# Advanced progress (bar + live stats). The block height is fixed (single: 4
# lines, chunked: 6 lines), so redraws just move the cursor up and repaint.
display_progress_advanced() {
    local mode="$1"
    local duration="$2"
    local chunk_num="${3:-0}"
    local total_chunks="${4:-0}"
    local progress_start="${5:-0}"
    local bar_style="${6:-horizontal_blocks}"
    local cols bw zone

    # Bar width adapts to the screen (line = 18 chars + bar)
    cols=$(_batch_cols)
    bw=$((cols - 21))
    if [ "$bw" -gt 30 ]; then bw=30; fi
    if [ "$bw" -lt 8 ]; then bw=8; fi

    zone=$(ui_cpu_zone)

    awk -v mode="$mode" -v dur="$duration" -v chunk="$chunk_num" -v total="$total_chunks" \
        -v style="$bar_style" -v zone="$zone" -v bar_width="$bw" '
    function hms(s,    h, m) {
        if (s < 0) s = 0
        h = int(s / 3600); m = int((s % 3600) / 60)
        return sprintf("%02d:%02d:%02d", h, m, int(s % 60))
    }

    function read_temp(    t) {
        if (zone == "") return -1
        if ((getline t < zone) > 0) { close(zone); if (t + 0 > 0) return int(t / 1000) }
        close(zone)
        return -1
    }

    # Build a bar for percentage p (0-100). The frontier cell animates.
    function make_bar(p,    total_units, filled, full_blocks, cur, b, i, a) {
        total_units = bar_width * partial_levels
        filled = int(p * total_units / 100 + 0.5)
        if (filled > total_units) filled = total_units
        full_blocks = int(filled / partial_levels)
        cur = filled % partial_levels
        b = ""
        for (i = 1; i <= bar_width; i++) {
            if (i <= full_blocks) {
                b = b full_char
            } else if (i == full_blocks + 1 && p < 100) {
                if (cur == 0) {
                    b = b blink partials[(phase % partial_levels) + 1] noblink
                } else {
                    a = (phase % (partial_levels - cur)) + cur + 1
                    if (a > partial_levels) a = partial_levels
                    b = b blink partials[a] noblink
                }
            } else {
                b = b " "
            }
        }
        return b
    }

    function bar_line(label, p, col) {
        return sprintf(" %s%-9s%s %3d%% %s\342\226\225%s%s%s\342\226\217%s", \
            col, label, reset, int(p), dim, col, make_bar(p), dim, reset)
    }

    function render(    i) {
        if (!first) printf "\033[%dA", nlines
        for (i = 1; i <= nlines; i++) printf "\033[2K\r%s\n", L[i]
        fflush()
        first = 0
    }

    BEGIN {
        reset = "\033[0m"; dim = "\033[2m"; bold = "\033[1m"
        green  = "\033[1m\033[38;5;82m";  blue   = "\033[1m\033[38;5;39m"
        yellow = "\033[1m\033[38;5;226m"; orange = "\033[1m\033[38;5;208m"
        red    = "\033[1m\033[38;5;196m"
        blink = "\033[5m"; noblink = "\033[25m"

        style = tolower(style)
        # Default: horizontal blocks (also used for unknown names like h-bars)
        full_char = "\342\226\210"
        partial_levels = 8
        partials[1] = "\342\226\217"; partials[2] = "\342\226\216"; partials[3] = "\342\226\215"
        partials[4] = "\342\226\214"; partials[5] = "\342\226\213"; partials[6] = "\342\226\212"
        partials[7] = "\342\226\211"; partials[8] = "\342\226\210"

        if (style == "ascii") {
            full_char = "#"; partial_levels = 1; partials[1] = ">"
        } else if (style == "shading_blocks") {
            full_char = "\342\226\210"; partial_levels = 4
            partials[1] = "\342\226\221"; partials[2] = "\342\226\222"
            partials[3] = "\342\226\223"; partials[4] = "\342\226\210"
        } else if (style == "braille") {
            full_char = "\342\243\277"; partial_levels = 8
            partials[1] = "\342\240\201"; partials[2] = "\342\240\203"; partials[3] = "\342\240\207"
            partials[4] = "\342\241\207"; partials[5] = "\342\243\207"; partials[6] = "\342\243\247"
            partials[7] = "\342\243\267"; partials[8] = "\342\243\277"
        } else if (style == "arrow") {
            full_char = "\342\237\253"; partial_levels = 3
            partials[1] = "\342\200\272"; partials[2] = "\302\273"; partials[3] = "\342\237\253"
        } else if (style == "circle") {
            full_char = "\342\254\244"; partial_levels = 6
            partials[1] = "\342\227\213"; partials[2] = "\342\227\224"; partials[3] = "\342\227\221"
            partials[4] = "\342\227\225"; partials[5] = "\342\227\217"; partials[6] = "\342\254\244"
        } else if (style == "vertical_blocks") {
            full_char = "\342\226\210"; partial_levels = 8
            partials[1] = "\342\226\201"; partials[2] = "\342\226\202"; partials[3] = "\342\226\203"
            partials[4] = "\342\226\204"; partials[5] = "\342\226\205"; partials[6] = "\342\226\206"
            partials[7] = "\342\226\207"; partials[8] = "\342\226\210"
        }

        fps = "--"; qp = "--"; frames = "--"; speed = "--"; bitrate = "--"
        speed_value = 0; sec = 0; phase = 0; renders = 0; first = 1
        cpu_temp = -1; temp_color = green
        nlines = (mode == "chunked") ? 6 : 4
        total_time = hms(dur)
    }

    /^fps=/     { split($0, B, "="); fps = B[2] }
    /^frame=/   { split($0, B, "="); frames = B[2] + 0 }
    /q=/        { if (match($0, /q=[0-9.]+/)) qp = substr($0, RSTART + 2, RLENGTH - 2) }
    /^speed=/ {
        split($0, S, "="); speed = S[2]
        gsub(/ /, "", speed)
        if (speed ~ /x$/) { v = speed; sub(/x$/, "", v); speed_value = v + 0 }
    }
    /^bitrate=/ {
        split($0, B, "="); raw = tolower(B[2]); gsub(/ /, "", raw)
        if (raw ~ /kbits\/s/)      bitrate = sprintf("%.1f Kb/s", raw + 0)
        else if (raw ~ /mbits\/s/) bitrate = sprintf("%.1f Mb/s", raw + 0)
        else if (raw != "")        bitrate = raw
    }
    /^out_time=/ {
        split($0, a, "=")
        if (a[2] != "N/A" && a[2] != "") {
            n = split(a[2], t, ":")
            if (n == 3)      sec = t[1] * 3600 + t[2] * 60 + t[3]
            else if (n == 2) sec = t[1] * 60 + t[2]
            else             sec = t[1] + 0
            if (sec > dur) sec = dur
        }
    }

    /^progress=/ {
        if ($0 == "progress=end") {
            # Wipe the live block, leave one tidy success line behind
            if (!first) {
                printf "\033[%dA", nlines
                for (i = 1; i <= nlines; i++) printf "\033[2K\r\n"
                printf "\033[%dA", nlines
            }
            printf "\033[2K\r %s\342\234\224 ENCODED SUCCESSFULLY%s\n\n", green, reset
            fflush()
            next
        }

        pct = (dur > 0) ? sec / dur * 100 : 0
        if (pct > 100) pct = 100

        if (speed_value > 0 && sec >= 0.1) eta = hms((dur - sec) / speed_value)
        else eta = "--:--:--"

        phase++
        if (renders % 4 == 0) {
            cpu_temp = read_temp()
            if (cpu_temp >= 90) temp_color = red
            else if (cpu_temp >= 85) temp_color = orange
            else if (cpu_temp >= 75) temp_color = yellow
            else temp_color = green
        }
        renders++
        temp_txt = (cpu_temp < 0) ? dim "n/a" reset : sprintf("%s%d\302\260C%s", temp_color, cpu_temp, reset)

        if (mode == "chunked" && total > 0) {
            overall = (((chunk - 1) * dur) + sec) / (dur * total) * 100
            if (overall > 100) overall = 100
            if (speed_value > 0 && sec >= 0.1)
                eta_all = hms((((total - chunk) * dur) + (dur - sec)) / speed_value)
            else
                eta_all = "--:--:--"
            L[1] = bar_line(sprintf("CHUNK %d/%d", chunk + 0, total + 0), pct, blue)
            L[5] = bar_line("TOTAL", overall, green)
            L[6] = sprintf(" %sTOTAL ETA%s %s %s(cooldowns not included)%s", dim, reset, eta_all, dim, reset)
        } else {
            L[1] = bar_line("ENCODING", pct, green)
        }
        L[2] = sprintf(" %sTIME%s %s / %s  %sETA%s %s", dim, reset, hms(sec), total_time, dim, reset, eta)
        L[3] = sprintf(" %sFPS%s %s  %sFRAMES%s %s  %sQP%s %s", dim, reset, fps, dim, reset, frames, dim, reset, qp)
        L[4] = sprintf(" %sSPEED%s %s  %sRATE%s %s  %sCPU%s %s", dim, reset, speed, dim, reset, bitrate, dim, reset, temp_txt)
        render()
    }
    '
}

# Real-time cooldown: one self-updating line, then a one-line result.
countdown() {
    local total="${1:-0}"
    local LOG_FILE="${LOG_FILE:-}"
    local zone cols bw

    if [ -z "$LOG_FILE" ]; then
        if [ -n "${input_file:-}" ]; then
            local fn; fn=$(basename -- "$input_file")
            LOG_FILE="$LOG_DIR/${fn%.*}.log"
        else
            LOG_FILE="/dev/null"
        fi
    fi
    if ! [[ "$total" =~ ^[0-9]+$ ]]; then total=0; fi

    cols=$(_batch_cols)
    ui_refresh

    zone=""
    if [[ "${AUTO_COOLDOWN:-0}" == "1" ]]; then
        zone=$(ui_cpu_zone)
        if [ -z "$zone" ]; then
            ui_warn "No CPU temperature sensor found - using the fixed cooldown instead" \
                | tee >(clean_output >> "$LOG_FILE")
        fi
    fi

    # ---------------- AUTO: wait for the CPU to cool down ----------------
    if [ -n "$zone" ]; then
        local max_time=300          # longest allowed wait (seconds)
        local max_temp=38000        # target temperature (millidegrees)
        local start_time now elapsed temp avg_c tcolor line done_state=""
        start_time=$(date +%s)

        echo ""
        ui_section "COOLDOWN" | tee >(clean_output >> "$LOG_FILE")
        printf '   %sauto %s wait for CPU < %d°C (max %s)%s\n' "$UI_DIM" "$UI_SEP" $((max_temp / 1000)) \
            "$(format_time "$max_time" "simple")" "$UI_RST" | tee >(clean_output >> "$LOG_FILE")

        while true; do
            temp=0
            if ! read -r temp < "$zone" 2>/dev/null; then temp=0; fi
            if ! [[ "$temp" =~ ^[0-9]+$ ]]; then temp=0; fi
            avg_c=$((temp / 1000))
            tcolor=$(ui_temp_color "$avg_c")
            now=$(date +%s)
            elapsed=$((now - start_time))

            if (( temp > 0 && temp < max_temp )); then
                done_state="cool"; break
            elif (( elapsed >= max_time )); then
                done_state="timeout"; break
            fi

            line=$(printf ' %sCOOLING%s CPU %s%d°C%s %s target <%d°C %s %s/%s' \
                "$UI_WARNC" "$UI_RST" "$tcolor" "$avg_c" "$UI_RST" "$UI_SEP" $((max_temp / 1000)) "$UI_SEP" \
                "$(format_time "$elapsed" "hms")" "$(format_time "$max_time" "hms")")
            printf '\r\033[2K%s' "$line"
            sleep 0.5
        done

        printf '\r\033[2K'
        if [ "$done_state" = "cool" ]; then
            printf '  %s%s%s CPU %s%d°C%s - cooled down after %s\n\n' "$UI_OK" "$UI_CHK" "$UI_RST" \
                "$tcolor" "$avg_c" "$UI_RST" "$(format_time "$elapsed" "hms")" | tee >(clean_output >> "$LOG_FILE")
        else
            printf '  %s%s%s CPU %s%d°C%s - time limit reached after %s, continuing anyway\n\n' "$UI_WARNC" "$UI_WRN" "$UI_RST" \
                "$tcolor" "$avg_c" "$UI_RST" "$(format_time "$elapsed" "hms")" | tee >(clean_output >> "$LOG_FILE")
        fi
        return 0
    fi

    # ---------------- MANUAL: fixed countdown ----------------
    if [ "$total" -le 0 ]; then return 0; fi

    local remaining="$total" mins secs filled bar_on="█" bar_off="░"
    if [ "$BATCH_H" != "─" ]; then bar_on="#"; bar_off="-"; fi
    bw=$((cols - 34))
    if [ "$bw" -gt 20 ]; then bw=20; fi

    echo ""
    ui_section "COOLDOWN" | tee >(clean_output >> "$LOG_FILE")
    printf '   %sfixed pause of %s%s\n' "$UI_DIM" "$(format_time "$total" "simple")" "$UI_RST" \
        | tee >(clean_output >> "$LOG_FILE")

    while (( remaining > 0 )); do
        mins=$(( remaining / 60 ))
        secs=$(( remaining % 60 ))
        printf '\r\033[2K %sWAITING%s %02d:%02d left' "$UI_WARNC" "$UI_RST" "$mins" "$secs"
        if [ "$bw" -ge 6 ]; then
            filled=$(( (total - remaining) * bw / total ))
            printf '  %s%s%s%s%s%s' "$UI_DIM" "$BATCH_V" "$UI_ACC" "$(_batch_rep "$bar_on" "$filled")" \
                "$UI_DIM$(_batch_rep "$bar_off" $((bw - filled)))" "$BATCH_V$UI_RST"
        fi
        sleep 1
        remaining=$((remaining - 1))
    done
    printf '\r\033[2K'
    printf '  %s%s%s cooldown finished (%s)\n\n' "$UI_OK" "$UI_CHK" "$UI_RST" "$(format_time "$total" "simple")" \
        | tee >(clean_output >> "$LOG_FILE")
    return 0
}
