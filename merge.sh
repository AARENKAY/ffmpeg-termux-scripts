#!/data/data/com.termux/files/usr/bin/bash

# ------------------------------------------------------------
# SETTINGS
# ------------------------------------------------------------
# Where merged files are saved (override with: MERGE_OUTDIR=/path ./merge.sh ...)
OUTDIR="${MERGE_OUTDIR:-/sdcard/Movies/ffmpeg/Merged}"

# Video files that count as input. Hidden files (".trashed-...", ".pending-...") are ignored.
VIDEO_FIND_ARGS=( \( -iname "*.mp4" -o -iname "*.mkv" -o -iname "*.webm" -o -iname "*.mov" \) ! -name '.*' )

# ------------------------------------------------------------
# TEMP FILES + CLEAN STOP
# All scratch files live in one private temp folder, never in the source folders.
# ------------------------------------------------------------
WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/merge.XXXXXX" 2>/dev/null || mktemp -d "$HOME/.merge_tmp.XXXXXX")"
CURRENT_PARTIALS=()          # half-written output files, removed on abort
declare -A USED_OUTPUTS=()   # output names already taken during this run

cleanup_temp() {
    local p
    for p in "${CURRENT_PARTIALS[@]}"; do rm -f -- "$p" 2>/dev/null; done
    [ -n "$WORKDIR" ] && rm -rf -- "$WORKDIR" 2>/dev/null
}

handle_interrupt() {
    trap '' INT TERM HUP
    echo -e "\n🛑 CTRL+C DETECTED. ABORTING ALL MERGE PROCESSES..."
    # Only stop this script's own helpers (not other ffmpeg jobs running on the phone)
    pkill -P $$ 2>/dev/null
    sleep 0.3
    cleanup_temp
    echo "‼️PROCESS TERMINATED BY USER"
    exit 130
}

trap handle_interrupt INT TERM HUP
trap cleanup_temp EXIT

float_to_timestamp() {
    local seconds="$1"
    local style="${2:-full}"

    awk -v t="$seconds" -v style="$style" 'BEGIN {
        if (t ~ /[^0-9.-]/ || t == "") {
            print "INVALID_INPUT"
            exit 1
        }
        sign = (t < 0) ? "-" : ""
        t = (t < 0) ? -t : t
        h = int(t / 3600)
        remaining = t - h * 3600
        m = int(remaining / 60)
        s = remaining - m * 60
        epsilon = 0.0001
        if (s - int(s) > 0.9999) s = int(s) + 1
        if (s >= 60 - epsilon) { m += 1; s = 0 }
        if (style == "compact") {
            if (h > 0)
                printf("%s%dh%02dm", sign, h, m)
            else if (m > 0)
                printf("%s%dm%02ds", sign, m, int(s))
            else
                printf("%s%.3fs", sign, s)
        } else {
            printf("%s%02d:%02d:%06.3f", sign, h, m, s)
        }
    }' 2>/dev/null || echo "ERROR: INVALID TIME FORMAT"
}

# Progress bar fed by "ffmpeg -progress pipe:1"; argument = total duration in seconds
ffmpeg_progress_awk() {
    awk -v dur="$1" '
      /^out_time=/ {
        split($0, a, "=")
        split(a[2], t, ":")
        hh = t[1] + 0; mm = t[2] + 0; ss_ms = t[3] + 0
        elapsed = hh*3600 + mm*60 + ss_ms
        if (dur > 0) {
          pct = (elapsed / dur) * 100
          if (pct > 100) pct = 100
          printf "\rPROGRESS: %3d%%", int(pct)
          fflush()
        }
      }
      END { printf "\rPROGRESS: 100%%\n" }
    '
}

probe_duration() {
    ffprobe -v error -show_entries format=duration \
        -of default=noprint_wrappers=1:nokey=1 "$1" 2>/dev/null </dev/null | head -n 1
}

# ------------------------------------------------------------
# FUNCTION: Process a single folder (merge its video files)
# Returns: 0 = merged, 1 = failed, 2 = skipped (nothing to merge)
# ------------------------------------------------------------
process_folder() {
    local SRC="$1"
    SRC=$(realpath "$SRC")
    local FOLDER_NAME
    FOLDER_NAME=$(basename "$SRC")

    echo ""
    echo "=========================================="
    echo "📁 PROCESSING FOLDER: $SRC"
    echo "=========================================="

    if ! mkdir -p "$OUTDIR" 2>/dev/null; then
        echo "❌ CANNOT CREATE OUTPUT FOLDER: $OUTDIR"
        echo "   (run termux-setup-storage if storage access was not granted)"
        return 1
    fi

    # Find all video files (NUL-safe, natural sort, hidden files skipped)
    local files=()
    mapfile -d '' -t files < <(find "$SRC" -maxdepth 1 -type f "${VIDEO_FIND_ARGS[@]}" -print0 2>/dev/null | sort -zV)
    if [ ${#files[@]} -eq 0 ]; then
        echo "❌ NO SUPPORTED VIDEO FILES FOUND IN $SRC – SKIPPING"
        return 1
    fi
    if [ ${#files[@]} -eq 1 ]; then
        echo "⏭️ ONLY ONE VIDEO FILE IN THIS FOLDER – NOTHING TO MERGE, SKIPPING"
        return 2
    fi

    # Determine input extension (first file)
    local FIRST_FILE="${files[0]}"
    local EXT="${FIRST_FILE##*.}"
    local EXT_LOWER
    EXT_LOWER=$(echo "$EXT" | tr '[:upper:]' '[:lower:]')

    # Output name: never reuse a name another folder already got in this run
    # (two different folders called "Season 1" would overwrite each other).
    local base="$FOLDER_NAME" n=1
    while [ -n "${USED_OUTPUTS[${base,,}]+x}" ]; do
        n=$((n + 1)); base="$FOLDER_NAME ($n)"
    done
    USED_OUTPUTS[${base,,}]=1
    local FINAL_MKV="$OUTDIR/$base.mkv"
    local FINAL_ORIG="$OUTDIR/$base.$EXT_LOWER"
    # Work on hidden partial files; the real name only appears after the result is verified.
    local PART_MKV="$OUTDIR/.$base.partial.mkv"
    local PART_ORIG="$OUTDIR/.$base.partial.$EXT_LOWER"
    local OUTPUT="$FINAL_MKV"
    CURRENT_PARTIALS=("$PART_MKV" "$PART_ORIG")
    if [ "$base" != "$FOLDER_NAME" ]; then
        echo "⚠️ ANOTHER FOLDER IS ALSO CALLED \"$FOLDER_NAME\" – SAVING AS \"$base\""
    fi

    local start_time
    start_time=$(date +%s)

    echo ""
    echo "🔍 FILES FOUND IN THE FOLDER:"
    local TOTAL_DURATION=0 TOTAL_INPUT_SIZE=0 DUR_UNKNOWN=0
    local f DURATION DURATION_FMT FILE_SIZE
    local ref_v="" ref_a="" cur_v cur_a
    local MISMATCH=()
    for f in "${files[@]}"; do
        DURATION=$(probe_duration "$f")
        DURATION_FMT=$(float_to_timestamp "$DURATION")
        echo "🔹$(basename "$f") — $DURATION_FMT"
        if [[ "$DURATION" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
            TOTAL_DURATION=$(awk -v total="$TOTAL_DURATION" -v d="$DURATION" 'BEGIN { printf "%.6f", total + d }')
        else
            DUR_UNKNOWN=1
        fi
        FILE_SIZE=$(stat -c%s "$f" 2>/dev/null || stat -f%z "$f" 2>/dev/null)
        [[ "$FILE_SIZE" =~ ^[0-9]+$ ]] || FILE_SIZE=0
        TOTAL_INPUT_SIZE=$((TOTAL_INPUT_SIZE + FILE_SIZE))

        # Stream layout must match the first file, otherwise a lossless merge is not possible
        cur_v=$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name,width,height,pix_fmt \
            -of csv=p=0 "$f" 2>/dev/null </dev/null | head -n 1)
        cur_a=$(ffprobe -v error -select_streams a:0 -show_entries stream=codec_name,sample_rate,channels \
            -of csv=p=0 "$f" 2>/dev/null </dev/null | head -n 1)
        if [ -z "$ref_v$ref_a" ]; then
            ref_v="$cur_v"; ref_a="$cur_a"
        elif [ "$cur_v" != "$ref_v" ] || [ "$cur_a" != "$ref_a" ]; then
            MISMATCH+=("$(basename "$f")")
        fi
    done

    echo ""
    echo "🕛 TOTAL DURATION: $(float_to_timestamp "$TOTAL_DURATION")"
    if [ "$DUR_UNKNOWN" -eq 1 ]; then
        echo "⚠️ SOME FILES HAVE NO READABLE DURATION – DURATION CHECK WILL BE SKIPPED"
    fi
    if [ ${#MISMATCH[@]} -gt 0 ]; then
        echo ""
        echo "⚠️ THESE FILES HAVE A DIFFERENT CODEC / SIZE / AUDIO FORMAT THAN THE FIRST FILE:"
        for f in "${MISMATCH[@]}"; do echo "   • $f"; done
        echo "   (they cannot be joined losslessly – the merge is likely to fail)"
    fi
    echo ""

    # Free space: the merge needs about the size of the inputs (twice when the result is
    # first written as MKV and then converted back to another container).
    local NEED="$TOTAL_INPUT_SIZE" AVAIL_KB
    if command -v mkvmerge >/dev/null 2>&1 && [ "$EXT_LOWER" != "mkv" ]; then NEED=$((NEED * 2)); fi
    AVAIL_KB=$(df -Pk "$OUTDIR" 2>/dev/null | awk 'NR==2 { print $4 }')
    if [[ "$AVAIL_KB" =~ ^[0-9]+$ ]] && [ $((AVAIL_KB * 1024)) -lt $((NEED + NEED / 20)) ]; then
        echo "❌ NOT ENOUGH FREE SPACE IN $OUTDIR"
        echo "   NEEDED ≈ $((NEED / 1048576)) MB, FREE = $((AVAIL_KB / 1024)) MB"
        return 1
    fi

    # Track method used
    local MERGE_METHOD=""
    local merge_exit_code=1
    local PRODUCT=""     # the verified file produced by the merge step

    # Try mkvmerge first if available
    if command -v mkvmerge >/dev/null 2>&1; then
        echo "⛓️ MERGING FILES USING MKVMERGE..."
        echo ""
        local mkvmerge_cmd=(-o "$PART_MKV")
        local i
        for ((i=0; i<${#files[@]}; i++)); do
            if [ $i -eq 0 ]; then
                mkvmerge_cmd+=("${files[$i]}")
            else
                mkvmerge_cmd+=("+${files[$i]}")
            fi
        done
        mkvmerge "${mkvmerge_cmd[@]}" >"$WORKDIR/mkvmerge.log" 2>&1 &
        local MERGE_PID=$!
        echo -n "PROGRESS: 0%"
        local OUTPUT_SIZE PERCENTAGE
        sleep 1
        while kill -0 $MERGE_PID 2>/dev/null; do
            if [ -f "$PART_MKV" ]; then
                OUTPUT_SIZE=$(stat -c%s "$PART_MKV" 2>/dev/null || stat -f%z "$PART_MKV" 2>/dev/null)
                if [[ "$OUTPUT_SIZE" =~ ^[0-9]+$ ]] && [ "$TOTAL_INPUT_SIZE" -gt 0 ]; then
                    PERCENTAGE=$((OUTPUT_SIZE * 100 / TOTAL_INPUT_SIZE))
                    if [ $PERCENTAGE -gt 99 ]; then PERCENTAGE=99; fi
                    echo -ne "\rPROGRESS: ${PERCENTAGE}%"
                fi
            fi
            sleep 1
        done
        wait $MERGE_PID
        merge_exit_code=$?
        echo -e "\rPROGRESS: 100%"

        # mkvmerge: 0 = ok, 1 = finished with warnings (output is fine), 2 = error
        if [ $merge_exit_code -le 1 ] && [ -s "$PART_MKV" ]; then
            merge_exit_code=0
            MERGE_METHOD="mkvmerge"
            PRODUCT="$PART_MKV"
        else
            [ $merge_exit_code -eq 0 ] && merge_exit_code=1
            echo -e "\033[1A\033[2K\r‼️MKVMERGE FAILED — FALLING BACK TO FFMPEG CONCAT..."
            echo "   $(grep -m1 -i 'error' "$WORKDIR/mkvmerge.log" 2>/dev/null | cut -c1-120)"
            echo ""
            rm -f -- "$PART_MKV"
        fi
    else
        echo "❗MKVMERGE NOT AVAILABLE — USING FFMPEG CONCAT..."
        echo ""
    fi

    # If mkvmerge failed or not available, use ffmpeg concat
    if [ $merge_exit_code -ne 0 ]; then
        if [ ${#MISMATCH[@]} -gt 0 ]; then
            echo "❌ CANNOT CONCAT: FILES DO NOT SHARE THE SAME CODEC / SIZE / AUDIO FORMAT"
            echo "   RE-ENCODE THEM TO THE SAME SETTINGS FIRST, THEN MERGE"
            return 1
        fi
        OUTPUT="$FINAL_ORIG"
        echo "⛓️ MERGING VIDEOS USING FFMPEG CONCAT DEMUXER..."
        echo ""
        local LIST="$WORKDIR/concat.txt"
        : > "$LIST"
        for f in "${files[@]}"; do
            # ffmpeg concat syntax: a literal ' inside 'quotes' is written as '\''
            printf "file '%s'\n" "${f//\'/\'\\\'\'}" >> "$LIST"
        done
        # all video + audio tracks (not just the first audio); subtitles only where MKV can hold them
        local MAPS=(-map 0:v -map "0:a?")
        if [ "$EXT_LOWER" = "mkv" ]; then MAPS+=(-map "0:s?"); fi
        ffmpeg -nostdin -y -hide_banner -loglevel error -f concat -safe 0 -fflags +genpts -i "$LIST" \
          "${MAPS[@]}" -c copy \
          -progress pipe:1 -nostats "$PART_ORIG" 2>"$WORKDIR/ffmpeg.log" |
        ffmpeg_progress_awk "$TOTAL_DURATION"
        merge_exit_code=${PIPESTATUS[0]}
        if [ $merge_exit_code -eq 0 ] && [ -s "$PART_ORIG" ]; then
            MERGE_METHOD="ffmpeg"
            PRODUCT="$PART_ORIG"
        else
            echo "   $(grep -m1 . "$WORKDIR/ffmpeg.log" 2>/dev/null | cut -c1-120)"
            rm -f -- "$PART_ORIG"
        fi
    fi

    if [ $merge_exit_code -eq 0 ] && [ -n "$PRODUCT" ] && [ -f "$PRODUCT" ]; then
        echo ""
        echo -e "\033[2A\033[2K\r✅ MERGE COMPLETED SUCCESSFULLY"

        local OUT_DUR DIFF
        OUT_DUR=$(probe_duration "$PRODUCT")
        if [ "$DUR_UNKNOWN" -eq 1 ] || ! [[ "$OUT_DUR" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
            echo ""
            echo "⚠️ DURATION NOT VERIFIED (DURATION UNKNOWN)"
        else
            DIFF=$(awk -v d1="$OUT_DUR" -v d2="$TOTAL_DURATION" 'BEGIN { diff = d1 - d2; if (diff < 0) diff = -diff; print diff }')
            if awk -v d="$DIFF" 'BEGIN { exit !(d <= 2.0) }'; then
                echo ""
                echo "✅ DURATION VERIFIED"
                echo "   OUTPUT = $(float_to_timestamp "$OUT_DUR") vs EXPECTED = $(float_to_timestamp "$TOTAL_DURATION")"
            else
                echo ""
                echo "❌ DURATION MISMATCH"
                echo "   OUTPUT = $(float_to_timestamp "$OUT_DUR") VS EXPECTED = $(float_to_timestamp "$TOTAL_DURATION")"
                echo "‼️ THERE MAY BE SOME ISSUES WITH THE INPUT FILES"
                rm -f -- "$PRODUCT"
                return 1
            fi
        fi

        # Convert MKV back to original format if needed
        if [[ "$MERGE_METHOD" == "mkvmerge" && "$EXT_LOWER" != "mkv" ]]; then
            local conv_rc
            echo ""
            echo "🔄 CONVERTING MKV BACK TO ORIGINAL FORMAT ($EXT_LOWER)..."
            echo ""
            ffmpeg -nostdin -y -hide_banner -loglevel error -i "$PART_MKV" -map 0:v -map "0:a?" -c copy \
                -progress pipe:1 -nostats "$PART_ORIG" 2>"$WORKDIR/convert.log" |
            ffmpeg_progress_awk "$TOTAL_DURATION"
            conv_rc=${PIPESTATUS[0]}
            if [ $conv_rc -eq 0 ] && [ -s "$PART_ORIG" ]; then
                echo -e "\033[1A\033[2K\r✅ CONVERTING COMPLETE"
                mv -f -- "$PART_ORIG" "$FINAL_ORIG" && rm -f -- "$PART_MKV"
                OUTPUT="$FINAL_ORIG"
            else
                # Keep the good MKV instead of losing the whole merge
                echo -e "\033[1A\033[2K\r❌ FAILED TO CONVERT MKV TO $EXT_LOWER – KEEPING THE MKV"
                rm -f -- "$PART_ORIG"
                mv -f -- "$PART_MKV" "$FINAL_MKV"
                OUTPUT="$FINAL_MKV"
            fi
        elif [ "$MERGE_METHOD" == "mkvmerge" ]; then
            mv -f -- "$PART_MKV" "$FINAL_MKV"
            OUTPUT="$FINAL_MKV"
        else
            mv -f -- "$PART_ORIG" "$FINAL_ORIG"
            OUTPUT="$FINAL_ORIG"
        fi
    else
        echo ""
        echo "❌ FAILED TO CREATE OUTPUT FILE FOR $SRC"
        echo "   EXIT CODE: $merge_exit_code"
        return 1
    fi
    CURRENT_PARTIALS=()

    local end_time merge_time
    end_time=$(date +%s)
    merge_time=$((end_time - start_time))
    echo ""
    echo "⏱️ TOTAL PROCESSING TIME: $(printf '%02d:%02d:%02d' $((merge_time / 3600)) $((merge_time % 3600 / 60)) $((merge_time % 60)))"
    echo ""
    echo "📁 FILE SAVED TO: $OUTPUT"
    echo ""
    echo "🔹MERGE METHOD USED: $MERGE_METHOD"
    return 0
}

# ------------------------------------------------------------
# MAIN: Collect folders (supports spaces in paths)
# ------------------------------------------------------------
FOLDERS=()

if [ $# -eq 0 ]; then
    echo "📂 ENTER FOLDER PATHS (one per line, empty line to finish)"
    echo "   Example: /storage/emulated/0/Movies/Folder with spaces"
    echo "            /sdcard/Another Folder"
    echo ""
    while IFS= read -r line; do
        [ -z "$line" ] && break
        # Remove surrounding quotes if present (optional)
        line="${line#\"}"
        line="${line%\"}"
        [ -n "$line" ] && FOLDERS+=("$line")
    done
else
    # Command line arguments already preserve spaces when quoted
    FOLDERS=("$@")
fi

if [ ${#FOLDERS[@]} -eq 0 ]; then
    echo "❌ NO FOLDERS PROVIDED. EXITING."
    exit 1
fi

# The output folder is never scanned (otherwise earlier merges would be merged again)
OUT_REAL=$(realpath -m "$OUTDIR" 2>/dev/null || echo "$OUTDIR")

# Expand each input folder — walks the full subtree at any depth,
# not just one level down, so folders nested several levels deep are
# found too. Each qualifying folder is merged under its own base name.
# Hidden folders (".thumbnails", ".trash" ...) are skipped.
EXPANDED_FOLDERS=()
for folder in "${FOLDERS[@]}"; do
    given="$folder"
    folder=$(realpath "$folder" 2>/dev/null)
    if [ -z "$folder" ] || [ ! -d "$folder" ]; then
        echo "⚠️ SKIPPING: '$given' is not a directory"
        continue
    fi
    if [ "$folder" = "$OUT_REAL" ]; then
        echo "⚠️ SKIPPING: '$folder' is the output folder"
        continue
    fi

    has_videos=$(find "$folder" -maxdepth 1 -type f "${VIDEO_FIND_ARGS[@]}" -print -quit)
    if [ -n "$has_videos" ]; then
        EXPANDED_FOLDERS+=("$folder")
    else
        while IFS= read -r -d '' sub; do
            [ "$sub" = "$OUT_REAL" ] && continue
            case "$sub" in "$OUT_REAL"/*) continue ;; esac
            sub_has_videos=$(find "$sub" -maxdepth 1 -type f "${VIDEO_FIND_ARGS[@]}" -print -quit)
            if [ -n "$sub_has_videos" ]; then
                EXPANDED_FOLDERS+=("$sub")
            fi
        done < <(find "$folder" -mindepth 1 -name '.*' -prune -o -type d -print0)
    fi
done

# Remove duplicates
if [ ${#EXPANDED_FOLDERS[@]} -gt 0 ]; then
    mapfile -d '' -t EXPANDED_FOLDERS < <(printf "%s\0" "${EXPANDED_FOLDERS[@]}" | sort -zu)
fi

if [ ${#EXPANDED_FOLDERS[@]} -eq 0 ]; then
    echo "❌ NO VALID FOLDERS TO PROCESS. EXITING."
    exit 1
fi

echo ""
echo "🚀 STARTING BATCH MERGE FOR ${#EXPANDED_FOLDERS[@]} FOLDER(S)..."
echo ""

FAILED=0
SKIPPED=0
for folder in "${EXPANDED_FOLDERS[@]}"; do
    process_folder "$folder"
    rc=$?
    if [ $rc -eq 2 ]; then
        SKIPPED=$((SKIPPED + 1))
    elif [ $rc -ne 0 ]; then
        FAILED=$((FAILED + 1))
    fi
done

echo ""
echo "=========================================="
echo "🏁 BATCH MERGE COMPLETED"
echo "   TOTAL FOLDERS: ${#EXPANDED_FOLDERS[@]}"
echo "   SUCCESSFUL: $(( ${#EXPANDED_FOLDERS[@]} - FAILED - SKIPPED ))"
echo "   FAILED: $FAILED"
if [ "$SKIPPED" -gt 0 ]; then echo "   SKIPPED (single file): $SKIPPED"; fi
echo "=========================================="

[ "$FAILED" -eq 0 ] || exit 1
exit 0
