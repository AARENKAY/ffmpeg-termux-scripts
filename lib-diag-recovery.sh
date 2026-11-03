#!/bin/bash

# ==================== LOADING GUARD ====================
if [[ -n "${_LIB_DIAG_RECOVERY_LOADED+x}" ]]; then
    return 0  # Already loaded, skip
fi
readonly _LIB_DIAG_RECOVERY_LOADED=true
# ======================================================

# ===========================================================================
# DIAGNOSIS / RECOVERY MODULE - INTERACTIVE, ONE STEP AT A TIME
#   Needs lib-diagnostics.sh (helpers, case loading) and the ui_* functions.
#
# Stage 1 inspect original      Stage 5 video-only decode
# Stage 2 inspect output        Stage 6 audio-only decode
# Stage 3 video timestamps      Stage 7 compare + classify
# Stage 4 full decode           then: recovery menu (only options the findings support)
#
# Every test writes its full output into <case>/diagnosis/, every recovery
# artefact into <case>/recovery/. Originals are never modified or deleted.
# ===========================================================================

declare -g DR_DIAG_DIR="" DR_REC_DIR="" DR_SRC="" DR_OUT="" DR_NAV="" DR_RC=0 DR_EXP=""
declare -ga DR_CODEC_ARGS=()
declare -g R_V_STATE="" R_A_STATE="" R_FULL_STATE="" R_V_REACHED="" R_A_REACHED="" R_FULL_REACHED=""
declare -g R_V_ERRS="" R_A_ERRS="" R_FULL_ERRS="" R_V_FIRST_ERR="" R_A_FIRST_ERR="" R_FULL_FIRST_ERR=""
declare -g R_V_FRAMES="" R_TS_LAST="" R_TS_FRAMES="" R_CONCLUSION="" R_REC_VIDEO="" R_REC_AUDIO="" R_REC_FINAL=""

# ---------------------------------------------------------------------------
# Results persistence (so a later session can reuse what was already learned)
# ---------------------------------------------------------------------------
_dr_reset_results() {
    R_V_STATE=""; R_A_STATE=""; R_FULL_STATE=""; R_V_REACHED=""; R_A_REACHED=""; R_FULL_REACHED=""
    R_V_ERRS=""; R_A_ERRS=""; R_FULL_ERRS=""; R_V_FIRST_ERR=""; R_A_FIRST_ERR=""; R_FULL_FIRST_ERR=""
    R_V_FRAMES=""; R_TS_LAST=""; R_TS_FRAMES=""; R_CONCLUSION=""; R_REC_VIDEO=""; R_REC_AUDIO=""; R_REC_FINAL=""
    DS_readable=""; DO_readable=""
}

_dr_save_results() {
    {
        printf 'v_state=%s\na_state=%s\nfull_state=%s\n' "$R_V_STATE" "$R_A_STATE" "$R_FULL_STATE"
        printf 'v_reached=%s\na_reached=%s\nfull_reached=%s\n' "$R_V_REACHED" "$R_A_REACHED" "$R_FULL_REACHED"
        printf 'v_errs=%s\na_errs=%s\nfull_errs=%s\n' "$R_V_ERRS" "$R_A_ERRS" "$R_FULL_ERRS"
        printf 'v_first_err=%s\na_first_err=%s\nfull_first_err=%s\n' "$R_V_FIRST_ERR" "$R_A_FIRST_ERR" "$R_FULL_FIRST_ERR"
        printf 'v_frames=%s\nts_last=%s\nts_frames=%s\nconclusion=%s\n' "$R_V_FRAMES" "$R_TS_LAST" "$R_TS_FRAMES" "$R_CONCLUSION"
        printf 'rec_video=%s\nrec_audio=%s\nrec_final=%s\n' "$R_REC_VIDEO" "$R_REC_AUDIO" "$R_REC_FINAL"
    } > "$DR_DIAG_DIR/results.meta" 2>/dev/null || true
    return 0
}

_dr_load_results() {
    local k v f="$DR_DIAG_DIR/results.meta"
    if [ ! -f "$f" ]; then return 0; fi
    while IFS='=' read -r k v || [ -n "$k" ]; do
        case "$k" in
            v_state) R_V_STATE="$v" ;;          a_state) R_A_STATE="$v" ;;          full_state) R_FULL_STATE="$v" ;;
            v_reached) R_V_REACHED="$v" ;;      a_reached) R_A_REACHED="$v" ;;      full_reached) R_FULL_REACHED="$v" ;;
            v_errs) R_V_ERRS="$v" ;;            a_errs) R_A_ERRS="$v" ;;            full_errs) R_FULL_ERRS="$v" ;;
            v_first_err) R_V_FIRST_ERR="$v" ;;  a_first_err) R_A_FIRST_ERR="$v" ;;  full_first_err) R_FULL_FIRST_ERR="$v" ;;
            v_frames) R_V_FRAMES="$v" ;;        ts_last) R_TS_LAST="$v" ;;          ts_frames) R_TS_FRAMES="$v" ;;
            conclusion) R_CONCLUSION="$v" ;;
            rec_video) R_REC_VIDEO="$v" ;;      rec_audio) R_REC_AUDIO="$v" ;;      rec_final) R_REC_FINAL="$v" ;;
        esac
    done < "$f"
    # recovered files must still exist
    if [ -n "$R_REC_VIDEO" ] && [ ! -f "$R_REC_VIDEO" ]; then R_REC_VIDEO=""; fi
    if [ -n "$R_REC_AUDIO" ] && [ ! -f "$R_REC_AUDIO" ]; then R_REC_AUDIO=""; fi
    if [ -n "$R_REC_FINAL" ] && [ ! -f "$R_REC_FINAL" ]; then R_REC_FINAL=""; fi
    return 0
}

# ---------------------------------------------------------------------------
# Facts / navigation helpers
# ---------------------------------------------------------------------------
_dr_src_facts() {
    if [ -z "${DS_readable:-}" ] && [ -n "$DR_SRC" ]; then _diag_facts "$DR_SRC" DS; fi
    if _diag_num "${DS_dur:-}"; then DR_EXP="$DS_dur"
    elif _diag_num "${DC_expected_duration:-}"; then DR_EXP="$DC_expected_duration"
    else DR_EXP=""; fi
    return 0
}

_dr_out_facts() {
    if [ -z "${DO_readable:-}" ] && [ -n "$DR_OUT" ]; then _diag_facts "$DR_OUT" DO; fi
    return 0
}

# DR_NAV after asking before a stage runs: run | skip | back | quit
_dr_pre() {
    local ans
    while true; do
        echo ""
        ui_actions "Enter|Run|" "S|Skip|" "B|Back|" "L|Log location|" "Q|Stop|${UI_ERRC:-}"
        read -r -p "$(ui_prompt "ACTION")" ans || ans="q"
        case "${ans,,}" in
            ""|r|c) DR_NAV="run"; return 0 ;;
            s) DR_NAV="skip"; return 0 ;;
            b) DR_NAV="back"; return 0 ;;
            q) DR_NAV="quit"; return 0 ;;
            l) ui_note "Diagnosis files: $DR_DIAG_DIR" ;;
            *) ui_err "Choose Enter, S, B, L or Q" ;;
        esac
    done
}

# DR_NAV after a stage ran: next | retry | back | quit
_dr_post() {
    local ans
    while true; do
        echo ""
        ui_actions "Enter|Continue|" "R|Retry|" "B|Back|" "L|Log location|" "Q|Stop|${UI_ERRC:-}"
        read -r -p "$(ui_prompt "ACTION")" ans || ans="q"
        case "${ans,,}" in
            ""|c) DR_NAV="next"; return 0 ;;
            r) DR_NAV="retry"; return 0 ;;
            b) DR_NAV="back"; return 0 ;;
            q) DR_NAV="quit"; return 0 ;;
            l) ui_note "Diagnosis files: $DR_DIAG_DIR" ;;
            *) ui_err "Choose Enter, R, B, L or Q" ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# Decode runner (stdout+stderr captured completely, live progress, no FIFOs)
# ---------------------------------------------------------------------------
_diag_stats_args() {
    if ffmpeg -hide_banner -h full 2>/dev/null | grep -aq 'stats_period'; then printf '%s\n' "-stats_period" "1"; fi
    return 0
}

# _diag_run_decode OUT_FILE <ffmpeg args after the global options>; exit code -> DR_RC
_diag_run_decode() {
    local out="$1"; shift
    local raw="${out}.raw" pid rc=0 t sa=()
    mapfile -t sa < <(_diag_stats_args)
    ffmpeg -nostdin -hide_banner -loglevel info -stats "${sa[@]}" "$@" >"$raw" 2>&1 </dev/null &
    pid=$!
    while kill -0 "$pid" 2>/dev/null; do
        t=$(tail -c 600 "$raw" 2>/dev/null | tr '\r' '\n' | grep -ao 'time=[0-9:.]*' | tail -n1) || t=""
        printf '\r\033[2K    decoding... %s' "${t#time=}"
        sleep 1
    done
    wait "$pid" || rc=$?
    printf '\r\033[2K'
    if ! tr '\r' '\n' < "$raw" > "$out" 2>/dev/null; then cp -f "$raw" "$out" 2>/dev/null || true; fi
    rm -f "$raw"
    DR_RC=$rc
    return 0
}

# _diag_parse_decode FILE PREFIX -> PREFIX_reached/_errs/_first_err/_frames/_first_line
_diag_parse_decode() {
    local f="$1" p="$2" out
    out=$(awk '
        function secs(t,   a, n) { n = split(t, a, ":"); if (n == 3) return a[1]*3600 + a[2]*60 + a[3]; return -1 }
        {
            line = $0
            if (match(line, /time=[0-9]+:[0-9]+:[0-9.]+/)) {
                s = secs(substr(line, RSTART + 5, RLENGTH - 5)); if (s >= 0) { last = s; have = 1 }
            }
            if (match(line, /frame= *[0-9]+/)) { fr = substr(line, RSTART, RLENGTH); gsub(/[^0-9]/, "", fr); frames = fr }
            if (line !~ /^(frame=|size=|video:|Press|Input|Output|Stream|Metadata| |Duration)/ &&
                tolower(line) ~ /(error|invalid|corrupt|truncat|missing|non-monoton|overread|conceal|failed|unexpected end|premature)/) {
                n++
                if (n == 1) { first = (have ? last : ""); fl = line }   # unknown when no timestamp was printed yet
            }
        }
        END {
            printf "reached=%s\nerrs=%d\nfirst_err=%s\nframes=%s\nfirst_line=%s\n", (have ? last : ""), n + 0, (n > 0 ? first : ""), frames, fl
        }' "$f" 2>/dev/null) || out=""
    printf -v "${p}_reached" '%s' "$(_diag_kv "$out" reached)"
    printf -v "${p}_errs" '%s' "$(_diag_kv "$out" errs)"
    printf -v "${p}_first_err" '%s' "$(_diag_kv "$out" first_err)"
    printf -v "${p}_frames" '%s' "$(_diag_kv "$out" frames)"
    printf -v "${p}_first_line" '%s' "$(_diag_kv "$out" first_line | cut -c1-160)"
    return 0
}

# OK | WARN | SHORT | TRUNCATED | FAIL | NO_DATA
# SHORT = the stream decodes to the end of its *own* declared duration, which is
#         shorter than the container (not corruption by itself).
_diag_decode_state() {
    local rc="$1" reached="${2:-}" exp="${3:-}" native="${4:-}" errs="${5:-0}" tol lim
    if ! _diag_num "$reached"; then
        if [ "$rc" -ne 0 ]; then printf 'FAIL'; else printf 'NO_DATA'; fi
        return 0
    fi
    if ! _diag_num "$exp"; then
        if [ "$rc" -ne 0 ]; then printf 'FAIL'; elif [ "${errs:-0}" -gt 0 ]; then printf 'WARN'; else printf 'OK'; fi
        return 0
    fi
    tol=$(_diag_tol "$exp")
    lim=$(awk -v e="$exp" -v t="$tol" 'BEGIN { printf "%.3f", e - t }')
    if _diag_cmp "$reached" ">=" "$lim"; then
        if [ "$rc" -ne 0 ] || [ "${errs:-0}" -gt 0 ]; then printf 'WARN'; else printf 'OK'; fi
    else
        if _diag_num "$native" && _diag_cmp "$reached" ">=" "$(awk -v n="$native" -v t="$tol" 'BEGIN { printf "%.3f", n - t }')"; then
            printf 'SHORT'
        elif [ "$rc" -ne 0 ]; then printf 'FAIL'
        else printf 'TRUNCATED'; fi
    fi
    return 0
}

_dr_state_line() {   # LABEL STATE REACHED ERRS FIRST_ERR
    local label="$1" st="$2" reached="$3" errs="$4" first="$5" msg
    msg="$label: reached $(_diag_hms "$reached") of $(_diag_hms "$DR_EXP")"
    if [ "${errs:-0}" -gt 0 ]; then msg="$msg, $errs error line(s)"; fi
    if _diag_num "$first"; then msg="$msg, first near $(_diag_hms "$first")"; fi
    case "$st" in
        OK)        ui_ok "$msg" ;;
        WARN|SHORT) ui_warn "$msg" ;;
        NO_DATA)   ui_warn "$label: no usable result" ;;
        *)         ui_err "$msg" ;;
    esac
}

# ---------------------------------------------------------------------------
# Stages
# ---------------------------------------------------------------------------
_dr_stage_text() {   # N -> prints "title|what|why"
    case "$1" in
        1) echo "INSPECT ORIGINAL|Reads the container, video and audio stream details of the original file.|Shows what should be in the file, and whether it can be opened at all." ;;
        2) echo "INSPECT INCOMPLETE OUTPUT|Reads the same details from the file the converter produced and compares them with the original.|Shows missing streams, a shortened timeline or odd frame counts." ;;
        3) echo "VIDEO TIMESTAMPS|Lists the timestamp of every decoded video frame of the original.|Shows whether the video timeline really reaches the end. Can take a while." ;;
        4) echo "FULL DECODE OF ORIGINAL|Decodes video and first audio track completely without encoding anything.|Shows whether the source decodes without errors and where it stops. Can take a while." ;;
        5) echo "VIDEO-ONLY DECODE|Decodes only the video stream.|Tells whether the video alone is healthy, independent of the audio." ;;
        6) echo "AUDIO-ONLY DECODE|Decodes only the first audio stream.|Tells whether the audio alone is healthy, independent of the video." ;;
        7) echo "COMPARE AND CLASSIFY|Combines everything found so far.|Decides which stream is damaged and which recovery options make sense." ;;
    esac
}

_dr_stage1() {
    local f="$DR_SRC" vline aline
    _diag_facts "$f" DS
    ffprobe -hide_banner -v warning -show_format -show_streams "$f" > "$DR_DIAG_DIR/01_original_probe.txt" 2>&1 </dev/null || true
    _dr_src_facts
    if [ "${DS_readable:-0}" != "1" ]; then
        ui_err "FFprobe cannot open the original: the container or its index is probably damaged"
        ui_note "Details: $DR_DIAG_DIR/01_original_probe.txt"
        return 0
    fi
    vline="none"; aline="none"
    if [ "$DS_has_v" = "1" ]; then
        vline="${DS_v_codec:-?} ${DS_v_w:-?}x${DS_v_h:-?} ${DS_v_pix:-?} ${DS_v_fps:-?}fps"
    fi
    if [ "$DS_has_a" = "1" ]; then aline="${DS_a_codec:-?} ${DS_a_rate:-?}Hz ${DS_a_ch:-?}ch"; fi
    ui_card "ORIGINAL" \
        "Container||${DS_fmt:-?}" \
        "Duration||$(_diag_hms "${DS_dur:-}")" \
        "Video||$vline" \
        "  time base||${DS_v_tb:-n/a}   start ${DS_v_start:-n/a}" \
        "  duration||$(_diag_hms "${DS_v_dur:-}")   frames ${DS_v_nb:-n/a}" \
        "Audio||$aline" \
        "  duration||$(_diag_hms "${DS_a_dur:-}")   start ${DS_a_start:-n/a}" \
        "Other streams||${DS_n_other:-0}"
    if [ "$DS_has_v" != "1" ]; then ui_warn "The original has no video stream"; else ui_ok "Video stream found"; fi
    if [ "$DS_has_a" != "1" ]; then ui_note "The original has no audio stream, so audio tests will be skipped"; else ui_ok "Audio stream found"; fi
    if ! _diag_num "${DS_dur:-}"; then ui_warn "Container duration is unknown (metadata missing, not proof of damage)"; fi
    ui_note "Full output: $DR_DIAG_DIR/01_original_probe.txt"
    return 0
}

_dr_stage2() {
    local sp op cmp="$DR_DIAG_DIR/02_output_probe.txt"
    if [ -z "$DR_OUT" ]; then
        ui_note "No incomplete output was produced (or it could not be preserved) - nothing to inspect"
        return 0
    fi
    _dr_src_facts
    _diag_facts "$DR_OUT" DO
    ffprobe -hide_banner -v warning -show_format -show_streams "$DR_OUT" > "$cmp" 2>&1 </dev/null || true
    if [ "${DO_readable:-0}" != "1" ]; then
        ui_err "FFprobe cannot open the output (unfinished or damaged container)"
        ui_note "Details: $cmp"
        return 0
    fi
    sp=$(_diag_video_packets "$DR_SRC"); op=$(_diag_video_packets "$DR_OUT")
    {
        echo ""
        echo "---- comparison ----"
        echo "source duration : ${DS_dur:-n/a}"
        echo "output duration : ${DO_dur:-n/a}"
        echo "video packets   : source=${sp:-n/a} output=${op:-n/a}"
    } >> "$cmp"
    ui_card "OUTPUT vs ORIGINAL" \
        "Duration||$(_diag_hms "${DO_dur:-}")  (original $(_diag_hms "${DS_dur:-}"))" \
        "Video stream||$([ "${DO_has_v:-0}" = 1 ] && echo "present (${DO_v_codec:-?})" || echo MISSING)" \
        "Audio stream||$([ "${DO_has_a:-0}" = 1 ] && echo "present (${DO_a_codec:-?})" || echo "absent")" \
        "Video packets||${op:-n/a}  (original ${sp:-n/a})"
    if [ "${DS_has_v:-0}" = 1 ] && [ "${DO_has_v:-0}" != 1 ]; then ui_err "Video stream is missing in the output"; fi
    if [ "${DS_has_a:-0}" = 1 ] && [ "${DO_has_a:-0}" != 1 ]; then ui_err "The original has audio but the output has none"; fi
    if _diag_num "${DS_dur:-}" && _diag_num "${DO_dur:-}"; then
        if _diag_cmp "${DO_dur}" "<" "$(awk -v e="$DS_dur" -v t="$(_diag_tol "$DS_dur")" 'BEGIN { printf "%.3f", e - t }')"; then
            ui_err "The output is shorter by $(_diag_hms "$(awk -v a="$DS_dur" -v b="$DO_dur" 'BEGIN { printf "%.3f", a - b }')")"
        else
            ui_ok "Output duration matches the original"
        fi
    fi
    if [[ "${sp:-}" =~ ^[0-9]+$ ]] && [[ "${op:-}" =~ ^[0-9]+$ ]] && [ "$sp" -gt 0 ]; then
        if [ "$op" -lt $(( sp * 995 / 1000 )) ]; then ui_warn "Output has fewer video packets ($op) than the original ($sp)"; fi
    fi
    ui_note "Full output: $cmp"
    return 0
}

_dr_stage3() {
    local csv="$DR_DIAG_DIR/03_video_timestamps.csv" pid rc=0 last n
    _dr_src_facts
    if [ "${DS_has_v:-0}" != "1" ]; then ui_warn "No video stream in the original - skipped"; return 0; fi
    ffprobe -v error -select_streams v:0 -show_frames -show_entries frame=best_effort_timestamp_time \
        -of csv=p=0 "$DR_SRC" > "$csv" 2> "$DR_DIAG_DIR/03_video_timestamps.err" </dev/null &
    pid=$!
    while kill -0 "$pid" 2>/dev/null; do
        printf '\r\033[2K    reading frames... %s lines' "$(wc -l < "$csv" 2>/dev/null || echo 0)"
        sleep 1
    done
    wait "$pid" || rc=$?
    printf '\r\033[2K'
    last=$(grep -aE '^[0-9]' "$csv" 2>/dev/null | tail -n1) || last=""
    n=$(grep -acE '^[0-9]' "$csv" 2>/dev/null) || n=0
    R_TS_LAST="$last"; R_TS_FRAMES="$n"
    if ! _diag_num "$last"; then
        ui_warn "No usable frame timestamps were returned (exit code $rc)"
        ui_note "Details: $DR_DIAG_DIR/03_video_timestamps.err"
        return 0
    fi
    ui_note "Last timestamps: $(grep -aE '^[0-9]' "$csv" | tail -n3 | tr '\n' ' ')"
    if [ "$rc" -ne 0 ]; then ui_warn "FFprobe ended with exit code $rc while reading frames"; fi
    if _diag_num "$DR_EXP" && _diag_cmp "$last" "<" "$(awk -v e="$DR_EXP" -v t="$(_diag_tol "$DR_EXP")" 'BEGIN { printf "%.3f", e - t }')"; then
        ui_err "The video timeline stops at $(_diag_hms "$last"), expected $(_diag_hms "$DR_EXP")"
    else
        ui_ok "The video timeline reaches $(_diag_hms "$last") ($n frames)"
    fi
    ui_note "Complete list: $csv"
    return 0
}

_dr_stage4() {
    _dr_src_facts
    _diag_run_decode "$DR_DIAG_DIR/04_full_decode.txt" -i "$DR_SRC" -map 0:v:0 -map '0:a:0?' -f null -
    _diag_parse_decode "$DR_DIAG_DIR/04_full_decode.txt" FD
    R_FULL_REACHED="${FD_reached:-}"; R_FULL_ERRS="${FD_errs:-0}"; R_FULL_FIRST_ERR="${FD_first_err:-}"
    R_FULL_STATE=$(_diag_decode_state "$DR_RC" "$R_FULL_REACHED" "$DR_EXP" "" "$R_FULL_ERRS")
    _dr_state_line "Full decode" "$R_FULL_STATE" "$R_FULL_REACHED" "$R_FULL_ERRS" "$R_FULL_FIRST_ERR"
    if [ "$DR_RC" -ne 0 ]; then ui_warn "FFmpeg exit code: $DR_RC"; fi
    if [ -n "${FD_first_line:-}" ]; then ui_note "First error: $FD_first_line"; fi
    ui_note "Complete output: $DR_DIAG_DIR/04_full_decode.txt"
    return 0
}

_dr_stage5() {
    _dr_src_facts
    if [ "${DS_has_v:-0}" != "1" ]; then ui_warn "No video stream - skipped"; R_V_STATE="NO_DATA"; return 0; fi
    _diag_run_decode "$DR_DIAG_DIR/05_video_decode.txt" -i "$DR_SRC" -map 0:v:0 -an -f null -
    _diag_parse_decode "$DR_DIAG_DIR/05_video_decode.txt" VD
    R_V_REACHED="${VD_reached:-}"; R_V_ERRS="${VD_errs:-0}"; R_V_FIRST_ERR="${VD_first_err:-}"; R_V_FRAMES="${VD_frames:-}"
    R_V_STATE=$(_diag_decode_state "$DR_RC" "$R_V_REACHED" "$DR_EXP" "${DS_v_dur:-}" "$R_V_ERRS")
    _dr_state_line "Video" "$R_V_STATE" "$R_V_REACHED" "$R_V_ERRS" "$R_V_FIRST_ERR"
    if [ "$DR_RC" -ne 0 ]; then ui_warn "FFmpeg exit code: $DR_RC"; fi
    if [ -n "${VD_first_line:-}" ]; then ui_note "First error: $VD_first_line"; fi
    ui_note "Complete output: $DR_DIAG_DIR/05_video_decode.txt"
    return 0
}

_dr_stage6() {
    _dr_src_facts
    if [ "${DS_has_a:-0}" != "1" ]; then
        R_A_STATE="NONE"
        ui_note "The original has no audio stream - audio test skipped, nothing to recover"
        return 0
    fi
    _diag_run_decode "$DR_DIAG_DIR/06_audio_decode.txt" -i "$DR_SRC" -map 0:a:0 -vn -f null -
    _diag_parse_decode "$DR_DIAG_DIR/06_audio_decode.txt" AD
    R_A_REACHED="${AD_reached:-}"; R_A_ERRS="${AD_errs:-0}"; R_A_FIRST_ERR="${AD_first_err:-}"
    R_A_STATE=$(_diag_decode_state "$DR_RC" "$R_A_REACHED" "$DR_EXP" "${DS_a_dur:-}" "$R_A_ERRS")
    _dr_state_line "Audio" "$R_A_STATE" "$R_A_REACHED" "$R_A_ERRS" "$R_A_FIRST_ERR"
    if [ "$DR_RC" -ne 0 ]; then ui_warn "FFmpeg exit code: $DR_RC"; fi
    if [ -n "${AD_first_line:-}" ]; then ui_note "First error: $AD_first_line"; fi
    ui_note "Complete output: $DR_DIAG_DIR/06_audio_decode.txt"
    return 0
}

_dr_bad() { [ "$1" = "FAIL" ] || [ "$1" = "TRUNCATED" ]; }

_dr_stage7() {
    local vs="${R_V_STATE:-}" as="${R_A_STATE:-}" fs="${R_FULL_STATE:-}" txt="" tol out_d="" code
    _dr_src_facts; _dr_out_facts
    if [ -n "$DR_OUT" ] && [ "${DO_readable:-0}" = "1" ]; then out_d="${DO_dur:-}"; fi

    if [ "${DS_readable:-0}" != "1" ]; then
        code="CONTAINER"
        txt="The original cannot be opened by FFprobe. This points to a damaged container or index, not to a specific stream."
    elif [ -z "$vs" ] && [ -z "$as" ] && [ -z "$fs" ]; then
        code="INCONCLUSIVE"
        txt="No decode test has been run yet, so no conclusion can be drawn."
    elif _dr_bad "$vs" && _dr_bad "$as"; then
        code="BOTH_CORRUPT"
        txt="Both streams fail: video reaches $(_diag_hms "$R_V_REACHED") and audio reaches $(_diag_hms "$R_A_REACHED") of $(_diag_hms "$DR_EXP")."
    elif _dr_bad "$vs"; then
        code="VIDEO_CORRUPT"
        txt="The video stream stops or fails at $(_diag_hms "$R_V_REACHED") of $(_diag_hms "$DR_EXP"); the audio stream is $(printf '%s' "$as" | tr 'A-Z' 'a-z')."
    elif _dr_bad "$as"; then
        code="AUDIO_CORRUPT"
        txt="The video stream decodes through its expected duration ($(_diag_hms "$R_V_REACHED") of $(_diag_hms "$DR_EXP")), but the audio stream stops or fails at $(_diag_hms "$R_A_REACHED")."
        if _diag_num "$out_d" && _diag_num "$R_A_REACHED"; then
            if _diag_cmp "$(awk -v a="$out_d" -v b="$R_A_REACHED" 'BEGIN { d = a - b; if (d < 0) d = -d; print d }')" "<=" "5"; then
                txt="$txt The incomplete output ($(_diag_hms "$out_d")) ends where audio decoding ends, so FFmpeg's handling of the damaged audio most likely cut the output short."
            else
                txt="$txt The incomplete output ends at $(_diag_hms "$out_d"), which does not line up with where audio stops, so another cause may also be involved."
            fi
        fi
    elif [ "$fs" = "FAIL" ] || [ "$fs" = "TRUNCATED" ]; then
        code="TIMESTAMP_OR_CONTAINER"
        txt="Video and audio decode correctly on their own, but decoding them together fails. Interleaving, timestamps or the container index are the likely cause."
    elif [ "$vs" = "WARN" ] || [ "$as" = "WARN" ] || [ "$fs" = "WARN" ]; then
        if _diag_num "$R_TS_LAST" && _diag_num "$DR_EXP" && _diag_cmp "$R_TS_LAST" "<" "$(awk -v e="$DR_EXP" -v t="$(_diag_tol "$DR_EXP")" 'BEGIN { printf "%.3f", e - t }')"; then
            code="TIMESTAMP_PROBLEM"
            txt="Both streams decode to the end with warnings, but the video timestamps stop at $(_diag_hms "$R_TS_LAST"). The problem is in the timestamps."
        else
            code="MINOR_SOURCE_ERRORS"
            txt="Both streams decode to the end, with some decoder warnings (video $R_V_ERRS, audio ${R_A_ERRS:-0}). The source is readable; the original failure was probably not caused by the media itself."
        fi
    elif { [ "$vs" = "OK" ] || [ "$vs" = "SHORT" ]; } && { [ "$as" = "OK" ] || [ "$as" = "SHORT" ] || [ "$as" = "NONE" ]; }; then
        code="ENCODER_SIDE"
        txt="The streams of the original decode cleanly through their full length. The failure happened on the encoding side (category ${DC_category:-unknown}), not in the source."
    else
        code="INCONCLUSIVE"
        txt="The tests that ran do not give a clear answer. Run the skipped tests, or retry the ones that returned no data."
    fi
    R_CONCLUSION="$code"
    {
        echo "DIAGNOSIS SUMMARY - ${DC_name:-}"
        echo "Original duration : $(_diag_hms "$DR_EXP")"
        echo "Full decode       : ${fs:-not run}  reached $(_diag_hms "$R_FULL_REACHED")"
        echo "Video decode      : ${vs:-not run}  reached $(_diag_hms "$R_V_REACHED")  errors ${R_V_ERRS:-0}"
        echo "Audio decode      : ${as:-not run}  reached $(_diag_hms "$R_A_REACHED")  errors ${R_A_ERRS:-0}"
        echo "Output duration   : $(_diag_hms "$out_d")"
        echo "Conclusion        : $code"
        echo "$txt"
    } > "$DR_DIAG_DIR/07_summary.txt" 2>/dev/null || true

    ui_card "SOURCE DIAGNOSTIC RESULTS" \
        "Original|${COLOR_GREEN}|preserved" \
        "Incomplete output|${COLOR_GREEN}|$([ -n "$DR_OUT" ] && echo preserved || echo "none")" \
        "Video stream||${vs:-not tested} ($(_diag_hms "$R_V_REACHED"))" \
        "Audio stream||${as:-not tested} ($(_diag_hms "$R_A_REACHED"))" \
        "Conclusion|${COLOR_YELLOW}|$code"
    _ui_wrap_print "  " $((UI_W - 3)) "$txt" ""
    ui_note "Summary file: $DR_DIAG_DIR/07_summary.txt"
    _dr_save_results
    return 0
}

# ---------------------------------------------------------------------------
# Main interactive loop
# ---------------------------------------------------------------------------
run_interactive_diagnosis() {
    local case_dir="$1" idx=1 total=7 text title what why
    if ! diag_load_case "$case_dir"; then ui_err "Not a diagnostic case folder: $case_dir"; return 1; fi
    DR_DIAG_DIR="$case_dir/diagnosis"; DR_REC_DIR="$case_dir/recovery"
    mkdir -p "$DR_DIAG_DIR" "$DR_REC_DIR" 2>/dev/null || { ui_err "Cannot write to $case_dir"; return 1; }
    DR_SRC=$(diag_case_source); DR_OUT=$(diag_case_output)
    _dr_reset_results; _dr_load_results
    if [ -z "$DR_SRC" ]; then
        ui_err "The original file is not available (copy failed and the source moved)"
        ui_note "Original location: ${DC_orig_path:-?}"
        return 1
    fi
    _dr_src_facts

    echo ""
    ui_card "DIAGNOSING" \
        "File||$DC_name" \
        "Failure|${COLOR_RED}|$DC_category" \
        "Suspected|${COLOR_YELLOW}|$DC_cause" \
        "Reason||$DC_reason"
    ui_note "Nothing below modifies or deletes your files. Q stops at any time."

    while [ "$idx" -le "$total" ]; do
        text=$(_dr_stage_text "$idx")
        title="${text%%|*}"; text="${text#*|}"; what="${text%%|*}"; why="${text#*|}"
        echo ""
        ui_section "STEP $idx/$total  $title"
        ui_hint "What: $what"
        ui_hint "Why:  $why"
        _dr_pre
        case "$DR_NAV" in
            quit) ui_ok "Stopped. Everything is preserved in: $case_dir"; return 0 ;;
            back) if [ "$idx" -gt 1 ]; then idx=$((idx - 1)); fi; continue ;;
            skip) ui_note "Skipped"; idx=$((idx + 1)); continue ;;
        esac
        while true; do
            "_dr_stage$idx" || true
            _dr_save_results
            _dr_post
            if [ "$DR_NAV" != "retry" ]; then break; fi
        done
        case "$DR_NAV" in
            quit) ui_ok "Stopped. Everything is preserved in: $case_dir"; return 0 ;;
            back) if [ "$idx" -gt 1 ]; then idx=$((idx - 1)); fi ;;
            *)    idx=$((idx + 1)) ;;
        esac
    done
    diag_recovery_menu
    return 0
}

# ---------------------------------------------------------------------------
# Recovery
# ---------------------------------------------------------------------------
_dr_unique_path() {   # DIR BASE EXT -> unused path
    local d="$1" b="$2" e="$3" n=1 p
    p="$d/$b.$e"
    while [ -e "$p" ]; do n=$((n + 1)); p="$d/${b}_$n.$e"; done
    printf '%s' "$p"
}

_dr_codec_args() {   # same encoder options the converter itself uses
    local thr="${DC_job_threads:-2}"
    case "${DC_job_vcodec:-}" in
        libx264)            DR_CODEC_ARGS=(-threads "$thr") ;;
        libx265)            DR_CODEC_ARGS=(-x265-params "pools=$thr") ;;
        libsvtav1)          DR_CODEC_ARGS=(-svtav1-params "lp=$thr") ;;
        libvpx|libvpx-vp9)  DR_CODEC_ARGS=(-threads "$thr" -tile-columns 0 -row-mt 0 -cpu-used 5) ;;
        *)                  DR_CODEC_ARGS=(-threads "$thr") ;;
    esac
}

# _dr_run_ffmpeg LABEL EXPECTED_SECS LOG_FILE OUT_FILE <full ffmpeg command without output>
# Live percentage from a plain progress file in private temp storage; exit code -> DR_RC.
_dr_run_ffmpeg() {
    local label="$1" exp="$2" logf="$3" out="$4"; shift 4
    local sd pf pid rc=0 t pct
    sd=$(_diag_scratch); pf="${sd:-/tmp}/progress.txt"; : > "$pf" 2>/dev/null || true
    "$@" -progress "$pf" -nostats "$out" >/dev/null 2>"$logf" </dev/null &
    pid=$!
    while kill -0 "$pid" 2>/dev/null; do
        t=$(grep -a '^out_time_us=' "$pf" 2>/dev/null | tail -n1 | cut -d= -f2) || t=""
        if [[ "$t" =~ ^[0-9]+$ ]]; then
            t=$(awk -v u="$t" 'BEGIN { printf "%.1f", u / 1000000 }')
            if _diag_num "$exp"; then pct=$(awk -v s="$t" -v e="$exp" 'BEGIN { p = (e > 0) ? 100 * s / e : 0; if (p > 100) p = 100; printf "%d", p }'); else pct="?"; fi
            printf '\r\033[2K    %s %s%%  %s / %s' "$label" "$pct" "$(_diag_hms "$t")" "$(_diag_hms "$exp")"
        else
            printf '\r\033[2K    %s starting...' "$label"
        fi
        sleep 1
    done
    wait "$pid" || rc=$?
    printf '\r\033[2K'
    if [ -n "$sd" ]; then rm -rf "$sd"; fi
    DR_RC=$rc
    return 0
}

_dr_show_job_settings() {
    ui_card "SETTINGS (unchanged from the original job)" \
        "Video codec||${DC_job_vcodec:-?}" \
        "CRF / preset||${DC_job_crf:-?} / ${DC_job_preset:-?}" \
        "Pixel format||${DC_job_pix_fmt:-keep source}" \
        "Filters||${DC_job_vf:-none}" \
        "Threads||${DC_job_threads:-?}" \
        "Audio||${DC_job_acodec:-?} ${DC_job_abitrate:-?}k"
}

recover_video_stream() {
    local out log cmd=() vf="${DC_job_vf:-}"
    _dr_src_facts
    ui_hint "The original video stream is encoded again on its own, without audio. Frame timing is kept; encoder settings are not changed."
    if [ "$R_V_STATE" = "TRUNCATED" ] || [ "$R_V_STATE" = "FAIL" ]; then
        ui_warn "The video only decodes up to $(_diag_hms "$R_V_REACHED") - only that part can be recovered"
    fi
    _dr_show_job_settings
    if ! command -v ffmpeg >/dev/null 2>&1; then ui_err "ffmpeg is not available"; return 0; fi
    if ! ui_confirm "Start video recovery?" Y; then return 0; fi
    _dr_codec_args
    out=$(_dr_unique_path "$DR_REC_DIR" "recovered_video" "${DC_job_format:-mkv}")
    log="${out%.*}.log"
    cmd=(ffmpeg -nostdin -hide_banner -loglevel warning -y
         -fflags +discardcorrupt+genpts+igndts+ignidx -max_error_rate 1.0
         -analyzeduration 100M -probesize 10M -err_detect ignore_err
         -i "$DR_SRC" -map 0:v:0 -an)
    if [ -n "$vf" ]; then cmd+=(-vf "$vf"); fi
    cmd+=(-max_muxing_queue_size 1024 -avoid_negative_ts make_zero
          -c:v "${DC_job_vcodec:-libx264}" "${DR_CODEC_ARGS[@]}" -crf "${DC_job_crf:-23}")
    if [ "${DC_job_limits_on:-0}" = "1" ]; then cmd+=(-maxrate "$DC_job_maxrate" -bufsize "$DC_job_bufsize"); fi
    cmd+=(-preset "${DC_job_preset:-medium}")
    if [ -n "${DC_job_pix_fmt:-}" ]; then cmd+=(-pix_fmt "$DC_job_pix_fmt"); fi
    _dr_run_ffmpeg "VIDEO" "$DR_EXP" "$log" "$out" "${cmd[@]}"
    if [ "$DR_RC" -ne 0 ] || [ ! -s "$out" ]; then
        ui_err "Video recovery failed (exit code $DR_RC). Log: $log"
        return 0
    fi
    R_REC_VIDEO="$out"; _dr_save_results
    ui_ok "Video written: $out"
    verify_recovered_output "$out" video || true
    return 0
}

recover_audio_stream() {
    local out log cmd=() ac="${DC_job_acodec:-libopus}" ab="${DC_job_abitrate:-80}"
    _dr_src_facts
    ui_hint "The original audio is re-encoded on its own. Corrupt audio packets are discarded; audio that is truly damaged cannot be reconstructed."
    if [ "$R_A_STATE" = "TRUNCATED" ] || [ "$R_A_STATE" = "FAIL" ]; then
        ui_warn "The audio only decodes up to $(_diag_hms "$R_A_REACHED") - nothing can be recovered after that point"
    fi
    ui_card "SETTINGS (unchanged from the original job)" "Audio codec||$ac" "Bitrate||${ab}k"
    if ! ui_confirm "Start audio recovery?" Y; then return 0; fi
    out=$(_dr_unique_path "$DR_REC_DIR" "recovered_audio" "mka")
    log="${out%.*}.log"
    cmd=(ffmpeg -nostdin -hide_banner -loglevel warning -y
         -fflags +discardcorrupt+genpts -err_detect ignore_err
         -i "$DR_SRC" -map 0:a:0 -vn)
    if [ "$ac" = "copy" ]; then cmd+=(-c:a copy); else cmd+=(-c:a "$ac" -b:a "${ab}k" -ar 48000); fi
    _dr_run_ffmpeg "AUDIO" "$DR_EXP" "$log" "$out" "${cmd[@]}"
    if [ "$DR_RC" -ne 0 ] || [ ! -s "$out" ]; then
        ui_err "Audio recovery failed (exit code $DR_RC). Log: $log"
        return 0
    fi
    R_REC_AUDIO="$out"; _dr_save_results
    ui_ok "Audio written: $out"
    verify_recovered_output "$out" audio || true
    return 0
}

mux_recovered_streams() {
    local out log cmd=() fmt="${DC_job_format:-mkv}"
    if [ -z "$R_REC_VIDEO" ] || [ -z "$R_REC_AUDIO" ]; then ui_err "Both recovered streams are needed"; return 0; fi
    ui_hint "Recovered video and audio are combined without re-encoding. The longer stream is never cut to the shorter one."
    out=$(_dr_unique_path "$DR_REC_DIR" "recovered_final" "$fmt")
    log="${out%.*}.log"
    cmd=(ffmpeg -nostdin -hide_banner -loglevel warning -y -i "$R_REC_VIDEO" -i "$R_REC_AUDIO"
         -map 0:v:0 -map 1:a:0 -c copy)
    if [ "$fmt" = "mp4" ]; then cmd+=(-movflags +faststart); fi
    _dr_run_ffmpeg "MUX" "$DR_EXP" "$log" "$out" "${cmd[@]}"
    if [ "$DR_RC" -ne 0 ] || [ ! -s "$out" ]; then
        ui_err "Muxing failed (exit code $DR_RC). Log: $log"
        return 0
    fi
    R_REC_FINAL="$out"; _dr_save_results
    ui_ok "Final file written: $out"
    verify_recovered_output "$out" final || true
    return 0
}

video_only_output() {
    local out fmt="${DC_job_format:-mkv}"
    if [ -z "$R_REC_VIDEO" ]; then ui_err "Recover the video first"; return 0; fi
    ui_warn "The result will have NO AUDIO."
    if ! ui_confirm "Create a video-only file?" N; then return 0; fi
    out=$(_dr_unique_path "$DR_REC_DIR" "recovered_video_only" "$fmt")
    if cp -f -- "$R_REC_VIDEO" "$out" 2>/dev/null; then
        R_REC_FINAL="$out"; _dr_save_results
        ui_ok "Video-only file: $out"
    else
        ui_err "Could not create the video-only file"
    fi
    return 0
}

# Copies the finished recovery into the normal output folder (asks first).
install_recovered_output() {
    local dest="${DC_output_path:-}" src="$R_REC_FINAL" alt
    if [ -z "$src" ] || [ ! -f "$src" ]; then ui_err "No finished recovery file yet"; return 0; fi
    if [ -z "$dest" ]; then ui_err "Original output location unknown"; return 0; fi
    if [ -e "$dest" ]; then
        ui_warn "A file already exists at: $dest"
        if ! ui_confirm "Overwrite it with the recovered file?" N; then
            alt="${dest%.*}_recovered.${dest##*.}"
            if [ -e "$alt" ]; then ui_warn "$alt also exists - nothing copied"; return 0; fi
            dest="$alt"
        fi
    fi
    mkdir -p "$(dirname -- "$dest")" 2>/dev/null || true
    if cp -f -- "$src" "$dest" 2>/dev/null; then
        ui_ok "Copied to: $dest"
        if ui_confirm "Mark the original as completed so the next batch skips it?" Y; then
            mark_completed "$DC_orig_path" && ui_ok "Marked as completed"
        fi
    else
        ui_err "Copy failed"
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Verification - never trusts the exit code alone
# ---------------------------------------------------------------------------
verify_recovered_output() {
    local f="$1" kind="$2" fails=0 warns=0 tol vt at vdur adur rp target tolp rep
    local lines=()
    rep="${f%.*}.verify.txt"
    _dr_src_facts
    _diag_facts "$f" RV
    tol=$(_diag_tol "${DR_EXP:-0}")

    if [ "${RV_readable:-0}" != "1" ]; then
        lines+=("FAIL  cannot be opened by FFprobe"); fails=$((fails + 1))
    else
        if [ "$kind" != "audio" ]; then
            if [ "${RV_has_v:-0}" = "1" ]; then lines+=("PASS  video stream present"); else lines+=("FAIL  no video stream"); fails=$((fails + 1)); fi
        fi
        if [ "$kind" = "audio" ] || [ "$kind" = "final" ]; then
            if [ "${RV_has_a:-0}" = "1" ]; then lines+=("PASS  audio stream present")
            elif [ "$kind" = "audio" ] || [ -n "$R_REC_AUDIO" ]; then lines+=("FAIL  no audio stream"); fails=$((fails + 1)); fi
        fi
        # --- video timeline ---
        if [ "$kind" != "audio" ] && _diag_num "${DR_EXP:-}"; then
            vdur="${RV_v_dur:-${RV_dur:-}}"
            if _dr_bad "${R_V_STATE:-}" && _diag_num "${R_V_REACHED:-}"; then vt="$R_V_REACHED"; else vt="$DR_EXP"; fi
            if _diag_num "$vdur"; then
                if _diag_cmp "$vdur" ">=" "$(awk -v a="$vt" -v t="$tol" 'BEGIN { printf "%.3f", a - t }')"; then
                    lines+=("PASS  video duration $(_diag_hms "$vdur") (expected $(_diag_hms "$vt"))")
                else
                    lines+=("FAIL  video is truncated: $(_diag_hms "$vdur") of $(_diag_hms "$vt")"); fails=$((fails + 1))
                fi
            else
                lines+=("WARN  video duration unknown"); warns=$((warns + 1))
            fi
            if _dr_bad "${R_V_STATE:-}" && _diag_num "${R_V_REACHED:-}"; then
                lines+=("WARN  the source video is only decodable until $(_diag_hms "$R_V_REACHED") of $(_diag_hms "$DR_EXP"): the recovered file ends there"); warns=$((warns + 1))
            fi
            # --- video frame count (packets, no decoding) ---
            rp=$(_diag_video_packets "$f")
            target="${R_V_FRAMES:-}"
            if ! [[ "$target" =~ ^[0-9]+$ ]]; then target=$(_diag_video_packets "$DR_SRC"); fi
            if [[ "${rp:-}" =~ ^[0-9]+$ ]] && [[ "${target:-}" =~ ^[0-9]+$ ]] && [ "$target" -gt 0 ]; then
                tolp=$(( target / 200 + 2 ))
                if [ "$rp" -ge $(( target - tolp )) ] && [ "$rp" -le $(( target + tolp )) ]; then
                    lines+=("PASS  video frames $rp (source $target)")
                elif [ "$rp" -lt "$target" ]; then
                    lines+=("FAIL  fewer video frames than the source: $rp of $target"); fails=$((fails + 1))
                else
                    lines+=("WARN  more video frames than the source: $rp vs $target"); warns=$((warns + 1))
                fi
            else
                lines+=("WARN  frame count could not be compared"); warns=$((warns + 1))
            fi
        fi
        # --- audio timeline ---
        if [ "$kind" = "audio" ] || { [ "$kind" = "final" ] && [ "${RV_has_a:-0}" = "1" ]; }; then
            adur="${RV_a_dur:-${RV_dur:-}}"
            if _dr_bad "${R_A_STATE:-}" && _diag_num "${R_A_REACHED:-}"; then at="$R_A_REACHED"; else at="${DR_EXP:-}"; fi
            if _diag_num "$adur" && _diag_num "$at"; then
                if _diag_cmp "$adur" ">=" "$(awk -v a="$at" -v t="$tol" 'BEGIN { printf "%.3f", a - t }')"; then
                    lines+=("PASS  audio duration $(_diag_hms "$adur") (expected $(_diag_hms "$at"))")
                else
                    lines+=("WARN  audio is shorter than expected: $(_diag_hms "$adur") of $(_diag_hms "$at")"); warns=$((warns + 1))
                fi
            fi
            if _dr_bad "${R_A_STATE:-}" && _diag_num "${DR_EXP:-}"; then
                lines+=("WARN  the source audio is only decodable until $(_diag_hms "$R_A_REACHED") of $(_diag_hms "$DR_EXP"): there is no audio after that point"); warns=$((warns + 1))
            fi
        fi
        # --- final must not be shorter than its video ---
        if [ "$kind" = "final" ] && [ -n "$R_REC_VIDEO" ]; then
            _diag_facts "$R_REC_VIDEO" RW
            if _diag_num "${RV_dur:-}" && _diag_num "${RW_dur:-}" && \
               _diag_cmp "$RV_dur" "<" "$(awk -v a="$RW_dur" -v t="$tol" 'BEGIN { printf "%.3f", a - t }')"; then
                lines+=("FAIL  final file ($(_diag_hms "$RV_dur")) is shorter than the recovered video ($(_diag_hms "$RW_dur"))"); fails=$((fails + 1))
            fi
        fi
    fi
    printf '%s\n' "${lines[@]}" > "$rep" 2>/dev/null || true
    local l
    for l in "${lines[@]}"; do
        case "$l" in
            PASS*) ui_ok "${l#PASS  }" ;;
            WARN*) ui_warn "${l#WARN  }" ;;
            *)     ui_err "${l#FAIL  }" ;;
        esac
    done
    ui_note "Verification report: $rep"
    if [ "$fails" -gt 0 ]; then
        ui_err "NOT VERIFIED: this recovery is incomplete or damaged ($fails problem(s))"
        return 1
    fi
    if [ "$warns" -gt 0 ]; then ui_warn "Recovered with $warns warning(s) - see above"; else ui_ok "VERIFIED"; fi
    return 0
}

# ---------------------------------------------------------------------------
# Recovery menu: only options the findings support
# ---------------------------------------------------------------------------
diag_recovery_menu() {
    local keys=() labels=() choice i vok aok recommend
    while true; do
        keys=(); labels=()
        vok=0; aok=0
        case "${R_V_STATE:-}" in OK|WARN|SHORT|TRUNCATED) vok=1 ;; esac
        if [ "${DS_has_a:-0}" = "1" ]; then
            case "${R_A_STATE:-}" in OK|WARN|SHORT|TRUNCATED) aok=1 ;; esac
        fi
        if [ "$R_CONCLUSION" = "ENCODER_SIDE" ] || [ "$R_CONCLUSION" = "MINOR_SOURCE_ERRORS" ]; then
            recommend="The source is healthy. Fix the encoder-side cause (see the failure report) and run the conversion again."
        elif [ "$vok" -eq 1 ] && [ "$aok" -eq 1 ]; then recommend="Recover video and audio independently, then combine them."
        elif [ "$vok" -eq 1 ]; then recommend="Recover the video only; the audio cannot be recovered."
        elif [ "$aok" -eq 1 ]; then recommend="Only the audio can be recovered; the video is not recoverable."
        else recommend="Nothing can be safely recovered from this file with these tools."; fi

        echo ""
        ui_section "RECOVERY OPTIONS"
        ui_hint "Recommended: $recommend"
        echo ""
        if [ "$vok" -eq 1 ]; then keys+=(video); labels+=("Recover video independently$([ -n "$R_REC_VIDEO" ] && echo ' (done)')"); fi
        if [ "$aok" -eq 1 ]; then keys+=(audio); labels+=("Recover audio independently$([ -n "$R_REC_AUDIO" ] && echo ' (done)')"); fi
        if [ -n "$R_REC_VIDEO" ] && [ -n "$R_REC_AUDIO" ]; then keys+=(mux); labels+=("Mux recovered video + audio (no -shortest)"); fi
        if [ -n "$R_REC_VIDEO" ] && [ -z "$R_REC_AUDIO" ]; then keys+=(vonly); labels+=("Video-only output (no audio)"); fi
        if [ -n "$R_REC_FINAL" ]; then keys+=(install); labels+=("Copy the recovered file to the output folder"); fi
        keys+=(stop); labels+=("Stop and preserve everything")
        for i in "${!keys[@]}"; do ui_opt $((i + 1)) "${labels[$i]}"; done
        echo ""
        read -r -p "$(ui_prompt "SELECT [1-${#keys[@]}]")" choice || choice="${#keys[@]}"
        if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#keys[@]}" ]; then
            ui_err "Invalid choice"; continue
        fi
        case "${keys[$((choice - 1))]}" in
            video)   recover_video_stream ;;
            audio)   recover_audio_stream ;;
            mux)     mux_recovered_streams ;;
            vonly)   video_only_output ;;
            install) install_recovered_output ;;
            stop)    ui_ok "Everything is preserved in: $DC_DIR"; return 0 ;;
        esac
    done
}
