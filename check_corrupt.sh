#!/data/data/com.termux/files/usr/bin/bash

# ------------------------
# probe.sh
#
# Auto-checks and fast-remuxes corrupted videos in a folder.
# No re-encode. No prompt. Logs everything.
# ------------------------

if [ -z "$1" ]; then
    read -r -p "Enter source folder path (e.g., /sdcard/Download/MyVideos): " INPUT_DIR < /dev/tty
else
    INPUT_DIR="$1"
fi

INPUT_DIR=$(realpath "$INPUT_DIR")

REPORT_DIR="/sdcard/Movies/ffmpeg/CorruptionReports"
FIXED_DIR="$REPORT_DIR/Fixed"
mkdir -p "$REPORT_DIR" "$FIXED_DIR"

BASENAME_DIR=$(basename "$INPUT_DIR")
REPORT_FILE="$REPORT_DIR/${BASENAME_DIR}_corruption_report.txt"

TOTAL_FILES=0
CORRUPTED_COUNT=0
FIXED_COUNT=0

echo "Corruption Report for folder: $INPUT_DIR" > "$REPORT_FILE"
echo "Generated on: $(date '+%Y-%m-%d %H:%M:%S')" >> "$REPORT_FILE"
echo "----------------------------------------" >> "$REPORT_FILE"
echo "" >> "$REPORT_FILE"

shopt -s nullglob
for filepath in "$INPUT_DIR"/*.{mp4,mkv,webm,mov}; do
    [ -e "$filepath" ] || continue

    (( TOTAL_FILES++ ))
    filename=$(basename "$filepath")
    extension="${filename##*.}"
    name_no_ext="${filename%.*}"

    echo ""
    echo "🔍 Checking file: $filename"
    echo "File: $filename" >> "$REPORT_FILE"

    DURATION=$(ffprobe -v error -select_streams v:0 -show_entries format=duration \
      -of default=noprint_wrappers=1:nokey=1 "$filepath" 2>/dev/null)
    if [[ -z "$DURATION" || $(awk "BEGIN {print ($DURATION <= 0)}") -eq 1 ]]; then
        DURATION=0
    fi

    TMP_ERR="$REPORT_DIR/tmp_err.log"
    rm -f "$TMP_ERR"

    if awk "BEGIN {exit !($DURATION > 0)}"; then
        ffmpeg -v error -progress - -nostats -i "$filepath" -f null - 2> "$TMP_ERR" | \
        awk -v dur="$DURATION" '
          BEGIN {
            start = systime()
            printf "\r   ▶ Progress:   0%% | ⏳ ETA: 00:00:00"
            fflush()
          }
          /^out_time=/ {
            split($0, a, "=")
            split(a[2], t, ":")
            hh = t[1]+0; mm = t[2]+0; ss_ms = t[3]+0
            elapsed = hh*3600 + mm*60 + ss_ms
            pct = (elapsed / dur) * 100
            if (pct > 100) pct = 100
            elapsed_wall = systime() - start
            if (pct > 0) {
              eta_sec = (elapsed_wall * (100 - pct)) / pct
            } else {
              eta_sec = 0
            }
            eta_h = int(eta_sec/3600)
            eta_m = int((eta_sec%3600)/60)
            eta_s = int(eta_sec%60)
            printf "\r   ▶ Progress: %3d%% | ⏳ ETA: %02d:%02d:%02d", int(pct), eta_h, eta_m, eta_s
            fflush()
          }
          END {
            print "\r   🔎 Check complete.               "
          }
        '
        echo ""
    else
        ffmpeg -v error -i "$filepath" -f null - 2> "$TMP_ERR"
        echo "   🔎 Check complete (no duration)."
    fi

    if [ -s "$TMP_ERR" ]; then
        (( CORRUPTED_COUNT++ ))
        echo "❌ STATUS: CORRUPTED"
        echo "Status: CORRUPTED" >> "$REPORT_FILE"
        echo "Error details:" >> "$REPORT_FILE"
        sed 's/^/    /' "$TMP_ERR" >> "$REPORT_FILE"
        echo "" >> "$REPORT_FILE"

        FIXED_FAST="$FIXED_DIR/${name_no_ext}_fixed.${extension}"
        rm -f "$REPORT_DIR/tmp_fix_err.log"
        echo "🔧 Auto-remuxing: $filename → $(basename "$FIXED_FAST")"
        echo "Attempting fast remux: $filename" >> "$REPORT_FILE"

        if awk "BEGIN {exit !($DURATION > 0)}"; then
            ffmpeg -y -err_detect ignore_err \  # ADDED -y FLAG HERE
              -fflags +genpts \
              -avoid_negative_ts make_non_negative \
              -progress - -nostats -i "$filepath" -c copy "$FIXED_FAST" 2> "$REPORT_DIR/tmp_fix_err.log" | \
            awk -v dur="$DURATION" '
              BEGIN {
                start = systime()
                printf "\r   🔧 Fast-Remux Progress:   0%% | ⏳ ETA: 00:00:00"
                fflush()
              }
              /^out_time=/ {
                split($0, a, "=")
                split(a[2], t, ":")
                hh = t[1]+0; mm = t[2]+0; ss_ms = t[3]+0
                elapsed = hh*3600 + mm*60 + ss_ms
                pct = (elapsed / dur) * 100
                if (pct > 100) pct = 100
                elapsed_wall = systime() - start
                if (pct > 0) {
                  eta_sec = (elapsed_wall * (100 - pct)) / pct
                } else {
                  eta_sec = 0
                }
                eta_h = int(eta_sec/3600)
                eta_m = int((eta_sec%3600)/60)
                eta_s = int(eta_sec%60)
                printf "\r   🔧 Fast-Remux Progress: %3d%% | ⏳ ETA: %02d:%02d:%02d", int(pct), eta_h, eta_m, eta_s
                fflush()
              }
              END {
                print "\r   ✅ Fast-Remux complete.           "
              }
            '
            echo ""
        else
            ffmpeg -y -err_detect ignore_err \  # ADDED -y FLAG HERE
              -fflags +genpts \
              -avoid_negative_ts make_non_negative \
              -i "$filepath" -c copy "$FIXED_FAST" 2> "$REPORT_DIR/tmp_fix_err.log"
            echo "   ✅ Fast-Remux complete (no duration)."
        fi

        if [ -s "$REPORT_DIR/tmp_fix_err.log" ]; then
            echo "⚠️  Fast remux failed. File may still be corrupt."
            echo "Fast-Remux ERRORS:" >> "$REPORT_FILE"
            sed 's/^/    /' "$REPORT_DIR/tmp_fix_err.log" >> "$REPORT_FILE"
            echo "Fix: FAILED → Fast remux produced errors." >> "$REPORT_FILE"
            echo "" >> "$REPORT_FILE"
        else
            echo "✅ Fast-Remux succeeded: $(basename "$FIXED_FAST")"
            echo "Fix: FAST-REMUX → $(basename "$FIXED_FAST")" >> "$REPORT_FILE"
            (( FIXED_COUNT++ ))
        fi

        rm -f "$REPORT_DIR/tmp_fix_err.log"
    else
        echo "✅ STATUS: OK"
        echo "Status: OK" >> "$REPORT_FILE"
        echo "" >> "$REPORT_FILE"
    fi

    rm -f "$TMP_ERR"
done

echo ""
echo "========================================"
echo "📊 Summary:"
echo "Total files checked       : $TOTAL_FILES"
echo "Corrupted files found     : $CORRUPTED_COUNT"
echo "Files successfully fixed  : $FIXED_COUNT"
echo "Report saved to           : $REPORT_FILE"
echo "Fixed files (if any) in   : $FIXED_DIR"
echo "========================================"

echo "" >> "$REPORT_FILE"
echo "========================================" >> "$REPORT_FILE"
echo "Summary:" >> "$REPORT_FILE"
echo "Total files checked       : $TOTAL_FILES" >> "$REPORT_FILE"
echo "Corrupted files found     : $CORRUPTED_COUNT" >> "$REPORT_FILE"
echo "Files successfully fixed  : $FIXED_COUNT" >> "$REPORT_FILE"
echo "Fixed files directory     : $FIXED_DIR" >> "$REPORT_FILE"
echo "========================================" >> "$REPORT_FILE"

exit 0
