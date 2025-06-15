#!/data/data/com.termux/files/usr/bin/bash

# merge2.sh — safe, smart merge with auto-remux fallback

# 1. Get source folder
if [ -z "$1" ]; then
    read -p "Enter source folder path (e.g., /sdcard/Download/MyVideos): " SRC
else
    SRC="$1"
fi

# Absolute path and folder name
SRC=$(realpath "$SRC")
FOLDER_NAME=$(basename "$SRC")

# Output folder
OUTDIR="/sdcard/Movies/ffmpeg/Merged"
mkdir -p "$OUTDIR"

# Change to input dir
cd "$SRC" || { echo "❌ Folder not found"; exit 1; }

# Clean up
rm -f filelist.txt mylist.txt

# Find supported video files
find . -maxdepth 1 -type f | grep -Ei '\.(mp4|mkv|webm|mov)$' | sort -V > filelist.txt
if [ ! -s filelist.txt ]; then
    echo "❌ No supported video files found in $SRC"
    exit 1
fi

# Get extension of first file
FIRST_FILE=$(head -n 1 filelist.txt)
EXT="${FIRST_FILE##*.}"
EXT_LOWER=$(echo "$EXT" | tr '[:upper:]' '[:lower:]')
OUTPUT="$OUTDIR/$FOLDER_NAME.$EXT_LOWER"

# Create ffmpeg list file
while IFS= read -r f; do
    echo "file '${f#./}'" >> mylist.txt
done < filelist.txt

# Estimate total duration
start_time=$(date +%s)
TOTAL_DURATION=$(while IFS= read -r f; do
    ffprobe -v error -select_streams v:0 -show_entries format=duration \
        -of default=noprint_wrappers=1:nokey=1 "$f"
done < filelist.txt | awk '{ sum += $1 } END { printf "%.3f", sum }')

TD_H=$(printf "%.0f" "$(awk -v t="$TOTAL_DURATION" 'BEGIN { printf int(t/3600) }')")
TD_M=$(printf "%.0f" "$(awk -v t="$TOTAL_DURATION" 'BEGIN { printf int((t%3600)/60) }')")
TD_S_MS=$(printf "%06.3f" "$(awk -v t="$TOTAL_DURATION" 'BEGIN { printf (t%60) }')")

echo "📂 Merging videos in: $SRC"
echo "📼 Output: $OUTPUT"
echo "⏱️ Estimated total duration: $(printf '%02d:%02d:%s' "$TD_H" "$TD_M" "$TD_S_MS")"
echo "🔄 Merging with ffmpeg..."

# Perform the merge with progress and timestamp generation flags
ffmpeg -y -hide_banner -f concat -safe 0 -i mylist.txt \
  -c copy -fflags +genpts -async 1 \
  -err_detect ignore_err \
  -progress - -nostats "$OUTPUT" 2>/dev/null |
awk -v dur="$TOTAL_DURATION" '
  BEGIN {
    start = systime()
    stuck_count = 0
    pct = 0
    max_stuck = 10
  }
  /^out_time=/ {
    split($0, a, "=")
    split(a[2], t, ":")
    hh = t[1] + 0; mm = t[2] + 0; ss_ms = t[3] + 0
    elapsed = hh*3600 + mm*60 + ss_ms
    pct = (elapsed / dur) * 100; if (pct > 100) pct = 100
    stuck_count = 0
    last_update = systime()
  }
  {
    now = systime()
    if ((now - last_update) > 1) { stuck_count++; last_update = now }
    if (pct >= 99.5 || stuck_count >= max_stuck) { pct = 100 }
    eta = (pct > 0 && pct < 100) ? ((now - start) * (100 - pct)) / pct : 0
    eta_h = int(eta / 3600); eta_m = int((eta % 3600) / 60); eta_s = int(eta % 60)
    printf "\r   ⏳ Progress: %3d%% | ⌛ ETA: %02d:%02d:%02d", int(pct), eta_h, eta_m, eta_s
    fflush()
  }
  END {
    if (pct < 100) printf "\r   ⏳ Progress: 100%% | ⌛ ETA: 00:00:00"
    print "\r   ✅ Done merging.                  "
  }
'

# Show merge duration
end_time=$(date +%s)
merge_time=$((end_time - start_time))
echo "⏱️ Merge time: $(printf '%02d:%02d:%02d' $((merge_time / 3600)) $((merge_time % 3600 / 60)) $((merge_time % 60)))"
echo "📁 Merged file saved to: $OUTPUT"

# Check if merged file is valid
echo "🔍 Checking if merged file is playable..."
if [ ! -f "$OUTPUT" ] || \
   ! ffprobe -v error -show_entries format=duration \
     -of default=noprint_wrappers=1:nokey=1 "$OUTPUT" > /dev/null 2>&1 ; then
    echo "❌ Merged file may be corrupt or unplayable."

    # Attempt remux fix with additional flags
    echo "🔄 Trying remux fallback..."
    FIXED_OUTPUT="$OUTDIR/${FOLDER_NAME}_fixed.$EXT_LOWER"
    ffmpeg -y -hide_banner \
      -fflags +genpts -async 1 \
      -i "$OUTPUT" \
      -c:v copy -c:a copy \
      -movflags +faststart \
      "$FIXED_OUTPUT" 2>/dev/null

    if [ -f "$FIXED_OUTPUT" ] && \
       ffprobe -v error -show_entries format=duration \
         -of default=noprint_wrappers=1:nokey=1 "$FIXED_OUTPUT" > /dev/null 2>&1 ; then
        echo "✅ Remux fix succeeded. Final file: $FIXED_OUTPUT"
        OUTPUT="$FIXED_OUTPUT"  # Update output reference
    else
        echo "⚠️ Remux failed. Trying full re-encode..."
        REENCODE_OUTPUT="$OUTDIR/${FOLDER_NAME}_reencoded.$EXT_LOWER"
        ffmpeg -y -hide_banner -f concat -safe 0 -i mylist.txt \
            -c:v libx264 -preset medium -crf 23 \
            -c:a aac -b:a 128k \
            -movflags +faststart \
            "$REENCODE_OUTPUT" 2>/dev/null
        
        if [ -f "$REENCODE_OUTPUT" ] && \
           ffprobe -v error -show_entries format=duration \
             -of default=noprint_wrappers=1:nokey=1 "$REENCODE_OUTPUT" > /dev/null 2>&1 ; then
            echo "✅ Re-encode succeeded. Final file: $REENCODE_OUTPUT"
            OUTPUT="$REENCODE_OUTPUT"
        else
            echo "❌ All recovery attempts failed. Please check source files."
            exit 1
        fi
    fi
else
    echo "✅ Merged file passed basic integrity check."
fi

echo "🎉 Final output: $OUTPUT"
exit 0