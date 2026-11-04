# Termux Video Converter

An interactive batch video converter for **Termux on Android** (it also runs on plain Linux). It wraps `ffmpeg` in a phone-friendly menu and is tuned for long, slow encodes on a device that can overheat:

- converts a single file or a whole folder tree
- splits long videos into chunks, resumes after an interruption, and merges the chunks afterwards
- pauses between files and chunks so the CPU can cool down
- checks every output before marking it done
- keeps failed files aside and offers a guided diagnosis and recovery

The defaults give a small, good-looking file: **SVT-AV1 10-bit-friendly video + Opus audio in MKV**.

---

## Contents

1. [Quick start](#quick-start)
2. [Requirements](#requirements)
3. [Usage](#usage)
4. [Main menu](#main-menu)
5. [Advanced menu](#advanced-menu)
6. [How it works](#how-it-works)
7. [Where files go](#where-files-go)
8. [Configuration file](#configuration-file)
9. [Failures, diagnosis and recovery](#failures-diagnosis-and-recovery)
10. [Project layout](#project-layout)
11. [Notes and limitations](#notes-and-limitations)
12. [Troubleshooting](#troubleshooting)

---

## Quick start

```bash
# 1. One-time setup (Termux)
termux-setup-storage
pkg update
pkg install ffmpeg mkvtoolnix gawk coreutils findutils grep sed diffutils

# 2. Put the scripts in one folder and make the launcher executable
cp /sdcard/Download/*.sh "$HOME/" && chmod +x "$HOME"/*.sh

# 3. Run it
cd "$HOME"
./convert.sh
```

Drop videos into `/sdcard/Movies/ffmpeg/Job`, choose **7 Start** and press Enter at the path prompt. Converted files appear in `/sdcard/Movies/ffmpeg/Converted`.

> All `.sh` files must stay **in the same folder**. `convert.sh` loads the `lib-*.sh` modules from its own directory.

---

## Requirements

| Needed | Termux package | Notes |
|---|---|---|
| `ffmpeg`, `ffprobe` | `ffmpeg` | Must include the encoders you plan to use (`libsvtav1`, `libx264`, `libx265`, `libvpx`, `libvpx-vp9`, `libaom-av1`, `libopus`) |
| `mkvmerge` | `mkvtoolnix` | Used to join chunks when the output is MKV. If it is missing or fails, an ffmpeg concat fallback is used |
| `awk` | `gawk` | |
| `stat`, `realpath`, `du`, `date`, `ls`, `head`, `cut`, `tr`, `wc`, `tee`, `sleep`, `sha256sum`, `sort` | `coreutils` | |
| `find`, `xargs` | `findutils` | |
| `grep`, `sed`, `comm` | `grep`, `sed`, `diffutils` | |
| `mediainfo` | `mediainfo` | **Optional.** Only a last-resort fallback for reading bitrates |

At start-up the script checks for the required tools and prints the exact `pkg install` command for anything that is missing.

Shared storage (`/sdcard/...`, `/storage/<card-id>/...`) needs `termux-setup-storage` once. If a folder cannot be created or written, the script says so and repeats this hint.

---

## Usage

### Interactive

```bash
./convert.sh
```

Opens the main menu (below). Settings you change are used immediately. Use **8 Save** to keep them for next time.

### Command line

```bash
./convert.sh /path/to/video.mp4      # one file
./convert.sh /path/to/folder         # every video in the folder and its subfolders
```

Settings come from the saved configuration. The exit code is `0` on success and `1` if any file failed, so the script can be used from other scripts.

### Supported input formats

`mp4 mkv mov avi webm wmv flv mpeg mpg mpe m4v 3gp 3g2 f4v ts m2ts mts vob`

### Verbose module loading

```bash
VERBOSE_LOAD=1 ./convert.sh
```

---

## Main menu

```
 1  Codec          video encoder
 2  Quality (CRF)  lower = better quality, bigger file
 3  Speed preset   slower = smaller file, longer encode
 4  Audio codec
 5  Audio bitrate  kbps
 6  Advanced       more options
 7  Start
 8  Save
 9  Diagnose
 0  Exit
```

### Video codecs

| Option | Encoder | CRF range | Preset |
|---|---|---|---|
| 1 | `libsvtav1` (SVT-AV1), default | 0-63 | number 0-13 (0 slowest, 13 fastest) |
| 2 | `libx264` (H.264) | 0-51 | name, `ultrafast` to `veryslow` |
| 3 | `libx265` (H.265) | 0-51 | name, `ultrafast` to `veryslow` |
| 4 | `libvpx` (VP8) | 0-63 | none (uses `default`) |
| 5 | `libvpx-vp9` (VP9) | 0-63 | none (uses `default`) |
| 6 | `libaom-av1` (AV1) | 0-63 | name, `ultrafast` to `veryslow` |

Choosing VP8 or VP9 switches the output format to MKV automatically.

### Audio codecs

`libopus` (default), `aac`, `flac` (lossless), `mp3`, or `copy` (keep the original audio; the bitrate setting is then ignored).

### Start

Enter a file or folder path, or press **Enter** to use the default folders. A folder is scanned and a **Batch menu** appears:

1. View the file list (paged)
2. Start processing
3. Cancel the batch

Files that were already completed in an earlier run are marked and skipped.

### Diagnose

Opens the diagnosis tool for files that failed earlier (see [Failures](#failures-diagnosis-and-recovery)).

---

## Advanced menu

| # | Setting | Choices / meaning |
|---|---|---|
| 1 | **Output format** | `mkv` (default), `mp4`, `webm`, `mov`, `avi`. Incompatible codec/container pairs are warned about (AV1 or VP in MP4/MOV, H.264/H.265 in WebM, anything but H.264 in AVI) |
| 2 | **Pixel format** | `copy` keeps the source format; `8-bit` forces `yuv420p`; `10-bit` forces `yuv420p10le` |
| 3 | **Frame rate** | `auto` (default): only variable-frame-rate sources are converted to a constant rate; constant-rate sources are never touched. `source`: never change the frame rate or timing. See [Frame rate](#frame-rate-handling) |
| 4 | **Bitrate limits** | Optional `-maxrate` / `-bufsize` cap (for example `800k` / `1200k`). Values are checked against sensible limits for the chosen codec |
| 5 | **Chunk threshold** | Files longer than this are split into chunks. Default 30 min (`1800` s). Accepts values like `30m`, `1h` |
| 6 | **Chunk duration** | `default` (30–35 minute chunks) or `manual` with your own length |
| 7 | **Cooldown** | `manual`: fixed pause (default 10 min). `auto`: wait until the CPU cools down |
| 8 | **Scaling** | `OFF` (default), `720P`, `1080P`, or `Custom` (for example `1920x1080`) |
| 9 | **Sharpening** | Light edge sharpening on or off |
| 10 | **Progress style** | `advanced` (live bar, CPU temperature, ETA, finish time) or `simple`; plus seven bar styles |
| 11 | **File sorting** | Name A–Z / Z–A, smallest / largest first, newest / oldest first |
| 12 | **CPU threads** | Default 2. Fewer = cooler and slower. Values above 4 trigger an overheating warning |

### Default settings

| Setting | Default |
|---|---|
| Video codec / CRF / preset | `libsvtav1` / `20` / `6` |
| Audio codec / bitrate | `libopus` / `80` kbps (48 kHz) |
| Output format | `mkv` |
| Pixel format | `copy` |
| Frame rate | `auto` |
| Bitrate limits | off (`800k` max, `1200k` buffer if enabled) |
| Chunk threshold / mode | 1800 s / `default` |
| Cooldown | 600 s fixed |
| Scaling / sharpening | off / off |
| Progress style | `advanced`, `horizontal_blocks` bar |
| Sort order | name A–Z |
| CPU threads | 2 |

### Frame rate handling

Phone recordings are often **variable frame rate (VFR)**. Some software decoders and MKV's 1 ms timestamp resolution make such files look slightly uneven, as if frames were being skipped.

In `auto` mode the script compares the source's `r_frame_rate` and `avg_frame_rate` with `ffprobe`:

- they match within 1 % (constant frame rate): no flags are added, the rate is untouched
- they differ (VFR): the output is forced to a constant rate (`-fps_mode cfr -r N`), where `N` is the average rate snapped to the nearest standard one (23.976 … 120)
- an unusual average rate that matches no standard one is left alone

The decision is written to the log as `FRAME RATE:`. Choose `source` to disable this completely.

---

## How it works

1. **Probe.** `ffprobe` reads codec, resolution, pixel format, duration, frame rate and video/audio bitrates. Bitrates fall back to the `BPS` tag, then `mediainfo` (if installed), then a calculation from packet sizes, because MKV/WebM files often carry no bitrate field.
2. **Plan.** Scaling, sharpening, pixel format, frame rate and bitrate limits are combined into one filter/argument set. Audio-only or unusual inputs are handled.
3. **Encode.** Short files are encoded in one pass. Files longer than the chunk threshold go through the chunk path below.
4. **Verify.** The output is probed and its duration compared with the source (with a tolerance). Only verified files are marked as completed.
5. **Cool down.** A pause follows each file, and each chunk of a chunked file.

Video and audio streams are mapped (`-map 0:v -map 0:a?`). Subtitles, chapters and attachments are not carried over.

### Long videos: chunking and resume

A file longer than the threshold is split into chunks of roughly 30–35 minutes (or your manual length). Each chunk is encoded on its own, so a crash or heat shutdown costs at most one chunk.

- Chunks live in `chunks_<name>_<id>` **next to the source file**.
- If the run is interrupted, starting it again **resumes**: valid chunks are kept, missing ones are encoded.
- Chunks are merged strictly in order with `mkvmerge` (MKV output) or ffmpeg concat, then the merged file is verified.
- The chunk folder is removed after a successful merge.

Resume does not check that the settings are the same as in the earlier run. If you change codec, CRF or scaling in between, delete the `chunks_*` folder first.

### Cooldown

- **Manual:** a fixed countdown (default 10 minutes).
- **Auto:** waits until the CPU is below 38 °C, for at most 5 minutes. If no temperature sensor can be read, the fixed countdown is used instead.

The cooldown is not counted as encoding time in the ETA. The progress screen shows the live CPU temperature, a per-file ETA and the batch ETA/finish time, which are recalculated from measured speed.

### Completion markers

Finished files are remembered in the *completed* folder (one marker per source path). A rerun skips them. After a **fully successful** batch all markers are cleared. If any file failed, the markers are kept so a rerun only processes what is left.

### Safety checks

- A source is never used as its own output; the batch refuses if the output folder equals the input folder.
- If two sources would produce the same output name (for example `x.mp4` and `x.mkv`, or names differing only by case), the later one is refused and listed as failed instead of overwriting the first.
- ffmpeg never reads the keyboard during an encode (`-nostdin`).
- The configuration file is parsed, not executed, and every value is validated.

---

## Where files go

| What | Default location |
|---|---|
| Input (default scan folders) | `/sdcard/Movies/ffmpeg/Job` and `/storage/F437-7513/Movies/ffmpeg/Job` |
| Converted output | `/sdcard/Movies/ffmpeg/Converted` |
| Per-file logs | `/sdcard/Movies/ffmpeg/Logs/<name>.log` |
| Completion markers | `/sdcard/Movies/ffmpeg/.video_status/completed` |
| Chunk working folders | `chunks_<name>_<id>` beside the source |
| Failure isolation | `.ffmpeg_diagnostics/<timestamp>` inside the input folder |
| Saved settings | `video_converter.conf` next to `convert.sh` |

Subfolders of the input are scanned, and the same folder structure is created under the output and log folders. Output files are named `<source name>.<format>`.

Change these paths by editing the variables at the top of `convert.sh` (the second default input folder is an SD-card path and will need your own card ID) or by editing the saved configuration.

---

## Configuration file

**8 Save** writes `video_converter.conf` as plain `KEY="value"` lines. It is read from the script's folder first, then from the current directory. Unknown keys and invalid values are ignored, so a damaged file cannot run commands or crash the script.

| Key | Allowed values |
|---|---|
| `INPUT_DIR`, `OUTPUT_DIR`, `LOG_DIR`, `COMPLETED_DIR` | any path |
| `VIDEO_CODEC`, `AUDIO_CODEC`, `PRESET` | names such as `libsvtav1`, `libopus`, `6` |
| `CRF`, `AUDIO_BITRATE`, `CPU_THREADS` | whole numbers |
| `PIXFMT_MODE` | `copy`, `8-bit`, `10-bit` |
| `FPS_HANDLING` | `auto`, `source` |
| `OUTPUT_FORMAT` | `mkv`, `mp4`, `webm`, `mov`, `avi` |
| `BITRATE_LIMITS_ENABLED`, `AUTO_COOLDOWN`, `SHARPEN_EDGES` | `0` or `1` |
| `MAXRATE`, `BUFSIZE` | for example `800k`, `2M` |
| `CHUNK_THRESHOLD`, `MANUAL_CHUNK_DURATION`, `COOLDOWN_TIME` | seconds |
| `CHUNK_MODE` | `default`, `manual` |
| `SCALING_MODE` | `OFF`, `720P`, `1080P`, `Custom` |
| `CUSTOM_RESOLUTION` | `WIDTHxHEIGHT` |
| `PROGRESS_STYLE` | `simple`, `advanced` |
| `BAR_STYLE` | `horizontal_blocks`, `ascii`, `shading_blocks`, `braille`, `arrow`, `circle`, `vertical_blocks` |
| `FILE_SORT_MODE` | `name_az`, `name_za`, `size_small`, `size_large`, `date_new`, `date_old` |

---

## Failures, diagnosis and recovery

When a file fails (encode error, bad output, failed merge), the script:

1. writes the reason to that file's log,
2. copies the original, any partial output, the logs and probe data into `.ffmpeg_diagnostics/<timestamp>/<name>/` inside the input folder,
3. continues with the rest of the batch,
4. offers a menu at the end: **start diagnosis**, **return to the main menu**, or **view isolated files and failure details**.

The interactive diagnosis (also reachable from main-menu option **9 Diagnose**) runs staged checks, for example a full decode test of the source, and shows what it found and why. Where possible it can **recover**: re-encode the video and audio streams separately, mux them, verify the result and install it into the output folder. Each stage can be run, skipped, retried or stopped (Enter / S / R / Q).

Nothing in the diagnostics folder is deleted automatically.

---

## Project layout

```
convert.sh               entry point: settings, folders, input handling, main loop
lib-config.sh            dependency check, config load/save, time/size helpers, scaling rules
lib-probe.sh             ffprobe analysis, bitrate and frame-rate detection, integrity check
lib-encode.sh            batch scan and sorting, single-pass and chunked encoding, merge, ETA
lib-diagnostics.sh       failure classification, isolation, post-batch menu
lib-diag-recovery.sh     interactive diagnosis and stream recovery
lib-ui-kit.sh            shared look and feel (boxes, rows, prompts), CPU temperature
lib-ui-info.sh           input/output info cards, progress bars, countdown
lib-ui-main_menu.sh      main menu
lib-ui-adv_menu.sh       advanced menu
CHANGES.md               list of bugs fixed in the review, and open decisions
fixes.diff               unified diff of those fixes
```

Each module has a loading guard, so it is safe to source twice.

---

## Notes and limitations

- Output is written directly to its final name. An interrupted single-pass encode can leave a partial file there, and a rerun overwrites an existing output of the same name.
- `-map 0:v -map 0:a?` means cover-art streams are treated as video, and subtitles, chapters and attachments are dropped.
- Single-pass and chunked SVT-AV1 runs use slightly different encoder parameters.
- The output-format check looks at the video codec only, not the audio codec (for example WebM with AAC is not flagged).
- `mkvmerge` is a required tool in the dependency check, although the merge can fall back to ffmpeg. The ffmpeg-concat fallback re-encodes audio with `libopus` if stream copy fails.
- Stopping with SIGTERM (instead of Ctrl+C) may leave an ffmpeg process running; check with `pgrep ffmpeg`.
- Developed for Termux. The automated checks in `CHANGES.md` were run on Linux (bash 5.2, ffmpeg 6.1) with short test clips, not on a phone.
- Long AV1 encodes keep the CPU busy for hours. Keep the phone cool, plugged in and with battery optimisation off for Termux (`termux-wake-lock` helps), and keep threads at 1–4.

---

## Troubleshooting

| Problem | What to do |
|---|---|
| `MISSING DEPENDENCIES` | Run the `pkg install ...` line the script prints |
| `CANNOT CREATE OR WRITE ... FOLDER` | Run `termux-setup-storage`, or change the folder in `convert.sh` or the config |
| "No video files found" in the default folders | Put videos in `/sdcard/Movies/ffmpeg/Job`, or type the path at the **Start** prompt |
| Encoder not found | Your ffmpeg build lacks it; choose another codec or install a fuller ffmpeg build |
| Playback looks slightly jerky on some players | Keep **Frame rate** on `auto` (it converts variable-rate sources to a constant rate) |
| Resumed output looks mixed | Delete the `chunks_*` folder next to the source and start again |
| A file keeps failing | Open **9 Diagnose**, or read its log in the Logs folder |
| Phone gets hot / throttles | Lower threads, raise the preset number (faster), use auto cooldown, take breaks between files |
