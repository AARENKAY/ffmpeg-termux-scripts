#!/bin/bash

# ==================== LOADING GUARD ====================
if [[ -n "${_LIB_ENCODE_LOADED+x}" ]]; then
    return 0  # Already loaded, skip
fi
readonly _LIB_ENCODE_LOADED=true  # Mark as loaded
# ==================================================

# ===========================================================================
# BATCH UI HELPERS (summary boxes, banners, paginated file browser)
# ---------------------------------------------------------------------------
# Configurable (override via environment before launching, or set after load):
#   BATCH_PAGE_SIZE  files shown per page in the file browser (default 10)
#   BATCH_UI_ASCII   set to 1 to force plain-ASCII borders/icons
# Result of the last process_all_files call (read by callers, never an exit
# status, because convert.sh runs under "set -e"):
#   BATCH_LAST_RESULT = cancelled | empty | no_pending | completed | failed
# Per-file outcome flag, set by process_file/encode_* (see ENCODE_LAST_STATUS):
#   "ok" or "failed"  (encode_* historically return 0 even on failure)
# Note: namerefs (local -n) need Bash >= 4.3 (Termux ships 5.x).
# ===========================================================================
declare -g BATCH_PAGE_SIZE="${BATCH_PAGE_SIZE:-10}"
declare -g BATCH_UI_ASCII="${BATCH_UI_ASCII:-0}"
declare -g BATCH_LAST_RESULT=""
declare -g BATCH_BYTE_MODE=0
declare -g ENCODE_LAST_STATUS="ok"
declare -g ENCODE_LAST_FFMPEG_RC=0   # ffmpeg exit code of the last encode_single_chunk call

# Choose Unicode or ASCII glyphs. Unicode is used only when Bash itself counts
# a multibyte character as one character (i.e. a UTF-8 locale), otherwise the
# width arithmetic would be wrong, so we fall back to ASCII.
_batch_ui_init() {
    local probe='✓'
    BATCH_BYTE_MODE=0
    if [ "${#probe}" -ne 1 ]; then BATCH_BYTE_MODE=1; fi   # C/POSIX locale: ${#var} counts bytes
    if [ "$BATCH_UI_ASCII" != "1" ] && [ "${#probe}" -eq 1 ] \
        && [ "${TERM:-}" != "dumb" ] && [ "${TERM:-}" != "linux" ]; then
        BATCH_TL='╭'; BATCH_TR='╮'; BATCH_BL='╰'; BATCH_BR='╯'
        BATCH_H='─'; BATCH_V='│'; BATCH_DH='═'
        BATCH_OK='✓'; BATCH_PEND='○'; BATCH_ELL='…'; BATCH_ARROW='➤'
    else
        BATCH_TL='+'; BATCH_TR='+'; BATCH_BL='+'; BATCH_BR='+'
        BATCH_H='-'; BATCH_V='|'; BATCH_DH='='
        BATCH_OK='[x]'; BATCH_PEND='[ ]'; BATCH_ELL='...'; BATCH_ARROW='>'
    fi
}

# Terminal width: $COLUMNS, then the controlling tty, then tput, then 80.
_batch_cols() {
    local c="${COLUMNS:-}"
    if ! [[ "$c" =~ ^[0-9]+$ ]] || [ "$c" -lt 20 ]; then
        c=$(stty size 2>/dev/null </dev/tty | awk '{print $2}') || c=""
    fi
    if ! [[ "$c" =~ ^[0-9]+$ ]] || [ "$c" -lt 20 ]; then
        c=$(tput cols 2>/dev/null) || c=""
    fi
    if ! [[ "$c" =~ ^[0-9]+$ ]] || [ "$c" -lt 20 ]; then
        c=80
    fi
    printf '%s' "$c"
}

# Repeat a string N times: _batch_rep STRING N
_batch_rep() {
    local pad
    printf -v pad '%*s' "$2" ''
    printf '%s' "${pad// /$1}"
}

# Truncate to MAX characters keeping the tail (extension / deepest folder),
# and neutralise control characters so names cannot corrupt the terminal.
_batch_trunc() {
    local s="$1" max="$2"
    s="${s//[[:cntrl:]]/?}"
    if [ "$max" -lt 1 ]; then
        return 0
    fi
    if [ "${#s}" -le "$max" ]; then
        printf '%s' "$s"
    elif [ "$max" -le "${#BATCH_ELL}" ]; then
        printf '%s' "${s:0:max}"
    else
        local tail="${s: -$((max - ${#BATCH_ELL}))}"
        if [ "${BATCH_BYTE_MODE:-0}" -eq 1 ]; then
            # Byte-counting locale: drop orphaned UTF-8 continuation bytes (0x80-0xBF)
            # left at the start of the cut so no half character is printed.
            while [ -n "$tail" ] && [[ "${tail:0:1}" == [$'\x80'-$'\xbf'] ]]; do
                tail="${tail:1}"
            done
        fi
        printf '%s%s' "$BATCH_ELL" "$tail"
    fi
}

# Draw a bordered box sized to its content (capped to the terminal width).
# Usage: _batch_box "TITLE" "label|color|value" ...
#   - empty label  => the value spans the whole row
#   - color may be empty; only the first two '|' are separators
_batch_box() {
    local title="$1"; shift
    local cols maxw row label rest color value
    local labelw=0 contentw=0 w i n pfx avail pad tl
    local labels=() colors=() values=()
    cols=$(_batch_cols)
    maxw=$((cols - 2))
    if [ "$maxw" -lt 20 ]; then maxw=20; fi

    for row in "$@"; do
        label="${row%%|*}"; rest="${row#*|}"
        color="${rest%%|*}"; value="${rest#*|}"
        value="${value//[[:cntrl:]]/?}"
        labels+=("$label"); colors+=("$color"); values+=("$value")
        if [ "${#label}" -gt "$labelw" ]; then labelw=${#label}; fi
    done
    n=${#labels[@]}
    for (( i=0; i<n; i++ )); do
        pfx=0
        if [ -n "${labels[$i]}" ]; then pfx=$((labelw + 3)); fi
        if [ $((pfx + ${#values[$i]})) -gt "$contentw" ]; then
            contentw=$((pfx + ${#values[$i]}))
        fi
    done

    w=$((contentw + 2))
    if [ "$w" -lt $((${#title} + 4)) ]; then w=$((${#title} + 4)); fi
    if [ "$w" -gt "$maxw" ]; then w=$maxw; fi

    # Top border with centred title
    title=$(_batch_trunc "$title" $((w - 2)))
    tl=$(( (w - ${#title} - 2) / 2 ))
    printf '%b%s%s %s %s%s%b\n' "$COLOR_BLUE" "$BATCH_TL" "$(_batch_rep "$BATCH_H" "$tl")" \
        "$title" "$(_batch_rep "$BATCH_H" $((w - ${#title} - 2 - tl)))" "$BATCH_TR" "$COLOR_RESET"

    for (( i=0; i<n; i++ )); do
        pfx=0
        if [ -n "${labels[$i]}" ]; then pfx=$((labelw + 3)); fi
        avail=$((w - 2 - pfx))
        value=$(_batch_trunc "${values[$i]}" "$avail")
        pad=$((w - 2 - pfx - ${#value}))
        if [ "$pad" -lt 0 ]; then pad=0; fi
        if [ -n "${labels[$i]}" ]; then
            printf '%b%s%b %b%-*s%b : %b%s%b%*s %b%s%b\n' \
                "$COLOR_BLUE" "$BATCH_V" "$COLOR_RESET" \
                "$COLOR_YELLOW" "$labelw" "${labels[$i]}" "$COLOR_RESET" \
                "${colors[$i]}" "$value" "$COLOR_RESET" "$pad" "" \
                "$COLOR_BLUE" "$BATCH_V" "$COLOR_RESET"
        else
            printf '%b%s%b %b%s%b%*s %b%s%b\n' \
                "$COLOR_BLUE" "$BATCH_V" "$COLOR_RESET" \
                "${colors[$i]}" "$value" "$COLOR_RESET" "$pad" "" \
                "$COLOR_BLUE" "$BATCH_V" "$COLOR_RESET"
        fi
    done

    printf '%b%s%s%s%b\n' "$COLOR_BLUE" "$BATCH_BL" "$(_batch_rep "$BATCH_H" "$w")" "$BATCH_BR" "$COLOR_RESET"
}

# Bordered menu panel with coloured keys; several items per row are allowed.
# Usage: _batch_menu_box "TITLE" "key|label|color~key|label|color" ...
# A dim colour (e.g. "\033[2m") marks an item that is currently unavailable.
_batch_menu_box() {
    local title="$1"; shift
    local cols maxw row seg segs=() key rest label color plain w=0 i n tl pad first
    local plains=() rows=() src=("$@")
    cols=$(_batch_cols)
    maxw=$((cols - 2))
    if [ "$maxw" -lt 20 ]; then maxw=20; fi

    # Rows too wide for the terminal are split into one item per row
    for row in "${src[@]}"; do
        plain=""
        IFS='~' read -r -a segs <<< "$row"
        for seg in "${segs[@]}"; do
            key="${seg%%|*}"; rest="${seg#*|}"; label="${rest%%|*}"
            plain+="${plain:+  }[$key] $label"
        done
        if [ $((${#plain} + 2)) -gt "$maxw" ] && [ "${#segs[@]}" -gt 1 ]; then
            for seg in "${segs[@]}"; do rows+=("$seg"); done
        else
            rows+=("$row")
        fi
    done

    for row in "${rows[@]}"; do
        plain=""
        IFS='~' read -r -a segs <<< "$row"
        for seg in "${segs[@]}"; do
            key="${seg%%|*}"; rest="${seg#*|}"; label="${rest%%|*}"
            plain+="${plain:+  }[$key] $label"
        done
        plains+=("$plain")
        if [ $((${#plain} + 2)) -gt "$w" ]; then w=$((${#plain} + 2)); fi
    done
    if [ "$w" -lt $((${#title} + 4)) ]; then w=$((${#title} + 4)); fi
    if [ "$w" -gt "$maxw" ]; then w=$maxw; fi

    title=$(_batch_trunc "$title" $((w - 2)))
    tl=$(( (w - ${#title} - 2) / 2 ))
    printf '%b%s%s %s %s%s%b\n' "$COLOR_BLUE" "$BATCH_TL" "$(_batch_rep "$BATCH_H" "$tl")" \
        "$title" "$(_batch_rep "$BATCH_H" $((w - ${#title} - 2 - tl)))" "$BATCH_TR" "$COLOR_RESET"

    n=${#rows[@]}
    for (( i=0; i<n; i++ )); do
        plain="${plains[$i]}"
        if [ "${#plain}" -gt $((w - 2)) ]; then
            # Too narrow for styling: plain truncated row keeps the frame intact
            plain=$(_batch_trunc "$plain" $((w - 2)))
            printf '%b%s%b %s%*s %b%s%b\n' "$COLOR_BLUE" "$BATCH_V" "$COLOR_RESET" "$plain" \
                $((w - 2 - ${#plain})) "" "$COLOR_BLUE" "$BATCH_V" "$COLOR_RESET"
            continue
        fi
        pad=$((w - 2 - ${#plain}))
        printf '%b%s%b ' "$COLOR_BLUE" "$BATCH_V" "$COLOR_RESET"
        IFS='~' read -r -a segs <<< "${rows[$i]}"
        first=1
        for seg in "${segs[@]}"; do
            key="${seg%%|*}"; rest="${seg#*|}"; label="${rest%%|*}"; color="${rest#*|}"
            if [ "$first" -eq 0 ]; then printf '  '; fi
            first=0
            printf '%b[%s]%b %b%s%b' "$COLOR_YELLOW" "$key" "$COLOR_RESET" "$color" "$label" "$COLOR_RESET"
        done
        printf '%*s %b%s%b\n' "$pad" "" "$COLOR_BLUE" "$BATCH_V" "$COLOR_RESET"
    done
    printf '%b%s%s%s%b\n' "$COLOR_BLUE" "$BATCH_BL" "$(_batch_rep "$BATCH_H" "$w")" "$BATCH_BR" "$COLOR_RESET"
}

# Compact per-file banner (printed once per file, never per progress update).
# Usage: _batch_banner POSITION TOTAL FINISHED PENDING FAILED NAME
# With BATCH_CLEAR_SCREEN=1 (default) the full output of each file replaces the previous
# file's instead of stacking below it. Only the visible screen is cleared (scrollback is
# kept), and nothing is sent when output is not a terminal (logs, pipes).
declare -g BATCH_CLEAR_SCREEN="${BATCH_CLEAR_SCREEN:-1}"
_batch_clear_screen() {
    if [ "${BATCH_CLEAR_SCREEN:-1}" = "1" ] && [ -t 1 ]; then printf '\033[H\033[2J'; fi
    return 0
}

_batch_banner() {
    local pos="$1" total="$2" finished="$3" pending="$4" failed="$5" name="$6" eta1="${7:-}" eta2="${8:-}" eta3="${9:-}" last="${10:-}" last_ok="${11:-1}"
    local cols maxw l1 l2 l3 w
    cols=$(_batch_cols)
    maxw=$((cols - 1))
    l1="PROCESSING FILE [$pos/$total]"
    l2="Progress: $finished/$pending pending done"
    if [ "$failed" -gt 0 ]; then l2="$l2 ($failed failed)"; fi
    l2="${l2:0:maxw}"   # ASCII-only text: cut from the end so the counters stay visible
    l3="File: $(_batch_trunc "$name" $((maxw - 6)))"
    eta1="${eta1:0:maxw}"; eta2="${eta2:0:maxw}"; eta3="${eta3:0:maxw}"; last="${last:0:maxw}"
    w=${#l1}
    if [ "${#l2}" -gt "$w" ]; then w=${#l2}; fi
    if [ "${#l3}" -gt "$w" ]; then w=${#l3}; fi
    if [ "${#eta1}" -gt "$w" ]; then w=${#eta1}; fi
    if [ "${#eta2}" -gt "$w" ]; then w=${#eta2}; fi
    if [ "${#eta3}" -gt "$w" ]; then w=${#eta3}; fi
    if [ "${#last}" -gt "$w" ]; then w=${#last}; fi
    if [ "$w" -gt "$maxw" ]; then w=$maxw; fi
    echo ""
    printf '%b%s%b\n' "$COLOR_ORANGE" "$(_batch_rep "$BATCH_DH" "$w")" "$COLOR_RESET"
    printf '%b%s%b\n' "$COLOR_ORANGE" "$l1" "$COLOR_RESET"
    printf '%s\n' "$l2"
    if [ -n "$last" ]; then
        if [ "$last_ok" = "1" ]; then printf '%b%s%b\n' "$COLOR_GREEN" "$last" "$COLOR_RESET"
        else printf '%b%s%b\n' "$COLOR_RED" "$last" "$COLOR_RESET"; fi
    fi
    printf '%bFile:%b %s\n' "$COLOR_CYAN" "$COLOR_RESET" "${l3#File: }"
    if [ -n "$eta1" ]; then printf '%b%s%b\n' "$COLOR_BLUE" "$eta1" "$COLOR_RESET"; fi
    if [ -n "$eta2" ]; then printf '%s\n' "$eta2"; fi
    if [ -n "$eta3" ]; then printf '%s\n' "$eta3"; fi
    printf '%b%s%b\n' "$COLOR_ORANGE" "$(_batch_rep "$BATCH_DH" "$w")" "$COLOR_RESET"
}

# Render one page of the file list (read-only; no state is modified).
# Usage: _batch_render_page INPUT_DIR FILES_ARRAY_NAME DURS_ARRAY_NAME PAGE PAGE_SIZE TOTAL_PAGES
_batch_render_page() {
    local input_dir_clean="${1%/}"
    local -n _rp_files="$2"
    local -n _rp_durs="$3"
    local page="$4" page_size="$5" total_pages="$6"
    local total=${#_rp_files[@]}
    local first last i numw cols rel name dur_str status icon icolor
    cols=$(_batch_cols)

    if [ "$total" -eq 0 ]; then
        first=0; last=0
    else
        first=$(( (page - 1) * page_size + 1 ))
        last=$(( page * page_size ))
        if [ "$last" -gt "$total" ]; then last=$total; fi
    fi

    numw=${#total}
    if [ "$numw" -lt 2 ]; then numw=2; fi

    echo ""
    _batch_box "FILE LIST" "||Page $page of $total_pages | Showing $first-$last of $total"
    echo ""

    if [ "$total" -eq 0 ]; then
        echo -e " ${COLOR_YELLOW}NO FILES DISCOVERED${COLOR_RESET}"
        echo ""
        return 0
    fi

    for (( i=first-1; i<last; i++ )); do
        rel="${_rp_files[$i]#"$input_dir_clean"/}"
        name=$(_batch_trunc "$rel" $((cols - numw - ${#BATCH_PEND} - 5)))
        if [ -n "${_rp_durs[$i]}" ]; then
            dur_str=$(format_time "${_rp_durs[$i]}" "hms") || dur_str="unknown"
        else
            dur_str="unknown"
        fi
        if is_completed "${_rp_files[$i]}"; then
            icon="$BATCH_OK"; icolor="$COLOR_GREEN"; status="${COLOR_GREEN}Already processed${COLOR_RESET}"
        else
            icon="$BATCH_PEND"; icolor="$COLOR_YELLOW"; status="Pending"
        fi
        printf '%0*d. %b%s%b %b%s%b\n' "$numw" $((i + 1)) "$icolor" "$icon" "$COLOR_RESET" \
            "$COLOR_CYAN" "$name" "$COLOR_RESET"
        printf '%*sDuration: %s\n' $((numw + 2)) "" "$dur_str"
        printf '%*sStatus: %b\n' $((numw + 2)) "" "$status"
        echo ""
    done
}

# Paginated, inspection-only file browser.
# Usage: display_file_list_paged INPUT_DIR FILES_ARRAY_NAME DURS_ARRAY_NAME [PAGE_SIZE]
# Keys (case-insensitive, then Enter): N next, P previous, R return, Q quit list.
# Both R and Q leave the browser and return to the caller's menu.
display_file_list_paged() {
    local input_dir="$1"
    local files_name="$2"
    local durs_name="$3"
    local page_size="${4:-$BATCH_PAGE_SIZE}"
    local -n _fl_files="$files_name"
    local total=${#_fl_files[@]}
    local total_pages page=1 redraw=1 key

    if ! is_positive_integer "$page_size" || [ "$page_size" -lt 1 ]; then
        page_size=10
    fi
    total_pages=$(( (total + page_size - 1) / page_size ))
    if [ "$total_pages" -lt 1 ]; then total_pages=1; fi

    while true; do
        if [ "$redraw" -eq 1 ]; then
            _batch_render_page "$input_dir" "$files_name" "$durs_name" "$page" "$page_size" "$total_pages"
            local next_c="$COLOR_GREEN" prev_c="$COLOR_GREEN"
            if [ "$page" -ge "$total_pages" ]; then next_c="\033[2m"; fi
            if [ "$page" -le 1 ]; then prev_c="\033[2m"; fi
            _batch_menu_box "NAVIGATE" \
                "N|Next page|$next_c~P|Previous page|$prev_c" \
                "R|Return to menu|$COLOR_CYAN~Q|Quit list|$COLOR_RED"
            redraw=0
        fi
        printf '%b %s%b PAGE %d/%d %b[N/P/R/Q]:%b ' "$COLOR_BLUE" "$BATCH_ARROW" "$COLOR_RESET" \
            "$page" "$total_pages" "$COLOR_YELLOW" "$COLOR_RESET"
        if ! read -r key; then
            echo ""
            return 0
        fi
        key="${key//[[:space:]]/}"
        case "${key,,}" in
            n)
                if [ "$page" -lt "$total_pages" ]; then
                    page=$((page + 1)); redraw=1
                else
                    echo -e " ${COLOR_YELLOW}ALREADY ON THE LAST PAGE${COLOR_RESET}"
                fi
                ;;
            p)
                if [ "$page" -gt 1 ]; then
                    page=$((page - 1)); redraw=1
                else
                    echo -e " ${COLOR_YELLOW}ALREADY ON THE FIRST PAGE${COLOR_RESET}"
                fi
                ;;
            r|q)
                return 0
                ;;
            *)
                echo -e " ${COLOR_RED}INVALID OPTION${COLOR_RESET} (use N, P, R or Q)"
                ;;
        esac
    done
}

# Pre-processing menu. Returns 0 = start processing, 1 = cancel.
# Usage: batch_confirm_menu INPUT_DIR FILES_ARRAY_NAME DURS_ARRAY_NAME PENDING_COUNT
# Non-interactive stdin (not a terminal): starts automatically when files are
# pending, which matches the behaviour before this menu existed.
batch_confirm_menu() {
    local input_dir="$1" files_name="$2" durs_name="$3" pending="$4"
    local choice

    if [ ! -t 0 ]; then
        if [ "$pending" -eq 0 ]; then
            return 1
        fi
        echo -e "${COLOR_YELLOW} NON-INTERACTIVE INPUT - STARTING AUTOMATICALLY${COLOR_RESET}"
        return 0
    fi

    while true; do
        echo ""
        local start_label="Start processing" start_c="$COLOR_GREEN"
        if [ "$pending" -eq 0 ]; then
            start_label="Start processing (nothing pending)"; start_c="\033[2m"
        fi
        _batch_menu_box "BATCH MENU" \
            "1|View file list|$COLOR_CYAN" \
            "2|$start_label|$start_c" \
            "3|Cancel batch|$COLOR_RED"
        while true; do
            printf '%b %s%b SELECT %b[1-3]:%b ' "$COLOR_BLUE" "$BATCH_ARROW" "$COLOR_RESET" "$COLOR_YELLOW" "$COLOR_RESET"
            if ! read -r choice; then
                echo ""
                return 1
            fi
            choice="${choice//[[:space:]]/}"
            case "$choice" in
                1)
                    display_file_list_paged "$input_dir" "$files_name" "$durs_name"
                    break
                    ;;
                2)
                    if [ "$pending" -eq 0 ]; then
                        echo -e " ${COLOR_YELLOW}NO PENDING FILES:${COLOR_RESET} every file is already processed, nothing to do"
                        break
                    fi
                    return 0
                    ;;
                3)
                    return 1
                    ;;
                *)
                    echo -e " ${COLOR_RED}INVALID OPTION${COLOR_RESET} (enter 1, 2 or 3)"
                    ;;
            esac
        done
    done
}


# ---------------------------------------------------------------------------
# NUL-safe sort of a file array by a numeric stat key.
# Usage: _sort_files_by_stat ARRAY_NAME STAT_FORMAT asc|desc     (%Y mtime, %s size)
# The old "xargs stat | sort | sed 's/$/\x0/'" pipeline left a newline in front of
# every path after the first, so date/size sorting produced non-existent names.
# ---------------------------------------------------------------------------
_sort_files_by_stat() {
    local -n _ssb_arr="$1"
    local fmt="$2" order="${3:-asc}" f key rec
    local sort_args=(-z -n) sorted=()
    if [ "$order" = "desc" ]; then sort_args+=(-r); fi
    while IFS= read -r -d '' rec; do
        sorted+=("${rec#* }")
    done < <(
        for f in "${_ssb_arr[@]}"; do
            key=$(stat -c "$fmt" -- "$f" 2>/dev/null) || key=0
            if ! [[ "$key" =~ ^[0-9]+$ ]]; then key=0; fi
            printf '%s %s\0' "$key" "$f"
        done | sort "${sort_args[@]}"
    )
    if [ "${#sorted[@]}" -gt 0 ]; then _ssb_arr=("${sorted[@]}"); fi
    return 0
}

# Escape-free check that DIR is a chunk folder of FILE_NOEXT: chunks_<name>_<digits>
_is_chunk_dir_of() {
    local base="${1##*/}" name="$2" prefix
    prefix="chunks_${name}_"
    [[ "$base" == "$prefix"* ]] && [[ "${base#"$prefix"}" =~ ^[0-9]+$ ]]
}

# ===========================================================================
# ENCODE MODULE - SELF-CORRECTING ETA
# The initial batch estimate assumes 3 s of work per second of video. Once real
# encoding has been timed, the remaining time is recalculated from the measured
# speed (cooldowns are added separately and never counted as encoding time).
# ===========================================================================
declare -g ETA_MEDIA_SEC=0      # seconds of video encoded so far (this batch)
declare -g ETA_WALL_SEC=0       # wall seconds spent encoding it (no cooldowns)

_eta_reset() { ETA_MEDIA_SEC=0; ETA_WALL_SEC=0; return 0; }

# _eta_record MEDIA_SECONDS WALL_SECONDS   (call only for successful encodes)
_eta_record() {
    if [[ "${1:-}" =~ ^[0-9]+(\.[0-9]+)?$ ]] && [[ "${2:-}" =~ ^[0-9]+$ ]]; then
        ETA_MEDIA_SEC=$(awk -v a="$ETA_MEDIA_SEC" -v b="$1" 'BEGIN { printf "%.3f", a + b }')
        ETA_WALL_SEC=$((ETA_WALL_SEC + $2))
    fi
    return 0
}

# Measured only after >= 5 s of encoding were timed (shorter runs are too noisy).
_eta_is_measured() { awk -v m="$ETA_MEDIA_SEC" -v w="$ETA_WALL_SEC" 'BEGIN { exit !(w >= 5 && m > 0) }'; }

# wall seconds per second of video
_eta_ratio() {
    awk -v m="$ETA_MEDIA_SEC" -v w="$ETA_WALL_SEC" 'BEGIN { if (w >= 5 && m > 0) printf "%.4f", w / m; else printf "3.0000" }'
}

_eta_speed_text() {   # e.g. "0.42x (measured)"
    local r src="estimate"
    r=$(_eta_ratio)
    if _eta_is_measured; then src="measured"; fi
    awk -v r="$r" -v s="$src" 'BEGIN { printf "%.2fx (%s)", (r > 0) ? 1 / r : 0, s }'
}

# Finish clock for "now + SECONDS". Same day: "03:40 PM". Another day: the day is
# shown, so an estimate beyond 24 h is never ambiguous:
#   next day  -> "Tomorrow 03:40 PM"      later -> "Sat 02 Nov, 03:40 PM (in 3 days)"
_eta_clock() {
    local secs="${1:-0}" now_day tgt_day diff days
    if ! [[ "$secs" =~ ^[0-9]+$ ]]; then printf 'N/A'; return 0; fi
    now_day=$(date +%Y-%m-%d)
    tgt_day=$(date -d "+$secs seconds" +%Y-%m-%d 2>/dev/null) || { printf 'N/A'; return 0; }
    diff=$(( $(date -d "$tgt_day" +%s 2>/dev/null || echo 0) - $(date -d "$now_day" +%s 2>/dev/null || echo 0) ))
    days=$(( (diff + 43200) / 86400 ))   # rounded, so DST shifts cannot change the day count
    if [ "$days" -le 0 ]; then
        date -d "+$secs seconds" +"%I:%M %p" 2>/dev/null || printf 'N/A'
    elif [ "$days" -eq 1 ]; then
        printf 'Tomorrow %s' "$(date -d "+$secs seconds" +"%I:%M %p" 2>/dev/null || echo "")"
    else
        printf '%s (in %d days)' "$(date -d "+$secs seconds" +"%a %d %b, %I:%M %p" 2>/dev/null || echo "")" "$days"
    fi
    return 0
}

# Remaining time / finish clock for all pending files from index START on.
# Sets ETA_L1 (remaining), ETA_L2 (finish clock) and ETA_L3 (speed) as plain text for the
# file banner. Unknown durations make it "(approx.)"; none known -> "unavailable".
# Usage: _eta_batch_compute DURATIONS_ARRAY WAS_DONE_ARRAY START_INDEX
declare -g ETA_L1="" ETA_L2="" ETA_L3=""
_eta_batch_compute() {
    local -n _eb_d="$1"
    local -n _eb_w="$2"
    local start="$3" i n=${#_eb_d[@]} media=0 chunks=0 unknown=0 c ratio rem clock approx=""
    ETA_L1=""; ETA_L2=""; ETA_L3=""
    for (( i=start; i<n; i++ )); do
        if [ "${_eb_w[$i]:-1}" -ne 0 ]; then continue; fi
        if [ -n "${_eb_d[$i]:-}" ]; then
            media=$(awk -v t="$media" -v d="${_eb_d[$i]}" 'BEGIN { printf "%.3f", t + d }')
            c=$(calculate_chunk_count "${_eb_d[$i]}" "$CHUNK_MODE" "$MANUAL_CHUNK_DURATION" 2>/dev/null) || c=1
            if ! [[ "$c" =~ ^[0-9]+$ ]]; then c=1; fi
            chunks=$((chunks + c))
        else
            unknown=$((unknown + 1))
        fi
    done
    if ! awk -v m="$media" 'BEGIN { exit !(m > 0) }'; then
        if [ "$unknown" -gt 0 ]; then ETA_L1="ETA remaining: unavailable (durations unknown)"; fi
        return 0
    fi
    if [ "$unknown" -gt 0 ]; then approx=" (approx.)"; fi
    ratio=$(_eta_ratio)
    rem=$(awk -v m="$media" -v r="$ratio" -v n="$chunks" -v c="${COOLDOWN_TIME:-0}" \
        'BEGIN { cd = (n > 1) ? (n - 1) * c : 0; printf "%d", m * r + cd }')
    clock=$(_eta_clock "$rem")
    ETA_L1="ETA remaining: $(format_time "$rem" "compact" 2>/dev/null || echo n/a)$approx"
    ETA_L2="Finish: ${clock}${approx}"
    ETA_L3="Speed: $(_eta_speed_text)"
    return 0
}

# Revised ETA for the rest of the current chunked file.
# Usage: _eta_file_line MEDIA_SECONDS_PER_CHUNK REMAINING_CHUNKS
_eta_file_line() {
    local m="$1" left="$2" ratio rem clock
    ratio=$(_eta_ratio)
    rem=$(awk -v m="$m" -v r="$ratio" -v n="$left" -v c="${COOLDOWN_TIME:-0}" 'BEGIN { printf "%d", n * (m * r + c) }')
    clock=$(_eta_clock "$rem")
    echo -e "${COLOR_BLUE} FILE ETA:${COLOR_RESET} $(format_time "$rem" "compact" 2>/dev/null || echo n/a) (cooldowns included) ${COLOR_BLUE}FINISH ~${COLOR_RESET} $clock ${COLOR_BLUE}SPEED${COLOR_RESET} $(_eta_speed_text)" \
        | tee >(clean_output >> "$LOG_FILE")
    return 0
}

# ===========================================================================
# ENCODE MODULE - PROCESS ALL FILES IN DIRECTORY
# ===========================================================================

process_all_files() {
    local input_dir="$1"
    local current_log_dir="$LOG_DIR"
    
    if [ ! -d "$input_dir" ]; then
        echo -e "${COLOR_RED} DIRECTORY DOES NOT EXIST:${COLOR_RESET} $input_dir"
        sleep 2
        return 1
    fi
    
    if [ -z "$OUTPUT_DIR" ]; then
        echo -e "${COLOR_RED} OUTPUT_DIR IS NOT SET${COLOR_RESET}"
        sleep 2
        return 1
    fi
    
    mkdir -p "$OUTPUT_DIR" || {
        echo -e "${COLOR_RED} FAILED TO CREATE OUTPUT DIRECTORY:${COLOR_RESET} $OUTPUT_DIR"
        sleep 2
        return 1
    }
    
    local file_log_dir="$LOG_DIR"

    # Data safety: the output folder must not be the input folder (ffmpeg -y would
    # overwrite the sources), and nesting it inside the input tree would feed
    # converted files back into the next scan.
    local _in_real _out_real
    _in_real=$(realpath -m -- "$input_dir")
    _out_real=$(realpath -m -- "$OUTPUT_DIR")
    if [ "$_in_real" = "$_out_real" ]; then
        echo -e "${COLOR_RED} OUTPUT FOLDER IS THE SAME AS THE INPUT FOLDER:${COLOR_RESET} $OUTPUT_DIR"
        echo -e "${COLOR_YELLOW} CHOOSE A DIFFERENT OUTPUT_DIR SO THE ORIGINALS CANNOT BE OVERWRITTEN${COLOR_RESET}"
        sleep 2
        return 1
    fi
    case "$_out_real/" in
        "$_in_real"/*)
            echo -e "${COLOR_YELLOW} WARNING: OUTPUT FOLDER IS INSIDE THE INPUT FOLDER;${COLOR_RESET} converted files will be picked up by the next scan"
            ;;
    esac

	# Find and sort files by modification time (oldest first)
	local files=()
    while IFS= read -r -d '' file; do
        files+=("$file")
    done < <(find "$input_dir" \
        \( -type d \( -iname "chunks_*" -o -name ".ffmpeg_diagnostics" \) -prune \) -o \
        \( -type f \( \
        -iname "*.mp4" -o \
        -iname "*.mkv" -o \
        -iname "*.mov" -o \
        -iname "*.avi" -o \
        -iname "*.webm" -o \
        -iname "*.wmv" -o \
        -iname "*.flv" -o \
        -iname "*.mpeg" -o \
        -iname "*.mpg" -o \
        -iname "*.mpe" -o \
        -iname "*.m4v" -o \
        -iname "*.3gp" -o \
        -iname "*.3g2" -o \
        -iname "*.f4v" -o \
        -iname "*.ts" -o \
        -iname "*.m2ts" -o \
        -iname "*.mts" -o \
        -iname "*.vob" \) -printf "%p\0" \))

    # Empty folder: nothing to sort or process (also avoids sorting a lone empty entry)
    if [ "${#files[@]}" -eq 0 ]; then
        BATCH_LAST_RESULT="empty"
        echo -e "${COLOR_YELLOW} NO SUPPORTED VIDEO FILES FOUND IN:${COLOR_RESET} $input_dir"
        return 0
    fi

    # Sort files based on selected mode (NUL-safe)
    case "$FILE_SORT_MODE" in
        date_old)   _sort_files_by_stat files '%Y' asc ;;
        date_new)   _sort_files_by_stat files '%Y' desc ;;
        name_az)    mapfile -d '' files < <(printf '%s\0' "${files[@]}" | sort -z -d) ;;
        name_za)    mapfile -d '' files < <(printf '%s\0' "${files[@]}" | sort -z -r -d) ;;
        size_small) _sort_files_by_stat files '%s' asc ;;
        size_large) _sort_files_by_stat files '%s' desc ;;
        *)          _sort_files_by_stat files '%Y' asc ;;
    esac
	
	local total_files=${#files[@]}
    local processed_files=0
    local current_index=0
    local input_dir_clean="${input_dir%/}"
    _batch_ui_init

    local TOTAL_DURATION=0
    local remaining_files=0  # Track files that actually need processing
    local TOTAL_CHUNKS=0     # Track total chunks for cooldown overhead
    local done_files=0       # Already completed before this batch started
    local unknown_duration=0 # Pending files whose duration could not be read
    local durations=()       # Parallel to files[]: valid duration or empty
    local was_done=()        # Parallel to files[]: 1 if already completed at scan time
    local collide=()         # Parallel to files[]: path of the file that owns the same output name
    local -A out_owner=()    # lower-cased expected output path -> first file claiming it
    local _crel _cdir _cname _ckey
    local input_file filename idx dur show_scan=0
    if [ -t 1 ]; then show_scan=1; fi

    # Scan: probe durations and completion state. Nothing is listed here, the
    # complete sorted list stays in memory (files/durations/was_done).
    for (( idx=0; idx<total_files; idx++ )); do
        file="${files[$idx]}"
        if [ "$show_scan" -eq 1 ]; then
            printf '\r\033[2K%b SCANNING%b %d/%d' "$COLOR_YELLOW" "$COLOR_RESET" $((idx + 1)) "$total_files"
        fi
        dur=$(ffprobe -v error -select_streams v:0 -show_entries format=duration \
            -of default=noprint_wrappers=1:nokey=1 "$file" 2>/dev/null </dev/null || true)
        dur="${dur%%$'\n'*}"
        dur="${dur//[[:space:]]/}"
        if ! [[ "$dur" =~ ^[0-9]+(\.[0-9]+)?$ ]] \
            || ! awk -v d="$dur" 'BEGIN { exit !(d > 0) }'; then
            dur=""
        fi
        durations+=("$dur")

        # Two sources that map to the same output name (clip.mp4 + clip.mkv in one
        # folder, or names differing only in case on case-insensitive Android storage)
        # would silently overwrite each other's output. The later one is refused.
        _crel="${file#"$input_dir_clean"/}"
        _cdir="$(dirname -- "$_crel")"
        _cname="$(basename -- "$file")"
        _ckey="$OUTPUT_DIR/"
        if [ "$_cdir" != "." ]; then _ckey+="$_cdir/"; fi
        _ckey+="${_cname%.*}.$OUTPUT_FORMAT"
        _ckey="${_ckey,,}"
        if [ -n "${out_owner["$_ckey"]+x}" ]; then
            collide+=("${out_owner["$_ckey"]}")
        else
            out_owner["$_ckey"]="$file"
            collide+=("")
        fi

        # Check if file is already processed (kept in the list, never removed)
        if is_completed "$file"; then
            done_files=$((done_files + 1))
            was_done+=(1)
        else
            was_done+=(0)
            remaining_files=$((remaining_files + 1))
            if [ -n "$dur" ]; then
                # Add to total duration
                TOTAL_DURATION=$(awk -v total="$TOTAL_DURATION" -v d="$dur" \
                    'BEGIN { printf "%.6f", total + d }')

                # Calculate chunk count for ETA
                file_chunks=$(calculate_chunk_count "$dur" "$CHUNK_MODE" "$MANUAL_CHUNK_DURATION")
                if ! [[ "$file_chunks" =~ ^[0-9]+$ ]]; then file_chunks=1; fi
                TOTAL_CHUNKS=$((TOTAL_CHUNKS + file_chunks))
            else
                unknown_duration=$((unknown_duration + 1))
            fi
        fi
    done
    if [ "$show_scan" -eq 1 ]; then printf '\r\033[2K'; fi

    # --- Encode time estimate (existing approach: 3x realtime) ---
    BASE_ETA=$(awk -v t="$TOTAL_DURATION" 'BEGIN { printf "%.6f", t * 3 }')

    # --- Cooldown overhead based on chunking ---
    COOLDOWN_OVERHEAD=$(awk -v n="$TOTAL_CHUNKS" -v c="$COOLDOWN_TIME" '
    BEGIN {
        if (n > 1) printf "%.6f", (n - 1) * c;
        else printf "0";
    }')

    # --- FINAL ETA ---
    TOTAL_ETA=$(awk -v base="$BASE_ETA" -v cd="$COOLDOWN_OVERHEAD" \
        'BEGIN { printf "%.6f", base + cd }')

    # Convert ETA to integer seconds
    ETA_SEC=$(awk -v t="$TOTAL_ETA" 'BEGIN { printf "%d", t }')

    # Completion time (time only)
    CLOCK=$(_eta_clock "$ETA_SEC")

    # Summary strings (never show a misleading estimate)
    local dur_str eta_str fin_str approx=""
    local valid_pending=$((remaining_files - unknown_duration))
    if [ "$remaining_files" -eq 0 ]; then
        dur_str="none"; eta_str="n/a"; fin_str="n/a"
    elif [ "$valid_pending" -eq 0 ]; then
        dur_str="unavailable"; eta_str="unavailable"; fin_str="unavailable"
    else
        if [ "$unknown_duration" -gt 0 ]; then approx=" (approx.)"; fi
        dur_str="$(format_time "$TOTAL_DURATION" "compact" || echo "n/a")$approx"
        eta_str="$(format_time "$TOTAL_ETA" "compact" || echo "n/a")$approx"
        fin_str="$CLOCK$approx"
    fi

    if [ "$total_files" -eq 1 ]; then
        echo -e "${COLOR_YELLOW} FOUND${COLOR_RESET} 1 ${COLOR_YELLOW}FILE IN THE FOLDER${COLOR_RESET}"
    else
        echo -e "${COLOR_YELLOW} FOUND${COLOR_RESET} $total_files ${COLOR_YELLOW}FILES IN THE FOLDER${COLOR_RESET}"
    fi
    echo ""
    local summary_rows=(
        "Input folder|$COLOR_CYAN|$input_dir"
        "Total files found||$total_files"
        "Already processed|$COLOR_GREEN|$done_files"
        "Remaining files||$remaining_files"
        "Remaining duration||$dur_str"
    )
    if [ "$unknown_duration" -gt 0 ]; then
        summary_rows+=("Unknown duration|$COLOR_YELLOW|$unknown_duration pending file(s)")
    fi
    _batch_box "BATCH PROCESSING" "${summary_rows[@]}"

    # Interactive pre-processing menu (view list / start / cancel)
    if ! batch_confirm_menu "$input_dir" files durations "$remaining_files"; then
        if [ "$remaining_files" -eq 0 ]; then
            BATCH_LAST_RESULT="no_pending"
            echo -e "${COLOR_YELLOW} NO PENDING FILES:${COLOR_RESET} nothing to process (completion markers left untouched)"
        else
            BATCH_LAST_RESULT="cancelled"
            echo -e "${COLOR_YELLOW} BATCH CANCELLED:${COLOR_RESET} no files were processed, completion markers unchanged"
        fi
        return 0
    fi

    local files_start_time=$(date +%s)
    diag_batch_begin "$input_dir_clean"
    _eta_reset
    local warn_count=0
    local ok_count=0 fail_count=0 skip_count=0
    local pending_total=$remaining_files
    local failed_names=() failed_logs=()
    local relative_path relative_dir out_dir log_dir expected_out log_path
    local process_rc pf_args finished last_line="" last_ok=1
    ENCODE_LAST_STATUS="ok"

    while [ $current_index -lt $total_files ]; do
        input_file="${files[$current_index]}"
        current_index=$((current_index + 1))
        filename=$(basename -- "$input_file")  # Define filename here

        # Skip already processed files (not counted as processed in this batch)
        if is_completed "$input_file"; then
            skip_count=$((skip_count + 1))
            if [ "${was_done[$((current_index - 1))]}" -eq 0 ]; then
                pending_total=$((pending_total - 1))   # completed since the scan
            fi
            continue
        fi

        # Work out the file's subdirectory relative to input_dir, so nested
        # files can be mirrored into matching output/log subfolders
        relative_path="${input_file#"$input_dir_clean"/}"
        relative_dir="$(dirname "$relative_path")"

        # Refuse files whose output name is already claimed by another source
        if [ -n "${collide[$((current_index - 1))]:-}" ]; then
            fail_count=$((fail_count + 1))
            failed_names+=("$relative_path")
            failed_logs+=("(not processed: output name collision)")
            echo ""
            echo -e "${COLOR_RED} SKIPPED (OUTPUT NAME COLLISION):${COLOR_RESET} $relative_path"
            echo -e "${COLOR_YELLOW} SAME OUTPUT NAME AS:${COLOR_RESET} ${collide[$((current_index - 1))]}"
            echo -e "${COLOR_YELLOW} RENAME ONE OF THE TWO FILES; NOTHING WAS OVERWRITTEN${COLOR_RESET}"
            echo ""
            continue
        fi

        finished=$((ok_count + fail_count))
        _eta_batch_compute durations was_done $((current_index - 1)) || true
        # from the second processed file on: wipe the previous file's output (its result stays as one line)
        if [ "$finished" -gt 0 ]; then _batch_clear_screen; fi
        _batch_banner "$current_index" "$total_files" "$finished" "$pending_total" "$fail_count" "$relative_path" "$ETA_L1" "$ETA_L2" "$ETA_L3" "$last_line" "$last_ok"

        pf_args=("$input_file" "$file_log_dir")
        if [ "$relative_dir" != "." ]; then
            pf_args+=("$relative_dir")
        fi

        # "|| rc=$?" keeps "set -e" (convert.sh) from aborting the whole batch
        # when one file fails, so the failure can be reported and the batch continues.
        ENCODE_LAST_STATUS="ok"
        process_rc=0
        process_file "${pf_args[@]}" || process_rc=$?

        # Expected output / log locations (same rules as process_file)
        out_dir="$OUTPUT_DIR"; log_dir="$LOG_DIR"
        if [ "$relative_dir" != "." ]; then
            out_dir="$OUTPUT_DIR/$relative_dir"; log_dir="$LOG_DIR/$relative_dir"
        fi
        expected_out="$out_dir/${filename%.*}.$OUTPUT_FORMAT"
        log_path="$log_dir/${filename%.*}.log"

        # Success only if process_file succeeded, no encode path flagged a failure,
        # and the output file really exists.
        if [ "$process_rc" -eq 0 ] && [ "$ENCODE_LAST_STATUS" = "ok" ] && [ -f "$expected_out" ]; then
            mark_completed "$input_file"
            ok_count=$((ok_count + 1))
            if [ "${DIAG_LAST_HAD_WARNINGS:-0}" = "1" ]; then warn_count=$((warn_count + 1)); fi
            echo ""
            echo -e "${COLOR_GREEN} DONE PROCESSING (${COLOR_RESET}$filename${COLOR_GREEN}) AND MARKED AS COMPLETED${COLOR_RESET}"
            echo ""
            last_ok=1; last_line="Last: OK - $filename"
            if [ "${DIAG_LAST_HAD_WARNINGS:-0}" = "1" ]; then last_line="$last_line (with warnings)"; fi
        else
            fail_count=$((fail_count + 1))
            failed_names+=("$relative_path")
            failed_logs+=("$log_path")
            echo ""
            echo -e "${COLOR_RED} FAILED:${COLOR_RESET} $filename ${COLOR_RED}(NOT MARKED AS COMPLETED)${COLOR_RESET}"
            echo -e "${COLOR_YELLOW} LOG:${COLOR_RESET} $log_path"
            echo ""
            last_ok=0; last_line="Last: FAILED - $filename (see log)"
        fi

        # Add cooldown between files (skip when no pending files remain)
        if [ $((ok_count + fail_count)) -lt "$pending_total" ]; then
            countdown "$COOLDOWN_TIME"
        fi
    done

    processed_files=$ok_count
    local files_end_time=$(date +%s)
    local files_total_time=$((files_end_time - files_start_time))

    echo ""
    local fail_color=""
    if [ "$fail_count" -gt 0 ]; then fail_color="$COLOR_RED"; fi
    _batch_box "BATCH COMPLETE" \
        "Total discovered||$total_files" \
        "Processed|$COLOR_GREEN|$processed_files" \
        "Failed|$fail_color|$fail_count" \
        "Integrity warnings||$warn_count" \
        "Isolated for diagnosis|$fail_color|$DIAG_ISOLATED_COUNT" \
        "Previously done||$skip_count" \
        "Total elapsed||$(format_time "$files_total_time" "compact" || echo "n/a")" \
        "Completed at||$(date +"%I:%M %p")"

    echo -e "${COLOR_YELLOW} LOG FOLDER:${COLOR_RESET} $LOG_DIR"
    if [ "$DIAG_ISOLATED_COUNT" -gt 0 ]; then
        echo -e "${COLOR_YELLOW} DIAGNOSTIC FOLDER:${COLOR_RESET} $DIAG_SESSION_DIR"
    fi
    if [ "$DIAG_ISOLATE_FAIL_COUNT" -gt 0 ]; then
        echo -e "${COLOR_RED} ISOLATION FAILED FOR${COLOR_RESET} $DIAG_ISOLATE_FAIL_COUNT ${COLOR_RED}FILE(S) - THEIR LOGS STAY IN THE LOG FOLDER${COLOR_RESET}"
    fi
    if [ "$fail_count" -gt 0 ]; then
        # Keep a durable failure report next to the per-file logs
        local report="$LOG_DIR/batch_failures_$(date +%Y%m%d_%H%M%S).txt"
        local f
        {
            echo "Batch failures - input: $input_dir"
            for (( f=0; f<${#failed_names[@]}; f++ )); do
                printf '%s\t%s\n' "${failed_names[$f]}" "${failed_logs[$f]}"
            done
        } > "$report" 2>/dev/null || report=""

        echo -e "${COLOR_RED} FAILED FILES:${COLOR_RESET}"
        local shown=0
        for (( f=0; f<${#failed_names[@]}; f++ )); do
            if [ "$shown" -ge "$BATCH_PAGE_SIZE" ]; then break; fi
            echo "  - $(_batch_trunc "${failed_names[$f]}" $(( $(_batch_cols) - 6 )))"
            shown=$((shown + 1))
        done
        if [ "${#failed_names[@]}" -gt "$shown" ]; then
            echo "  ... and $(( ${#failed_names[@]} - shown )) more"
        fi
        if [ -n "$report" ]; then
            echo -e "${COLOR_YELLOW} FAILURE REPORT:${COLOR_RESET} $report"
        fi
        echo -e "${COLOR_YELLOW} COMPLETION MARKERS KEPT${COLOR_RESET} so a rerun resumes only the unfinished files"
        BATCH_LAST_RESULT="failed"
    else
        # Whole batch succeeded: reset completion state exactly as before.
        # Guarded so an empty/invalid COMPLETED_DIR can never expand to "/*".
        if [ -n "$COMPLETED_DIR" ] && [ -d "$COMPLETED_DIR" ]; then
            rm -f "$COMPLETED_DIR"/*
        fi
        BATCH_LAST_RESULT="completed"
    fi
    # Offer the interactive diagnosis only now, after the whole batch has finished
    diag_post_batch_menu || true
    return 0
}

# ===========================================================================
# ENCODE MODULE - PROCESS SINGLE FILE
# ===========================================================================

process_file() {
    local input_file=$(realpath -m "$1")
    local file_log_dir="${2:-$LOG_DIR}"
    local relative_dir="${3:-}"
    local filename=$(basename -- "$input_file")
    local filename_noext="${filename%.*}"
    ENCODE_LAST_STATUS="ok"   # reset per file; encode_* set "failed" on failure paths
    diag_reset_failure

    local output_dir="$OUTPUT_DIR"
    local log_dir="$LOG_DIR"
    if [ -n "$relative_dir" ] && [ "$relative_dir" != "." ]; then
        output_dir="$OUTPUT_DIR/$relative_dir"
        log_dir="$LOG_DIR/$relative_dir"
    fi

    local output_file=$(realpath -m "$output_dir/${filename_noext}.$OUTPUT_FORMAT")
    if [ "$output_file" = "$input_file" ]; then
        echo -e "${COLOR_RED} REFUSING TO ENCODE:${COLOR_RESET} the output path equals the input file (it would be overwritten)"
        echo -e "${COLOR_YELLOW} CHANGE OUTPUT_DIR OR OUTPUT FORMAT${COLOR_RESET}"
        ENCODE_LAST_STATUS="failed"
        return 1
    fi
    mkdir -p "$log_dir"
    local LOG_FILE=$(realpath -m "$log_dir/${filename_noext}.log")
    
    mkdir -p "$(dirname "$output_file")" || {
        echo -e "${COLOR_RED}FAILED TO CREATE OUTPUT DIRECTORY FOR:${COLOR_RESET} $output_file" | tee >(clean_output >> "$LOG_FILE")
        sleep 2
        return 1
    }
    
    > "$LOG_FILE"  # Clear existing log
    
    display_input_info "$input_file" "$LOG_FILE"
    
	local scale_filter scale_info vf_args pix_fmt_arg
	get_scaling_and_filters "$width" "$height" "$input_pix_fmt" \
	    scale_filter scale_info vf_args pix_fmt_arg

    echo "-----------------------------------------------" | tee >(clean_output >> "$LOG_FILE")
    
    local start_time=$(date +%s)
    
    local chunk_thr=$(format_time "$CHUNK_THRESHOLD" "simple")
    local total_chunks=$(calculate_chunk_count "$duration" "$CHUNK_MODE" "$MANUAL_CHUNK_DURATION")
    
    if awk -v d="$duration" -v t="$CHUNK_THRESHOLD" 'BEGIN { exit !(d > t) }'; then
	    if (( total_chunks > 1 )); then
	        echo -e "${COLOR_BLUE} INPUT FILE OVER CHUNKING THRESHOLD:${COLOR_RESET} $chunk_thr" | tee >(clean_output >> "$LOG_FILE")
	        encode_chunk "$input_file" "$output_file" "$duration" "$filename_noext" "${vf_args[@]}"
	    else
	        echo -e "${COLOR_BLUE} INPUT FILE OVER CHUNKING THRESHOLD:${COLOR_RESET} $chunk_thr" | tee >(clean_output >> "$LOG_FILE")
	        echo -e "${COLOR_YELLOW} BUT ONLY${COLOR_RESET} 1 ${COLOR_YELLOW}CHUNK WOULD BE CREATED${COLOR_RESET}" | tee >(clean_output >> "$LOG_FILE")
	        echo -e "${COLOR_YELLOW} SO CONTINUING WITH SINGLE-PASS ENCODING${COLOR_RESET}" | tee >(clean_output >> "$LOG_FILE")
	        echo ""
	        encode_single "$input_file" "$output_file" "$duration" "$filename_noext" "${vf_args[@]}"
	    fi
	else
	    echo -e "${COLOR_BLUE} INPUT FILE UNDER CHUNKING THRESHOLD:${COLOR_RESET} $chunk_thr" | tee >(clean_output >> "$LOG_FILE")
	    echo -e "${COLOR_BLUE} CONTINUING WITH SINGLE-PASS ENCODING${COLOR_RESET}" | tee >(clean_output >> "$LOG_FILE")
	    echo ""
	    encode_single "$input_file" "$output_file" "$duration" "$filename_noext" "${vf_args[@]}"
	fi
    
    if [ $? -ne 0 ]; then
        return 1
    fi
 
    # Major failure: classify it, isolate original + partial output + logs, let the batch go on
    if [ "$ENCODE_LAST_STATUS" = "failed" ]; then
        diag_handle_failure "$input_file" "$output_file" "$LOG_FILE" "$relative_dir" || true
        return 1
    fi

    display_output_info "$output_file" "$LOG_FILE"
    
    local file_end_time=$(date +%s)
    local file_total_time=$((file_end_time - start_time))
    echo -e "${COLOR_BLUE} PROCESSING TIME:${COLOR_RESET} $(format_time "$file_total_time" "hms") ${COLOR_BLUE}COMPLETED AT:${COLOR_RESET} $(date +"%I:%M %p")" | tee >(clean_output >> "$LOG_FILE")
    
    sleep 1
    return 0
}

# ===========================================================================
# ENCODE MODULE - FFMPEG DIAGNOSTICS
# ===========================================================================
# ffmpeg stderr is captured to a per-encode temp file so it cannot garble the
# progress bar. This helper makes sure that file is never thrown away unread:
# it is always appended to $LOG_FILE (when it has content or ffmpeg exited
# non-zero), and optionally echoed to the screen.
#   _flush_ffmpeg_log LABEL LOGFILE [SHOW=0|1] [EXIT_CODE=0]
_flush_ffmpeg_log() {
    local label="$1" log="$2" show="${3:-0}" rc="${4:-0}"
    local has_log=0 lines=0 msg
    if [ -n "$log" ] && [ -s "$log" ]; then
        has_log=1
        # count only lines that look like warnings/errors (chunk logs also hold plain info lines)
        lines=$(grep -aEic 'error|warn|invalid|corrupt|fail|missing|non-monoton|truncat|overread|conceal|discard|unable|cannot' "$log" 2>/dev/null) || lines=0
    fi
    if [ "$has_log" -eq 0 ] && [ "$rc" = "0" ]; then
        return 0    # nothing to report
    fi

    msg="----- ffmpeg diagnostics: $label (exit code: $rc) -----"
    if [ "$has_log" -eq 1 ]; then
        msg+=$'\n'"$(cat "$log")"
    else
        msg+=$'\n'"(ffmpeg produced no stderr output)"
    fi
    msg+=$'\n'"----- end ffmpeg diagnostics -----"

    if [ -n "${LOG_FILE:-}" ]; then
        if declare -F clean_output >/dev/null 2>&1; then
            printf '%s\n' "$msg" | clean_output >> "$LOG_FILE"
        else
            printf '%s\n' "$msg" >> "$LOG_FILE"
        fi
    fi

    if [ "$show" = "1" ]; then
        printf '%s\n' "$msg"
    elif [ "${lines:-0}" -gt 0 ]; then
        DIAG_LAST_HAD_WARNINGS=1
        echo -e "${COLOR_YELLOW} FFMPEG REPORTED${COLOR_RESET} $lines ${COLOR_YELLOW}WARNING LINE(S) - SAVED TO LOG${COLOR_RESET}"
    fi
    return 0
}

# ===========================================================================
# ENCODE MODULE - SINGLE PASS ENCODING
# ===========================================================================

encode_single() {
    local input_file="$1"
    local output_file="$2"
    local duration="$3"
    local filename_noext="$4"
    shift 4
    local vf_args=("$@")

    local RESILIENCE_INPUT_FLAGS=(
        -fflags +discardcorrupt+genpts+igndts+ignidx
        -max_error_rate 1.0
        -analyzeduration 100M
        -probesize 10M
        -err_detect ignore_err
        )
    
    local RESILIENCE_OUTPUT_FLAGS=(
        -max_muxing_queue_size 1024
        -avoid_negative_ts make_zero
        )

    local ffmpeg_log="${output_file}.fflog"
    local bitrate_args=()
    if [ "$BITRATE_LIMITS_ENABLED" -eq 1 ]; then
        bitrate_args=(-maxrate "$MAXRATE" -bufsize "$BUFSIZE")
    fi

    # ---------- SINGLE ARRAY for codec‑specific flags ----------
    local codec_args=()
    case "$VIDEO_CODEC" in
        libx264)
            codec_args=(-threads "$CPU_THREADS")
            ;;
        libx265)
            codec_args=(-x265-params "pools=$CPU_THREADS")
            # optionally add: :no-sao=1:no-deblock=1
            ;;
        libsvtav1)
            # SVT‑AV1: we use -svtav1-params; -threads is ignored, so we omit it
            codec_args=(-svtav1-params lp=$CPU_THREADS)
            ;;
        libvpx | libvpx-vp9)
            codec_args=(-threads "$CPU_THREADS" -tile-columns 0 -row-mt 0 -cpu-used 5)
            ;;
        *)
            codec_args=(-threads "$CPU_THREADS")
            ;;
    esac
    # ------------------------------------------------------------

    if [ -n "$pix_fmt_arg" ]; then
        pix_fmt_option=(-pix_fmt "$pix_fmt_arg")
    else
        pix_fmt_option=()
    fi
    
    local single_start_time=$(date +%s)      
    
    # convert.sh runs with "set -e -o pipefail". A failing ffmpeg would abort the script right
    # here (before its log is saved) unless the pipeline has a "||" branch. That branch runs
    # first after the pipeline, so PIPESTATUS still describes the pipeline at that point.
    local ff_rc=0
    DIAG_CURRENT_RAW_LOG="$ffmpeg_log"
    DIAG_ENCODE_MODE="single"
    _probe_fps_args "$input_file"
    if [ -n "$FPS_NOTE" ]; then
        echo -e "${COLOR_BLUE} FRAME RATE:${COLOR_RESET} $FPS_NOTE" | tee >(clean_output >> "$LOG_FILE")
    fi
    ffmpeg -nostdin -hide_banner -loglevel warning -y \
        "${RESILIENCE_INPUT_FLAGS[@]}" -i "$input_file" -map 0:v -map "0:a?" "${vf_args[@]}" \
        "${FPS_ARGS[@]}" "${RESILIENCE_OUTPUT_FLAGS[@]}" \
        -c:v "$VIDEO_CODEC" "${codec_args[@]}" -crf "$CRF" "${bitrate_args[@]}" -preset "$PRESET" \
        "${pix_fmt_option[@]}" \
        -c:a "$AUDIO_CODEC" -b:a "${AUDIO_BITRATE}k" -ar 48000 \
        -progress pipe:1 -nostats "$output_file" 2>"$ffmpeg_log" | \
        display_progress "single" "$duration" "$BAR_STYLE" || ff_rc="${PIPESTATUS[0]}"
    
    if [ ! -f "$output_file" ]; then
        echo -e "${COLOR_RED} OUTPUT FILE NOT CREATED${COLOR_RESET}" | tee >(clean_output >> "$LOG_FILE")
        
        sleep 2
        _flush_ffmpeg_log "$(basename -- "$input_file")" "$ffmpeg_log" 1 "$ff_rc"
        diag_note_failure OUTPUT_MISSING "output file was not created" "$ffmpeg_log" "$ff_rc"
        rm -f "$ffmpeg_log"
        DIAG_CURRENT_RAW_LOG=""
        ENCODE_LAST_STATUS="failed"   # batch UI: report as failed (return code unchanged)
        return 0
    fi
    # Output exists: still keep warnings / a non-zero exit (e.g. partial output) in the log.
    # Show on screen only when ffmpeg actually exited with an error.
    if [ "$ff_rc" != "0" ]; then
        echo -e "${COLOR_YELLOW} FFMPEG EXITED WITH CODE${COLOR_RESET} $ff_rc ${COLOR_YELLOW}BUT AN OUTPUT FILE EXISTS${COLOR_RESET}" | tee >(clean_output >> "$LOG_FILE")
        _flush_ffmpeg_log "$(basename -- "$input_file")" "$ffmpeg_log" 1 "$ff_rc"
    else
        _flush_ffmpeg_log "$(basename -- "$input_file")" "$ffmpeg_log" 0 "$ff_rc"
    fi
    # (the raw log is kept until the integrity check below has passed)

    local single_end_time=$(date +%s)
    local single_total_time=$((single_end_time - single_start_time))
    echo -e "${COLOR_BLUE} ENCODING TOOK:${COLOR_RESET} $(format_time "$single_total_time" "hms")" | tee >(clean_output >> "$LOG_FILE")
    echo ""
    sleep 1
    
    if ! check_video_integrity "$output_file" "$duration" "$input_file"; then
    actual_duration=$(ffprobe -v error -show_entries format=duration \
        -of default=noprint_wrappers=1:nokey=1 "$output_file" | awk '{ printf "%.3f", $0 }')

    expected_duration=$(awk -v d="$duration" 'BEGIN { printf "%.3f", d }')
    actual_human=$(format_time "$actual_duration" "compact")
    expected_human=$(format_time "$expected_duration" "compact")

    echo -e "${COLOR_RED} FAILED INTEGRITY CHECK${COLOR_RESET}" | tee -a "$LOG_FILE"

    diff=$(awk -v a="$actual_duration" -v e="$expected_duration" 'BEGIN { d = (a > e) ? (a - e) : (e - a); printf "%.3f", d }')
    formatted_diff=$(format_time "$diff" "dynamic")

    awk -v ah="$actual_human" -v eh="$expected_human" -v fd="$formatted_diff" '
    BEGIN {
        printf " DURATION MISMATCH — %s vs %s\n", ah, eh
        printf " DIFFERENCE: %s\n", fd
    }' | tee -a "$LOG_FILE"

    echo -e "${COLOR_RED} OUTPUT MAY BE CORRUPTED OR INCOMPLETE:${COLOR_RESET} $output_file" | tee >(clean_output >> "$LOG_FILE")
    diag_note_failure "$(diag_context_from_integrity)" "integrity check failed: ${INTEGRITY_DETAIL:-unknown}" "$ffmpeg_log" "$ff_rc" "$output_file"
    rm -f "$ffmpeg_log"
    DIAG_CURRENT_RAW_LOG=""
    ENCODE_LAST_STATUS="failed"   # batch UI: report as failed (return code unchanged)
    sleep 2
    return 0
	else
    echo -e "${COLOR_GREEN} PASSED INTEGRITY CHECK${COLOR_RESET}" | tee >(clean_output >> "$LOG_FILE")
    if [ "$ff_rc" != "0" ]; then DIAG_LAST_HAD_WARNINGS=1; fi   # exit code was non-zero but the output verified
    rm -f "$ffmpeg_log"
    DIAG_CURRENT_RAW_LOG=""
    _eta_record "$duration" "$single_total_time"
    sleep 1
	fi

    return 0
}

# ===========================================================================
# ENCODE MODULE - CHUNKED ENCODING
# ===========================================================================

encode_chunk() {
    local input_file="$1"
    local output_file="$2"
    local duration="$3"
    local filename_noext="$4"
    shift 4
    local vf_args=("$@")

    DIAG_ENCODE_MODE="chunked"
    local total_chunks=$(calculate_chunk_count "$duration" "$CHUNK_MODE" "$MANUAL_CHUNK_DURATION")
    local chunk_duration=$(awk -v d="$duration" -v c="$total_chunks" 'BEGIN { printf "%.3f", d / c }')
    local human_chunk_hms=$(format_time "$chunk_duration")
    
    # Check for existing resume directory: exactly chunks_<this name>_<digits>.
    # (A glob pattern here also matched other files' folders, e.g. "show" vs "show_2".)
    local i RESUME_DIR="" _cand
    while IFS= read -r -d '' _cand; do
        if _is_chunk_dir_of "$_cand" "$filename_noext"; then RESUME_DIR="$_cand"; break; fi
    done < <(find "$(dirname -- "$input_file")" -maxdepth 1 -type d -name 'chunks_*' -print0 | sort -z)
    
    echo -e "${COLOR_BLUE} SPLITTING INTO${COLOR_RESET} $total_chunks ${COLOR_BLUE}CHUNKS OF${COLOR_RESET} $human_chunk_hms ${COLOR_BLUE}EACH${COLOR_RESET}" | tee >(clean_output >> "$LOG_FILE")
    
    # RESUME PROCESSING 
    if [ -n "$RESUME_DIR" ]; then
        CHUNK_DIR="$RESUME_DIR"
        local resume_dirname="${CHUNK_DIR#/storage/emulated/0/}"
        echo ""
        echo -e "${COLOR_ORANGE} PREVIOUS PROGRESS DETECTED:${COLOR_RESET}" | tee >(clean_output >> "$LOG_FILE")
        echo " $resume_dirname" | tee -a "$LOG_FILE"
        echo ""
        sleep 1
        # Verify chunk sequence and duration
        local valid_chunks=()
        local missing_chunks=()
        
        for (( i=1; i<=$total_chunks; i++ )); do
            local chunk_file="$CHUNK_DIR/${filename_noext}_chunk_${i}.$OUTPUT_FORMAT"
            
            if [[ -f "$chunk_file" ]]; then
                local chunk_dur=$(ffprobe -v error -show_entries format=duration \
                    -of default=noprint_wrappers=1:nokey=1 "$chunk_file" 2>/dev/null | awk '{printf "%.3f", $0}')
                
                local expected_dur=$(awk -v d="$duration" -v c="$total_chunks" \
                    -v i="$((i-1))" 'BEGIN {
                        if (i < c-1) printf "%.3f", d/c;
                        else printf "%.3f", d - (i * (d/c))
                    }')
                
                local tolerance="0.300"
                local min_dur=$(awk -v e="$expected_dur" -v t="$tolerance" 'BEGIN {printf "%.3f", e - t}')
                
                if [ -n "$chunk_dur" ] && awk -v a="$chunk_dur" -v b="$min_dur" 'BEGIN { exit !(a >= b) }'; then
                    valid_chunks+=("$chunk_file")
                    echo -e "${COLOR_GREEN} CHUNK${COLOR_RESET} $i ${COLOR_GREEN}VALID${COLOR_RESET} ($(format_time "$chunk_dur"))" | tee >(clean_output >> "$LOG_FILE")
                    sleep 0.5
                else
                    echo -e "${COLOR_YELLOW} CHUNK${COLOR_RESET} $i ${COLOR_YELLOW}INCOMPLETE${COLOR_RESET} ($(format_time "$chunk_dur"))" | tee >(clean_output >> "$LOG_FILE")
                    sleep 0.5
                    rm -f "$chunk_file"
                    missing_chunks+=("$i")
                fi
            else
                echo -e "${COLOR_RED} CHUNK${COLOR_RESET} $i ${COLOR_RED}MISSING${COLOR_RESET}" | tee >(clean_output >> "$LOG_FILE")
                sleep 0.5
                missing_chunks+=("$i")
            fi
        done
        converted_chunks=("${valid_chunks[@]}")
    else
        # NEW ENCODING PROCESS
        CHUNK_DIR="$(dirname "$input_file")/chunks_${filename_noext}_$$"
        mkdir -p "$CHUNK_DIR" || {
            echo ""
        	echo -e "${COLOR_RED} FAILED TO CREATE TEMP DIRECTORY:${COLOR_RESET} $CHUNK_DIR" | tee >(clean_output >> "$LOG_FILE")
            sleep 2
            return 1
        }
        converted_chunks=()
        missing_chunks=($(seq 1 $total_chunks))
    fi
    
    declare -g chunk_dir="$CHUNK_DIR"
    local start_time=$(date +%s)
    
    # Process all chunks needed (missing chunks for resume, all chunks for new)
    for chunk_num in "${missing_chunks[@]}"; do
        local chunk_index=$((chunk_num-1))
        chunk_start_time=$(date +%s)
        
        local start_sec=$(awk -v chunk_index="$chunk_index" -v cdt="$chunk_duration" 'BEGIN { printf "%.3f", chunk_index * cdt }')
        local end_sec=$(awk -v chunk_index="$chunk_index" -v cdt="$chunk_duration" \
            -v tc="$total_chunks" -v dur="$duration" 'BEGIN {
            if (chunk_index < tc - 1) printf "%.3f", (chunk_index + 1) * cdt;
            else printf "%.3f", dur
        }')

        local start_ts=$(format_time "$start_sec" "full")
        local end_ts=$(format_time "$end_sec" "full")
        local precise_duration=$(awk -v e="$end_sec" -v s="$start_sec" 'BEGIN { printf "%.3f", e - s }')
        
        echo ""
        echo -e "${COLOR_BLUE} CHUNK${COLOR_RESET} $chunk_num${COLOR_BLUE}:${COLOR_RESET} $start_ts — $end_ts" | tee >(clean_output >> "$LOG_FILE")

        local chunk_out="$CHUNK_DIR/${filename_noext}_chunk_${chunk_num}.$OUTPUT_FORMAT"
        local ffmpeg_log="$CHUNK_DIR/ffmpeg_chunk_${chunk_num}.log"
        
        if ! encode_single_chunk "$input_file" "$start_ts" "$end_ts" "$precise_duration" \
             "$chunk_out" "$chunk_num" "$total_chunks" "$(( (chunk_num-1) * 100 / total_chunks ))" "$ffmpeg_log" "${vf_args[@]}"; then
            echo -e "${COLOR_RED} CHUNK${COLOR_RESET} $chunk_num ${COLOR_RED}FAILED${COLOR_RESET}" | tee >(clean_output >> "$LOG_FILE")
            _flush_ffmpeg_log "chunk $chunk_num" "$ffmpeg_log" 1 "${ENCODE_LAST_FFMPEG_RC:-?}"
            ENCODE_LAST_STATUS="failed"
            return 0
        fi
        
        if [ ! -f "$chunk_out" ]; then
            echo -e "${COLOR_RED} CHUNK${COLOR_RESET} $chunk_num ${COLOR_RED}FAILED TO CREATE OUTPUT${COLOR_RESET}" | tee >(clean_output >> "$LOG_FILE")
            _flush_ffmpeg_log "chunk $chunk_num" "$ffmpeg_log" 1 "${ENCODE_LAST_FFMPEG_RC:-?}"
            ENCODE_LAST_STATUS="failed"
            return 0
        fi
        
        local chunk_end_time=$(date +%s)
        local chunk_time=$((chunk_end_time - chunk_start_time))
        echo -e " ${COLOR_BLUE}ENCODING TOOK:${COLOR_RESET} $(format_time "$chunk_time" "hms")" | tee >(clean_output >> "$LOG_FILE")
        _eta_record "$precise_duration" "$chunk_time"
        if [ "$chunk_num" -lt "$total_chunks" ]; then
            _eta_file_line "$precise_duration" $((total_chunks - chunk_num))
        fi
        echo ""
        
        # NOTE: separate variable. This used to overwrite $chunk_duration (the nominal chunk
        # length used to compute every later start/end), so each chunk started a few
        # milliseconds off and frames were dropped at the joins.
        local chunk_probe_dur
        chunk_probe_dur=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$chunk_out" 2>/dev/null </dev/null | head -n1) || chunk_probe_dur=""
        
        size_kb=$(du -k "$chunk_out" 2>/dev/null | awk '{print $1}')
        if [[ -n "$size_kb" && "$size_kb" -gt 0 ]]; then
            size_bytes=$((size_kb * 1024))
        else
            size_bytes=$(stat -c%s "$chunk_out" 2>/dev/null || echo 0)
        fi
        size_human=$(format_size "$size_bytes")
        
        bitrate=$(ffprobe -v error -show_entries format=bit_rate -of default=noprint_wrappers=1:nokey=1 "$chunk_out" 2>/dev/null </dev/null | head -n1) || bitrate=0
        bitrate=$(_probe_int "$bitrate")
        bitrate_kbps=$((bitrate / 1000))
        local chunk_filename=$(basename -- "$chunk_out")
        
        echo -e " ${COLOR_BLUE}CHUNK${COLOR_RESET} $chunk_num ${COLOR_BLUE}INFO:${COLOR_RESET} " | tee >(clean_output >> "$LOG_FILE")
        echo -e "   ${COLOR_BLUE}FILE NAME:${COLOR_RESET} $chunk_filename" | tee >(clean_output >> "$LOG_FILE")
        echo -e "   ${COLOR_BLUE}DURATION:${COLOR_RESET} $(format_time "$chunk_probe_dur" "full")" | tee >(clean_output >> "$LOG_FILE")
        echo -e "   ${COLOR_BLUE}SIZE:${COLOR_RESET} $size_human" | tee >(clean_output >> "$LOG_FILE")
        echo -e "   ${COLOR_BLUE}BITRATE:${COLOR_RESET} ${bitrate_kbps} kbps" | tee >(clean_output >> "$LOG_FILE")
        echo ""
        
        converted_chunks+=("$chunk_out")
        # Keep warnings in the main log; show on screen only on a non-zero ffmpeg exit
        if [ "${ENCODE_LAST_FFMPEG_RC:-0}" != "0" ]; then
            _flush_ffmpeg_log "chunk $chunk_num" "$ffmpeg_log" 1 "$ENCODE_LAST_FFMPEG_RC"
        else
            _flush_ffmpeg_log "chunk $chunk_num" "$ffmpeg_log" 0 0
        fi
        rm -f "$ffmpeg_log"
        
        [[ $chunk_num -lt $total_chunks ]] && countdown $COOLDOWN_TIME
    done
    echo "-----------------------------------------------" | tee >(clean_output >> "$LOG_FILE")
    sleep 1

    # Rebuild the list strictly in chunk order. On a resume the already-valid chunks
    # were listed first and newly encoded ones appended, so a gap in the middle
    # (e.g. chunk 2 redone, chunk 3 kept) merged the scenes out of order.
    converted_chunks=()
    for (( i=1; i<=total_chunks; i++ )); do
        if [ -f "$CHUNK_DIR/${filename_noext}_chunk_${i}.$OUTPUT_FORMAT" ]; then
            converted_chunks+=("$CHUNK_DIR/${filename_noext}_chunk_${i}.$OUTPUT_FORMAT")
        fi
    done

    # merge_chunks always returns 0 and signals failure through ENCODE_LAST_STATUS, so check
    # both; otherwise the chunks (and their ffmpeg logs) would be deleted after a failed merge.
    if merge_chunks "$CHUNK_DIR" "$output_file" "$total_chunks" "$filename_noext" "$duration" "${converted_chunks[@]}" \
       && [ "$ENCODE_LAST_STATUS" != "failed" ]; then
        if [ -n "$RESUME_DIR" ]; then
            rm -rf "$RESUME_DIR"
        fi
        rm -rf "$CHUNK_DIR"
        unset chunk_dir
        return 0
    else
        echo -e "${COLOR_RED} CHUNK MERGE FAILED - PRESERVING CHUNKS IN:${COLOR_RESET} $CHUNK_DIR" | tee >(clean_output >> "$LOG_FILE")
        ENCODE_LAST_STATUS="failed"
        return 0
    fi
}

encode_single_chunk() {
    local input_file="$1"
    local start_ts="$2"
    local end_ts="$3"
    local chunk_duration_seg="$4"
    local chunk_out="$5"
    local chunk_num="$6"
    local total_chunks="$7"
    local progress_pct="$8"
    local ffmpeg_log="$9"
    shift 9
    DIAG_CURRENT_RAW_LOG="$ffmpeg_log"
    local vf_args=("$@")
    
    local RESILIENCE_INPUT_FLAGS=(
        -fflags +discardcorrupt+genpts+igndts+ignidx
        -max_error_rate 1.0
        -analyzeduration 100M
        -probesize 10M
        -err_detect ignore_err
        )
    
    local RESILIENCE_OUTPUT_FLAGS=(
        -max_muxing_queue_size 1024
        -avoid_negative_ts make_zero
        )
        
    local bitrate_args=()
    if [ "$BITRATE_LIMITS_ENABLED" -eq 1 ]; then
        bitrate_args=(-maxrate "$MAXRATE" -bufsize "$BUFSIZE")
    fi

    # ---------- SINGLE ARRAY (same as above) ----------
    local codec_args=()
    case "$VIDEO_CODEC" in
        libx264)
            codec_args=(-threads "$CPU_THREADS")
            ;;
        libx265)
            codec_args=(-x265-params "pools=$CPU_THREADS")
            ;;
        libsvtav1)
            codec_args=(-svtav1-params "pred-struct=2:aq-mode=2:lp=$CPU_THREADS")
            ;;
        libvpx | libvpx-vp9)
            codec_args=(-threads "$CPU_THREADS" -tile-columns 0 -row-mt 0 -cpu-used 5)
            ;;
        *)
            codec_args=(-threads "$CPU_THREADS")
            ;;
    esac
    # --------------------------------------------------

    if [ -n "$pix_fmt_arg" ]; then
        pix_fmt_option=(-pix_fmt "$pix_fmt_arg")
    else
        pix_fmt_option=()
    fi

    _probe_fps_args "$input_file"
    ffmpeg -nostdin -hide_banner -y "${RESILIENCE_INPUT_FLAGS[@]}" \
        -ss "$start_ts" -to "$end_ts" -i "$input_file" -map 0:v -map "0:a?" "${vf_args[@]}" \
        "${FPS_ARGS[@]}" "${RESILIENCE_OUTPUT_FLAGS[@]}" \
        -c:v "$VIDEO_CODEC" "${codec_args[@]}" -crf "$CRF" "${bitrate_args[@]}" -preset "$PRESET" \
        "${pix_fmt_option[@]}" \
        -c:a "$AUDIO_CODEC" -b:a "${AUDIO_BITRATE}k" -ar 48000 \
        -fflags +genpts -avoid_negative_ts make_zero \
        -progress pipe:1 -nostats "$chunk_out" 2>"$ffmpeg_log" | \
        display_progress "chunked" "$chunk_duration_seg" "$chunk_num" "$total_chunks" "$progress_pct" "$BAR_STYLE" \
        || {
            # Pipeline failed (pipefail): record ffmpeg's exit code and keep the original
            # return value (rightmost non-zero status), so callers behave exactly as before.
            local _ps=("${PIPESTATUS[@]}")
            ENCODE_LAST_FFMPEG_RC="${_ps[0]}"
            if [ "${_ps[1]:-0}" -ne 0 ]; then return "${_ps[1]}"; fi
            return "${_ps[0]}"
        }
    ENCODE_LAST_FFMPEG_RC=0
    return 0
}

# ===========================================================================
# ENCODE MODULE - MERGE VIDEO CHUNKS
# ===========================================================================

merge_chunks() {
    local CHUNK_DIR="$1"
    local chunkdir_name="${CHUNK_DIR#/storage/emulated/0/}"
    local output_file="$2"
    local total_chunks="$3"
    local filename_noext="$4"
    local duration="$5"
    shift 5  # Now $@ contains only chunk paths
    local converted_chunks=()
    for f in "$@"; do
        [ -f "$f" ] && converted_chunks+=("$f")
    done

    echo -e "${COLOR_BLUE} MERGING ${COLOR_RESET}$total_chunks ${COLOR_BLUE}CHUNKS INTO FINAL OUTPUT...${COLOR_RESET}" | tee >(clean_output >> "$LOG_FILE")
    echo ""
    sleep 1

    # Verify we have all chunks
    local actual_chunks=${#converted_chunks[@]}
    if [ "$actual_chunks" -ne "$total_chunks" ]; then
        local missing_chunks=$((total_chunks - actual_chunks))
        echo -e "${COLOR_RED} MISSING CHUNKS:${COLOR_RESET} $missing_chunks (${COLOR_GREEN}FOUND:${COLOR_RESET} $actual_chunks / $total_chunks)" | tee >(clean_output >> "$LOG_FILE")
        sleep 1
        echo -e "${COLOR_YELLOW} COMMENCING RECOVERY AFTER COOLDOWN${COLOR_RESET}" | tee >(clean_output >> "$LOG_FILE")
        countdown "$COOLDOWN_TIME"
        encode_chunk "$input_file" "$output_file" "$duration" "$filename_noext" "${vf_args[@]}"
        return 0
    fi

    temp_output="${output_file%.*}_temp.${output_file##*.}"
    local merge_success=0
    
    # Try mkvmerge first (if available)
    if [ "$OUTPUT_FORMAT" = "mkv" ] && command -v mkvmerge >/dev/null 2>&1; then
        echo -e "${COLOR_BLUE} ATTEMPTING MERGE WITH MKVMERGE...${COLOR_RESET}" | tee >(clean_output >> "$LOG_FILE")
        echo ""
        # Build mkvmerge command with proper concatenation syntax
        # First file is normal, subsequent files are prefixed with +
        mkvmerge_cmd=(-o "$temp_output")
        for ((i=0; i<${#converted_chunks[@]}; i++)); do
            if [ $i -eq 0 ]; then
                mkvmerge_cmd+=("${converted_chunks[$i]}")
            else
                mkvmerge_cmd+=("+${converted_chunks[$i]}")
            fi
        done
        
        if mkvmerge "${mkvmerge_cmd[@]}" >>"$LOG_FILE" 2>&1; then
            merge_success=1
        else
        echo -e "${COLOR_RED} MERGE WITH MKVMERGE FAILED${COLOR_RESET}" | tee >(clean_output >> "$LOG_FILE")
        echo ""
            merge_success=0
        fi
    fi
    
    # If mkvmerge not available or failed, try ffmpeg methods
    if [ "$merge_success" -ne 1 ]; then
        local concat_file="$CHUNK_DIR/concat_list.txt"
        > "$concat_file"
        for f in "${converted_chunks[@]}"; do
            # ffmpeg concat syntax: a literal ' inside 'quotes' is written as '\''
            [ -f "$f" ] && printf "file '%s'\n" "${f//\'/\'\\\'\'}" >> "$concat_file"
        done
        
        echo -e "${COLOR_BLUE} ATTEMPTING MERGE WITH FFMPEG CONCAT...${COLOR_RESET}" | tee >(clean_output >> "$LOG_FILE")
        echo ""
        # First try simple copy
        if ffmpeg -nostdin -hide_banner -loglevel warning -y -f concat -safe 0 -i "$concat_file" \
             -c copy -movflags +faststart "$temp_output" 2>>"$LOG_FILE"; then
            merge_success=1
        else
            # Fallback: re-encode audio if needed
            echo -e "${COLOR_YELLOW} SIMPLE COPY FAILED, TRYING AUDIO RE-ENCODE...${COLOR_RESET}" | tee >(clean_output >> "$LOG_FILE")
            echo ""
            if ffmpeg -nostdin -hide_banner -loglevel warning -y -f concat -safe 0 -i "$concat_file" \
                 -c:v copy -c:a libopus -b:a "${AUDIO_BITRATE}k" -movflags +faststart "$temp_output" 2>>"$LOG_FILE"; then
                merge_success=1
            else
                merge_success=0
            fi
        fi
    fi
        
    if [ "$merge_success" -eq 1 ]; then
        echo -e "${COLOR_GREEN} MERGING SUCCESSFUL${COLOR_RESET}" | tee >(clean_output >> "$LOG_FILE")
        echo ""
        sleep 1

        if check_video_integrity "$temp_output" "$duration" "${input_file:-}"; then
            echo -e "${COLOR_GREEN} PASSED INTEGRITY CHECK${COLOR_RESET}" | tee >(clean_output >> "$LOG_FILE")
            echo ""
            mv "$temp_output" "$output_file"
            merge_success=1    
        else
            echo -e "${COLOR_RED} FAILED INTEGRITY CHECK${COLOR_RESET}" | tee >(clean_output >> "$LOG_FILE")
            echo ""
            actual_duration=$(ffprobe -v error -show_entries format=duration \
                -of default=noprint_wrappers=1:nokey=1 "$temp_output" | awk '{ printf "%.3f", $0 }')
            expected_duration=$(awk -v d="$duration" 'BEGIN { printf "%.3f", d }')
            actual_human=$(format_time "$actual_duration")
            expected_human=$(format_time "$expected_duration")
            
            diff=$(awk -v a="$actual_duration" -v e="$expected_duration" 'BEGIN { d = (a > e) ? (a - e) : (e - a); printf "%.3f", d }')
            formatted_diff=$(format_time "$diff" "dynamic")

            awk -v ah="$actual_human" -v eh="$expected_human" -v fd="$formatted_diff" '
            BEGIN {
                printf " DURATION MISMATCH — %s vs %s\n", ah, eh
                printf " DIFFERENCE: %s\n", fd
            }' | tee -a "$LOG_FILE"
            echo ""

            # Keep the incomplete output for diagnosis and report the file as FAILED
            # (previously this was silently accepted as a success).
            mv "$temp_output" "$output_file"
            diag_note_failure "$(diag_context_from_integrity)" "merged output failed integrity: ${INTEGRITY_DETAIL:-unknown}" "" "" "$output_file" "$CHUNK_DIR"
            merge_success=0
        fi
    else
        echo -e "${COLOR_RED} MERGING FAILED${COLOR_RESET}" | tee >(clean_output >> "$LOG_FILE")
        echo ""
        diag_note_failure MERGE_FAILURE "merging the chunks failed (mkvmerge / ffmpeg concat)" "" "" "" "$CHUNK_DIR"
        merge_success=0
    fi

    # Cleanup only temp file
    [ -f "$temp_output" ] && rm -f "$temp_output"

    if [ "$merge_success" -eq 1 ]; then
        echo -e "${COLOR_YELLOW} CLEANING UP CHUNK DIRECTORY:${COLOR_RESET}" | tee >(clean_output >> "$LOG_FILE")
        echo " $chunkdir_name" | tee >(clean_output >> "$LOG_FILE")
        return 0
    else
        echo -e "${COLOR_YELLOW} CHUNK DIRECTORY PRESERVED FOR DEBUGGING:${COLOR_RESET}" | tee >(clean_output >> "$LOG_FILE")
        echo " $chunkdir_name" | tee >(clean_output >> "$LOG_FILE")
        ENCODE_LAST_STATUS="failed"
        return 0
    fi
}