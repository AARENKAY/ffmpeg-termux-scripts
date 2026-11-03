#!/bin/bash

# ==================== LOADING GUARD ====================
if [[ -n "${_LIB_UI_KIT_LOADED+x}" ]]; then
    return 0  # Already loaded, skip
fi
readonly _LIB_UI_KIT_LOADED=true  # Mark as loaded
# ==================================================

# ===========================================================================
# UI KIT - shared look & feel for every screen
# ---------------------------------------------------------------------------
# One visual language (rounded boxes, [key] chips, dotted rows, status marks)
# that adapts to the terminal width (phone portrait ~40 cols up to 58 cols).
#
# Screens:   ui_header TITLE [SUBLINE...]      boxed screen title
#            ui_section LABEL                  "─ LABEL ─────" divider
#            ui_row KEY LABEL VALUE [TONE] [EXTRA]
#                                              "[1] Label ···· value  extra"
#                                              TONE: on | off | warn | (empty)
#            ui_actions "key|label|color" ...  footer shortcuts, wraps to width
#            ui_card TITLE "label|color|value" ...   fixed-width info card
# Sub-menus: ui_submenu_title TITLE [DESC]     section title + wrapped description
#            ui_opt N TEXT [CURRENT THIS]      option; ● when CURRENT == THIS
#            ui_hint TEXT                      dim helper line
#            ui_prompt TEXT                    used as: read -r -p "$(ui_prompt "...")" v
#            ui_confirm TEXT [Y|N]             yes/no question (returns 0 = yes)
# Messages:  ui_ok / ui_warn / ui_err / ui_note   (one argument each)
#            ui_pause [SECONDS]
# Helpers:   ui_cpu_zone, ui_temp_color
#
# Gotchas this file respects (convert.sh runs with set -euo pipefail and
# IFS=$'\n\t'): every variable is defaulted, "$*" is never used, word
# splitting is done with read -a, and no function ends on a bare "A && B".
#
# Dependencies: _batch_ui_init / _batch_cols / _ui_trunc / _batch_rep from
# lib-encode.sh. Falls back to ASCII glyphs automatically (BATCH_UI_ASCII=1).
# ===========================================================================

declare -g UI_W=0                           # current screen width (set by ui_refresh)
declare -g UI_MAX_W="${UI_MAX_W:-58}"       # never wider than this
declare -g UI_LABEL_W=17
declare -g UI_LAST_INPUT_BYTES=0            # set by display_input_info, read by display_output_info

# ---- palette (real ESC bytes, print with %s) -----------------------------
declare -g UI_RST=$'\033[0m'
declare -g UI_BOLD=$'\033[1m'
declare -g UI_DIM=$'\033[2m'
declare -g UI_ACC=$'\033[1;38;5;39m'     # accent / borders
declare -g UI_HEAD=$'\033[1;38;5;208m'   # titles and section labels
declare -g UI_KEY=$'\033[1;38;5;226m'    # [key] chips
declare -g UI_OK=$'\033[1;38;5;82m'
declare -g UI_WARNC=$'\033[1;38;5;226m'
declare -g UI_ERRC=$'\033[1;38;5;196m'
declare -g UI_PATH=$'\033[38;5;6m'

# ---- glyphs ---------------------------------------------------------------
ui_glyphs() {
    _batch_ui_init
    if [ "$BATCH_H" = "─" ]; then
        UI_BUL='▸'; UI_ON='●'; UI_PLAY='▶'; UI_CHK='✔'; UI_WRN='▲'; UI_X='✖'
        UI_NOTE='•'; UI_LEAD='·'; UI_MORE='▾'; UI_SEP='·'
    else
        UI_BUL='>'; UI_ON='*'; UI_PLAY='>'; UI_CHK='+'; UI_WRN='!'; UI_X='x'
        UI_NOTE='-'; UI_LEAD='.'; UI_MORE='v'; UI_SEP='|'
    fi
}

# Measure the terminal once per screen and derive the layout.
ui_refresh() {
    local c
    ui_glyphs
    c=$(_batch_cols)
    UI_W=$UI_MAX_W
    if [ "$c" -le "$UI_W" ]; then UI_W=$((c - 1)); fi
    if [ "$UI_W" -lt 30 ]; then UI_W=30; fi
    if [ "$UI_W" -ge 50 ]; then UI_LABEL_W=17; else UI_LABEL_W=15; fi
}

_ui_ready() {
    if [ "${UI_W:-0}" -le 0 ] || [ -z "${UI_BUL:-}" ]; then ui_refresh; fi
}

# Truncate keeping the START of the text (the batch helper _batch_trunc keeps the tail, which
# is right for paths but not for sentences or values).
_ui_trunc() {
    local s="$1" max="$2"
    s="${s//[[:cntrl:]]/?}"
    if [ "$max" -lt 1 ]; then return 0; fi
    if [ "${#s}" -le "$max" ]; then
        printf '%s' "$s"
    elif [ "$max" -le "${#BATCH_ELL}" ]; then
        printf '%s' "${s:0:max}"
    else
        printf '%s%s' "${s:0:$((max - ${#BATCH_ELL}))}" "$BATCH_ELL"
    fi
}

# Word-wrap TEXT to WIDTH columns: _ui_wrap_print INDENT WIDTH TEXT COLOR
_ui_wrap_print() {
    local indent="$1" width="$2" text="$3" color="${4:-}"
    local IFS=' ' word line="" words=()
    read -r -a words <<< "$text"
    for word in "${words[@]}"; do
        if [ -z "$line" ]; then
            line="$word"
        elif [ $(( ${#line} + 1 + ${#word} )) -le "$width" ]; then
            line="$line $word"
        else
            printf '%s%s%s%s\n' "$indent" "$color" "$line" "$UI_RST"
            line="$word"
        fi
    done
    if [ -n "$line" ]; then
        printf '%s%s%s%s\n' "$indent" "$color" "$line" "$UI_RST"
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Boxed header
# ---------------------------------------------------------------------------
_ui_boxline() {   # ALIGN(center|left) COLOR TEXT
    local align="$1" color="$2" text="$3" inner avail pl pr
    inner=$((UI_W - 2)); avail=$((inner - 2))
    text=$(_ui_trunc "$text" "$avail")
    if [ "$align" = "center" ]; then pl=$(( (inner - ${#text}) / 2 )); else pl=1; fi
    pr=$((inner - ${#text} - pl))
    if [ "$pr" -lt 0 ]; then pr=0; fi
    printf '%s%s%s%*s%s%s%s%*s%s%s%s\n' \
        "$UI_ACC" "$BATCH_V" "$UI_RST" "$pl" "" "$color" "$text" "$UI_RST" "$pr" "" \
        "$UI_ACC" "$BATCH_V" "$UI_RST"
}

ui_header() {
    local title="$1" line inner
    shift
    ui_refresh
    inner=$((UI_W - 2))
    echo ""
    printf '%s%s%s%s%s\n' "$UI_ACC" "$BATCH_TL" "$(_batch_rep "$BATCH_H" "$inner")" "$BATCH_TR" "$UI_RST"
    _ui_boxline center "$UI_HEAD" "$title"
    for line in "$@"; do
        _ui_boxline left "$UI_DIM" "$line"
    done
    printf '%s%s%s%s%s\n' "$UI_ACC" "$BATCH_BL" "$(_batch_rep "$BATCH_H" "$inner")" "$BATCH_BR" "$UI_RST"
}

# " ─ LABEL ───────────"
ui_section() {
    local label="$1" n
    _ui_ready
    n=$((UI_W - ${#label} - 4))
    if [ "$n" -lt 2 ]; then n=2; fi
    printf ' %s%s%s %s%s%s %s%s%s\n' "$UI_DIM" "$BATCH_H" "$UI_RST" "$UI_HEAD" "$label" "$UI_RST" \
        "$UI_DIM" "$(_batch_rep "$BATCH_H" "$n")" "$UI_RST"
}

ui_rule() {
    _ui_ready
    printf ' %s%s%s\n' "$UI_DIM" "$(_batch_rep "$BATCH_H" $((UI_W - 2)))" "$UI_RST"
}

# ---------------------------------------------------------------------------
# Menu row:  [1]  Label ···· value  extra
# ---------------------------------------------------------------------------
ui_row() {
    local key="$1" label="$2" value="$3" tone="${4:-}" extra="${5:-}"
    local lw avail pad vcolor rem kpad
    _ui_ready
    lw=$UI_LABEL_W
    label=$(_ui_trunc "$label" "$lw")
    pad=$((lw - ${#label}))
    avail=$((UI_W - lw - 9))
    if [ "$avail" -lt 6 ]; then avail=6; fi
    value=$(_ui_trunc "$value" "$avail")
    rem=$((avail - ${#value} - 1))
    if [ -z "$extra" ] || [ "${#extra}" -gt "$rem" ]; then extra=""; fi
    case "$tone" in
        on)   vcolor="$UI_OK" ;;
        off)  vcolor="$UI_DIM" ;;
        warn) vcolor="$UI_WARNC" ;;
        *)    vcolor="$UI_BOLD" ;;
    esac
    kpad=$((2 - ${#key}))
    if [ "$kpad" -lt 0 ]; then kpad=0; fi
    printf ' %s[%s]%s%*s %s %s%s%s %s%s%s' \
        "$UI_KEY" "$key" "$UI_RST" "$kpad" "" \
        "$label" \
        "$UI_DIM" "$(_batch_rep "$UI_LEAD" $((pad + 1)))" "$UI_RST" \
        "$vcolor" "$value" "$UI_RST"
    if [ -n "$extra" ]; then
        printf ' %s%s%s' "$UI_DIM" "$extra" "$UI_RST"
    fi
    printf '\n'
}

# Footer shortcuts: ui_actions "7|▶ Start|$UI_OK" "8|Save|" "0|Exit|$UI_ERRC"
ui_actions() {
    local item key rest label tone used=1 need first=1
    _ui_ready
    printf ' '
    for item in "$@"; do
        key="${item%%|*}"; rest="${item#*|}"
        if [[ "$rest" == *"|"* ]]; then label="${rest%%|*}"; tone="${rest#*|}"; else label="$rest"; tone=""; fi
        need=$(( ${#key} + ${#label} + 5 ))
        if [ "$first" -eq 0 ] && [ $((used + need)) -gt "$UI_W" ]; then
            printf '\n '
            used=1
        fi
        printf '%s[%s]%s %s%s%s   ' "$UI_KEY" "$key" "$UI_RST" "$tone" "$label" "$UI_RST"
        used=$((used + need))
        first=0
    done
    printf '\n'
}

# ---------------------------------------------------------------------------
# Info card (fixed width). Rows: "label|color|value"
# ---------------------------------------------------------------------------
ui_card() {
    local title="$1" row label rest color value labelw=0 inner avail pad i n fill
    local labels=() colors=() values=()
    shift
    ui_refresh
    inner=$((UI_W - 2))
    for row in "$@"; do
        label="${row%%|*}"; rest="${row#*|}"
        color="${rest%%|*}"; value="${rest#*|}"
        color=$(printf '%b' "$color")   # COLOR_* in convert.sh are literal \033 text
        value="${value//[[:cntrl:]]/?}"
        labels+=("$label"); colors+=("$color"); values+=("$value")
        if [ "${#label}" -gt "$labelw" ]; then labelw=${#label}; fi
    done
    n=${#labels[@]}

    title=$(_ui_trunc "$title" $((inner - 4)))
    fill=$((inner - ${#title} - 3))
    if [ "$fill" -lt 0 ]; then fill=0; fi
    printf '%s%s%s %s%s%s %s%s%s%s\n' "$UI_ACC" "$BATCH_TL" "$BATCH_H" "$UI_HEAD" "$title" "$UI_ACC" \
        "$(_batch_rep "$BATCH_H" "$fill")" "$BATCH_TR" "$UI_RST" ""

    avail=$((inner - labelw - 4))
    if [ "$avail" -lt 4 ]; then avail=4; fi
    for (( i=0; i<n; i++ )); do
        value=$(_ui_trunc "${values[$i]}" "$avail")
        pad=$((avail - ${#value}))
        if [ "$pad" -lt 0 ]; then pad=0; fi
        printf '%s%s%s %s%-*s%s  %s%s%s%*s %s%s%s\n' \
            "$UI_ACC" "$BATCH_V" "$UI_RST" \
            "$UI_DIM" "$labelw" "${labels[$i]}" "$UI_RST" \
            "${colors[$i]}" "$value" "$UI_RST" "$pad" "" \
            "$UI_ACC" "$BATCH_V" "$UI_RST"
    done
    printf '%s%s%s%s%s\n' "$UI_ACC" "$BATCH_BL" "$(_batch_rep "$BATCH_H" "$inner")" "$BATCH_BR" "$UI_RST"
}

# ---------------------------------------------------------------------------
# Sub-menu pieces
# ---------------------------------------------------------------------------
# " ▸ TITLE ─────────" + optional wrapped description underneath
ui_submenu_title() {
    local title="$1" desc="${2:-}" n
    ui_refresh
    title=$(_ui_trunc "$title" $((UI_W - 6)))
    n=$((UI_W - ${#title} - 4))
    if [ "$n" -lt 2 ]; then n=2; fi
    echo ""
    printf ' %s%s%s %s%s%s %s%s%s\n' "$UI_ACC" "$UI_BUL" "$UI_RST" "$UI_HEAD" "$title" "$UI_RST" \
        "$UI_DIM" "$(_batch_rep "$BATCH_H" "$n")" "$UI_RST"
    if [ -n "$desc" ]; then
        _ui_wrap_print "   " $((UI_W - 4)) "$desc" "$UI_DIM"
    fi
    echo ""
}

# Option line. Pass the current value and this option's value to get a ● marker.
ui_opt() {
    local n="$1" text="$2" cur="${3:-}" me="${4:-}" mark=" " color="" maxw
    _ui_ready
    maxw=$((UI_W - 9))
    text=$(_ui_trunc "$text" "$maxw")
    if [ -n "$me" ] && [ "$cur" = "$me" ]; then mark="$UI_ON"; color="$UI_OK"; fi
    printf '  %s%s%s %s[%s]%s %s\n' "$color" "$mark" "$UI_RST" "$UI_KEY" "$n" "$UI_RST" "$text"
}

# Backwards-compatible name used by older call sites
ui_submenu_item() { ui_opt "$1" "$2"; }

ui_hint() {
    _ui_ready
    _ui_wrap_print "  " $((UI_W - 3)) "$1" "$UI_DIM"
}

ui_prompt() {
    _batch_ui_init
    printf ' %s%s %s:%s ' "$UI_ACC" "$BATCH_ARROW" "$1" "$UI_RST"
}

# Yes/no question. Returns 0 for yes. Default applies on empty input / EOF.
ui_confirm() {
    local prompt="$1" def="${2:-Y}" ans="" hint="[Y/n]"
    if [ "$def" = "N" ]; then hint="[y/N]"; fi
    read -r -p "$(ui_prompt "$prompt $hint")" ans || ans=""
    if [ "$def" = "N" ]; then
        [[ "$ans" =~ ^[Yy] ]]
    else
        [[ ! "$ans" =~ ^[Nn] ]]
    fi
}

# ---------------------------------------------------------------------------
# One-line messages (single argument!)
# ---------------------------------------------------------------------------
ui_ok()   { _ui_ready; printf '  %s%s%s %s\n' "$UI_OK"    "$UI_CHK"  "$UI_RST" "$1"; }
ui_warn() { _ui_ready; printf '  %s%s%s %s\n' "$UI_WARNC" "$UI_WRN"  "$UI_RST" "$1"; }
ui_err()  { _ui_ready; printf '  %s%s%s %s\n' "$UI_ERRC"  "$UI_X"    "$UI_RST" "$1"; }
ui_note() { _ui_ready; printf '  %s%s %s%s\n' "$UI_DIM"   "$UI_NOTE" "$1" "$UI_RST"; }

ui_pause() { sleep "${1:-1}"; }

# ---------------------------------------------------------------------------
# CPU temperature helpers (shared by progress screen and cooldown)
# ---------------------------------------------------------------------------
# Prints the sysfs temp file of the best CPU sensor, or nothing if none found.
ui_cpu_zone() {
    local d type temp pick=""
    for d in /sys/class/thermal/thermal_zone*; do
        if [ ! -r "$d/type" ] || [ ! -r "$d/temp" ]; then continue; fi
        read -r type < "$d/type" || continue
        read -r temp < "$d/temp" || continue
        if ! [[ "$temp" =~ ^[0-9]+$ ]] || [ "$temp" -le 0 ]; then continue; fi
        if [ "$type" = "cpu-1-7-usr" ]; then pick="$d/temp"; break; fi
        if [ -z "$pick" ] && [[ "$type" == *cpu* || "$type" == *soc* || "$type" == x86_pkg_temp ]]; then
            pick="$d/temp"
        fi
    done
    printf '%s' "$pick"
}

ui_temp_color() {   # degrees C -> color escape
    local t="${1:-0}"
    if   [ "$t" -ge 90 ]; then printf '%b' "$COLOR_RED"
    elif [ "$t" -ge 85 ]; then printf '%b' "$COLOR_ORANGE"
    elif [ "$t" -ge 75 ]; then printf '%b' "$COLOR_YELLOW"
    else printf '%b' "$COLOR_GREEN"
    fi
}
