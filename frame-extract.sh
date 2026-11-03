#!/data/data/com.termux/files/usr/bin/bash
set -uo pipefail

# ===========================================================================
# VIDEO FRAME EXTRACTOR
# Standalone tool — generates N evenly-spaced preview images from a video.
# User picks how many previews they want (min 10); the script works out
# which timestamps to grab based on the video's own duration, and caps the
# request at that video's actual total frame count.
#
# After choosing "new extraction", you pick what to produce:
#   1) previews only        2) contact sheet only        3) both
# Every later question adapts to that choice.
# ===========================================================================

# ==================== COLOR DEFINITIONS (matches convert.sh) ====================
declare -g COLOR_RESET="\033[0m"
declare -g COLOR_RED="\033[1m\033[38;5;196m"
declare -g COLOR_GREEN="\033[1m\033[38;5;82m"
declare -g COLOR_YELLOW="\033[1m\033[38;5;226m"
declare -g COLOR_ORANGE="\033[1m\033[38;5;208m"
declare -g COLOR_BLUE="\033[1m\033[38;5;39m"
declare -g COLOR_CYAN="\033[1m\033[38;5;6m"
# ===================================================================================

# ==================== CONFIG — EDIT THESE AS NEEDED ====================
declare -g DEFAULT_INPUT_DIR="/sdcard/Movies/ffmpeg/Converted"
declare -g OUTPUT_DIR="/sdcard/Movies/ffmpeg/Previews"
declare -g LOG_DIR="/sdcard/Movies/ffmpeg/Previews/Previews_Logs"
declare -g COMPLETED_DIR="/sdcard/Movies/ffmpeg/.preview_status/completed"

declare -g MIN_PREVIEWS=10          # hard floor — never request fewer than this
declare -g CONFIRM_ABOVE=200        # ask to confirm if requesting more than this many per video
declare -g PREVIEW_WIDTH=0        # output width in px, height auto-scales; empty = original size
declare -g PREVIEW_FORMAT="jpg"     # jpg or png
declare -g PREVIEW_QUALITY=1        # jpg only: 1 (best) - 31 (worst); ignored for png

declare -g PREVIEW_TIMESTAMP="no"  # yes/no — burn the clip's HH:MM:SS onto each preview
declare -g PREVIEW_TS_FONTSIZE=50   # individual preview timestamp size in px
declare -g SHEET_TS_FONTSIZE=50      # contact sheet timestamp size in px
declare -g PREVIEW_TS_FONT=""       # path to a .ttf/.otf to use; empty = auto-detect one

declare -g KEEP_PREVIEWS="yes"        # set automatically from the output choice (sheet-only = no)
declare -g CONTACT_SHEET="yes"         # yes/no — also build a single grid image from the extracted previews
declare -g CONTACT_SHEET_COLUMNS=3    # 2-6 — rows are computed automatically to fit every preview
declare -g CONTACT_SHEET_MIN_COLUMNS=2
declare -g CONTACT_SHEET_MAX_COLUMNS=6
declare -g SHEET_TIMESTAMP="yes"      # yes/no — independent of PREVIEW_TIMESTAMP: the grid can show
                                       # timestamps even when individual previews don't, or vice versa
declare -g GENERATE_BBCODE="yes"       # yes/no — write a BBCode post .txt beside the previews/sheet
declare -g BBCODE_FONT="Arial"
declare -g BBCODE_COLOR="#000000"
declare -g BBCODE_FIXED_TAGS="InTheCrack, ITC, Solo, Masturbation" # comma-separated tags reused for every post
# =========================================================================

# ==================== UI HELPERS ====================
# Look: sentence-case text, one icon per message type, a rounded banner,
# thin section dividers, [n] menu keys and a live progress bar. Widths adapt
# to the terminal (clamped so it still looks right on a phone).
declare -g COLOR_ACCENT="\033[1m\033[38;5;45m"
declare -g COLOR_WHITE="\033[1m\033[38;5;255m"
declare -g COLOR_GRAY="\033[38;5;245m"
declare -g UI_WIDTH=40
declare -g UI_RULE=""

ui_init() {
    local cols i
    cols=$(tput cols 2>/dev/null || echo 44)
    [[ "$cols" =~ ^[0-9]+$ ]] || cols=44
    UI_WIDTH=$(( cols - 4 ))
    [ "$UI_WIDTH" -gt 52 ] && UI_WIDTH=52
    [ "$UI_WIDTH" -lt 24 ] && UI_WIDTH=24
    UI_RULE=""
    for ((i = 0; i < UI_WIDTH; i++)); do UI_RULE+="─"; done
}
ui_init

ui_banner() {  # title [subtitle]  (ASCII only: padding is by character count)
    local inner=$(( UI_WIDTH - 4 )) t sub=""
    printf -v t '%-*s' "$inner" "${1:0:$inner}"
    [ -n "${2:-}" ] && printf -v sub '%-*s' "$inner" "${2:0:$inner}"
    echo ""
    echo -e " ${COLOR_ACCENT}╭${UI_RULE}╮${COLOR_RESET}"
    echo -e " ${COLOR_ACCENT}│${COLOR_RESET}  ${COLOR_WHITE}${t}${COLOR_RESET}  ${COLOR_ACCENT}│${COLOR_RESET}"
    [ -n "$sub" ] && echo -e " ${COLOR_ACCENT}│${COLOR_RESET}  ${COLOR_GRAY}${sub}${COLOR_RESET}  ${COLOR_ACCENT}│${COLOR_RESET}"
    echo -e " ${COLOR_ACCENT}╰${UI_RULE}╯${COLOR_RESET}"
}

ui_section() {  # title (ASCII only: its length sizes the divider)
    local t="$1" fill i bar=""
    fill=$(( UI_WIDTH - ${#t} - 3 ))
    [ "$fill" -lt 3 ] && fill=3
    for ((i = 0; i < fill; i++)); do bar+="─"; done
    echo ""
    echo -e " ${COLOR_ACCENT}──${COLOR_RESET} ${COLOR_WHITE}${t}${COLOR_RESET} ${COLOR_GRAY}${bar}${COLOR_RESET}"
}

ui_ok()   { echo -e " ${COLOR_GREEN}✔${COLOR_RESET} $*"; }
ui_warn() { echo -e " ${COLOR_YELLOW}⚠${COLOR_RESET} $*"; }
ui_err()  { echo -e " ${COLOR_RED}✖${COLOR_RESET} $*"; }
ui_info() { echo -e " ${COLOR_ACCENT}•${COLOR_RESET} $*"; }
ui_note() { echo -e "   ${COLOR_GRAY}$*${COLOR_RESET}"; }

ui_kv() {  # label value
    local l
    l=$(printf '%-9s' "$1")
    echo -e "   ${COLOR_GRAY}${l}${COLOR_RESET} $2"
}

ui_opt() {  # key label [hint]
    local hint=""
    [ -n "${3:-}" ] && hint="  ${COLOR_GRAY}${3}${COLOR_RESET}"
    echo -e "   ${COLOR_ACCENT}[${1}]${COLOR_RESET} ${2}${hint}"
}

# Use as: read -r -p "$(ui_prompt "Question" "(hint)")" var
ui_prompt() {  # label [hint]
    local out=" ${COLOR_ACCENT}❯${COLOR_RESET} ${COLOR_WHITE}$1${COLOR_RESET}"
    [ -n "${2:-}" ] && out+=" ${COLOR_GRAY}$2${COLOR_RESET}"
    printf '%b ' "$out"
}

ui_progress() {  # current total  (only drawn on a real terminal)
    [ -t 1 ] || return 0
    local cur="$1" total="$2" w=20 filled pct i bar=""
    [ "$total" -gt 0 ] 2>/dev/null || return 0
    filled=$(( cur * w / total ))
    pct=$(( cur * 100 / total ))
    for ((i = 0; i < w; i++)); do
        if (( i < filled )); then bar+="█"; else bar+="░"; fi
    done
    printf '\r\033[K   %b%s%b %3d%%  %b%d/%d%b' \
        "$COLOR_ACCENT" "$bar" "$COLOR_RESET" "$pct" "$COLOR_GRAY" "$cur" "$total" "$COLOR_RESET"
}
ui_progress_clear() { [ -t 1 ] && printf '\r\033[K'; return 0; }
# =========================================================================

declare -g FAILED=0
declare -g SUCCEEDED=0
declare -g SKIPPED=0
declare -g CURRENT_FFMPEG_PID=""
declare -g CURRENT_OUTPUT_FILE=""

# ------------------------------------------------------------
# Ctrl+C handling — kills only the ffmpeg process this script
# itself started, tracked by PID.
# ------------------------------------------------------------
trap handle_interrupt INT TERM

handle_interrupt() {
    echo ""
    printf '\r\033[K'
    ui_err "Ctrl+C detected — aborting..."
    if [ -n "$CURRENT_FFMPEG_PID" ]; then
        kill -INT "$CURRENT_FFMPEG_PID" 2>/dev/null
        sleep 1
        kill -KILL "$CURRENT_FFMPEG_PID" 2>/dev/null
    fi
    [ -n "$CURRENT_OUTPUT_FILE" ] && rm -f "$CURRENT_OUTPUT_FILE" 2>/dev/null
    ui_err "Process terminated by user"
    exit 130
}

run_ffmpeg() {
    "$@" &
    CURRENT_FFMPEG_PID=$!
    wait "$CURRENT_FFMPEG_PID"
    local status=$?
    CURRENT_FFMPEG_PID=""
    return $status
}

# ------------------------------------------------------------
# FUNCTION: find_font — locates a .ttf/.otf for the timestamp
# overlay. Checks PREVIEW_TS_FONT first, then common Termux and
# Linux font package locations. Prints nothing; echoes the path
# found, or nothing if none was found.
# ------------------------------------------------------------
find_font() {
    local candidates=(
        "$PREVIEW_TS_FONT"
        "${PREFIX:-}/share/fonts/TTF/DejaVuSans.ttf"
        "/data/data/com.termux/files/usr/share/fonts/TTF/DejaVuSans.ttf"
        "/data/data/com.termux/files/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"
        "/system/fonts/Roboto-Regular.ttf"
        "/system/fonts/DroidSans.ttf"
        "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"
        "/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf"
    )
    local f
    for f in "${candidates[@]}"; do
        [ -n "$f" ] && [ -f "$f" ] && { echo "$f"; return 0; }
    done
    return 1
}

# ------------------------------------------------------------
# FUNCTION: human_duration — turns seconds (e.g. 4814.798000) into
# "1h 20m 15s". Drops leading zero units: "20m 15s", "15s".
# ------------------------------------------------------------
human_duration() {
    awk -v d="$1" 'BEGIN {
        d = int(d + 0.5)
        h = int(d / 3600); m = int((d % 3600) / 60); s = d % 60
        if (h > 0)      printf "%dh %dm %ds", h, m, s
        else if (m > 0) printf "%dm %ds", m, s
        else            printf "%ds", s
    }'
}

# ------------------------------------------------------------
# FUNCTION: check_dependencies
# ------------------------------------------------------------
check_dependencies() {
    local missing=()
    local deps=(ffmpeg ffprobe find realpath sha256sum sort awk du grep sed tr wc head)

    declare -A dep_pkg=(
        [ffmpeg]="ffmpeg" [ffprobe]="ffmpeg"
        [realpath]="coreutils" [sha256sum]="coreutils" [sort]="coreutils" [du]="coreutils"
        [awk]="gawk" [find]="findutils" [grep]="grep" [sed]="sed"
        [tr]="coreutils" [wc]="coreutils" [head]="coreutils"
    )

    for dep in "${deps[@]}"; do
        command -v "$dep" >/dev/null 2>&1 || missing+=("$dep")
    done

    if [ ${#missing[@]} -gt 0 ]; then
        ui_err "Missing dependencies"
        for m in "${missing[@]}"; do echo -e "   ${COLOR_GRAY}•${COLOR_RESET} $m"; done
        local pkgs=()
        for m in "${missing[@]}"; do pkgs+=("${dep_pkg[$m]}"); done
        pkgs=($(printf "%s\n" "${pkgs[@]}" | sort -u))
        echo ""
        ui_info "Install with:"
        printf "   ${COLOR_ACCENT}pkg install${COLOR_RESET}"
        for p in "${pkgs[@]}"; do printf " %s" "$p"; done
        printf "\n"
        exit 1
    fi
}

# ------------------------------------------------------------
# FUNCTION: mark_completed / is_completed
# Hashes input_file + requested count + width + format together,
# so changing how many previews you ask for (or the output size/
# format) correctly triggers a re-extract instead of being
# skipped as "already done".
# ------------------------------------------------------------
mark_completed() {
    local key="$1"
    local marker_name
    marker_name=$(printf '%s' "$key" | sha256sum | awk '{print $1}')
    touch "$COMPLETED_DIR/$marker_name"
}

is_completed() {
    local key="$1"
    local marker_name
    marker_name=$(printf '%s' "$key" | sha256sum | awk '{print $1}')
    [ -f "$COMPLETED_DIR/$marker_name" ] && return 0
    return 1
}

# Forget a completion marker (used when its output folder is deleted, so a
# later batch run re-extracts instead of skipping it as "already done").
declare -gA CLEANUP_MARKERS=()
unmark_completed() {
    local key="$1" marker_name
    [ -n "$key" ] || return 0
    marker_name=$(printf '%s' "$key" | sha256sum | awk '{print $1}')
    rm -f "$COMPLETED_DIR/$marker_name"
}

# ------------------------------------------------------------
# FUNCTION: has_video_files — recursive, prunes chunks_* dirs
# ------------------------------------------------------------
has_video_files() {
    local dir="$1"
    [ ! -d "$dir" ] && return 1

    local first_match
    first_match=$(find "$dir" \
        \( -type d -iname "chunks_*" -prune \) -o \
        \( -type f \( \
        -iname "*.mp4" -o -iname "*.mkv" -o -iname "*.mov" -o -iname "*.avi" -o \
        -iname "*.webm" -o -iname "*.wmv" -o -iname "*.flv" -o -iname "*.mpeg" -o \
        -iname "*.mpg" -o -iname "*.mpe" -o -iname "*.m4v" -o -iname "*.3gp" -o \
        -iname "*.3g2" -o -iname "*.f4v" -o -iname "*.ts" -o -iname "*.m2ts" -o \
        -iname "*.mts" -o -iname "*.vob" \) -print \) -quit)

    [ -n "$first_match" ]
}

# ------------------------------------------------------------
# FUNCTION: process_file — extracts N evenly-spaced previews
# from one video.
# $1 = input file, $2 = requested count, $3 = relative
#      subdirectory under the scan root (mirrored into
#      OUTPUT_DIR/LOG_DIR), optional
# $4 = batch mode flag (true enables completion-marker checks)
# ------------------------------------------------------------
# ------------------------------------------------------------
# FUNCTION: build_contact_sheet — tiles an ordered list of
# already-extracted preview images into a single grid (cols
# fixed, rows computed to fit them all). Pads any leftover
# slots in the final row with blank cells so the grid always
# comes out complete. Never fails the overall video — a sheet
# problem is logged and skipped, individual previews still count.
# $1 = output path for the sheet, $2 = log file, $3 = cols,
# remaining args = ordered list of source image files
# ------------------------------------------------------------
build_contact_sheet() {
    local sheet_file="$1"
    local log_file="$2"
    local cols="$3"
    shift 3
    local files=("$@")
    local n=${#files[@]}
    [ "$n" -eq 0 ] && return 1

    local rows=$(( (n + cols - 1) / cols ))
    local total_slots=$(( cols * rows ))
    local pad_needed=$(( total_slots - n ))

    local dims
    dims=$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height \
        -of csv=s=x:p=0 "${files[0]}" 2>>"$log_file")
    if [ -z "$dims" ]; then
        ui_warn "Couldn't read preview dimensions — skipping contact sheet"
        return 1
    fi

    local stage_dir
    stage_dir=$(mktemp -d "$(dirname "$sheet_file")/.sheet_stage_XXXXXX") || return 1

    local stage_pad=${#total_slots}
    local idx=1 f num
    for f in "${files[@]}"; do
        num=$(printf "%0${stage_pad}d" "$idx")
        cp "$f" "${stage_dir}/tile_${num}.${PREVIEW_FORMAT}" 2>>"$log_file"
        ((idx++))
    done

    if [ "$pad_needed" -gt 0 ]; then
        local blank_file="${stage_dir}/blank_src.${PREVIEW_FORMAT}"
        if ! run_ffmpeg ffmpeg -y -f lavfi -i "color=c=black:s=${dims}" -frames:v 1 \
            "$blank_file" >>"$log_file" 2>&1; then
            ui_warn "Couldn't build the blank filler — skipping contact sheet"
            rm -rf "$stage_dir"
            return 1
        fi
        local p
        for ((p = 0; p < pad_needed; p++)); do
            num=$(printf "%0${stage_pad}d" "$idx")
            cp "$blank_file" "${stage_dir}/tile_${num}.${PREVIEW_FORMAT}"
            ((idx++))
        done
    fi

    local quality_args=()
    [ "$PREVIEW_FORMAT" = "jpg" ] && quality_args=(-q:v "$PREVIEW_QUALITY")

    CURRENT_OUTPUT_FILE="$sheet_file"
    local ok=1
    if run_ffmpeg ffmpeg -y -i "${stage_dir}/tile_%0${stage_pad}d.${PREVIEW_FORMAT}" \
        -vf "tile=${cols}x${rows}" -frames:v 1 "${quality_args[@]}" \
        "$sheet_file" >>"$log_file" 2>&1 && [ -s "$sheet_file" ]; then
        ok=0
    fi
    CURRENT_OUTPUT_FILE=""
    rm -rf "$stage_dir"

    if [ "$ok" -eq 0 ]; then
        ui_ok "Contact sheet ${COLOR_GRAY}(${cols}x${rows} grid, $n preview(s)$( [ "$pad_needed" -gt 0 ] && echo ", $pad_needed blank"))${COLOR_RESET}"
        ui_note "$sheet_file"
        return 0
    else
        ui_warn "Contact sheet generation failed ${COLOR_GRAY}(see $log_file)${COLOR_RESET}"
        rm -f "$sheet_file"
        return 1
    fi
}

# ------------------------------------------------------------
# BBCODE POST GENERATOR
# Helper functions (bbcode_*) are small and independent so tag
# rules, templates and input handling can be changed in one place.
# write_bbcode_metadata (further below) is the orchestrator that
# process_file calls once per video.
# ------------------------------------------------------------
declare -g BBCODE_URL_REGEX='https?://[^][:space:]<>"]+'   # URLs may not contain [ ] quotes, <> or spaces
declare -g BBCODE_SKIP_ALL="no"        # set when the user answers "s" (skip for the rest of this run)
declare -g BB_IMAGE_URL="" BB_IMAGE_LINK="" BB_DOWNLOAD_URL=""
declare -g BB_PARSED_IMG="" BB_PARSED_LINK=""
declare -g BB_TITLE="" BB_TAGS=""
declare -g BB_DURATION="" BB_RESOLUTION="" BB_RES_LABEL="" BB_FILE_SIZE=""
declare -g BB_CONTAINER="" BB_VCODEC="" BB_ACODEC=""
declare -g BB_FPS="" BB_PIX_FMT="" BB_VBITRATE="" BB_ASAMPLE_RATE="" BB_ABITRATE=""
declare -g BB_EP_NUM="" BB_EP_HASH="" BB_EP_TAG="" BB_TITLE_TAG=""
declare -ga BB_TAG_LIST=()

bbcode_warn() { ui_warn "$*"; }

# Trim leading/trailing whitespace.
bbcode_trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

# bbcode_ask VAR "prompt" — returns 1 when input is closed (EOF) so no
# prompt loop can spin forever on a closed/piped stdin.
bbcode_ask() {
    local __var="$1" __prompt="$2" __reply=""
    if ! read -r -p "$__prompt" __reply; then
        echo ""
        return 1
    fi
    printf -v "$__var" '%s' "$__reply"
    return 0
}

# Discards extra lines that arrived with a multi-line paste so they are not
# mistaken for answers to the next prompts. Only on a real terminal.
bbcode_drain_input() {
    [ -t 0 ] || return 0
    local junk
    while IFS= read -r -t 1.0 junk; do :; done
    return 0
}

# bbcode_ask_paste VAR "prompt" - like bbcode_ask, but accepts a multi-line
# paste: after the first line it keeps collecting lines until the input has
# been quiet for a moment (a partial last line without a newline is kept too).
# Lines are joined with newlines. Only on a real terminal; elsewhere it is a
# plain single-line read so scripted input is never over-consumed.
bbcode_ask_paste() {
    local __var="$1" __prompt="$2" __first="" __all="" __chunk="" __stty=""
    bbcode_ask __first "$__prompt" || return 1
    __all="$__first"
    if [ -t 0 ]; then
        # The terminal holds back a last pasted line that has no trailing
        # newline until Enter is pressed. Switch to non-canonical mode briefly
        # so that held-back text (and any further lines) can be read now.
        __stty=$(stty -g 2>/dev/null) || __stty=""
        [ -n "$__stty" ] && stty -icanon 2>/dev/null
        IFS= read -r -t 0.8 -d '' -N 65536 __chunk 2>/dev/null || true
        [ -n "$__stty" ] && stty "$__stty" 2>/dev/null
        __chunk="${__chunk//$'\r'/}"
        [ -n "$__chunk" ] && __all+=$'\n'"$__chunk"
    fi
    printf -v "$__var" '%s' "$__all"
    return 0
}

# Prints every valid URL found in $1, one per line, in order, no duplicates.
bbcode_extract_all_urls() {
    local u
    printf '%s\n' "$1" | grep -oiE "$BBCODE_URL_REGEX" | while IFS= read -r u; do
        u=$(printf '%s' "$u" | sed "s/[\"',;.]*\$//")
        [[ "$u" != *"("* ]] && u="${u%)}"
        bbcode_is_valid_url "$u" && printf '%s\n' "$u"
    done | awk '!seen[$0]++'
}

bbcode_is_cancel() {
    local s
    s=$(bbcode_trim "$1")
    [ "${s,,}" = "cancel" ]
}

bbcode_is_valid_url() {
    [[ "$1" =~ ^${BBCODE_URL_REGEX}$ ]]
}

# Prints the first URL found in $1 (any surrounding text is ignored),
# minus trailing punctuation that is almost never part of a link.
bbcode_extract_first_url() {
    local url
    url=$(printf '%s\n' "$1" | grep -oiE "$BBCODE_URL_REGEX" | head -n 1 || true)
    url=$(printf '%s' "$url" | sed "s/[\"',;.]*\$//")
    if [[ "$url" != *"("* ]]; then
        url="${url%)}"
    fi
    printf '%s' "$url"
}

# Thumbnail -> full-size: only the first "/u/t/" path segment (before any
# query string) becomes "/u/i/". Everything else is left untouched.
bbcode_normalize_image_url() {
    local url="$1" base rest=""
    base="$url"
    if [[ "$url" == *\?* ]]; then
        base="${url%%\?*}"
        rest="?${url#*\?}"
    fi
    base="${base/\/u\/t\//\/u\/i\/}"
    printf '%s%s' "$base" "$rest"
}

# Parses either a plain image URL or a [URL=...][IMG]...[/IMG][/URL] block.
# Sets BB_PARSED_IMG / BB_PARSED_LINK (link may be empty for a plain URL).
# Returns 0 = ok, 1 = no valid image URL, 2 = click-through URL malformed.
bbcode_parse_image_input() {
    local raw="$1" img="" link=""
    BB_PARSED_IMG=""
    BB_PARSED_LINK=""
    if printf '%s' "$raw" | grep -qiE '\[img\]'; then
        img=$(printf '%s' "$raw" | grep -oiE '\[img\][^][]+\[/img\]' | head -n 1 \
            | sed -E 's/^\[[Ii][Mm][Gg]\]//; s/\[\/[Ii][Mm][Gg]\]$//' || true)
        link=$(printf '%s' "$raw" | grep -oiE '\[url=[^]]+\]' | head -n 1 \
            | sed -E "s/^\[[Uu][Rr][Ll]=//; s/\]\$//; s/^[\"']//; s/[\"']\$//" || true)
    else
        img=$(bbcode_extract_first_url "$raw")
    fi
    img=$(bbcode_trim "$img")
    link=$(bbcode_trim "$link")
    bbcode_is_valid_url "$img" || return 1
    if [ -n "$link" ] && ! bbcode_is_valid_url "$link"; then
        return 2
    fi
    BB_PARSED_IMG="$img"
    BB_PARSED_LINK="$link"
    return 0
}

# Asks for the image link. Sets BB_IMAGE_URL / BB_IMAGE_LINK on success only.
# Returns 0 = ok, 1 = input closed, 2 = user typed "cancel".
bbcode_prompt_image_link() {
    local raw rc click norm
    ui_section "Image link"
    ui_note "Paste a full [URL=...][IMG]...[/IMG][/URL] block (easiest),"
    ui_note "or just the image URL — you'll then be asked for its click-through URL."
    while true; do
        bbcode_ask_paste raw "$(ui_prompt "Image link" "(or 'cancel')")" || return 1
        raw=$(bbcode_trim "$raw")
        if [ -z "$raw" ]; then
            bbcode_warn "The image link is required."
            continue
        fi
        bbcode_is_cancel "$raw" && return 2
        bbcode_parse_image_input "$raw"
        rc=$?
        if [ "$rc" -eq 1 ]; then
            bbcode_warn "No valid image URL found. It must start with http:// or https:// and contain no spaces or brackets."
            continue
        elif [ "$rc" -eq 2 ]; then
            bbcode_warn "The click-through URL inside the [URL=...] tag is not a valid http(s) link."
            continue
        fi
        click="$BB_PARSED_LINK"
        while [ -z "$click" ]; do
            bbcode_ask click "$(ui_prompt "Click-through URL" "(or 'cancel')")" || return 1
            click=$(bbcode_trim "$click")
            bbcode_is_cancel "$click" && return 2
            if ! bbcode_is_valid_url "$click"; then
                bbcode_warn "Enter a full URL beginning with http:// or https://."
                click=""
            fi
        done
        norm=$(bbcode_normalize_image_url "$BB_PARSED_IMG")
        [ "$norm" != "$BB_PARSED_IMG" ] && ui_info "Thumbnail link converted to the full-size image URL."
        BB_IMAGE_URL="$norm"
        BB_IMAGE_LINK="$click"
        return 0
    done
}

# Asks for the download URL. Whatever is pasted, the first valid URL in the
# line is used. Sets BB_DOWNLOAD_URL on success only.
# Returns 0 = ok, 1 = input closed, 2 = user typed "cancel".
bbcode_prompt_download_url() {
    local text pick n i
    local -a urls
    while true; do
        bbcode_ask_paste text "$(ui_prompt "Download URL" "(paste, or 'cancel')")" || return 1
        bbcode_is_cancel "$text" && return 2
        mapfile -t urls < <(bbcode_extract_all_urls "$text")
        n=${#urls[@]}
        if [ "$n" -eq 0 ]; then
            bbcode_warn "No valid URL found. Enter a full link beginning with http:// or https://."
            continue
        fi
        if [ "$n" -eq 1 ]; then
            BB_DOWNLOAD_URL="${urls[0]}"
            return 0
        fi
        ui_info "Found $n links — which one is the download link?"
        for ((i=0; i<n; i++)); do
            ui_opt "$((i+1))" "${urls[$i]}"
        done
        while true; do
            bbcode_ask pick "$(ui_prompt "Choose 1-$n" "(blank = 1, 'paste' = again, 'cancel')")" || return 1
            pick=$(bbcode_trim "$pick")
            bbcode_is_cancel "$pick" && return 2
            [ -z "$pick" ] && pick=1
            if [ "${pick,,}" = "paste" ]; then break; fi
            if [[ "$pick" =~ ^[0-9]+$ ]] && [ "$pick" -ge 1 ] && [ "$pick" -le "$n" ]; then
                BB_DOWNLOAD_URL="${urls[$((pick-1))]}"
                return 0
            fi
            bbcode_warn "Please enter a number from 1 to $n."
        done
    done
}

# ---- readable labels for ffprobe codec / container names ----
bbcode_video_codec_label() {
    case "${1,,}" in
        h264) echo "H.264" ;;
        hevc|h265) echo "H.265" ;;
        av1) echo "AV1" ;;
        vp9) echo "VP9" ;;
        vp8) echo "VP8" ;;
        mpeg4) echo "MPEG-4" ;;
        mpeg2video) echo "MPEG-2" ;;
        mpeg1video) echo "MPEG-1" ;;
        vc1) echo "VC-1" ;;
        wmv1|wmv2|wmv3) echo "WMV" ;;
        "") echo "Unknown" ;;
        *) echo "${1^^}" ;;
    esac
}

bbcode_audio_codec_label() {
    case "${1,,}" in
        aac) echo "AAC" ;;
        opus) echo "Opus" ;;
        mp3) echo "MP3" ;;
        mp2) echo "MP2" ;;
        ac3) echo "AC3" ;;
        eac3) echo "E-AC-3" ;;
        dts) echo "DTS" ;;
        truehd) echo "TrueHD" ;;
        flac) echo "FLAC" ;;
        vorbis) echo "Vorbis" ;;
        wmav1|wmav2|wmapro) echo "WMA" ;;
        pcm_*) echo "PCM" ;;
        "") echo "No audio" ;;
        *) echo "${1^^}" ;;
    esac
}

# Container from ffprobe's format_name. The extension is used only to pick
# between formats ffprobe reports as one family (e.g. matroska/webm,
# mov/mp4), or as a last resort when ffprobe returns nothing.
bbcode_container_label() {
    local input_file="$1" log_file="$2" fmt ext
    fmt=$(ffprobe -v error -show_entries format=format_name \
        -of default=noprint_wrappers=1:nokey=1 "$input_file" 2>>"$log_file" | head -n 1)
    ext="${input_file##*.}"
    ext="${ext,,}"
    case ",${fmt}," in
        *,matroska,*|*,webm,*) [ "$ext" = "webm" ] && echo "WEBM" || echo "MKV" ;;
        *,mp4,*|*,mov,*)
            case "$ext" in
                mov) echo "MOV" ;; m4v) echo "M4V" ;; 3gp) echo "3GP" ;;
                3g2) echo "3G2" ;; f4v) echo "F4V" ;; *) echo "MP4" ;;
            esac ;;
        *,avi,*) echo "AVI" ;;
        *,asf,*) [ "$ext" = "wmv" ] && echo "WMV" || echo "ASF" ;;
        *,flv,*) echo "FLV" ;;
        *,mpegts,*) case "$ext" in m2ts|mts) echo "M2TS" ;; *) echo "TS" ;; esac ;;
        *,mpeg,*) [ "$ext" = "vob" ] && echo "VOB" || echo "MPEG" ;;
        *,ogg,*) echo "OGG" ;;
        ",,")
            if [ -n "$ext" ] && [ "$ext" != "${input_file,,}" ]; then echo "${ext^^}"; else echo "Unknown"; fi ;;
        *) fmt="${fmt%%,*}"; echo "${fmt^^}" ;;
    esac
}

# Formats a bitrate in bits/s as a human-readable kb/s value.
# Empty, N/A, or invalid values become Unknown.
bbcode_format_bitrate() {
    local value="$1"
    if [[ "$value" =~ ^[0-9]+([.][0-9]+)?$ ]] && awk -v b="$value" 'BEGIN{exit !(b>0)}'; then
        awk -v b="$value" 'BEGIN { printf "%.0f kb/s", b/1000 }'
    else
        echo "Unknown"
    fi
}

# Converts an FFprobe frame-rate fraction or decimal to a readable FPS value.
bbcode_format_fps() {
    local value="$1"
    awk -v r="$value" 'BEGIN {
        n=split(r,a,"/")
        if (n==2 && a[2]+0>0) f=a[1]/a[2]
        else if (r+0>0) f=r+0
        else { print "Unknown"; exit }
        if (f<=0) print "Unknown"
        else if (f-int(f)<0.0005 || int(f)+1-f<0.0005) printf "%d FPS", int(f+0.5)
        else printf "%.3f FPS", f
    }'
}

# Reads real metadata with ffprobe into BB_* globals. Anything ffprobe
# cannot report becomes "Unknown" — values are not guessed.
bbcode_collect_metadata() {
    local input_file="$1" log_file="$2" dur w h bytes vcodec acodec
    local fps_raw pix_fmt vbitrate abit_rate audio_rate vtag_bps atag_bps

    dur=$(ffprobe -v error -show_entries format=duration \
        -of default=noprint_wrappers=1:nokey=1 "$input_file" 2>>"$log_file" | head -n 1)
    if [[ "$dur" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        BB_DURATION=$(awk -v d="$dur" 'BEGIN {
            d=int(d+0.5); printf "%02d:%02d:%02d", int(d/3600), int((d%3600)/60), int(d%60)
        }')
    else
        BB_DURATION="Unknown"
    fi

    w=$(ffprobe -v error -select_streams v:0 -show_entries stream=width \
        -of default=noprint_wrappers=1:nokey=1 "$input_file" 2>>"$log_file" | head -n 1)
    h=$(ffprobe -v error -select_streams v:0 -show_entries stream=height \
        -of default=noprint_wrappers=1:nokey=1 "$input_file" 2>>"$log_file" | head -n 1)
    if [[ "$w" =~ ^[0-9]+$ && "$h" =~ ^[0-9]+$ && "$h" -gt 0 ]]; then
        BB_RESOLUTION="${w}x${h}"
        BB_RES_LABEL="${h}p"
    else
        BB_RESOLUTION="Unknown"
        BB_RES_LABEL=""
    fi

    bytes=$(wc -c < "$input_file" 2>/dev/null | tr -d '[:space:]')
    if [[ "$bytes" =~ ^[0-9]+$ ]]; then
        # Dynamic unit: KB under 1 MB, MB under 1 GB, otherwise GB (1024 MB -> 1.00 GB; GB gets 2 decimals).
        BB_FILE_SIZE=$(awk -v b="$bytes" 'BEGIN {
            mb = b/1048576
            if (sprintf("%.1f", mb) + 0 >= 1024) printf "%.2f GB", b/1073741824
            else if (mb >= 1)                    printf "%.1f MB", mb
            else                                 printf "%.1f KB", b/1024
        }')
    else
        BB_FILE_SIZE="Unknown"
    fi

    BB_CONTAINER=$(bbcode_container_label "$input_file" "$log_file")
    [ -n "$BB_CONTAINER" ] || BB_CONTAINER="Unknown"

    vcodec=$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name \
        -of default=noprint_wrappers=1:nokey=1 "$input_file" 2>>"$log_file" | head -n 1)
    acodec=$(ffprobe -v error -select_streams a:0 -show_entries stream=codec_name \
        -of default=noprint_wrappers=1:nokey=1 "$input_file" 2>>"$log_file" | head -n 1)
    BB_VCODEC=$(bbcode_video_codec_label "$vcodec")
    BB_ACODEC=$(bbcode_audio_codec_label "$acodec")

    fps_raw=$(ffprobe -v error -select_streams v:0 -show_entries stream=avg_frame_rate \
        -of default=noprint_wrappers=1:nokey=1 "$input_file" 2>>"$log_file" | head -n 1)
    if [ -z "$fps_raw" ] || [ "$fps_raw" = "0/0" ]; then
        fps_raw=$(ffprobe -v error -select_streams v:0 -show_entries stream=r_frame_rate \
            -of default=noprint_wrappers=1:nokey=1 "$input_file" 2>>"$log_file" | head -n 1)
    fi
    BB_FPS=$(bbcode_format_fps "$fps_raw")

    pix_fmt=$(ffprobe -v error -select_streams v:0 -show_entries stream=pix_fmt \
        -of default=noprint_wrappers=1:nokey=1 "$input_file" 2>>"$log_file" | head -n 1)
    BB_PIX_FMT="${pix_fmt:-Unknown}"

    vbitrate=$(ffprobe -v error -select_streams v:0 -show_entries stream=bit_rate \
        -of default=noprint_wrappers=1:nokey=1 "$input_file" 2>>"$log_file" | head -n 1)
    if ! [[ "$vbitrate" =~ ^[0-9]+([.][0-9]+)?$ ]] || [ "$vbitrate" = "0" ]; then
        vtag_bps=$(ffprobe -v error -select_streams v:0 -show_entries stream_tags=BPS \
            -of default=noprint_wrappers=1:nokey=1 "$input_file" 2>>"$log_file" | head -n 1)
        vbitrate="$vtag_bps"
    fi
    BB_VBITRATE=$(bbcode_format_bitrate "$vbitrate")

    audio_rate=$(ffprobe -v error -select_streams a:0 -show_entries stream=sample_rate \
        -of default=noprint_wrappers=1:nokey=1 "$input_file" 2>>"$log_file" | head -n 1)
    if [[ "$audio_rate" =~ ^[0-9]+$ ]] && [ "$audio_rate" -gt 0 ]; then
        BB_ASAMPLE_RATE=$(awk -v r="$audio_rate" 'BEGIN { if (r%1000==0) printf "%.0f kHz", r/1000; else printf "%.1f kHz", r/1000 }')
    else
        BB_ASAMPLE_RATE="Unknown"
    fi

    abit_rate=$(ffprobe -v error -select_streams a:0 -show_entries stream=bit_rate \
        -of default=noprint_wrappers=1:nokey=1 "$input_file" 2>>"$log_file" | head -n 1)
    if ! [[ "$abit_rate" =~ ^[0-9]+([.][0-9]+)?$ ]] || [ "$abit_rate" = "0" ]; then
        atag_bps=$(ffprobe -v error -select_streams a:0 -show_entries stream_tags=BPS \
            -of default=noprint_wrappers=1:nokey=1 "$input_file" 2>>"$log_file" | head -n 1)
        abit_rate="$atag_bps"
    fi
    BB_ABITRATE=$(bbcode_format_bitrate "$abit_rate")
}

# ---- tag rules (edit these to change how tags are built) ----

bbcode_tags_add() {
    local t e
    t=$(bbcode_trim "$1")
    [ -n "$t" ] || return 0
    for e in ${BB_TAG_LIST[@]+"${BB_TAG_LIST[@]}"}; do
        [ "${e,,}" = "${t,,}" ] && return 0      # case-insensitive duplicate
    done
    BB_TAG_LIST+=("$t")
}

# Episode rules, tried in order. If none matches, no episode tags are added.
#   "#07 Title" / "#07"        -> #07, Title, E07
#   "07 - Title" / "07_Title"  -> #07, Title, E07
#   "...S01E07..."             -> full name, S01E07
#   "...Ep 7..." / "...E07..." -> full name, E7 / E07
# Sets BB_EP_NUM, BB_EP_HASH, BB_EP_TAG and BB_TITLE_TAG.
bbcode_parse_episode() {
    local name="$1"
    BB_EP_NUM=""; BB_EP_HASH=""; BB_EP_TAG=""; BB_TITLE_TAG="$name"
    if [[ "$name" =~ ^#([0-9]+)([[:space:]._-]+(.*))?$ ]]; then
        BB_EP_NUM="${BASH_REMATCH[1]}"
        BB_TITLE_TAG="${BASH_REMATCH[3]:-}"
        BB_EP_HASH="#${BB_EP_NUM}"
        BB_EP_TAG="E${BB_EP_NUM}"
    elif [[ "$name" =~ ^([0-9]{1,3})[[:space:]]*[-_.][[:space:]_.-]*(.+)$ ]]; then
        BB_EP_NUM="${BASH_REMATCH[1]}"
        BB_TITLE_TAG="${BASH_REMATCH[2]}"
        BB_EP_HASH="#${BB_EP_NUM}"
        BB_EP_TAG="E${BB_EP_NUM}"
    elif [[ "$name" =~ [Ss][0-9]{1,2}[Ee]([0-9]{1,3}) ]]; then
        BB_EP_NUM="${BASH_REMATCH[1]}"
        BB_EP_TAG="${BASH_REMATCH[0]^^}"
    elif [[ "$name" =~ (^|[^[:alnum:]])[Ee]([Pp]|[Pp][Ii][Ss][Oo][Dd][Ee])?[[:space:]._-]?([0-9]{1,3})([^[:alnum:]]|$) ]]; then
        BB_EP_NUM="${BASH_REMATCH[3]}"
        BB_EP_TAG="E${BB_EP_NUM}"
    fi
    BB_TITLE_TAG="${BB_TITLE_TAG//_/ }"
    BB_TITLE_TAG=$(bbcode_trim "$BB_TITLE_TAG")
}

# Builds BB_TAGS: fixed tags, filename tags, episode tag, real resolution
# label, real container. Duplicates are dropped (case-insensitive).
bbcode_build_tags() {
    local name="$1" t
    local fixed=()
    BB_TAG_LIST=()
    IFS=',' read -ra fixed <<< "$BBCODE_FIXED_TAGS"
    for t in ${fixed[@]+"${fixed[@]}"}; do bbcode_tags_add "$t"; done
    bbcode_parse_episode "$name"
    bbcode_tags_add "$BB_EP_HASH"
    bbcode_tags_add "$BB_TITLE_TAG"
    bbcode_tags_add "$BB_EP_TAG"
    bbcode_tags_add "$BB_RES_LABEL"
    [ "$BB_CONTAINER" = "Unknown" ] || bbcode_tags_add "$BB_CONTAINER"
    BB_TAGS=""
    for t in ${BB_TAG_LIST[@]+"${BB_TAG_LIST[@]}"}; do
        BB_TAGS+="${BB_TAGS:+, }${t}"
    done
}

# Prints the finished BBCode post to stdout (used for both the on-screen
# review and the saved file, so they can never differ).
bbcode_render_post() {
    local res_display="$BB_RESOLUTION"
    [ -n "$BB_RES_LABEL" ] && res_display="${BB_RESOLUTION} (${BB_RES_LABEL})"
    printf '[INDENT][FONT=%s][COLOR=%s]\n' "$BBCODE_FONT" "$BBCODE_COLOR"
    printf '[SIZE=6][B]%s[/B][/SIZE]\n\n' "$BB_TITLE"
    printf '[URL=%s][IMG]%s[/IMG][/URL]\n\n' "$BB_IMAGE_LINK" "$BB_IMAGE_URL"
    printf '[SIZE=4]\n'
    printf '[B]Duration:[/B] %s\n' "$BB_DURATION"
    printf '[B]Resolution:[/B] %s\n' "$res_display"
    printf '[B]File Size:[/B] %s\n' "$BB_FILE_SIZE"
    printf '[B]Container Format:[/B] %s\n' "$BB_CONTAINER"
    local video_fps="${BB_FPS% FPS}"
    local video_bit_depth="Unknown"
    if [[ "$BB_PIX_FMT" =~ (10|12|14|16|f16|f32) ]]; then
        video_bit_depth="${BASH_REMATCH[1]}bit"
        [[ "$video_bit_depth" == "f16bit" ]] && video_bit_depth="16bit"
        [[ "$video_bit_depth" == "f32bit" ]] && video_bit_depth="32bit"
    elif [[ "$BB_PIX_FMT" =~ ^(yuv420p|yuv422p|yuv444p|nv12|nv21|rgb24|bgr24|yuyv422|uyvy422)$ ]]; then
        video_bit_depth="8bit"
    fi
    printf '[B]Video:[/B] %s, %sfps, %s, %s\n' "$BB_VCODEC" "$video_fps" "$video_bit_depth" "$BB_VBITRATE"
    printf '[B]Audio:[/B] %s, %s, %s\n' "$BB_ACODEC" "$BB_ASAMPLE_RATE" "$BB_ABITRATE"
    printf '[/SIZE]\n\n'
    printf '[SIZE=6][B][URL=%s]DOWNLOAD VIDEO[/URL][/B][/SIZE]\n\n\n' "$BB_DOWNLOAD_URL"
    printf '[B]Tags:[/B] %s\n' "$BB_TAGS"
    printf '[/COLOR][/FONT][/INDENT]\n'
}

# Writes the post to $1 via a temp file. Asks before overwriting; never
# overwrites silently. Returns 0 if saved, 1 if not (declined / failed).
bbcode_save_post() {
    local target="$1" tmp
    # Overwrite is already announced in the review menu ("will be
    # overwritten"), so choosing Save is the confirmation - no second prompt.
    tmp=$(mktemp "${target}.XXXXXX" 2>/dev/null) || {
        ui_err "Could not create a file in: $(dirname -- "$target")"
        return 1
    }
    if bbcode_render_post > "$tmp" 2>/dev/null && [ -s "$tmp" ] && mv -f "$tmp" "$target" 2>/dev/null; then
        ui_ok "BBCode post saved"
        ui_note "$target"
        return 0
    fi
    rm -f "$tmp"
    ui_err "Could not write BBCode file: $target"
    return 1
}

# Edit menu: fixes one user-entered detail, then returns so the post is
# regenerated and shown again. Returns 0 normally, 1 if input is closed.
bbcode_edit_details() {
    local choice val rc
    while true; do
        ui_section "Edit which detail?"
        ui_opt 1 "Title"
        ui_opt 2 "Image link"
        ui_opt 3 "Download URL"
        ui_opt 4 "Tags"
        ui_opt 5 "Back to review"
        bbcode_ask choice "$(ui_prompt "Choose" "(1-5, blank = 5)")" || return 1
        case "$(bbcode_trim "$choice")" in
            1)
                bbcode_ask val "$(ui_prompt "Post title" "[${BB_TITLE}]")" || return 1
                val=$(bbcode_trim "$val")
                [ -n "$val" ] && BB_TITLE="$val"
                return 0 ;;
            2)
                bbcode_prompt_image_link; rc=$?
                [ "$rc" -eq 1 ] && return 1
                [ "$rc" -eq 2 ] && bbcode_warn "Image link left unchanged."
                return 0 ;;
            3)
                bbcode_prompt_download_url; rc=$?
                [ "$rc" -eq 1 ] && return 1
                [ "$rc" -eq 2 ] && bbcode_warn "Download URL left unchanged."
                return 0 ;;
            4)
                ui_kv "Tags" "$BB_TAGS"
                bbcode_ask val "$(ui_prompt "New tags, comma-separated" "(blank = keep, 'reset' = auto)")" || return 1
                val=$(bbcode_trim "$val")
                if [ "${val,,}" = "reset" ]; then
                    bbcode_build_tags "$BB_NAME_NOEXT"
                elif [ -n "$val" ]; then
                    BB_TAGS="$val"
                fi
                return 0 ;;
            5|"") return 0 ;;
            *) bbcode_warn "Please choose 1-5." ;;
        esac
    done
}

# ------------------------------------------------------------
# FUNCTION: write_bbcode_metadata
# Generates the BBCode post for one video and saves it as
# <video name>_bbcode.txt in the video's output folder (beside the
# previews / contact sheet). A failure here never stops the script.
# $1 = input video, $2 = output folder, $3 = log file,
# $4 = "true" when called from a batch run (optional)
# ------------------------------------------------------------
declare -g BB_NAME_NOEXT=""
write_bbcode_metadata() {
    [ "${GENERATE_BBCODE,,}" = "yes" ] || return 0
    [ "$BBCODE_SKIP_ALL" = "yes" ] && return 0

    local input_file="$1" output_folder="$2" log_file="$3" batch_mode="${4:-false}"
    local filename bbcode_file choice rc dep

    for dep in ffprobe grep sed tr wc awk head; do
        if ! command -v "$dep" >/dev/null 2>&1; then
            ui_warn "BBCode skipped: required tool '$dep' is not installed."
            return 1
        fi
    done
    if [ ! -r "$input_file" ]; then
        ui_warn "BBCode skipped: cannot read $input_file"
        return 1
    fi

    filename=$(basename -- "$input_file")
    BB_NAME_NOEXT="${filename%.*}"
    bbcode_file="$output_folder/${BB_NAME_NOEXT}_bbcode.txt"

    ui_section "BBCode post"
    local gate_hint="[Y/n]"
    [ "$batch_mode" = "true" ] && gate_hint="[Y/n/s = skip all]"
    bbcode_ask choice "$(ui_prompt "Create a BBCode post for $filename?" "$gate_hint")" || return 1
    case "${choice,,}" in
        n|no) ui_note "BBCode skipped for this video."; return 0 ;;
        s|skip) BBCODE_SKIP_ALL="yes"; ui_note "BBCode skipped for all remaining videos."; return 0 ;;
    esac

    bbcode_collect_metadata "$input_file" "$log_file"
    local missing=()
    [ "$BB_DURATION" = "Unknown" ] && missing+=("duration")
    [ "$BB_RESOLUTION" = "Unknown" ] && missing+=("resolution")
    [ "$BB_CONTAINER" = "Unknown" ] && missing+=("container")
    [ "$BB_VCODEC" = "Unknown" ] && missing+=("video codec")
    [ "$BB_FILE_SIZE" = "Unknown" ] && missing+=("file size")
    if [ ${#missing[@]} -gt 0 ]; then
        bbcode_warn "Could not read: ${missing[*]} — these will show as Unknown in the post."
    fi

    # Title defaults to the filename (no extension); Enter keeps it.
    BB_TITLE="$BB_NAME_NOEXT"
    local val
    bbcode_ask val "$(ui_prompt "Post title" "[${BB_TITLE}]")" || return 1
    val=$(bbcode_trim "$val")
    [ -n "$val" ] && BB_TITLE="$val"

    bbcode_prompt_image_link; rc=$?
    if [ "$rc" -eq 2 ]; then ui_note "BBCode generation cancelled."; return 0; fi
    if [ "$rc" -ne 0 ]; then bbcode_warn "BBCode skipped: no input received."; return 1; fi

    bbcode_prompt_download_url; rc=$?
    if [ "$rc" -eq 2 ]; then ui_note "BBCode generation cancelled."; return 0; fi
    if [ "$rc" -ne 0 ]; then bbcode_warn "BBCode skipped: no input received."; return 1; fi

    bbcode_build_tags "$BB_NAME_NOEXT"

    # Review: show the generated post, then Copy / Edit / Cancel.
    # No file is written; "Copy" puts the post on the clipboard.
    local redraw=1
    while true; do
        if [ "$redraw" = 1 ]; then
            ui_section "BBCode post preview"
            echo -e " ${COLOR_GRAY}${UI_RULE}${COLOR_RESET}"
            bbcode_render_post
            echo -e " ${COLOR_GRAY}${UI_RULE}${COLOR_RESET}"
            ui_opt 1 "Copy to clipboard"
            ui_opt 2 "Edit"
            ui_opt 3 "Cancel"
        fi
        redraw=1
        bbcode_ask choice "$(ui_prompt "Choose" "(1-3, blank = 1)")" || { bbcode_warn "BBCode skipped: no input received."; return 1; }
        case "$(bbcode_trim "$choice")" in
            1|"")
                if command -v termux-clipboard-set >/dev/null 2>&1; then
                    # Render once and feed it via a here-string (no pipe, so
                    # pipefail/SIGPIPE can't turn a good copy into a "failure").
                    local post copy_rc=0 got
                    post=$(bbcode_render_post)
                    termux-clipboard-set <<< "$post" >/dev/null 2>&1 || copy_rc=$?
                    if [ "$copy_rc" -ne 0 ] && command -v termux-clipboard-get >/dev/null 2>&1; then
                        # Non-zero exit but the text may still have landed - verify.
                        got=$(termux-clipboard-get 2>/dev/null)
                        [ "$got" = "$post" ] && copy_rc=0
                    fi
                    if [ "$copy_rc" -eq 0 ]; then
                        ui_ok "Copied to clipboard"
                        return 0
                    fi
                    bbcode_warn "Could not copy to the clipboard (exit $copy_rc). Try again, edit, or cancel."
                else
                    bbcode_warn "termux-clipboard-set not found - install Termux:API to enable clipboard copy."
                fi
                ;;
            2) bbcode_edit_details || { bbcode_warn "BBCode skipped: no input received."; return 1; } ;;
            3) ui_note "BBCode generation cancelled."; return 0 ;;
            *) bbcode_warn "Please choose 1, 2, or 3."; redraw=0 ;;
        esac
    done
}

# ------------------------------------------------------------
# FUNCTION: media_scan_file — tells Android's media database about a
# new file so gallery / media pickers see it immediately. Uses
# termux-media-scan (Termux:API) when available, else a media-scanner
# broadcast. Best effort: never fails the run.
# $1 = file path
# ------------------------------------------------------------
media_scan_file() {
    local f="$1"
    [ -f "$f" ] || return 0
    if command -v termux-media-scan >/dev/null 2>&1; then
        termux-media-scan "$f" >/dev/null 2>&1 && return 0
    fi
    if command -v am >/dev/null 2>&1; then
        am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE \
            -d "file://$f" >/dev/null 2>&1 || true
    fi
    return 0
}

# ------------------------------------------------------------
# FUNCTION: delete_output_folder — removes one per-video output folder
# (refuses anything that is not inside OUTPUT_DIR), then tells Android's
# media database the deleted images are gone. Best effort for the scan.
# $1 = folder
# ------------------------------------------------------------
delete_output_folder() {
    local dir="$1" base real f
    local gone=()
    base=$(realpath -m "$OUTPUT_DIR")
    real=$(realpath -m "$dir")
    if [ -z "$real" ] || [ "$real" = "$base" ] || [[ "$real" != "$base"/* ]]; then
        ui_err "Refusing to delete (not a folder inside $base):"
        ui_note "$dir"
        return 1
    fi
    [ -d "$real" ] || return 0
    while IFS= read -r -d '' f; do gone+=("$f"); done < <(find "$real" -type f -print0 2>/dev/null)
    if rm -rf -- "$real" 2>/dev/null && [ ! -e "$real" ]; then
        ui_ok "Deleted ${COLOR_GRAY}$real${COLOR_RESET}"
        unmark_completed "${CLEANUP_MARKERS[$dir]:-}"
        if command -v termux-media-scan >/dev/null 2>&1 && [ ${#gone[@]} -gt 0 ]; then
            termux-media-scan "${gone[@]}" >/dev/null 2>&1 || true
        fi
        return 0
    fi
    ui_warn "Could not fully delete: $real"
    return 1
}

# ------------------------------------------------------------
# FUNCTION: offer_cleanup_folders — asked once at the end of a run,
# before the "process another / main menu / exit" menu. Lists the
# per-video output folders created in this run (previews, contact sheet,
# BBCode file) and asks whether to delete them. Default (blank) is delete.
# ------------------------------------------------------------
declare -ga CLEANUP_DIRS=()
offer_cleanup_folders() {
    [ ${#CLEANUP_DIRS[@]} -gt 0 ] || return 0
    local d n answer
    ui_section "Clean up"
    ui_warn "Delete the output folder(s) created in this run?"
    ui_note "Everything inside is removed: previews, contact sheet and BBCode file."
    for d in "${CLEANUP_DIRS[@]}"; do
        n=$(find "$d" -type f 2>/dev/null | wc -l)
        echo -e "   ${COLOR_GRAY}•${COLOR_RESET} $d ${COLOR_GRAY}($n file(s))${COLOR_RESET}"
    done
    echo ""
    ui_opt y "Delete all"
    ui_opt e "Ask for each"
    ui_opt n "Keep"
    if read -r -p "$(ui_prompt "Choose" "(blank = y)")" answer; then
        answer="${answer:-y}"
        case "${answer,,}" in
            y|yes)
                for d in "${CLEANUP_DIRS[@]}"; do delete_output_folder "$d" || true; done ;;
            e)
                for d in "${CLEANUP_DIRS[@]}"; do
                    read -r -p "$(ui_prompt "Delete $d ?" "[y/N]")" answer || break
                    [[ "$answer" =~ ^[Yy]$ ]] && { delete_output_folder "$d" || true; }
                done ;;
            *) ui_note "Folders kept." ;;
        esac
    else
        echo ""
    fi
    CLEANUP_DIRS=()
}

process_file() {
    local input_file
    input_file=$(realpath "$1")
    local requested_count="$2"
    local relative_dir="${3:-}"
    local batch_mode="${4:-false}"
    local filename
    filename=$(basename -- "$input_file")
    local filename_noext="${filename%.*}"

    local marker_key="${input_file}|count=${requested_count}|width=${PREVIEW_WIDTH}|fmt=${PREVIEW_FORMAT}|ts=${TIMESTAMP_EFFECTIVE}|tsfont=${PREVIEW_TS_FONTSIZE}|out=${OUTPUT_MODE}|sheet=${CONTACT_SHEET,,}-${CONTACT_SHEET_COLUMNS}-sheetts${SHEET_TIMESTAMP_EFFECTIVE}-sheetfont${SHEET_TS_FONTSIZE}"
    if [ "$batch_mode" = "true" ] && is_completed "$marker_key"; then
        echo -e " ${COLOR_GRAY}↷${COLOR_RESET} $filename ${COLOR_GRAY}(already extracted)${COLOR_RESET}"
        ((SKIPPED++))
        return 0
    fi

    local base_output_dir="$OUTPUT_DIR"
    local log_dir="$LOG_DIR"
    if [ -n "$relative_dir" ] && [ "$relative_dir" != "." ]; then
        base_output_dir="$OUTPUT_DIR/$relative_dir"
        log_dir="$LOG_DIR/$relative_dir"
    fi
    local video_output_dir="$base_output_dir/$filename_noext"
    mkdir -p "$video_output_dir" "$log_dir"

    local LOG_FILE
    LOG_FILE=$(realpath -m "$log_dir/${filename_noext}.log")
    > "$LOG_FILE"

    echo ""
    echo -e " ${COLOR_ORANGE}▶${COLOR_RESET} ${COLOR_WHITE}$filename${COLOR_RESET}"

    # ---- duration ----
    local duration
    duration=$(ffprobe -v error -show_entries format=duration \
        -of default=noprint_wrappers=1:nokey=1 "$input_file" 2>>"$LOG_FILE")
    if ! [[ "$duration" =~ ^[0-9]+(\.[0-9]+)?$ ]] || awk -v d="$duration" 'BEGIN{exit !(d<=0)}'; then
        ui_err "Couldn't read the video duration ${COLOR_GRAY}(see $LOG_FILE)${COLOR_RESET}"
        ((FAILED++))
        return 1
    fi

    # ---- frame rate -> this video's max possible preview count ----
    local fps_raw fps max_frames
    fps_raw=$(ffprobe -v error -select_streams v:0 -show_entries stream=r_frame_rate \
        -of default=noprint_wrappers=1:nokey=1 "$input_file" 2>>"$LOG_FILE")
    fps=$(awk -F'/' -v r="$fps_raw" 'BEGIN{
        n=split(r,a,"/")
        if (n==2 && a[2]+0>0) printf "%.6f", a[1]/a[2]
        else if (r+0>0) printf "%.6f", r
        else print "0"
    }')
    max_frames=$(awk -v d="$duration" -v f="$fps" 'BEGIN{printf "%d", d*f}')

    local count="$requested_count"
    if [ "$max_frames" -gt 0 ] && [ "$count" -gt "$max_frames" ]; then
        ui_warn "Asked for $count previews, but this video only has ~$max_frames frames — using $max_frames"
        count="$max_frames"
    fi
    if [ "$count" -lt 1 ]; then
        ui_err "Video too short to extract any previews"
        ((FAILED++))
        return 1
    fi

    ui_kv "Duration" "$(human_duration "$duration")"
    ui_kv "Previews" "$count"

    local scale_filter=""
    if [ -n "$PREVIEW_WIDTH" ] && [ "$PREVIEW_WIDTH" -gt 0 ] 2>/dev/null; then
        scale_filter="scale=${PREVIEW_WIDTH}:-2"
    fi
    local quality_args=()
    [ "$PREVIEW_FORMAT" = "jpg" ] && quality_args=(-q:v "$PREVIEW_QUALITY")

    # Sheet-only mode: frames go into a hidden throwaway folder and are
    # deleted once the contact sheet is built. Otherwise they are the
    # final previews and live directly in the video's output folder.
    local frames_dir="$video_output_dir"
    if [ "$KEEP_PREVIEWS" != "yes" ]; then
        frames_dir=$(mktemp -d "$video_output_dir/.frames_XXXXXX") || {
            ui_err "Couldn't create a temp folder for the frames"
            ((FAILED++))
            return 1
        }
    fi

    local pad=${#count}
    local extracted=0
    local extracted_files=()
    local extracted_meta=()
    local i ts ts_label h m s ts_display num out_file vf_value vf_args
    ui_progress 0 "$count"

    for ((i = 0; i < count; i++)); do
        # Midpoint of the i-th of `count` equal time segments — spreads
        # previews evenly across the whole duration without landing
        # exactly on frame 0 or the very last frame.
        ts=$(awk -v d="$duration" -v k="$count" -v idx="$i" -v f="$fps" 'BEGIN{
            seg = d / k
            t = seg * (idx + 0.5)
            margin = d * 0.01
            if (margin > 0.05) margin = 0.05
            if (f > 0 && (1 / f) > margin) margin = 1 / f
            if (t > d - margin) t = d - margin
            if (t < 0) t = 0
            printf "%.3f", t
        }')
        read -r h m s <<< "$(awk -v t="$ts" 'BEGIN{h=int(t/3600); m=int((t%3600)/60); s=int(t%60); printf "%d %d %d", h, m, s}')"
        ts_label=$(printf "%02dh%02dm%02ds" "$h" "$m" "$s")
        num=$(printf "%0${pad}d" $((i + 1)))
        out_file="$frames_dir/${filename_noext}_${num}_${ts_label}.${PREVIEW_FORMAT}"
        CURRENT_OUTPUT_FILE="$out_file"

        vf_value="$scale_filter"
        if [ "$TIMESTAMP_EFFECTIVE" = "true" ]; then
            # Colons must be backslash-escaped inside a drawtext text= value
            ts_display=$(printf "%02d\\:%02d\\:%02d" "$h" "$m" "$s")
            local dt="drawtext=fontfile='${RESOLVED_FONT}':text='${ts_display}':x=w-text_w-10:y=h-text_h-10:fontsize=${PREVIEW_TS_FONTSIZE}:fontcolor=white:box=1:boxcolor=black@0.5:boxborderw=6"
            if [ -n "$vf_value" ]; then vf_value="${vf_value},${dt}"; else vf_value="$dt"; fi
        fi
        vf_args=()
        [ -n "$vf_value" ] && vf_args=(-vf "$vf_value")

        if run_ffmpeg ffmpeg -y -ss "$ts" -i "$input_file" -frames:v 1 \
            "${vf_args[@]}" "${quality_args[@]}" \
            "$out_file" >>"$LOG_FILE" 2>&1 && [ -s "$out_file" ]; then
            ((extracted++))
            extracted_files+=("$out_file")
            extracted_meta+=("${ts}|${h}|${m}|${s}")
        else
            ui_progress_clear
            ui_warn "Frame $num failed ${COLOR_GRAY}(see $LOG_FILE)${COLOR_RESET}"
            rm -f "$out_file"
        fi
        CURRENT_OUTPUT_FILE=""
        ui_progress $((i + 1)) "$count"
    done
    ui_progress_clear

    if [ "$extracted" -eq 0 ]; then
        ui_err "No previews could be extracted from $filename"
        [ "$frames_dir" != "$video_output_dir" ] && rm -rf "$frames_dir"
        rmdir "$video_output_dir" 2>/dev/null
        ((FAILED++))
        return 1
    fi

    if [ "$KEEP_PREVIEWS" = "yes" ]; then
        local size
        size=$(du -sh "$video_output_dir" 2>/dev/null | cut -f1)
        ui_ok "Saved $extracted/$count previews ${COLOR_GRAY}($size)${COLOR_RESET}"
        ui_note "$video_output_dir"
    else
        ui_ok "Extracted $extracted/$count frames for the contact sheet"
    fi

    if [ "${CONTACT_SHEET,,}" = "yes" ]; then
        local sheet_file
        sheet_file=$(realpath -m "${video_output_dir}/${filename_noext}_contact_sheet.${PREVIEW_FORMAT}")

        local sheet_source_files=()
        local sheet_temp_dir=""

        if [ "$SHEET_TIMESTAMP_EFFECTIVE" = "$TIMESTAMP_EFFECTIVE" ] && { [ "$SHEET_TIMESTAMP_EFFECTIVE" != "true" ] || [ "$SHEET_TS_FONTSIZE" = "$PREVIEW_TS_FONTSIZE" ]; }; then
            # Sheet wants the same timestamp state the previews already
            # have — just reuse those files, no extra work needed.
            sheet_source_files=("${extracted_files[@]}")
        else
            # Sheet wants a different timestamp state than the previews.
            # A burned-in overlay can't be stripped back off, so render a
            # separate set of frames at the same timestamps, just for the
            # sheet, in a throwaway temp dir.
            sheet_temp_dir=$(mktemp -d "${video_output_dir}/.sheet_src_XXXXXX")
            local si=0 s_meta s_ts s_h s_m s_s s_num s_out s_vf s_vf_args s_dt s_ts_display
            for s_meta in "${extracted_meta[@]}"; do
                IFS='|' read -r s_ts s_h s_m s_s <<< "$s_meta"
                s_num=$(printf "%0${pad}d" $((si + 1)))
                s_out="${sheet_temp_dir}/sframe_${s_num}.${PREVIEW_FORMAT}"

                s_vf="$scale_filter"
                if [ "$SHEET_TIMESTAMP_EFFECTIVE" = "true" ]; then
                    s_ts_display=$(printf "%02d\\:%02d\\:%02d" "$s_h" "$s_m" "$s_s")
                    s_dt="drawtext=fontfile='${RESOLVED_FONT}':text='${s_ts_display}':x=w-text_w-10:y=h-text_h-10:fontsize=${SHEET_TS_FONTSIZE}:fontcolor=white:box=1:boxcolor=black@0.5:boxborderw=6"
                    if [ -n "$s_vf" ]; then s_vf="${s_vf},${s_dt}"; else s_vf="$s_dt"; fi
                fi
                s_vf_args=()
                [ -n "$s_vf" ] && s_vf_args=(-vf "$s_vf")

                if run_ffmpeg ffmpeg -y -ss "$s_ts" -i "$input_file" -frames:v 1 \
                    "${s_vf_args[@]}" "${quality_args[@]}" \
                    "$s_out" >>"$LOG_FILE" 2>&1 && [ -s "$s_out" ]; then
                    sheet_source_files+=("$s_out")
                fi
                ((si++))
            done
        fi

        if [ ${#sheet_source_files[@]} -gt 0 ]; then
            build_contact_sheet "$sheet_file" "$LOG_FILE" "$CONTACT_SHEET_COLUMNS" "${sheet_source_files[@]}" || true
        else
            ui_warn "Couldn't prepare frames for the contact sheet"
        fi

        [ -n "$sheet_temp_dir" ] && rm -rf "$sheet_temp_dir"

        # Sheet-only: drop the individual frames once the sheet exists.
        # If the sheet failed, keep them so the work isn't lost.
        if [ "$KEEP_PREVIEWS" != "yes" ]; then
            if [ -s "$sheet_file" ]; then
                rm -rf "$frames_dir"
            else
                ui_warn "Sheet wasn't created — keeping the extracted frames in:"
                ui_note "$frames_dir"
            fi
        fi

        # Register the finished sheet with Android's media database so
        # gallery / media pickers see it immediately.
        media_scan_file "$sheet_file"
    fi

    # Generate BBCode metadata beside the previews or contact sheet.
    # Also works in contact-sheet-only mode after temporary frames are removed.
    write_bbcode_metadata "$input_file" "$video_output_dir" "$LOG_FILE" "$batch_mode" || true

    # Remember every finished output folder (previews, contact sheet and/or
    # BBCode file) so the end-of-run prompt can offer to delete them.
    if [ -d "$video_output_dir" ]; then
        local q already=0
        for q in ${CLEANUP_DIRS[@]+"${CLEANUP_DIRS[@]}"}; do [ "$q" = "$video_output_dir" ] && already=1; done
        [ "$already" -eq 1 ] || CLEANUP_DIRS+=("$video_output_dir")
        CLEANUP_MARKERS["$video_output_dir"]="$marker_key"
    fi

    # Completion markers are only for batch runs. Single-video mode
    # always reprocesses the selected video and never consults markers.
    if [ "$batch_mode" = "true" ]; then
        mark_completed "$marker_key"
    fi
    ((SUCCEEDED++))
    return 0
}

# ------------------------------------------------------------
# FUNCTION: process_all_files — recursive batch scan of a
# directory, pruning chunks_* temp folders, mirroring the
# input's subfolder structure into OUTPUT_DIR and LOG_DIR.
# Same requested preview count is applied to every video found
# (each clamped to its own max, individually).
# ------------------------------------------------------------
process_all_files() {
    local input_dir
    input_dir=$(realpath "$1")
    local requested_count="$2"
    local input_dir_clean="${input_dir%/}"

    local files=()
    while IFS= read -r -d '' f; do
        files+=("$f")
    done < <(find "$input_dir" \
        \( -type d -iname "chunks_*" -prune \) -o \
        \( -type f \( \
        -iname "*.mp4" -o -iname "*.mkv" -o -iname "*.mov" -o -iname "*.avi" -o \
        -iname "*.webm" -o -iname "*.wmv" -o -iname "*.flv" -o -iname "*.mpeg" -o \
        -iname "*.mpg" -o -iname "*.mpe" -o -iname "*.m4v" -o -iname "*.3gp" -o \
        -iname "*.3g2" -o -iname "*.f4v" -o -iname "*.ts" -o -iname "*.m2ts" -o \
        -iname "*.mts" -o -iname "*.vob" \) -printf "%p\0" \))

    if [ ${#files[@]} -eq 0 ]; then
        ui_err "No video files found in:"
        ui_note "$input_dir"
        return 1
    fi

    mapfile -d '' files < <(printf '%s\0' "${files[@]}" | sort -zV)

    ui_section "Batch"
    ui_info "Found ${COLOR_WHITE}${#files[@]}${COLOR_RESET} video file(s) in"
    ui_note "$input_dir"

    for input_file in "${files[@]}"; do
        local relative_path="${input_file#"$input_dir_clean"/}"
        local relative_dir
        relative_dir="$(dirname "$relative_path")"

        if [ "$relative_dir" = "." ]; then
            process_file "$input_file" "$requested_count" "" true || true
        else
            process_file "$input_file" "$requested_count" "$relative_dir" true || true
        fi
    done
}


# ------------------------------------------------------------
# FUNCTION: build_sheet_from_existing_folder
# Creates a contact sheet from preview images already on disk.
# Existing images are used as-is; timestamps cannot be added here.
# ------------------------------------------------------------
build_sheet_from_existing_folder() {
    local source_dir="$1"
    local cols="$2"
    source_dir=$(realpath "$source_dir") || return 1
    [ -d "$source_dir" ] || { ui_err "Folder doesn't exist: $source_dir"; return 1; }

    local images=() f base sheet_file log_file temp_dir converted=() num
    while IFS= read -r -d '' f; do
        images+=("$f")
    done < <(find "$source_dir" -maxdepth 1 -type f \
        \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.webp' \) \
        ! -iname '*_contact_sheet.*' -print0 | sort -zV)

    if [ ${#images[@]} -eq 0 ]; then
        ui_err "No supported preview images found in: $source_dir"
        ui_note "Supported formats: JPG, JPEG, PNG, WEBP"
        return 1
    fi

    # Normalize mixed source formats to JPG in a temporary folder so the
    # image sequence remains valid regardless of each original extension.
    PREVIEW_FORMAT="jpg"
    base=$(basename "$source_dir")
    sheet_file="$source_dir/${base}_contact_sheet.jpg"
    log_file="$LOG_DIR/${base}_existing_sheet.log"
    mkdir -p "$LOG_DIR"
    : > "$log_file"
    temp_dir=$(mktemp -d "$source_dir/.existing_sheet_src_XXXXXX") || return 1

    ui_info "Found ${#images[@]} existing preview image(s)"
    ui_warn "Timestamps can't be added in this mode — existing images are used as-is (apart from format normalization)."

    num=0
    for f in "${images[@]}"; do
        ((num+=1))
        local converted_file
        converted_file=$(printf '%s/frame_%06d.jpg' "$temp_dir" "$num")
        if ! run_ffmpeg ffmpeg -y -i "$f" -frames:v 1 "$converted_file" >>"$log_file" 2>&1 || [ ! -s "$converted_file" ]; then
            ui_warn "Skipping unreadable image: $(basename "$f")"
            rm -f "$converted_file"
            continue
        fi
        converted+=("$converted_file")
    done

    if [ ${#converted[@]} -eq 0 ]; then
        rm -rf "$temp_dir"
        ui_err "Couldn't read any preview images ${COLOR_GRAY}(see $log_file)${COLOR_RESET}"
        return 1
    fi

    build_contact_sheet "$sheet_file" "$log_file" "$cols" "${converted[@]}"
    local result=$?
    rm -rf "$temp_dir"
    return "$result"
}

# ===========================================================================
# MAIN
# ===========================================================================
mkdir -p "$LOG_DIR" "$COMPLETED_DIR"

ui_banner "Video Frame Extractor" "Previews & contact sheets"

check_dependencies

# Choose the workflow before asking extraction-specific questions.
while true; do
    ui_section "Mode"
    ui_opt 1 "Extract previews from video(s)"
    ui_opt 2 "Build a contact sheet from an existing preview folder"
    echo ""
    read -r -p "$(ui_prompt "Choose" "(blank = 1)")" RUN_MODE
    RUN_MODE=${RUN_MODE:-1}
    case "$RUN_MODE" in
        1) break ;;
        2)
            while true; do
                while true; do
                    read -r -p "$(ui_prompt "Folder with the existing preview images")" EXISTING_PREVIEW_DIR
                    [ -n "$EXISTING_PREVIEW_DIR" ] && break
                    ui_warn "Please enter a folder path — there's no default."
                done
                while true; do
                    read -r -p "$(ui_prompt "Contact sheet columns" "($CONTACT_SHEET_MIN_COLUMNS-$CONTACT_SHEET_MAX_COLUMNS, default $CONTACT_SHEET_COLUMNS)")" EXISTING_SHEET_COLUMNS
                    EXISTING_SHEET_COLUMNS=${EXISTING_SHEET_COLUMNS:-$CONTACT_SHEET_COLUMNS}
                    if [[ "$EXISTING_SHEET_COLUMNS" =~ ^[0-9]+$ ]] && [ "$EXISTING_SHEET_COLUMNS" -ge "$CONTACT_SHEET_MIN_COLUMNS" ] && [ "$EXISTING_SHEET_COLUMNS" -le "$CONTACT_SHEET_MAX_COLUMNS" ]; then
                        break
                    fi
                    ui_err "Enter a number from $CONTACT_SHEET_MIN_COLUMNS to $CONTACT_SHEET_MAX_COLUMNS"
                done
                build_sheet_from_existing_folder "$EXISTING_PREVIEW_DIR" "$EXISTING_SHEET_COLUMNS"
                status=$?
                echo ""
                ui_opt 1 "Process another folder" "same settings"
                ui_opt 2 "Main menu"
                ui_opt 3 "Exit"
                read -r -p "$(ui_prompt "Choose" "(blank = 1)")" next_action
        next_action="${next_action:-1}"
                case "$next_action" in
                    1) continue ;;
                    2) exec "$0" ;;
                    3) exit "$status" ;;
                    *) ui_warn "Please enter 1, 2 or 3." ;;
                esac
            done
            ;;
        *) ui_warn "Please enter 1 or 2." ;;
    esac
done

REQUESTED_COUNT=""
INPUT_PATH=""
CLI_WIDTH=""
CLI_FORMAT=""
CLI_QUALITY=""
CLI_TIMESTAMP=""
CLI_CONTACT_SHEET=""
CLI_OUTPUT=""
CLI_SHEET_COLUMNS=""
CLI_SHEET_TIMESTAMP=""
CLI_PREVIEW_FONTSIZE=""
CLI_SHEET_FONTSIZE=""
CLI_BBCODE=""

POSITIONAL=()
while [ $# -gt 0 ]; do
    case "$1" in
        --width)   shift; CLI_WIDTH="${1:-}";   shift ;;
        --format)  shift; CLI_FORMAT="${1:-}";  shift ;;
        --quality) shift; CLI_QUALITY="${1:-}"; shift ;;
        --timestamp)    CLI_TIMESTAMP="yes"; shift ;;
        --no-timestamp) CLI_TIMESTAMP="no";  shift ;;
        --output)  shift; CLI_OUTPUT="${1:-}";  shift ;;   # previews | sheet | both (or 1/2/3)
        --contact-sheet)    CLI_CONTACT_SHEET="yes"; shift ;;
        --no-contact-sheet) CLI_CONTACT_SHEET="no";  shift ;;
        --sheet-columns) shift; CLI_SHEET_COLUMNS="${1:-}"; shift ;;
        --preview-fontsize) shift; CLI_PREVIEW_FONTSIZE="${1:-}"; shift ;;
        --sheet-fontsize)   shift; CLI_SHEET_FONTSIZE="${1:-}"; shift ;;
        --sheet-timestamp)    CLI_SHEET_TIMESTAMP="yes"; shift ;;
        --no-sheet-timestamp) CLI_SHEET_TIMESTAMP="no";  shift ;;
        --bbcode)    CLI_BBCODE="yes"; shift ;;   # offer a BBCode post for each video
        --no-bbcode) CLI_BBCODE="no";  shift ;;   # never ask about BBCode
        *) POSITIONAL+=("$1"); shift ;;
    esac
done
set -- "${POSITIONAL[@]}"
[ -n "$CLI_BBCODE" ] && GENERATE_BBCODE="$CLI_BBCODE"

if [ $# -ge 1 ] && [[ "$1" =~ ^[0-9]+$ ]]; then
    REQUESTED_COUNT="$1"
    INPUT_PATH="${2:-}"
elif [ $# -ge 1 ]; then
    INPUT_PATH="$1"
fi

# Prints the current choices as a small card. $1 = optional title.
show_settings_summary() {
WIDTH_DISPLAY="original size"
[ -n "$PREVIEW_WIDTH" ] && [ "$PREVIEW_WIDTH" -gt 0 ] 2>/dev/null && WIDTH_DISPLAY="${PREVIEW_WIDTH}px wide"
OUTPUT_DISPLAY="previews only"
[ "$OUTPUT_MODE" = "sheet" ] && OUTPUT_DISPLAY="contact sheet only"
[ "$OUTPUT_MODE" = "both" ] && OUTPUT_DISPLAY="previews + contact sheet"
TS_PREV="off"; [ "$TIMESTAMP_EFFECTIVE" = "true" ] && TS_PREV="on"
TS_SHEET="off"; [ "$SHEET_TIMESTAMP_EFFECTIVE" = "true" ] && TS_SHEET="on"
ui_section "${1:-Summary}"
ui_kv "Output" "$OUTPUT_DISPLAY"
ui_kv "Frames" "$REQUESTED_COUNT per video"
if [ "$PREVIEW_FORMAT" = "jpg" ]; then
    ui_kv "Format" "${WIDTH_DISPLAY} · .jpg (quality $PREVIEW_QUALITY)"
else
    ui_kv "Format" "${WIDTH_DISPLAY} · .${PREVIEW_FORMAT}"
fi
[ "$KEEP_PREVIEWS" = "yes" ] && ui_kv "Preview" "timestamp $TS_PREV"
[ "${CONTACT_SHEET,,}" = "yes" ] && ui_kv "Sheet" "${CONTACT_SHEET_COLUMNS} columns · timestamp $TS_SHEET"
}

declare -g OUTPUT_DEFAULT=3   # menu number used when Enter is pressed at "Output"

# Asks every setting (skipping any already given as a CLI flag), then shows
# the summary. Also used by "Change settings" at the end of a run.
configure_settings() {
# ---- what to produce: previews / contact sheet / both ----
# (--contact-sheet / --no-contact-sheet still work: they map to both / previews)
declare -g OUTPUT_MODE=""
case "${CLI_OUTPUT,,}" in
    1|previews|preview) OUTPUT_MODE="previews" ;;
    2|sheet|contact|contact-sheet) OUTPUT_MODE="sheet" ;;
    3|both) OUTPUT_MODE="both" ;;
    "")
        if [ "$CLI_CONTACT_SHEET" = "yes" ]; then OUTPUT_MODE="both"
        elif [ "$CLI_CONTACT_SHEET" = "no" ]; then OUTPUT_MODE="previews"
        fi ;;
    *) ui_warn "Invalid --output value (use previews, sheet or both)" ;;
esac

if [ -z "$OUTPUT_MODE" ]; then
    while true; do
        ui_section "Output"
        ui_opt 1 "Preview images only"
        ui_opt 2 "Contact sheet only"
        ui_opt 3 "Both"
        echo ""
        read -r -p "$(ui_prompt "Choose" "(blank = $OUTPUT_DEFAULT)")" val
        val=${val:-$OUTPUT_DEFAULT}
        case "$val" in
            1) OUTPUT_MODE="previews"; break ;;
            2) OUTPUT_MODE="sheet"; break ;;
            3) OUTPUT_MODE="both"; break ;;
            *) ui_warn "Please enter 1, 2 or 3." ;;
        esac
    done
fi

COUNT_LABEL="How many previews per video?"
case "$OUTPUT_MODE" in
    previews) CONTACT_SHEET="no";  KEEP_PREVIEWS="yes" ;;
    sheet)    CONTACT_SHEET="yes"; KEEP_PREVIEWS="no"
              COUNT_LABEL="How many frames in the contact sheet?" ;;
    both)     CONTACT_SHEET="yes"; KEEP_PREVIEWS="yes" ;;
esac

ui_section "Settings"
if [ -z "$REQUESTED_COUNT" ]; then
    while true; do
        count_hint="(min $MIN_PREVIEWS)"
        [ -n "${PREV_COUNT:-}" ] && count_hint="(min $MIN_PREVIEWS, blank = keep $PREV_COUNT)"
        read -p "$(ui_prompt "$COUNT_LABEL" "$count_hint")" REQUESTED_COUNT
        [ -z "$REQUESTED_COUNT" ] && [ -n "${PREV_COUNT:-}" ] && REQUESTED_COUNT="$PREV_COUNT"
        if [[ "$REQUESTED_COUNT" =~ ^[0-9]+$ ]] && [ "$REQUESTED_COUNT" -ge "$MIN_PREVIEWS" ]; then
            break
        fi
        ui_err "Enter a whole number, at least $MIN_PREVIEWS"
    done
elif [ "$REQUESTED_COUNT" -lt "$MIN_PREVIEWS" ]; then
    ui_warn "$REQUESTED_COUNT is below the minimum of $MIN_PREVIEWS — using $MIN_PREVIEWS instead"
    REQUESTED_COUNT="$MIN_PREVIEWS"
fi

if [ "$REQUESTED_COUNT" -gt "$CONFIRM_ABOVE" ]; then
    read -p "$(ui_prompt "That's up to $REQUESTED_COUNT images per video — continue?" "[y/N]")" confirm
    if ! [[ "$confirm" =~ ^[Yy]$ ]]; then
        ui_note "Cancelled."
        [ -n "${PREV_COUNT:-}" ] || exit 0
        REQUESTED_COUNT="$PREV_COUNT"
        ui_note "Keeping $REQUESTED_COUNT per video."
    fi
fi

# ---- preview width ----
if [ -n "$CLI_WIDTH" ]; then
    if [[ "$CLI_WIDTH" =~ ^[0-9]+$ ]]; then
        PREVIEW_WIDTH="$CLI_WIDTH"
    else
        ui_warn "Invalid --width value — keeping $PREVIEW_WIDTH"
    fi
else
    read -p "$(ui_prompt "Preview width in px" "(0 = original, blank = keep $PREVIEW_WIDTH)")" val
    if [ -n "$val" ]; then
        if [[ "$val" =~ ^[0-9]+$ ]]; then
            PREVIEW_WIDTH="$val"
        else
            ui_warn "Invalid value — keeping $PREVIEW_WIDTH"
        fi
    fi
fi

# ---- preview format ----
if [ -n "$CLI_FORMAT" ]; then
    case "${CLI_FORMAT,,}" in
        jpg|png) PREVIEW_FORMAT="${CLI_FORMAT,,}" ;;
        *) ui_warn "Invalid --format value — keeping $PREVIEW_FORMAT" ;;
    esac
else
    read -p "$(ui_prompt "Preview format" "(jpg or png, blank = keep $PREVIEW_FORMAT)")" val
    if [ -n "$val" ]; then
        case "${val,,}" in
            jpg|png) PREVIEW_FORMAT="${val,,}" ;;
            *) ui_warn "Invalid value — keeping $PREVIEW_FORMAT" ;;
        esac
    fi
fi

# ---- jpg quality (only relevant when format is jpg) ----
if [ "$PREVIEW_FORMAT" = "jpg" ]; then
    if [ -n "$CLI_QUALITY" ]; then
        if [[ "$CLI_QUALITY" =~ ^[0-9]+$ ]] && [ "$CLI_QUALITY" -ge 1 ] && [ "$CLI_QUALITY" -le 31 ]; then
            PREVIEW_QUALITY="$CLI_QUALITY"
        else
            ui_warn "Invalid --quality value — keeping $PREVIEW_QUALITY"
        fi
    else
        read -p "$(ui_prompt "JPG quality" "(1 best – 31 worst, blank = keep $PREVIEW_QUALITY)")" val
        if [ -n "$val" ]; then
            if [[ "$val" =~ ^[0-9]+$ ]] && [ "$val" -ge 1 ] && [ "$val" -le 31 ]; then
                PREVIEW_QUALITY="$val"
            else
                ui_warn "Invalid value — keeping $PREVIEW_QUALITY"
            fi
        fi
    fi
fi

# ---- timestamp overlay on/off (individual previews; skipped in sheet-only mode) ----
if [ "$KEEP_PREVIEWS" = "yes" ]; then
    if [ -n "$CLI_TIMESTAMP" ]; then
        PREVIEW_TIMESTAMP="$CLI_TIMESTAMP"
    else
        read -p "$(ui_prompt "Burn a timestamp onto each preview?" "[Y/n] (blank = keep $PREVIEW_TIMESTAMP)")" val
        if [ -n "$val" ]; then
            case "${val,,}" in
                y|yes) PREVIEW_TIMESTAMP="yes" ;;
                n|no)  PREVIEW_TIMESTAMP="no" ;;
                *) ui_warn "Invalid value — keeping $PREVIEW_TIMESTAMP" ;;
            esac
        fi
    fi
else
    PREVIEW_TIMESTAMP="no"
fi

# Resolve a font once for the whole run rather than per-frame. If the
# overlay is wanted but no font can be found, degrade gracefully —
# previews still generate, just without the burned-in timestamp.
declare -g RESOLVED_FONT=""
declare -g TIMESTAMP_EFFECTIVE="false"
if [ "${PREVIEW_TIMESTAMP,,}" = "yes" ]; then
    if RESOLVED_FONT=$(find_font); then
        TIMESTAMP_EFFECTIVE="true"
    else
        ui_warn "No font found for the timestamp overlay — previews will be generated without it."
        ui_note "Install one (e.g. 'pkg install fontconfig') or set PREVIEW_TS_FONT to a .ttf path."
    fi
fi

# ---- individual preview timestamp font size ----
if [ "$TIMESTAMP_EFFECTIVE" = "true" ]; then
    if [ -n "$CLI_PREVIEW_FONTSIZE" ]; then
        if [[ "$CLI_PREVIEW_FONTSIZE" =~ ^[0-9]+$ ]] && [ "$CLI_PREVIEW_FONTSIZE" -ge 8 ] && [ "$CLI_PREVIEW_FONTSIZE" -le 200 ]; then
            PREVIEW_TS_FONTSIZE="$CLI_PREVIEW_FONTSIZE"
        else
            ui_warn "Invalid --preview-fontsize value (use 8-200) — keeping $PREVIEW_TS_FONTSIZE"
        fi
    else
        while true; do
            read -r -p "$(ui_prompt "Preview timestamp font size in px" "(8-200, blank = keep $PREVIEW_TS_FONTSIZE)")" val
            [ -z "$val" ] && break
            if [[ "$val" =~ ^[0-9]+$ ]] && [ "$val" -ge 8 ] && [ "$val" -le 200 ]; then
                PREVIEW_TS_FONTSIZE="$val"
                break
            fi
            ui_err "Enter a whole number from 8 to 200"
        done
    fi
fi

# ---- contact sheet columns (only relevant if the sheet is on) ----
if [ "${CONTACT_SHEET,,}" = "yes" ]; then
    if [ -n "$CLI_SHEET_COLUMNS" ]; then
        if [[ "$CLI_SHEET_COLUMNS" =~ ^[0-9]+$ ]] && [ "$CLI_SHEET_COLUMNS" -ge "$CONTACT_SHEET_MIN_COLUMNS" ] && [ "$CLI_SHEET_COLUMNS" -le "$CONTACT_SHEET_MAX_COLUMNS" ]; then
            CONTACT_SHEET_COLUMNS="$CLI_SHEET_COLUMNS"
        else
            ui_warn "Invalid --sheet-columns value — keeping $CONTACT_SHEET_COLUMNS"
        fi
    else
        read -p "$(ui_prompt "Contact sheet columns" "($CONTACT_SHEET_MIN_COLUMNS-$CONTACT_SHEET_MAX_COLUMNS, blank = keep $CONTACT_SHEET_COLUMNS)")" val
        if [ -n "$val" ]; then
            if [[ "$val" =~ ^[0-9]+$ ]] && [ "$val" -ge "$CONTACT_SHEET_MIN_COLUMNS" ] && [ "$val" -le "$CONTACT_SHEET_MAX_COLUMNS" ]; then
                CONTACT_SHEET_COLUMNS="$val"
            else
                ui_warn "Must be $CONTACT_SHEET_MIN_COLUMNS-$CONTACT_SHEET_MAX_COLUMNS — keeping $CONTACT_SHEET_COLUMNS"
            fi
        fi
    fi

    # ---- avoid blank contact-sheet cells when preview count doesn't divide evenly ----
    if (( REQUESTED_COUNT % CONTACT_SHEET_COLUMNS != 0 )); then
        lower_count=$(( REQUESTED_COUNT / CONTACT_SHEET_COLUMNS * CONTACT_SHEET_COLUMNS ))
        upper_count=$(( lower_count + CONTACT_SHEET_COLUMNS ))
        ui_section "Grid fit"
        ui_warn "The preview count doesn't fill the contact sheet grid evenly"
        ui_note "Currently $REQUESTED_COUNT previews in $CONTACT_SHEET_COLUMNS columns"
        if (( lower_count >= MIN_PREVIEWS )); then
            ui_opt 1 "Use $lower_count previews" "no blank cells"
            ui_opt 2 "Use $upper_count previews" "no blank cells"
            ui_opt 3 "Keep $REQUESTED_COUNT previews" "one blank cell"
            while true; do
                read -r -p "$(ui_prompt "Choose" "(1-3, blank = 3)")" grid_choice
                grid_choice=${grid_choice:-3}
                case "$grid_choice" in
                    1) REQUESTED_COUNT="$lower_count"; break ;;
                    2) REQUESTED_COUNT="$upper_count"; break ;;
                    3) break ;;
                    *) ui_warn "Please enter 1, 2 or 3." ;;
                esac
            done
        else
            ui_opt 1 "Use $upper_count previews" "no blank cells"
            ui_opt 2 "Keep $REQUESTED_COUNT previews" "one blank cell"
            while true; do
                read -r -p "$(ui_prompt "Choose" "(1-2, blank = 2)")" grid_choice
                grid_choice=${grid_choice:-2}
                case "$grid_choice" in
                    1) REQUESTED_COUNT="$upper_count"; break ;;
                    2) break ;;
                    *) ui_warn "Please enter 1 or 2." ;;
                esac
            done
        fi
        ui_ok "Preview count set to $REQUESTED_COUNT"
    fi

    # ---- sheet timestamp on/off — independent of the preview timestamp setting ----
    if [ -n "$CLI_SHEET_TIMESTAMP" ]; then
        SHEET_TIMESTAMP="$CLI_SHEET_TIMESTAMP"
    else
        read -p "$(ui_prompt "Burn a timestamp onto the contact sheet too?" "[Y/n] (blank = keep $SHEET_TIMESTAMP)")" val
        if [ -n "$val" ]; then
            case "${val,,}" in
                y|yes) SHEET_TIMESTAMP="yes" ;;
                n|no)  SHEET_TIMESTAMP="no" ;;
                *) ui_warn "Invalid value — keeping $SHEET_TIMESTAMP" ;;
            esac
        fi
    fi
fi

# Resolved once, alongside the preview timestamp font lookup above. Same
# font, but its own on/off outcome — only needs a font if it's wanted.
declare -g SHEET_TIMESTAMP_EFFECTIVE="false"
if [ "${CONTACT_SHEET,,}" = "yes" ] && [ "${SHEET_TIMESTAMP,,}" = "yes" ]; then
    if [ -n "$RESOLVED_FONT" ]; then
        SHEET_TIMESTAMP_EFFECTIVE="true"
    else
        RESOLVED_FONT=$(find_font) && SHEET_TIMESTAMP_EFFECTIVE="true" || ui_warn "No font found — the contact sheet won't have timestamps either"
    fi
fi

# ---- contact sheet timestamp font size ----
if [ "$SHEET_TIMESTAMP_EFFECTIVE" = "true" ]; then
    if [ -n "$CLI_SHEET_FONTSIZE" ]; then
        if [[ "$CLI_SHEET_FONTSIZE" =~ ^[0-9]+$ ]] && [ "$CLI_SHEET_FONTSIZE" -ge 8 ] && [ "$CLI_SHEET_FONTSIZE" -le 200 ]; then
            SHEET_TS_FONTSIZE="$CLI_SHEET_FONTSIZE"
        else
            ui_warn "Invalid --sheet-fontsize value (use 8-200) — keeping $SHEET_TS_FONTSIZE"
        fi
    else
        while true; do
            read -r -p "$(ui_prompt "Contact sheet timestamp font size in px" "(8-200, blank = keep $SHEET_TS_FONTSIZE)")" val
            [ -z "$val" ] && break
            if [[ "$val" =~ ^[0-9]+$ ]] && [ "$val" -ge 8 ] && [ "$val" -le 200 ]; then
                SHEET_TS_FONTSIZE="$val"
                break
            fi
            ui_err "Enter a whole number from 8 to 200"
        done
    fi
fi

# Sheet-only: the throwaway frames carry the sheet's timestamp settings
# directly, so the sheet is built from them with no second render pass.
if [ "$KEEP_PREVIEWS" != "yes" ]; then
    TIMESTAMP_EFFECTIVE="$SHEET_TIMESTAMP_EFFECTIVE"
    PREVIEW_TS_FONTSIZE="$SHEET_TS_FONTSIZE"
fi

show_settings_summary "Summary"
}

configure_settings

# End-of-run "Change settings": forget the CLI flags so every question is
# asked again, with the current values offered as the Enter default.
change_settings() {
    CLI_WIDTH=""; CLI_FORMAT=""; CLI_QUALITY=""; CLI_TIMESTAMP=""
    CLI_CONTACT_SHEET=""; CLI_OUTPUT=""; CLI_SHEET_COLUMNS=""
    CLI_SHEET_TIMESTAMP=""; CLI_PREVIEW_FONTSIZE=""; CLI_SHEET_FONTSIZE=""
    case "$OUTPUT_MODE" in
        previews) OUTPUT_DEFAULT=1 ;;
        sheet)    OUTPUT_DEFAULT=2 ;;
        *)        OUTPUT_DEFAULT=3 ;;
    esac
    PREV_COUNT="$REQUESTED_COUNT"
    REQUESTED_COUNT=""
    OUTPUT_MODE=""
    configure_settings
    PREV_COUNT=""
}

while true; do
    if [ -z "$INPUT_PATH" ]; then
        ui_section "Input"
        while true; do
            read -r -p "$(ui_prompt "Video file or folder path")" INPUT_PATH
            [ -n "$INPUT_PATH" ] && break
            ui_warn "Please enter a video file or folder path — there's no default folder."
        done
    fi

    FAILED=0
    SUCCEEDED=0
    SKIPPED=0
    if [ -f "$INPUT_PATH" ]; then
        process_file "$INPUT_PATH" "$REQUESTED_COUNT" || true
    elif [ -d "$INPUT_PATH" ]; then
        process_all_files "$INPUT_PATH" "$REQUESTED_COUNT" || true
    else
        ui_err "File or folder doesn't exist:"
        ui_note "$INPUT_PATH"
        FAILED=1
    fi

    ui_section "Task complete"
    ui_kv "Processed" "${COLOR_GREEN}$SUCCEEDED${COLOR_RESET}"
    ui_kv "Skipped" "$SKIPPED ${COLOR_GRAY}(already done)${COLOR_RESET}"
    if [ "$FAILED" -gt 0 ]; then ui_kv "Failed" "${COLOR_RED}$FAILED${COLOR_RESET}"; else ui_kv "Failed" "0"; fi

    offer_cleanup_folders

    show_summary=1
    while true; do
        if [ "$show_summary" = 1 ]; then
            show_settings_summary "Current settings"
            show_summary=0
        fi
        echo ""
        ui_opt 1 "Process another file/folder" "same settings"
        ui_opt 2 "Change settings"
        ui_opt 3 "Main menu"
        ui_opt 4 "Exit"
        read -r -p "$(ui_prompt "Choose" "(blank = 1)")" next_action
        next_action="${next_action:-1}"
        case "$next_action" in
            1)
                INPUT_PATH=""
                break
                ;;
            2)
                change_settings
                show_summary=1
                ;;
            3)
                exec "$0"
                ;;
            4)
                [ "$FAILED" -gt 0 ] && exit 1
                exit 0
                ;;
            *)
                ui_warn "Please enter 1, 2, 3 or 4."
                ;;
        esac
    done
done
