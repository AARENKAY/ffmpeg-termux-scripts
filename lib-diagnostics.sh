#!/bin/bash

# ==================== LOADING GUARD ====================
if [[ -n "${_LIB_DIAG_LOADED+x}" ]]; then
    return 0  # Already loaded, skip
fi
readonly _LIB_DIAG_LOADED=true
# ======================================================

# ===========================================================================
# DIAGNOSTICS MODULE - FAILURE DETECTION, ISOLATION AND POST-BATCH MENU
#   (the interactive diagnosis / recovery workflow lives in lib-diag-recovery.sh)
#
# Flow:   encode_* / merge_chunks  --diag_note_failure-->  DIAG_FAIL_* globals
#         process_file             --diag_handle_failure-> classify + isolate
#         process_all_files        --diag_post_batch_menu-> user decides
#
# Everything here uses plain directories and plain file copies (no FIFOs,
# symlinks or permission tricks), so it works on Android shared storage.
# Nothing here may abort a batch: every public function returns 0.
# ===========================================================================

declare -g DIAG_DIR_NAME=".ffmpeg_diagnostics"
declare -g DIAG_ROOT_DIR=""              # folder that owns .ffmpeg_diagnostics (batch input dir)
declare -g DIAG_SESSION_DIR=""           # one per batch, never reused
declare -g DIAG_ISOLATED_COUNT=0
declare -g DIAG_ISOLATE_FAIL_COUNT=0
declare -ga DIAG_CASE_DIRS=()

# Failure record of the file being processed (reset in process_file)
declare -g DIAG_FAIL_CONTEXT=""          # category hint given by the detection site
declare -g DIAG_FAIL_CATEGORY=""         # final primary category
declare -g DIAG_FAIL_CAUSE=""            # evidence-based suspected cause
declare -g DIAG_FAIL_REASON=""
declare -g DIAG_FAIL_RC=""
declare -g DIAG_FAIL_RAW_LOG=""          # permanent copy of the raw ffmpeg stderr
declare -g DIAG_FAIL_PARTIAL=""          # incomplete output / failed chunk
declare -g DIAG_FAIL_CHUNK_DIR=""
declare -g DIAG_FAIL_EVIDENCE=""         # newline separated "CLASS|count|sample"
declare -g DIAG_ENCODE_MODE="single"
declare -g DIAG_LAST_HAD_WARNINGS=0      # success, but ffmpeg wrote warnings
declare -g DIAG_CURRENT_RAW_LOG=""       # temp stderr log of the running ffmpeg

# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------
_diag_say_log() {   # append one line to the per-file log (never fails)
    if [ -n "${LOG_FILE:-}" ]; then
        printf '%s\n' "$1" | clean_output >> "$LOG_FILE" 2>/dev/null || true
    fi
    return 0
}

_diag_num() { [[ "${1:-}" =~ ^[0-9]+(\.[0-9]+)?$ ]]; }

# awk float compare: _diag_cmp A OP B  (OP one of < <= > >=)
_diag_cmp() { awk -v a="$1" -v b="$3" -v op="$2" 'BEGIN {
    if (op == "<") r = (a < b); else if (op == "<=") r = (a <= b);
    else if (op == ">") r = (a > b); else r = (a >= b);
    exit !r }'; }

_diag_tol() {   # tolerance in seconds for an expected duration
    awk -v e="${1:-0}" 'BEGIN { t = e * 0.003; if (t < 2) t = 2; printf "%.3f", t }'
}

_diag_hms() {   # seconds -> hh:mm:ss, or "n/a"
    if _diag_num "${1:-}"; then format_time "$1" "hms" 2>/dev/null || printf 'n/a'; else printf 'n/a'; fi
}

_diag_one_line() { local s="${1:-}"; s="${s//$'\n'/ }"; s="${s//$'\t'/ }"; printf '%s' "$s"; }

_diag_free_kb() {   # free space (KiB) of the filesystem holding $1, empty if unknown
    local v
    v=$(df -Pk "$1" 2>/dev/null | awk 'NR==2 {print $4}') || v=""
    printf '%s' "$v"
}

_diag_filesize() { stat -c%s "$1" 2>/dev/null || wc -c < "$1" 2>/dev/null || echo 0; }

# Private scratch directory (progress files etc.). Never inside shared storage
# when Termux's private $PREFIX/tmp is available.
_diag_scratch() {
    local base="${TMPDIR:-}"
    if [ -z "$base" ] && [ -n "${PREFIX:-}" ] && [ -d "${PREFIX}/tmp" ]; then base="${PREFIX}/tmp"; fi
    if [ -z "$base" ] || [ ! -d "$base" ]; then base="/tmp"; fi
    mktemp -d "$base/ffconv_diag.XXXXXX" 2>/dev/null || mktemp -d 2>/dev/null || true
}

# value of KEY in text of key=value lines
_diag_kv() { printf '%s\n' "$1" | awk -F= -v k="$2" '$1 == k { sub(/^[^=]*=/, ""); print; exit }'; }

# Quick facts about a media file into globals PREFIX_*  (never fails)
#   readable dur size fmt has_v has_a v_codec v_w v_h v_pix v_fps v_tb v_start v_dur v_nb
#   a_codec a_rate a_ch a_dur a_start n_other
_diag_facts() {
    local f="$1" p="$2" txt types t other=0
    local readable=0 dur="" size="" fmt="" has_v=0 has_a=0
    if [ -n "$f" ] && [ -f "$f" ]; then
        txt=$(ffprobe -v error -show_entries format=duration,size,format_name \
            -of default=noprint_wrappers=1 "$f" 2>/dev/null </dev/null) && readable=1 || readable=0
        dur=$(_diag_kv "$txt" duration); size=$(_diag_kv "$txt" size); fmt=$(_diag_kv "$txt" format_name)
        if ! _diag_num "$dur"; then dur=""; fi
    fi
    printf -v "${p}_readable" '%s' "$readable"
    printf -v "${p}_dur" '%s' "$dur"
    printf -v "${p}_size" '%s' "$size"
    printf -v "${p}_fmt" '%s' "$fmt"

    local v_codec="" v_w="" v_h="" v_pix="" v_fps="" v_tb="" v_start="" v_dur="" v_nb=""
    local a_codec="" a_rate="" a_ch="" a_dur="" a_start=""
    if [ "$readable" -eq 1 ]; then
        types=$(ffprobe -v error -show_entries stream=codec_type -of csv=p=0 "$f" 2>/dev/null </dev/null) || types=""
        while IFS= read -r t; do
            case "$t" in
                video) : ;;
                audio) : ;;
                "") : ;;
                *) other=$((other + 1)) ;;
            esac
        done <<< "$types"
        txt=$(ffprobe -v error -select_streams v:0 -show_entries \
            stream=codec_name,width,height,pix_fmt,r_frame_rate,time_base,start_time,duration,nb_frames \
            -of default=noprint_wrappers=1 "$f" 2>/dev/null </dev/null) || txt=""
        if [ -n "$txt" ]; then
            has_v=1
            v_codec=$(_diag_kv "$txt" codec_name); v_w=$(_diag_kv "$txt" width); v_h=$(_diag_kv "$txt" height)
            v_pix=$(_diag_kv "$txt" pix_fmt); v_fps=$(_diag_kv "$txt" r_frame_rate); v_tb=$(_diag_kv "$txt" time_base)
            v_start=$(_diag_kv "$txt" start_time); v_dur=$(_diag_kv "$txt" duration); v_nb=$(_diag_kv "$txt" nb_frames)
        fi
        txt=$(ffprobe -v error -select_streams a:0 -show_entries \
            stream=codec_name,sample_rate,channels,start_time,duration \
            -of default=noprint_wrappers=1 "$f" 2>/dev/null </dev/null) || txt=""
        if [ -n "$txt" ]; then
            has_a=1
            a_codec=$(_diag_kv "$txt" codec_name); a_rate=$(_diag_kv "$txt" sample_rate)
            a_ch=$(_diag_kv "$txt" channels); a_start=$(_diag_kv "$txt" start_time); a_dur=$(_diag_kv "$txt" duration)
        fi
    fi
    if ! _diag_num "$v_dur"; then v_dur=""; fi
    if ! _diag_num "$a_dur"; then a_dur=""; fi
    if ! _diag_num "$v_nb"; then v_nb=""; fi
    printf -v "${p}_has_v" '%s' "$has_v";   printf -v "${p}_has_a" '%s' "$has_a"
    printf -v "${p}_v_codec" '%s' "$v_codec"; printf -v "${p}_v_w" '%s' "$v_w"; printf -v "${p}_v_h" '%s' "$v_h"
    printf -v "${p}_v_pix" '%s' "$v_pix";   printf -v "${p}_v_fps" '%s' "$v_fps"; printf -v "${p}_v_tb" '%s' "$v_tb"
    printf -v "${p}_v_start" '%s' "$v_start"; printf -v "${p}_v_dur" '%s' "$v_dur"; printf -v "${p}_v_nb" '%s' "$v_nb"
    printf -v "${p}_a_codec" '%s' "$a_codec"; printf -v "${p}_a_rate" '%s' "$a_rate"; printf -v "${p}_a_ch" '%s' "$a_ch"
    printf -v "${p}_a_start" '%s' "$a_start"; printf -v "${p}_a_dur" '%s' "$a_dur"
    printf -v "${p}_n_other" '%s' "$other"
    return 0
}

# Packet count of the first video stream (fast: reads packets, no decoding). Empty if unknown.
_diag_video_packets() {
    local n
    n=$(ffprobe -v error -count_packets -select_streams v:0 -show_entries stream=nb_read_packets \
        -of default=noprint_wrappers=1:nokey=1 "$1" 2>/dev/null </dev/null | head -n1) || n=""
    if [[ "$n" =~ ^[0-9]+$ ]]; then printf '%s' "$n"; fi
    return 0
}

# ---------------------------------------------------------------------------
# Failure notes (called by the detection sites in lib-encode.sh)
# ---------------------------------------------------------------------------
diag_reset_failure() {
    DIAG_FAIL_CONTEXT=""; DIAG_FAIL_CATEGORY=""; DIAG_FAIL_CAUSE=""; DIAG_FAIL_REASON=""
    DIAG_FAIL_RC=""; DIAG_FAIL_RAW_LOG=""; DIAG_FAIL_PARTIAL=""; DIAG_FAIL_CHUNK_DIR=""
    DIAG_FAIL_EVIDENCE=""; DIAG_LAST_HAD_WARNINGS=0; DIAG_CURRENT_RAW_LOG=""
    return 0
}

# Permanent copy of a temporary ffmpeg stderr log, next to the per-file log in LOG_DIR.
# Appends (with a header), so several chunk logs of one file end up in one file.
# Prints the permanent path. Never deletes the source.
preserve_ffmpeg_logs() {
    local src="${1:-}" label="${2:-ffmpeg}" rc="${3:-}" dest
    if [ -z "$src" ] || [ ! -f "$src" ] || [ -z "${LOG_FILE:-}" ]; then return 0; fi
    dest="${LOG_FILE%.log}.ffmpeg_raw.log"
    {
        printf '===== %s | exit code: %s | %s =====\n' "$label" "${rc:-unknown}" "$(date '+%Y-%m-%d %H:%M:%S')"
        cat "$src"
        printf '\n'
    } >> "$dest" 2>/dev/null || return 0
    printf '%s' "$dest"
    return 0
}

# diag_note_failure CONTEXT REASON [RAW_LOG] [EXIT_CODE] [PARTIAL_FILE] [CHUNK_DIR]
# CONTEXT is the fallback category when the log has no more specific evidence.
diag_note_failure() {
    DIAG_FAIL_CONTEXT="${1:-UNKNOWN}"
    DIAG_FAIL_REASON="${2:-}"
    DIAG_FAIL_RC="${4:-}"
    if [ -n "${5:-}" ]; then DIAG_FAIL_PARTIAL="$5"; fi
    if [ -n "${6:-}" ]; then DIAG_FAIL_CHUNK_DIR="$6"; fi
    local raw="${3:-}" perm=""
    if [ -n "$raw" ] && [ -s "$raw" ]; then
        perm=$(preserve_ffmpeg_logs "$raw" "$DIAG_FAIL_REASON" "$DIAG_FAIL_RC")
        if [ -n "$perm" ]; then DIAG_FAIL_RAW_LOG="$perm"; fi
    fi
    ENCODE_LAST_STATUS="failed"
    _diag_say_log " FAILURE RECORDED: ${DIAG_FAIL_CONTEXT} - ${DIAG_FAIL_REASON}"
    return 0
}

# Maps INTEGRITY_REASON (set by check_video_integrity) to a failure context.
diag_context_from_integrity() {
    case "${INTEGRITY_REASON:-}" in
        MISSING)    printf 'OUTPUT_MISSING' ;;
        EMPTY)      printf 'OUTPUT_EMPTY' ;;
        UNREADABLE) printf 'OUTPUT_UNREADABLE' ;;
        NO_VIDEO)   printf 'OUTPUT_NO_VIDEO' ;;
        NO_AUDIO)   printf 'OUTPUT_NO_AUDIO' ;;
        DURATION)   printf 'OUTPUT_DURATION_MISMATCH' ;;
        *)          printf 'OUTPUT_INTEGRITY_FAILURE' ;;
    esac
}

# ---------------------------------------------------------------------------
# Classification
# ---------------------------------------------------------------------------
# Evidence patterns (grep -E, case-insensitive), kept in parallel arrays.
_DIAG_CLASSES=(INTERRUPTED RESOURCE ENCODER_INIT MISSING_CODEC STREAM_MAP IO_ERROR MUX CONTAINER SOURCE_DECODE TIMESTAMP)
_DIAG_PATTERNS=(
    'Exiting normally, received signal|Immediate exit requested|received signal [0-9]+'
    'Cannot allocate memory|Out of memory|std::bad_alloc|memory allocation|No space left on device|Disk quota exceeded|Resource temporarily unavailable'
    'Error initializing output stream|Error while opening encoder|Could not open encoder|Unknown encoder|Encoder .* not found|Error initializing the filter|Error reinitializing filters|Error selecting an encoder'
    'Unknown decoder|Decoder .* not found|Unsupported codec|Decoding requested, but no decoder found|Failed to find decoder'
    'Stream map .* matches no streams|Stream specifier .* matches no streams|does not contain any stream'
    'Input/output error|I/O error|Broken pipe|Permission denied|Read-only file system|Error writing trailer|Error closing file'
    'Error muxing a packet|Error writing header|Could not write header|Too many packets buffered'
    'moov atom not found|Invalid index|EBML header parsing failed|Could not find codec parameters|Cannot determine format|Seek failed|Invalid atom|unspecified pixel format'
    'Error while decoding stream|Invalid NAL|decode_slice_header error|concealing|error while decoding MB|co located POCs unavailable|corrupt decoded frame|Missing reference picture|reference picture missing|Invalid data found when processing input|Error submitting packet to decoder|Header missing|invalid block type|unexpected end of file|Truncating packet|Premature end|overread|Invalid frame size|corrupt'
    'Non-monotonous DTS|non monotonically increasing dts|Invalid timestamp|pts has no value|Timestamps are unset|DTS .* out of order|Past duration .* too large'
)

# Prints "CLASS|count|first matching line" for each class found in FILE.
_diag_scan_file() {
    local f="$1" i n s
    if [ -z "$f" ] || [ ! -s "$f" ]; then return 0; fi
    for i in "${!_DIAG_CLASSES[@]}"; do
        n=$(grep -aEic -- "${_DIAG_PATTERNS[$i]}" "$f" 2>/dev/null) || n=0
        if [ "${n:-0}" -gt 0 ]; then
            s=$(grep -aEi -m1 -- "${_DIAG_PATTERNS[$i]}" "$f" 2>/dev/null | cut -c1-200) || s=""
            printf '%s|%s|%s\n' "${_DIAG_CLASSES[$i]}" "$n" "$s"
        fi
    done
    return 0
}

# Sets DIAG_FAIL_CATEGORY, DIAG_FAIL_CAUSE and DIAG_FAIL_EVIDENCE from the recorded
# failure. Not every non-zero exit is blamed on the source: the cause is only
# SOURCE_CORRUPTION when the logs actually contain decoder/corruption evidence.
classify_conversion_failure() {
    local scan_file="${DIAG_FAIL_RAW_LOG:-}" tmp="" rc="${DIAG_FAIL_RC:-}"
    local ev line cls cnt cat cause
    local -A seen=()

    if [ -z "$scan_file" ] || [ ! -s "$scan_file" ]; then
        # No raw ffmpeg log (e.g. merge step): use the tail of the per-file log
        if [ -n "${LOG_FILE:-}" ] && [ -s "${LOG_FILE:-}" ]; then
            tmp=$(mktemp 2>/dev/null) || tmp=""
            # drop the converter's own status lines so they are never mistaken for ffmpeg evidence
            if [ -n "$tmp" ]; then
                tail -n 400 "$LOG_FILE" 2>/dev/null | grep -avE 'OUTPUT MAY BE|FAILED INTEGRITY|FAILURE (RECORDED|CLASSIFIED)|DURATION MISMATCH|ISOLATED FOR|ENCODING INTERRUPTED' > "$tmp" || true
                scan_file="$tmp"
            fi
        fi
    fi
    ev=$(_diag_scan_file "$scan_file")
    if [ -n "$tmp" ]; then rm -f "$tmp"; fi
    DIAG_FAIL_EVIDENCE="$ev"

    while IFS='|' read -r cls cnt line; do
        if [ -n "$cls" ]; then seen["$cls"]="$cnt"; fi
    done <<< "$ev"

    cat="${DIAG_FAIL_CONTEXT:-UNKNOWN}"
    if [ "$rc" = "130" ] || [ "$rc" = "143" ] || [ -n "${seen[INTERRUPTED]:-}" ]; then
        cat="INTERRUPTED"
    elif [ "$rc" = "137" ] || [ -n "${seen[RESOURCE]:-}" ]; then
        cat="RESOURCE_FAILURE"
    elif [ -n "${seen[ENCODER_INIT]:-}" ]; then
        cat="ENCODER_INIT_FAILURE"
    elif [ -n "${seen[MISSING_CODEC]:-}" ]; then
        cat="CODEC_UNAVAILABLE"
    elif [ -n "${seen[STREAM_MAP]:-}" ]; then
        cat="STREAM_MAPPING_FAILURE"
    elif [ -n "${seen[IO_ERROR]:-}" ]; then
        cat="IO_ERROR"
    elif [ -n "${seen[MUX]:-}" ]; then
        cat="MUX_FAILURE"
    elif [ "$cat" = "UNKNOWN" ] && [ -n "$rc" ] && [ "$rc" != "0" ]; then
        cat="FFMPEG_NONZERO_EXIT"
    fi

    case "$cat" in
        INTERRUPTED)                     cause="INTERRUPTION" ;;
        RESOURCE_FAILURE)                cause="RESOURCE_LIMIT" ;;
        IO_ERROR)                        cause="STORAGE_IO" ;;
        ENCODER_INIT_FAILURE|CODEC_UNAVAILABLE|STREAM_MAPPING_FAILURE|MUX_FAILURE)
                                         cause="ENCODER_SIDE" ;;
        *)
            if   [ -n "${seen[CONTAINER]:-}" ];     then cause="CONTAINER_INDEX"
            elif [ -n "${seen[SOURCE_DECODE]:-}" ]; then cause="SOURCE_CORRUPTION"
            elif [ -n "${seen[TIMESTAMP]:-}" ];     then cause="TIMESTAMP_PROBLEM"
            else                                         cause="UNKNOWN"
            fi
            ;;
    esac
    DIAG_FAIL_CATEGORY="$cat"
    DIAG_FAIL_CAUSE="$cause"
    return 0
}

# ---------------------------------------------------------------------------
# Session / isolation
# ---------------------------------------------------------------------------
diag_batch_begin() {
    DIAG_ROOT_DIR="${1:-}"
    DIAG_SESSION_DIR=""
    DIAG_ISOLATED_COUNT=0
    DIAG_ISOLATE_FAIL_COUNT=0
    DIAG_CASE_DIRS=()
    return 0
}

# Creates <root>/.ffmpeg_diagnostics/<timestamp>[_N] exactly once per batch.
_diag_ensure_session() {
    local root="${1:-}" base ts d n=1
    if [ -n "$DIAG_SESSION_DIR" ] && [ -d "$DIAG_SESSION_DIR" ]; then return 0; fi
    if [ -z "$root" ]; then return 1; fi
    base="${root%/}/$DIAG_DIR_NAME"
    mkdir -p "$base" 2>/dev/null || return 1
    ts=$(date +%Y%m%d_%H%M%S)
    d="$base/$ts"
    until mkdir "$d" 2>/dev/null; do           # atomic: never reuses an existing session
        n=$((n + 1))
        d="$base/${ts}_$n"
        if [ "$n" -gt 500 ]; then return 1; fi
    done
    DIAG_SESSION_DIR="$d"
    : > "$d/manifest.txt" 2>/dev/null || return 1
    {
        echo "FFmpeg converter - diagnostic session"
        echo "Created: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "Input folder: $root"
        echo "Log folder: ${LOG_DIR:-}"
    } >> "$d/manifest.txt" 2>/dev/null || true
    return 0
}

# Collision-safe unique directory under PARENT for NAME
_diag_unique_case_dir() {
    local parent="$1" name="$2" d n=1
    d="$parent/$name"
    while [ -e "$d" ]; do n=$((n + 1)); d="$parent/${name}_$n"; done
    printf '%s' "$d"
}

# copy FILE to DEST and verify the size; removes a partial copy. Returns 0 on success.
_diag_safe_copy() {
    local src="$1" dest="$2" need_kb free_kb
    need_kb=$(( ( $(_diag_filesize "$src") / 1024 ) + 1024 ))
    free_kb=$(_diag_free_kb "$(dirname "$dest")")
    if [[ "$free_kb" =~ ^[0-9]+$ ]] && [ "$free_kb" -lt "$need_kb" ]; then
        return 2   # not enough free space
    fi
    if ! cp -f -- "$src" "$dest" 2>/dev/null; then rm -f -- "$dest" 2>/dev/null || true; return 1; fi
    if [ "$(_diag_filesize "$src")" != "$(_diag_filesize "$dest")" ]; then rm -f -- "$dest" 2>/dev/null || true; return 1; fi
    return 0
}

_diag_job_vf() {   # value of -vf in the dynamically visible vf_args array of process_file
    if [ "${#vf_args[@]}" -ge 2 ] && [ "${vf_args[0]}" = "-vf" ]; then printf '%s' "${vf_args[1]}"; fi
}

# isolate_failed_media INPUT OUTPUT LOG_FILE [RELATIVE_DIR]
# Copies original, incomplete output, logs and probe data into the session dir
# and records a manifest entry. Reports (but survives) every kind of copy error.
isolate_failed_media() {
    local input_file="$1" output_file="$2" log_file="$3" relative_dir="${4:-}"
    local root="${DIAG_ROOT_DIR:-}" name base ext case_dir parent rc
    local orig_copy="NONE" out_copy="NONE" partial_copy="NONE"
    name=$(basename -- "$input_file"); base="${name%.*}"; ext="${name##*.}"
    if [ -z "$root" ]; then root=$(dirname -- "$input_file"); fi

    if ! _diag_ensure_session "$root"; then
        DIAG_ISOLATE_FAIL_COUNT=$((DIAG_ISOLATE_FAIL_COUNT + 1))
        ui_err "COULD NOT CREATE DIAGNOSTIC FOLDER IN: $root"
        ui_note "Logs stay at: ${log_file}"
        return 0
    fi

    parent="$DIAG_SESSION_DIR"
    if [ -n "$relative_dir" ] && [ "$relative_dir" != "." ]; then parent="$parent/$relative_dir"; fi
    case_dir=$(_diag_unique_case_dir "$parent" "$base")
    if ! mkdir -p "$case_dir" 2>/dev/null; then
        DIAG_ISOLATE_FAIL_COUNT=$((DIAG_ISOLATE_FAIL_COUNT + 1))
        ui_err "COULD NOT CREATE: $case_dir"
        ui_note "Logs stay at: ${log_file}"
        return 0
    fi

    ui_note "Isolating files for diagnosis (copying, originals stay untouched)..."
    sleep 1   # let the asynchronous log writers (tee >(...)) flush

    # --- original (copy, never move) ---
    if [ -f "$input_file" ]; then
        _diag_safe_copy "$input_file" "$case_dir/original.$ext" && rc=0 || rc=$?
        case "$rc" in
            0) orig_copy="original.$ext" ;;
            2) orig_copy="FAILED_NO_SPACE"; ui_warn "Not enough free space to copy the original - it stays where it is" ;;
            *) orig_copy="FAILED_COPY";     ui_warn "Copying the original failed - it stays where it is" ;;
        esac
    fi
    # --- incomplete output ---
    if [ -n "$output_file" ] && [ -f "$output_file" ]; then
        _diag_safe_copy "$output_file" "$case_dir/incomplete_output.${output_file##*.}" && rc=0 || rc=$?
        if [ "$rc" -eq 0 ]; then out_copy="incomplete_output.${output_file##*.}"; else out_copy="FAILED_COPY"; ui_warn "Could not copy the incomplete output"; fi
    fi
    if [ -n "${DIAG_FAIL_PARTIAL:-}" ] && [ -f "$DIAG_FAIL_PARTIAL" ] && [ "$DIAG_FAIL_PARTIAL" != "$output_file" ]; then
        _diag_safe_copy "$DIAG_FAIL_PARTIAL" "$case_dir/incomplete_chunk.${DIAG_FAIL_PARTIAL##*.}" && rc=0 || rc=$?
        if [ "$rc" -eq 0 ]; then partial_copy="incomplete_chunk.${DIAG_FAIL_PARTIAL##*.}"; else partial_copy="FAILED_COPY"; fi
    fi
    # --- logs ---
    if [ -f "$log_file" ]; then cp -f -- "$log_file" "$case_dir/encoding.log" 2>/dev/null || true; fi
    if [ -n "$DIAG_FAIL_RAW_LOG" ] && [ -f "$DIAG_FAIL_RAW_LOG" ]; then
        cp -f -- "$DIAG_FAIL_RAW_LOG" "$case_dir/ffmpeg_raw.log" 2>/dev/null || true
    fi
    if [ -n "$DIAG_FAIL_CHUNK_DIR" ] && [ -d "$DIAG_FAIL_CHUNK_DIR" ]; then
        local cl
        mkdir -p "$case_dir/chunk_logs" 2>/dev/null || true
        for cl in "$DIAG_FAIL_CHUNK_DIR"/ffmpeg_chunk_*.log; do
            if [ -f "$cl" ]; then cp -f -- "$cl" "$case_dir/chunk_logs/" 2>/dev/null || true; fi
        done
    fi
    # --- probe snapshots (cheap, no decoding) ---
    local P_SRC_readable="" P_OUT_readable=""
    ffprobe -hide_banner -v warning -show_format -show_streams "$input_file" > "$case_dir/ffprobe_original.txt" 2>&1 </dev/null || true
    if [ -n "$output_file" ] && [ -f "$output_file" ]; then
        ffprobe -hide_banner -v warning -show_format -show_streams "$output_file" > "$case_dir/ffprobe_output.txt" 2>&1 </dev/null || true
    fi

    _diag_write_failure_report "$case_dir" "$input_file" "$output_file" "$orig_copy" "$out_copy"
    _diag_write_case_meta "$case_dir" "$input_file" "$output_file" "$relative_dir" "$orig_copy" "$out_copy" "$log_file"
    {
        echo ""
        echo "[$((${#DIAG_CASE_DIRS[@]} + 1))] ${relative_dir:+$relative_dir/}$name"
        echo "  case folder : $case_dir"
        echo "  original    : $input_file  (copy: $orig_copy)"
        echo "  output      : ${output_file:-none}  (copy: $out_copy)"
        echo "  category    : ${DIAG_FAIL_CATEGORY:-?}   suspected cause: ${DIAG_FAIL_CAUSE:-?}"
        echo "  reason      : ${DIAG_FAIL_REASON:-?}"
        echo "  time        : $(date '+%Y-%m-%d %H:%M:%S')"
    } >> "$DIAG_SESSION_DIR/manifest.txt" 2>/dev/null || true

    DIAG_CASE_DIRS+=("$case_dir")
    DIAG_ISOLATED_COUNT=$((DIAG_ISOLATED_COUNT + 1))
    return 0
}

_diag_write_failure_report() {
    local case_dir="$1" input_file="$2" output_file="$3" orig_copy="$4" out_copy="$5"
    local rep="$case_dir/failure_report.txt" ev cls cnt sample
    {
        echo "FAILURE REPORT"
        echo "=============="
        echo "Time          : $(date '+%Y-%m-%d %H:%M:%S')"
        echo "Original      : $input_file"
        echo "Original copy : $orig_copy"
        echo "Output        : ${output_file:-none}"
        echo "Output copy   : $out_copy"
        echo "Encode mode   : ${DIAG_ENCODE_MODE:-single}"
        echo "Category      : ${DIAG_FAIL_CATEGORY:-UNKNOWN}"
        echo "Suspected     : ${DIAG_FAIL_CAUSE:-UNKNOWN}"
        echo "Reason        : ${DIAG_FAIL_REASON:-}"
        echo "FFmpeg exit   : ${DIAG_FAIL_RC:-n/a}"
        if [ -n "${INTEGRITY_DETAIL:-}" ]; then echo "Integrity     : ${INTEGRITY_REASON:-}: ${INTEGRITY_DETAIL}"; fi
        echo ""
        echo "Evidence found in the FFmpeg log (class, matches, first match):"
        if [ -z "$DIAG_FAIL_EVIDENCE" ]; then
            echo "  none - no known error signature found; the cause is not established"
        else
            while IFS='|' read -r cls cnt sample; do
                if [ -n "$cls" ]; then printf '  %-14s %5s  %s\n' "$cls" "$cnt" "$sample"; fi
            done <<< "$DIAG_FAIL_EVIDENCE"
        fi
        echo ""
        echo "Quick facts (no decoding):"
        _diag_facts "$input_file" S
        printf '  source : readable=%s duration=%s video=%s audio=%s\n' "$S_readable" "${S_dur:-n/a}" "$S_has_v" "$S_has_a"
        if [ -f "$output_file" ]; then
            _diag_facts "$output_file" O
            printf '  output : readable=%s duration=%s video=%s audio=%s size=%s\n' "$O_readable" "${O_dur:-n/a}" "$O_has_v" "$O_has_a" "${O_size:-n/a}"
            if _diag_num "${S_dur:-}" && _diag_num "${O_dur:-}"; then
                printf '  output covers %s of the source (%s of %s)\n' \
                    "$(awk -v a="$O_dur" -v b="$S_dur" 'BEGIN { printf "%.1f%%", (b > 0) ? 100 * a / b : 0 }')" \
                    "$(_diag_hms "$O_dur")" "$(_diag_hms "$S_dur")"
            fi
            local sp op
            sp=$(_diag_video_packets "$input_file"); op=$(_diag_video_packets "$output_file")
            printf '  video packets: source=%s output=%s\n' "${sp:-n/a}" "${op:-n/a}"
        fi
        echo ""
        echo "Files kept: encoding.log, ffmpeg_raw.log, chunk_logs/, ffprobe_*.txt (when available)"
        echo "Next step : run the interactive diagnosis (offered after the batch, or main menu option 9)."
    } > "$rep" 2>/dev/null || true
    return 0
}

# key=value metadata (read back by diag_load_case; never sourced)
_diag_write_case_meta() {
    local case_dir="$1" input_file="$2" output_file="$3" rel="$4" orig_copy="$5" out_copy="$6" log_file="$7"
    local pix="${pix_fmt_arg:-}"
    {
        printf 'version=1\n'
        printf 'orig_path=%s\n' "$(_diag_one_line "$input_file")"
        printf 'rel_dir=%s\n' "$(_diag_one_line "$rel")"
        printf 'name=%s\n' "$(_diag_one_line "$(basename -- "$input_file")")"
        printf 'time=%s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
        printf 'category=%s\n' "${DIAG_FAIL_CATEGORY:-}"
        printf 'cause=%s\n' "${DIAG_FAIL_CAUSE:-}"
        printf 'context=%s\n' "${DIAG_FAIL_CONTEXT:-}"
        printf 'reason=%s\n' "$(_diag_one_line "${DIAG_FAIL_REASON:-}")"
        printf 'ffmpeg_rc=%s\n' "${DIAG_FAIL_RC:-}"
        printf 'original_copy=%s\n' "$orig_copy"
        printf 'output_copy=%s\n' "$out_copy"
        printf 'output_path=%s\n' "$(_diag_one_line "$output_file")"
        printf 'log_path=%s\n' "$(_diag_one_line "$log_file")"
        printf 'raw_log=%s\n' "$(_diag_one_line "${DIAG_FAIL_RAW_LOG:-}")"
        printf 'chunk_dir=%s\n' "$(_diag_one_line "${DIAG_FAIL_CHUNK_DIR:-}")"
        printf 'encode_mode=%s\n' "${DIAG_ENCODE_MODE:-single}"
        printf 'expected_duration=%s\n' "${duration:-}"
        printf 'job_vcodec=%s\n' "${VIDEO_CODEC:-}"
        printf 'job_crf=%s\n' "${CRF:-}"
        printf 'job_preset=%s\n' "${PRESET:-}"
        printf 'job_threads=%s\n' "${CPU_THREADS:-}"
        printf 'job_pix_fmt=%s\n' "$pix"
        printf 'job_vf=%s\n' "$(_diag_one_line "$(_diag_job_vf)")"
        printf 'job_acodec=%s\n' "${AUDIO_CODEC:-}"
        printf 'job_abitrate=%s\n' "${AUDIO_BITRATE:-}"
        printf 'job_format=%s\n' "${OUTPUT_FORMAT:-}"
        printf 'job_limits_on=%s\n' "${BITRATE_LIMITS_ENABLED:-0}"
        printf 'job_maxrate=%s\n' "${MAXRATE:-}"
        printf 'job_bufsize=%s\n' "${BUFSIZE:-}"
    } > "$case_dir/case.meta" 2>/dev/null || true
    return 0
}

# diag_handle_failure INPUT OUTPUT LOG_FILE [RELATIVE_DIR]   (called inside process_file)
diag_handle_failure() {
    local input_file="$1" output_file="$2" log_file="$3" relative_dir="${4:-}"
    classify_conversion_failure || true
    ui_err "FAILURE: ${DIAG_FAIL_CATEGORY:-UNKNOWN}  (suspected: ${DIAG_FAIL_CAUSE:-UNKNOWN})"
    _diag_say_log " FAILURE CLASSIFIED: ${DIAG_FAIL_CATEGORY:-UNKNOWN} / suspected ${DIAG_FAIL_CAUSE:-UNKNOWN} - ${DIAG_FAIL_REASON:-}"
    isolate_failed_media "$input_file" "$output_file" "$log_file" "$relative_dir" || true
    if [ "${#DIAG_CASE_DIRS[@]}" -gt 0 ]; then
        ui_warn "ISOLATED FOR DIAGNOSIS: ${DIAG_CASE_DIRS[${#DIAG_CASE_DIRS[@]}-1]}"
        _diag_say_log " ISOLATED FOR DIAGNOSIS: ${DIAG_CASE_DIRS[${#DIAG_CASE_DIRS[@]}-1]}"
    fi
    return 0
}

# Called from handle_termination (Ctrl+C / SIGTERM): keep what ffmpeg wrote so far.
diag_on_interrupt() {
    if [ -n "${DIAG_CURRENT_RAW_LOG:-}" ] && [ -s "${DIAG_CURRENT_RAW_LOG}" ]; then
        _diag_say_log " ENCODING INTERRUPTED - FFMPEG LOG SO FAR:"
        clean_output < "$DIAG_CURRENT_RAW_LOG" >> "${LOG_FILE:-/dev/null}" 2>/dev/null || true
        preserve_ffmpeg_logs "$DIAG_CURRENT_RAW_LOG" "interrupted by user/system" "130" >/dev/null || true
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Case registry + UI
# ---------------------------------------------------------------------------
# Load case.meta into DC_* globals (whitelisted keys only).
diag_load_case() {
    local case_dir="$1" k v meta="$1/case.meta"
    if [ ! -f "$meta" ]; then return 1; fi
    DC_DIR="$case_dir"
    DC_orig_path=""; DC_rel_dir=""; DC_name=""; DC_category=""; DC_cause=""; DC_context=""; DC_reason=""
    DC_ffmpeg_rc=""; DC_original_copy=""; DC_output_copy=""; DC_output_path=""; DC_log_path=""; DC_raw_log=""
    DC_chunk_dir=""; DC_encode_mode=""; DC_expected_duration=""; DC_time=""
    DC_job_vcodec=""; DC_job_crf=""; DC_job_preset=""; DC_job_threads=""; DC_job_pix_fmt=""; DC_job_vf=""
    DC_job_acodec=""; DC_job_abitrate=""; DC_job_format=""; DC_job_limits_on="0"; DC_job_maxrate=""; DC_job_bufsize=""
    while IFS='=' read -r k v || [ -n "$k" ]; do
        case "$k" in
            orig_path|rel_dir|name|category|cause|context|reason|ffmpeg_rc|original_copy|output_copy|output_path|\
            log_path|raw_log|chunk_dir|encode_mode|expected_duration|time|\
            job_vcodec|job_crf|job_preset|job_threads|job_pix_fmt|job_vf|job_acodec|job_abitrate|job_format|\
            job_limits_on|job_maxrate|job_bufsize)
                printf -v "DC_$k" '%s' "$v" ;;
        esac
    done < "$meta"
    return 0
}

# Original media for a case: the preserved copy, else the original location.
diag_case_source() {
    if [ -n "${DC_original_copy:-}" ] && [ -f "$DC_DIR/$DC_original_copy" ]; then
        printf '%s' "$DC_DIR/$DC_original_copy"
    elif [ -n "${DC_orig_path:-}" ] && [ -f "$DC_orig_path" ]; then
        printf '%s' "$DC_orig_path"
    fi
    return 0
}

diag_case_output() {
    if [ -n "${DC_output_copy:-}" ] && [ -f "$DC_DIR/$DC_output_copy" ]; then
        printf '%s' "$DC_DIR/$DC_output_copy"
    elif [ -n "${DC_output_path:-}" ] && [ -f "$DC_output_path" ]; then
        printf '%s' "$DC_output_path"
    fi
    return 0
}

_diag_list_cases() {   # session_dir -> prints case dirs, one per line
    find "$1" -name case.meta -type f 2>/dev/null | sort | while IFS= read -r m; do dirname "$m"; done
}

diag_show_isolated() {
    local session="$1" c n=0
    local cases=()
    mapfile -t cases < <(_diag_list_cases "$session")
    echo ""
    ui_section "ISOLATED FILES"
    for c in "${cases[@]}"; do
        n=$((n + 1))
        diag_load_case "$c" || continue
        echo ""
        ui_card "FILE $n" \
            "Name||$DC_name" \
            "Category|${COLOR_RED}|$DC_category" \
            "Suspected|${COLOR_YELLOW}|$DC_cause" \
            "Reason||$DC_reason" \
            "Original||${DC_original_copy:-?}" \
            "Output||${DC_output_copy:-none}" \
            "Folder||$c"
    done
    echo ""
    return 0
}

# Pick a case from a session and run the interactive diagnosis.
diag_open_session() {
    local session="$1" cases=() c i choice n
    mapfile -t cases < <(_diag_list_cases "$session")
    n=${#cases[@]}
    if [ "$n" -eq 0 ]; then ui_warn "No isolated files in this session"; return 0; fi
    while true; do
        if [ "$n" -eq 1 ]; then
            run_interactive_diagnosis "${cases[0]}" || true
            return 0
        fi
        echo ""
        ui_section "SELECT A FILE TO DIAGNOSE"
        for i in "${!cases[@]}"; do
            diag_load_case "${cases[$i]}" || continue
            ui_opt $((i + 1)) "$DC_name  ($DC_category)"
        done
        ui_opt 0 "Back"
        echo ""
        read -r -p "$(ui_prompt "FILE [0-$n]")" choice || return 0
        if [ "$choice" = "0" ] || [ -z "$choice" ]; then return 0; fi
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "$n" ]; then
            run_interactive_diagnosis "${cases[$((choice - 1))]}" || true
        else
            ui_err "Invalid choice"
        fi
    done
}

# Shown after the batch summary when files were isolated.
diag_post_batch_menu() {
    local choice
    if [ "${DIAG_ISOLATED_COUNT:-0}" -eq 0 ] || [ -z "$DIAG_SESSION_DIR" ]; then return 0; fi
    echo ""
    ui_section "DIAGNOSTIC RECOVERY"
    echo ""
    ui_hint "Some files encountered major conversion errors."
    echo ""
    ui_hint "Files isolated: $DIAG_ISOLATED_COUNT"
    ui_hint "Their original files, incomplete outputs and diagnostic logs have been preserved."
    echo ""
    ui_hint "Diagnostic folder:"
    printf '   %s%s%s\n' "${UI_PATH:-}" "$DIAG_SESSION_DIR/" "${UI_RST:-}"
    echo ""
    if [ ! -t 0 ]; then
        ui_note "Non-interactive run: nothing started. Diagnose later via main menu option 9."
        return 0
    fi
    while true; do
        echo ""
        ui_hint "Would you like to investigate these files now?"
        echo ""
        ui_opt 1 "Yes, start diagnosis"
        ui_opt 2 "No, return to main menu"
        ui_opt 3 "View isolated files and failure details"
        echo ""
        read -r -p "$(ui_prompt "SELECT [1-3]")" choice || choice="2"
        case "$choice" in
            1) diag_open_session "$DIAG_SESSION_DIR" ;;
            3) diag_show_isolated "$DIAG_SESSION_DIR" ;;
            2|"") ui_note "Everything stays preserved. Run it later from main menu option 9."; return 0 ;;
            *) ui_err "Invalid option" ;;
        esac
    done
}

# Main-menu entry: find earlier sessions and diagnose from them.
diag_standalone_menu() {
    local path root sessions=() s i choice n cand roots=()
    ui_submenu_title "DIAGNOSE ISOLATED FILES" "Open files that were isolated after failed conversions. Enter scans the default folders."
    read -r -p "$(ui_prompt "FOLDER")" path || path=""
    echo ""
    if [ -z "$path" ]; then
        roots=("$DEFAULT_INPUT_DIR_1" "$DEFAULT_INPUT_DIR_2")
        if [ -n "${INPUT_DIR:-}" ]; then roots+=("$INPUT_DIR"); fi
    else
        roots=("$path")
    fi
    for root in "${roots[@]}"; do
        root="${root%/}"
        if [ -z "$root" ]; then continue; fi
        if [ "$(basename -- "$root")" = "$DIAG_DIR_NAME" ]; then cand="$root"; else cand="$root/$DIAG_DIR_NAME"; fi
        if [ -f "$root/manifest.txt" ]; then sessions+=("$root"); continue; fi   # a session folder itself
        if [ -d "$cand" ]; then
            while IFS= read -r s; do
                if [ -f "$s/manifest.txt" ]; then sessions+=("$s"); fi
            done < <(find "$cand" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort -r)
        fi
    done
    n=${#sessions[@]}
    if [ "$n" -eq 0 ]; then
        ui_warn "No diagnostic sessions found"
        ui_pause 2
        return 0
    fi
    while true; do
        echo ""
        ui_section "DIAGNOSTIC SESSIONS"
        for i in "${!sessions[@]}"; do
            ui_opt $((i + 1)) "$(basename -- "${sessions[$i]}")  $(_ui_trunc "$(dirname -- "$(dirname -- "${sessions[$i]}")")" 40)"
        done
        ui_opt 0 "Back"
        echo ""
        read -r -p "$(ui_prompt "SESSION [0-$n]")" choice || return 0
        if [ "$choice" = "0" ] || [ -z "$choice" ]; then return 0; fi
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "$n" ]; then
            diag_show_isolated "${sessions[$((choice - 1))]}"
            diag_open_session "${sessions[$((choice - 1))]}"
        else
            ui_err "Invalid choice"
        fi
    done
}
